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

# Function to prompt user for confirmation
prompt_to_proceed() {
    local step_message="$1"
    read -p "$step_message [y/n]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

set_hostname() {
    log "Checking if hostname change is required..."
    local change_hostname="$1"
    local NEW_HOSTNAME="$2"

    if [[ "$change_hostname" =~ ^[yY]$ ]] && [ -n "$NEW_HOSTNAME" ]; then
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
    
    if ! sudo apt-get install -y net-tools gcc make perl samba cifs-utils winbind curl git bzip2 tar; then
        log "Package installation failed"
        exit 1
    fi
    
    sudo apt-get autoremove -y && sudo apt-get autoclean -y
    log "Package installation complete."
}

share_home_directory() {
    local smb_conf="/etc/samba/smb.conf"
    local samba_user password password_confirm
    samba_user="${SUDO_USER:-$USER}"
    home_directory=$(eval echo "~$samba_user")

    if [[ ! -d "$home_directory" ]]; then
        log "Home directory for user $samba_user not found."
        echo "Home directory for user $samba_user not found. Exiting..."
        return 1
    fi

    # Password prompt with confirmation
    while true; do
        read -sp "Enter a password for Samba access to $samba_user's home directory: " password
        echo
        read -sp "Confirm password: " password_confirm
        echo
        [[ "$password" == "$password_confirm" ]] && break
        echo "Passwords do not match. Please try again."
    done

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
    local server_ip samba_user samba_pass samba_pass_confirm share_name
    local -a shares=()

    log "Starting Samba shares setup..."
    
    read -p "Enter the file server hostname/IP: " server_ip
    if [[ -z "$server_ip" ]]; then
        log "No server hostname/IP entered. Exiting Samba setup..."
        return 1
    fi

    read -p "Enter the Samba username: " samba_user

    # Password prompt with confirmation
    while true; do
        read -sp "Enter the Samba password: " samba_pass
        echo
        read -sp "Confirm password: " samba_pass_confirm
        echo
        [[ "$samba_pass" == "$samba_pass_confirm" ]] && break
        echo "Passwords do not match. Please try again."
    done

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
        echo "//${server_ip}/${share_name} ${mount_point} cifs credentials=${secrets_file},uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0 0 0" | sudo tee -a /etc/fstab > /dev/null
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

configure_dns() {
    local resolved_conf="/etc/systemd/resolved.conf"
    
    read -p "Enter the DNS server IP address (default: 10.1.1.1): " dns_server
    dns_server=${dns_server:-10.1.1.1}

    {
        echo "DNS=[$dns_server]"
        echo "FallbackDNS=8.8.8.8 8.8.4.4"
    } | sudo tee -a "$resolved_conf" > /dev/null
    log "DNS configuration updated in $resolved_conf."

    if sudo systemctl restart systemd-resolved; then
        log "Systemd-resolved service restarted successfully."
        echo "DNS configuration has been applied."
    else
        log "Failed to restart systemd-resolved service."
        echo "Error: Failed to restart DNS service. Check $SETUP_LOG for details."
        return 1
    fi
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

# Clear the APT cache
sudo apt-get clean

# Remove orphaned packages (no longer required)
sudo deborphan | xargs -r sudo apt-get remove --purge -y

# Remove any old log files
sudo find /var/log -type f -name '*.log' -delete

echo "Cleanup complete!"
EOF

    sudo chmod +x /usr/local/bin/update_cleanup.sh
    log "Update and cleanup script created at /usr/local/bin/update_cleanup.sh."
}

configure_bash_aliases() {
    # Determine the current user's home directory
    local target_home
    target_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)

    # If SUDO_USER is not set, fall back to the current user's home
    if [ -z "$target_home" ]; then
        target_home="$HOME"
    fi

    # Create or append to the .bash_aliases file
    if [ ! -f "$target_home/.bash_aliases" ]; then
        touch "$target_home/.bash_aliases"
        echo "# Custom Bash aliases" >> "$target_home/.bash_aliases"
    fi

    # Check for existing aliases to avoid duplication
    if ! grep -q "alias ..='cd ..'" "$target_home/.bash_aliases"; then
        cat << 'EOF' >> "$target_home/.bash_aliases"

alias ..='cd ..'
alias ...='cd ../..'
alias dock='cd ~/.docker/compose'
alias dc='cd ~/.config/appdata/'
alias dup='docker compose -f ~/.docker/compose/docker-compose.yml up -d'
alias ddown='docker compose -f ~/.docker/compose/docker-compose.yml down'
alias dr='docker compose -f ~/.docker/compose/docker-compose.yml restart'
alias dstart='docker compose -f ~/.docker/compose/docker-compose.yml start'
alias dstop='docker compose -f ~/.docker/compose/docker-compose.yml stop'
alias lsl='ls -la'
EOF
        log "Aliases added to $target_home/.bash_aliases."
    else
        log "Aliases already exist in $target_home/.bash_aliases, skipping."
    fi
}

# Main function
main() {
    echo "Starting setup script..."

    # Run functions with user confirmation
    if prompt_to_proceed "Set the hostname?"; then
        read -p "Enter new hostname: " NEW_HOSTNAME
        set_hostname "y" "$NEW_HOSTNAME"
    fi

    if prompt_to_proceed "Install necessary packages?"; then
        install_packages
    fi

    if prompt_to_proceed "Share home directory with Samba?"; then
        share_home_directory
    fi

    if prompt_to_proceed "Set up Samba shares?"; then
        setup_samba_shares
    fi

    if prompt_to_proceed "Configure DNS settings?"; then
        configure_dns
    fi

    if prompt_to_proceed "Create a system update and cleanup script?"; then
        create_update_cleanup_script
    fi

    if prompt_to_proceed "Configure Bash aliases?"; then
        configure_bash_aliases
    fi

    echo "Setup script completed."
}

main
