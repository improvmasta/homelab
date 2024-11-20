#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Log file
LOGFILE="configure_lxc.log"
exec > >(tee -i "$LOGFILE") 2>&1

# Check for container ID argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <container_id>"
    exit 1
fi

CONTAINER_ID="$1"

# Configuration
HOST_MEDIA=("/media/d" "/media/e" "/media/f" "/media/vmb")
CONTAINER_MEDIA=("/media/d" "/media/e" "/media/f" "/media/vmb")

# Check if the container exists
if ! pct list | grep -qw "$CONTAINER_ID"; then
    echo "Error: Container $CONTAINER_ID does not exist."
    exit 1
fi

# Enable nesting for the container
echo "Enabling nesting for container $CONTAINER_ID..."
pct set "$CONTAINER_ID" -features nesting=1
echo "Nesting enabled."

# Add mount points
echo "Adding mount points to container $CONTAINER_ID..."
for i in "${!HOST_MEDIA[@]}"; do
    HOST_PATH="${HOST_MEDIA[$i]}"
    CONTAINER_PATH="${CONTAINER_MEDIA[$i]}"
    
    # Ensure the host directory exists
    if [ ! -d "$HOST_PATH" ]; then
        echo "Warning: Host path $HOST_PATH does not exist. Creating it..."
        mkdir -p "$HOST_PATH"
    fi

    # Add mount point to the container
    echo "Adding mount point: Host $HOST_PATH -> Container $CONTAINER_PATH"
    pct set "$CONTAINER_ID" -mp$i "$HOST_PATH","mp=$CONTAINER_PATH"
done

echo "Mount points added successfully."

# Restart the container to apply changes
echo "Restarting container $CONTAINER_ID..."
pct stop "$CONTAINER_ID"
pct start "$CONTAINER_ID"
echo "Container $CONTAINER_ID configured successfully."
