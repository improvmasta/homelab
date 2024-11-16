#!/bin/bash

# Default values
LOG_FILE="/var/log/proxmox_setup.log"
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOeNMeemwPLteWku0Fz/u/LsbfaEPnkbRNZKVY6T9wZlAoxCbtJn1YfBhPFb87a6xYa0mdloH0rQTHVEAOqFidUKc9O2E4p7yMK6994y+8P/xriCgUzl4huyy50MR1a2Ao6M9T9XooFomestkycbHy0Dup+lDNmE8YG/kE243b0uJnHDDsNsn9K8169haugNlcBlUSY638K/u5M7Xz0YPUGCnXxTUVgfrEozyzvv8ZzOieHm2HIzRoLuCUz6cn8vEmXZW075Ae+5L/BQIiZhFCj0uaKGZ7LE3GfDt+eRLK1EWabP+i3R5+ORhLoIybK6JKoLTIyKaTsm+UWxf8rM7v"
BACKUP_DIR="/media/f/backup/vm/prox"

# Function to log errors
log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$LOG_FILE"
}

# Function to change variables
change_variables() {
    echo "Current SSH key: $SSH_KEY"
    read -p "Enter a new SSH key (leave empty to keep the current one): " new_ssh_key
    if [ -n "$new_ssh_key" ]; then
        SSH_KEY="$new_ssh_key"
        echo "SSH key updated."
    fi

    echo "Current backup directory: $BACKUP_DIR"
    read -p "Enter a new backup directory (leave empty to keep the current one): " new_backup_dir
    if [ -n "$new_backup_dir" ]; then
        BACKUP_DIR="$new_backup_dir"
        echo "Backup directory updated."
    fi
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
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup

    sudo tee /etc/apt/sources.list > /dev/null << EOF
deb http://ftp.debian.org/debian bookworm main contrib
deb http://ftp.debian.org/debian bookworm-updates main contrib

# Proxmox VE pve-no-subscription repository provided by proxmox.com,
# NOT recommended for production use
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription

# security updates
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF

    sudo apt-get update -y && sudo apt-get upgrade -y
    echo "Repositories configured and system updated."
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
    echo "Creating user and adding to sudoers..."
    read -p "Enter the new non-root username: " new_user
    useradd -m -s /bin/bash "$new_user" && passwd "$new_user"
    usermod -aG sudo "$new_user"
    echo "$new_user created and added to sudoers."

    mkdir -p /root/.ssh /home/"$new_user"/.ssh
    echo "$SSH_KEY" >> /root/.ssh/authorized_keys
    echo "$SSH_KEY" >> /home/"$new_user"/.ssh/authorized_keys
    chmod 700 /root/.ssh /home/"$new_user"/.ssh
    chmod 600 /root/.ssh/authorized_keys /home/"$new_user"/.ssh/authorized_keys
    echo "SSH key added to both root and $new_user users."
}

# Function to import ZFS pool
import_zfs_pool() {
    echo "Do you want to import a ZFS pool? (yes/no): "
    read import_zfs
    if [[ "$import_zfs" =~ ^(yes|y)$ ]]; then
        echo "Enter the ZFS pool name: "
        read pool_name
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

# Function to restore from backup
restore_configs() {
    # Use the default backup directory from the beginning of the script
    default_backup_dir="$BACKUP_DIR"

    echo "Do you want to restore from the most recent backup? (yes/no): "
    read restore_choice
    if [[ "$restore_choice" =~ ^(yes|y)$ ]]; then
        echo "Do you want to use the default backup directory: $default_backup_dir? (yes/no): "
        read use_default_dir
        if [[ ! "$use_default_dir" =~ ^(yes|y)$ ]]; then
            echo "Enter the backup folder path (where the backups are stored): "
            read backup_folder
        else
            backup_folder="$default_backup_dir"
        fi

        if [ -d "$backup_folder" ]; then
            # Find the most recent backup file
            backup_file=$(ls -t "$backup_folder"/proxmox_backup_*.tar.gz | head -n 1)

            if [ -f "$backup_file" ]; then
                echo "Restoring from the most recent backup: $backup_file"

                # Ask for the hostname where the configurations should be restored
                echo "Enter the hostname for the Proxmox node: "
                read hostname

                # Ensure the specified hostname exists under the nodes directory
                if [ -d "/etc/pve/nodes/$hostname" ]; then
                    # Extract only the storage and VM/container files for the specified hostname
                    tar -xzf "$backup_file" -C /etc pve/storage.cfg /etc/pve/nodes/$hostname/lxc /etc/pve/nodes/$hostname/qemu-server

                    # Check if the restoration of the storage and VM/container files was successful
                    if [ -d "/etc/pve/nodes/$hostname/qemu-server" ] && [ -d "/etc/pve/nodes/$hostname/lxc" ] && [ -f "/etc/pve/storage.cfg" ]; then
                        echo "Restoration successful!"
                    else
                        log_error "Restoration failed. Backup may be incomplete."
                        echo "Error: Restoration failed."
                    fi
                else
                    log_error "Hostname $hostname not found in /etc/pve/nodes."
                    echo "Error: Hostname $hostname not found."
                fi
            else
                log_error "No backup files found in $backup_folder."
                echo "Error: No valid backup files found."
            fi
        else
            log_error "Invalid backup folder: $backup_folder"
            echo "Error: Folder not found."
        fi
    fi
}

# Function to set up Bash aliases for root
setup_bash_aliases() {
    echo "Do you want to set up bash aliases for root? (yes/no): "
    read setup_aliases
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

        chmod 644 /root/.bash_aliases
        echo "Bash aliases set up for root."
    fi
}

# Function to create the update and cleanup script
create_update_cleanup_script() {
    cat << 'EOF' | tee /usr/local/bin/update_cleanup.sh > /dev/null
#!/bin/bash

# Update and upgrade the system packages
apt-get update && apt-get upgrade -y

# Remove unused packages and dependencies
apt-get autoremove -y && apt-get autoclean -y

# Remove old kernel versions (keep the current and one previous)
current_kernel=$(uname -r)
previous_kernel=$(dpkg --list | grep linux-image | awk '{print $2}' | grep -v "$current_kernel" | tail -n 1)
[[ -n "$previous_kernel" ]] && apt-get remove --purge -y "$previous_kernel"
EOF
    chmod +x /usr/local/bin/update_cleanup.sh
    echo "Update and cleanup script created at /usr/local/bin/update_cleanup.sh."
}

#Function to create backup script
create_backup_script() {
    # Ensure BACKUP_DIR is set in the larger script
    BACKUP_DIR="${BACKUP_DIR:-/media/f/backup/vm/prox}"  # Default if not set by the larger script

    # Create the backup script content with the correct variables
    cat <<EOF > /usr/local/bin/proxmox_backup.sh
#!/bin/bash

# Variables
BACKUP_DIR="$BACKUP_DIR"  # This will be passed or defaulted to /media/f/backup/vm/prox
DATE=\$(date +\%Y-\%m-\%d_\%H-\%M-\%S)
BACKUP_FILE="\$BACKUP_DIR/proxmox_backup_\$DATE.tar.gz"

# Ensure backup directory exists
mkdir -p "\$BACKUP_DIR" || { echo "Failed to create \$BACKUP_DIR"; exit 1; }

# Prune old backups: Remove backups older than 7 days
echo "Pruning backups older than 7 days..."
find "\$BACKUP_DIR" -type f -name "proxmox_backup_*.tar.gz" -mtime +6 -exec rm -f {} \;

# Backup /etc/pve (VM and storage configurations)
echo "Starting backup of /etc/pve to \$BACKUP_FILE..."
tar -czf "\$BACKUP_FILE" -C /etc pve
if [ \$? -ne 0 ]; then
    echo "Backup failed!"
    exit 1
fi

# Confirm the file was created
echo "Backup created: \$BACKUP_FILE"
EOF

    # Make the backup script executable
    chmod +x /usr/local/bin/proxmox_backup.sh

    echo "Backup script created at /usr/local/bin/proxmox_backup.sh"
}

# Function to set up a cron job for daily backups at 12 AM
setup_backup_cron() {
    cron_job="0 0 * * * /usr/local/bin/proxmox_backup.sh"
    if ! crontab -l | grep -q "$cron_job"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        echo "Cron job set up to run backup every day at 12:00 AM."
    else
        echo "Cron job already exists. Skipping cron setup."
    fi
}

# Main function to run all functions
run_all() {
    echo "Running all steps..."

    # Install packages
    echo "Do you want to proceed with installing packages? (yes/no): "
    read install_choice
    if [[ "$install_choice" =~ ^(yes|y)$ ]]; then
        install_packages
    fi

    # Configure repositories
    echo "Do you want to proceed with configuring repositories? (yes/no): "
    read repo_choice
    if [[ "$repo_choice" =~ ^(yes|y)$ ]]; then
        configure_repositories
    fi

    # Update PVEAM templates
    echo "Do you want to proceed with updating PVEAM templates? (yes/no): "
    read pveam_choice
    if [[ "$pveam_choice" =~ ^(yes|y)$ ]]; then
        update_pveam_templates
    fi

    # Create user and add to sudoers
    echo "Do you want to proceed with creating a user and adding to sudoers? (yes/no): "
    read user_choice
    if [[ "$user_choice" =~ ^(yes|y)$ ]]; then
        create_user_and_add_to_sudoers
    fi

    # Import ZFS pool
    echo "Do you want to proceed with importing the ZFS pool? (yes/no): "
    read zfs_choice
    if [[ "$zfs_choice" =~ ^(yes|y)$ ]]; then
        import_zfs_pool
    fi

    # Configure fstab mounts
    echo "Do you want to proceed with configuring fstab mounts? (yes/no): "
    read fstab_choice
    if [[ "$fstab_choice" =~ ^(yes|y)$ ]]; then
        configure_fstab_mounts
    fi

    # Restore configurations
    echo "Do you want to proceed with restoring configurations from backup? (yes/no): "
    read restore_choice
    if [[ "$restore_choice" =~ ^(yes|y)$ ]]; then
        restore_configs
    fi

    # Setup bash aliases
    echo "Do you want to proceed with setting up bash aliases? (yes/no): "
    read aliases_choice
    if [[ "$aliases_choice" =~ ^(yes|y)$ ]]; then
        setup_bash_aliases
    fi

    # Create update and cleanup script
    echo "Do you want to proceed with creating the update and cleanup script? (yes/no): "
    read update_script_choice
    if [[ "$update_script_choice" =~ ^(yes|y)$ ]]; then
        create_update_cleanup_script
    fi

    # Create backup script
    echo "Do you want to proceed with creating the backup script? (yes/no): "
    read backup_script_choice
    if [[ "$backup_script_choice" =~ ^(yes|y)$ ]]; then
        create_backup_script
    fi

    # Setup backup cron
    echo "Do you want to proceed with setting up the backup cron job? (yes/no): "
    read backup_cron_choice
    if [[ "$backup_cron_choice" =~ ^(yes|y)$ ]]; then
        setup_backup_cron
    fi

    echo "All functions completed."
}

# Function to handle menu options
main_menu() {
    while true; do  # Keep the menu running until the user chooses to exit
        clear
        echo "Proxmox Server Setup - Main Menu"
        echo "1. Run All Functions (with prompts)"
        echo "2. Install Packages"
        echo "3. Configure Repositories"
        echo "4. Update Proxmox Appliance Templates"
        echo "5. Create User and Add to Sudoers"
        echo "6. Import ZFS Pool"
        echo "7. Configure fstab Mounts"
        echo "8. Restore from Backup"
        echo "9. Set Up Bash Aliases"
        echo "10. Change Variables"
        echo "11. Create Update and Cleanup Script"
        echo "12. Create Backup Script"
        echo "13. Set Up Backup Cron"
        echo "14. Exit"
        read -p "Choose an option (1-14): " choice

        case $choice in
            1) run_all ;;
            2) install_packages ;;
            3) configure_repositories ;;
            4) update_pveam_templates ;;
            5) create_user_and_add_to_sudoers ;;
            6) import_zfs_pool ;;
            7) configure_fstab_mounts ;;
            8) restore_configs ;;
            9) setup_bash_aliases ;;
            10) change_variables ;;
            11) create_update_cleanup_script ;;
            12) create_backup_script ;;
            13) setup_backup_cron ;;
            14) echo "Exiting..."; exit 0 ;;
            *) echo "Invalid choice. Please choose between 1 and 14." ;;
        esac
        # Optionally wait for the user to press a key to continue before showing the menu again
        read -p "Press Enter to continue..." 
    done
}

# Call the main menu function
main_menu
