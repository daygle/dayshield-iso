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

# Determine kernel version from the vmlinuz we copied earlier
KVER="$(strings "${KERNEL_DIR}/vmlinuz" 2>/dev/null \
        | grep -oP '\d+\.\d+\.\d+-\d+-[a-z0-9]+' \
        | head -n1 || true)"

if [[ -z "${KVER}" ]]; then
    # Fallback: look for modules directory in rootfs
    KVER="$(ls "${ROOTFS_DIR}/lib/modules/" 2>/dev/null | sort -V | tail -n1 || true)"
fi

echo "--> Building initrd (kernel: ${KVER:-unknown}) …"

# ---------------------------------------------------------------------------
# Embed installer scripts
# ---------------------------------------------------------------------------
INSTALLER_EMBED_DIR="${INITRD_WORK}/usr/lib/dayshield-installer"
mkdir -p "${INSTALLER_EMBED_DIR}"

if [[ -d "${INSTALLER_SRC}" ]]; then
    cp -a "${INSTALLER_SRC}/." "${INSTALLER_EMBED_DIR}/"
    chmod 755 "${INSTALLER_EMBED_DIR}"/*.sh 2>/dev/null || true
    # Normalise timestamps
    find "${INSTALLER_EMBED_DIR}" -exec touch -h -t 197001010000 {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Try dracut first
# ---------------------------------------------------------------------------
if command -v dracut &>/dev/null; then
    echo "--> Using dracut …"

    # Build a dracut conf snippet
    DRACUT_CONF="$(mktemp --suffix=.conf)"
    cat > "${DRACUT_CONF}" <<'EOF'
# DayShield installer initrd configuration
add_dracutmodules+=" systemd network base rootfs-block "
add_drivers+=" ext4 xfs btrfs "
omit_dracutmodules+=" ipv6 "
install_items+=" /usr/lib/dayshield-installer "
compress="zstd"
EOF

    KVER_ARG=""
    if [[ -n "${KVER}" ]]; then
        KVER_ARG="--kver ${KVER}"
    fi

    # shellcheck disable=SC2086
    dracut \
        --conf "${DRACUT_CONF}" \
        --force \
        --no-hostonly \
        --add "dmsquash-live" \
        ${KVER_ARG} \
        "${KERNEL_DIR}/initrd.img"

    rm -f "${DRACUT_CONF}"

# ---------------------------------------------------------------------------
# Fallback: mkinitramfs
# ---------------------------------------------------------------------------
elif command -v mkinitramfs &>/dev/null; then
    echo "--> Using mkinitramfs …"

    MKINITRAMFS_CONF="$(mktemp -d)"

    # Add installer scripts hook
    cat > "${MKINITRAMFS_CONF}/hook-dayshield" <<'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /usr/lib/dayshield-installer/ /usr/lib/dayshield-installer
HOOK
    chmod 755 "${MKINITRAMFS_CONF}/hook-dayshield"
    cp "${MKINITRAMFS_CONF}/hook-dayshield" \
       /etc/initramfs-tools/hooks/dayshield-installer 2>/dev/null || true

    KVER_ARG="${KVER:-$(uname -r)}"
    mkinitramfs -o "${KERNEL_DIR}/initrd.img" "${KVER_ARG}"

    rm -rf "${MKINITRAMFS_CONF}"
    rm -f /etc/initramfs-tools/hooks/dayshield-installer 2>/dev/null || true

else
    echo "WARNING: Neither dracut nor mkinitramfs found." >&2
    echo "         The placeholder initrd.img will be used." >&2
fi

# Normalise timestamp
touch -h -t 197001010000 "${KERNEL_DIR}/initrd.img" 2>/dev/null || true

echo "--> initrd built: $(du -sh "${KERNEL_DIR}/initrd.img" | cut -f1)"
