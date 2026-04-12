#!/bin/bash
set -e

# ============================================================
# elk-setup.sh
# Installs Elasticsearch + Kibana on a fresh Ubuntu VM
# Creates cowrie-* data view automatically via Kibana API
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

echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] \
  https://artifacts.elastic.co/packages/8.x/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/elastic-8.x.list

sudo apt-get update -y
sudo apt-get install -y elasticsearch

# ============================================================
# STEP 2: Configure Elasticsearch
# ============================================================
echo "[2/7] Configuring Elasticsearch..."

sudo tee -a /etc/elasticsearch/elasticsearch.yml > /dev/null <<'ESCONF'

# --- Added by elk-setup.sh ---
network.host: 0.0.0.0
discovery.type: single-node
xpack.security.enabled: true
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.keystore.path: certs/http.p12
ESCONF

sudo systemctl daemon-reload
sudo systemctl enable elasticsearch
sudo systemctl start elasticsearch

echo "Waiting for Elasticsearch to start..."
sleep 30

# ============================================================
# STEP 3: Set elastic user password
# ============================================================
echo "[3/7] Setting elastic user password..."

sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic -i -b <<< "${ES_PASS}
${ES_PASS}"

curl -s -u elastic:"${ES_PASS}" -k https://localhost:9200 > /dev/null \
  && echo "Elasticsearch is responding!" \
  || echo "WARNING: Elasticsearch may not be ready yet"

# ============================================================
# STEP 4: Install Kibana
# ============================================================
echo "[4/7] Installing Kibana..."

sudo apt-get install -y kibana

# ============================================================
# STEP 5: Configure Kibana
# ============================================================
echo "[5/7] Configuring Kibana..."

ENC_KEY=$(openssl rand -hex 16)

sudo tee -a /etc/kibana/kibana.yml > /dev/null <<KBCONF

# --- Added by elk-setup.sh ---
server.host: "0.0.0.0"
server.port: 5601
elasticsearch.hosts: ["https://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.ssl.verificationMode: none

# Encryption key for connectors/alerting
xpack.encryptedSavedObjects.encryptionKey: "${ENC_KEY}"
KBCONF

# Set kibana_system password to match elastic password
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u kibana_system -i -b <<< "${ES_PASS}
${ES_PASS}"

# Add password to kibana.yml
sudo sed -i '/elasticsearch.username/a \
elasticsearch.password: "'"${ES_PASS}"'"' \
  /etc/kibana/kibana.yml

sudo systemctl daemon-reload
sudo systemctl enable kibana
sudo systemctl start kibana

# ============================================================
# STEP 6: Wait for Kibana
# ============================================================
echo "[6/7] Waiting for Kibana to start (~90 seconds)..."
sleep 90

for i in {1..10}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    http://localhost:5601/api/status)
  if [ "$STATUS" = "200" ]; then
    echo "Kibana is up!"
    break
  fi
  echo "Still waiting... (attempt $i/10)"
  sleep 15
done

# ============================================================
# STEP 7: Create cowrie-* data view
# ============================================================
echo "[7/7] Creating cowrie-* data view..."

curl -s -X POST "http://localhost:5601/api/data_views/data_view" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u elastic:"${ES_PASS}" \
  -d '{
    "data_view": {
      "title": "cowrie-*",
      "name": "cowrie-*",
      "timeFieldName": "@timestamp"
    }
  }'

echo ""
echo ""
echo "============================================"
echo "  ELK SETUP COMPLETE"
echo "============================================"
echo ""
echo "Elasticsearch: https://<this-VM-IP>:9200"
echo "Kibana:        http://<this-VM-IP>:5601"
echo "Username:      elastic"
echo "Password:      (the one you just set)"
echo "Data view:     cowrie-* (already created)"
echo ""
echo "NEXT STEPS:"
echo "1. Give Leena this VM's external IP + password"
echo "2. Make sure firewall rules are configured"
echo "3. Check Kibana Discover for logs once honeypot is running"
