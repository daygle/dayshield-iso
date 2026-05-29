#!/usr/bin/env bash
# partition.sh - Partition a target disk for DayShield's A/B image-based update layout.
#
# Creates a GPT partition table with:
#   1. BIOS boot       (1 MiB,   bios_grub)
#   2. EFI System      (512 MiB, FAT32, DS_EFI)
#   3. Shared BOOT     (2 GiB,   ext4, DAYSHIELD_BOOT) — GRUB + per-slot kernels
#   4. ROOT slot A     (5 GiB,   ext4, DS_ROOT_A)
#   5. ROOT slot B     (5 GiB,   ext4, DS_ROOT_B)
#   6. Persistent /var (rest,    ext4, DS_STATE)
#
# Updates write to the inactive slot; GRUB flips between them via grubenv.
#
# Usage: partition.sh <disk>  e.g. partition.sh /dev/sda

set -euo pipefail

DISK="${1:?"Usage: partition.sh <disk>"}"

[[ -b "${DISK}" ]] || { echo "ERROR: Not a block device: ${DISK}" >&2; exit 1; }

DISK_SIZE_MIB="$(( $(blockdev --getsize64 "${DISK}") / 1024 / 1024 ))"
# 1 + 512 + 2048 + 5120 + 5120 + 4096 (min /var) = 16897 MiB → round to 17 GiB minimum.
MIN_DISK_SIZE_MIB=17408
if (( DISK_SIZE_MIB < MIN_DISK_SIZE_MIB )); then
    echo "ERROR: ${DISK} is too small (${DISK_SIZE_MIB} MiB). Need at least ${MIN_DISK_SIZE_MIB} MiB (17 GiB)." >&2
    exit 1
fi

echo "--> Wiping existing partition table on ${DISK} …"
dd if=/dev/zero of="${DISK}" bs=1M count=4 conv=fsync 2>/dev/null
dd if=/dev/zero of="${DISK}" bs=1M count=4 \
    seek=$(( $(blockdev --getsz "${DISK}") / 2048 - 4 )) \
    conv=fsync 2>/dev/null || true

echo "--> Creating A/B GPT partition table on ${DISK} …"
parted --script "${DISK}" \
    mklabel gpt \
    mkpart "BIOS"   1MiB     2MiB \
    set 1 bios_grub on \
    mkpart "EFI"    fat32    2MiB     514MiB \
    set 2 esp on \
    mkpart "BOOT"   ext4     514MiB   2562MiB \
    mkpart "ROOT_A" ext4     2562MiB  7682MiB \
    mkpart "ROOT_B" ext4     7682MiB  12802MiB \
    mkpart "STATE"  ext4     12802MiB 100%

partprobe "${DISK}" 2>/dev/null || true
udevadm settle 2>/dev/null || true

echo "--> Partitions created:"
parted --script "${DISK}" print
