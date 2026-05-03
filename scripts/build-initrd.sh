#!/usr/bin/env bash
# build-initrd.sh — Build the installer initrd using dracut (preferred) or
#                   mkinitramfs as a fallback.
#
# The generated initrd:
#   • includes systemd, network drivers, ext4/xfs/btrfs, optional cryptsetup
#   • disables IPv6 kernel module
#   • embeds installer scripts into /usr/lib/dayshield-installer/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"
: "${CONFIG_DIR:="${SCRIPT_DIR}/../config"}"
: "${ARCH:="amd64"}"

KERNEL_DIR="${BUILD_DIR}/kernel"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
INITRD_WORK="${BUILD_DIR}/initrd-work"
INSTALLER_SRC="${CONFIG_DIR}/installer"

# ---------------------------------------------------------------------------
# Determine kernel version
# ---------------------------------------------------------------------------
# Prefer the modules directory name — it is the exact string the kernel and
# dracut need, and avoids regex mis-truncation (e.g. 6.1.0-42-rt-amd64 vs
# 6.1.0-42-rt).
KVER="$(ls "${ROOTFS_DIR}/lib/modules/" 2>/dev/null | sort -V | tail -n1 || true)"

if [[ -z "${KVER}" ]]; then
    # Fallback: extract from the kernel binary
    KVER="$(strings "${KERNEL_DIR}/vmlinuz" 2>/dev/null \
            | grep -oP '\d+\.\d+\.\d+-\S+' \
            | head -n1 || true)"
fi

KERNEL_VERSION="${KVER}"

echo "--> Building initrd (kernel: ${KERNEL_VERSION:-unknown}) …"

# ---------------------------------------------------------------------------
# Embed installer scripts into the ROOTFS (so mkinitramfs can see them)
# ---------------------------------------------------------------------------
INSTALLER_EMBED_DIR="${ROOTFS_DIR}/usr/lib/dayshield-installer"
mkdir -p "${INSTALLER_EMBED_DIR}"

if [[ -d "${INSTALLER_SRC}" ]]; then
    cp -a "${INSTALLER_SRC}/." "${INSTALLER_EMBED_DIR}/"
    chmod 755 "${INSTALLER_EMBED_DIR}"/*.sh 2>/dev/null || true
    find "${INSTALLER_EMBED_DIR}" -exec touch -h -t 197001010000 {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Try dracut first (requires dracut-live package for dmsquash-live module)
# ---------------------------------------------------------------------------
DRACUT_LIVE_MODULE=""
for _dir in /usr/lib/dracut/modules.d /lib/dracut/modules.d; do
    if [[ -d "${_dir}/90dmsquash-live" ]]; then
        DRACUT_LIVE_MODULE="${_dir}/90dmsquash-live"
        break
    fi
done

if command -v dracut &>/dev/null && [[ -n "${DRACUT_LIVE_MODULE}" ]]; then
    echo "--> Using dracut (dmsquash-live: ${DRACUT_LIVE_MODULE}) …"

    DRACUT_CONF="$(mktemp --suffix=.conf)"
    cat > "${DRACUT_CONF}" <<'EOF'
# DayShield installer initrd configuration
# 'network' is intentionally omitted — not available on all build hosts and
# not required for live squashfs boot; networking starts post-pivot via
# systemd-networkd in the live environment.
add_dracutmodules+=" systemd base rootfs-block "
add_drivers+=" ext4 xfs btrfs squashfs loop "
omit_dracutmodules+=" ipv6 "
compress="zstd"
EOF

    KVER_ARG=""
    KMODDIR_ARG=""
    if [[ -n "${KERNEL_VERSION}" ]]; then
        KVER_ARG="--kver ${KERNEL_VERSION}"
        # Point dracut at the rootfs modules — the build host won't have them
        MODULES_DIR="${ROOTFS_DIR}/lib/modules/${KERNEL_VERSION}"
        if [[ -d "${MODULES_DIR}" ]]; then
            KMODDIR_ARG="--kmoddir ${MODULES_DIR}"
        fi
    fi

    dracut \
        --conf "${DRACUT_CONF}" \
        --force \
        --no-hostonly \
        --add "dmsquash-live" \
        ${KVER_ARG} \
        ${KMODDIR_ARG} \
        "${KERNEL_DIR}/initrd.img"

    rm -f "${DRACUT_CONF}"

# ---------------------------------------------------------------------------
# Fallback: mkinitramfs (CHROOTED)
# ---------------------------------------------------------------------------
elif command -v mkinitramfs &>/dev/null; then
    echo "--> Using mkinitramfs (chrooted) …"

    # Create hook inside rootfs
    mkdir -p "${ROOTFS_DIR}/etc/initramfs-tools/hooks"

    cat > "${ROOTFS_DIR}/etc/initramfs-tools/hooks/dayshield-installer" <<'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

# Copy installer payload into the initrd
mkdir -p "${DESTDIR}/usr/lib/dayshield-installer"
if [ -d /usr/lib/dayshield-installer ]; then
    cp -a /usr/lib/dayshield-installer/. "${DESTDIR}/usr/lib/dayshield-installer/"
fi
HOOK

    chmod 755 "${ROOTFS_DIR}/etc/initramfs-tools/hooks/dayshield-installer"

    # Activate live-boot mode so the initrd can pivot to the squashfs root
    mkdir -p "${ROOTFS_DIR}/etc/initramfs-tools/conf.d"
    echo 'BOOT=live' > "${ROOTFS_DIR}/etc/initramfs-tools/conf.d/live.conf"

    # Run mkinitramfs inside the rootfs so it sees the correct modules + payload
    chroot "${ROOTFS_DIR}" mkinitramfs -o /tmp/initrd.img "${KERNEL_VERSION}"

    # Copy initrd out of chroot
    cp "${ROOTFS_DIR}/tmp/initrd.img" "${KERNEL_DIR}/initrd.img"
    rm -f "${ROOTFS_DIR}/tmp/initrd.img"
    rm -f "${ROOTFS_DIR}/etc/initramfs-tools/hooks/dayshield-installer"
    rm -f "${ROOTFS_DIR}/etc/initramfs-tools/conf.d/live.conf"

else
    echo "WARNING: Neither dracut nor mkinitramfs found." >&2
    echo "         The placeholder initrd.img will be used." >&2
fi

# ---------------------------------------------------------------------------
# Normalise timestamp
# ---------------------------------------------------------------------------
touch -h -t 197001010000 "${KERNEL_DIR}/initrd.img" 2>/dev/null || true

echo "--> initrd built: $(du -sh "${KERNEL_DIR}/initrd.img" | cut -f1)"
