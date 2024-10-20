#!/bin/bash

# Configuration
SERVER="10.1.1.3"  # Set the location of the file server
SHARES=("d" "e" "f" "v")  # List of shares to mount
LOGFILE="/var/log/setup.log"
LOCAL_USER="${SUDO_USER:-$(whoami)}"  # Get the user who ran the script with sudo or the current user if not run with sudo

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# Check if Samba shares are already set up
samba_shares_exist() {
    for SHARE in "${SHARES[@]}"; do
        if grep -q "//$SERVER/$SHARE" /etc/fstab; then
            return 0  # Shares exist
        fi
    done
    return 1  # Shares do not exist
}

# Get Samba user credentials
get_samba_credentials() {
    read -p "Enter Samba username: " SMB_USER
    read -s -p "Enter Samba password: " SMB_PASSWORD
    echo ""
}

# Change hostname if needed
change_hostname() {
    read -p "Do you want to change the current hostname? (yes/no): " hostname_choice
    if [[ "$hostname_choice" == "yes" ]]; then
        read -p "Enter the new hostname: " NEW_HOSTNAME
        log "Changing hostname to $NEW_HOSTNAME..."
        CURRENT_HOSTNAME=$(hostname)
        echo "$NEW_HOSTNAME" > /etc/hostname
        sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
        hostnamectl set-hostname "$NEW_HOSTNAME" || { log "Failed to set hostname"; exit 1; }
        log "Hostname changed to $NEW_HOSTNAME."
    else
        log "Hostname change skipped."
    fi
}

# Install necessary packages
install_packages() {
    log "Installing necessary packages..."
    apt-get update -y || { log "Failed to update package list"; exit 1; }
    apt-get install -y net-tools gcc make perl samba cifs-utils winbind curl git bzip2 tar linux-virtual linux-cloud-tools-virtual linux-tools-virtual || { log "Package installation failed"; exit 1; }
    apt-get autoremove -y && apt-get autoclean -y || { log "Autoremove failed"; exit 1; }
    log "Package installation complete."
}

# Configure Samba and mount shares
configure_samba() {
    log "Configuring Samba shares..."
    
    # If shares already exist, skip credentials input
    if samba_shares_exist; then
        log "Samba shares are already configured."
        return
    fi

    # Get Samba credentials
    get_samba_credentials
    
    # Add Samba user if not already existing
    if ! pdbedit -L | grep -q "$SMB_USER"; then
        (echo "$SMB_PASSWORD"; echo "$SMB_PASSWORD") | smbpasswd -s -a "$SMB_USER" || { log "Failed to add Samba user"; exit 1; }
        log "Samba user $SMB_USER added."
    else
        log "Samba user $SMB_USER already exists."
    fi

    # Mount each share
    CREDENTIALS_FILE="/etc/samba/credentials_$LOCAL_USER"
    echo "username=$SMB_USER" > "$CREDENTIALS_FILE"
    echo "password=$SMB_PASSWORD" >> "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"

    for SHARE in "${SHARES[@]}"; do
        MOUNT_POINT="/media/$SHARE"
        mkdir -p "$MOUNT_POINT"

        if ! grep -q "//$SERVER/$SHARE" /etc/fstab; then
            echo "//$SERVER/$SHARE $MOUNT_POINT cifs credentials=$CREDENTIALS_FILE,iocharset=utf8,file_mode=0777,dir_mode=0777 0 0" >> /etc/fstab
            log "Added entry for $SHARE to /etc/fstab."
            mount "$MOUNT_POINT" || { log "Failed to mount $SHARE"; exit 1; }
        else
            log "Mount entry for $SHARE already exists in /etc/fstab."
        fi
    done

    log "All Samba shares mounted successfully."
}

# Main Execution
log "Starting setup script..."
change_hostname
install_packages
configure_samba

log "Setup script completed."
