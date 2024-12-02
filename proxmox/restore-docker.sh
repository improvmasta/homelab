#!/bin/bash

restore_docker_backup() {
    local backup_base_dir="/media/f/backup/vm/"
    local hostname=$(hostname)
    local restore_dir
    local user_home="/home/$(logname)"
    local compose_dir="$user_home/.docker/compose"
    local appdata_dir="$user_home/.config/appdata"

    echo "Docker Backup Restore"
    echo "---------------------------------"

    # Find default restore directory based on hostname
    default_restore_dir=$(find "$backup_base_dir" -maxdepth 1 -type d -name "${hostname}-*" | head -n 1)

    if [ -n "$default_restore_dir" ]; then
        echo "Default backup directory found: $default_restore_dir"
    else
        echo "No matching backup directory found for hostname '$hostname'."
    fi

    # Prompt user to select restore directory
    read -p "Enter the restore directory [default: $default_restore_dir]: " restore_dir
    restore_dir=${restore_dir:-$default_restore_dir}

    # Validate restore directory
    if [ ! -d "$restore_dir" ]; then
        echo "Error: Restore directory '$restore_dir' does not exist."
        exit 1
    fi

    # Check if containers are running
    running_containers=$(docker ps -q)
    if [ -n "$running_containers" ]; then
        echo "Warning: Containers are currently running."
        read -p "Do you want to stop all running containers? [y/N]: " stop_containers
        if [[ "$stop_containers" =~ ^[Yy]$ ]]; then
            echo "Stopping all running containers..."
            docker stop $running_containers
        else
            echo "Cannot proceed while containers are running. Exiting."
            exit 1
        fi
    fi

    # Backup current directories if they exist
    timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    if [ -d "$compose_dir" ]; then
        echo "Backing up current Docker Compose directory..."
        sudo mv "$compose_dir" "${compose_dir}_backup_$timestamp"
    fi
    if [ -d "$appdata_dir" ]; then
        echo "Backing up current AppData directory..."
        sudo mv "$appdata_dir" "${appdata_dir}_backup_$timestamp"
    fi

    # Extract the backup
    echo "Restoring backup from $restore_dir..."
    sudo mkdir -p "$compose_dir" "$appdata_dir"
    sudo tar -xzf "$restore_dir/"*-compose.tar.gz -C "$user_home" --strip-components=2
    sudo tar -xzf "$restore_dir/"*-appdata.tar.gz -C "$user_home" --strip-components=2

    # Ensure ownership of restored files
    echo "Setting ownership of restored files..."
    sudo chown -R "$(logname)" "$compose_dir" "$appdata_dir"

    # Offer to restart containers
    read -p "Do you want to restart the containers? [y/N]: " restart_containers
    if [[ "$restart_containers" =~ ^[Yy]$ ]]; then
        echo "Restarting containers..."
        docker start $(docker ps -a -q)
    fi

    echo "Restore complete!"
}

restore_docker_backup
