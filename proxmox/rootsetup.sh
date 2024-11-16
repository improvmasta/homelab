#!/bin/bash

# Log file path
LOG_FILE="/var/log/proxmox_setup.log"

# SSH key to be added
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOeNMeemwPLteWku0Fz/u/LsbfaEPnkbRNZKVY6T9wZlAoxCbtJn1YfBhPFb87a6xYa0mdloH0rQTHVEAOqFidUKc9O2E4p7yMK6994y+8P/xriCgUzl4huyy50MR1a2Ao6M9T9XooFomestkycbHy0Dup+lDNmE8YG/kE243b0uJnHDDsNsn9K8169haugNlcBlUSY638K/u5M7Xz0YPUGCnXxTUVgfrEozyzvv8ZzOieHm2HIzRoLuCUz6cn8vEmXZW075Ae+5L/BQIiZhFCj0uaKGZ7LE3GfDt+eRLK1EWabP+i3R5+ORhLoIybK6JKoLTIyKaTsm+UWxf8rM7v"

# Function to log errors
log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$LOG_FILE"
}

# Function to install necessary packages
install_packages() {
    local packages=("ntfs-3g" "sudo")
    echo "Installing required packages: ${packages[@]}..."
    if apt-get update && apt-get install -y "${packages[@]}"; then
        echo "Packages installed successfully."
    else
        log_error "Failed to install packages: ${packages[@]}"
        exit 1
    fi
}

# Function to configure repositories
configure_repositories() {
    echo "Configuring repositories..."
    sed -i 's/^deb/deb#/' /etc/apt/sources.list.d/pve-enterprise.list
    echo "deb http://download.proxmox.com/debian/pve stretch pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
    apt-get update -y
}

# Function to update Proxmox appliance templates
update_pveam_templates() {
    echo "Updating Proxmox appliance templates..."
    pveam update
    if [ $? -eq 0 ]; then
        echo "Proxmox appliance templates updated successfully."
    else
        log_error "Failed to update Proxmox appliance templates."
        exit 1
    fi
}

# Function to create a user, install sudo, and add to sudoers
create_user_and_add_to_sudoers() {
    read -p "Enter the new non-root username: " new_user
    useradd -m -s /bin/bash "$new_user" && passwd "$new_user"
    usermod -aG sudo "$new_user"
    echo "$new_user created and added to sudoers."
    
    # Add SSH key to both root and new user's authorized_keys
    mkdir -p /root/.ssh /home/"$new_user"/.ssh
    echo "$SSH_KEY" >> /root/.ssh/authorized_keys
    echo "$SSH_KEY" >> /home/"$new_user"/.ssh/authorized_keys
    chmod 700 /root/.ssh /home/"$new_user"/.ssh
    chmod 600 /root/.ssh/authorized_keys /home/"$new_user"/.ssh/authorized_keys
    echo "SSH key added to both root and $new_user users."
}

# Function to import ZFS pool
import_zfs_pool() {
    read -p "Do you want to import a ZFS pool? (yes/no): " import_zfs
    if [[ "$import_zfs" =~ ^(yes|y)$ ]]; then
        read -p "Enter the ZFS pool name: " pool_name
        if zpool import "$pool_name"; then
            echo "ZFS pool $pool_name imported."
        else
            log_error "Failed to import ZFS pool: $pool_name"
            echo "Error: Failed to import ZFS pool $pool_name."
        fi
    fi
}

# Function to configure fstab mounts
configure_fstab_mounts() {
    local mounts=(
        'UUID="A8BADD47BADD1324" /media/d ntfs rw 0 0'
        'UUID="5E1E45AD1E457F51" /media/e ntfs rw 0 0'
        'UUID="123456781E457F51" /media/f ntfs rw 0 0'
        'UUID="a4b151c8-68b0-4a3a-abc7-b2aa1cfbbcaf" /media/vmb ext4 rw 0 0'
    )
    local directories=("/media/d" "/media/e" "/media/f" "/media/vmb")

    echo "Configuring fstab mounts..."
    for dir in "${directories[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir" && echo "Created directory: $dir"
        fi
    done

    for entry in "${mounts[@]}"; do
        grep -q "$entry" /etc/fstab || echo "$entry" >> /etc/fstab
    done

    mount -a && echo "fstab mounts configured."
}

# Function to import VM/Container and storage configurations
import_configs() {
    read -p "Do you want to provide an import folder for /pve? (yes/no): " import_folder
    if [[ "$import_folder" =~ ^(yes|y)$ ]]; then
        read -p "Enter the path to the import folder: " import_path
        if [ -d "$import_path" ]; then
            # Check and copy VM and LXC configurations
            [ -d "$import_path/qemu-server" ] && cp -r "$import_path/qemu-server"/* /etc/pve/qemu-server/
            [ -d "$import_path/lxc" ] && cp -r "$import_path/lxc"/* /etc/pve/lxc/
            [ -f "$import_path/storage.cfg" ] && cp "$import_path/storage.cfg" /etc/pve/
            echo "VM, container, and storage configurations imported from $import_path."
        else
            log_error "Invalid import folder: $import_path"
            echo "Error: Folder not found."
        fi
    fi
}

# Function to set up Bash aliases for root
setup_bash_aliases() {
    read -p "Do you want to set up bash aliases for root? (yes/no): " setup_aliases
    if [[ "$setup_aliases" =~ ^(yes|y)$ ]]; then
        echo "Setting up bash aliases for root..."

        cat > /root/.bash_aliases << EOF
# Custom bash aliases
alias ..='cd ..'
alias ...='cd ../..'
alias dock='cd ~/.docker/compose'
alias dc='cd ~/.config/appdata/'
alias dup='docker compose -f ~/.docker/compose/docker-compose.yml up -d'
alias ddown='docker compose -f ~/.docker/compose/docker-compose.yml down'
alias dr='docker compose -f ~/.docker/compose/docker-compose.yml restart'
alias dstart='docker compose -f ~/.docker/compose/docker-compose.yml start'
alias dstop='docker compose -f ~/.docker/compose/docker-compose.yml stop'
alias ls='ls --color -FlahH'
alias update='/usr/local/bin/update_cleanup.sh'
EOF
        echo "Bash aliases for root set up in /root/.bash_aliases."
    fi
}

create_update_cleanup_script() {
    read -p "Do you want to create the update and cleanup script? (yes/no): " create_script
    if [[ "$create_script" =~ ^(yes|y)$ ]]; then
        cat << 'EOF' | tee /usr/local/bin/update > /dev/null
#!/bin/bash

# Update and upgrade the system packages
apt-get update && apt-get upgrade -y

# Remove unused packages and dependencies
apt-get autoremove -y && apt-get autoclean -y

# Remove old kernel versions (keep the current and one previous)
current_kernel=$(uname -r)
previous_kernel=$(dpkg --list | grep linux-image | awk '{print $2}' | grep -v "$current_kernel" | tail -n 1)
[[ -n "$previous_kernel" ]] && apt-get remove --purge -y "$previous_kernel"

# Clean APT cache, remove orphaned packages, and old log files
apt-get clean && deborphan | xargs -r apt-get remove --purge -y
find /var/log -type f -name '*.log' -delete

# Optional: clear thumbnail and user-specific cache
rm -rf "$HOME/.cache/thumbnails/*" "$HOME/.cache/*"

echo "Update and cleanup complete!"
EOF

        chmod +x /usr/local/bin/update
        chmod 755 /usr/local/bin/update
        log "Update and cleanup script created at /usr/local/bin/update and is executable by all users."
    else
        echo "Skipping script creation."
    fi
}

# Example call to create the update and cleanup script
create_update_cleanup_script


# Function to set up a backup cron job
setup_backup_cron() {
    read -p "Do you want to set up a daily backup cron job? (yes/no): " backup_cron
    if [[ "$backup_cron" =~ ^(yes|y)$ ]]; then
        read -p "Enter the backup folder path (where backups will be stored): " backup_folder

        if [ -d "$backup_folder" ]; then
            backup_script="/usr/local/bin/proxmox_backup.sh"
            echo "Creating backup script at $backup_script..."

            cat > "$backup_script" << EOF
#!/bin/bash
# Proxmox backup script

# Variables
BACKUP_DIR="$backup_folder"
DATE=\$(date +\%Y-\%m-\%d_\%H-\%M-\%S)
VM_BACKUP_DIR="\$BACKUP_DIR/vm_backups"
LXC_BACKUP_DIR="\$BACKUP_DIR/lxc_backups"
STORAGE_BACKUP_DIR="\$BACKUP_DIR/storage_backups"

# Create backup directories if they don't exist
mkdir -p "\$VM_BACKUP_DIR" "\$LXC_BACKUP_DIR" "\$STORAGE_BACKUP_DIR"

# Backup VM files
cp -r /etc/pve/qemu-server/\* "\$VM_BACKUP_DIR/\$DATE" 2>/dev/null
cp -r /etc/pve/lxc/\* "\$LXC_BACKUP_DIR/\$DATE" 2>/dev/null
cp /etc/pve/storage.cfg "\$STORAGE_BACKUP_DIR/\$DATE" 2>/dev/null

# Keep only 7 backups, delete older ones
find "\$VM_BACKUP_DIR" -type d -mtime +6 -exec rm -rf {} \;
find "\$LXC_BACKUP_DIR" -type d -mtime +6 -exec rm -rf {} \;
find "\$STORAGE_BACKUP_DIR" -type f -mtime +6 -exec rm -f {} \;
EOF

            chmod +x "$backup_script"

            # Add cron job
            (crontab -l 2>/dev/null; echo "0 0 * * * $backup_script") | crontab -
            echo "Backup cron job set to run every day at 12:00 AM."
        else
            log_error "Invalid backup folder: $backup_folder"
            echo "Error: Folder not found."
        fi
    fi
}

# Main script execution
install_packages
configure_repositories
update_pveam_templates
create_user_and_add_to_sudoers
import_zfs_pool
configure_fstab_mounts
import_configs
setup_bash_aliases
create_update_cleanup_script
setup_backup_cron

echo "Proxmox setup complete."
