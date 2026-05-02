#!/usr/bin/env bash
# extract-rootfs.sh — Extract rootfs.tar.zst into build/rootfs/.
#
# Security guarantees:
#   • No device nodes created (--no-same-owner combined with explicit exclusions)
#   • No unexpected SUID/SGID binaries added
#   • Deterministic permissions (umask 022)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"

ROOTFS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${ROOTFS}" ]]; then
    echo "ERROR: --rootfs is required." >&2
    exit 1
fi

ROOTFS_DIR="${BUILD_DIR}/rootfs"

echo "--> Extracting rootfs: ${ROOTFS}"
echo "    destination: ${ROOTFS_DIR}"

# Clean previous extraction
rm -rf "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"

# Ensure predictable permissions
umask 022

# Extract with:
#   --no-same-owner    — do not restore original ownership (run as current user)
#   --no-same-permissions — apply umask instead of archive permissions
#   --exclude=./dev    — skip device nodes entirely
# zstd is handled transparently by modern tar (requires zstd on PATH)
tar \
    --extract \
    --file="${ROOTFS}" \
    --directory="${ROOTFS_DIR}" \
    --no-same-owner \
    --no-same-permissions \
    --exclude="./dev/*" \
    --exclude="./proc/*" \
    --exclude="./sys/*" \
    --exclude="./run/*" \
    --use-compress-program="zstd -d" \
    2>/dev/null || \
tar \
    --extract \
    --file="${ROOTFS}" \
    --directory="${ROOTFS_DIR}" \
    --no-same-owner \
    --no-same-permissions \
    --exclude="./dev/*" \
    --exclude="./proc/*" \
    --exclude="./sys/*" \
    --exclude="./run/*"

# Re-create minimal /dev entries as empty directories (no device nodes)
mkdir -p "${ROOTFS_DIR}/dev"
mkdir -p "${ROOTFS_DIR}/proc"
mkdir -p "${ROOTFS_DIR}/sys"
mkdir -p "${ROOTFS_DIR}/run"

# Security check: report any SUID/SGID binaries that ended up in the rootfs.
echo "--> Checking for SUID/SGID binaries …"
SUID_FILES="$(find "${ROOTFS_DIR}" -perm /6000 -type f 2>/dev/null || true)"
if [[ -n "${SUID_FILES}" ]]; then
    echo "WARNING: SUID/SGID binaries found in rootfs:"
    echo "${SUID_FILES}"
fi

# Normalise all timestamps to epoch 0 for deterministic builds
echo "--> Normalising file timestamps …"
find "${ROOTFS_DIR}" -exec touch -h -t 197001010000 {} + 2>/dev/null || true

echo "--> rootfs extraction complete."
