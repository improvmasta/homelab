#!/bin/bash

# Configuration
SERVER="10.1.1.3"
SHARES=("d" "e" "f" "v")  # Add more shares if needed
LOGFILE="/var/log/setup.log"
LOCAL_USER="${SUDO_USER:-$(whoami)}"  # Get the user who ran the script with sudo or the current user if not run with sudo

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# Check if Samba user exists
samba_user_exists() {
    pdbedit -L | grep -q "$1"
}

# Check if Samba shares are configured
samba_shares_configured() {
    for SHARE in "${SHARES[@]}"; do
        if ! grep -q "[$SHARE]" /etc/samba/smb.conf; then
            return 1
        fi
    done
    return 0
}

# Collect Samba information if not already configured
collect_samba_info() {
    read -p "Enter Samba username: " SMB_USER
    read -s -p "Enter Samba password: " SMB_PASSWORD
    echo ""
}

# Set the new hostname
set_hostname() {
    read -p "Do you want to change the current hostname? (yes/no): " change_hostname
    if [[ "$change_hostname" == "yes" ]]; then
        read -p "Enter the desired hostname for this server: " NEW_HOSTNAME
        log "Setting hostname to $NEW_HOSTNAME..."
        CURRENT_HOSTNAME=$(hostname)
        echo "$NEW_HOSTNAME" > /etc/hostname
        sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
        hostnamectl set-hostname "$NEW_HOSTNAME" || { log "Failed to set hostname"; exit 1; }
        log "Hostname has been changed to $NEW_HOSTNAME."
    else
        log "Skipping hostname change."
    fi
}

# Install necessary packages
install_packages() {
    log "Updating and installing necessary packages..."
    apt-get update -y && apt-get upgrade -y || { log "Failed to update packages"; exit 1; }
    apt-get install -y net-tools gcc make perl samba cifs-utils winbind curl git bzip2 tar linux-virtual linux-cloud-tools-virtual linux-tools-virtual || { log "Package installation failed"; exit 1; }
    apt-get autoremove -y && apt-get autoclean -y || { log "Autoremove failed"; exit 1; }
    log "Package installation complete."
}

# Configure Samba and mount network shares
configure_samba() {
    log "Configuring Samba for $LOCAL_USER..."

    if ! samba_shares_configured; then
        collect_samba_info

        # Create Samba share for the user's home directory if it doesn't exist
        if ! samba_user_exists "$LOCAL_USER"; then
            log "Creating Samba share for home directory..."
            cat <<EOF >> /etc/samba/smb.conf
[$LOCAL_USER]
    path = /home/$LOCAL_USER
    read only = no
    browsable = yes
EOF
            log "Samba configuration added for $LOCAL_USER."

            (echo "$SMB_PASSWORD"; echo "$SMB_PASSWORD") | smbpasswd -s -a "$SMB_USER" || { log "Failed to set Samba password"; exit 1; }
        else
            log "Samba configuration for $LOCAL_USER already exists."
        fi

        # Configure additional shares
        for SHARE in "${SHARES[@]}"; do
            if ! grep -q "[$SHARE]" /etc/samba/smb.conf; then
                cat <<EOF >> /etc/samba/smb.conf
[$SHARE]
    path = /media/$SHARE
    read only = no
    browsable = yes
EOF
                log "Samba share configured for $SHARE."
            fi
        done

        systemctl restart smbd || { log "Failed to restart Samba"; exit 1; }
        ufw allow samba || { log "Failed to configure firewall for Samba"; exit 1; }
        log "Samba configured successfully."
    else
        log "Samba shares are already configured."
    fi

    log "Mounting network shares..."

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

    log "Network shares mounted successfully."
}

# Configure DNS if setting up as Pi-hole
configure_dns() {
    read -p "Is this system going to be configured as a Pi-hole? (yes/no): " pihole_choice

    if [[ "$pihole_choice" == "yes" ]]; then
        log "Configuring DNS settings..."
        {
            echo "DNS=10.1.1.1"
            echo "Domains=lan"
            echo "Cache=no"
            echo "DNSStubListener=no"
        } >> /etc/systemd/resolved.conf

        systemctl restart systemd-resolved || { log "Failed to restart systemd-resolved"; exit 1; }
        log "DNS settings configured."
    else
        log "Skipping Pi-hole DNS configuration."
    fi
}

# Create or update the update script
create_update_script() {
    log "Creating or updating the update script for $LOCAL_USER..."
    UPDATE_SCRIPT="/home/$LOCAL_USER/update"

    NEW_CONTENT=$(cat <<EOF
#!/bin/bash
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get autoremove -y && sudo apt-get autoclean -y
sudo journalctl --vacuum-time=3d
EOF
)

    # Create the user's home directory if it doesn't exist
    if [ ! -d "/home/$LOCAL_USER" ]; then
        mkdir -p "/home/$LOCAL_USER"
        log "Created home directory for $LOCAL_USER."
    fi

    # Create or update the update script
    if [ ! -f "$UPDATE_SCRIPT" ] || [ "$NEW_CONTENT" != "$(cat $UPDATE_SCRIPT)" ]; then
        echo "$NEW_CONTENT" > "$UPDATE_SCRIPT"
        chmod +x "$UPDATE_SCRIPT"
        log "Update script created or updated successfully at $UPDATE_SCRIPT."
    else
        log "Update script is already up to date."
    fi
}

# Set up Bash aliases
configure_bash_aliases() {
    log "Setting up Bash aliases for $LOCAL_USER..."
    BASH_ALIASES_FILE="/home/$LOCAL_USER/.bash_aliases"

    # Create the user's home directory if it doesn't exist
    if [ ! -d "/home/$LOCAL_USER" ]; then
        mkdir -p "/home/$LOCAL_USER"
        log "Created home directory for $LOCAL_USER."
    fi

    {
        echo "alias dock='cd ~/.docker/compose'"
        echo "alias dc='cd ~/.config/appdata/'"
        echo "alias dr='docker compose -f ~/.docker/compose/docker-compose.yml restart'"
        echo "alias dstart='docker compose -f ~/.docker/compose/docker-compose.yml start'"
        echo "alias dstop='docker compose -f ~/.docker/compose/docker-compose.yml stop'"
        echo "alias lsl='ls -la'"
    } > "$BASH_ALIASES_FILE"

    # Check and add source command in .bashrc
    BASHRC_FILE="/home/$LOCAL_USER/.bashrc"
    if [ ! -f "$BASHRC_FILE" ]; then
        touch "$BASHRC_FILE"
        log "Created .bashrc for $LOCAL_USER."
    fi

    if ! grep -q "if [ -f ~/.bash_aliases ]" "$BASHRC_FILE"; then
        echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" >> "$BASHRC_FILE"
        log "Added .bash_aliases source command to $BASHRC_FILE."
    fi

    chown "$LOCAL_USER:$LOCAL_USER" "$BASH_ALIASES_FILE"
    chmod 644 "$BASH_ALIASES_FILE"

    log "Bash aliases setup completed for $LOCAL_USER."
}

# Ask if the user wants to install Docker
install_docker() {
    read -p "Do you want to install Docker? (yes/no): " docker_choice
    if [[ "$docker_choice" == "yes" ]]; then
        log "Downloading and running the Docker installation script..."
        curl -fsSL https://github.com/improvmasta/homelab/raw/refs/heads/main/installdocker | bash
        log "Docker installation completed."
    else
        log "Skipping Docker installation."
    fi
}

# Main Execution
set_hostname
install_packages
configure_samba
configure_dns
install_docker
configure_bash_aliases
create_update_script

log "Setup script completed successfully."
