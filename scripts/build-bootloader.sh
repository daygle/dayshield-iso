#!/usr/bin/env bash
# build-bootloader.sh - Build the hybrid BIOS+UEFI GRUB bootloader images.
#
# Produces:
#   build/bootloader/boot/grub/bios.img   - El Torito BIOS boot image
#   build/bootloader/EFI/efiboot.img      - UEFI FAT EFI System Partition image
#   build/bootloader/boot/grub/grub.cfg   - GRUB configuration (copied from config/)
#   build/bootloader/boot/grub/boot_hybrid.img - MBR hybrid boot sector

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
    # Generate a proper El Torito BIOS boot image for CD boot.
    grub-mkimage \
        --directory="${GRUB_I386_LIB}" \
        --prefix="(cd)/boot/grub" \
        --output="${GRUB_BIOS_DIR}/bios.img" \
        --format="i386-pc-eltorito" \
        --compression="auto" \
        biosdisk iso9660 normal search search_fs_file \
        search_label configfile linux echo all_video gzio part_gpt \
        part_msdos ext2 fat

    # Copy the hybrid MBR boot sector used by xorriso --grub2-mbr.
    # boot_hybrid.img is the combined MBR/GPT hybrid sector; boot.img is the
    # plain MBR-only sector and is NOT a valid substitute.
    _hybrid_found=0
    for _hybrid_path in \
            "${GRUB_I386_LIB}/boot_hybrid.img" \
            /usr/lib/grub/i386-pc/boot_hybrid.img; do
        if [[ -f "${_hybrid_path}" ]]; then
            cp "${_hybrid_path}" "${GRUB_BIOS_DIR}/boot_hybrid.img"
            _hybrid_found=1
            break
        fi
    done
    if [[ "${_hybrid_found}" -eq 0 ]]; then
        echo "WARNING: boot_hybrid.img not found; USB hybrid boot (MBR path) will not work." >&2
        echo "         Install grub-pc-bin or grub-common to enable USB booting." >&2
    fi

    echo "    BIOS image: $(du -sh "${GRUB_BIOS_DIR}/bios.img" | cut -f1)"
else
    echo "WARNING: grub-i386-pc modules not found; BIOS boot will NOT be available." >&2
    echo "         A UEFI-only ISO will be produced." >&2
    # Write a sentinel so assemble-iso.sh knows to omit the BIOS El Torito entry.
    touch "${GRUB_BIOS_DIR}/.bios-boot-unavailable"
fi

# ---------------------------------------------------------------------------
# UEFI: build grubx64.efi and wrap it in a FAT EFI System Partition image
# ---------------------------------------------------------------------------
echo "--> Building GRUB UEFI image …"

if [[ -z "${GRUB_X64_LIB}" ]]; then
    echo "ERROR: grub-x86_64-efi modules not found. Install grub-efi-amd64-bin." >&2
    exit 1
fi

GRUBX64_EFI="${EFI_DIR}/BOOTX64.EFI"

# grub-mkstandalone produces a single self-contained EFI PE32+ binary with all
# modules and the embedded config baked in.  This is what Debian/Ubuntu use and
# is the most portable approach for OVMF / Proxmox UEFI boot.
GRUB_EMBEDDED_CFG="${BUILD_DIR}/grub-embedded.cfg"
cat > "${GRUB_EMBEDDED_CFG}" <<'EMBEDDED_EOF'
search --no-floppy --label --set=root DAYSHIELD
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EMBEDDED_EOF

grub-mkstandalone \
    --directory="${GRUB_X64_LIB}" \
    --format="x86_64-efi" \
    --output="${GRUBX64_EFI}" \
    "boot/grub/grub.cfg=${GRUB_EMBEDDED_CFG}"

if [[ ! -s "${GRUBX64_EFI}" ]]; then
    echo "ERROR: grub-mkstandalone produced an empty BOOTX64.EFI" >&2
    exit 1
fi

echo "    GRUB EFI binary: $(du -sh "${GRUBX64_EFI}" | cut -f1)"

# Copy x86_64-efi modules onto the ISO tree so GRUB can load additional
# modules at runtime from /boot/grub/x86_64-efi/
echo "--> Copying x86_64-efi GRUB modules …"
mkdir -p "${GRUB_BIOS_DIR}/x86_64-efi"
cp "${GRUB_X64_LIB}"/*.mod "${GRUB_BIOS_DIR}/x86_64-efi/" 2>/dev/null || true
[[ -f "${GRUB_X64_LIB}/moddep.lst" ]] && cp "${GRUB_X64_LIB}/moddep.lst" "${GRUB_BIOS_DIR}/x86_64-efi/"
echo "    Modules: $(ls "${GRUB_BIOS_DIR}/x86_64-efi/" | wc -l) files"

# Build the FAT EFI System Partition image (efiboot.img)
EFI_IMG="${BOOT_DIR}/EFI/efiboot.img"
mkdir -p "${BOOT_DIR}/EFI"

# Size: round up to nearest mebibyte; keep at least 16 MiB so we can format
# the ESP as FAT16 for broader firmware compatibility.
EFI_BIN_SIZE=0
[[ -f "${EFI_DIR}/BOOTX64.EFI" ]] && \
    EFI_BIN_SIZE="$(stat -c%s "${EFI_DIR}/BOOTX64.EFI")"
EFI_IMG_MB=$(( (EFI_BIN_SIZE / 1048576) + 4 ))
if [[ "${EFI_IMG_MB}" -lt 16 ]]; then
    EFI_IMG_MB=16
fi

echo "--> Creating EFI System Partition image (${EFI_IMG_MB} MiB) …"
dd if=/dev/zero bs=1M count="${EFI_IMG_MB}" of="${EFI_IMG}" 2>/dev/null
mkfs.fat -F 16 -n "EFI" "${EFI_IMG}"

# Mount and populate
EFI_MOUNT="$(mktemp -d)"
mount -o loop "${EFI_IMG}" "${EFI_MOUNT}"
trap 'umount "${EFI_MOUNT}" 2>/dev/null; rm -rf "${EFI_MOUNT}"' EXIT

mkdir -p "${EFI_MOUNT}/EFI/BOOT" "${EFI_MOUNT}/boot/grub"
[[ -f "${EFI_DIR}/BOOTX64.EFI" ]] && \
    cp "${EFI_DIR}/BOOTX64.EFI" "${EFI_MOUNT}/EFI/BOOT/BOOTX64.EFI"
# Place grub.cfg at the prefix path so GRUB finds it from inside the FAT image
# before the search command locates the ISO root.
cp "${GRUB_BIOS_DIR}/grub.cfg" "${EFI_MOUNT}/boot/grub/grub.cfg"

umount "${EFI_MOUNT}"
rm -rf "${EFI_MOUNT}"
trap - EXIT

echo "    EFI image: $(du -sh "${EFI_IMG}" | cut -f1)"

# ---------------------------------------------------------------------------
# Normalise all timestamps
# ---------------------------------------------------------------------------
find "${BOOT_DIR}" -exec touch -h -t 197001010000 {} + 2>/dev/null || true

echo "--> Bootloader build complete."
