#!/bin/bash

# Variables
BACKUP_DIR="/media/f/backup/VirtualBox VMs/media-10.1.1.5/backup"  # Replace with your local backup directory
CONFIG_DIR="/home/lindsay/.config/appdata"
DOCKER_DIR="/home/lindsay/.docker"
STORAGE_DIR="/home/lindsay/storage"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
VERSIONED_BACKUP_DIR="$BACKUP_DIR/backup_$TIMESTAMP"
MAX_BACKUPS=1

# Create backup directory
mkdir -p "$VERSIONED_BACKUP_DIR"

# Function to stop all Docker containers
stop_docker_containers() {
    echo "Stopping all running Docker containers..."
    CONTAINERS=$(docker ps -q)
    if [ -n "$CONTAINERS" ]; then
        docker stop $CONTAINERS
    else
        echo "No running containers to stop."
    fi
}

# Function to restart Docker containers
restart_docker_containers() {
    echo "Restarting Docker containers..."
    if [ -n "$CONTAINERS" ]; then
        docker start $CONTAINERS
    else
        echo "No containers to restart."
    fi
}

# Function to create backups using tar
create_backups() {
    echo "Creating backup of $CONFIG_DIR..."
    tar -czf "$VERSIONED_BACKUP_DIR/appdata_backup.tar.gz" -C "$CONFIG_DIR" .

    echo "Creating backup of $STORAGE_DIR..."
    tar -czf "$VERSIONED_BACKUP_DIR/storage_backup.tar.gz" -C "$STORAGE_DIR" .

    echo "Creating backup of $DOCKER_DIR..."
    tar -czf "$VERSIONED_BACKUP_DIR/docker_backup.tar.gz" -C "$DOCKER_DIR" .
}

# Function to clean up old backups, keeping only the latest
cleanup_old_backups() {
    echo "Cleaning up old backups, keeping the latest $MAX_BACKUPS..."

    # List backup directories, sort by modification time (newest first), and skip the newest ones
    BACKUPS=$(ls -dt "$BACKUP_DIR"/backup_* 2>/dev/null)

    # Check if there are more backups than the MAX_BACKUPS threshold
    if [ $(echo "$BACKUPS" | wc -l) -gt "$MAX_BACKUPS" ]; then
        # Find backups to delete: list all backups, except the first $MAX_BACKUPS
        TO_DELETE=$(echo "$BACKUPS" | tail -n +$(($MAX_BACKUPS + 1)))

        # Delete old backups
        echo "Deleting old backups:"
        echo "$TO_DELETE" | xargs rm -rf --
        echo "Old backups removed."
    else
        echo "No old backups to remove."
    fi
}

# Main script execution
stop_docker_containers
create_backups
cleanup_old_backups
restart_docker_containers

echo "Backup completed and stored in $VERSIONED_BACKUP_DIR."
