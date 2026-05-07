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
: "${ALLOW_NETWORK_FETCH:="0"}"

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

# ---------------------------------------------------------------------------
# Fallback: install kernel inside chroot if not present
# ---------------------------------------------------------------------------
if [[ -z "${VMLINUZ}" ]]; then
    if [[ "${ALLOW_NETWORK_FETCH}" != "1" ]]; then
        echo "ERROR: No kernel found in rootfs and network fetch is disabled." >&2
        echo "       Ensure rootfs includes vmlinuz/initrd or set ALLOW_NETWORK_FETCH=1 explicitly." >&2
        exit 1
    fi

    echo "--> No kernel found in rootfs; installing linux-image via chroot …"

    # Ensure /tmp exists inside the rootfs for apt/dpkg temporary files.
    mkdir -p "${ROOTFS_DIR}/tmp"
    chmod 1777 "${ROOTFS_DIR}/tmp"

    # Bind-mount essential pseudo-filesystems
    for _fs in dev dev/pts proc sys run tmp; do
        mkdir -p "${ROOTFS_DIR}/${_fs}"
        mount --bind "/${_fs}" "${ROOTFS_DIR}/${_fs}"
    done

    cleanup_kernel_mounts() {
        for _fs in tmp run sys proc dev/pts dev; do
            umount -lf "${ROOTFS_DIR}/${_fs}" 2>/dev/null || true
        done
    }
    trap cleanup_kernel_mounts EXIT

    # shellcheck disable=SC2016  # $1 is intentionally expanded by the inner sh
    chroot "${ROOTFS_DIR}" /bin/sh -c \
        'LANG=C LC_ALL=C apt-get -qq update && LANG=C LC_ALL=C apt-get -qq -y \
            -o APT::Install-Recommends=false \
            -o APT::Install-Suggests=false \
            install "linux-image-$1"' -- "${ARCH}"

    cleanup_kernel_mounts
    trap - EXIT

    VMLINUZ="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -name 'vmlinuz*' -type f \
               | sort -V | tail -n1)"
fi

if [[ -z "${VMLINUZ}" ]]; then
    echo "ERROR: Could not locate or install a kernel." >&2
    exit 1
fi

KVER="$(basename "${VMLINUZ}" | sed 's/vmlinuz-//')"
# If KVER equals "vmlinuz" (no suffix stripped) or is empty, it is invalid
if [[ -z "${KVER}" ]] || [[ "${KVER}" == "vmlinuz" ]]; then
    echo "ERROR: Could not determine kernel version from filename: ${VMLINUZ}" >&2
    echo "       Expected a kernel named 'vmlinuz-<version>'." >&2
    exit 1
fi
# Find an initrd that matches the selected kernel version exactly; fall back to
# the most-recent non-RT initrd.  Two separate find calls are used because find
# exits 0 even when nothing matches, so the || operator cannot trigger the
# fallback — we must check the result explicitly instead.
INITRD="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -name "initrd.img-${KVER}" -type f 2>/dev/null | head -n1)"
if [[ -z "${INITRD}" ]]; then
    INITRD="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -name 'initrd.img*' -type f 2>/dev/null \
              | grep -v '\-rt' | sort -V | tail -n1 || true)"
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
