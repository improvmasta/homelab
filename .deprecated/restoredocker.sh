#!/bin/bash

# Exit on any error
set -e

# Define base GitHub repository URL
REPO_URL="https://homelab.jupiterns.org/proxmox"

# Get the non-root user who invoked the script
if [[ -n "$SUDO_USER" ]]; then
  USER_HOME=$(eval echo ~"$SUDO_USER")
else
  echo "This script must be run with sudo."
  exit 1
fi

# Prompt the user to choose a directory (media, proxy, immich, plex)
echo "Choose a directory to pull the docker-compose.yml from:"
echo "1. media"
echo "2. proxy"
echo "3. immich"
echo "4. plex"
read -p "Enter your choice (1/2/3/4): " choice

# Set the directory and associated files based on the user's choice
case $choice in
  1)
    DIR="media"
    FILES=("docker-compose.yml" "config.sh")
    ;;
  2)
    DIR="proxy"
    FILES=("docker-compose.yml")
    ;;
  3)
    DIR="immich"
    FILES=("docker-compose.yml" ".env")
    ;;
  4)
    DIR="plex"
    FILES=("docker-compose.yml" "config.sh")
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac

# Define directories relative to the non-root user's home
DOCKER_COMPOSE_DIR="$USER_HOME/.docker/compose"
APPDATA_DIR="$USER_HOME/.config/appdata"

# Create the necessary directories if they don't exist
echo "Creating directories if they don't exist..."
mkdir -p "$DOCKER_COMPOSE_DIR" "$APPDATA_DIR"

# Download the selected files from the GitHub repository
for FILE in "${FILES[@]}"; do
  FILE_URL="$REPO_URL/$DIR/$FILE"
  echo "Downloading $FILE from $FILE_URL..."
  curl -o "$DOCKER_COMPOSE_DIR/$FILE" "$FILE_URL"
  
  # Confirm the download
  if [[ -f "$DOCKER_COMPOSE_DIR/$FILE" ]]; then
    echo "$FILE successfully downloaded to $DOCKER_COMPOSE_DIR."
  else
    echo "Failed to download $FILE. Exiting."
    exit 1
  fi
done

# Ask the user if they want to provide a restore path to copy files into appdata
read -p "Do you want to provide a restore path to copy contents into $APPDATA_DIR? (y/n): " restore_choice

if [[ "$restore_choice" == "y" || "$restore_choice" == "Y" ]]; then
  # Ask for the restore path
  read -p "Enter the restore path (directory to copy from): " restore_path

  # Check if the provided restore path exists
  if [[ -d "$restore_path" ]]; then
    echo "Copying contents from $restore_path to $APPDATA_DIR..."
    cp -r "$restore_path"/* "$APPDATA_DIR/"
    echo "Restore completed successfully."
  else
    echo "Invalid restore path. Exiting."
    exit 1
  fi
else
  echo "No restore path provided. Skipping restore."
fi
