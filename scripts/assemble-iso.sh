#!/usr/bin/env bash
# assemble-iso.sh - Assemble the final DayShield installer ISO using xorriso.
#
# ISO layout:
#   /boot/grub/         - GRUB configuration, modules, bios.img
#   /EFI/BOOT/          - UEFI binaries
#   /EFI/efiboot.img    - FAT EFI system partition image (appended partition)
#   /live/              - squashfs
#   /boot/              - kernel + initrd (FIXED)
#   /installer/         - installer scripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"
: "${CONFIG_DIR:="${SCRIPT_DIR}/../config"}"
# shellcheck source=scripts/installer-ui-common.sh
source "${SCRIPT_DIR}/installer-ui-common.sh"

OUTPUT=""
ROOTFS_ARCHIVE=""
INSTALLER_UI_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)        OUTPUT="$2"; shift 2 ;;
        --rootfs)        ROOTFS_ARCHIVE="$2"; shift 2 ;;
        --installer-ui)  INSTALLER_UI_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${OUTPUT}" ]]; then
    OUTPUT="${BUILD_DIR}/dayshield.iso"
fi

ISO_ROOT="${BUILD_DIR}/iso"
KERNEL_DIR="${BUILD_DIR}/kernel"
SQUASHFS_IMG="${BUILD_DIR}/squashfs-rootfs.sqsh"
BOOT_DIR="${BUILD_DIR}/bootloader"
INSTALLER_SRC="${CONFIG_DIR}/installer"

# ---------------------------------------------------------------------------
# Validate required artefacts
# ---------------------------------------------------------------------------
missing=()
[[ ! -f "${SQUASHFS_IMG}" ]]                          && missing+=("squashfs-rootfs.sqsh")
[[ ! -f "${KERNEL_DIR}/vmlinuz" ]]                    && missing+=("kernel/vmlinuz")
[[ ! -f "${KERNEL_DIR}/initrd.img" ]]                 && missing+=("kernel/initrd.img")
[[ ! -f "${BOOT_DIR}/boot/grub/grub.cfg" ]]           && missing+=("bootloader/boot/grub/grub.cfg")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required artefacts:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build ISO root directory tree
# ---------------------------------------------------------------------------
echo "--> Building ISO directory tree …"

rm -rf "${ISO_ROOT}"
mkdir -p \
    "${ISO_ROOT}/boot/grub" \
    "${ISO_ROOT}/EFI/BOOT" \
    "${ISO_ROOT}/live" \
    "${ISO_ROOT}/boot" \
    "${ISO_ROOT}/installer"

# Live squashfs
cp "${SQUASHFS_IMG}"              "${ISO_ROOT}/live/filesystem.squashfs"

# ---------------------------------------------------------------------------
# FIX: Kernel + initrd must be in /boot for GRUB
# ---------------------------------------------------------------------------
cp "${KERNEL_DIR}/vmlinuz"        "${ISO_ROOT}/boot/vmlinuz"
cp "${KERNEL_DIR}/initrd.img"     "${ISO_ROOT}/boot/initrd.img"

# GRUB BIOS boot files
cp "${BOOT_DIR}/boot/grub/grub.cfg"  "${ISO_ROOT}/boot/grub/grub.cfg"
if [[ ! -f "${BOOT_DIR}/boot/grub/.bios-boot-unavailable" ]]; then
    cp "${BOOT_DIR}/boot/grub/bios.img"  "${ISO_ROOT}/boot/grub/bios.img"
fi
[[ -f "${BOOT_DIR}/boot/grub/core.img" ]] && \
    cp "${BOOT_DIR}/boot/grub/core.img" "${ISO_ROOT}/boot/grub/core.img"
[[ -f "${BOOT_DIR}/boot/grub/splash.png" ]] && \
    cp "${BOOT_DIR}/boot/grub/splash.png" "${ISO_ROOT}/boot/grub/splash.png"
[[ -f "${BOOT_DIR}/boot/grub/unicode.pf2" ]] && \
    cp "${BOOT_DIR}/boot/grub/unicode.pf2" "${ISO_ROOT}/boot/grub/unicode.pf2"

# Copy any GRUB locale/module directories that may be present
for sub in fonts locale i386-pc x86_64-efi; do
    [[ -d "${BOOT_DIR}/boot/grub/${sub}" ]] && \
        cp -r "${BOOT_DIR}/boot/grub/${sub}" "${ISO_ROOT}/boot/grub/${sub}"
done

# UEFI EFI binaries
[[ -f "${BOOT_DIR}/EFI/BOOT/BOOTX64.EFI" ]] && \
    cp "${BOOT_DIR}/EFI/BOOT/BOOTX64.EFI" "${ISO_ROOT}/EFI/BOOT/BOOTX64.EFI"

# Installer scripts
if [[ -d "${INSTALLER_SRC}" ]]; then
    cp -r "${INSTALLER_SRC}/." "${ISO_ROOT}/installer/"
fi

# Place rootfs archive on ISO so the web installer can find it without RAM copy
if [[ -n "${ROOTFS_ARCHIVE}" ]] && [[ -f "${ROOTFS_ARCHIVE}" ]]; then
    echo "--> Embedding rootfs archive at /installer/rootfs.tar.zst …"
    cp "${ROOTFS_ARCHIVE}" "${ISO_ROOT}/installer/rootfs.tar.zst"
fi

# Place installer web UI files on ISO (served by installer-ui-web.service)
if [[ -n "${INSTALLER_UI_DIR}" ]] && [[ -d "${INSTALLER_UI_DIR}" ]]; then
    echo "--> Embedding installer web UI at /installer-ui/ …"
    mkdir -p "${ISO_ROOT}/installer-ui"
    cp -r "${INSTALLER_UI_DIR}/." "${ISO_ROOT}/installer-ui/"
    prune_installer_ui_tree "${ISO_ROOT}/installer-ui"
fi

# Normalise all timestamps to epoch 0
find "${ISO_ROOT}" -exec touch -h -t 197001010000 {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Locate the hybrid MBR and EFI partition image
# ---------------------------------------------------------------------------
BOOT_HYBRID_IMG="${BOOT_DIR}/boot/grub/boot_hybrid.img"
EFI_PART_IMG="${BOOT_DIR}/EFI/efiboot.img"

XORRISO_EXTRA_ARGS=()

if [[ -f "${BOOT_HYBRID_IMG}" ]] && [[ -s "${BOOT_HYBRID_IMG}" ]]; then
    XORRISO_EXTRA_ARGS+=( --grub2-mbr "${BOOT_HYBRID_IMG}" )
fi

if [[ -f "${EFI_PART_IMG}" ]]; then
    cp "${EFI_PART_IMG}" "${ISO_ROOT}/EFI/efiboot.img"
    XORRISO_EXTRA_ARGS+=(
        -eltorito-alt-boot
        -e          "EFI/efiboot.img"
        -no-emul-boot
        -append_partition 2 0xef "${EFI_PART_IMG}"
        -appended_part_as_gpt
    )
fi

# ---------------------------------------------------------------------------
# BIOS El Torito boot entry (omitted when grub-i386-pc was unavailable)
# ---------------------------------------------------------------------------
BIOS_ELTORITO_ARGS=()
if [[ ! -f "${BOOT_DIR}/boot/grub/.bios-boot-unavailable" ]]; then
    BIOS_ELTORITO_ARGS=(
        -eltorito-boot    "boot/grub/bios.img"
        -eltorito-catalog "boot/grub/boot.cat"
        -no-emul-boot
        -boot-load-size 4
        -boot-info-table
        --grub2-boot-info
    )
else
    echo "INFO: Omitting BIOS El Torito entry (grub-i386-pc was unavailable at build time)."
fi

# ---------------------------------------------------------------------------
# Assemble the ISO with xorriso
# ---------------------------------------------------------------------------

echo "--> Running xorriso …"
echo "    output: ${OUTPUT}"

XORRISO_DATE_ARGS=()
if xorriso -as mkisofs -help 2>/dev/null | grep -q -- '-set_all_file_dates'; then
    XORRISO_DATE_ARGS+=( -set_all_file_dates 0 )
else
    echo "WARNING: xorriso does not support -set_all_file_dates; ISO file dates will not be normalized by xorriso."
fi

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -rational-rock \
    -joliet \
    -joliet-long \
    -volid "DAYSHIELD" \
    -publisher "DayShield Project" \
    -appid "DayShield Firewall OS Installer" \
    ${XORRISO_DATE_ARGS[@]+"${XORRISO_DATE_ARGS[@]}"} \
    ${BIOS_ELTORITO_ARGS[@]+"${BIOS_ELTORITO_ARGS[@]}"} \
    ${XORRISO_EXTRA_ARGS[@]+"${XORRISO_EXTRA_ARGS[@]}"} \
    -output "${OUTPUT}" \
    "${ISO_ROOT}"

SHA256_FILE="${OUTPUT}.sha256"

sha256sum "${OUTPUT}" > "${SHA256_FILE}"

echo "--> ISO assembled: ${OUTPUT}"
echo "    SHA256 : $(sha256sum "${OUTPUT}" | cut -d' ' -f1)"
echo "    SHA256 file: ${SHA256_FILE}"
