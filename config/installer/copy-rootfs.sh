#!/usr/bin/env bash
# copy-rootfs.sh - Extract the squashfs live image onto the target root
#                  filesystem mount point.
#
# Usage: copy-rootfs.sh <squashfs.img> <target-mountpoint>

set -euo pipefail

SQUASHFS_IMG="${1:?"Usage: copy-rootfs.sh <squashfs.img> <target-mountpoint>"}"
TARGET_MOUNT="${2:?"Usage: copy-rootfs.sh <squashfs.img> <target-mountpoint>"}"

[[ -f "${SQUASHFS_IMG}" ]] || { echo "ERROR: squashfs not found: ${SQUASHFS_IMG}" >&2; exit 1; }
[[ -d "${TARGET_MOUNT}" ]] || { echo "ERROR: target mountpoint not found: ${TARGET_MOUNT}" >&2; exit 1; }

echo "--> Mounting squashfs read-only …"
SQMOUNT="$(mktemp -d)"
mount -t squashfs -o loop,ro "${SQUASHFS_IMG}" "${SQMOUNT}"
trap 'umount "${SQMOUNT}" 2>/dev/null; rm -rf "${SQMOUNT}"' EXIT

echo "--> Copying rootfs to ${TARGET_MOUNT} …"
# Use rsync for proper handling of special files, symlinks, permissions
if command -v rsync &>/dev/null; then
    rsync -aHAX --numeric-ids --delete \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/run \
        --exclude=/lib/live \
        --exclude=/usr/lib/live \
        --exclude=/etc/live \
        "${SQMOUNT}/" "${TARGET_MOUNT}/"
else
    # Fallback to tar round-trip
    tar -C "${SQMOUNT}" \
        --exclude="./proc" \
        --exclude="./sys" \
        --exclude="./dev" \
        --exclude="./run" \
        --exclude="./lib/live" \
        --exclude="./usr/lib/live" \
        --exclude="./etc/live" \
        -cf - . \
    | tar -C "${TARGET_MOUNT}" \
        --numeric-owner \
        -xf -
fi

# Recreate empty mount point directories
mkdir -p \
    "${TARGET_MOUNT}/proc" \
    "${TARGET_MOUNT}/sys" \
    "${TARGET_MOUNT}/dev" \
    "${TARGET_MOUNT}/run"

umount "${SQMOUNT}"
rm -rf "${SQMOUNT}"
trap - EXIT

echo "--> rootfs copy complete."
