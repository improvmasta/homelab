#!/bin/bash

# Define the general setup log file (already set in your larger script)
SETUP_LOG="/var/log/setup.log"

share_home_directory() {
    local smb_conf="/etc/samba/smb.conf"
    local samba_user password

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

    # Get the current user and their home directory
    samba_user="${SUDO_USER:-$USER}"
    home_directory=$(eval echo "~$samba_user")

    # Ensure home directory exists
    if [[ ! -d "$home_directory" ]]; then
        log_message "Home directory for user $samba_user not found."
        echo "Home directory for user $samba_user not found. Exiting..."
        return 1
    fi

    # Prompt for Samba password
    read -sp "Enter a password for Samba access to $samba_user's home directory: " password
    echo

    # Add the user to Samba if not already added
    if ! sudo pdbedit -L | grep -qw "$samba_user"; then
        echo -e "$password\n$password" | sudo smbpasswd -a "$samba_user" > /dev/null
        log_message "Samba user $samba_user added."
    else
        echo -e "$password\n$password" | sudo smbpasswd -s "$samba_user" > /dev/null
        log_message "Samba password for $samba_user updated."
    fi

    # Add Samba configuration for the user's home directory
    sudo tee -a "$smb_conf" > /dev/null <<EOF

[$samba_user Home]
    path = $home_directory
    browseable = yes
    writable = yes
    valid users = $samba_user
    create mask = 0700
    directory mask = 0700
EOF

    log_message "Samba share for $samba_user's home directory configured in $smb_conf."

    # Restart Samba to apply changes
    if sudo systemctl restart smbd; then
        log_message "Samba service restarted successfully."
        echo "Home directory shared successfully via Samba."
    else
        log_message "Failed to restart Samba service."
        echo "Error: Failed to restart Samba. Check $SETUP_LOG for details."
        return 1
    fi
}

# Example of calling the function within a larger setup script
share_home_directory
