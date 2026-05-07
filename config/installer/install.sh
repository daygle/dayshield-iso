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
TARGET_MOUNT="/mnt/target"
LOG_FILE="/tmp/dayshield-install.log"
INSTALL_HOSTNAME=""
INSTALL_ROOT_PASSWORD=""
INSTALL_WAN_IFACE=""
INSTALL_LAN_IFACE=""

# Locate the squashfs on the live medium (path varies by live-boot version)
SQUASHFS_IMG="$(find /run/live/medium/live /lib/live/mount/medium/live -name 'filesystem.squashfs' 2>/dev/null | head -n1 || true)"
if [[ -z "${SQUASHFS_IMG}" ]] || [[ ! -f "${SQUASHFS_IMG}" ]]; then
    echo "[ERROR] Cannot locate filesystem.squashfs on the live medium. Checked: /run/live/medium/live and /lib/live/mount/medium/live" >&2
    exit 1
fi

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

valid_hostname() {
    local hostname="$1"
    [[ "${hostname}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

valid_iface_name() {
    local iface="$1"
    [[ "${iface}" =~ ^[[:alnum:]_.:-]+$ ]]
}

collect_install_configuration() {
    local unattended="${DAYSHIELD_UNATTENDED:-0}"
    local _wan_idx _lan_idx

    # Hostname
    INSTALL_HOSTNAME="${DAYSHIELD_HOSTNAME:-}"
    if [[ -z "${INSTALL_HOSTNAME}" ]]; then
        if [[ "${unattended}" == "1" ]]; then
            INSTALL_HOSTNAME="dayshield"
        else
            read -rp "Hostname [dayshield]: " INSTALL_HOSTNAME
            INSTALL_HOSTNAME="${INSTALL_HOSTNAME:-dayshield}"
        fi
    fi
    valid_hostname "${INSTALL_HOSTNAME}" || \
        error "Invalid hostname '${INSTALL_HOSTNAME}'. Use letters, digits, and '-' only."

    # Root password
    INSTALL_ROOT_PASSWORD="${DAYSHIELD_ROOT_PASSWORD:-}"
    if [[ -z "${INSTALL_ROOT_PASSWORD}" ]]; then
        if [[ "${unattended}" == "1" ]]; then
            error "DAYSHIELD_ROOT_PASSWORD is required when DAYSHIELD_UNATTENDED=1."
        fi

        local pass1="" pass2=""
        while true; do
            read -rsp "Set root password: " pass1
            echo ""
            read -rsp "Confirm root password: " pass2
            echo ""
            [[ -n "${pass1}" ]] || { warn "Password cannot be empty."; continue; }
            [[ "${pass1}" == "${pass2}" ]] || { warn "Passwords do not match."; continue; }
            INSTALL_ROOT_PASSWORD="${pass1}"
            break
        done
    fi

    # Interface selection
    mapfile -t _ifaces < <(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -v '^lo$' | sort)
    [[ ${#_ifaces[@]} -ge 2 ]] || error "At least two non-loopback network interfaces are required."

    INSTALL_WAN_IFACE="${DAYSHIELD_WAN_IFACE:-}"
    INSTALL_LAN_IFACE="${DAYSHIELD_LAN_IFACE:-}"

    if [[ -z "${INSTALL_WAN_IFACE}" ]]; then
        if [[ "${unattended}" == "1" ]]; then
            INSTALL_WAN_IFACE="${_ifaces[0]}"
        else
            echo ""
            echo "Available network interfaces:"
            for i in "${!_ifaces[@]}"; do
                echo "  [$i] ${_ifaces[$i]}"
            done
            read -rp "Select WAN interface [0]: " _wan_idx
            _wan_idx="${_wan_idx:-0}"
            [[ "${_wan_idx}" =~ ^[0-9]+$ ]] || error "Invalid WAN interface index: ${_wan_idx}"
            [[ "${_wan_idx}" -lt "${#_ifaces[@]}" ]] || error "WAN interface index out of range: ${_wan_idx}"
            INSTALL_WAN_IFACE="${_ifaces[${_wan_idx}]}"
        fi
    fi

    if [[ -z "${INSTALL_LAN_IFACE}" ]]; then
        if [[ "${unattended}" == "1" ]]; then
            INSTALL_LAN_IFACE="${_ifaces[1]}"
        else
            read -rp "Select LAN interface [1]: " _lan_idx
            _lan_idx="${_lan_idx:-1}"
            [[ "${_lan_idx}" =~ ^[0-9]+$ ]] || error "Invalid LAN interface index: ${_lan_idx}"
            [[ "${_lan_idx}" -lt "${#_ifaces[@]}" ]] || error "LAN interface index out of range: ${_lan_idx}"
            INSTALL_LAN_IFACE="${_ifaces[${_lan_idx}]}"
        fi
    fi

    valid_iface_name "${INSTALL_WAN_IFACE}" || error "Invalid WAN interface name: ${INSTALL_WAN_IFACE}"
    valid_iface_name "${INSTALL_LAN_IFACE}" || error "Invalid LAN interface name: ${INSTALL_LAN_IFACE}"
    [[ "${INSTALL_WAN_IFACE}" != "${INSTALL_LAN_IFACE}" ]] || error "WAN and LAN interfaces must be different."
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

collect_install_configuration
info "Install configuration:"
info "  hostname : ${INSTALL_HOSTNAME}"
info "  WAN iface: ${INSTALL_WAN_IFACE}"
info "  LAN iface: ${INSTALL_LAN_IFACE}"

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
[[ -b "${EFI_PART}" ]]  || error "EFI partition device not found: ${EFI_PART}"
[[ -b "${ROOT_PART}" ]] || error "Root partition device not found: ${ROOT_PART}"

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
chroot "${TARGET_MOUNT}" /bin/sh -c 'dpkg --configure -a 2>/dev/null || true'
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

# Write hostname and set root password
info "Configuring hostname and root password …"
printf '%s\n' "${INSTALL_HOSTNAME}" > "${TARGET_MOUNT}/etc/hostname"
if grep -q '^127\.0\.1\.1[[:space:]]' "${TARGET_MOUNT}/etc/hosts" 2>/dev/null; then
    awk -v host="${INSTALL_HOSTNAME}" '
        BEGIN { done=0 }
        /^127\.0\.1\.1[[:space:]]/ { print "127.0.1.1 " host; done=1; next }
        { print }
        END { if (!done) print "127.0.1.1 " host }
    ' "${TARGET_MOUNT}/etc/hosts" > "${TARGET_MOUNT}/etc/hosts.tmp"
    mv "${TARGET_MOUNT}/etc/hosts.tmp" "${TARGET_MOUNT}/etc/hosts"
else
    printf '127.0.1.1 %s\n' "${INSTALL_HOSTNAME}" >> "${TARGET_MOUNT}/etc/hosts"
fi
printf 'root:%s\n' "${INSTALL_ROOT_PASSWORD}" | chroot "${TARGET_MOUNT}" chpasswd
unset INSTALL_ROOT_PASSWORD

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
info "Writing network configuration …"
NETWORK_DIR="${TARGET_MOUNT}/etc/systemd/network"
mkdir -p "${NETWORK_DIR}"

# 10-wan.network — WAN interface with DHCP.
cat > "${NETWORK_DIR}/10-wan.network" <<EOF
# 10-wan.network - Generated by DayShield installer.
# WAN interface: DHCP on the primary outbound ethernet port.
[Match]
Name=${INSTALL_WAN_IFACE}

[Network]
DHCP=yes
IPv6AcceptRA=no

[DHCP]
RouteMetric=10
UseDNS=yes
EOF

# 20-lan.network — LAN interface with a static address.
cat > "${NETWORK_DIR}/20-lan.network" <<EOF
# 20-lan.network - Generated by DayShield installer.
# LAN interface: static address on the primary inbound ethernet port.
[Match]
Name=${INSTALL_LAN_IFACE}

[Network]
Address=192.168.1.1/24
IPv6AcceptRA=no
EOF

# Enable systemd-networkd on the target by creating the
# required symlinks directly.  Pseudo-filesystem bind mounts were torn down
# above (after update-initramfs), so chroot + systemctl is not available at
# this point.
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

# Mask systemd-resolved; the installed system uses unbound (port 53) as its
# DNS resolver.  Enabling both would cause a port-53 conflict on first boot.
ln -sf /dev/null "${SYSTEMD_DIR}/systemd-resolved.service" 2>/dev/null || true

# Point resolv.conf at 127.0.0.1 (unbound listening on all interfaces).
# systemd-resolved is masked above so its stub resolver at
# /run/systemd/resolve/resolv.conf is never populated; a plain file is safer.
rm -f "${TARGET_MOUNT}/etc/resolv.conf"
printf 'nameserver 127.0.0.1\n' > "${TARGET_MOUNT}/etc/resolv.conf"

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
info "Syncing filesystems …"
sync
info "Unmounting target …"
umount -R "${TARGET_MOUNT}"

info "Installation complete. Remove the installation medium and reboot."
