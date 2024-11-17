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
    echo "11. Restore VM"
    echo "12. Exit"
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
        11) restore_vm ;;
        12) exit 0 ;;
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
    ask_and_execute "Restore VM" restore_vm
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

add_ssh_key() {
    log "Setting up SSH key authentication..."

    if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
        echo "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
    fi

    echo "Copying SSH key to remote server..."
    ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" "$SUDO_USER@localhost"

    log "SSH key setup completed."
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

    local alias_file="$HOME/.bash_aliases"
    if [[ ! -f "$alias_file" ]]; then
        touch "$alias_file"
    fi

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
}

restore_vm() {
    read -p "Do you want to restore an existing VM? (y/n): " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            echo "Downloading and running the VM restore script..."
            curl -fsSL https://github.com/improvmasta/homelab/raw/refs/heads/main/proxmox/restoredocker.sh -o /tmp/restoredocker.sh
            if [ $? -eq 0 ]; then
                chmod +x /tmp/restoredocker.sh
                /tmp/restoredocker.sh || echo "Error: Failed to execute the restore script. Check for issues."
            else
                echo "Error: Failed to download the restore script. Check your internet connection or URL."
            fi
            ;;
        *)
            echo "Skipping VM restoration."
            ;;
    esac
}

# Function to restore an existing VM
restore_vm() {
    echo "Restoring an existing VM..."
    curl -fsSL https://github.com/improvmasta/homelab/raw/refs/heads/main/proxmox/restoredocker.sh -o /tmp/restoredocker.sh
    if [ $? -eq 0 ]; then
        chmod +x /tmp/restoredocker.sh
        /tmp/restoredocker.sh || echo "Error: Failed to execute the restore script. Check for issues."
    else
        echo "Error: Failed to download the restore script. Check your internet connection or URL."
    fi
}

menu