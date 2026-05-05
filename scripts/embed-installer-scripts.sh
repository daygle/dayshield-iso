#!/usr/bin/env bash
# embed-installer-scripts.sh — Copy the CLI installer scripts into the live
# rootfs so that they are present inside the squashfs image and available at
# /usr/lib/dayshield-installer/ in the live session after switch_root.
#
# This MUST run BEFORE build-squashfs.sh.  Previously the embedding was done
# inside build-initrd.sh (after the squashfs was already frozen), which meant
# the scripts were absent from the live squashfs overlay.  install.sh and
# firstboot-run.sh then could not be found at runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"
: "${CONFIG_DIR:="${SCRIPT_DIR}/../config"}"

ROOTFS_DIR="${BUILD_DIR}/rootfs"
INSTALLER_SRC="${CONFIG_DIR}/installer"
INSTALLER_DEST="${ROOTFS_DIR}/usr/lib/dayshield-installer"

if [[ ! -d "${ROOTFS_DIR}" ]]; then
    echo "ERROR: rootfs directory not found: ${ROOTFS_DIR}; run extract-rootfs.sh first." >&2
    exit 1
fi

if [[ ! -d "${INSTALLER_SRC}" ]]; then
    echo "ERROR: installer scripts not found: ${INSTALLER_SRC}" >&2
    exit 1
fi

echo "--> Embedding installer scripts into live rootfs …"
echo "    source : ${INSTALLER_SRC}"
echo "    dest   : ${INSTALLER_DEST}"

mkdir -p "${INSTALLER_DEST}"
cp -a "${INSTALLER_SRC}/." "${INSTALLER_DEST}/"
chmod 755 "${INSTALLER_DEST}"/*.sh 2>/dev/null || true

# Normalise timestamps for reproducible squashfs
find "${INSTALLER_DEST}" -exec touch -h -t 197001010000 {} + 2>/dev/null || true

echo "--> Installer scripts embedded at /usr/lib/dayshield-installer/"
