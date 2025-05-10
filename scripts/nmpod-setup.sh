#!/bin/bash
# Netmaker Podman Setup Script (nmpod-setup.sh)
# ------------------------------------------------------------------------------
# This script sets up a complete Netmaker environment with EMQX MQTT broker
# using Podman pods for containerization. 
#
# Features:
# - Creates and configures all required components for Netmaker
# - Generates SSL/TLS certificates for secure communications
# - Configures EMQX MQTT broker with proper security settings
# - Sets up Nginx as a reverse proxy
# - Generates helper scripts for managing the deployment
# - Uses Podman pods for better network isolation and management
#
# The script will also generate additional management scripts:
# - nmpod-run.sh: Creates the pod and starts all services
# - nmpod-stop.sh: Stops the running pod and services
# - nmpod-restart.sh: Restarts the pod and services
# - nmpod-cleanup.sh: Completely removes all components and data
#
# Usage: ./nmpod-setup.sh <domain> [server_port] [broker_port] [dashboard_port]
# ------------------------------------------------------------------------------
set -e

# Cleanup function
cleanup() {
    echo "Cleaning up old configurations..."
    
    # Stop and remove existing pod if it exists
    if podman pod exists netmaker; then
        echo "Stopping and removing existing netmaker pod..."
        podman pod stop netmaker 2>/dev/null || true
        podman pod rm netmaker 2>/dev/null || true
    fi

    # Remove old volumes
    podman volume rm netmaker-mq-data netmaker-mq-logs 2>/dev/null || true
    podman volume rm netmaker-data netmaker-certs 2>/dev/null || true
}

# Arguments
DOMAIN=$1
SERVER_PORT=${2:-8081}
BROKER_PORT=${3:-8883}
DASHBOARD_PORT=${4:-8080}

# Validate command line arguments
if [ -z "$DOMAIN" ]; then
    echo "Error: Domain name is required"
    echo "Usage: $0 <domain> [server_port] [broker_port] [dashboard_port]"
    exit 1
fi

echo "Setting up Netmaker with EMQX broker for domain: $DOMAIN"
echo "Ports configuration:"
echo "  - Server/API Port: $SERVER_PORT"
echo "  - MQTT Broker SSL Port: $BROKER_PORT"
echo "  - MQTT Broker TCP Port: 1883 (fixed)"
echo "  - Dashboard Port: $DASHBOARD_PORT"

# Clean up before starting
cleanup

# Get absolute path to the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$BASE_DIR/config"

# Create config directory
[ ! -d $CONFIG_DIR ] && mkdir -p $CONFIG_DIR
[ ! -d $CONFIG_DIR/emqx-certs ] && mkdir -p $CONFIG_DIR/emqx-certs

# Generate a secure cookie for EMQX
EMQX_COOKIE="$(openssl rand -hex 16)"
echo "Generated secure EMQX cookie: $EMQX_COOKIE"

# Prepare EMQX broker configuration
echo "Creating EMQX configuration..."
cat << EOF > $CONFIG_DIR/emqx.conf
node {
  name = "emqx@netmaker-mq"
  cookie = "$EMQX_COOKIE"
}

listeners.ssl.default {
  bind = "0.0.0.0:8883"
  ssl_options {
    keyfile = "/etc/emqx/certs/server.key"
    certfile = "/etc/emqx/certs/server.pem"
    cacertfile = "/etc/emqx/certs/root.pem"
    verify = verify_peer
  }
}

listeners.tcp.default {
  bind = "0.0.0.0:1883"
}

authentication = [
  {
    mechanism = "password_based"
    backend = "built_in_database"
    enable = true
  }
]

authorization {
  sources = ["file", "http", "built_in_database"]
  no_match = allow
  deny_action = ignore
}
EOF

# Generate TLS certificates
echo "Creating TLS certificates..."
if [ ! -f $CONFIG_DIR/selfsigned.key ]; then
    echo "Generating self-signed certificates for domain: $DOMAIN"
    
    # Create OpenSSL config
    cat << EOF > $CONFIG_DIR/openssl.cnf
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${DOMAIN}
C = US
ST = State
L = City
O = Organization
OU = Unit

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
EOF

    # Generate certificate using config
    openssl req -x509 \
        -newkey rsa:4096 -sha256 \
        -days 3650 -nodes \
        -keyout $CONFIG_DIR/selfsigned.key \
        -out $CONFIG_DIR/selfsigned.crt \
        -config $CONFIG_DIR/openssl.cnf

    # Clean up config
    rm $CONFIG_DIR/openssl.cnf
else
    echo "Using existing self-signed certificates at $CONFIG_DIR/selfsigned.key"
fi

# Generate EMQX certificates
echo "Generating EMQX specific certificates..."

# Generate server certificate for EMQX
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout $CONFIG_DIR/emqx-certs/server.key \
    -out $CONFIG_DIR/emqx-certs/server.pem \
    -subj "/CN=broker.$DOMAIN" \
    -addext "subjectAltName = DNS:broker.$DOMAIN,DNS:*.broker.$DOMAIN"

# Copy selfsigned cert as root CA
if [ -f $CONFIG_DIR/selfsigned.crt ]; then
    echo "Using existing certificate as root CA..."
    cp $CONFIG_DIR/selfsigned.crt $CONFIG_DIR/emqx-certs/root.pem
else
    echo "Creating root CA certificate..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout $CONFIG_DIR/emqx-certs/root.key \
        -out $CONFIG_DIR/emqx-certs/root.pem \
        -subj "/CN=Root CA for $DOMAIN" \
        -addext "basicConstraints=critical,CA:TRUE"
fi

# Ensure all files have proper permissions
chmod 644 $CONFIG_DIR/emqx-certs/*.pem $CONFIG_DIR/selfsigned.crt
chmod 600 $CONFIG_DIR/emqx-certs/*.key $CONFIG_DIR/selfsigned.key

# Prepare reverse proxy configuration
echo "Creating Nginx reverse proxy configuration..."
cat << EOF > $CONFIG_DIR/nginx.conf
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log    /var/log/nginx/access.log  main;

    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       8443 ssl;
        server_name api.$DOMAIN;

        ssl_certificate /etc/nginx/ssl/selfsigned.crt;
        ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

        # Enhanced SSL security settings
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
        ssl_session_timeout 1d;
        ssl_session_cache shared:SSL:50m;

        location / {
            # Use the container name for service discovery within the pod
            proxy_pass   http://netmaker-server:8081;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }

    server {
        listen       8080 ssl;
        server_name dashboard.$DOMAIN;

        ssl_certificate /etc/nginx/ssl/selfsigned.crt;
        ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

        # Enhanced SSL security settings
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
        ssl_session_timeout 1d;
        ssl_session_cache shared:SSL:50m;

        location / {
            # Use the container name for service discovery within the pod
            proxy_pass   http://netmaker-ui:80;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }
}
EOF

# Create podman-compose.yml
COMPOSE_FILE="$BASE_DIR/podman-compose.yml"
echo "Creating podman-compose.yml at $COMPOSE_FILE"
cat << EOF > $COMPOSE_FILE
version: '3.8'

services:
  netmaker-server:
    image: gravitl/netmaker:latest
    container_name: netmaker-server
    volumes:
      - netmaker-data:/root/data
      - netmaker-certs:/etc/netmaker
    environment:
      - SERVER_NAME=broker.$DOMAIN
      - SERVER_API_CONN_STRING=api.$DOMAIN:$SERVER_PORT
      - MASTER_KEY=TODO_REPLACE_MASTER_KEY
      - DATABASE=sqlite
      - NODE_ID=netmaker-server
      - MQ_HOST=netmaker-mq
      - MQ_PORT=1883
      - TELEMETRY=off
      - VERBOSITY=3
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
    restart: unless-stopped

  netmaker-mq:
    image: emqx/emqx:latest
    container_name: netmaker-mq
    volumes:
      - $CONFIG_DIR/emqx.conf:/opt/emqx/etc/emqx.conf:ro
      - netmaker-mq-data:/opt/emqx/data
      - netmaker-mq-logs:/opt/emqx/log
      - $CONFIG_DIR/emqx-certs:/etc/emqx/certs:ro
    environment:
      - EMQX_NODE__NAME=emqx@netmaker-mq
      - EMQX_NODE__COOKIE=$EMQX_COOKIE
      - EMQX_NODE__DATA_DIR=/opt/emqx/data
      - EMQX_NODE__DB_BACKEND=mnesia
      - EMQX_CLUSTER__PROTO_DIST=inet_tcp
      - EMQX_NODE__DIST_NET_TICKTIME=120
    restart: unless-stopped

  netmaker-ui:
    image: gravitl/netmaker-ui:latest
    container_name: netmaker-ui
    environment:
      - BACKEND_URL=https://api.$DOMAIN:$SERVER_PORT
    restart: unless-stopped

  netmaker-proxy:
    image: nginx
    container_name: netmaker-proxy
    volumes:
      - $CONFIG_DIR/nginx.conf:/etc/nginx/nginx.conf:ro
      - $CONFIG_DIR/selfsigned.key:/etc/nginx/ssl/selfsigned.key
      - $CONFIG_DIR/selfsigned.crt:/etc/nginx/ssl/selfsigned.crt
    restart: unless-stopped

volumes:
  netmaker-data:
  netmaker-mq-data:
  netmaker-mq-logs:
  netmaker-certs:
EOF

# Create an init script to run all services
INIT_SCRIPT="$BASE_DIR/scripts/nmpod-run.sh"
echo "Creating init script at $INIT_SCRIPT"
cat << EOF > $INIT_SCRIPT
#!/bin/bash
# Netmaker Podman Run Script (nmpod-run.sh)
# ------------------------------------------------------------------------------
# This script creates the Netmaker pod and launches all required services.
# It handles:
# - Creation of the pod with proper port mappings
# - Starting all services using podman-compose
# - Waiting for EMQX broker to fully initialize
# - Configuring EMQX with proper credentials and permissions
#
# This should be run after nmpod-setup.sh has generated the configuration.
# ------------------------------------------------------------------------------
set -e

# Get absolute path to the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$BASE_DIR/podman-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: podman-compose.yml not found at $COMPOSE_FILE"
    echo "Please run nmpod-setup.sh first"
    exit 1
fi

# Create the pod with proper port mappings
echo "Creating netmaker pod..."
podman pod create --name netmaker \\
  -p ${SERVER_PORT}:8081 \\
  -p ${BROKER_PORT}:8883 \\
  -p 1883:1883 \\
  -p ${DASHBOARD_PORT}:8080 \\
  -p 8443:8443

# Start the services using podman-compose
echo "Starting services with podman-compose..."
cd $BASE_DIR
podman-compose -f $COMPOSE_FILE up -d

# Wait for EMQX to start
echo "Waiting for EMQX to start (this may take up to 30 seconds)..."
for i in {1..30}; do
  if podman exec netmaker-mq emqx_ctl status >/dev/null 2>&1; then
    echo "EMQX is up and running!"
    break
  fi
  
  if [ $i -eq 30 ]; then
    echo "Warning: Timed out waiting for EMQX to start."
    echo "You may need to manually configure EMQX once it's running."
    exit 1
  fi
  
  echo -n "."
  sleep 1
done

# Configure EMQX
echo "Configuring EMQX users and permissions..."
podman exec netmaker-mq emqx_ctl users add netmaker netmaker || echo "Warning: Failed to add EMQX user."
podman exec netmaker-mq emqx_ctl acl add username netmaker topic "#" allow || echo "Warning: Failed to configure EMQX ACL."

echo "Checking service status..."
podman ps

echo "Setup completed successfully!"
echo "Your Netmaker instance is now running."
echo ""
echo "Access points:"
echo "- API/Server: https://api.${DOMAIN}:${SERVER_PORT}"
echo "- Dashboard: https://dashboard.${DOMAIN}:${DASHBOARD_PORT}"
echo "- MQTT Broker (SSL): broker.${DOMAIN}:${BROKER_PORT}"
echo "- MQTT Broker (TCP): broker.${DOMAIN}:1883"
EOF

chmod +x $INIT_SCRIPT

# Create stop script for easier management
STOP_SCRIPT="$BASE_DIR/scripts/nmpod-stop.sh"
echo "Creating stop script at $STOP_SCRIPT"
cat << 'EOF' > $STOP_SCRIPT
#!/bin/bash
# Netmaker Podman Stop Script (nmpod-stop.sh)
# ------------------------------------------------------------------------------
# This script stops the Netmaker pod and all its services.
# It safely shuts down the Netmaker environment without removing any data.
# The environment can be restarted using nmpod-run.sh or nmpod-restart.sh.
# ------------------------------------------------------------------------------

echo "Stopping Netmaker pod and all services..."
podman pod stop netmaker
echo "Netmaker pod stopped."
EOF

chmod +x $STOP_SCRIPT

# Create restart script
RESTART_SCRIPT="$BASE_DIR/scripts/nmpod-restart.sh"
echo "Creating restart script at $RESTART_SCRIPT"
cat << 'EOF' > $RESTART_SCRIPT
#!/bin/bash
# Netmaker Podman Restart Script (nmpod-restart.sh)
# ------------------------------------------------------------------------------
# This script restarts the Netmaker pod and all its services.
# It performs a clean stop and start sequence by:
# 1. Stopping the pod using nmpod-stop.sh
# 2. Waiting a moment for all systems to properly shut down
# 3. Starting the pod again using nmpod-run.sh
#
# This is useful when configuration changes have been made or to
# recover from temporary issues without losing any data.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

echo "Restarting Netmaker pod and all services..."

# Stop the pod
$SCRIPT_DIR/nmpod-stop.sh

# Wait a moment
sleep 2

# Start the pod 
$SCRIPT_DIR/nmpod-run.sh

echo "Netmaker pod restarted."
EOF

chmod +x $RESTART_SCRIPT

# Create a cleanup script
CLEANUP_SCRIPT="$BASE_DIR/scripts/nmpod-cleanup.sh"
echo "Creating cleanup script at $CLEANUP_SCRIPT"
cat << 'EOF' > $CLEANUP_SCRIPT
#!/bin/bash
# Netmaker Podman Cleanup Script (nmpod-cleanup.sh)
# ------------------------------------------------------------------------------
# This script completely removes all Netmaker components and data.
# WARNING: This is a destructive operation that will:
# - Stop and remove the Netmaker pod
# - Delete all persistent volumes and their data
# - Remove all containers associated with the Netmaker pod
#
# This is useful when:
# - You want to perform a complete reinstall
# - You're decommissioning the Netmaker installation
# - You need to reset all data and start fresh
#
# The script includes confirmation to prevent accidental deletions.
# ------------------------------------------------------------------------------

echo "WARNING: This will remove all Netmaker components and data."
echo "This action CANNOT be undone."
echo "Are you sure you want to continue? (y/N)"
read -r response
if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Stop and remove pod
echo "Stopping and removing Netmaker pod..."
podman pod exists netmaker && podman pod stop netmaker 2>/dev/null
podman pod exists netmaker && podman pod rm netmaker 2>/dev/null

# Remove volumes
echo "Removing volumes..."
podman volume exists netmaker-mq-data && podman volume rm netmaker-mq-data 2>/dev/null
podman volume exists netmaker-mq-logs && podman volume rm netmaker-mq-logs 2>/dev/null
podman volume exists netmaker-data && podman volume rm netmaker-data 2>/dev/null
podman volume exists netmaker-certs && podman volume rm netmaker-certs 2>/dev/null

echo "Cleanup completed."
echo "You can run nmpod-setup.sh again to reinstall Netmaker."
EOF

chmod +x $CLEANUP_SCRIPT

# Create a status script
STATUS_SCRIPT="$BASE_DIR/scripts/nmpod-status.sh"
echo "Creating status script at $STATUS_SCRIPT"
cat << 'EOF' > $STATUS_SCRIPT
#!/bin/bash
# Netmaker Podman Status Script (nmpod-status.sh)
# ------------------------------------------------------------------------------
# This script checks the status of the Netmaker environment.
# It provides information about:
# - Pod status
# - Running containers
# - Volume status
# - EMQX broker health
# - Network connectivity
#
# Use this script to diagnose issues with your Netmaker deployment.
# ------------------------------------------------------------------------------

echo "Checking Netmaker environment status..."
echo "--------------------------------------"

# Check if pod exists
if ! podman pod exists netmaker; then
  echo "❌ Netmaker pod does not exist."
  echo "Run nmpod-setup.sh followed by nmpod-run.sh to create and start the pod."
  exit 1
fi

# Check pod status
POD_STATUS=$(podman pod inspect netmaker --format "{{.State}}")
if [ "$POD_STATUS" == "Running" ]; then
  echo "✅ Netmaker pod is running."
else
  echo "❌ Netmaker pod exists but is not running (current state: $POD_STATUS)."
  echo "Run nmpod-run.sh to start the pod."
  exit 1
fi

# Check container status
echo -e "\nContainer Status:"
echo "-----------------"
podman ps --pod netmaker --format "{{.Names}}: {{.Status}}"

# Check EMQX status
echo -e "\nEMQX Broker Status:"
echo "------------------"
if podman exec -it netmaker-mq emqx_ctl status >/dev/null 2>&1; then
  echo "✅ EMQX broker is running."
  
  # Check if netmaker user exists
  if podman exec -it netmaker-mq emqx_ctl users list | grep -q netmaker; then
    echo "✅ EMQX netmaker user is configured."
  else
    echo "❌ EMQX netmaker user is not configured."
    echo "Run: podman exec netmaker-mq emqx_ctl users add netmaker netmaker"
  fi
else
  echo "❌ EMQX broker is not responding."
fi

# Check Netmaker API
echo -e "\nNetmaker API Status:"
echo "------------------"
if podman exec -it netmaker-server curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/api/status >/dev/null 2>&1; then
  echo "✅ Netmaker API is accessible."
else
  echo "❌ Netmaker API is not responding."
fi

# Show volume information
echo -e "\nVolume Status:"
echo "-------------"
for vol in netmaker-data netmaker-certs netmaker-mq-data netmaker-mq-logs; do
  if podman volume exists $vol; then
    VOLSIZE=$(podman volume inspect $vol --format "{{.Mountpoint}}" | xargs -I{} du -sh {} 2>/dev/null | cut -f1)
    echo "$vol: Exists (Size: $VOLSIZE)"
  else
    echo "$vol: Missing"
  fi
done

echo -e "\nCheck complete."
EOF

chmod +x $STATUS_SCRIPT

echo "All configuration files generated successfully"
echo ""
echo "To start the Netmaker services, run:"
echo "  $INIT_SCRIPT"
echo ""
echo "To stop the services:"
echo "  $STOP_SCRIPT"
echo ""
echo "To restart the services:"
echo "  $RESTART_SCRIPT"
echo ""
echo "To check status of services:"
echo "  $STATUS_SCRIPT"
echo ""
echo "For complete cleanup (removes all data):"
echo "  $CLEANUP_SCRIPT" 