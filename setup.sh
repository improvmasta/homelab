#!/bin/bash

# Configuration
SERVER="10.1.1.3"
SHARES=("d" "e" "f" "v")  # Add more shares if needed
LOGFILE="/var/log/setup.log"
BASH_ALIASES_FILE="/home/$LOCAL_USER/.bash_aliases"

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOGFILE
}

# Collect user input
read -p "Enter your local username: " LOCAL_USER
read -p "Enter Samba username: " SMB_USER
read -s -p "Enter Samba password: " SMB_PASSWORD
echo ""
read -p "Enter the desired hostname for this server: " NEW_HOSTNAME

# Set the new hostname
set_hostname() {
    log "Setting hostname to $NEW_HOSTNAME..."
    CURRENT_HOSTNAME=$(hostname)
    echo "$NEW_HOSTNAME" > /etc/hostname
    sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
    hostnamectl set-hostname "$NEW_HOSTNAME" || { log "Failed to set hostname"; exit 1; }
    log "Hostname has been changed to $NEW_HOSTNAME."
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

    if ! grep -q "\[$LOCAL_USER\]" /etc/samba/smb.conf; then
        cat <<EOF >> /etc/samba/smb.conf
[$LOCAL_USER]
    path = /home/$LOCAL_USER
    read only = no
    browsable = yes
EOF
        log "Samba configuration added for $LOCAL_USER."
    else
        log "Samba configuration for $LOCAL_USER already exists."
    fi

    systemctl restart smbd || { log "Failed to restart Samba"; exit 1; }
    ufw allow samba || { log "Failed to configure firewall for Samba"; exit 1; }
    (echo "$SMB_PASSWORD"; echo "$SMB_PASSWORD") | smbpasswd -s -a "$LOCAL_USER" || { log "Failed to set Samba password"; exit 1; }
    log "Samba configured successfully."

    log "Mounting network shares..."

    CREDENTIALS_FILE="/etc/samba/credentials_$LOCAL_USER"
    echo "username=$SMB_USER" > $CREDENTIALS_FILE
    echo "password=$SMB_PASSWORD" >> $CREDENTIALS_FILE
    chmod 600 $CREDENTIALS_FILE

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
        read -p "Enter the static IP of the DNS server (e.g., 10.1.1.1): " static_ip

        if grep -q "DNS=$static_ip" /etc/systemd/resolved.conf; then
            log "DNS settings are already configured with IP: $static_ip"
        else
            log "Configuring DNS settings..."
            echo "DNS=$static_ip" >> /etc/systemd/resolved.conf
            echo "Domains=lan" >> /etc/systemd/resolved.conf
            echo "Cache=no" >> /etc/systemd/resolved.conf
            echo "DNSStubListener=no" >> /etc/systemd/resolved.conf

            systemctl restart systemd-resolved || { log "Failed to restart systemd-resolved"; exit 1; }

            log "DNS settings configured with static IP: $static_ip"
        fi
    else
        log "Skipping Pi-hole DNS configuration."
    fi
}

# Set up Bash aliases
configure_bash_aliases() {
    log "Setting up Bash aliases for $LOCAL_USER..."

    if [ -f "$BASH_ALIASES_FILE" ]; then
        log "Bash alias file already exists. Checking for updates."
    else
        touch "$BASH_ALIASES_FILE"
        log "Created Bash alias file."
    fi

    cat <<EOF >> "$BASH_ALIASES_FILE"
alias dock='cd ~/.docker/compose'
alias dc='cd ~/.config/appdata/'
alias dr='docker compose -f ~/.docker/compose/docker-compose.yml restart'
alias dstart='docker compose -f ~/.docker/compose/docker-compose.yml start'
alias dstop='docker compose -f ~/.docker/compose/docker-compose.yml stop'
alias lsl='ls -la'
EOF

    if ! grep -q "if \[ -f ~/.bash_aliases \]" "/home/$LOCAL_USER/.bashrc"; then
        echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" >> "/home/$LOCAL_USER/.bashrc"
    fi

    log "Bash aliases set up successfully."
}

# Create or update the update script
create_update_script() {
    log "Creating or updating update script for $LOCAL_USER..."
    UPDATE_SCRIPT="/home/$LOCAL_USER/update"

    NEW_CONTENT=$(cat <<EOF
#!/bin/bash
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get autoremove -y && sudo apt-get autoclean -y
sudo journalctl --vacuum-time=3d
cd ~/.config/appdata/plex/Library/'Application Support'/'Plex Media Server'/Logs
ls | grep -v '\\.log\$' | xargs rm
EOF
)

    if [ ! -f "$UPDATE_SCRIPT" ] || [ "$NEW_CONTENT" != "$(cat $UPDATE_SCRIPT)" ]; then
        echo "$NEW_CONTENT" > $UPDATE_SCRIPT
        chmod +x $UPDATE_SCRIPT
        log "Update script created or updated successfully."
    else
        log "Update script is already up to date."
    fi
}

# Create or update the DockSTARTer install script
create_dockstarter_script() {
    log "Creating or updating DockSTARTer install script for $LOCAL_USER..."
    DOCKSTARTER_SCRIPT="/home/$LOCAL_USER/installds"

    NEW_CONTENT=$(cat <<EOF
#!/bin/bash
git clone https://github.com/GhostWriters/DockSTARTer "/home/$LOCAL_USER/.docker"
bash /home/$LOCAL_USER/.docker/main.sh -vi
EOF
)

    if [ ! -f "$DOCKSTARTER_SCRIPT" ] || [ "$NEW_CONTENT" != "$(cat $DOCKSTARTER_SCRIPT)" ]; then
        echo "$NEW_CONTENT" > $DOCKSTARTER_SCRIPT
        chmod +x $DOCKSTARTER_SCRIPT
        log "DockSTARTer install script created or updated successfully."
    else
        log "DockSTARTer install script is already up to date."
    fi
}

# Main Execution
set_hostname
install_packages
configure_samba
configure_dns
configure_bash_aliases
create_update_script
create_dockstarter_script

log "Setup script completed."
