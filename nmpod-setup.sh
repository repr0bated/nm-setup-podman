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
