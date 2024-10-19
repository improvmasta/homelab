#!/bin/bash

# Configuration
SERVER="10.1.1.3"
SHARES=("d" "e" "f" "v")  # Add more shares if needed
LOGFILE="/var/log/setup.log"

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

    # Check if Samba share configuration already exists
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

    # Store credentials securely in /etc/samba/credentials_<username>
    CREDENTIALS_FILE="/etc/samba/credentials_$LOCAL_USER"
    echo "username=$SMB_USER" > $CREDENTIALS_FILE
    echo "password=$SMB_PASSWORD" >> $CREDENTIALS_FILE
    chmod 600 $CREDENTIALS_FILE  # Secure the file

    for SHARE in "${SHARES[@]}"; do
        MOUNT_POINT="/media/$SHARE"
        mkdir -p "$MOUNT_POINT"

        # Check if the mount point entry already exists in /etc/fstab
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

# Create or update the update script
create_update_script() {
    log "Creating or updating update script for $LOCAL_USER..."
    UPDATE_SCRIPT="/home/$LOCAL_USER/update"

    # Check if the update script already exists
    if [ -f "$UPDATE_SCRIPT" ]; then
        # Compare the existing script with the new content
        NEW_CONTENT=$(cat <<EOF
#!/bin/bash
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get autoremove -y && sudo apt-get autoclean -y
sudo journalctl --vacuum-time=3d
cd ~/.config/appdata/plex/Library/'Application Support'/'Plex Media Server'/Logs
ls | grep -v '\\.log\$' | xargs rm
EOF
)
        if [ "$NEW_CONTENT" != "$(cat $UPDATE_SCRIPT)" ]; then
            echo "$NEW_CONTENT" > $UPDATE_SCRIPT
            log "Update script updated successfully."
        else
            log "Update script is already up to date."
        fi
    else
        echo "#!/bin/bash" > $UPDATE_SCRIPT
        echo "sudo apt-get update -y && sudo apt-get upgrade -y" >> $UPDATE_SCRIPT
        echo "sudo apt-get autoremove -y && sudo apt-get autoclean -y" >> $UPDATE_SCRIPT
        echo "sudo journalctl --vacuum-time=3d" >> $UPDATE_SCRIPT
        echo "cd ~/.config/appdata/plex/Library/'Application Support'/'Plex Media Server'/Logs" >> $UPDATE_SCRIPT
        echo "ls | grep -v '\\.log\$' | xargs rm" >> $UPDATE_SCRIPT
        chmod +x $UPDATE_SCRIPT
        log "Update script created successfully."
    fi
}

# Create or update the DockSTARTer install script
create_dockstarter_script() {
    log "Creating or updating DockSTARTer install script for $LOCAL_USER..."
    DOCKSTARTER_SCRIPT="/home/$LOCAL_USER/installds"

    # Check if the DockSTARTer script already exists
    if [ -f "$DOCKSTARTER_SCRIPT" ]; then
        # Compare the existing script with the new content
        NEW_CONTENT=$(cat <<EOF
#!/bin/bash
git clone https://github.com/GhostWriters/DockSTARTer "/home/$LOCAL_USER/.docker"
bash /home/$LOCAL_USER/.docker/main.sh -vi
EOF
)
        if [ "$NEW_CONTENT" != "$(cat $DOCKSTARTER_SCRIPT)" ]; then
            echo "$NEW_CONTENT" > $DOCKSTARTER_SCRIPT
            log "DockSTARTer install script updated successfully."
        else
            log "DockSTARTer install script is already up to date."
        fi
    else
        echo "#!/bin/bash" > $DOCKSTARTER_SCRIPT
        echo "git clone https://github.com/GhostWriters/DockSTARTer \"/home/$LOCAL_USER/.docker\"" >> $DOCKSTARTER_SCRIPT
        echo "bash /home/$LOCAL_USER/.docker/main.sh -vi" >> $DOCKSTARTER_SCRIPT
        chmod +x $DOCKSTARTER_SCRIPT
        log "DockSTARTer install script created successfully."
    fi
}

# Run everything
set_hostname
install_packages
configure_samba
create_update_script
create_dockstarter_script

log "Setup completed. Run './installds' to install DockSTARTer."
