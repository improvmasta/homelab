#!/bin/bash

# Determine the sudoer
if [[ $EUID -eq 0 ]]; then
    SUDO_USER_HOME=$(eval echo ~"${SUDO_USER:-root}")
    INSTALL_DIR="$SUDO_USER_HOME/bin"
else
    SUDO_USER_HOME="$HOME"
    INSTALL_DIR="$HOME/bin"
fi

SCRIPT_NAME="backup_sync.sh"
CRON_SCHEDULE="0 0 * * *" # Nightly at midnight
DEFAULT_BACKUP_DIR="/media/vmb/lindsay/Documents/GitHub/homelab/proxmox"

# Prompt for the backup directory
read -rp "Enter the backup directory path [$DEFAULT_BACKUP_DIR]: " BACKUP_DIR
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"

# Ensure the install directory exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Creating directory for scripts: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR" || { echo "Error: Failed to create $INSTALL_DIR"; exit 1; }
fi

# Create the backup sync script
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
cat << 'EOF' > "$SCRIPT_PATH"
#!/bin/bash

# Variables
USERNAME=$(whoami)
HOSTNAME=$(hostname)
LOCAL_DIR="/home/$USERNAME/.docker/compose"
REMOTE_BACKUP_DIR="/media/vmb/lindsay/Documents/GitHub/homelab/proxmox/$HOSTNAME" # Placeholder, replaced dynamically
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOCAL_BACKUP_DIR="$LOCAL_DIR-backup-$TIMESTAMP"
REMOTE_BACKUP_DIR_STAMPED="$REMOTE_BACKUP_DIR-backup-$TIMESTAMP"

# Ensure the remote directory exists
if [[ ! -d "$REMOTE_BACKUP_DIR" ]]; then
    echo "Creating remote directory: $REMOTE_BACKUP_DIR"
    mkdir -p "$REMOTE_BACKUP_DIR" || { echo "Error: Failed to create remote backup directory."; exit 1; }
fi

# Step 1: Create a local backup
echo "Creating local backup: $LOCAL_BACKUP_DIR"
mkdir -p "$LOCAL_BACKUP_DIR"
rsync -av --delete "$LOCAL_DIR/" "$LOCAL_BACKUP_DIR/" || {
    echo "Error: Failed to create local backup."
    exit 1
}

# Step 2: Create a remote backup
echo "Creating remote backup: $REMOTE_BACKUP_DIR_STAMPED"
rsync -av --delete "$REMOTE_BACKUP_DIR/" "$REMOTE_BACKUP_DIR_STAMPED/" || {
    echo "Error: Failed to create remote backup."
    exit 1
}

# Step 3: Sync from local to remote
echo "Syncing local to remote: $LOCAL_DIR -> $REMOTE_BACKUP_DIR"
rsync -av --delete "$LOCAL_DIR/" "$REMOTE_BACKUP_DIR/" || {
    echo "Error: Failed to sync local to remote."
    exit 1
}

# Step 4: Sync from remote to local
echo "Syncing remote to local: $REMOTE_BACKUP_DIR -> $LOCAL_DIR"
rsync -av --delete "$REMOTE_BACKUP_DIR/" "$LOCAL_DIR/" || {
    echo "Error: Failed to sync remote to local."
    exit 1
}

echo "Two-way sync with backups complete."
EOF

# Replace placeholder for the remote backup directory
sed -i "s|/media/vmb/lindsay/Documents/GitHub/homelab/proxmox|$BACKUP_DIR|g" "$SCRIPT_PATH"

# Make the script executable
chmod +x "$SCRIPT_PATH"

# Add the script directory to PATH in sudoer's .bashrc if not already included
BASHRC_PATH="$SUDO_USER_HOME/.bashrc"
if ! grep -q "export PATH=\$PATH:$INSTALL_DIR" "$BASHRC_PATH"; then
    echo "Adding $INSTALL_DIR to PATH for $SUDO_USER"
    echo "export PATH=\$PATH:$INSTALL_DIR" >> "$BASHRC_PATH"
fi

# Reload PATH for the sudoer
export PATH="$PATH:$INSTALL_DIR"

# Add a cron job for the script
CRON_JOB="$CRON_SCHEDULE $SCRIPT_PATH"
echo "Setting up nightly cron job for $SUDO_USER: $CRON_JOB"
sudo -u "${SUDO_USER:-root}" bash -c "(crontab -l 2>/dev/null; echo \"$CRON_JOB\") | crontab -"

echo "Setup complete for user $SUDO_USER. The script is installed at $SCRIPT_PATH and runs nightly at midnight."
