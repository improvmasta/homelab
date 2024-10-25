#!/bin/bash

# Configuration
SERVER="10.1.1.3"  # Set the file server address
SHARES=("d" "e" "f" "v")  # Add more shares if needed
LOGFILE="/var/log/setup.log"
LOCAL_USER="${SUDO_USER:-$(whoami)}"  # Get the user who ran the script with sudo or the current user if not run with sudo

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOGFILE"
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

# Set the new hostname
set_hostname() {
    read -p "Do you want to change the hostname? (y/n): " change_hostname
    if [[ "$change_hostname" =~ ^[yY]$ ]]; then
        read -p "Enter the desired hostname for this server: " NEW_HOSTNAME
        log "Setting hostname to $NEW_HOSTNAME..."
        CURRENT_HOSTNAME=$(hostname)
        echo "$NEW_HOSTNAME" | sudo tee /etc/hostname
        sudo sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
        sudo hostnamectl set-hostname "$NEW_HOSTNAME" || { log "Failed to set hostname"; exit 1; }
        log "Hostname has been changed to $NEW_HOSTNAME."
    else
        log "Hostname change skipped."
    fi
}

# Install necessary packages
install_packages() {
    log "Updating and installing necessary packages..."
    sudo apt-get update -y && sudo apt-get upgrade -y || { log "Failed to update packages"; exit 1; }
    sudo apt-get install -y net-tools gcc make perl samba cifs-utils winbind curl git bzip2 tar || { log "Package installation failed"; exit 1; }
    sudo apt-get autoremove -y && sudo apt-get autoclean -y || { log "Autoremove failed"; exit 1; }
    log "Package installation complete."
}

# Install and configure Hyper-V guest additions
install_hyperv_guest_additions() {
    log "Installing and configuring Hyper-V guest additions..."

    # Install necessary packages for Hyper-V guest tools
    sudo apt-get install -y linux-virtual linux-cloud-tools-virtual linux-tools-virtual || { log "Failed to install Hyper-V guest additions packages"; exit 1; }

    # Function to add a module if it doesn't already exist
    add_module_if_missing() {
        MODULE=$1
        if ! grep -q "^$MODULE" /etc/initramfs-tools/modules; then
            echo "$MODULE" | sudo tee -a /etc/initramfs-tools/modules
            log "Added $MODULE to /etc/initramfs-tools/modules."
        else
            log "$MODULE is already present in /etc/initramfs-tools/modules."
        fi
    }

    # Add Hyper-V modules if not already configured
    log "Checking and adding Hyper-V modules to initramfs if needed..."
    add_module_if_missing "hv_vmbus"
    add_module_if_missing "hv_storvsc"
    add_module_if_missing "hv_blkvsc"
    add_module_if_missing "hv_netvsc"

    # Regenerate initramfs to include the new modules
    log "Regenerating initramfs..."
    sudo update-initramfs -u || { log "Failed to regenerate initramfs"; exit 1; }

    log "Hyper-V guest additions installed and configured."
}

# Install Docker
install_docker() {
    read -p "Do you want to install Docker? (y/n): " docker_install
    if [[ "$docker_install" =~ ^[yY]$ ]]; then
        log "Installing Docker..."
        curl -fsSL https://github.com/improvmasta/homelab/raw/refs/heads/main/installdocker | sudo bash || { log "Failed to install Docker"; exit 1; }
		sudo usermod -aG docker $LOCAL_USER
        log "Docker installation completed."
    else
        log "Skipping Docker installation."
    fi
}

# Configure Samba and mount network shares
configure_samba() {
    log "Configuring Samba for $LOCAL_USER..."

    if ! samba_user_exists "$LOCAL_USER"; then
        collect_samba_info

        echo "[$SMB_USER]
    path = /home/$LOCAL_USER
    read only = no
    browsable = yes" | sudo tee -a /etc/samba/smb.conf

        log "Samba configuration added for $SMB_USER."
        (echo "$SMB_PASSWORD"; echo "$SMB_PASSWORD") | sudo smbpasswd -s -a "$SMB_USER" || { log "Failed to set Samba password"; exit 1; }
    else
        log "Samba configuration for $LOCAL_USER already exists."
    fi

    sudo systemctl restart smbd || { log "Failed to restart Samba"; exit 1; }
    sudo ufw allow samba || { log "Failed to configure firewall for Samba"; exit 1; }
    log "Samba configured successfully."

    log "Mounting network shares..."

    CREDENTIALS_FILE="/etc/samba/credentials_$LOCAL_USER"
    echo "username=$SMB_USER" | sudo tee "$CREDENTIALS_FILE"
    echo "password=$SMB_PASSWORD" | sudo tee -a "$CREDENTIALS_FILE"
    sudo chmod 600 "$CREDENTIALS_FILE"

    for SHARE in "${SHARES[@]}"; do
        MOUNT_POINT="/media/$SHARE"
        sudo mkdir -p "$MOUNT_POINT"

        if ! grep -q "//$SERVER/$SHARE" /etc/fstab; then
            echo "//$SERVER/$SHARE $MOUNT_POINT cifs credentials=$CREDENTIALS_FILE,iocharset=utf8,file_mode=0777,dir_mode=0777 0 0" | sudo tee -a /etc/fstab
            log "Added entry for $SHARE to /etc/fstab."
            sudo mount "$MOUNT_POINT" || { log "Failed to mount $SHARE"; exit 1; }
        else
            log "Mount entry for $SHARE already exists in /etc/fstab."
        fi
    done

    log "Network shares mounted successfully."
}

# Configure DNS if setting up as Pi-hole
configure_dns() {
    read -p "Is this system going to be configured as a Pi-hole? (y/n): " pihole_choice

    if [[ "$pihole_choice" =~ ^[yY]$ ]]; then
        echo "DNS=10.1.1.1" | sudo tee -a /etc/systemd/resolved.conf
        echo "Domains=lan" | sudo tee -a /etc/systemd/resolved.conf
        echo "Cache=no" | sudo tee -a /etc/systemd/resolved.conf
        echo "DNSStubListener=no" | sudo tee -a /etc/systemd/resolved.conf

        sudo systemctl restart systemd-resolved || { log "Failed to restart systemd-resolved"; exit 1; }

        log "DNS settings configured for Pi-hole."
    else
        log "Skipping Pi-hole DNS configuration."
    fi
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
EOF
)

    if [ ! -f "$UPDATE_SCRIPT" ] || [ "$NEW_CONTENT" != "$(cat $UPDATE_SCRIPT)" ]; then
        echo "$NEW_CONTENT" | sudo tee "$UPDATE_SCRIPT" > /dev/null
        sudo chmod +x "$UPDATE_SCRIPT"
        log "Update script created or updated successfully."
    else
        log "Update script is already up to date."
    fi
}

# Set up Bash aliases
configure_bash_aliases() {
    log "Setting up Bash aliases for $LOCAL_USER..."
    BASH_ALIASES_FILE="/home/$LOCAL_USER/.bash_aliases"

    {
        echo "alias ..='cd ..'"
		echo "alias ...='cd ../..'"
		echo "alias dock='cd ~/.docker/compose'"
        echo "alias dc='cd ~/.config/appdata/'"
		echo "alias dup='docker compose -f ~/.docker/compose/docker-compose.yml up -d'"
		echo "alias ddown='docker compose -f ~/.docker/compose/docker-compose.yml down'"
        echo "alias dr='docker compose -f ~/.docker/compose/docker-compose.yml restart'"
        echo "alias dstart='docker compose -f ~/.docker/compose/docker-compose.yml start'"
        echo "alias dstop='docker compose -f ~/.docker/compose/docker-compose.yml stop'"
        echo "alias ls='ls -lah'"
    } | sudo tee "$BASH_ALIASES_FILE" > /dev/null

    # Check and add source command in .bashrc
    if ! sudo grep -q "if [ -f ~/.bash_aliases ]" "/home/$LOCAL_USER/.bashrc"; then
        echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" | sudo tee -a "/home/$LOCAL_USER/.bashrc" > /dev/null
        log "Added .bash_aliases source command to /home/$LOCAL_USER/.bashrc."
    fi

    sudo chown "$LOCAL_USER:$LOCAL_USER" "$BASH_ALIASES_FILE"
    sudo chmod 644 "$BASH_ALIASES_FILE"

    log "Bash aliases setup completed for $LOCAL_USER."
}

# Main Execution
set_hostname
install_packages
install_hyperv_guest_additions
install_docker
configure_samba
configure_dns
create_update_script
configure_bash_aliases

log "Setup script completed."
echo "To load the new aliases, please run:"
echo "source /home/$LOCAL_USER/.bashrc"
