#!/bin/bash

BACKUP_DIR="/tmp/full_backup_$(date +%Y%m%d_%H%M%S)"
YEDENECIKTI="$BACKUP_DIR.tar.gz"

log() {
    echo -e "\e[1;32m[+] $*\e[0m"
}

err() {
    echo -e "\e[1;31m[ERROR]\e[0m $*" >&2
    exit 1
}

check_root() {
    [[ $EUID -ne 0 ]] && err "This script must be run as root."
}

# Get remote details
echo -e "\n=== Backup destination info ==="
read -rp "📥 Username (e.g., root): " REMOTE_USER
read -rp "🌐 Remote host (IP/hostname): " REMOTE_HOST
read -rp "📁 Remote path (e.g., /mnt/backups): " REMOTE_PATH

# Select transfer method
echo -e "\n=== Select transfer method ==="
echo "1: SCP"
echo "2: rsync"
echo "3: FTP"
echo "4: Google Drive (rclone)"
echo "5: NFS"
echo "6: SFTP"
read -rp "Enter your choice (1-6): " TRANSFER_METHOD

backup_entire_system() {
    log "📦 Creating full system backup..."
    mkdir -p "$(dirname "$YEDENECIKTI")"
    tar --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/tmp \
        --exclude=/run --exclude=/mnt --exclude=/media --exclude=/lost+found \
        -czf "$YEDENECIKTI" /
    [[ ! -f "$YEDENECIKTI" ]] && err "Backup failed!"
    log "✅ Backup completed!"
}

ftp_transfer() {
    log "📤 Transferring backup via FTP..."
    ftp -inv "$REMOTE_HOST" <<EOF
user $REMOTE_USER
binary
put "$YEDENECIKTI" "$REMOTE_PATH/$(basename "$YEDENECIKTI")"
bye
EOF
    log "✅ FTP transfer complete!"
}

scp_transfer() {
    log "📤 Transferring backup via SCP..."
    scp "$YEDENECIKTI" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
    log "✅ SCP transfer complete!"
}

rsync_transfer() {
    log "📤 Transferring backup via rsync..."
    rsync -avz "$YEDENECIKTI" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
    log "✅ rsync transfer complete!"
}

gdrive_transfer() {
    if ! command -v rclone &>/dev/null; then
        err "rclone is not installed. Please install it first (https://rclone.org/install/)."
    fi
    read -rp "🌐 Enter rclone remote name (e.g., gdrive): " RCLONE_REMOTE
    read -rp "📁 Enter rclone remote path (e.g., backup/fulls): " RCLONE_PATH
    log "📤 Uploading to Google Drive via rclone..."
    rclone copy "$YEDENECIKTI" "$RCLONE_REMOTE:$RCLONE_PATH"
    log "✅ Google Drive upload complete!"
}

nfs_transfer() {
    read -rp "🌐 Enter NFS server and export path (e.g., 192.168.1.10:/export/backups): " NFS_MOUNT
    TMP_MOUNT="/mnt/nfs_temp_mount_$(date +%s)"
    mkdir -p "$TMP_MOUNT"
    log "🔗 Mounting NFS share from $NFS_MOUNT ..."
    
    mount -t nfs "$NFS_MOUNT" "$TMP_MOUNT" || err "❌ Failed to mount NFS share."

    log "📤 Copying backup to NFS share..."
    cp "$YEDENECIKTI" "$TMP_MOUNT/" || err "❌ Failed to copy backup to NFS mount."

    umount "$TMP_MOUNT"
    rmdir "$TMP_MOUNT"
    log "✅ NFS transfer completed and unmounted successfully."
}

sftp_transfer() {
    log "📤 Transferring via SFTP..."
    sftp "$REMOTE_USER@$REMOTE_HOST" <<EOF
cd "$REMOTE_PATH"
put "$YEDENECIKTI"
bye
EOF
    log "✅ SFTP transfer complete!"
}

kullanici_onayi() {
    read -rp "Backup is complete. Continue with disk extension? [y/N]: " onay
    [[ "$onay" != "y" && "$onay" != "Y" ]] && {
        log "🛑 Operation cancelled."
        exit 0
    }
}

is_lvm() {
    [[ "$(findmnt / -o SOURCE -n)" == /dev/mapper/* ]]
}

extend_lvm() {
    log "📦 Extending LVM..."
    VG=$(vgs --noheadings -o vg_name | xargs)
    LV=$(lvs --noheadings -o lv_name | grep -v swap | xargs)
    LV_PATH="/dev/$VG/$LV"
    NEW_DISK=$(lsblk -dpno NAME | grep -v "$(pvs | awk '{print $1}')" | grep -v loop | head -n1)
    [[ -z "$NEW_DISK" ]] && err "No new disk found!"
    pvcreate "$NEW_DISK"
    vgextend "$VG" "$NEW_DISK"
    lvextend -l +100%FREE "$LV_PATH"
    FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
    [[ "$FS_TYPE" == "xfs" ]] && xfs_growfs / || resize2fs "$LV_PATH"
    log "✅ LVM extended."
}

extend_non_lvm() {
    log "📦 Extending non-LVM partition..."
    ROOT_PART=$(findmnt / -o SOURCE -n)
    DISK="/dev/$(lsblk -no pkname "$ROOT_PART")"
    parted "$DISK" resizepart 1 100% <<EOF
Yes
EOF
    partprobe "$DISK"
    sleep 2
    FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
    [[ "$FS_TYPE" == "xfs" ]] && xfs_growfs / || resize2fs "$ROOT_PART"
    log "✅ Non-LVM disk extended."
}

main() {
    check_root
    backup_entire_system

    case "$TRANSFER_METHOD" in
        1) scp_transfer ;;
        2) rsync_transfer ;;
        3) ftp_transfer ;;
        4) gdrive_transfer ;;
        5) nfs_transfer ;;
        6) sftp_transfer ;;
        *) err "Invalid option!" ;;
    esac

    kullanici_onayi

    if is_lvm; then
        extend_lvm
    else
        extend_non_lvm
    fi

    log "🎉 All operations completed successfully."
}

main
