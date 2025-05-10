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
