#!/usr/bin/env bash
# inject-installer-ui.sh — Inject installer web UI files into the live rootfs
#                           before the squashfs image is built.
#
# This script runs AFTER extract-rootfs.sh and BEFORE build-squashfs.sh.
# It places the installer web UI at /installer-ui/ inside the live rootfs and
# enables the two installer services so they start automatically when the ISO is
# booted with "installer" on the kernel command line.
#
# Both service units carry ConditionKernelCommandLine=installer so they are
# silently skipped on an installed (non-live) system.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"

ROOTFS_DIR="${BUILD_DIR}/rootfs"
INSTALLER_UI_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installer-ui) INSTALLER_UI_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${INSTALLER_UI_DIR}" ]]; then
    echo "ERROR: --installer-ui <path> is required." >&2
    exit 1
fi

if [[ ! -d "${INSTALLER_UI_DIR}" ]]; then
    echo "ERROR: installer-ui directory not found: ${INSTALLER_UI_DIR}" >&2
    exit 1
fi

if [[ ! -d "${ROOTFS_DIR}" ]]; then
    echo "ERROR: rootfs not found at ${ROOTFS_DIR}; run extract-rootfs.sh first." >&2
    exit 1
fi

echo "--> Injecting installer web UI into live rootfs …"
echo "    source : ${INSTALLER_UI_DIR}"
echo "    dest   : ${ROOTFS_DIR}/installer-ui/"

# ---------------------------------------------------------------------------
# Copy web UI files
# ---------------------------------------------------------------------------
mkdir -p "${ROOTFS_DIR}/installer-ui"
cp -a "${INSTALLER_UI_DIR}/." "${ROOTFS_DIR}/installer-ui/"

# Ensure all API scripts are executable (busybox httpd runs them as CGI)
find "${ROOTFS_DIR}/installer-ui/api" -name "*.sh" -exec chmod 755 {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Install systemd service units
# ---------------------------------------------------------------------------
SYSTEMD_SRC="${INSTALLER_UI_DIR}/systemd"
SYSTEMD_DEST="${ROOTFS_DIR}/etc/systemd/system"

mkdir -p "${SYSTEMD_DEST}"

for unit in installer-ui.service installer-ui-web.service; do
    if [[ -f "${SYSTEMD_SRC}/${unit}" ]]; then
        cp "${SYSTEMD_SRC}/${unit}" "${SYSTEMD_DEST}/${unit}"
        echo "    installed ${unit}"
    else
        echo "WARNING: service unit not found: ${SYSTEMD_SRC}/${unit}" >&2
    fi
done

# ---------------------------------------------------------------------------
# Enable both installer services so that on live boot the web UI starts
# automatically AND tty1 shows access instructions / a console installer.
# Both units carry ConditionKernelCommandLine=installer so they are silently
# skipped on a non-live (installed) system.
# ---------------------------------------------------------------------------
WANTS_DIR="${SYSTEMD_DEST}/multi-user.target.wants"
mkdir -p "${WANTS_DIR}"

for unit in installer-ui.service installer-ui-web.service; do
    if [[ -f "${SYSTEMD_DEST}/${unit}" ]]; then
        ln -sf "/etc/systemd/system/${unit}" "${WANTS_DIR}/${unit}"
        echo "    enabled  ${unit} → multi-user.target"
    fi
done

# ---------------------------------------------------------------------------
# Normalise timestamps for reproducible squashfs
# ---------------------------------------------------------------------------
find "${ROOTFS_DIR}/installer-ui" -exec touch -h -t 197001010000 {} + 2>/dev/null || true
find "${SYSTEMD_DEST}/installer-ui"* -exec touch -h -t 197001010000 {} + 2>/dev/null || true
find "${WANTS_DIR}/installer-ui"* -exec touch -h -t 197001010000 {} + 2>/dev/null || true

echo "--> Installer UI injection complete."
