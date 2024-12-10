#!/bin/bash

# Check and install dependencies
install_dependencies() {
    echo "Installing necessary packages..."
    apt update
    apt install -y mdadm xfsprogs mailutils
}

# Function to list available drives
list_drives() {
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E "disk" | awk '{print NR " - /dev/" $1 " (" $2 ")"}'
}

# Function to select a drive
select_drive() {
    list_drives
    read -p "Select a drive number: " drive_num
    drive=$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E "disk" | awk "NR==$drive_num {print \"/dev/\" \$1}")
    echo "$drive"
}

# Function to create an XFS mirror
create_xfs_mirror() {
    echo "Available drives for the mirror:"
    drive1=$(select_drive)
    echo "Selected first drive: $drive1"

    drive2=$(select_drive)
    echo "Selected second drive: $drive2"

    echo "Creating RAID 1 array with $drive1 and $drive2..."
    mdadm --create --verbose /dev/md0 --level=1 --raid-devices=2 "$drive1" "$drive2"

    echo "Formatting RAID 1 array with XFS..."
    mkfs.xfs /dev/md0

    read -p "Enter mount point (e.g., /media/media): " mount_point
    mkdir -p "$mount_point"
    mount /dev/md0 "$mount_point"

    echo "Adding to /etc/fstab..."
    uuid=$(blkid -s UUID -o value /dev/md0)
    echo "UUID=$uuid $mount_point xfs defaults 0 0" >> /etc/fstab

    echo "Saving RAID configuration..."
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u

    echo "RAID 1 array created and mounted at $mount_point."
}

# Function to rebuild the mirror with a new drive
rebuild_xfs_mirror() {
    echo "Current RAID status:"
    cat /proc/mdstat
    mdadm --detail /dev/md0

    echo "Available drives to replace the faulty drive:"
    new_drive=$(select_drive)
    echo "Selected new drive: $new_drive"

    echo "Preparing the new drive..."
    wipefs -a "$new_drive"

    echo "Adding the new drive to the array..."
    mdadm --add /dev/md0 "$new_drive"

    echo "Rebuilding process started. Monitor progress with 'cat /proc/mdstat'."
}

# Function to create a monitoring script
create_monitoring_script() {
    read -p "Enter your email address for notifications: " email

    echo "Creating RAID monitoring script..."
    cat << EOF > /usr/local/bin/check_raid_status.sh
#!/bin/bash
status=\$(cat /proc/mdstat | grep -i "md0" | grep -i "degraded")
if [ -n "\$status" ]; then
    echo "RAID degraded!" | mail -s "RAID Alert" "$email"
fi
EOF

    chmod +x /usr/local/bin/check_raid_status.sh

    echo "Setting up cron job for monitoring..."
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/check_raid_status.sh") | crontab -

    echo "Monitoring script created and scheduled."
}

# Main menu
main_menu() {
    PS3="Select an option: "
    options=("Install Dependencies" "Create XFS Mirror" "Rebuild XFS Mirror" "Create Monitoring Script" "Exit")
    select opt in "${options[@]}"; do
        case $opt in
            "Install Dependencies")
                install_dependencies
                ;;
            "Create XFS Mirror")
                create_xfs_mirror
                ;;
            "Rebuild XFS Mirror")
                rebuild_xfs_mirror
                ;;
            "Create Monitoring Script")
                create_monitoring_script
                ;;
            "Exit")
                break
                ;;
            *)
                echo "Invalid option. Try again."
                ;;
        esac
    done
}

main_menu
