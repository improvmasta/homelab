#!/bin/bash

# Define the general setup log file (this would be at the top of your larger script)
SETUP_LOG="/var/log/setup.log"

setup_samba_shares() {
    local secrets_file="/etc/samba_credentials"
    local server_ip samba_user samba_pass share_name mount_point
    local -a shares=()  # Array to hold all share names

    # Function to log messages to the general setup log file
    log_message() {
        local message="$1"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | sudo tee -a "$SETUP_LOG" > /dev/null
    }

    # Ensure script is run with necessary privileges
    if [[ $EUID -ne 0 ]]; then
        echo "Please run this script with sudo or as root."
        return 1
    fi

    # Prompt for the Samba server IP or hostname
    read -p "Enter the file server hostname/IP: " server_ip
    if [[ -z "$server_ip" ]]; then
        log_message "No server hostname/IP entered. Exiting Samba setup..."
        echo "No server hostname/IP entered. Exiting Samba setup..."
        return 1
    fi

    # Prompt for Samba credentials
    read -p "Enter the Samba username: " samba_user
    read -sp "Enter the Samba password: " samba_pass
    echo

    # Create or update the secrets file with proper permissions
    {
        echo "username=$samba_user"
        echo "password=$samba_pass"
    } | sudo tee "$secrets_file" > /dev/null
    sudo chmod 600 "$secrets_file"
    log_message "Credentials stored securely in $secrets_file."

    # Collect and validate share names
    while :; do
        read -p "Enter a Samba share name (or press Enter to finish): " share_name
        [[ -z "$share_name" ]] && break
        shares+=("$share_name")
    done

    if [[ ${#shares[@]} -eq 0 ]]; then
        log_message "No shares were added."
        echo "No shares were added."
        return 1
    fi

    # Add each share to fstab and create mount points
    for share_name in "${shares[@]}"; do
        mount_point="/media/$share_name"
        sudo mkdir -p "$mount_point"

        # Check for existing fstab entry to avoid duplicates
        if grep -qs "^//$server_ip/$share_name" /etc/fstab; then
            log_message "Skipping $share_name; entry already exists in /etc/fstab."
            echo "Skipping $share_name; entry already exists in /etc/fstab."
            continue
        fi

        # Append entry to fstab
        echo "//${server_ip}/${share_name} ${mount_point} cifs credentials=${secrets_file},uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0 0 0" | sudo tee -a /etc/fstab > /dev/null
        log_message "Added $share_name to /etc/fstab, mounted at $mount_point."
    done

    # Attempt to mount all shares and log the result
    if sudo mount -a; then
        log_message "All Samba shares mounted successfully."
        echo "All Samba shares mounted successfully."
    else
        log_message "Error occurred while mounting Samba shares."
        echo "Error occurred while mounting Samba shares. Check $SETUP_LOG for details."
        return 1
    fi
}

# Example of calling the function within a larger setup script
setup_samba_shares
