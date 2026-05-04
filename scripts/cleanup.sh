#!/usr/bin/env bash
# cleanup.sh - Remove intermediate build artefacts.
#
# Keeps: the final ISO and any explicitly preserved artefacts.
# Removes: build/ tree (rootfs extraction, squashfs work, bootloader staging,
#          iso staging, initrd work directories).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"

echo "--> Cleaning up intermediate build artefacts in ${BUILD_DIR} …"

# Remove large intermediate directories; leave build/ itself for the ISO if
# assemble-iso.sh wrote it there.
for d in rootfs kernel bootloader iso initrd-work; do
    if [[ -d "${BUILD_DIR}/${d}" ]]; then
        echo "    removing ${BUILD_DIR}/${d}"
        rm -rf "${BUILD_DIR:?}/${d}"
    fi
done

# Remove squashfs intermediate image (it is already embedded in the ISO)
if [[ -f "${BUILD_DIR}/squashfs-rootfs.sqsh" ]]; then
    echo "    removing ${BUILD_DIR}/squashfs-rootfs.sqsh"
    rm -f "${BUILD_DIR}/squashfs-rootfs.sqsh"
fi

# Remove any leftover temp dracut conf files
rm -f /tmp/dayshield-dracut-*.conf 2>/dev/null || true

echo "--> Cleanup complete."
