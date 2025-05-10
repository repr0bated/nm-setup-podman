#!/bin/bash
# Netmaker Podman Setup Script (nmpod-setup.sh)
# ------------------------------------------------------------------------------
# Sets up Netmaker with EMQX broker using Podman pods
# Usage: ./nmpod-setup.sh <domain> [server_port] [broker_port] [dashboard_port]
# ------------------------------------------------------------------------------
set -e

# Cleanup function
cleanup() {
    echo "Cleaning up old configurations..."
    podman pod exists netmaker && podman pod stop netmaker 2>/dev/null && podman pod rm netmaker 2>/dev/null
    podman volume rm netmaker-mq-data netmaker-mq-logs netmaker-data netmaker-certs 2>/dev/null || true
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

# Clean up before starting
cleanup

# Setup directories
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$BASE_DIR/config"
mkdir -p $CONFIG_DIR/emqx-certs

# Generate a secure cookie for EMQX
EMQX_COOKIE="$(openssl rand -hex 16)"

# Create EMQX configuration
echo "Creating EMQX configuration..."
cat > $CONFIG_DIR/emqx.conf << EOFEMQX
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
EOFEMQX

# Generate TLS certificates
echo "Creating TLS certificates..."
if [ ! -f $CONFIG_DIR/selfsigned.key ]; then
    # Generate OpenSSL config
    cat > $CONFIG_DIR/openssl.cnf << EOFOPENSSL
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
EOFOPENSSL

    # Generate certificate
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout $CONFIG_DIR/selfsigned.key \
        -out $CONFIG_DIR/selfsigned.crt \
        -config $CONFIG_DIR/openssl.cnf
    rm $CONFIG_DIR/openssl.cnf
fi

# Generate EMQX certificates
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout $CONFIG_DIR/emqx-certs/server.key \
    -out $CONFIG_DIR/emqx-certs/server.pem \
    -subj "/CN=broker.$DOMAIN" \
    -addext "subjectAltName = DNS:broker.$DOMAIN,DNS:*.broker.$DOMAIN"

# Copy selfsigned cert as root CA
[ -f $CONFIG_DIR/selfsigned.crt ] && cp $CONFIG_DIR/selfsigned.crt $CONFIG_DIR/emqx-certs/root.pem || \
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout $CONFIG_DIR/emqx-certs/root.key \
        -out $CONFIG_DIR/emqx-certs/root.pem \
        -subj "/CN=Root CA for $DOMAIN" \
        -addext "basicConstraints=critical,CA:TRUE"

# Set permissions
chmod 644 $CONFIG_DIR/emqx-certs/*.pem $CONFIG_DIR/selfsigned.crt
chmod 600 $CONFIG_DIR/emqx-certs/*.key $CONFIG_DIR/selfsigned.key

# Create Nginx config
echo "Creating Nginx config..."
cat > $CONFIG_DIR/nginx.conf << EOFNGINX
user  nginx;
worker_processes  auto;
error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;
events { worker_connections  1024; }

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
        ssl_protocols TLSv1.2 TLSv1.3;
        location / {
            proxy_pass   http://netmaker-server:8081;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }

    server {
        listen       8080 ssl;
        server_name dashboard.$DOMAIN;
        ssl_certificate /etc/nginx/ssl/selfsigned.crt;
        ssl_certificate_key /etc/nginx/ssl/selfsigned.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        location / {
            proxy_pass   http://netmaker-ui:80;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }
}
EOFNGINX

# Create podman-compose.yml
COMPOSE_FILE="$BASE_DIR/podman-compose.yml"
echo "Creating podman-compose.yml at $COMPOSE_FILE"
cat > $COMPOSE_FILE << EOFCOMPOSE
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
EOFCOMPOSE

# Create scripts directory if it doesn't exist
mkdir -p "$BASE_DIR/scripts"

# Create the additional scripts
for script in run stop restart cleanup status; do
    # Create utility scripts
    SCRIPT_PATH="$BASE_DIR/scripts/nmpod-$script.sh"
    echo "Creating $SCRIPT_PATH..."
    touch $SCRIPT_PATH
    chmod +x $SCRIPT_PATH
done

echo "Configuration completed! Next steps:"
echo "1. Edit scripts/nmpod-run.sh to create the pod and start services"
echo "2. Run scripts/nmpod-run.sh to start the Netmaker environment"
echo "3. Use scripts/nmpod-status.sh to check the status"
