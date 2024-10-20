#!/bin/bash

# Configuration
SERVER="10.1.1.3"  # Change this to your file server's IP address
SHARES=("d" "e" "f" "v")  # Add more shares if needed
LOGFILE="/var/log/setup.log"
LOCAL_USER="${SUDO_USER:-$(whoami)}"  # Get the user who ran the script with sudo or the current user if not run with sudo

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# Check if Samba user exists
samba_user_exists() {
    pdbedit -L | grep -q "$1"
}

# Collect Samba information if not already configured
collect_samba_info() {
    read -p "Enter Samba username: " SMB_USER
    read -s -p "Enter Samba password: " SMB_PASSWORD
    echo ""
}

# Check if Samba shares are configured
check_samba_configured() {
    for SHARE in "${SHARES[@]}"; do
        if grep -q "//$SERVER/$SHARE" /etc/fstab; then
            log "Samba share for $SHARE is already configured."
            return 0
        fi
    done
    return 1
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
        log "Hostname change skipped."
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
    
    if ! samba_user_exists "$LOCAL_USER"; then
        collect_samba_info
        cat <<EOF >> /etc/samba/smb.conf
[$SMB_USER]
    path = /home/$LOCAL_USER
    read only = no
    browsable = yes
EOF
        log "Samba configuration added for $SMB_USER."
        (echo "$SMB_PASSWORD"; echo "$SMB_PASSWORD") | smbpasswd -s -a "$SMB_USER" || { log "Failed to set Samba password"; exit 1; }
    else
        log "Samba configuration for $LOCAL_USER already exists."
    fi

    systemctl restart smbd || { log "Failed to restart Samba"; exit 1; }
    ufw allow samba || { log "Failed to configure firewall for Samba"; exit 1; }
    log "Samba configured successfully."

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
        log "Configuring DNS settings for Pi-hole..."
        {
            echo "DNS=10.1.1.1"
            echo "Domains=lan"
            echo "Cache=no"
            echo "DNSStubListener=no"
        } >> /etc/systemd/resolved.conf

        systemctl restart systemd-resolved || { log "Failed to restart systemd-resolved"; exit 1; }
        log "DNS settings configured for Pi-hole."
    else
        log "Skipping Pi-hole DNS configuration."
    fi
}

# Create or update the update script
create_update_script() {
    log "Creating or updating the update script for $LOCAL_USER..."
    
    UPDATE_SCRIPT="/home/$LOCAL_USER/update"
    
    UPDATE_CONTENT=$(cat <<EOF
#!/bin/bash
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get autoremove -y && sudo apt-get autoclean -y
sudo journalctl --vacuum-time=3d
EOF
)

    # Check if the update script already exists and if the content is different
    if [ -f "$UPDATE_SCRIPT" ]; then
        if [ "$UPDATE_CONTENT" != "$(cat $UPDATE_SCRIPT)" ]; then
            echo "$UPDATE_CONTENT" > "$UPDATE_SCRIPT"
            chmod +x "$UPDATE_SCRIPT"
            log "Update script updated at $UPDATE_SCRIPT."
        else
            log "Update script is already up to date."
        fi
    else
        echo "$UPDATE_CONTENT" > "$UPDATE_SCRIPT"
        chmod +x "$UPDATE_SCRIPT"
        log "Update script created at $UPDATE_SCRIPT."
    fi
}

# Set up Bash aliases
configure_bash_aliases() {
    log "Setting up Bash aliases for $LOCAL_USER..."
    BASH_ALIASES_FILE="/home/$LOCAL_USER/.bash_aliases"

    {
        echo "alias dock='cd ~/.docker/compose'"
        echo "alias dc='cd ~/.config/appdata/'"
        echo "alias dr='docker compose -f ~/.docker/compose/docker-compose.yml restart'"
        echo "alias dstart='docker compose -f ~/.docker/compose/docker-compose.yml start'"
        echo "alias dstop='docker compose -f ~/.docker/compose/docker-compose.yml stop'"
        echo "alias lsl='ls -la'"
    } >> "$BASH_ALIASES_FILE"

    # Check and add source command in .bashrc
    if ! grep -q "if \[ -f ~/.bash_aliases \]" "/home/$LOCAL_USER/.bashrc"; then
        echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" >> "/home/$LOCAL_USER/.bashrc"
        log "Added .bash_aliases source command to /home/$LOCAL_USER/.bashrc."
    fi

    chown "$LOCAL_USER:$LOCAL_USER" "$BASH_ALIASES_FILE"
    chmod 644 "$BASH_ALIASES_FILE"

    log "Bash aliases setup completed for $LOCAL_USER."
}

# Install Docker if requested
install_docker() {
    read -p "Do you want to install Docker? (yes/no): " docker_choice
    if [[ "$docker_choice" == "yes" ]]; then
        log "Downloading and running the Docker installation script..."
        curl -fsSL https://github.com/improvmasta/homelab/raw/refs/heads/main/installdocker | bash || { log "Docker installation failed"; exit 1; }
        log "Docker installation completed successfully."
    else
        log "Docker installation skipped."
    fi
}

# Main Execution
set_hostname
install_packages

if check_samba_configured; then
    log "Samba shares are already configured."
else
    configure_samba
fi

configure_dns
create_update_script
configure_bash_aliases
install_docker  # Added Docker installation call

log "Setup script completed."
echo "To load the new configurations, please run:"
echo "source /home/$LOCAL_USER/.bashrc"
