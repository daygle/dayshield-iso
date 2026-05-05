#!/usr/bin/env bash
# ensure-live-boot.sh - Guarantee that live-boot and live-config are present
#                       in the live rootfs BEFORE the squashfs image and the
#                       installer initrd are built.
#
# Background
# ----------
# The input rootfs.tar.zst may have been produced from a system where
# live-boot/live-config were already purged (e.g. after a previous install
# run).  Without these packages:
#   • The squashfs will lack the live-config scripts that set up the live
#     session (hostname, auto-login, etc.).
#   • mkinitramfs will produce an initrd with no live-boot hook even though
#     BOOT=live is set, so the kernel cannot pivot to the squashfs → the ISO
#     will not boot.
#   • dracut / dmsquash-live is self-contained and does not require live-boot
#     in the rootfs, so it is unaffected; but we still want live-config in the
#     squashfs for a functional live session.
#
# This script is intentionally idempotent: if the packages are already
# installed nothing is changed and the script exits quickly.
#
# The installed /target system is cleaned separately by install.sh; this
# script only touches the temporary build/rootfs/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"

ROOTFS_DIR="${BUILD_DIR}/rootfs"

if [[ ! -d "${ROOTFS_DIR}" ]]; then
    echo "ERROR: rootfs directory not found: ${ROOTFS_DIR}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Check whether live-boot-initramfs-tools is already installed
# ---------------------------------------------------------------------------
_pkg_installed() {
    dpkg-query --root="${ROOTFS_DIR}" -W -f='${Status}' "$1" 2>/dev/null \
        | grep -q "install ok installed"
}

if _pkg_installed live-boot-initramfs-tools && _pkg_installed live-config; then
    echo "--> live-boot already present in rootfs; nothing to do."
    exit 0
fi

echo "--> live-boot / live-config not found in live rootfs; installing …"

# ---------------------------------------------------------------------------
# Ensure /tmp exists and is writable inside the rootfs.
# Some chrooted apt operations need a writable /tmp directory.
# ---------------------------------------------------------------------------
mkdir -p "${ROOTFS_DIR}/tmp"
chmod 1777 "${ROOTFS_DIR}/tmp"

# ---------------------------------------------------------------------------
# Ensure /tmp exists and is writable inside the rootfs.
# Some chrooted apt operations need a writable /tmp directory.
# ---------------------------------------------------------------------------
mkdir -p "${ROOTFS_DIR}/tmp"
chmod 1777 "${ROOTFS_DIR}/tmp"

# ---------------------------------------------------------------------------
# Bind-mount pseudo-filesystems so apt / dpkg work inside the chroot
# ---------------------------------------------------------------------------
for _fs in dev dev/pts proc sys run tmp; do
    mkdir -p "${ROOTFS_DIR}/${_fs}"
    mount --bind "/${_fs}" "${ROOTFS_DIR}/${_fs}"
done

cleanup_mounts() {
    for _fs in tmp run sys proc dev/pts dev; do
        umount -lf "${ROOTFS_DIR}/${_fs}" 2>/dev/null || true
    done
}
trap cleanup_mounts EXIT

# ---------------------------------------------------------------------------
# Install the live-boot stack into the live rootfs
# ---------------------------------------------------------------------------
# live-boot-initramfs-tools  — provides the mkinitramfs hook that enables
#                              live-boot when BOOT=live is set.
# live-boot                  — the actual live-boot scripts (boot/live scripts
#                              executed by the initrd).
# live-config                — configures the running live session (hostname,
#                              autologin, etc.).
# live-config-systemd        — systemd units for live-config.
chroot "${ROOTFS_DIR}" /bin/sh -c \
    'DEBIAN_FRONTEND=noninteractive apt-get -qq update && \
     DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
         live-boot \
         live-boot-initramfs-tools \
         live-config \
         live-config-systemd'

cleanup_mounts
trap - EXIT

echo "--> live-boot / live-config installed in live rootfs."
