#!/bin/bash
set -e

# ============================================================
# honeypot-setup.sh
# Installs Cowrie SSH honeypot + Filebeat on a fresh Ubuntu 22.04 VM
# Tested on Google Cloud e2-small, Ubuntu 22.04 LTS
# ============================================================

echo "================================================"
echo "       Cowrie SSH Honeypot Setup Script         "
echo "================================================"
echo ""

# --- Prompt for ELK server details ---
read -p "Enter ELK server IP address: " ELK_IP
read -sp "Enter Elasticsearch password: " ES_PASS
echo ""
echo ""

# --- Validate inputs ---
if [ -z "$ELK_IP" ] || [ -z "$ES_PASS" ]; then
  echo "ERROR: ELK IP and password are required."
  exit 1
fi

# ----------------------------------------
# STEP 1 — Move real SSH to port 5000
# ----------------------------------------
echo "[1/8] Moving real SSH to port 5000..."

sudo sed -i 's/^#Port 22$/Port 5000/' /etc/ssh/sshd_config
sudo sed -i 's/^Port 22$/Port 5000/' /etc/ssh/sshd_config
grep -q '^Port ' /etc/ssh/sshd_config || echo 'Port 5000' | sudo tee -a /etc/ssh/sshd_config

sudo systemctl restart sshd
echo "    SSH moved to port 5000."

# ----------------------------------------
# STEP 2 — Install system dependencies
# ----------------------------------------
echo "[2/8] Installing dependencies..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git \
  python3-venv \
  python3-pip \
  libssl-dev \
  libffi-dev \
  build-essential \
  python3-dev \
  iptables-persistent

# ----------------------------------------
# STEP 3 — Create cowrie system user
# ----------------------------------------
echo "[3/8] Creating cowrie user..."
sudo useradd -m -s /bin/bash user || true

# ----------------------------------------
# STEP 4 — Install Cowrie
# ----------------------------------------
echo "[4/8] Installing Cowrie v2.9.16..."

sudo -u user bash <<'COWRIE_INSTALL'
set -e
cd /home/user

# Clone directly to the pinned stable tag.
# --branch pins to the exact tag, --depth 1 skips unneeded history.
git clone --branch v2.9.16 --depth 1 https://github.com/cowrie/cowrie.git
cd cowrie

# Create virtualenv — do NOT upgrade pip.
# pip 26+ changes editable install behavior and breaks Twisted plugin discovery.
python3 -m venv cowrie-env
source cowrie-env/bin/activate

# Build a wheel first, then install from the wheel.
# This guarantees a proper non-editable install regardless of pip version.
pip install wheel
pip wheel . --no-deps -w /tmp/cowrie_wheel/
pip install /tmp/cowrie_wheel/cowrie-*.whl

# Copy the Twisted plugin into the virtualenv plugin directory.
# Required — without this Twisted reports "Unknown command: cowrie".
cp src/twisted/plugins/cowrie_plugin.py \
   cowrie-env/lib/python3.10/site-packages/twisted/plugins/

# ---- Configure cowrie.cfg ----
cp etc/cowrie.cfg.dist etc/cowrie.cfg

# Set hostname
sed -i 's/^#hostname = .*/hostname = webserver01/' etc/cowrie.cfg
sed -i 's/^hostname = .*/hostname = webserver01/' etc/cowrie.cfg

# Set SSH version string inside the existing [ssh] section.
# Do NOT append a new [ssh] section — duplicate sections crash the config parser.
sed -i '/^\[ssh\]/,/^\[/ s/^version = .*/version = SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6/' \
  etc/cowrie.cfg

# Set fake credentials
cat > etc/userdb.txt <<'USERDB'
root:x:123456
root:x:password
root:x:admin
admin:x:admin
ubuntu:x:ubuntu
root:x:!root
USERDB

COWRIE_INSTALL

echo "    Cowrie installed."

# ----------------------------------------
# STEP 5 — Create systemd service
# ----------------------------------------
echo "[5/8] Creating Cowrie systemd service..."

sudo tee /etc/systemd/system/cowrie.service > /dev/null <<'SERVICE'
[Unit]
Description=Cowrie SSH Honeypot
After=network.target

[Service]
Type=simple
User=user
WorkingDirectory=/home/user/cowrie

# PYTHONPATH tells Twisted where to find the cowrie plugin — required.
Environment="PATH=/home/user/cowrie/cowrie-env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=/home/user/cowrie/cowrie-env"
Environment="PYTHONPATH=/home/user/cowrie/src"

# --nodaemon keeps process in foreground so systemd manages it correctly.
# -l- sends logs to stdout so they appear in journalctl.
ExecStart=/home/user/cowrie/cowrie-env/bin/twistd --umask=0022 --nodaemon -l- cowrie

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable cowrie
sudo systemctl start cowrie

sleep 5
if ! sudo systemctl is-active --quiet cowrie; then
  echo "ERROR: Cowrie failed to start."
  echo "Check logs: sudo journalctl -u cowrie -n 30 --no-pager"
  exit 1
fi
echo "    Cowrie service running."

# ----------------------------------------
# STEP 6 — iptables port redirect
# ----------------------------------------
echo "[6/8] Setting up iptables redirect (port 22 -> 2222)..."

sudo iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
sudo netfilter-persistent save

echo "    iptables redirect saved."

# ----------------------------------------
# STEP 7 — Install and configure Filebeat
# ----------------------------------------
echo "[7/8] Installing Filebeat..."

wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | sudo gpg --dearmor -o /usr/share/keyrings/elastic.gpg

echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/elastic-8.x.list

sudo apt-get update -y
sudo apt-get install -y filebeat

echo "    Writing Filebeat config..."

sudo tee /etc/filebeat/filebeat.yml > /dev/null <<FBEOF
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /home/user/cowrie/var/log/cowrie/cowrie.json
  json.keys_under_root: true
  json.overwrite_keys: true
  json.add_error_key: true
  close_inactive: 5m
  scan_frequency: 5s

processors:
  - rename:
      fields:
        - from: "input"
          to: "filebeat_input"
      ignore_missing: true
      fail_on_error: false
  - timestamp:
      field: "timestamp"
      layouts:
        - "2006-01-02T15:04:05.999999Z"
      target_field: "@timestamp"
      ignore_missing: false
      ignore_failure: false

output.elasticsearch:
  hosts: ["https://${ELK_IP}:9200"]
  username: "elastic"
  password: "${ES_PASS}"
  ssl.verification_mode: none
  index: "cowrie-%{+yyyy.MM.dd}"

setup.ilm.enabled: false
setup.template.enabled: false
FBEOF

sudo systemctl enable filebeat
sudo systemctl start filebeat

sleep 5
if ! sudo systemctl is-active --quiet filebeat; then
  echo "ERROR: Filebeat failed to start."
  echo "Check logs: sudo journalctl -u filebeat -n 30 --no-pager"
  exit 1
fi
echo "    Filebeat running."

# ----------------------------------------
# STEP 8 — Done
# ----------------------------------------
echo ""
echo "================================================"
echo "              Setup Complete!                   "
echo "================================================"
echo ""
echo "  Cowrie honeypot:  port 2222 (port 22 redirects here)"
echo "  Real admin SSH:   port 5000"
echo "  Logs shipping to: https://${ELK_IP}:9200"
echo ""
echo "  Verify everything is working:"
echo "  1. sudo systemctl status cowrie"
echo "  2. sudo systemctl status filebeat"
echo "  3. ssh -p 2222 root@localhost  (password: 123456)"
echo "  4. sudo journalctl -u filebeat -f"
echo ""
echo "  IMPORTANT: Admin browser SSH now requires port 5000."
echo "  GCP Console: SSH dropdown -> Open in browser on custom port -> 5000"
echo ""
echo "  NOTE: GCP firewall rules must be configured manually."
echo "  See the firewall checklist for the required rules."
echo "================================================"
