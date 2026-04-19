#!/bin/bash

# Default values for the .env file
DEFAULT_TZ="America/New_York"
DEFAULT_UPLOAD_LOCATION="/media/d/photos_2015+/_phone_backup"
DEFAULT_DB_DATA_LOCATION="/home/lindsay/.config/appdata/immich"
DEFAULT_IMMICH_VERSION="release"
DEFAULT_DB_PASSWORD="postgres"
DEFAULT_DB_USERNAME="postgres"
DEFAULT_DB_DATABASE_NAME="immich"

# Prompt user for input with default values
prompt_input() {
    local prompt="$1"
    local default="$2"
    local input

    read -p "$prompt [$default]: " input
    echo "${input:-$default}"
}

# Create .env file
create_env_file() {
    echo "Creating .env file..."
    {
        echo "TZ=$TZ"
        echo "UPLOAD_LOCATION=$UPLOAD_LOCATION"
        echo "DB_DATA_LOCATION=$DB_DATA_LOCATION"
        echo "IMMICH_VERSION=$IMMICH_VERSION"
        echo "DB_PASSWORD=$DB_PASSWORD"
        echo "DB_USERNAME=$DB_USERNAME"
        echo "DB_DATABASE_NAME=$DB_DATABASE_NAME"
    } > .env
    echo ".env file created successfully."
}

# Main script execution
if [[ -f .env ]]; then
    read -p ".env file already exists. Do you want to overwrite it? (y/N): " overwrite
    if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
        echo "Aborting. .env file not modified."
        exit 1
    fi
fi

echo "Please provide values for the .env file variables. Press Enter to use the default values."

TZ=$(prompt_input "Enter the timezone (TZ)" "$DEFAULT_TZ")
UPLOAD_LOCATION=$(prompt_input "Enter the upload location (UPLOAD_LOCATION)" "$DEFAULT_UPLOAD_LOCATION")
DB_DATA_LOCATION=$(prompt_input "Enter the database data location (DB_DATA_LOCATION)" "$DEFAULT_DB_DATA_LOCATION")
IMMICH_VERSION=$(prompt_input "Enter the Immich version (IMMICH_VERSION)" "$DEFAULT_IMMICH_VERSION")
DB_PASSWORD=$(prompt_input "Enter the database password (DB_PASSWORD)" "$DEFAULT_DB_PASSWORD")
DB_USERNAME=$(prompt_input "Enter the database username (DB_USERNAME)" "$DEFAULT_DB_USERNAME")
DB_DATABASE_NAME=$(prompt_input "Enter the database name (DB_DATABASE_NAME)" "$DEFAULT_DB_DATABASE_NAME")

create_env_file
