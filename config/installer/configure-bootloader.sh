#!/usr/bin/env bash
# configure-bootloader.sh - Install and configure GRUB on the target system.
#
# Installs GRUB for:
#   • BIOS boot  (i386-pc target via grub-install)
#   • UEFI boot  (x86_64-efi target via grub-install)
#
# Usage: configure-bootloader.sh <disk> <target-mountpoint>

set -euo pipefail

DISK="${1:?"Usage: configure-bootloader.sh <disk> <target-mountpoint>"}"
TARGET="${2:?"Usage: configure-bootloader.sh <disk> <target-mountpoint>"}"

[[ -b "${DISK}" ]]  || { echo "ERROR: Not a block device: ${DISK}" >&2; exit 1; }
[[ -d "${TARGET}" ]] || { echo "ERROR: Target mountpoint not found: ${TARGET}" >&2; exit 1; }

echo "--> Preparing chroot environment …"

# Bind-mount pseudo-filesystems into the target
for fs in dev dev/pts proc sys run; do
    mkdir -p "${TARGET}/${fs}"
    mount --bind "/${fs}" "${TARGET}/${fs}"
done

cleanup_chroot() {
    for fs in run sys proc dev/pts dev; do
        umount -lf "${TARGET}/${fs}" 2>/dev/null || true
    done
}
trap cleanup_chroot EXIT

# ---------------------------------------------------------------------------
# Install GRUB inside the chroot
# ---------------------------------------------------------------------------
echo "--> Installing GRUB (BIOS) …"
chroot "${TARGET}" grub-install \
    --target=i386-pc \
    --recheck \
    --no-floppy \
    "${DISK}" || \
    echo "WARNING: BIOS grub-install failed (BIOS boot may not work on this system)" >&2

echo "--> Installing GRUB (UEFI) …"
chroot "${TARGET}" grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=dayshield \
    --recheck \
    --no-nvram \
    || { echo "ERROR: UEFI grub-install failed - UEFI boot will not work. Aborting." >&2; exit 1; }

# Copy the EFI binary to the UEFI spec fallback path (/EFI/BOOT/BOOTX64.EFI).
# --no-nvram skips writing an NVRAM boot variable; without the fallback path,
# firmware that only scans NVRAM or /EFI/BOOT/ will fail to find a boot loader.
mkdir -p "${TARGET}/boot/efi/EFI/BOOT"
cp "${TARGET}/boot/efi/EFI/dayshield/grubx64.efi" \
   "${TARGET}/boot/efi/EFI/BOOT/BOOTX64.EFI"

find_latest_boot_file() {
    local dir="$1" prefix="$2" exact="$3" candidate=""
    if [[ -e "${dir}/${exact}" ]]; then
        printf '%s\n' "${dir}/${exact}"
        return 0
    fi
    candidate="$(find "${dir}" -maxdepth 1 -name "${prefix}*" | sort | tail -n1)"
    [[ -n "${candidate}" ]] || return 1
    printf '%s\n' "${candidate}"
}

install_slot_boot_files() {
    local slot="$1" source_boot="$2" dest="${TARGET}/boot/dayshield/slot-${slot}"
    local kernel initrd
    kernel="$(find_latest_boot_file "${source_boot}" "vmlinuz-" "vmlinuz")"
    initrd="$(find_latest_boot_file "${source_boot}" "initrd.img-" "initrd.img")"
    mkdir -p "${dest}"
    cp "${kernel}" "${dest}/vmlinuz"
    cp "${initrd}" "${dest}/initrd.img"
}

BOOT_UUID="$(blkid -s UUID -o value "$(blkid -L DAYSHIELD_BOOT)")"
ROOT_A_UUID="$(blkid -s UUID -o value "$(blkid -L DAYSHIELD_ROOT_A)")"
ROOT_B_UUID="$(blkid -s UUID -o value "$(blkid -L DAYSHIELD_ROOT_B)")"

echo "--> Installing DayShield A/B boot entries ..."
install_slot_boot_files "a" "${TARGET}/boot"
install_slot_boot_files "b" "${TARGET}/boot"
cat > "${TARGET}/etc/grub.d/09_dayshield_ab" <<EOF
#!/bin/sh
set -e
cat <<'GRUB_EOF'
menuentry 'DayShield slot A' --id 'dayshield-a' {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /dayshield/slot-a/vmlinuz root=UUID=${ROOT_A_UUID} ro quiet splash
    initrd /dayshield/slot-a/initrd.img
}

menuentry 'DayShield slot B' --id 'dayshield-b' {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /dayshield/slot-b/vmlinuz root=UUID=${ROOT_B_UUID} ro quiet splash
    initrd /dayshield/slot-b/initrd.img
}
GRUB_EOF
EOF
chmod 755 "${TARGET}/etc/grub.d/09_dayshield_ab"

# ---------------------------------------------------------------------------
# Write GRUB default configuration
# ---------------------------------------------------------------------------
echo "--> Writing /etc/default/grub …"
cat > "${TARGET}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="DayShield"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL_INPUT=console
GRUB_GFXMODE=auto
EOF

# ---------------------------------------------------------------------------
# Generate grub.cfg inside the chroot
# ---------------------------------------------------------------------------
echo "--> Running grub-mkconfig …"
chroot "${TARGET}" grub-mkconfig -o /boot/grub/grub.cfg

cleanup_chroot
trap - EXIT

echo "--> Bootloader configuration complete."
