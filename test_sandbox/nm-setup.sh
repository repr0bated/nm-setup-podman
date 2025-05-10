#!/bin/bash
set -e

# Cleanup function
cleanup() {
    echo "Cleaning up old configurations..."
    
    # Stop and remove existing pod if it exists
    if podman pod exists netmaker; then
        echo "Stopping and removing existing netmaker pod..."
        podman pod stop netmaker
        podman pod rm netmaker
    fi

    # Remove old configuration files
    [ -f $NMDIR/mosquitto.conf ] && rm $NMDIR/mosquitto.conf
    [ -f $NMDIR/emqx.conf ] && rm $NMDIR/emqx.conf

    # Remove old volumes
    podman volume rm netmaker-mq-data netmaker-mq-logs 2>/dev/null || true
    podman volume rm netmaker-data netmaker-certs 2>/dev/null || true
}

# Call cleanup before starting new setup
cleanup

# Arguments
DOMAIN=$1
SERVER_PORT=${2:-8081}
BROKER_PORT=${3:-8883}
DASHBOARD_PORT=${4:-8080}

# Validate domain
if [ -z "$DOMAIN" ]; then
    echo "Error: Domain name is required"
    echo "Usage: $0 <domain> [server_port] [broker_port] [dashboard_port]"
    exit 1
fi

# Directory containing volume data
[ "${EUID:-$(id -u)}" -eq 0 ] \
    && NMDIR=/var/lib/netmaker \
    || NMDIR=$HOME/.local/share/netmaker

# Create state directory if not exists
[ ! -d $NMDIR ] && mkdir -p $NMDIR

# Get absolute path to the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$BASE_DIR/config"

# Create config directory
[ ! -d $CONFIG_DIR ] && mkdir -p $CONFIG_DIR

# Generate a secure cookie for EMQX
EMQX_COOKIE="$(openssl rand -hex 16)"

# Prepare broker configuration
[ ! -f $CONFIG_DIR/emqx.conf ] && cat << EOF > $CONFIG_DIR/emqx.conf
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

# Prepare reverse proxy certificates
if [ ! -f $CONFIG_DIR/selfsigned.key ]; then
    echo "Creating netmaker-proxy TLS certificates..."
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
fi

# Generate EMQX certificates
echo "Generating EMQX certificates..."
mkdir -p $CONFIG_DIR/emqx-certs

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
chmod 644 $CONFIG_DIR/emqx-certs/*.pem
chmod 600 $CONFIG_DIR/emqx-certs/*.key

# Prepare reverse proxy configuration
[ ! -f $CONFIG_DIR/nginx.conf ] && cat << EOF > $CONFIG_DIR/nginx.conf
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

        location / {
            proxy_pass   http://netmaker-server:8081;
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

        location / {
            proxy_pass   http://netmaker-ui:80;
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
    pod: netmaker

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
    pod: netmaker

  netmaker-ui:
    image: gravitl/netmaker-ui:latest
    container_name: netmaker-ui
    environment:
      - BACKEND_URL=https://api.$DOMAIN:$SERVER_PORT
    restart: unless-stopped
    pod: netmaker

  netmaker-proxy:
    image: nginx
    container_name: netmaker-proxy
    volumes:
      - $CONFIG_DIR/nginx.conf:/etc/nginx/nginx.conf:ro
      - $CONFIG_DIR/selfsigned.key:/etc/nginx/ssl/selfsigned.key
      - $CONFIG_DIR/selfsigned.crt:/etc/nginx/ssl/selfsigned.crt
    restart: unless-stopped
    pod: netmaker

volumes:
  netmaker-data:
  netmaker-mq-data:
  netmaker-mq-logs:
  netmaker-certs:
EOF

echo "Configuration files generated. Creating pod and starting services..."

# Create the pod with proper port mappings
echo "Creating pod with necessary port mappings..."
podman pod create --name netmaker \
  -p $SERVER_PORT:8443 \
  -p $BROKER_PORT:8883 \
  -p 1883:1883 \
  -p $DASHBOARD_PORT:8080

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
echo "Your Netmaker instance is now running with EMQX as the broker."
echo "- API: https://api.$DOMAIN:$SERVER_PORT"
echo "- Dashboard: https://dashboard.$DOMAIN:$DASHBOARD_PORT"
echo "- MQTT Broker: broker.$DOMAIN:$BROKER_PORT (SSL) and broker.$DOMAIN:1883 (TCP)"
