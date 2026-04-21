#!/bin/bash

# --- Configuration ---
NVIDIA_VERSION="550.163.01"
# LINK: https://www.nvidia.com/download/driverResults.aspx/224052/en-us/ 
# (Update the variable below if you want the script to curl it automatically)
NVIDIA_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/550.163.01/NVIDIA-Linux-x86_64-550.163.01.run"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

# --- Function: Install Packages ---
install_packages() {
    local packages=("ntfs-3g" "sudo" "net-tools" "gcc" "make" "perl" "samba" "cifs-utils" "winbind" "curl" "git" "bzip2" "tar" "nut" "nut-client" "nut-server")
    
    echo "--- Phase 1: OS Packages ---"
    apt-get update
    if apt-get install -y "${packages[@]}"; then
        echo "Base packages and NUT installed."
    else
        echo "Error: Package installation failed."
        exit 1
    fi

    echo "--- Phase 2: Nvidia Environment ---"
    # Essential for building the kernel module
    apt-get install -y pve-headers-$(uname -r) dkms

    echo "Attempting to install Nvidia $NVIDIA_VERSION via repository..."
    apt-get install -y nvidia-driver-550=550.163.01 || {
        echo "Repository install failed. Manual download required."
        echo "URL: $NVIDIA_URL"
        # Optional: Uncomment below to auto-download if apt fails
        # curl -L $NVIDIA_URL -o /tmp/nvidia.run
        # chmod +x /tmp/nvidia.run
        # /tmp/nvidia.run --silent --dkms
    }
}

# --- Function: Restore Files ---
restore_files() {
    echo "--- Phase 3: File Restoration ---"
    read -p "Enter full path to the backup .tar.gz file: " BACKUP_FILE

    if [ ! -f "$BACKUP_FILE" ]; then
        echo "Error: File not found."
        return
    fi

    echo "Stopping PVE cluster (unlocking /etc/pve)..."
    systemctl stop pve-cluster

    echo "Extracting files to original locations..."
    # --absolute-names is critical here
    tar -xzf "$BACKUP_FILE" --absolute-names

    if [ -f "/tmp/root_crontab" ]; then
        echo "Restoring crontab..."
        crontab /tmp/root_crontab
    fi

    if [ -d "/home/lindsay" ]; then
        echo "Correcting ownership for /home/lindsay..."
        chown -R lindsay:lindsay /home/lindsay
    fi

    echo "Restarting PVE cluster..."
    systemctl start pve-cluster
}

# --- Main Menu ---
show_menu() {
    echo "=========================================="
    echo "   PVE SYSTEM REBUILDER (v550.163.01)"
    echo "=========================================="
    echo "1) Full Rebuild (Packages + Driver + Files)"
    echo "2) Install Packages & Nvidia Only"
    echo "3) Restore Files Only"
    echo "4) Exit"
    echo "------------------------------------------"
    read -p "Select an option [1-4]: " CHOICE

    case $CHOICE in
        1) install_packages; restore_files ;;
        2) install_packages ;;
        3) restore_files ;;
        4) exit 0 ;;
        *) echo "Invalid option."; sleep 1; show_menu ;;
    esac
}

show_menu
echo "Rebuild task complete. Please REBOOT to initialize the GPU and NUT drivers."