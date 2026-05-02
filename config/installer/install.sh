#!/usr/bin/env bash
# install.sh — DayShield Firewall OS installer (runs inside the live environment)
#
# This script orchestrates the full installation:
#   1. Detect or prompt for target disk
#   2. Partition the disk
#   3. Format and mount partitions
#   4. Extract the rootfs squashfs
#   5. Install and configure the bootloader
#   6. Write machine-id and enable firstboot.service
#
# Must be run as root.

set -euo pipefail

INSTALLER_DIR="/usr/lib/dayshield-installer"
SQUASHFS_IMG="/live/filesystem.squashfs"
TARGET_MOUNT="/mnt/target"
LOG_FILE="/tmp/dayshield-install.log"

# Redirect output to log
exec > >(tee -a "${LOG_FILE}") 2>&1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || error "This installer must be run as root."
}

detect_target_disk() {
    # Look for block devices that are not the live medium
    local disks
    disks="$(lsblk -d -n -o NAME,TYPE,RM \
             | awk '$2=="disk" && $3=="0" {print "/dev/" $1}')"

    # Exclude the current boot device (the ISO)
    local boot_dev
    boot_dev="$(lsblk -n -o NAME,MOUNTPOINT \
                | awk '$2=="/run/live/medium" || $2=="/media/cdrom" {print $1}' \
                | head -n1 | sed 's/[0-9]*$//' || true)"

    local candidates=()
    while IFS= read -r dev; do
        [[ -n "${boot_dev}" ]] && [[ "${dev}" == *"${boot_dev}"* ]] && continue
        candidates+=("${dev}")
    done <<< "${disks}"

    if [[ ${#candidates[@]} -eq 0 ]]; then
        error "No suitable target disk detected."
    fi

    if [[ ${#candidates[@]} -eq 1 ]]; then
        TARGET_DISK="${candidates[0]}"
        info "Target disk auto-detected: ${TARGET_DISK}"
    else
        echo ""
        echo "Available disks:"
        for i in "${!candidates[@]}"; do
            SIZE="$(lsblk -d -n -o SIZE "${candidates[$i]}" 2>/dev/null || echo '?')"
            echo "  [$i] ${candidates[$i]}  ${SIZE}"
        done
        read -rp "Select disk [0]: " sel
        sel="${sel:-0}"
        TARGET_DISK="${candidates[${sel}]}"
        info "Selected target disk: ${TARGET_DISK}"
    fi
}

# ---------------------------------------------------------------------------
# Main installation flow
# ---------------------------------------------------------------------------
require_root

TARGET_DISK="${DAYSHIELD_TARGET_DISK:-}"

if [[ -z "${TARGET_DISK}" ]]; then
    detect_target_disk
fi

[[ -b "${TARGET_DISK}" ]] || error "Not a block device: ${TARGET_DISK}"

info "Installing DayShield Firewall OS to ${TARGET_DISK}"
info "WARNING: All data on ${TARGET_DISK} will be erased."

# Confirm unless DAYSHIELD_UNATTENDED=1
if [[ "${DAYSHIELD_UNATTENDED:-}" != "1" ]]; then
    read -rp "Type 'yes' to continue: " confirm
    [[ "${confirm}" == "yes" ]] || error "Installation cancelled."
fi

# ---------------------------------------------------------------------------
# Partition
# ---------------------------------------------------------------------------
info "Partitioning ${TARGET_DISK} …"
"${INSTALLER_DIR}/partition.sh" "${TARGET_DISK}"

# Determine partition names (handle nvme, mmcblk naming conventions)
if [[ "${TARGET_DISK}" =~ (nvme|mmcblk) ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

# ---------------------------------------------------------------------------
# Format
# ---------------------------------------------------------------------------
info "Formatting EFI partition: ${EFI_PART}"
mkfs.fat -F 32 -n "EFI" "${EFI_PART}"

info "Formatting root partition: ${ROOT_PART}"
mkfs.ext4 -F -L "dayshield" "${ROOT_PART}"

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------
mkdir -p "${TARGET_MOUNT}"
mount "${ROOT_PART}" "${TARGET_MOUNT}"
mkdir -p "${TARGET_MOUNT}/boot/efi"
mount "${EFI_PART}" "${TARGET_MOUNT}/boot/efi"

# ---------------------------------------------------------------------------
# Extract rootfs
# ---------------------------------------------------------------------------
info "Extracting rootfs squashfs …"
"${INSTALLER_DIR}/copy-rootfs.sh" "${SQUASHFS_IMG}" "${TARGET_MOUNT}"

# ---------------------------------------------------------------------------
# Configure target system
# ---------------------------------------------------------------------------

# Write a fresh machine-id (will be fully regenerated on first boot by systemd)
info "Writing machine-id …"
truncate -s 0 "${TARGET_MOUNT}/etc/machine-id"

# Write fstab
info "Writing /etc/fstab …"
ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
EFI_UUID="$(blkid -s UUID -o value "${EFI_PART}")"
cat > "${TARGET_MOUNT}/etc/fstab" <<EOF
# /etc/fstab - generated by DayShield installer
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0  1
UUID=${EFI_UUID}   /boot/efi  vfat  umask=0077        0  2
tmpfs              /tmp       tmpfs defaults           0  0
EOF

# ---------------------------------------------------------------------------
# Bootloader
# ---------------------------------------------------------------------------
info "Installing bootloader …"
"${INSTALLER_DIR}/configure-bootloader.sh" "${TARGET_DISK}" "${TARGET_MOUNT}"

# ---------------------------------------------------------------------------
# Enable firstboot.service
# ---------------------------------------------------------------------------
info "Enabling firstboot.service …"
SYSTEMD_DIR="${TARGET_MOUNT}/etc/systemd/system"
mkdir -p "${SYSTEMD_DIR}/multi-user.target.wants"
install -m 644 "${INSTALLER_DIR}/firstboot.service" \
    "${SYSTEMD_DIR}/firstboot.service"
ln -sf "/etc/systemd/system/firstboot.service" \
    "${SYSTEMD_DIR}/multi-user.target.wants/firstboot.service"

# ---------------------------------------------------------------------------
# Unmount
# ---------------------------------------------------------------------------
info "Unmounting target …"
umount -R "${TARGET_MOUNT}"

info "Installation complete. Remove the installation medium and reboot."
