#!/bin/bash
set -euo pipefail

# CONFIGURATION
CACHE_DEV="/dev/nvme0n1p1"   # NVMe partition dedicated to cache
BACKING_DEV="/dev/sdb"       # USB stick device (adjust!)
BCACHE_DEV="/dev/bcache0"
TEMP_MOUNT="/mnt/bcache_temp"
BACKUP_ROOT="/mnt/original_root"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Validate devices exist
validate_devices() {
    log "Validating devices..."
    
    if [[ ! -b "$CACHE_DEV" ]]; then
        error "Cache device $CACHE_DEV not found"
    fi
    
    if [[ ! -b "$BACKING_DEV" ]]; then
        error "Backing device $BACKING_DEV not found"
    fi
    
    # Check if devices are mounted
    if mountpoint -q "$CACHE_DEV" 2>/dev/null; then
        error "Cache device $CACHE_DEV is currently mounted"
    fi
    
    if mountpoint -q "$BACKING_DEV" 2>/dev/null; then
        error "Backing device $BACKING_DEV is currently mounted"
    fi
}

# Install bcache tools if needed
install_bcache_tools() {
    if ! command -v make-bcache >/dev/null; then
        log "Installing bcache-tools..."
        if ! sudo apt-get update && sudo apt-get install -y bcache-tools; then
            error "Failed to install bcache-tools"
        fi
    fi
}

# Load bcache module
load_bcache_module() {
    log "Loading bcache kernel module..."
    if ! sudo modprobe bcache; then
        error "Failed to load bcache module"
    fi
}

# Setup bcache devices
setup_bcache() {
    log "Setting up bcache devices..."
    
    # Check if cache device is already a bcache cache
    local cache_exists=false
    if blkid "$CACHE_DEV" | grep -q "TYPE=\"bcache\""; then
        log "Cache device already formatted for bcache"
        cache_exists=true
    fi
    
    # Check if backing device is already a bcache backing device
    local backing_exists=false
    if blkid "$BACKING_DEV" | grep -q "TYPE=\"bcache\""; then
        log "Backing device already formatted for bcache"
        backing_exists=true
    fi
    
    # Create cache device if needed
    if [[ "$cache_exists" == false ]]; then
        log "Formatting cache device $CACHE_DEV..."
        if ! sudo make-bcache -C "$CACHE_DEV" --wipe-bcache; then
            error "Failed to format cache device"
        fi
    fi
    
    # Create backing device if needed
    if [[ "$backing_exists" == false ]]; then
        log "Formatting backing device $BACKING_DEV..."
        if ! sudo make-bcache -B "$BACKING_DEV" --wipe-bcache; then
            error "Failed to format backing device"
        fi
    fi
}

# Register bcache devices
register_devices() {
    log "Registering bcache devices..."
    
    # Register backing device
    if [[ ! -e "$BCACHE_DEV" ]]; then
        log "Registering backing device..."
        if ! echo "$BACKING_DEV" | sudo tee /sys/fs/bcache/register >/dev/null; then
            error "Failed to register backing device"
        fi
        
        # Wait for bcache device to appear
        local count=0
        while [[ ! -b "$BCACHE_DEV" && $count -lt 30 ]]; do
            sleep 1
            ((count++))
        done
        
        if [[ ! -b "$BCACHE_DEV" ]]; then
            error "Bcache device $BCACHE_DEV did not appear after 30 seconds"
        fi
    fi
    
    # Register cache device
    log "Registering cache device..."
    if ! echo "$CACHE_DEV" | sudo tee /sys/fs/bcache/register >/dev/null; then
        warn "Cache device registration failed or already registered"
    fi
}

# Attach cache to backing device
attach_cache() {
    log "Attaching cache to backing device..."
    
    # Get cache UUID
    local cache_uuid
    cache_uuid=$(sudo blkid -s UUID -o value "$CACHE_DEV")
    if [[ -z "$cache_uuid" ]]; then
        error "Could not get cache UUID"
    fi
    
    # Check if already attached
    if [[ -f "/sys/block/bcache0/bcache/cache/cache0/../set" ]]; then
        log "Cache already attached"
        return 0
    fi
    
    # Attach cache
    if ! echo "$cache_uuid" | sudo tee /sys/block/bcache0/bcache/attach >/dev/null; then
        error "Failed to attach cache"
    fi
    
    # Set cache mode to writearound for safety
    log "Setting cache mode to writearound..."
    echo writearound | sudo tee /sys/block/bcache0/bcache/cache_mode >/dev/null
}

# Copy current root to bcache device
copy_root_to_bcache() {
    log "Copying current root filesystem to bcache device..."
    
    # Create temporary mount points
    sudo mkdir -p "$TEMP_MOUNT" "$BACKUP_ROOT"
    
    # Create filesystem on bcache device
    log "Creating ext4 filesystem on bcache device..."
    if ! sudo mkfs.ext4 -F "$BCACHE_DEV"; then
        error "Failed to create filesystem on bcache device"
    fi
    
    # Mount bcache device
    if ! sudo mount "$BCACHE_DEV" "$TEMP_MOUNT"; then
        error "Failed to mount bcache device"
    fi
    
    # Copy root filesystem (excluding some directories)
    log "Copying root filesystem (this may take a while)..."
    if ! sudo rsync -axHAWX --numeric-ids \
        --exclude=/dev \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/tmp \
        --exclude=/run \
        --exclude=/mnt \
        --exclude=/media \
        --exclude="$TEMP_MOUNT" \
        --exclude="$BACKUP_ROOT" \
        / "$TEMP_MOUNT/"; then
        error "Failed to copy root filesystem"
    fi
    
    # Create missing directories
    sudo mkdir -p "$TEMP_MOUNT"/{dev,proc,sys,tmp,run,mnt,media}
    
    # Set proper permissions
    sudo chmod 1777 "$TEMP_MOUNT/tmp"
}

# Safely pivot to new root
pivot_root_safely() {
    log "Preparing to pivot root filesystem..."
    
    # Mount backup point for original root
    if ! sudo mount --bind / "$BACKUP_ROOT"; then
        error "Failed to create backup mount point"
    fi
    
    # Pivot root filesystems
    log "Pivoting root filesystem..."
    if ! sudo pivot_root "$TEMP_MOUNT" "$TEMP_MOUNT$BACKUP_ROOT"; then
        error "Failed to pivot root"
    fi
    
    # Update mount points in new environment
    log "Updating mount points..."
    
    # Remount special filesystems
    sudo mount -t proc proc /proc
    sudo mount -t sysfs sysfs /sys
    sudo mount -t devtmpfs devtmpfs /dev
    sudo mount -t tmpfs tmpfs /run
    sudo mount -t tmpfs tmpfs /tmp
    
    # Optional: unmount old root (be very careful here)
    warn "Old root filesystem is still accessible at $BACKUP_ROOT"
    warn "You can unmount it later with: sudo umount $BACKUP_ROOT"
}

# Create systemd service for persistence (optional)
create_persistence_service() {
    log "Creating systemd service for bcache persistence..."
    
    cat << 'EOF' | sudo tee /etc/systemd/system/bcache-setup.service >/dev/null
[Unit]
Description=Setup bcache on boot
After=local-fs-pre.target
Before=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'modprobe bcache && echo /dev/sdb > /sys/fs/bcache/register && echo /dev/nvme0n1p1 > /sys/fs/bcache/register'
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable bcache-setup.service
}

# Main execution
main() {
    log "Starting bcache live root pivot..."
    
    # Sanity checks
    if [[ $EUID -eq 0 ]]; then
        error "Do not run this script as root directly. Use sudo for individual commands."
    fi
    
    if [[ ! -f /etc/debian_version ]] && [[ ! -f /etc/ubuntu-version ]]; then
        warn "This script is designed for Debian/Ubuntu systems"
    fi
    
    # Confirm action
    warn "This script will:"
    warn "1. Set up bcache using $CACHE_DEV (cache) and $BACKING_DEV (backing)"
    warn "2. Copy your entire root filesystem to the bcache device"
    warn "3. Pivot the root filesystem to use bcache"
    warn ""
    warn "This is a potentially dangerous operation!"
    
    read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm
    if [[ "$confirm" != "yes" ]]; then
        error "Operation cancelled by user"
    fi
    
    # Execute setup steps
    validate_devices
    install_bcache_tools
    load_bcache_module
    setup_bcache
    register_devices
    attach_cache
    copy_root_to_bcache
    pivot_root_safely
    create_persistence_service
    
    log "Bcache live root pivot completed successfully!"
    log "Cache device: $CACHE_DEV"
    log "Backing device: $BACKING_DEV"
    log "Bcache device: $BCACHE_DEV"
    log ""
    log "Your system is now running from the bcache device."
    log "Reboot to ensure everything works correctly."
}

# Run main function
main "$@"
