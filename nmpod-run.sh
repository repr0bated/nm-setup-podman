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
CONFIG_DIR="$BASE_DIR/config"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: podman-compose.yml not found at $COMPOSE_FILE"
    echo "Please run nmpod-setup.sh first"
    exit 1
fi

# Fix EMQX authorization configuration - update for compatibility
echo "Updating EMQX configuration for compatibility..."
cat > $CONFIG_DIR/emqx.conf << EOFEMQX
node {
  name = "emqx@netmaker-mq"
  cookie = "$(grep 'cookie' $CONFIG_DIR/emqx.conf | cut -d'"' -f2)"
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

# Updated authorization config format
authorization {
  no_match = allow
  sources = [
    {
      type = "file"
    },
    {
      type = "http"
    },
    {
      type = "built_in_database"
    }
  ]
}
EOFEMQX

# Create the pod with proper port mappings
echo "Creating netmaker pod..."
podman pod create --name netmaker \
  -p 8081:8081 \
  -p 8883:8883 \
  -p 1883:1883 \
  -p 8080:8080 \
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
