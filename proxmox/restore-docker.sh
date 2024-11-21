#!/bin/bash

# Exit on any error
set -e

# Get the non-root user who invoked the script
if [[ -n "$SUDO_USER" ]]; then
  USER_HOME=$(eval echo ~"$SUDO_USER")
else
  echo "This script must be run with sudo."
  exit 1
fi

# Default backup directory
DEFAULT_BACKUP_DIR="/media/vmb/vmb/_docker_backup"
BACKUP_DIR="$DEFAULT_BACKUP_DIR"

# Function to display the menu and handle selections
show_menu() {
  # Ask if the user wants to change the restore base directory
  read -p "Do you want to change the restore base directory? (y/n): " change_dir_choice
  if [[ "$change_dir_choice" == "y" || "$change_dir_choice" == "Y" ]]; then
    read -p "Enter the new restore base directory: " NEW_BACKUP_DIR
    if [[ -d "$NEW_BACKUP_DIR" ]]; then
      BACKUP_DIR="$NEW_BACKUP_DIR"
      echo "Backup directory changed to $BACKUP_DIR."
    else
      echo "Invalid directory. Using the default directory $DEFAULT_BACKUP_DIR."
      BACKUP_DIR="$DEFAULT_BACKUP_DIR"
    fi
  else
    echo "Using default backup directory: $BACKUP_DIR."
  fi

  # Get the list of existing hostnames in the backup directory
  HOSTNAMES=$(ls "$BACKUP_DIR")

  if [[ -z "$HOSTNAMES" ]]; then
    echo "No backups found in $BACKUP_DIR. Exiting."
    exit 1
  fi

  # Display the list of available hostnames (backups)
  echo "Available backups:"
  PS3="Select a hostname to restore from: "
  select HOSTNAME in $HOSTNAMES; do
    if [[ -n "$HOSTNAME" ]]; then
      echo "Selected backup: $HOSTNAME"
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done

  # Define restore directories
  COMPOSE_BACKUP_DIR="$BACKUP_DIR/$HOSTNAME/compose"
  CONFIG_BACKUP_DIR="$BACKUP_DIR/$HOSTNAME/appdata"

  # Prompt user if they want to restore Docker Compose files or appdata
  echo "1. Restore Docker Compose files"
  echo "2. Restore Configuration (Appdata)"
  echo "3. Exit"
  read -p "Choose an option (1/2/3): " choice

  case $choice in
    1)
      restore_compose
      ;;
    2)
      restore_config
      ;;
    3)
      echo "Exiting script. Goodbye!"
      exit 0
      ;;
    *)
      echo "Invalid option. Exiting."
      exit 1
      ;;
  esac
}

# Function to restore Docker Compose files
restore_compose() {
    # Ensure the destination directory exists
    mkdir -p "$USER_HOME/.docker/compose"
    echo "Restoring Docker Compose files from $COMPOSE_BACKUP_DIR..."
    
    # Copy backup files to the compose directory
    sudo cp -r "$COMPOSE_BACKUP_DIR"/* "$USER_HOME/.docker/compose/"
    
    # Set ownership to the non-root user
    sudo chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.docker/compose"
    echo "Docker Compose files restored successfully."
}

# Function to restore Configuration (Appdata)
restore_config() {
    # Ensure the destination directory exists
    mkdir -p "$USER_HOME/.config/appdata"
    echo "Restoring appdata from $CONFIG_BACKUP_DIR..."
    
    # Stop all running Docker containers before restoring
    echo "Stopping all running Docker containers..."
    docker ps --quiet | xargs --no-run-if-empty docker stop
    
    # Copy backup files to the appdata directory
    sudo cp -r "$CONFIG_BACKUP_DIR"/* "$USER_HOME/.config/appdata/"
    
    # Set ownership to the non-root user
    sudo chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.config/appdata"
    echo "Appdata restored successfully."
    
    # Ask if the user wants to restart Docker containers
    read -p "Do you want to restart Docker containers? (y/n): " restart_choice
    if [[ "$restart_choice" == "y" || "$restart_choice" == "Y" ]]; then
        echo "Restarting Docker containers..."
        docker ps -a --quiet | xargs --no-run-if-empty docker start
    else
        echo "Docker containers will remain stopped."
    fi
}

# Main loop to keep showing the menu after an operation
while true; do
  show_menu
done
