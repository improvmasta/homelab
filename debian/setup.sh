#!/bin/bash

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

# Remove old kernel versions (keep the current and one previous)
current_kernel=$(uname -r)
previous_kernel=$(dpkg --list | grep linux-image | awk '{print $2}' | grep -v "$current_kernel" | tail -n 1)
if [[ -n "$previous_kernel" ]]; then
    sudo apt-get remove --purge -y "$previous_kernel"
fi

# Clear the APT cache
sudo apt-get clean

# Remove orphaned packages (no longer required)
sudo deborphan | xargs -r sudo apt-get remove --purge -y

# Remove any old log files
sudo find /var/log -type f -name '*.log' -delete

# Optional: clear thumbnail cache (if using a desktop environment)
if [[ -d "$HOME/.cache/thumbnails" ]]; then
    rm -rf "$HOME/.cache/thumbnails/*"
fi

# Optional: clear user-specific cache (be careful with this)
rm -rf "$HOME/.cache/*"

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
alias ls='ls --color -Flah'
alias update='/usr/local/bin/update_cleanup.sh'
EOF

        log "Bash aliases configured in $target_home/.bash_aliases."
        echo "Bash aliases added to $target_home/.bash_aliases. Run 'source ~/.bash_aliases' to apply changes."
    else
        echo "Bash aliases are already configured in $target_home/.bash_aliases."
    fi

    # Ensure .bashrc sources the .bash_aliases file
    if ! grep -q "if [ -f $target_home/.bash_aliases ]; then" "$target_home/.bashrc"; then
        echo "if [ -f $target_home/.bash_aliases ]; then" >> "$target_home/.bashrc"
        echo "    . $target_home/.bash_aliases" >> "$target_home/.bashrc"
        echo "fi" >> "$target_home/.bashrc"
        log ".bashrc updated to source $target_home/.bash_aliases."
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

sshkey() {
    # Determine the current user's home directory
    local target_home
    target_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)

    # If SUDO_USER is not set, fall back to the current user's home
    if [ -z "$target_home" ]; then
        target_home="$HOME"
    fi
    # Create .ssh directory if it doesn't exist
    mkdir -p "$target_home/.ssh"
    chmod 700 "$target_home/.ssh"

    # Add the SSH2 public key to authorized_keys
    echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCJZfbiKdE9swjxMQ7cBH8Dh2gPEgClDtUGEYV8Xf0GbicoxgjlKohRKwW3kbOAZsjA0ecjtRtNNJRRkMfVmVNmkrga1HXN1vL3vs7QuOt5X3+H4h3u2TkEmxpohxGURbi9qHBAV+BAljqZHtR08+qRZZ/ezrtr2gKnteQ5l1q/y/N8X4KSholelu6/TOaPzHbqapEsFvKwbxdh5uIAziyWL20y8J5CXClCg8BrODVYr6rd0jrt5Z3aV2zpCQm524dmsXTGHnRWXL4mtFNMrHeK6LaC69WVzKkkN2lwfNZy/wScYXbNPqDA0M5RZLmBh4hj62zic8CIHYVhlNuu+PLh" >> "$target_home/.ssh/authorized_keys"

    # Set permissions for the authorized_keys file
    chmod 600 "$target_home/.ssh/authorized_keys"

    echo "SSH key has been added to authorized_keys."
}

disable_password_auth() {
    # Backup the original sshd_config file
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    # Modify the sshd_config file to disable password authentication
    echo "Disabling password authentication in /etc/ssh/sshd_config..."
    
    # Check if the file contains the PasswordAuthentication line and update it
    if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
        sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    else
        echo "PasswordAuthentication no" | sudo tee -a /etc/ssh/sshd_config
    fi

    # Disable ChallengeResponseAuthentication as well
    if grep -q "^ChallengeResponseAuthentication" /etc/ssh/sshd_config; then
        sudo sed -i 's/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    else
        echo "ChallengeResponseAuthentication no" | sudo tee -a /etc/ssh/sshd_config
    fi

    # Restart the SSH service to apply the changes
    echo "Restarting SSH service..."
    sudo systemctl restart ssh

    echo "Password authentication has been disabled. Please test your SSH key login."
}

main() {
    log "Starting setup script..."

    if prompt_to_proceed "Would you like to change the hostname?"; then
        read -p "Enter new hostname: " NEW_HOSTNAME
        set_hostname "y" "$NEW_HOSTNAME"
    fi

    if prompt_to_proceed "Would you like to install necessary packages?"; then
        install_packages
    fi

    if prompt_to_proceed "Would you like to share the home directory via Samba?"; then
        share_home_directory
    fi

    if prompt_to_proceed "Would you like to set up Samba shares?"; then
        setup_samba_shares
    fi

    if prompt_to_proceed "Would you like to configure DNS settings for Pi-hole?"; then
        configure_dns
    fi

    if prompt_to_proceed "Would you like to create a system update/cleanup script?"; then
        create_update_cleanup_script
    fi

    if prompt_to_proceed "Would you like to configure Bash aliases?"; then
        configure_bash_aliases
    fi
 
    if prompt_to_proceed "Would you like to configure Docker?"; then
        install_docker
    fi
	
	if prompt_to_proceed "Would you like to install your public SSH key?"; then
        sshkey
    fi
	
#	if prompt_to_proceed "Would you like to disable SSH pw authentication?"; then
#        disable_password_auth
#    fi

    log "Setup script completed."
    echo "Setup script completed. Check $SETUP_LOG for details."
}

main "$@"
