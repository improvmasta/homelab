#!/bin/bash

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Please run it with sudo or as the root user."
    exit 1
fi

# Define the general setup log file
SETUP_LOG="/var/log/setup.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$SETUP_LOG"
}

# Helper function to prompt user before running a step
ask_and_execute() {
    local step_name="$1"
    local function_name="$2"
    
    read -p "Do you want to proceed with $step_name? (y/n): " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            echo "Starting $step_name..."
            $function_name || echo "Error: $step_name failed. Check logs for details." ;;
        *)
            echo "Skipping $step_name." ;;
    esac
}

# Function to prompt user for confirmation
menu() {
    echo "Select an option:"
    echo "1. *RUN FULL SETUP*"
    echo "2. Set Hostname"
    echo "3. Install Packages"
    echo "4. Configure Samba Share"
    echo "5. Set Up Samba Shares"
    echo "6. Install Docker"
    echo "7. Add SSH Key Authentication"
    echo "8. Disable Password Authentication for SSH"
    echo "9. Create Update/Cleanup Script"
    echo "10. Add Bash Aliases"
	echo "11. Add User to docker Group"
    echo "12. Restore VM"
	echo "13. Set Up Docker Sync"
	echo "14. Set Up Docker Backup Job"
    echo "15. Exit"
    read -p "Enter your choice: " choice

    case "$choice" in
        1) full_setup ;;
        2) set_hostname ;;
        3) install_packages ;;
        4) share_home_directory ;;
        5) setup_samba_shares ;;
        6) install_docker ;;
        7) add_ssh_key ;;
        8) disable_ssh_pw_auth ;;
        9) create_update_cleanup_script ;;
        10) configure_bash_aliases ;;
		11) add_user_to_docker_group ;;
        12) restore_vm ;;
		13) setup_docker_sync ;;
		14) create_docker_backup_script ;;
        15) exit 0 ;;
        *) echo "Invalid choice, please try again." && menu ;;
    esac
}

# Full setup function that prompts the user for each step
full_setup() {
    ask_and_execute "Set Hostname" set_hostname
    ask_and_execute "Install Packages" install_packages
    ask_and_execute "Share Home Directory" share_home_directory
    ask_and_execute "Set Up Samba Shares" setup_samba_shares
    ask_and_execute "Install Docker" install_docker
    ask_and_execute "Add SSH Key Authentication" add_ssh_key
    ask_and_execute "Disable Password Authentication for SSH" disable_ssh_pw_auth
    ask_and_execute "Create Update/Cleanup Script" create_update_cleanup_script
    ask_and_execute "Add Bash Aliases" configure_bash_aliases
    ask_and_execute "Add User to Docker Group" add_user_to_docker_group
	ask_and_execute "Restore VM" restore_vm
	ask_and_execute "Set Up Docker Sync" setup_docker_sync
	ask_and_execute "Set Up Docker Backup Job" create_docker_backup_script
}

set_hostname() {
    log "Checking if hostname change is required..."
    local NEW_HOSTNAME="$1"

    if [ -n "$NEW_HOSTNAME" ]; then
        log "Setting hostname to $NEW_HOSTNAME..."
        CURRENT_HOSTNAME=$(hostname)

        echo "$NEW_HOSTNAME" | sudo tee /etc/hostname > /dev/null
        sudo sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
        sudo hostnamectl set-hostname "$NEW_HOSTNAME"
        log "Hostname has been changed to $NEW_HOSTNAME."
    else
        log "Hostname change skipped."
    fi
}

install_packages() {
    log "Updating and installing necessary packages..."
    if ! sudo apt-get update -y && sudo apt-get upgrade -y; then
        log "Failed to update packages"
        exit 1
    fi
    
    if ! sudo apt-get install -y net-tools gcc make perl samba cifs-utils winbind curl git bzip2 tar qemu-guest-agent; then
        log "Package installation failed"
        exit 1
    fi
    
    sudo apt-get autoremove -y && sudo apt-get autoclean -y
    log "Package installation complete."
}

share_home_directory() {
    local smb_conf="/etc/samba/smb.conf"
    local samba_user password
    samba_user="${SUDO_USER:-$USER}"
    home_directory=$(eval echo "~$samba_user")

    if [[ ! -d "$home_directory" ]]; then
        log "Home directory for user $samba_user not found."
        echo "Home directory for user $samba_user not found. Exiting..."
        return 1
    fi

    read -sp "Enter a password for Samba access to $samba_user's home directory: " password
    echo

    if ! sudo pdbedit -L | grep -qw "$samba_user"; then
        echo -e "$password\n$password" | sudo smbpasswd -a "$samba_user" > /dev/null
        log "Samba user $samba_user added."
    else
        echo -e "$password\n$password" | sudo smbpasswd -s "$samba_user" > /dev/null
        log "Samba password for $samba_user updated."
    fi

    sudo tee -a "$smb_conf" > /dev/null <<EOF

[$samba_user]
    path = $home_directory
    browseable = yes
    writable = yes
    valid users = $samba_user
    create mask = 0700
    directory mask = 0700
EOF

    log "Samba share for $samba_user's home directory configured in $smb_conf."
    sudo systemctl restart smbd
}

setup_samba_shares() {
    local secrets_file="/etc/samba_credentials"
    local server_ip samba_user samba_pass share_name
    local -a shares=()

    log "Starting Samba shares setup..."
    
    read -p "Enter the file server hostname/IP: " server_ip
    if [[ -z "$server_ip" ]]; then
        log "No server hostname/IP entered. Exiting Samba setup..."
        return 1
    fi

    read -p "Enter the Samba username: " samba_user
    read -sp "Enter the Samba password: " samba_pass
    echo

    {
        echo "username=$samba_user"
        echo "password=$samba_pass"
    } | sudo tee "$secrets_file" > /dev/null
    sudo chmod 600 "$secrets_file"
    log "Credentials stored securely in $secrets_file."

    while :; do
        read -p "Enter a Samba share name (or press Enter to finish): " share_name
        [[ -z "$share_name" ]] && break
        shares+=("$share_name")
    done

    if [[ ${#shares[@]} -eq 0 ]]; then
        log "No shares were added."
        echo "No shares were added."
        return 1
    fi

    for share_name in "${shares[@]}"; do
        mount_point="/media/$share_name"
        sudo mkdir -p "$mount_point"
        echo "//${server_ip}/${share_name} ${mount_point} cifs credentials=${secrets_file},uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0,dir_mode=0777,file_mode=0777 0 0" | sudo tee -a /etc/fstab > /dev/null
        log "Added $share_name to /etc/fstab, mounted at $mount_point."
    done

    if sudo mount -a; then
        log "All Samba shares mounted successfully."
        echo "All Samba shares mounted successfully."
    else
        log "Error occurred while mounting Samba shares."
        echo "Error occurred while mounting Samba shares. Check $SETUP_LOG for details."
        return 1
    fi
}

install_docker() {
    echo "Starting Docker installation..."

    # Remove existing Docker-related packages
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        sudo apt-get remove -y "$pkg"
    done

    # Update package index
    sudo apt-get update

    # Install necessary packages
    sudo apt-get install -y ca-certificates curl

    # Create directory for APT keyrings
    sudo install -m 0755 -d /etc/apt/keyrings

    # Download Docker GPG key
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc

    # Set permissions for the GPG key
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repository to APT sources
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package index again
    sudo apt-get update

    # Install Docker packages
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Post-installation: Add user to the docker group
    sudo usermod -aG docker "$USER"

    echo "Docker installation completed successfully."
    echo "Please log out and back in for the changes to take effect."
}

# Function to set up SSH key
add_ssh_key() {
    # Determine the current user's home directory
    local target_user="${SUDO_USER:-$USER}"
    local target_home=$(getent passwd "$target_user" | cut -d: -f6)
    local default_key_url="https://homelab.jupiterns.org/.keys/rsa_public"
    local key_path

    # Prompt user to provide a key path or use default
    read -p "Enter path to public key file (leave blank to use default): " key_path
    key_path="${key_path:-$default_key_url}"

    # Create .ssh directory with correct permissions
    sudo -u "$target_user" mkdir -p "$target_home/.ssh" && chmod 700 "$target_home/.ssh"

    # Fetch or copy the key into authorized_keys
    if [[ "$key_path" == http* ]]; then
        curl -fsSL "$key_path" | sudo -u "$target_user" tee -a "$target_home/.ssh/authorized_keys" > /dev/null
    else
        sudo -u "$target_user" cat "$key_path" | sudo -u "$target_user" tee -a "$target_home/.ssh/authorized_keys" > /dev/null
    fi

    # Set correct permissions
    sudo -u "$target_user" chmod 600 "$target_home/.ssh/authorized_keys"

    echo "SSH key has been added to $target_user's authorized_keys."
}

disable_ssh_pw_auth() {
    log "Disabling password authentication for SSH..."

    sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo systemctl restart sshd
    log "Password authentication disabled for SSH."
}

create_update_cleanup_script() {
    cat << 'EOF' | sudo tee /usr/local/bin/update_cleanup.sh > /dev/null
#!/bin/bash

# Update and upgrade the system packages
sudo apt-get update && sudo apt-get upgrade -y

# Remove unused packages and dependencies
sudo apt-get autoremove -y

# Clean up the local repository by removing package files
sudo apt-get autoclean -y

# Remove old kernel versions (keep the current and one previous)
current_kernel=$(uname -r)
sudo apt-get --purge remove "linux-image-*" -y
sudo apt-get install -y "linux-image-$current_kernel"

EOF

    sudo chmod +x /usr/local/bin/update_cleanup.sh
    log "Update and cleanup script created at /usr/local/bin/update_cleanup.sh."
}

configure_bash_aliases() {
    log "Configuring Bash aliases..."

    # Determine the sudo user's home directory
    if [[ -n "$SUDO_USER" ]]; then
        USER_HOME=$(eval echo ~"$SUDO_USER")
    else
        log "This script must be run with sudo. Exiting."
        exit 1
    fi

    # Set the .bash_aliases file path for the sudo user
    local alias_file="$USER_HOME/.bash_aliases"

    # Create the .bash_aliases file if it doesn't exist
    if [[ ! -f "$alias_file" ]]; then
        touch "$alias_file"
    fi

    # Append the aliases to the .bash_aliases file
    cat << 'EOF' >> "$alias_file"
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

    log "Bash aliases added to $alias_file."

    # Ensure the .bash_aliases file is owned by the sudo user
    chown "$SUDO_USER:$SUDO_USER" "$alias_file"
}


# Function to restore an existing VM
restore_vm() {
    echo "Restoring an existing VM..."
    curl -fsSL https://homelab.jupiterns.org/proxmox/restore-docker.sh -o /tmp/restore-docker.sh
    if [ $? -eq 0 ]; then
        chmod +x /tmp/restore-docker.sh
        /tmp/restore-docker.sh || echo "Error: Failed to execute the restore script. Check for issues."
    else
        echo "Error: Failed to download the restore script. Check your internet connection or URL."
    fi
}

# Function to set up Docker Sync
setup_docker_sync() {
    echo "Setting up Docker Sync..."
    curl -fsSL https://homelab.jupiterns.org/proxmox/setup-docker-sync.sh -o /tmp/setup-docker-sync.sh
    if [ $? -eq 0 ]; then
        chmod +x /tmp/setup-docker-sync.sh
        /tmp/setup-docker-sync.sh || echo "Error: Failed to execute the Sync script. Check for issues."
    else
        echo "Error: Failed to download the Sync script. Check your internet connection or URL."
    fi
}

# Function to create a script and cron job to backup the appdata and compose files
create_docker_backup_script() {
    local default_backup_dir="/media/f/backup/vm/$(hostname)-$(hostname -I | awk '{print $1}')/"
    local backup_dir
    local cron_schedule="0 2 * * *" # Default cron schedule: 2 am every day
    local script_path="/home/$(logname)/docker_backup.sh"

    echo "Docker Backup Script Creation"
    echo "---------------------------------"

    # Prompt for backup directory
    read -p "Enter the backup directory [default: $default_backup_dir]: " backup_dir
    backup_dir=${backup_dir:-$default_backup_dir}

    # Prompt for cron schedule
    echo "The default cron schedule is '2 am every day'."
    read -p "Enter a new cron schedule in standard format (or press Enter to use the default): " user_cron_schedule
    cron_schedule=${user_cron_schedule:-$cron_schedule}

    # Create the backup script
    echo "Creating backup script at $script_path..."
    sudo tee "$script_path" > /dev/null << EOF
#!/bin/bash
set -e

# Variables
BACKUP_DIR="$backup_dir"
USER_HOME="/home/$(logname)"
TIMESTAMP=\$(date +%Y-%m-%d)
MONTHLY_TAG=\$(date +%Y-%m)

# Functions
create_backup() {
    echo "Stopping all running containers..."
    docker stop \$(docker ps -q) || echo "No running containers to stop."

    echo "Creating backup directory..."
    mkdir -p "\$BACKUP_DIR"

    echo "Backing up Docker Compose and AppData directories..."
    tar -czf "\$BACKUP_DIR/\$TIMESTAMP-compose.tar.gz" -C "\$USER_HOME" .docker/compose
    tar -czf "\$BACKUP_DIR/\$TIMESTAMP-appdata.tar.gz" -C "\$USER_HOME" .config/appdata

    echo "Pruning backups..."
    find "\$BACKUP_DIR" -name "*.tar.gz" -type f -mtime +3 -not -name "*-monthly.tar.gz" -exec rm -f {} +
}

create_monthly_backup() {
    echo "Creating monthly backup..."
    if ! find "\$BACKUP_DIR" -name "\$MONTHLY_TAG-monthly.tar.gz" -type f &>/dev/null; then
        cp "\$BACKUP_DIR/\$TIMESTAMP-compose.tar.gz" "\$BACKUP_DIR/\$MONTHLY_TAG-monthly.tar.gz"
        cp "\$BACKUP_DIR/\$TIMESTAMP-appdata.tar.gz" "\$BACKUP_DIR/\$MONTHLY_TAG-monthly.tar.gz"
    fi

    # Retain monthly backups for 6 months
    find "\$BACKUP_DIR" -name "*-monthly.tar.gz" -type f -mtime +180 -exec rm -f {} +
}

restart_containers() {
    echo "Restarting all stopped containers..."
    docker start \$(docker ps -a -q)
}

# Execution
create_backup
if [ "\$(date +%d)" = "01" ]; then
    create_monthly_backup
fi
restart_containers

echo "Backup complete!"
EOF

    # Make the script executable
    sudo chmod +x "$script_path"
    sudo chown "$(logname)" "$script_path"

    # Add cron job as root
    echo "Adding the backup script to root's cron with the schedule: $cron_schedule"
    (sudo crontab -l 2>/dev/null; echo "$cron_schedule bash $script_path") | sudo crontab -

    echo "Backup script and root cron job created successfully."
}

add_user_to_docker_group() {
    echo "Adding the sudo user to the Docker group..."
    
    # Get the non-root user running the script
    SUDO_USER=$(logname 2>/dev/null || echo "root")
    
    if [[ "$SUDO_USER" == "root" ]]; then
        echo "No non-root user detected. Skipping adding user to Docker group."
        return 1
    fi
    
    # Ensure the Docker group exists
    if ! getent group docker >/dev/null; then
        echo "Docker group does not exist. Creating it..."
        groupadd docker
    fi

    # Add the user to the Docker group
    usermod -aG docker "$SUDO_USER"
    
    # Notify user of changes
    echo "User '$SUDO_USER' added to the Docker group."
    echo "You may need to log out and back in for the changes to take effect."
}


menu
