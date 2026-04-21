#!/bin/bash

# --- Configuration ---
BACKUP_DIR="/media/f/backup/vm/prox-10.1.1.2/raid"
DATE=$(date +%Y-%m-%d)

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

mkdir -p "$BACKUP_DIR"

# --- Backup Function ---
run_backup() {
    echo "$(date) : Starting RAID Metadata Backup..."
    
    # 1. Capture blkid (The UUID 'Phonebook')
    blkid > "$BACKUP_DIR/blkid-$DATE.txt"
    
    # 2. Capture lsblk (The Physical Map)
    lsblk -e 7 -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT > "$BACKUP_DIR/lsblk-$DATE.txt"
    
    # 3. Capture mdadm (Software RAID)
    if [ -d /etc/mdadm ]; then
        cp /etc/mdadm/mdadm.conf "$BACKUP_DIR/mdadm-$DATE.conf"
        mdadm --detail --scan >> "$BACKUP_DIR/mdadm-$DATE.conf"
    fi

    # 4. Capture ZFS (Pool Layout)
    if command -v zpool >/dev/null; then
        zpool status > "$BACKUP_DIR/zpool-$DATE.txt"
        zpool export -p > "$BACKUP_DIR/zpool-import-map-$DATE.txt" 2>/dev/null
    fi

    # 5. Prune (Keep 30 days of metadata)
    find "$BACKUP_DIR" -type f -mtime +30 -delete
    echo "RAID Metadata saved to $BACKUP_DIR"
}

# --- Restore Functions ---
select_backup_date() {
    echo "--- Last 5 RAID Backups ---"
    mapfile -t LIST < <(ls -1t "$BACKUP_DIR"/blkid-*.txt | head -n 5)
    
    if [ ${#LIST[@]} -eq 0 ]; then echo "No backups found."; exit 1; fi

    for i in "${!LIST[@]}"; do
        echo "$((i+1))) $(basename "${LIST[$i]}" | sed 's/blkid-//;s/.txt//')"
    done

    read -p "Select backup date [1-${#LIST[@]}]: " CHOICE
    # Validate
    if [[ "$CHOICE" -lt 1 || "$CHOICE" -gt ${#LIST[@]} ]]; then exit 1; fi
    
    SEL_DATE=$(basename "${LIST[$((CHOICE-1))]}" | sed 's/blkid-//;s/.txt//')
}

restore_raid() {
    select_backup_date
    echo "--- Restoring RAID from $SEL_DATE ---"
    
    # mdadm restore
    if [ -f "$BACKUP_DIR/mdadm-$SEL_DATE.conf" ]; then
        echo "[*] Applying mdadm.conf..."
        cp "$BACKUP_DIR/mdadm-$SEL_DATE.conf" /etc/mdadm/mdadm.conf
        mdadm --assemble --scan
    fi

    # ZFS restore
    if command -v zpool >/dev/null; then
        echo "[*] Importing ZFS Pools..."
        zpool import -a -f
    fi
    
    echo "RAID tasks complete. Run 'lsblk' to verify mounts."
}

view_map() {
    select_backup_date
    cat "$BACKUP_DIR/lsblk-$SEL_DATE.txt"
}

# --- Execution ---

# Silent Mode check
if [[ "$1" == "backup" ]]; then
    run_backup
    exit 0
fi

# Menu Mode
clear
echo "=========================================="
echo "    RAID METADATA MANAGER"
echo "=========================================="
echo "1) Backup RAID Metadata"
echo "2) Restore/Assemble RAID (Select from last 5)"
echo "3) View Historical Disk Map"
echo "4) Exit"
echo "------------------------------------------"
read -p "Selection: " MAIN

case $MAIN in
    1) run_backup ;;
    2) restore_raid ;;
    3) view_map ;;
    4) exit 0 ;;
    *) echo "Invalid option." ;;
esac