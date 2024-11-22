#!/bin/bash

# Exit on error
set -e

# Function to prompt for hostname
get_hostname() {
    local current_hostname
    current_hostname=$(hostname)
    read -p "Current hostname is '$current_hostname'. Use this for backup? (y/n): " hostname_choice
    if [[ "$hostname_choice" == "y" || "$hostname_choice" == "Y" ]]; then
        echo "$current_hostname"
    else
        read -p "Enter a new hostname for the backup: " new_hostname
        echo "$new_hostname"
    fi
}

# Get hostname (user can change it)
HOSTNAME=$(get_hostname)

# Default backup directories
DEFAULT_COMPOSE_DIR="/media/vmb/vmb/_docker_backup/$HOSTNAME/compose"
DEFAULT_CONFIG_DIR="/media/vmb/vmb/_docker_backup/$HOSTNAME/appdata"

# Function to handle existing backups
handle_existing_backup() {
    local backup_dir="$1"
    if [[ -d "$backup_dir" ]]; then
        echo "Backup directory '$backup_dir' already exists."
        read -p "Do you want to (r)ename or (d)elete the existing backup? (r/d): " choice
        case $choice in
            r|R)
                read -p "Enter a new name for the existing backup directory: " new_name
                mv "$backup_dir" "${backup_dir}_$new_name"
                echo "Existing backup renamed to '${backup_dir}_$new_name'."
                ;;
            d|D)
                sudo rm -rf "$backup_dir"
                echo "Existing backup removed."
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
    fi
}

# Function to change ownership of files to the sudo user
change_owner() {
    local backup_dir="$1"
    echo "Changing ownership of files in $backup_dir to $SUDO_USER..."
    sudo chown -R "$SUDO_USER:$SUDO_USER" "$backup_dir"
}

# Function to backup Docker Compose files
backup_compose() {
    echo "Backing up Docker Compose files..."
    
    # Prompt user to confirm or change the destination directory
    read -p "Enter backup destination for Compose files (default: $DEFAULT_COMPOSE_DIR): " compose_backup_dir
    compose_backup_dir=${compose_backup_dir:-$DEFAULT_COMPOSE_DIR}

    # Check if backup already exists
    handle_existing_backup "$compose_backup_dir"

    # Create the destination directory if it doesn't exist
    sudo mkdir -p "$compose_backup_dir"

    # Backup Docker Compose files
    sudo cp -r ~/.docker/compose/. "$compose_backup_dir/"
    echo "Compose files backed up to $compose_backup_dir."

    # Change ownership back to the sudo user
    change_owner "$compose_backup_dir"
}

# Function to backup configuration (appdata)
backup_config() {
    echo "Backing up configuration (appdata)..."

    # Stop running Docker containers
    echo "Stopping all running Docker containers..."
    docker ps --quiet | xargs --no-run-if-empty docker stop

    # Prompt user to confirm or change the destination directory
    read -p "Enter backup destination for appdata (default: $DEFAULT_CONFIG_DIR): " config_backup_dir
    config_backup_dir=${config_backup_dir:-$DEFAULT_CONFIG_DIR}

    # Check if backup already exists
    handle_existing_backup "$config_backup_dir"

    # Create the destination directory if it doesn't exist
    sudo mkdir -p "$config_backup_dir"

    # Backup appdata
    sudo cp -r ~/.config/appdata/* "$config_backup_dir/"
    echo "Configuration (appdata) backed up to $config_backup_dir."

    # Change ownership back to the sudo user
    change_owner "$config_backup_dir"

    # Ask if user wants to restart Docker containers
    read -p "Do you want to restart Docker containers? (y/n): " restart_choice
    if [[ "$restart_choice" == "y" || "$restart_choice" == "Y" ]]; then
        echo "Restarting Docker containers..."
        docker ps -a --quiet | xargs --no-run-if-empty docker start
    else
        echo "Docker containers will remain stopped."
    fi
}

# Main menu
while true; do
    echo "Backup Menu:"
    echo "1. Backup Compose"
    echo "2. Backup Config"
    echo "3. Exit"
    read -p "Choose an option (1/2/3): " choice

    case $choice in
        1)
            backup_compose
            ;;
        2)
            backup_config
            ;;
        3)
            echo "Exiting script. Goodbye!"
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            ;;
    esac
done
