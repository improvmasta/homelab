#!/bin/bash

# Log file path
LOG_FILE="/var/log/proxmox_setup.log"

# Function to log errors
log_error() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $message" | tee -a "$LOG_FILE"
}

# Function to install ntfs-3g
install_ntfs3g() {
    echo "Installing ntfs-3g..."
    if apt-get update && apt-get install -y ntfs-3g; then
        echo "ntfs-3g installed successfully."
    else
        log_error "Failed to install ntfs-3g."
        echo "Error: Could not install ntfs-3g. Check the logs for details."
        exit 1
    fi
}

# Function to import a ZFS pool
import_zfs_pool() {
    read -p "Do you want to import a ZFS pool? (yes/no): " import_zfs
    if [[ "$import_zfs" =~ ^(yes|y)$ ]]; then
        read -p "Enter the name of the ZFS pool to import: " pool_name

        # Attempt to import the ZFS pool
        echo "Importing ZFS pool: $pool_name"
        if zpool import "$pool_name"; then
            echo "ZFS pool $pool_name imported successfully."
        else
            log_error "Failed to import ZFS pool: $pool_name"
            echo "Error: Could not import ZFS pool: $pool_name"
        fi
    else
        echo "Skipping ZFS pool import."
    fi
}

# Function to add fstab mounts and handle VM/Container import
add_fstab_and_import() {
    echo "Would you like to add fstab mounts for 10.1.1.2? (yes/no)"
    read -r add_mounts

    if [[ "$add_mounts" =~ ^(yes|y)$ ]]; then
        echo "Adding fstab mounts..."

        # Mount entries and directories
        local mounts=(
            'UUID="A8BADD47BADD1324" /media/d ntfs rw 0 0'
            'UUID="5E1E45AD1E457F51" /media/e ntfs rw 0 0'
            'UUID="123456781E457F51" /media/f ntfs rw 0 0'
            'UUID="a4b151c8-68b0-4a3a-abc7-b2aa1cfbbcaf" /media/vmb ext4 rw 0 0'
        )
        local directories=("/media/d" "/media/e" "/media/f" "/media/vmb")

        # Create directories if they don't exist
        for dir in "${directories[@]}"; do
            if [ ! -d "$dir" ]; then
                echo "Creating directory: $dir"
                if mkdir -p "$dir"; then
                    echo "Directory created: $dir"
                else
                    log_error "Failed to create directory: $dir"
                    echo "Error: Could not create directory: $dir"
                    return 1
                fi
            else
                echo "Directory already exists: $dir"
            fi
        done

        # Check if each entry exists in fstab and append if not
        for entry in "${mounts[@]}"; do
            if grep -q "${entry}" /etc/fstab; then
                echo "Entry already exists in fstab: ${entry}"
            else
                echo "${entry}" >> /etc/fstab
                if [ $? -eq 0 ]; then
                    echo "Added to fstab: ${entry}"
                else
                    log_error "Failed to add entry to fstab: ${entry}"
                    echo "Error: Could not add entry: ${entry}"
                fi
            fi
        done

        # Reload fstab to apply changes
        echo "Reloading fstab..."
        if mount -a; then
            echo "fstab reloaded successfully."
        else
            log_error "Failed to reload fstab with 'mount -a'."
            echo "Error: Could not reload fstab. Please check manually."
        fi
    else
        echo "Skipping fstab configuration."
        return 0
    fi

    # Prompt for VM/Container import
    echo "Do you want to import VM/container configurations? (yes/no)"
    read -r import_configs

    if [[ "$import_configs" =~ ^(yes|y)$ ]]; then
        read -p "Enter the path to the configuration files: " config_path

        if [ -d "$config_path" ]; then
            echo "Importing configurations from $config_path..."

            # Ensure subdirectories exist under /etc/pve
            local vm_dir="/etc/pve/qemu-server"
            local ct_dir="/etc/pve/lxc"
            mkdir -p "$vm_dir" "$ct_dir"

            # Move files into appropriate directories
            for file in "$config_path"/*; do
                if [[ "$file" =~ \.conf$ ]]; then
                    if grep -q 'arch: amd64' "$file"; then
                        mv "$file" "$vm_dir/"
                        echo "Moved VM config to $vm_dir: $(basename "$file")"
                    elif grep -q 'arch: lxc' "$file"; then
                        mv "$file" "$ct_dir/"
                        echo "Moved Container config to $ct_dir: $(basename "$file")"
                    else
                        log_error "Unrecognized file format: $file"
                        echo "Warning: Skipped unrecognized file: $file"
                    fi
                else
                    log_error "Non-config file encountered: $file"
                    echo "Warning: Skipped non-config file: $file"
                fi
            done

            echo "VM/container configurations imported successfully."
        else
            log_error "Invalid configuration path: $config_path"
            echo "Error: The specified path does not exist or is not a directory."
        fi
    else
        echo "Skipping VM/container configuration import."
    fi
}

# Example main function to test the setup script
main() {
    # Ensure the log file is writable
    if ! touch "$LOG_FILE"; then
        echo "Error: Cannot write to log file at $LOG_FILE. Check permissions."
        exit 1
    fi

    install_ntfs3g
    import_zfs_pool
    add_fstab_and_import
}

main
