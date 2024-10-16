#!/bin/bash

# Variables
BACKUP_DIR="/f/backup/VirtualBox VMs/media-10.1.1.5/backup"  # Replace with your local backup directory
CONFIG_DIR="/home/lindsay/.config/appdata"
DOCKER_DIR="/home/lindsay/.docker"
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

    echo "Creating backup of $DOCKER_DIR..."
    tar -czf "$VERSIONED_BACKUP_DIR/docker_backup.tar.gz" -C "$DOCKER_DIR" .
}

# Main script execution
stop_docker_containers
create_backups
restart_docker_containers

echo "Backup completed and stored in $VERSIONED_BACKUP_DIR."
