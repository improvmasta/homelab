#!/bin/bash

# Function to prompt user for input with a default value
prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local input

  read -p "$prompt_text [$default_value]: " input
  echo "${input:-$default_value}"
}

# Prompting user for environment variables
echo "Let's create an .env file for your Docker Compose setup."
TZ=$(prompt "TZ" "Enter your timezone (e.g., America/New_York)" "UTC")
USERNAME=$(prompt "USERNAME" "Enter the username for Docker services" "$(whoami)")
APPDATA_PATH=$(prompt "APPDATA_PATH" "Enter the app data path (e.g., /home/$USERNAME/.config/appdata)" "/home/$USERNAME/.config/appdata")

# Create the .env file
cat <<EOF > .env
# Environment variables for Docker Compose

TZ=$TZ
USERNAME=$USERNAME
APPDATA_PATH=$APPDATA_PATH
EOF

echo ".env file created with the following content:"
cat .env
