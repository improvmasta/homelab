#!/bin/bash

# Function to create a user, ensure sudo is installed, and add to sudoers
create_user_and_add_to_sudoers() {
    echo "Checking if 'sudo' is installed..."

    # Check if sudo is installed, and install it if not
    if ! command -v sudo &> /dev/null; then
        echo "'sudo' is not installed. Installing it now..."
        apt update && apt install -y sudo || {
            echo "Error: Failed to install sudo. Exiting."
            return 1
        }
    fi

    echo "'sudo' is installed."

    # Prompt for the new username
    read -p "Enter the new non-root username: " new_user
    useradd -m -s /bin/bash "$new_user" && passwd "$new_user"
    usermod -aG sudo "$new_user"
    echo "$new_user created and added to sudoers."

    # Default SSH key URL
    local default_ssh_key_url="https://homelab.jupiterns.org/.keys/rsa_public"
    local ssh_key_url

    # Prompt user to provide an alternative key source
    read -p "Enter a URL or path for the SSH public key (leave blank to use default): " ssh_key_url
    ssh_key_url="${ssh_key_url:-$default_ssh_key_url}"

    # Fetch the SSH key
    local ssh_key
    if [[ "$ssh_key_url" == http* ]]; then
        ssh_key=$(curl -fsSL "$ssh_key_url") || {
            echo "Error: Unable to fetch the SSH key from $ssh_key_url."
            return 1
        }
    else
        ssh_key=$(cat "$ssh_key_url") || {
            echo "Error: Unable to read the SSH key from $ssh_key_url."
            return 1
        }
    fi

    # Create .ssh directories and set permissions
    mkdir -p /root/.ssh /home/"$new_user"/.ssh
    echo "$ssh_key" > /root/.ssh/authorized_keys
    echo "$ssh_key" > /home/"$new_user"/.ssh/authorized_keys
    chmod 700 /root/.ssh /home/"$new_user"/.ssh
    chmod 600 /root/.ssh/authorized_keys /home/"$new_user"/.ssh/authorized_keys
    chown -R "$new_user:$new_user" /home/"$new_user"/.ssh

    echo "SSH key added to both root and $new_user users."
}

#Run
create_user_and_add_to_sudoers