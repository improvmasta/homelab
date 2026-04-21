#!/bin/bash

# --- Configuration ---
BACKUP_DIR="/media/f/backup/vm/prox-10.1.1.2/"  # Ensure this mount point is active
DATE=$(date +%Y-%m-%d)
DAY_OF_WEEK=$(date +%u) 
DAY_OF_MONTH=$(date +%d)

# Create directory structure
mkdir -p $BACKUP_DIR/{daily,weekly,monthly}

# --- Pre-Backup Tasks ---
# Dump the root crontab so we have a flat file to restore from
crontab -l > /tmp/root_crontab

# --- Define the Targets ---
TARGETS=(
    # --- The "Surgical" List ---
    "/etc/pve"                             # PVE Cluster Configs
    "/var/lib/pve-cluster/config.db"       # The actual PVE Database
    "/etc/udev/rules.d/99-nvidia-dri.rules" # Nvidia Device Rules
    "/etc/rc.local"                        # Startup Scripts
    "/usr/local/bin"                       # Custom Scripts
    "/etc/nut"                             # UPS Configs
    "/bin/upssched-cmd"                    # UPS Schedule Script
    "/lib/nut/usbhid-ups"                  # Your Custom NUT Driver
    "/etc/fstab"                           # Disk Mounts
    
    # --- The Nvidia/Kernel "Brain" (Added) ---
    "/etc/modprobe.d"                      # Blacklists and GPU Options
    "/etc/modules"                         # Kernel Modules to load at boot
    "/etc/default/grub"                    # (Optional) For IOMMU/Hugepages settings
    
    # --- Personal/User Data ---
    "/root"                                # Root home (SSH keys, etc)
    "/home/lindsay"                        # Lindsay's home
    "/tmp/root_crontab"                    # The crontab dump
)

FILENAME="pve-backup-$DATE.tar.gz"

echo "Starting backup of $(hostname) at $(date)"
echo "Targeting: ${TARGETS[*]}"

# --- Execute Archive ---
# Using --absolute-names to preserve the full path for easier restoration
tar -czf "$BACKUP_DIR/daily/$FILENAME" "${TARGETS[@]}" --absolute-names

# --- Retention Logic ---
# Weekly: If Monday (1), copy to weekly
if [ "$DAY_OF_WEEK" -eq 1 ]; then
    cp "$BACKUP_DIR/daily/$FILENAME" "$BACKUP_DIR/weekly/"
fi

# Monthly: If 1st of the month, copy to monthly
if [ "$DAY_OF_MONTH" -eq "01" ]; then
    cp "$BACKUP_DIR/daily/$FILENAME" "$BACKUP_DIR/monthly/"
fi

# --- Pruning (The Cleanup) ---
# Daily: Keep 7 days
find $BACKUP_DIR/daily/ -type f -mtime +7 -delete
# Weekly: Keep 14 days
find $BACKUP_DIR/weekly/ -type f -mtime +14 -delete
# Monthly: Keep 730 days (2 years)
find $BACKUP_DIR/monthly/ -type f -mtime +730 -delete

echo "Backup Complete: $FILENAME"