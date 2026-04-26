#!/bin/sh
# 1. Install dependencies to allow mounting
apk update
apk add kmod-fs-cifs mount-utils

# 2. Setup mount point
mkdir -p /mnt/f
mount -t cifs //10.1.1.3/f /mnt/f -o username=lindsay,password='winter1.',vers=3.0,uid=0,gid=0

# 3. Find latest backup
BACKUP_DIR="/mnt/f/backup/router-10.1.1.1"
LATEST=$(ls -t $BACKUP_DIR/OpenWrt_Full_Backup_*.tar.gz | head -n 1)

# 4. Extract and Install Packages
tar -zxf "$LATEST" -C / etc/user_packages.txt
apk add $(cat /etc/user_packages.txt)

# 5. Restore Config and Reboot
sysupgrade -r "$LATEST"