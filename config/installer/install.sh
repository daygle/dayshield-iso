#!/usr/bin/env bash
# install.sh - DayShield Firewall OS installer (runs inside the live environment)
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
    EFI_PART="${TARGET_DISK}p2"
    ROOT_PART="${TARGET_DISK}p3"
else
    EFI_PART="${TARGET_DISK}2"
    ROOT_PART="${TARGET_DISK}3"
fi

# ---------------------------------------------------------------------------
# Format
# ---------------------------------------------------------------------------
info "Formatting EFI partition: ${EFI_PART}"
mkfs.fat -F 32 -n "EFI" "${EFI_PART}"

info "Formatting root partition: ${ROOT_PART}"
mkfs.ext4 -F -L "dayshield-root" "${ROOT_PART}"

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
# Clean live-boot artefacts from the installed target
# ---------------------------------------------------------------------------
info "Preparing target chroot environment …"
for _fs in dev dev/pts proc sys run; do
    mkdir -p "${TARGET_MOUNT}/${_fs}"
    mount --bind "/${_fs}" "${TARGET_MOUNT}/${_fs}"
done

cleanup_chroot_mounts() {
    for _fs in run sys proc dev/pts dev; do
        umount -lf "${TARGET_MOUNT}/${_fs}" 2>/dev/null || true
    done
}
trap cleanup_chroot_mounts EXIT

info "Purging live-boot / live-config packages from target …"
chroot "${TARGET_MOUNT}" /bin/sh -c \
    'DEBIAN_FRONTEND=noninteractive apt-get -y --purge remove \
        live-boot live-boot-initramfs-tools \
        live-config live-config-systemd live-config-sysvinit \
        live-tools 2>/dev/null || true'

# Remove any leftover live directories not caught by the package purge
info "Removing leftover live directories …"
rm -rf \
    "${TARGET_MOUNT}/lib/live" \
    "${TARGET_MOUNT}/usr/lib/live" \
    "${TARGET_MOUNT}/etc/live"

# Regenerate a clean initramfs without live-boot hooks
info "Regenerating initramfs inside target …"
chroot "${TARGET_MOUNT}" update-initramfs -u -k all

cleanup_chroot_mounts
trap - EXIT

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
# Network configuration
# ---------------------------------------------------------------------------
info "Writing default network configuration …"
NETWORK_DIR="${TARGET_MOUNT}/etc/systemd/network"
mkdir -p "${NETWORK_DIR}"
cat > "${NETWORK_DIR}/20-wired.network" <<'EOF'
# 20-wired.network - Generated by DayShield installer.
# Enables DHCP on all wired Ethernet interfaces (en*, eth*).
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=no

[DHCP]
RouteMetric=100
EOF

# Enable systemd-networkd on the target by creating the required symlinks
# directly.  Pseudo-filesystem bind mounts were torn down above (after
# update-initramfs), so chroot + systemctl is not available at this point.
SYSTEMD_DIR="${TARGET_MOUNT}/etc/systemd/system"
mkdir -p \
    "${SYSTEMD_DIR}/multi-user.target.wants" \
    "${SYSTEMD_DIR}/sockets.target.wants" \
    "${SYSTEMD_DIR}/network-online.target.wants"
for _unit_dir in /lib/systemd/system /usr/lib/systemd/system; do
    if [[ -f "${TARGET_MOUNT}${_unit_dir}/systemd-networkd.service" ]]; then
        ln -sf "${_unit_dir}/systemd-networkd.service" \
            "${SYSTEMD_DIR}/multi-user.target.wants/systemd-networkd.service" || true
        ln -sf "${_unit_dir}/systemd-networkd.socket" \
            "${SYSTEMD_DIR}/sockets.target.wants/systemd-networkd.socket" || true
        ln -sf "${_unit_dir}/systemd-networkd-wait-online.service" \
            "${SYSTEMD_DIR}/network-online.target.wants/systemd-networkd-wait-online.service" || true
        break
    fi
done

# ---------------------------------------------------------------------------
# Firstboot marker
# ---------------------------------------------------------------------------
info "Creating firstboot marker …"
mkdir -p "${TARGET_MOUNT}/etc/dayshield"
touch "${TARGET_MOUNT}/etc/dayshield/.firstboot"

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
