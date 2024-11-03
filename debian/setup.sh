#!/bin/bash

# Define the general setup log file
SETUP_LOG="/var/log/setup.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$SETUP_LOG"
}

set_hostname() {
    log "Checking if hostname change is required..."

    # Get user input for hostname change and new hostname
    local change_hostname="$1"
    local NEW_HOSTNAME="$2"

    if [[ "$change_hostname" =~ ^[yY]$ ]] && [ -n "$NEW_HOSTNAME" ]; then
        log "Setting hostname to $NEW_HOSTNAME..."
        CURRENT_HOSTNAME=$(hostname)

        # Update /etc/hostname
        echo "$NEW_HOSTNAME" | sudo tee /etc/hostname > /dev/null
        
        # Update /etc/hosts
        if sudo sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts; then
            log "Updated /etc/hosts successfully."
        else
            log "Failed to update /etc/hosts."
            exit 1
        fi
        
        # Set the new hostname
        if sudo hostnamectl set-hostname "$NEW_HOSTNAME"; then
            log "Hostname has been changed to $NEW_HOSTNAME."
        else
            log "Failed to set hostname."
            exit 1
        fi
    else
        log "Hostname change skipped."
    fi
}

install_packages() {
    log "Updating and installing necessary packages..."
    sudo apt-get update -y && sudo apt-get upgrade -y || { log "Failed to update packages"; exit 1; }
    sudo apt-get install -y net-tools gcc make perl samba cifs-utils winbind curl git bzip2 tar || { log "Package installation failed"; exit 1; }
    sudo apt-get autoremove -y && sudo apt-get autoclean -y || { log "Autoremove failed"; exit 1; }
    log "Package installation complete."
}

setup_samba_shares() {
    local secrets_file="/etc/samba_credentials"
    local server_ip samba_user samba_pass share_name mount_point
    local -a shares=()  # Array to hold all share names

    # Function to log messages to the general setup log file
    log_message() {
        local message="$1"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | sudo tee -a "$SETUP_LOG" > /dev/null
    }

    # Ensure script is run with necessary privileges
    if [[ $EUID -ne 0 ]]; then
        echo "Please run this script with sudo or as root."
        return 1
    fi

    # Prompt for the Samba server IP or hostname
    read -p "Enter the file server hostname/IP: " server_ip
    if [[ -z "$server_ip" ]]; then
        log_message "No server hostname/IP entered. Exiting Samba setup..."
        echo "No server hostname/IP entered. Exiting Samba setup..."
        return 1
    fi

    # Prompt for Samba credentials
    read -p "Enter the Samba username: " samba_user
    read -sp "Enter the Samba password: " samba_pass
    echo

    # Create or update the secrets file with proper permissions
    {
        echo "username=$samba_user"
        echo "password=$samba_pass"
    } | sudo tee "$secrets_file" > /dev/null
    sudo chmod 600 "$secrets_file"
    log_message "Credentials stored securely in $secrets_file."

    # Collect and validate share names
    while :; do
        read -p "Enter a Samba share name (or press Enter to finish): " share_name
        [[ -z "$share_name" ]] && break
        shares+=("$share_name")
    done

    if [[ ${#shares[@]} -eq 0 ]]; then
        log_message "No shares were added."
        echo "No shares were added."
        return 1
    fi

    # Add each share to fstab and create mount points
    for share_name in "${shares[@]}"; do
        mount_point="/media/$share_name"
        sudo mkdir -p "$mount_point"

        # Check for existing fstab entry to avoid duplicates
        if grep -qs "^//$server_ip/$share_name" /etc/fstab; then
            log_message "Skipping $share_name; entry already exists in /etc/fstab."
            echo "Skipping $share_name; entry already exists in /etc/fstab."
            continue
        fi

        # Append entry to fstab
        echo "//${server_ip}/${share_name} ${mount_point} cifs credentials=${secrets_file},uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0 0 0" | sudo tee -a /etc/fstab > /dev/null
        log_message "Added $share_name to /etc/fstab, mounted at $mount_point."
    done

    # Attempt to mount all shares and log the result
    if sudo mount -a; then
        log_message "All Samba shares mounted successfully."
        echo "All Samba shares mounted successfully."
    else
        log_message "Error occurred while mounting Samba shares."
        echo "Error occurred while mounting Samba shares. Check $SETUP_LOG for details."
        return 1
    fi
}

share_home_directory() {
    local smb_conf="/etc/samba/smb.conf"
    local samba_user password

    # Function to log messages to the general setup log file
    log_message() {
        local message="$1"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | sudo tee -a "$SETUP_LOG" > /dev/null
    }

    # Ensure script is run with necessary privileges
    if [[ $EUID -ne 0 ]]; then
        echo "Please run this script with sudo or as root."
        return 1
    fi

    # Get the current user and their home directory
    samba_user="${SUDO_USER:-$USER}"
    home_directory=$(eval echo "~$samba_user")

    # Ensure home directory exists
    if [[ ! -d "$home_directory" ]]; then
        log_message "Home directory for user $samba_user not found."
        echo "Home directory for user $samba_user not found. Exiting..."
        return 1
    fi

    # Prompt for Samba password
    read -sp "Enter a password for Samba access to $samba_user's home directory: " password
    echo

    # Add the user to Samba if not already added
    if ! sudo pdbedit -L | grep -qw "$samba_user"; then
        echo -e "$password\n$password" | sudo smbpasswd -a "$samba_user" > /dev/null
        log_message "Samba user $samba_user added."
    else
        echo -e "$password\n$password" | sudo smbpasswd -s "$samba_user" > /dev/null
        log_message "Samba password for $samba_user updated."
    fi

    # Add Samba configuration for the user's home directory
    sudo tee -a "$smb_conf" > /dev/null <<EOF

[$samba_user]
    path = $home_directory
    browseable = yes
    writable = yes
    valid users = $samba_user
    create mask = 0700
    directory mask = 0700
EOF

    log_message "Samba share for $samba_user's home directory configured in $smb_conf."

    # Restart Samba to apply changes
    if sudo systemctl restart smbd; then
        log_message "Samba service restarted successfully."
        echo "Home directory shared successfully via Samba."
    else
        log_message "Failed to restart Samba service."
        echo "Error: Failed to restart Samba. Check $SETUP_LOG for details."
        return 1
    fi
}

# Docker installation function for Debian
install_docker() {
    # Log message function to use the general setup log
    log_message() {
        local message="$1"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | sudo tee -a "$SETUP_LOG" > /dev/null
    }

    # Confirm with the user before starting
    if ! prompt_to_proceed "Would you like to install Docker on Debian?"; then
        log_message "Docker installation skipped."
        echo "Skipping Docker installation."
        return
    fi

    log_message "Starting Docker installation on Debian."

    # Step 1: Update the apt package index
    if ! sudo apt-get update -y; then
        log_message "Failed to update apt package index."
        echo "Error: Failed to update package index."
        return 1
    fi
    log_message "Package index updated successfully."

    # Step 2: Install required packages
    if ! sudo apt-get install -y ca-certificates curl gnupg lsb-release; then
        log_message "Failed to install prerequisite packages."
        echo "Error: Prerequisite packages installation failed."
        return 1
    fi
    log_message "Prerequisite packages installed successfully."

    # Step 3: Add Docker's official GPG key
    sudo mkdir -p /etc/apt/keyrings
    if ! curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        log_message "Failed to add Docker's GPG key."
        echo "Error: Failed to add Docker GPG key."
        return 1
    fi
    log_message "Docker GPG key added successfully."

    # Step 4: Set up the Docker repository
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    log_message "Docker repository configured successfully."

    # Step 5: Install Docker Engine
    if ! sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        log_message "Failed to install Docker packages."
        echo "Error: Docker installation failed."
        return 1
    fi
    log_message "Docker installed successfully."

    # Step 6: Verify Docker installation
    if ! sudo docker --version; then
        log_message "Docker installation verification failed."
        echo "Error: Docker verification failed. Check $SETUP_LOG for details."
        return 1
    fi
    log_message "Docker installation verified successfully."
    echo "Docker has been installed and verified."
}

configure_dns() {
    local resolved_conf="/etc/systemd/resolved.conf"
    
    # Prompt for DNS server IP address
    read -p "Enter the DNS server IP address (default: 10.1.1.1): " dns_server
    dns_server=${dns_server:-10.1.1.1}  # Use default if no input is given

    # Log message function for general setup log
    log_message() {
        local message="$1"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | sudo tee -a "$SETUP_LOG" > /dev/null
    }

    # Configure DNS settings in systemd-resolved.conf
    {
        echo "DNS=$dns_server"
        echo "Domains=lan"
        echo "Cache=no"
        echo "DNSStubListener=no"
    } | sudo tee -a "$resolved_conf" > /dev/null

    # Restart systemd-resolved service to apply changes
    if sudo systemctl restart systemd-resolved; then
        log_message "DNS settings configured for Pi-hole in $resolved_conf."
        echo "DNS settings configured successfully for Pi-hole."
    else
        log_message "Error: Failed to restart systemd-resolved service."
        echo "Error: Failed to restart systemd-resolved. Check $SETUP_LOG for details."
        return 1
    fi
}

create_update_script() {
    log "Creating or updating update script for $LOCAL_USER..."
    UPDATE_SCRIPT="/home/$LOCAL_USER/update"

    # Define the new script content with additional cleanup commands
    NEW_CONTENT=$(cat <<EOF
#!/bin/bash

# Update package index and upgrade packages
sudo apt-get update -y && sudo apt-get upgrade -y

# Remove unused packages and clean up
sudo apt-get autoremove -y && sudo apt-get autoclean -y

# Clean journal logs older than 3 days
sudo journalctl --vacuum-time=3d

# Clean APT cache (uncomment if you want to keep the cache clean)
# sudo apt-get clean

# Remove orphaned packages (requires deborphan to be installed)
# sudo apt-get install -y deborphan
# sudo apt-get remove --purge \$(deborphan)

EOF
    )

    # Check if the script needs to be created or updated
    if [ ! -f "$UPDATE_SCRIPT" ] || [ "$NEW_CONTENT" != "$(cat "$UPDATE_SCRIPT")" ]; then
        echo "$NEW_CONTENT" | sudo tee "$UPDATE_SCRIPT" > /dev/null
        sudo chmod +x "$UPDATE_SCRIPT"
        log "Update script created or updated successfully."
    else
        log "Update script is already up to date."
    fi
}







# Function to prompt user for each step
prompt_to_proceed() {
    local step_message="$1"
    read -p "$step_message [y/n]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

configure_bash_aliases() {
    log "Setting up Bash aliases for $LOCAL_USER..."
    BASH_ALIASES_FILE="/home/$LOCAL_USER/.bash_aliases"

    # Create the aliases content
    NEW_CONTENT=$(cat <<EOF
# Bash Aliases
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
alias update='~/update'
EOF
    )

    # Check if .bash_aliases file exists and needs updating
    if [ ! -f "$BASH_ALIASES_FILE" ] || [ "$NEW_CONTENT" != "$(cat "$BASH_ALIASES_FILE")" ]; then
        echo "$NEW_CONTENT" | sudo tee "$BASH_ALIASES_FILE" > /dev/null
        log "Bash aliases file created or updated successfully."
    else
        log "Bash aliases file is already up to date."
    fi

    # Ensure .bash_aliases is sourced in .bashrc
    if ! sudo grep -q "if [ -f ~/.bash_aliases ]" "/home/$LOCAL_USER/.bashrc"; then
        echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" | sudo tee -a "/home/$LOCAL_USER/.bashrc" > /dev/null
        log "Added .bash_aliases source command to /home/$LOCAL_USER/.bashrc."
    fi

    # Set appropriate permissions for .bash_aliases
    sudo chown "$LOCAL_USER:$LOCAL_USER" "$BASH_ALIASES_FILE"
    sudo chmod 644 "$BASH_ALIASES_FILE"

    log "Bash aliases setup completed for $LOCAL_USER."
}

# Main setup function
main_setup() {
    # Set hostname
    read -p "Do you want to change the hostname? (y/n): " change_hostname
    if [[ "$change_hostname" =~ ^[yY]$ ]]; then
        read -p "Enter the desired hostname for this server: " NEW_HOSTNAME
        set_hostname "$change_hostname" "$NEW_HOSTNAME"
    else
        log "Hostname change skipped."
    fi

    # Install packages
    read -p "Do you want to install necessary packages? (y/n): " install_choice
    if [[ "$install_choice" =~ ^[yY]$ ]]; then
        install_packages
    else
        log "Package installation skipped."
    fi

    # Share home directory
    read -p "Do you want to share the user's home directory? (y/n): " share_home_choice
    if [[ "$share_home_choice" =~ ^[yY]$ ]]; then
        share_home_directory
    else
        log "Home directory sharing skipped."
    fi

    # Set up Samba shares
    read -p "Do you want to set up Samba shares? (y/n): " samba_choice
    if [[ "$samba_choice" =~ ^[yY]$ ]]; then
        setup_samba_shares
    else
        log "Samba share setup skipped."
    fi

    # Install Docker
    read -p "Do you want to install Docker? (y/n): " docker_choice
    if [[ "$docker_choice" =~ ^[yY]$ ]]; then
        install_docker
    else
        log "Docker installation skipped."
    fi

    # Configure DNS
    read -p "Is this system going to be configured as a Pi-hole? (y/n): " pihole_choice
    if [[ "$pihole_choice" =~ ^[yY]$ ]]; then
        read -p "Enter the DNS host (IP address): " dns_host
        configure_dns "$dns_host"
    else
        log "DNS configuration skipped."
    fi

    # Create update script
    read -p "Do you want to create or update the system update script? (y/n): " update_script_choice
    if [[ "$update_script_choice" =~ ^[yY]$ ]]; then
        create_update_script
    else
        log "Update script creation skipped."
    fi

    # Configure Bash aliases
    read -p "Do you want to configure Bash aliases? (y/n): " aliases_choice
    if [[ "$aliases_choice" =~ ^[yY]$ ]]; then
        configure_bash_aliases
    else
        log "Bash aliases configuration skipped."
    fi
}

# Call the main setup function
main_setup