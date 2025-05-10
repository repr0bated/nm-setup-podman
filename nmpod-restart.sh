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
