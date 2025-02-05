#!/bin/bash

DISK=sdb1
MOUNT_POINT=/mnt/data
FILESYSTEM_TYPE="ext4"


mkdir -p "$MOUNT_POINT"
UUID=$(blkid -s UUID -o value "/dev/$DISK")
if [ -z "$UUID" ]; then
    echo "Failed to get UUID for /dev/$DISK. Exiting."
    exit 1
fi
echo "UUID=$UUID $MOUNT_POINT $FILESYSTEM_TYPE defaults,nofail 0 2" | tee -a /etc/fstab > /dev/null

mount -a
if [ $? -eq 0 ]; then
    echo "Disk successfully mounted at $MOUNT_POINT."
else
    echo "Failed to mount disk. Check /etc/fstab and system logs."
    exit 1
fi
