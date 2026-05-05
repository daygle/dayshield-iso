#!/usr/bin/env bash
# build-kernel.sh - Extract vmlinuz and a base initrd from the rootfs.
#
# Strategy:
#   1. Look for a kernel already present in build/rootfs (copied from rootfs.tar.zst).
#   2. If not found, attempt to install the latest linux-image from within the
#      extracted rootfs using chroot + apt-get.
#   3. Copy vmlinuz and initrd.img to build/kernel/ with normalised timestamps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"
: "${ARCH:="amd64"}"

ROOTFS_DIR="${BUILD_DIR}/rootfs"
KERNEL_DIR="${BUILD_DIR}/kernel"

mkdir -p "${KERNEL_DIR}"

echo "--> Locating kernel in rootfs …"

# Prefer non-RT kernel - RT kernels require CONSTANT_TSC which QEMU TCG does
# not provide, causing hangs.  Fall back to RT only if nothing else is present.
VMLINUZ="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -name 'vmlinuz*' -type f 2>/dev/null \
           | grep -v '\-rt' | sort -V | tail -n1 || true)"
# Fall back to RT if no non-RT kernel is found
if [[ -z "${VMLINUZ}" ]]; then
    VMLINUZ="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -name 'vmlinuz*' -type f 2>/dev/null \
               | sort -V | tail -n1 || true)"
fi

KVER="$(basename "${VMLINUZ}" | sed 's/vmlinuz-//')"
# If KVER equals "vmlinuz" (no suffix stripped) or is empty, it is invalid
if [[ -z "${KVER}" ]] || [[ "${KVER}" == "vmlinuz" ]]; then
    echo "ERROR: Could not determine kernel version from filename: ${VMLINUZ}" >&2
    echo "       Expected a kernel named 'vmlinuz-<version>'." >&2
    exit 1
fi
INITRD="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -name "initrd.img-${KVER}" -type f 2>/dev/null \
          || find "${ROOTFS_DIR}/boot" -maxdepth 1 -name 'initrd.img*' -type f 2>/dev/null \
          | grep -v '\-rt' | sort -V | tail -n1 || true)"

# ---------------------------------------------------------------------------
# Fallback: install kernel inside chroot if not present
# ---------------------------------------------------------------------------
if [[ -z "${VMLINUZ}" ]]; then
    echo "--> No kernel found in rootfs; installing linux-image via chroot …"

    # Bind-mount essential pseudo-filesystems
    mount --bind /dev  "${ROOTFS_DIR}/dev"
    mount --bind /proc "${ROOTFS_DIR}/proc"
    mount --bind /sys  "${ROOTFS_DIR}/sys"

    trap 'umount -lf "${ROOTFS_DIR}/dev" "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys" 2>/dev/null || true' EXIT

    chroot "${ROOTFS_DIR}" /bin/sh -c \
        'apt-get -qq update && apt-get -y --no-install-recommends install linux-image-amd64'

    umount -lf "${ROOTFS_DIR}/dev"
    umount -lf "${ROOTFS_DIR}/proc"
    umount -lf "${ROOTFS_DIR}/sys"
    trap - EXIT

    VMLINUZ="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -name 'vmlinuz*' -type f \
               | sort -V | tail -n1)"
    INITRD="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -name 'initrd.img*' -type f \
              | sort -V | tail -n1 || true)"
fi

if [[ -z "${VMLINUZ}" ]]; then
    echo "ERROR: Could not locate or install a kernel." >&2
    exit 1
fi

echo "    kernel : ${VMLINUZ}"

# Copy vmlinuz
cp "${VMLINUZ}" "${KERNEL_DIR}/vmlinuz"

# Copy or create initrd placeholder
if [[ -n "${INITRD}" ]]; then
    echo "    initrd : ${INITRD}"
    cp "${INITRD}" "${KERNEL_DIR}/initrd.img"
else
    echo "    initrd : (placeholder - will be replaced by build-initrd.sh)"
    touch "${KERNEL_DIR}/initrd.img"
fi

# Normalise timestamps
touch -h -t 197001010000 "${KERNEL_DIR}/vmlinuz" "${KERNEL_DIR}/initrd.img" 2>/dev/null || true

echo "--> Kernel stage complete."
