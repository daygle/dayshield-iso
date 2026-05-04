#!/usr/bin/env bash
# build-squashfs.sh - Build a deterministic squashfs image from build/rootfs/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"

ROOTFS_DIR="${BUILD_DIR}/rootfs"
SQUASHFS_IMG="${BUILD_DIR}/squashfs-rootfs.sqsh"

echo "--> Building squashfs image …"
echo "    source : ${ROOTFS_DIR}"
echo "    output : ${SQUASHFS_IMG}"

if [[ ! -d "${ROOTFS_DIR}" ]]; then
    echo "ERROR: rootfs directory not found: ${ROOTFS_DIR}" >&2
    exit 1
fi

rm -f "${SQUASHFS_IMG}"

# Build deterministic squashfs
#   -comp zstd               - zstd compression
#   -Xcompression-level 19   - maximum zstd compression
#   -noappend                - overwrite if exists
#   -all-root                - force uid/gid 0:0 for all files
#   -no-xattrs               - exclude extended attributes (not needed for live)
#   -no-fragments            - disable tail-end packing (reproducibility)
#   -root-owned              - alias for -all-root (some versions)
#   -mkfs-time 0             - set filesystem creation timestamp to epoch
#   -wildcards               - enable wildcard exclusions
mksquashfs \
    "${ROOTFS_DIR}" \
    "${SQUASHFS_IMG}" \
    -comp zstd \
    -Xcompression-level 19 \
    -noappend \
    -all-root \
    -no-xattrs \
    -no-fragments \
    -mkfs-time 0 \
    -wildcards \
    -e "proc/*" \
    -e "sys/*" \
    -e "run/*" \
    -e "dev/*"

echo "--> squashfs image built: $(du -sh "${SQUASHFS_IMG}" | cut -f1)"
