#!/usr/bin/env bash
# partition.sh - Partition a target disk for DayShield.
#
# Creates a GPT partition table with:
#   Partition 1: BIOS boot partition (1 MiB, bios_grub)
#   Partition 2: EFI System Partition (512 MiB, FAT32)
#   Partition 3: Linux root partition  (remainder of disk, ext4)
#
# Usage: partition.sh <disk>  e.g. partition.sh /dev/sda

set -euo pipefail

DISK="${1:?"Usage: partition.sh <disk>"}"

[[ -b "${DISK}" ]] || { echo "ERROR: Not a block device: ${DISK}" >&2; exit 1; }

echo "--> Wiping existing partition table on ${DISK} …"
# Zero out the first and last 4 MiB to destroy existing signatures
dd if=/dev/zero of="${DISK}" bs=1M count=4 conv=fsync 2>/dev/null
dd if=/dev/zero of="${DISK}" bs=1M count=4 \
    seek=$(( $(blockdev --getsz "${DISK}") / 2048 - 4 )) \
    conv=fsync 2>/dev/null || true

echo "--> Creating GPT partition table on ${DISK} …"
parted --script "${DISK}" \
    mklabel gpt \
    mkpart "BIOS" 1MiB   2MiB \
    set 1 bios_grub on \
    mkpart "EFI"  fat32  2MiB   514MiB \
    set 2 esp on \
    mkpart "ROOT" ext4   514MiB 100%

# Inform the kernel of the new partition table
partprobe "${DISK}" 2>/dev/null || true
udevadm settle 2>/dev/null || true   # wait for udev to process new partition events

echo "--> Partitions created:"
parted --script "${DISK}" print
