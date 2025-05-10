#!/bin/bash
# Netmaker Podman Cleanup Script (nmpod-cleanup.sh)
# ------------------------------------------------------------------------------
# This script completely removes all Netmaker components and data.
# It performs the following operations:
# - Stops and removes systemd services if they exist
# - Stops and removes all Netmaker pods and containers
# - Removes all Netmaker related volumes
# - Optionally removes all state directories
#
# WARNING: This is a destructive operation that will result in data loss.
# ------------------------------------------------------------------------------
set -e

# Arguments
REMOVE_STATE=false
while [ "$1" != "" ]; do
    case $1 in
        -a|--all)
            REMOVE_STATE=true
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -a, --all     Also remove state directories"
            echo "  -h, --help    Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
    shift
done

echo "Starting Netmaker cleanup process..."

# Directory containing volume data
[ "${EUID:-$(id -u)}" -eq 0 ] \
    && NMDIR=/var/lib/netmaker \
    || NMDIR=$HOME/.local/share/netmaker

# Remove systemd units if running as root
if [ "$(id -u)" -eq 0 ]; then
    echo "Checking for systemd units..."
    units=$(systemctl list-unit-files --all | grep 'netmaker-\|netclient-' | awk '{print $1}')
    if [ -n "$units" ]; then
        for unit in $units; do
            echo "Disabling and stopping $unit..."
            systemctl disable --now $unit

            echo "Removing $unit..."
            unit_path=$(systemctl show -P FragmentPath $unit)
            rm -f $unit_path
        done
        systemctl daemon-reload
        echo "Systemd units removed."
    else
        echo "No systemd units found."
    fi
fi

# Stop and remove all netmaker pods
echo "Checking for Netmaker pods..."
if podman pod exists netmaker; then
    echo "Stopping and removing netmaker pod..."
    podman pod stop netmaker
    podman pod rm -f netmaker
    echo "Netmaker pod removed."
else
    echo "No Netmaker pod found."
fi

# Stop and remove all netclient containers
echo "Checking for Netmaker client containers..."
clients=$(podman ps -a --format '{{.Names}}' | grep 'netclient-')
if [ -n "$clients" ]; then
    echo "Removing Netmaker client containers..."
    for client in $clients; do
        podman stop $client 2>/dev/null || true
        podman rm -f $client
        echo "Removed $client."
    done
else
    echo "No Netmaker client containers found."
fi

# Remove volumes
echo "Removing Netmaker volumes..."
volumes="netmaker-data netmaker-certs netmaker-mq-data netmaker-mq-logs"
for vol in $volumes; do
    if podman volume exists $vol; then
        podman volume rm -f $vol
        echo "Removed volume $vol."
    else
        echo "Volume $vol not found."
    fi
done

# Remove state directory if requested
if [ $REMOVE_STATE = true ]; then
    echo "Removing state directory $NMDIR..."
    if [ -d "$NMDIR" ]; then
        rm -rf $NMDIR
        echo "State directory removed."
    else
        echo "State directory not found."
    fi
fi

echo "Cleanup completed successfully."
