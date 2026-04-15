#!/bin/bash
set -e

# ============================================================
# elk-setup.sh
# Installs Elasticsearch + Kibana on a fresh Ubuntu 22.04 VM
# Run with: sudo bash elk-setup.sh
# ============================================================

echo "=== ELK Stack Setup Script ==="
echo ""

# --- Prompt for Elasticsearch password ---
read -sp "Choose a password for the elastic user: " ES_PASS
echo ""
read -sp "Confirm password: " ES_PASS_CONFIRM
echo ""
echo ""

if [ "$ES_PASS" != "$ES_PASS_CONFIRM" ]; then
  echo "ERROR: Passwords do not match."
  exit 1
fi

if [ -z "$ES_PASS" ]; then
  echo "ERROR: Password cannot be empty."
  exit 1
fi

# ============================================================
# STEP 1: Install Elasticsearch
# ============================================================
echo "[1/7] Installing Elasticsearch..."

wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | sudo gpg --dearmor -o /usr/share/keyrings/elastic.gpg

echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/elastic-8.x.list

sudo apt-get update -y
sudo apt-get install -y elasticsearch

# ============================================================
# STEP 2: Start Elasticsearch
# ============================================================
echo "[2/7] Starting Elasticsearch..."

# Elasticsearch 8.x auto-configures everything needed (security, TLS, network binding)
# during install. We do NOT touch elasticsearch.yml — adding anything risks
# duplicate key errors that will prevent startup.

sudo systemctl daemon-reload
sudo systemctl enable elasticsearch
sudo systemctl start elasticsearch

echo "Waiting for Elasticsearch to start..."
sleep 30

# ============================================================
# STEP 3: Set elastic user password
# ============================================================
echo "[3/7] Setting elastic user password..."

# Use -b (batch) to reset to a temporary random password, then
# immediately change it to our chosen password via the API.
# This avoids TTY/interactive issues with piped input.
RESET_OUTPUT=$(sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b 2>&1)
TEMP_PASS=$(echo "$RESET_OUTPUT" | grep "New value:" | awk '{print $NF}')

if [ -z "$TEMP_PASS" ]; then
  echo "ERROR: Could not capture temporary password. Output was:"
  echo "$RESET_OUTPUT"
  exit 1
fi

# Now set to our chosen password via the API
curl -s -u elastic:"${TEMP_PASS}" -k \
  -X POST https://localhost:9200/_security/user/elastic/_password \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"${ES_PASS}\"}" > /dev/null \
  && echo "Elasticsearch password set successfully!" \
  || { echo "ERROR: Failed to set elastic password."; exit 1; }

# Verify
curl -s -u elastic:"${ES_PASS}" -k https://localhost:9200 > /dev/null \
  && echo "Elasticsearch is responding!" \
  || { echo "ERROR: Elasticsearch not responding. Run: sudo journalctl -u elasticsearch -n 30"; exit 1; }

# ============================================================
# STEP 4: Install Kibana
# ============================================================
echo "[4/7] Installing Kibana..."

sudo apt-get install -y kibana

# ============================================================
# STEP 5: Configure Kibana
# ============================================================
echo "[5/7] Configuring Kibana..."

# Generate random encryption key for Kibana connectors/alerting
ENC_KEY=$(openssl rand -hex 16)

# Set kibana_system password via API using our elastic credentials
curl -s -u elastic:"${ES_PASS}" -k \
  -X POST https://localhost:9200/_security/user/kibana_system/_password \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"${ES_PASS}\"}" > /dev/null \
  && echo "kibana_system password set!" \
  || { echo "ERROR: Failed to set kibana_system password."; exit 1; }

# Write all Kibana settings in one block BEFORE starting Kibana
sudo tee -a /etc/kibana/kibana.yml > /dev/null <<KBCONF

# --- Added by elk-setup.sh ---
server.host: "0.0.0.0"
server.port: 5601
elasticsearch.hosts: ["https://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${ES_PASS}"
elasticsearch.ssl.verificationMode: none
xpack.encryptedSavedObjects.encryptionKey: "${ENC_KEY}"
KBCONF

# Now start Kibana with the complete config
sudo systemctl daemon-reload
sudo systemctl enable kibana
sudo systemctl start kibana

# ============================================================
# STEP 6: Wait for Kibana to be ready
# ============================================================
echo "[6/7] Waiting for Kibana to start (this takes about 90 seconds)..."
sleep 90

KIBANA_UP=false
for i in {1..10}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5601/api/status)
  if [ "$STATUS" = "200" ]; then
    echo "Kibana is up!"
    KIBANA_UP=true
    break
  fi
  echo "Still waiting... (attempt $i/10)"
  sleep 15
done

if [ "$KIBANA_UP" = false ]; then
  echo "WARNING: Kibana did not respond in time. Check: sudo journalctl -u kibana -n 30"
  echo "You can create the data view manually later."
  exit 1
fi

# ============================================================
# STEP 7: Create cowrie-* data view in Kibana
# ============================================================
echo "[7/7] Creating cowrie-* data view..."

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "http://localhost:5601/api/data_views/data_view" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u elastic:"${ES_PASS}" \
  -d '{
    "data_view": {
      "title": "cowrie-*",
      "name": "cowrie-*",
      "timeFieldName": "@timestamp"
    }
  }')

if [ "$RESPONSE" = "200" ] || [ "$RESPONSE" = "201" ]; then
  echo "Data view cowrie-* created successfully!"
else
  echo "WARNING: Data view creation returned HTTP ${RESPONSE}."
  echo "You can create it manually in Kibana: Stack Management -> Data Views -> Create"
fi

# ============================================================
# DONE
# ============================================================
ELK_IP=$(curl -sf --max-time 5 -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/externalIp" \
  2>/dev/null || hostname -I | awk "{print \$1}")

echo ""
echo "============================================"
echo "  ELK SETUP COMPLETE"
echo "============================================"
echo ""
echo "  Kibana:        http://${ELK_IP}:5601"
echo "  Elasticsearch: https://${ELK_IP}:9200"
echo "  Username:      elastic"
echo "  Password:      (the one you just set)"
echo "  Data view:     cowrie-* (auto-created)"
echo ""
echo "NEXT STEPS:"
echo "  1. !IMPORTANT! Save this ELK server IP address: ${ELK_IP}"
echo "  2. Configure GCP firewall rules if you haven't already (see README)"
echo "  3. Run honeypot-setup.sh on the honeypot VM"
echo "     using this IP and your password when prompted"
echo ""
