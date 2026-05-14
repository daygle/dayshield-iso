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
: "${ALLOW_NETWORK_FETCH:="0"}"

ROOTFS_DIR="${BUILD_DIR}/rootfs"
CHROOT_SHELL=""
CHROOT_SHELL_IS_BUSYBOX="0"

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

_resolve_chroot_shell() {
    local candidate
    for candidate in \
        /bin/sh \
        /usr/bin/sh \
        /bin/bash \
        /usr/bin/bash \
        /bin/dash \
        /usr/bin/dash \
        /bin/busybox \
        /usr/bin/busybox
    do
        if [[ -x "${ROOTFS_DIR}${candidate}" ]]; then
            CHROOT_SHELL="${candidate}"
            if [[ "${candidate}" == */busybox ]]; then
                CHROOT_SHELL_IS_BUSYBOX="1"
            fi
            return 0
        fi
    done
    return 1
}

_chroot_run() {
    local cmd="$1"
    if [[ "${CHROOT_SHELL_IS_BUSYBOX}" == "1" ]]; then
        chroot "${ROOTFS_DIR}" "${CHROOT_SHELL}" sh -c "${cmd}"
    else
        chroot "${ROOTFS_DIR}" "${CHROOT_SHELL}" -c "${cmd}"
    fi
}

_normalize_live_fstab() {
    # Live ISO boots from live-boot/overlay, not the installed root label.
    # Keep fstab intentionally empty in the live squashfs to avoid mount-unit
    # generation conflicts (e.g. "Failed to create unit file ..." warnings).
    cat > "${ROOTFS_DIR}/etc/fstab" <<'EOF'
# /etc/fstab - live installer runtime
# Intentionally minimal. Installed target fstab is generated during install.
EOF
}

if _pkg_installed live-boot-initramfs-tools && _pkg_installed live-config; then
    echo "--> live-boot already present in rootfs; nothing to do."
    _normalize_live_fstab
    exit 0
fi

if [[ "${ALLOW_NETWORK_FETCH}" != "1" ]]; then
    echo "ERROR: live-boot packages are missing in rootfs and network fetch is disabled." >&2
    echo "       Rebuild rootfs with required packages or set ALLOW_NETWORK_FETCH=1 explicitly." >&2
    exit 1
fi

if ! _resolve_chroot_shell; then
    echo "ERROR: cannot run commands in rootfs; no shell binary found." >&2
    echo "       Checked: /bin/sh, /usr/bin/sh, bash, dash, busybox." >&2
    echo "       Verify the rootfs archive was built correctly for the requested architecture." >&2
    exit 1
fi

echo "--> live-boot / live-config not found in live rootfs; installing …"

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
# live-boot-initramfs-tools  - provides the mkinitramfs hook that enables
#                              live-boot when BOOT=live is set.
# live-boot                  - the actual live-boot scripts (boot/live scripts
#                              executed by the initrd).
# live-config                - configures the running live session (hostname,
#                              autologin, etc.).
# live-config-systemd        - systemd units for live-config.
INIT_LOG="$(mktemp "${BUILD_DIR}/ensure-live-boot-XXXXXX.log")"
if _chroot_run \
    'LANG=C LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -qq update && \
     LANG=C LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -qq -y \
         -o APT::Install-Recommends=false \
         -o APT::Install-Suggests=false \
         install \
         live-boot \
         live-boot-initramfs-tools \
         live-config \
         live-config-systemd' >"${INIT_LOG}" 2>&1; then
    grep -v "Couldn't identify type of root file system .* for fsck hook" "${INIT_LOG}" || true
else
    grep -v "Couldn't identify type of root file system .* for fsck hook" "${INIT_LOG}" >&2 || true
    echo "ERROR: live-boot install failed." >&2
    cleanup_mounts
    trap - EXIT
    rm -f "${INIT_LOG}"
    exit 1
fi
rm -f "${INIT_LOG}"

cleanup_mounts
trap - EXIT

_normalize_live_fstab

echo "--> live-boot / live-config installed in live rootfs."
