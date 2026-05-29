#!/usr/bin/env bash
# upgrade-rootfs.sh - Stage an image-based rootfs update from the ISO.
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

json_string_value() {
    local file="$1" key="$2"
    sed -n -E "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" "${file}" | head -n1
}

sanitize_version() {
    local version="$1"
    [[ "${version}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s\n' "${version}"
}

detect_version_from_file() {
    local file="$1" key="$2" value
    [[ -f "${file}" ]] || return 1
    value="$(json_string_value "${file}" "${key}" || true)"
    [[ -n "${value}" ]] || return 1
    sanitize_version "${value}"
}

detect_rootfs_version() {
    local version
    version="${DAYSHIELD_ROOTFS_VERSION:-}"
    if [[ -n "${version}" ]]; then
        sanitize_version "${version}" || error "Invalid DAYSHIELD_ROOTFS_VERSION: ${version}"
        return 0
    fi

    version="$(detect_version_from_file "${STAGING_MOUNT}/usr/local/share/dayshield-updates/rootfs-build-manifest.json" "version" || true)"
    if [[ -n "${version}" ]]; then
        printf '%s\n' "${version}"
        return 0
    fi

    version="$(sed -n -E 's/^VERSION_ID="?([^"]+)"?/\1/p' "${STAGING_MOUNT}/etc/os-release" | head -n1 || true)"
    if [[ -n "${version}" ]]; then
        sanitize_version "${version}" || error "Detected unsupported VERSION_ID from staged rootfs: ${version}"
        return 0
    fi

    error "Could not determine rootfs version from staged rootfs. Set DAYSHIELD_ROOTFS_VERSION."
}

detect_current_rootfs_version() {
    local version
    version="$(detect_version_from_file "${TARGET_MOUNT}/var/lib/dayshield/rootfs-update/current.json" "version" || true)"
    if [[ -n "${version}" ]]; then
        printf '%s\n' "${version}"
        return 0
    fi

    version="$(detect_version_from_file "${TARGET_MOUNT}/usr/local/share/dayshield-updates/rootfs-build-manifest.json" "version" || true)"
    if [[ -n "${version}" ]]; then
        printf '%s\n' "${version}"
        return 0
    fi

    version="$(sed -n -E 's/^VERSION_ID="?([^"]+)"?/\1/p' "${TARGET_MOUNT}/etc/os-release" | head -n1 || true)"
    if [[ -n "${version}" ]]; then
        version="$(sanitize_version "${version}" || true)"
        if [[ -n "${version}" ]]; then
            printf '%s\n' "${version}"
            return 0
        fi
    fi

    printf '%s\n' "unknown"
}

stage_rootfs_image_upgrade() {
    local next_version current_version state_dir image_store rel_image_path previous_version now
    next_version="$(detect_rootfs_version)"
    current_version="$(detect_current_rootfs_version)"
    previous_version=""
    state_dir="${TARGET_MOUNT}/var/lib/dayshield/rootfs-update"
    image_store="${TARGET_MOUNT}/boot/dayshield/images"
    rel_image_path="/boot/dayshield/images/rootfs-${next_version}.squashfs"
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    info "Staging rootfs image version '${next_version}' ..."
    mkdir -p "${image_store}"
    cp -f "${SQUASHFS_IMG}" "${TARGET_MOUNT}${rel_image_path}"
    chmod 644 "${TARGET_MOUNT}${rel_image_path}"

    # Point the boot candidate symlink at the new image
    ln -sfn "images/rootfs-${next_version}.squashfs" "${TARGET_MOUNT}/boot/dayshield/next"

    if [[ "${current_version}" != "${next_version}" && "${current_version}" != "unknown" ]]; then
        previous_version="${current_version}"
    fi

    mkdir -p "${state_dir}"

    # Write pending.json — schema matches RootfsVersionMeta (camelCase) in rootfs_update.rs
    cat > "${state_dir}/pending.json" <<EOF
{
  "version": "${next_version}",
  "artifactPath": "${rel_image_path}",
  "recordedAt": "${now}"
}
EOF

    # Write current.json only if it does not already exist
    if [[ ! -f "${state_dir}/current.json" ]]; then
        cat > "${state_dir}/current.json" <<EOF
{
  "version": "${current_version}",
  "recordedAt": "${now}"
}
EOF
    fi

    # Rotate previous.json when there is a prior version
    if [[ -n "${previous_version}" ]]; then
        cat > "${state_dir}/previous.json" <<EOF
{
  "version": "${previous_version}",
  "recordedAt": "${now}"
}
EOF
    fi
}

[[ -b "${TARGET_DISK}" ]] || error "Not a block device: ${TARGET_DISK}"
[[ -f "${SQUASHFS_IMG}" ]] || error "Rootfs squashfs not found: ${SQUASHFS_IMG}"

ROOT_DEV="$(label_device DS_SYSROOT)"
BOOT_DEV="$(label_device DAYSHIELD_BOOT)"
STATE_DEV="$(label_device DS_STATE)"
EFI_DEV="$(resolve_efi_partition)"

[[ -n "${ROOT_DEV}" && -n "${BOOT_DEV}" ]] || \
    error "No compatible DayShield layout found. Expected DS_SYSROOT and DAYSHIELD_BOOT labels."
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

if [[ -n "${STATE_DEV}" ]] && [[ -d "${STAGING_MOUNT}/var" ]]; then
    rsync -aHAX --numeric-ids "${STAGING_MOUNT}/var/" "${TARGET_MOUNT}/var/"
fi

stage_rootfs_image_upgrade

sync
info "Rootfs image update staged successfully. Reboot to boot the new version."
