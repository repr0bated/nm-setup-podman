#!/bin/bash
# Netmaker Podman Persist Script (nmpod-persist.sh)
# ------------------------------------------------------------------------------
# This script sets up systemd services to run the Netmaker environment
# automatically on system startup. It creates:
# - Container services for each Netmaker component
# - A routes synchronization service with a timer
#
# Run this after nmpod-setup.sh and nmpod-run.sh to make the setup persistent.
# ------------------------------------------------------------------------------

# Constants
NETMAKER_DIR=/var/lib/netmaker
SYSTEMD_UNIT_DIR=/etc/systemd/system

# Ensure netmaker dir exists
[ ! -d $NETMAKER_DIR ] && mkdir -p $NETMAKER_DIR

# Verify we're running as root for systemd operations
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges for systemd operations"
    echo "Please run as root or with sudo"
    exit 1
fi

echo "Setting up Netmaker services for persistence..."

# Gather applicable containers
containers=$(podman ps --format '{{ .Names }}' | grep 'netmaker-\|netclient-')

# For each container
for container in $containers; do
    # Generate container service file if not exists
    unit_file=$SYSTEMD_UNIT_DIR/$container.service
    if [ ! -f $unit_file ]; then
        echo "Creating systemd service for $container..."
        podman generate systemd -n $container > $unit_file
        echo "Service file created at $unit_file"
    else
        echo "Service file for $container already exists"
    fi

    # Enable and start service
    systemctl enable --now $container
    echo "Service $container enabled and started"
done

# Copy route sync script
echo "Setting up route synchronization..."
cp $(dirname "$0")/nmpod-routes.sh $NETMAKER_DIR/
chmod a+x $NETMAKER_DIR/nmpod-routes.sh

# Generate service and timer unit files for route syncing
if [ ! -f $SYSTEMD_UNIT_DIR/netmaker-routes.service ]; then
    cat << EOF_SERVICE > $SYSTEMD_UNIT_DIR/netmaker-routes.service
[Unit]
Description=Synchronize Netmaker container routes
Wants=network.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$NETMAKER_DIR/nmpod-routes.sh

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    echo "Created route sync service"
fi

if [ ! -f $SYSTEMD_UNIT_DIR/netmaker-routes.timer ]; then
    cat << EOF_TIMER > $SYSTEMD_UNIT_DIR/netmaker-routes.timer
[Unit]
Description=Periodic Netmaker route synchronization

[Timer]
OnCalendar=*:*:00/30
AccuracySec=1sec
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
    echo "Created route sync timer"
fi

# Reload unit files
systemctl daemon-reload

# Enable and start timer
systemctl enable --now netmaker-routes.timer
echo "Route synchronization timer enabled and started"

echo "Netmaker environment is now set up for persistence."
echo "All components will start automatically on system boot."
