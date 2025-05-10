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
