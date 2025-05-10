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

# Create config directory
CONFIG_DIR=$NMDIR/config
[ ! -d $CONFIG_DIR ] && mkdir -p $CONFIG_DIR

# Prepare broker configuration
[ ! -f $CONFIG_DIR/emqx.conf ] && cat << EOF > $CONFIG_DIR/emqx.conf
node {
  name = "emqx@127.0.0.1"
  cookie = "emqxsecretcookie"
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
    echo "Creating netmaker-proxy tls certificates ..."
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

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log    /var/log/nginx/access.log  main;

    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       8443 ssl;
        server_name api.$DOMAIN;

        ssl_certificate /etc/nginx/ssl/selfsigned.crt;
        ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

        location / {
            proxy_pass   http://127.0.0.1:8081;
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
            proxy_pass   http://127.0.0.1:80;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }
}
EOF

# Create podman-compose.yml
cat << EOF > $NMDIR/podman-compose.yml
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
      - MQ_HOST=localhost
      - MQ_PORT=$BROKER_PORT
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
      - $CONFIG_DIR/emqx.conf:/opt/emqx/etc/emqx.conf
      - netmaker-mq-data:/opt/emqx/data
      - netmaker-mq-logs:/opt/emqx/log
      - netmaker-certs:/etc/emqx/certs
    environment:
      - EMQX_NODE__NAME=emqx@127.0.0.1
      - EMQX_NODE__COOKIE=emqxsecretcookie
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

# Create the pod first
echo "Creating netmaker pod..."
podman pod create -n netmaker \
    -p $SERVER_PORT:8443 \
    -p $BROKER_PORT:8883 \
    -p $DASHBOARD_PORT:8080 \
    -p 51821-51830:51821-51830/udp

# Start the services
echo "Starting Netmaker services..."
cd $NMDIR
podman-compose up -d

# Wait for EMQX to start
echo "Waiting for EMQX to start..."
max_attempts=30
attempt=1
while [ $attempt -le $max_attempts ]; do
    if podman exec netmaker-mq emqx_ctl status >/dev/null 2>&1; then
        echo "EMQX is ready!"
        break
    fi
    echo "Waiting for EMQX to start (attempt $attempt/$max_attempts)..."
    sleep 2
    attempt=$((attempt + 1))
done

if [ $attempt -gt $max_attempts ]; then
    echo "Error: EMQX failed to start within the expected time"
    exit 1
fi

# Setup EMQX users and permissions
echo "Setting up EMQX users and permissions..."
# Wait a bit more to ensure EMQX is fully initialized
sleep 5

# Add user if it doesn't exist
if ! podman exec netmaker-mq emqx_ctl users list | grep -q "netmaker"; then
    echo "Creating EMQX user..."
    podman exec netmaker-mq emqx_ctl users add netmaker netmaker_password
fi

# Add ACL if it doesn't exist
if ! podman exec netmaker-mq emqx_ctl acl list | grep -q "netmaker"; then
    echo "Setting up EMQX ACL..."
    podman exec netmaker-mq emqx_ctl acl add username netmaker topic "#" allow
fi

echo "EMQX configuration completed successfully"
