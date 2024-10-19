#!/bin/bash

# Configuration
SERVER="10.1.1.3"
SHARES=("d" "e" "f" "v")  # Add more shares if needed

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Collect user input
read -p "Enter your local username: " LOCAL_USER
read -p "Enter Samba username: " SMB_USER
read -s -p "Enter Samba password: " SMB_PASSWORD
echo ""

# Update and install necessary packages
apt-get update -y && apt-get upgrade -y
apt-get install -y net-tools gcc make perl samba cifs-utils winbind curl git bzip2 tar linux-virtual linux-cloud-tools-virtual linux-tools-virtual
apt-get autoremove -y && apt-get autoclean -y
journalctl --vacuum-time=3d

# Setup Hyper-V Integration
cat <<EOF >> /etc/initramfs-tools/modules
hv_vmbus
hv_storvsc
hvblkvsc
hv_netvsc
EOF
update-initramfs -u

# Configure Samba share
cat <<EOF >> /etc/samba/smb.conf
[$LOCAL_USER]
    path = /home/$LOCAL_USER
    read only = no
    browsable = yes
EOF
systemctl restart smbd
ufw allow samba
(echo "$SMB_PASSWORD"; echo "$SMB_PASSWORD") | smbpasswd -s -a "$LOCAL_USER"

# Mount network shares
for SHARE in "${SHARES[@]}"; do
    MOUNT_POINT="/media/$SHARE"
    mkdir -p "$MOUNT_POINT"
    echo "//$SERVER/$SHARE $MOUNT_POINT cifs nobrl,username=$SMB_USER,password=$SMB_PASSWORD,iocharset=utf8,file_mode=0777,dir_mode=0777 0 0" >> /etc/fstab
done
mount -a

# Setup Bash aliases
cat <<EOF >> /home/$LOCAL_USER/.bashrc
alias dock='cd ~/.docker/compose'
alias dc='cd ~/.config/appdata/'
alias dr='docker compose -f ~/.docker/compose/docker-compose.yml restart'
alias dstart='docker compose -f ~/.docker/compose/docker-compose.yml start'
alias dstop='docker compose -f ~/.docker/compose/docker-compose.yml stop'
alias lsl='ls -la'
EOF
source /home/$LOCAL_USER/.bashrc

# Create update script
cat <<EOF > /home/$LOCAL_USER/update
#!/bin/bash
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get autoremove -y && sudo apt-get autoclean -y
sudo journalctl --vacuum-time=3d
cd ~/.config/appdata/plex/Library/'Application Support'/'Plex Media Server'/Logs
ls | grep -v '\\.log\$' | xargs rm
EOF
chmod +x /home/$LOCAL_USER/update

# Create DockSTARTer install script
cat <<EOF > /home/$LOCAL_USER/installds
#!/bin/bash
git clone https://github.com/GhostWriters/DockSTARTer "/home/$LOCAL_USER/.docker"
bash /home/$LOCAL_USER/.docker/main.sh -vi
EOF
chmod +x /home/$LOCAL_USER/installds

echo "Setup completed. Run './installds' to install DockSTARTer."
