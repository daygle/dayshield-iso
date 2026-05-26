#!/usr/bin/env bash
# upgrade-rootfs.sh - Stage an ISO OSTree deployment onto an existing DayShield install.
#
# Usage: upgrade-rootfs.sh <disk> <filesystem.squashfs>

set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DISK="${1:?"Usage: upgrade-rootfs.sh <disk> <filesystem.squashfs>"}"
SQUASHFS_IMG="${2:?"Usage: upgrade-rootfs.sh <disk> <filesystem.squashfs>"}"
TARGET_MOUNT="/mnt/target"
STAGING_MOUNT=""
BOOT_MOUNTED=0
EFI_MOUNTED=0
STATE_MOUNTED=0

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

cleanup() {
    umount -lf "${TARGET_MOUNT}/run" 2>/dev/null || true
    umount -lf "${TARGET_MOUNT}/sys" 2>/dev/null || true
    umount -lf "${TARGET_MOUNT}/proc" 2>/dev/null || true
    umount -lf "${TARGET_MOUNT}/dev/pts" 2>/dev/null || true
    umount -lf "${TARGET_MOUNT}/dev" 2>/dev/null || true
    if (( EFI_MOUNTED )); then
        umount -lf "${TARGET_MOUNT}/boot/efi" 2>/dev/null || true
    fi
    if (( BOOT_MOUNTED )); then
        umount -lf "${TARGET_MOUNT}/boot" 2>/dev/null || true
    fi
    if (( STATE_MOUNTED )); then
        umount -lf "${TARGET_MOUNT}/var" 2>/dev/null || true
    fi
    umount -lf "${TARGET_MOUNT}" 2>/dev/null || true
    if [[ -n "${STAGING_MOUNT}" ]]; then
        umount -lf "${STAGING_MOUNT}" 2>/dev/null || true
        rmdir "${STAGING_MOUNT}" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

device_parent_disk() {
    local dev="$1" pkname
    pkname="$(lsblk -ndo PKNAME "${dev}" 2>/dev/null || true)"
    if [[ -n "${pkname}" ]]; then
        printf '/dev/%s\n' "${pkname}"
    else
        printf '%s\n' "${dev}" | sed -E 's/p?[0-9]+$//'
    fi
}

require_on_target_disk() {
    local dev="$1" parent
    parent="$(device_parent_disk "${dev}")"
    [[ "${parent}" == "${TARGET_DISK}" ]] || error "${dev} does not belong to selected disk ${TARGET_DISK}"
}

label_device() {
    blkid -L "$1" 2>/dev/null || true
}

resolve_partition() {
    local part_name="$1" legacy_label="$2" dev
    dev="$(label_device "${part_name}")"
    [[ -n "${dev}" ]] || dev="$(label_device "${legacy_label}")"
    printf '%s\n' "${dev}"
}

resolve_efi_partition() {
    local efi_dev
    efi_dev="$(lsblk -nr -o NAME,PARTTYPE "${TARGET_DISK}" 2>/dev/null \
        | awk 'tolower($2) ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b|ef00/ { print "/dev/" $1; exit }')"
    if [[ -z "${efi_dev}" ]]; then
        if [[ "${TARGET_DISK}" =~ (nvme|mmcblk) ]]; then
            efi_dev="${TARGET_DISK}p2"
        else
            efi_dev="${TARGET_DISK}2"
        fi
    fi
    printf '%s\n' "${efi_dev}"
}

detect_staging_ostree_ref() {
    local ref
    ref="${DAYSHIELD_OSTREE_REF:-}"
    if [[ -n "${ref}" ]]; then
        printf '%s\n' "${ref}"
        return 0
    fi
    ref="$(ostree --repo="${STAGING_MOUNT}/ostree/repo" refs --list 2>/dev/null | head -n1 || true)"
    printf '%s\n' "${ref}"
}

stage_ostree_upgrade() {
    local osname ref
    osname="${DAYSHIELD_OSTREE_OSNAME:-dayshield}"
    ref="$(detect_staging_ostree_ref)"
    [[ -n "${ref}" ]] || error "Could not determine OSTree ref from staged ISO rootfs. Set DAYSHIELD_OSTREE_REF."

    info "Pulling staged OSTree commit '${ref}' into target sysroot ..."
    ostree --repo="${TARGET_MOUNT}/ostree/repo" pull-local "${STAGING_MOUNT}/ostree/repo" "${ref}"

    info "Ensuring stateroot '${osname}' exists ..."
    if ! ostree admin --sysroot="${TARGET_MOUNT}" os-init "${osname}" 2>/dev/null; then
        info "Stateroot '${osname}' already initialized."
    fi

    info "Deploying staged OSTree ref '${ref}' for next boot ..."
    ostree admin --sysroot="${TARGET_MOUNT}" deploy --os="${osname}" "${ref}"

    mkdir -p "${TARGET_MOUNT}/var/lib/dayshield/update"
    cat > "${TARGET_MOUNT}/var/lib/dayshield/update/ostree-iso-stage.json" <<EOF
{
  "status": "staged",
  "ref": "${ref}",
  "osname": "${osname}",
  "source": "iso",
  "preparedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

[[ -b "${TARGET_DISK}" ]] || error "Not a block device: ${TARGET_DISK}"
[[ -f "${SQUASHFS_IMG}" ]] || error "Rootfs squashfs not found: ${SQUASHFS_IMG}"
command -v ostree >/dev/null 2>&1 || error "ostree CLI is required in the live environment for upgrade mode."

ROOT_DEV="$(label_device DS_SYSROOT)"
BOOT_DEV="$(resolve_partition DAYSHIELD_BOOT DAYSHIELD_BOOT)"
STATE_DEV="$(resolve_partition DS_STATE DAYSHIELD_STATE)"
EFI_DEV="$(resolve_efi_partition)"

[[ -n "${ROOT_DEV}" && -n "${BOOT_DEV}" ]] || \
    error "No compatible DayShield OSTree layout found. Expected DS_SYSROOT and DAYSHIELD_BOOT labels."
[[ -b "${EFI_DEV}" ]] || error "EFI partition not found on ${TARGET_DISK}"

require_on_target_disk "${ROOT_DEV}"
require_on_target_disk "${BOOT_DEV}"
require_on_target_disk "${EFI_DEV}"
if [[ -n "${STATE_DEV}" ]]; then
    require_on_target_disk "${STATE_DEV}"
fi

mkdir -p "${TARGET_MOUNT}"
mount "${ROOT_DEV}" "${TARGET_MOUNT}"

mkdir -p "${TARGET_MOUNT}/boot"
mount "${BOOT_DEV}" "${TARGET_MOUNT}/boot"
BOOT_MOUNTED=1

mkdir -p "${TARGET_MOUNT}/boot/efi"
mount "${EFI_DEV}" "${TARGET_MOUNT}/boot/efi"
EFI_MOUNTED=1

if [[ -n "${STATE_DEV}" ]]; then
    mkdir -p "${TARGET_MOUNT}/var"
    mount "${STATE_DEV}" "${TARGET_MOUNT}/var"
    STATE_MOUNTED=1
fi

STAGING_MOUNT="$(mktemp -d)"
mount -t tmpfs -o size=3G none "${STAGING_MOUNT}"

info "Extracting ISO rootfs to temporary staging area ..."
"${INSTALLER_DIR}/copy-rootfs.sh" "${SQUASHFS_IMG}" "${STAGING_MOUNT}"
[[ -d "${STAGING_MOUNT}/ostree/repo" ]] || error "Staged rootfs does not contain /ostree/repo."
[[ -d "${TARGET_MOUNT}/ostree/repo" ]] || error "Target sysroot does not contain /ostree/repo."

if [[ -n "${STATE_DEV}" ]] && [[ -d "${STAGING_MOUNT}/var" ]]; then
    rsync -aHAX --numeric-ids "${STAGING_MOUNT}/var/" "${TARGET_MOUNT}/var/"
fi

for _fs in dev dev/pts proc sys run; do
    mkdir -p "${TARGET_MOUNT}/${_fs}"
    mount --bind "/${_fs}" "${TARGET_MOUNT}/${_fs}"
done

stage_ostree_upgrade

info "Regenerating GRUB menu for staged deployment ..."
chroot "${TARGET_MOUNT}" grub-mkconfig -o /boot/grub/grub.cfg

sync
info "OSTree upgrade staged successfully. Reboot to boot the new deployment."
