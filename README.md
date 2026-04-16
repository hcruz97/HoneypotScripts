# Automated SSH Honeypot & Threat Intelligence Pipeline

This project deploys a highly interactive SSH honeypot using Cowrie paried with a centralized Threat Intelligence dashboard (Elastic Stack) on Google Cloud Platform (GCP). It automatically traps malicious actors attempting to brute-force SSH, captures their passwords and terminal commands, and securely streams that data via Filebeat to a Kibana dashboard for real-life visulization and threat analysis

## Prerequisites & Architecture
Before running any scripts, provision the infrastructure.

### Requirements
- Google Cloud Platform (GCP) account https://cloud.google.com/
- A credit card to have on file (its free to use charges may apply !) 
- Two Virtual Machines in the same VPC network

### Operating System (Both VMs)
- Ubuntu 22.04 LTS (x86/64, amd64 jammy image)

## Phase 1: Environemnt set up and Network Security (Firewall Rules)

### Cloud set up
- Create Google cloud account
- Add payment information (make sure not to fully activate if you wish to remain in a free trial)
- Once in the welcome screen use search tool at the top to lookup "Compute Engine API" and enable it

### VM Configuration
- Create a VM
  
#### VM 1: **ELK Server (Central Logging & Dashboard)**
- Machine Type: e2-standard-2
- Boot Disk Size: 20 GB 
- Network: Ephemeral IP

#### VM 2: **The Honeypot Server (The Trap)**
- Machine Type: e2-small
- Boot Disk Size: 10 GB

**Important: Complete this step before running scripts to avoid losing access.**

#### Create Firewall Rules In GCP Console
Navigate to:
VPC Network → Firewall → Create Firewall Rule

#### Rule 1: Allow Kibana Dashboard Access
- Name: ***allow-kibana-external***
- Direction: Ingress
- Action: Allow
- Targets: All instances in the network
- Source IPv4 ranges: ***0.0.0.0/0*** *(Security Note: For strict production environments, replace this with your personal public IP address)*
- Protocols and ports: ***TCP 5601***

#### Rule 2: Allow Admin SSH Access on Custom Port
- Name: ***allow-admin-ssh-5000***
- Direction: Ingress
- Action: Allow
- Targets: All instances in the network
- Source IPv4 ranges: ***0.0.0.0/0*** *(Security Note: For strict production environments, replace this with your personal public IP address)*
- Protocols and ports: ***TCP 5000***\
*Note:
Port 22 will be used by the honeypot. Administrative SSH access is moved to port 5000.*

## Phase 2: Deploy the ELK Stack

#### Connect to **ELK Server**
**SSH into the ELK VM via GCP.**

#### Download Script
`wget https://raw.githubusercontent.com/hcruz97/HoneypotScripts/main/elk-setup.sh`

#### Fix Line Endings
`sed -i 's/\r$//' elk-setup.sh`

#### Run Script
`sudo bash elk-setup.sh `
##### Important
- Create a secure password when prompted
- Save:
  - ELK Server IP Address
  - Password

## Phase 3: Deploy the Honeypot

#### Connect to **Honeypot Server**
**SSH into the honeypot VM via GCP.**

#### Download Script
`wget https://raw.githubusercontent.com/hcruz97/HoneypotScripts/main/honeypot-setup.sh`

#### Fix Line Endings
`sed -i 's/\r$//' honeypot-setup.sh`

#### Run Script
`sudo bash honeypot-setup.sh`
##### Required Inputs
- ELK Server IP
  - Use internal IP if in same VPC
  - Use external IP if remote
- Password
  - Must match the password created in Phase 2

## Phase 4: Verification & Usage
1. Simulate an Attack\
From your local machine:
`ssh root@<HONEYPOT_EXTERNAL_IP>`\
Enter any password (e.g., ***123456***)\
Run commands such as:
```
uname -a
whoami
```
2. View Captured Data\
Open your browser: http://<ELK_EXTERNAL_IP>:5601

Username: ***elastic***\
Password: (your configured password)\
Steps:
- Go to Discover
- Select data view: cowrie-*

3. Admin Access to Honeypot\
Since port 22 is occupied:
- Go to GCP Console
- Click dropdown next to SSH
- Select: Open in browser window on custom port
- Enter: ***5000***

## Troubleshooting Guide

### ELK Server Diagnostics
#### Check Elasticsearch
`sudo systemctl status elasticsearch`

#### Check Kibana
```
sudo systemctl status kibana
sudo ss -tlnp | grep 5601
```

#### View Kibana Logs
`sudo journalctl -u kibana -n 50 --no-pager`

### Honeypot Server Diagnostics
#### Check Cowrie Logs
`sudo tail -n 20 /home/user/cowrie/var/log/cowrie/cowrie.json`

#### Test Filebeat Connection
`sudo filebeat test output`


Expected output:\
***talk to server... OK*** \
Common Errors:
- ***401 Unauthorized*** → Incorrect password
- ***EOF or timeout*** → Firewall or IP issue

#### View Filebeat Logs
`sudo journalctl -u filebeat -n 50 --no-pager`

## Still Stuck? 
If issues persist, copy your error output and paste it into Gemini or Claude with a prompt like:
> I am running a Cowrie to ELK pipeline on Ubuntu 22.04.
> I ran [command] and received the following output:
> [paste output]
> What is the root cause and how do I fix it?

## Project Team and Credits

Georgia Gwinnett College Capstone Project
- Leena  
- Hector  
- Wendy  
- Myea  
