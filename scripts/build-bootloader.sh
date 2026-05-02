#!/usr/bin/env bash
# build-bootloader.sh — Build the hybrid BIOS+UEFI GRUB bootloader images.
#
# Produces:
#   build/bootloader/boot/grub/bios.img   — El Torito BIOS boot image
#   build/bootloader/EFI/efiboot.img      — UEFI FAT EFI System Partition image
#   build/bootloader/boot/grub/grub.cfg   — GRUB configuration (copied from config/)
#   build/bootloader/boot/grub/boot_hybrid.img — MBR hybrid boot sector

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BUILD_DIR:="${SCRIPT_DIR}/../build"}"
: "${CONFIG_DIR:="${SCRIPT_DIR}/../config"}"
: "${ARCH:="amd64"}"

BOOT_DIR="${BUILD_DIR}/bootloader"
GRUB_BIOS_DIR="${BOOT_DIR}/boot/grub"
EFI_DIR="${BOOT_DIR}/EFI/BOOT"

mkdir -p "${GRUB_BIOS_DIR}" "${EFI_DIR}"

# ---------------------------------------------------------------------------
# Locate GRUB modules
# ---------------------------------------------------------------------------
GRUB_I386_LIB=""
for d in /usr/lib/grub/i386-pc /usr/share/grub/i386-pc; do
    [[ -d "$d" ]] && GRUB_I386_LIB="$d" && break
done

GRUB_X64_LIB=""
for d in /usr/lib/grub/x86_64-efi /usr/share/grub/x86_64-efi; do
    [[ -d "$d" ]] && GRUB_X64_LIB="$d" && break
done

# ---------------------------------------------------------------------------
# Copy GRUB configuration
# ---------------------------------------------------------------------------
echo "--> Copying GRUB configuration …"
cp "${CONFIG_DIR}/grub.cfg" "${GRUB_BIOS_DIR}/grub.cfg"
# Copy splash image if present
[[ -f "${CONFIG_DIR}/splash.png" ]] && \
    cp "${CONFIG_DIR}/splash.png" "${GRUB_BIOS_DIR}/splash.png"

# ---------------------------------------------------------------------------
# BIOS: build core.img + embed into bios.img
# ---------------------------------------------------------------------------
echo "--> Building GRUB BIOS image …"

if [[ -n "${GRUB_I386_LIB}" ]]; then
    # Generate core.img
    grub-mkimage \
        --directory="${GRUB_I386_LIB}" \
        --prefix="(cd)/boot/grub" \
        --output="${GRUB_BIOS_DIR}/core.img" \
        --format="i386-pc" \
        --compression="auto" \
        biosdisk iso9660 normal search search_fs_file \
        search_label configfile linux echo all_video gzio part_gpt \
        part_msdos ext2 fat

    # Concatenate cdboot.img + core.img → bios.img (El Torito boot image)
    if [[ -f "${GRUB_I386_LIB}/cdboot.img" ]]; then
        cat "${GRUB_I386_LIB}/cdboot.img" "${GRUB_BIOS_DIR}/core.img" \
            > "${GRUB_BIOS_DIR}/bios.img"
    else
        cp "${GRUB_BIOS_DIR}/core.img" "${GRUB_BIOS_DIR}/bios.img"
    fi

    # Copy the hybrid MBR boot sector used by xorriso --grub2-mbr
    if [[ -f "${GRUB_I386_LIB}/boot_hybrid.img" ]]; then
        cp "${GRUB_I386_LIB}/boot_hybrid.img" "${GRUB_BIOS_DIR}/boot_hybrid.img"
    elif [[ -f "${GRUB_I386_LIB}/boot.img" ]]; then
        cp "${GRUB_I386_LIB}/boot.img" "${GRUB_BIOS_DIR}/boot_hybrid.img"
    fi

    echo "    BIOS image: $(du -sh "${GRUB_BIOS_DIR}/bios.img" | cut -f1)"
else
    echo "WARNING: grub-i386-pc modules not found; BIOS boot may not work." >&2
    # Create a dummy placeholder so assemble-iso.sh does not fail
    dd if=/dev/zero bs=512 count=2 of="${GRUB_BIOS_DIR}/bios.img" 2>/dev/null
    touch "${GRUB_BIOS_DIR}/boot_hybrid.img"
fi

# ---------------------------------------------------------------------------
# UEFI: build grubx64.efi and wrap it in a FAT EFI System Partition image
# ---------------------------------------------------------------------------
echo "--> Building GRUB UEFI image …"

if [[ -n "${GRUB_X64_LIB}" ]]; then
    GRUBX64_EFI="${EFI_DIR}/BOOTX64.EFI"

    grub-mkimage \
        --directory="${GRUB_X64_LIB}" \
        --prefix="(cd)/boot/grub" \
        --output="${GRUBX64_EFI}" \
        --format="x86_64-efi" \
        --compression="auto" \
        iso9660 normal search search_fs_file search_label configfile \
        linux echo all_video gzio part_gpt part_msdos ext2 fat efifwsetup

    echo "    GRUB EFI binary: $(du -sh "${GRUBX64_EFI}" | cut -f1)"
else
    echo "WARNING: grub-x86_64-efi modules not found; UEFI boot may not work." >&2
    touch "${EFI_DIR}/BOOTX64.EFI"
fi

# Build the FAT EFI System Partition image (efiboot.img)
EFI_IMG="${BOOT_DIR}/EFI/efiboot.img"
mkdir -p "${BOOT_DIR}/EFI"

# Size: round up to nearest mebibyte; at least 4 MiB
EFI_BIN_SIZE=0
[[ -f "${EFI_DIR}/BOOTX64.EFI" ]] && \
    EFI_BIN_SIZE="$(stat -c%s "${EFI_DIR}/BOOTX64.EFI")"
EFI_IMG_MB=$(( (EFI_BIN_SIZE / 1048576) + 4 ))

echo "--> Creating EFI System Partition image (${EFI_IMG_MB} MiB) …"
dd if=/dev/zero bs=1M count="${EFI_IMG_MB}" of="${EFI_IMG}" 2>/dev/null
mkfs.fat -F 12 -n "EFI" "${EFI_IMG}"

# Mount and populate
EFI_MOUNT="$(mktemp -d)"
mount -o loop "${EFI_IMG}" "${EFI_MOUNT}"
trap 'umount "${EFI_MOUNT}" 2>/dev/null; rm -rf "${EFI_MOUNT}"' EXIT

mkdir -p "${EFI_MOUNT}/EFI/BOOT"
[[ -f "${EFI_DIR}/BOOTX64.EFI" ]] && \
    cp "${EFI_DIR}/BOOTX64.EFI" "${EFI_MOUNT}/EFI/BOOT/BOOTX64.EFI"
cp "${GRUB_BIOS_DIR}/grub.cfg" "${EFI_MOUNT}/EFI/BOOT/grub.cfg" 2>/dev/null || true

umount "${EFI_MOUNT}"
rm -rf "${EFI_MOUNT}"
trap - EXIT

echo "    EFI image: $(du -sh "${EFI_IMG}" | cut -f1)"

# ---------------------------------------------------------------------------
# Normalise all timestamps
# ---------------------------------------------------------------------------
find "${BOOT_DIR}" -exec touch -h -t 197001010000 {} + 2>/dev/null || true

echo "--> Bootloader build complete."
