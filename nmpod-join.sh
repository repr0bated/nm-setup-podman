#!/bin/bash
# Netmaker Podman Join Script (nmpod-join.sh)
# ------------------------------------------------------------------------------
# This script creates a Netmaker client container to join a Netmaker network.
# It handles:
# - Extracting the API server details from the enrollment token
# - Creating a container with proper capabilities for WireGuard
# - Adding the API server certificate to the client's trusted certificates
# - Starting the client to establish the connection
#
# Usage: ./nmpod-join.sh <enrollment_token>
# ------------------------------------------------------------------------------
set -e

# Arguments
TOKEN=$1

# Validate token
if [ -z "$TOKEN" ]; then
    echo "Error: Enrollment token is required"
    echo "Usage: $0 <enrollment_token>"
    exit 1
fi

echo "Creating Netmaker client container to join network..."

# Fetch API server information from token
echo "Extracting server information from token..."
SERVER=$(echo $TOKEN | base64 -d 2>/dev/null | jq -r .apiconnstring 2>/dev/null || echo "")

if [ -z "$SERVER" ]; then
    echo "Error: Invalid token format. Could not extract server information."
    exit 1
fi

# Fetch API server certificate
echo "Fetching API server certificate from $SERVER..."
CERT_FILE=$(mktemp -p /tmp nm-${SERVER%:*}.XXXXXX.pem)
if ! openssl s_client -showcerts -connect $SERVER </dev/null 2>/dev/null | openssl x509 -outform PEM > $CERT_FILE; then
    echo "Error: Failed to fetch server certificate. Check if the server is accessible."
    rm -f $CERT_FILE
    exit 1
fi

# Generate random postfix for container name
CONTAINER_NAME=netclient-$(openssl rand -hex 4)
echo "Creating client container with name: $CONTAINER_NAME"

# Create netclient container
podman create --name $CONTAINER_NAME \
    -e TOKEN=$TOKEN \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add SYS_MODULE \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    gravitl/netclient:latest

if [ $? -ne 0 ]; then
    echo "Error: Failed to create container."
    rm -f $CERT_FILE
    exit 1
fi

# Append certificate to container system certificates
echo "Adding server certificate to client's trusted certificates..."
podman cp $CONTAINER_NAME:/etc/ssl/certs/ca-certificates.crt /tmp/nc-certs.crt
cat $CERT_FILE >> /tmp/nc-certs.crt
podman cp /tmp/nc-certs.crt $CONTAINER_NAME:/etc/ssl/certs/ca-certificates.crt

# Cleanup temp files
rm -f $CERT_FILE /tmp/nc-certs.crt

# Start netclient container
echo "Starting Netmaker client container..."
podman start $CONTAINER_NAME

echo "Checking client status..."
sleep 3
podman logs $CONTAINER_NAME

echo "Client container $CONTAINER_NAME created and started."
echo "To check status: podman logs $CONTAINER_NAME"
echo "To configure persistence, run: ./nmpod-persist.sh"
