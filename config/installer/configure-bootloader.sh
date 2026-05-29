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

# ---------------------------------------------------------------------------
# Suppress grub-mkconfig - we manage grub.cfg by hand for the A/B layout.
# Remove any prior auto-generated fragments that would interfere.
# ---------------------------------------------------------------------------
rm -f "${TARGET}/etc/grub.d/09_dayshield" \
      "${TARGET}/etc/grub.d/09_dayshield_ab" \
      "${TARGET}/etc/grub.d/10_linux" \
      "${TARGET}/etc/grub.d/30_os-prober"

echo "--> Writing /etc/default/grub (minimal — grub.cfg is hand-managed) …"
cat > "${TARGET}/etc/default/grub" <<'EOF'
# This file is intentionally minimal.  DayShield manages /boot/grub/grub.cfg
# directly to implement the A/B slot scheme; grub-mkconfig is not used.
GRUB_DEFAULT=saved
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_DISTRIBUTOR="DayShield"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL_INPUT=console
GRUB_DISABLE_OS_PROBER=true
EOF

# ---------------------------------------------------------------------------
# Hand-write grub.cfg with A/B menuentries + grubenv slot routing.
# See dayshield-installer-ui/installer-ui/api/install-bootloader.sh for the
# same logic in the web-installer path — keep both in sync.
# ---------------------------------------------------------------------------
echo "--> Writing /boot/grub/grub.cfg (A/B slot layout) …"
mkdir -p "${TARGET}/boot/grub"
cat > "${TARGET}/boot/grub/grub.cfg" <<'GRUB_EOF'
set timeout=0
set timeout_style=hidden

load_env

if [ -z "${saved_entry}" ];   then set saved_entry=ds_a;     fi
if [ -z "${boot_state}" ];    then set boot_state=confirmed; fi

if [ "${boot_state}" = "trying" ]; then
    if [ "${boot_attempts_left}" = "0" ] && [ -n "${fallback_entry}" ]; then
        set default="${fallback_entry}"
    else
        set default="${saved_entry}"
    fi
else
    set default="${saved_entry}"
fi

if [ "${boot_state}" = "trying" ]; then
    if [ "${boot_attempts_left}" = "3" ]; then
        set boot_attempts_left=2
        save_env boot_attempts_left
    elif [ "${boot_attempts_left}" = "2" ]; then
        set boot_attempts_left=1
        save_env boot_attempts_left
    elif [ "${boot_attempts_left}" = "1" ]; then
        set boot_attempts_left=0
        save_env boot_attempts_left
    fi
fi

menuentry 'DayShield (slot A)' --id ds_a {
    search --no-floppy --label DAYSHIELD_BOOT --set=root
    linux /dayshield/slot-a/vmlinuz root=LABEL=DS_ROOT_A ro
    initrd /dayshield/slot-a/initrd.img
}

menuentry 'DayShield (slot B)' --id ds_b {
    search --no-floppy --label DAYSHIELD_BOOT --set=root
    linux /dayshield/slot-b/vmlinuz root=LABEL=DS_ROOT_B ro
    initrd /dayshield/slot-b/initrd.img
}
GRUB_EOF

# Seed grubenv with a clean install state — slot A is the active slot.
chroot "${TARGET}" grub-editenv /boot/grub/grubenv create 2>/dev/null || true
chroot "${TARGET}" grub-editenv /boot/grub/grubenv set saved_entry=ds_a
chroot "${TARGET}" grub-editenv /boot/grub/grubenv set boot_state=confirmed
chroot "${TARGET}" grub-editenv /boot/grub/grubenv unset boot_attempts_left 2>/dev/null || true
chroot "${TARGET}" grub-editenv /boot/grub/grubenv unset fallback_entry     2>/dev/null || true

cleanup_chroot
trap - EXIT

echo "--> Bootloader configuration complete."
