#!/bin/bash
set -e

# CONFIGURATION
CACHE_DEV="/dev/nvme0n1p1"   # NVMe partition dedicated to cache
BACKING_DEV="/dev/sdb"       # USB stick device (adjust!)
BCACHE_DEV="/dev/bcache0"

# Make sure bcache tools are available
if ! command -v make-bcache >/dev/null; then
    echo "Installing bcache-tools..."
    sudo apt-get update
    sudo apt-get install -y bcache-tools
fi

# Load kernel module
sudo modprobe bcache

# If cache has already been set up in a previous boot, just register devices
if [ ! -e /sys/fs/bcache/$(blkid -s UUID -o value $CACHE_DEV) ]; then
    echo "Formatting cache device..."
    sudo make-bcache -C $CACHE_DEV --wipe-bcache
fi

if [ ! -e /sys/block/bcache0 ]; then
    echo "Registering devices..."
    echo $BACKING_DEV | sudo tee /sys/fs/bcache/register
    echo $CACHE_DEV   | sudo tee /sys/fs/bcache/register
fi

# Wait for /dev/bcache0
for i in {1..10}; do
    [ -b $BCACHE_DEV ] && break
    sleep 1
done

# Attach cache to backing
BACK_UUID=$(blkid -s UUID -o value $BACKING_DEV)
CACHE_UUID=$(blkid -s UUID -o value $CACHE_DEV)
echo $CACHE_UUID | sudo tee /sys/block/bcache0/bcache/attach

# Set cache mode (writearound for safety in live)
echo writearound | sudo tee /sys/block/bcache0/bcache/cache_mode

# Remount root filesystem through bcache if possible
ROOT_MNT=$(findmnt -n -o TARGET /)
if mountpoint -q "$ROOT_MNT"; then
    echo "Switching root to bcache device..."
    sudo mount --bind $BCACHE_DEV $ROOT_MNT
fi

echo "Bcache setup complete. Using $CACHE_DEV to accelerate $BACKING_DEV."
