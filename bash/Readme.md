Got it. You want to accelerate a Lubuntu live session booted from a slow USB stick by using an NVMe drive as a persistent bcache cache device — and make it so that the cache survives reboots (session persistence). That way, once blocks from the live system are cached, they’ll stay in NVMe and speed up subsequent runs.

Here’s how to approach it:


---

1. Background

bcache sits between a backing device (the slow USB stick with the Lubuntu live system) and a caching device (the NVMe SSD).

When you first boot, reads from USB will populate NVMe cache.

On the next boot, if the live system content hasn’t changed, the cache will still be valid.

Since this is a live environment, we can’t repartition or reformat permanently, so the setup must be scripted at boot.



---

2. Requirements

The NVMe must have a dedicated partition for bcache caching (will be erased when formatted as cache).

The USB stick (live medium) is the backing device.

We need to:

1. Format NVMe partition as bcache cache.


2. Register USB device as backing.


3. Attach them.


4. Mount the resulting /dev/bcache0 in place of the normal USB root.





---

3. Example Bash Script

Here’s a script (/root/setup-bcache.sh) that you can run manually (or via rc.local or systemd service) right after the live session boots.

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


---

4. Notes

Persistence: The cache metadata is stored on the NVMe partition, so across reboots, cached data survives as long as you don’t wipe the cache.

Cache mode choice:

writearound → only cache reads (safe for live USB).

writethrough → writes go to both USB and cache.

Avoid writeback in live sessions, since power loss would desync USB.


Integration: If you want this to auto-run every boot, place it in /etc/rc.local or make a systemd service.



---

⚠️ Caveat: Because this is a live USB system, the root filesystem is typically a squashfs image over aufs/overlayfs. Bcache will accelerate block-level reads of that squashfs file (so program loading gets faster), but not the writable overlay part (tmpfs/overlayfs upperdir). Still, it’s effective.


---

Do you want me to adapt this so that it automatically pivots the live root filesystem (instead of just rebinding), so the whole OS session runs from /dev/bcache0 transparently? That’s a bit more invasive but gives full acceleration.

