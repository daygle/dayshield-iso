#!/usr/bin/env bash
# shellcheck disable=SC2317
# verify.sh - Verify a DayShield installer ISO.
#
# Checks:
#   1. ISO contains squashfs, kernel, initrd, GRUB config, installer scripts
#   2. squashfs image mounts cleanly (loop mount)
#   3. Optionally boot under QEMU in BIOS and UEFI mode

set -euo pipefail

ISO=""
QEMU_TEST=false
OVMF_PATH=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            [[ $# -ge 2 ]] || { echo "ERROR: --iso requires a value." >&2; exit 1; }
            ISO="$2"; shift 2 ;;
        --qemu)       QEMU_TEST=true; shift ;;
        --ovmf)
            [[ $# -ge 2 ]] || { echo "ERROR: --ovmf requires a value." >&2; exit 1; }
            OVMF_PATH="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: verify.sh --iso <dayshield.iso> [--qemu] [--ovmf /path/to/OVMF.fd]"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${ISO}" ]]; then
    echo "ERROR: --iso <path> is required." >&2
    exit 1
fi

if [[ ! -f "${ISO}" ]]; then
    echo "ERROR: ISO not found: ${ISO}" >&2
    exit 1
fi

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@"; then
        echo "  [PASS] ${desc}"
        PASS=$(( PASS + 1 ))
    else
        echo "  [FAIL] ${desc}"
        FAIL=$(( FAIL + 1 ))
    fi
}

# shellcheck disable=SC2317
is_pe_efi_binary() {
    local file="$1"
    # "4d 5a" is ASCII "MZ", the DOS/PE executable header signature.
    local pe_offset
    od -A n -N 2 -t x1 "${file}" 2>/dev/null | grep -qi "4d 5a" || return 1
    # Offset 0x3C (decimal 60) stores the PE header location in DOS/PE files.
    pe_offset="$(od -An -j 60 -N 4 -tu4 "${file}" 2>/dev/null | tr -d '[:space:]')"
    [[ "${pe_offset}" =~ ^[0-9]+$ ]] || return 1
    od -A n -j "${pe_offset}" -N 4 -t x1 "${file}" 2>/dev/null | grep -qi "50 45 00 00"
}

# shellcheck disable=SC2317
is_userland_present() {
    local sq_mount="$1"
    local candidate

    for candidate in "${sq_mount}/bin" "${sq_mount}/usr/bin"; do
        if [[ -d "${candidate}" ]] && find "${candidate}" -mindepth 1 -print -quit >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

# shellcheck disable=SC2317
qemu_boot_probe() {
    local firmware_path="${1:-}"
    local log_file
    log_file="$(mktemp)"

    if [[ -n "${firmware_path}" ]]; then
        timeout "${QEMU_TIMEOUT}" \
            qemu-system-x86_64 \
                -nographic \
                -no-reboot \
                -m 1024M \
                -bios "${firmware_path}" \
                -cdrom "${ISO}" \
                -boot d \
                >"${log_file}" 2>&1 || true
    else
        timeout "${QEMU_TIMEOUT}" \
            qemu-system-x86_64 \
                -nographic \
                -no-reboot \
                -m 1024M \
                -cdrom "${ISO}" \
                -boot d \
                >"${log_file}" 2>&1 || true
    fi

    if grep -Eqi 'GNU GRUB|Linux version [0-9]|Booting .*DayShield|loading linux' "${log_file}"; then
        rm -f "${log_file}"
        return 0
    fi

    rm -f "${log_file}"
    return 1
}

# ---------------------------------------------------------------------------
# Mount the ISO read-only
# ---------------------------------------------------------------------------
ISO_MOUNT="$(mktemp -d)"
mount -o loop,ro "${ISO}" "${ISO_MOUNT}"
SQ_MOUNT=""
# shellcheck disable=SC2317
cleanup() {
    umount "${SQ_MOUNT:-}" 2>/dev/null || true
    rm -rf  "${SQ_MOUNT:-}" 2>/dev/null || true
    umount "${ISO_MOUNT}" 2>/dev/null || true
    rm -rf  "${ISO_MOUNT}" 2>/dev/null || true
}
trap cleanup EXIT

echo ""
echo "==> Verifying ISO content: ${ISO}"
echo ""

# ---------------------------------------------------------------------------
# 1. Required files
# ---------------------------------------------------------------------------
echo "--- Required files ---"
check "live/filesystem.squashfs exists"    test -f "${ISO_MOUNT}/live/filesystem.squashfs"
check "boot/vmlinuz exists"                test -f "${ISO_MOUNT}/boot/vmlinuz"
check "boot/initrd.img exists"             test -f "${ISO_MOUNT}/boot/initrd.img"
check "boot/grub/grub.cfg exists"          test -f "${ISO_MOUNT}/boot/grub/grub.cfg"
# bios.img is optional for UEFI-only ISOs (grub-i386-pc absent at build time).
if test -f "${ISO_MOUNT}/boot/grub/bios.img"; then
    check "boot/grub/bios.img is non-empty (BIOS boot available)" \
        test -s "${ISO_MOUNT}/boot/grub/bios.img"
else
    echo "  [INFO] boot/grub/bios.img absent - UEFI-only ISO"
fi
check "EFI/BOOT/BOOTX64.EFI exists"        test -f "${ISO_MOUNT}/EFI/BOOT/BOOTX64.EFI"
check "EFI/BOOT/BOOTX64.EFI is non-empty"  test -s "${ISO_MOUNT}/EFI/BOOT/BOOTX64.EFI"
check "EFI/BOOT/BOOTX64.EFI is PE32+ EFI" \
    is_pe_efi_binary "${ISO_MOUNT}/EFI/BOOT/BOOTX64.EFI"
check "EFI/efiboot.img exists"            test -f "${ISO_MOUNT}/EFI/efiboot.img"
check "installer/install.sh exists"        test -f "${ISO_MOUNT}/installer/install.sh"
check "installer/partition.sh exists"      test -f "${ISO_MOUNT}/installer/partition.sh"
check "installer/copy-rootfs.sh exists"    test -f "${ISO_MOUNT}/installer/copy-rootfs.sh"
check "installer/firstboot.service exists" test -f "${ISO_MOUNT}/installer/firstboot.service"
check "installer/rootfs.tar.zst exists"      test -f "${ISO_MOUNT}/installer/rootfs.tar.zst"
check "installer-ui/index.html exists"      test -f "${ISO_MOUNT}/installer-ui/index.html"
check "installer-ui/app.js exists"          test -f "${ISO_MOUNT}/installer-ui/app.js"
check "installer-ui/alpine.min.js exists"    test -f "${ISO_MOUNT}/installer-ui/alpine.min.js"
check "installer-ui/tailwind.min.js exists"  test -f "${ISO_MOUNT}/installer-ui/tailwind.min.js"
check "installer-ui/httpd.conf exists"      test -f "${ISO_MOUNT}/installer-ui/httpd.conf"

# ---------------------------------------------------------------------------
# 2. squashfs mounts cleanly
# ---------------------------------------------------------------------------
echo ""
echo "--- squashfs mount ---"
SQ_MOUNT="$(mktemp -d)"

mount -t squashfs -o loop,ro \
    "${ISO_MOUNT}/live/filesystem.squashfs" "${SQ_MOUNT}" 2>/dev/null
check "squashfs mounts without error"          test -f "${SQ_MOUNT}/etc/os-release"
check "squashfs /bin or /usr/bin is populated" \
    is_userland_present "${SQ_MOUNT}"
check "squashfs /usr/lib/dayshield-installer/install.sh exists" \
    test -f "${SQ_MOUNT}/usr/lib/dayshield-installer/install.sh"
check "squashfs /usr/lib/dayshield-installer/firstboot-run.sh exists" \
    test -f "${SQ_MOUNT}/usr/lib/dayshield-installer/firstboot-run.sh"
check "squashfs /usr/local/lib/dayshield/installer-finalize.sh exists" \
    test -f "${SQ_MOUNT}/usr/local/lib/dayshield/installer-finalize.sh"
check "squashfs /usr/bin/ostree exists" \
    test -x "${SQ_MOUNT}/usr/bin/ostree"
check "squashfs /usr/local/lib/dayshield/ostree-update.sh exists" \
    test -x "${SQ_MOUNT}/usr/local/lib/dayshield/ostree-update.sh"
check "squashfs /installer-ui/index.html exists" \
    test -f "${SQ_MOUNT}/installer-ui/index.html"
check "CLI installer invokes shared finalization helper" \
    grep -q '/usr/local/lib/dayshield/installer-finalize\.sh' "${SQ_MOUNT}/usr/lib/dayshield-installer/install.sh"
check "CLI installer includes DAYSHIELD media-label fallback" \
    grep -q 'LABEL=DAYSHIELD' "${SQ_MOUNT}/usr/lib/dayshield-installer/install.sh"
check "CLI installer checks alternate live-media squashfs paths" \
    grep -q '/media/cdrom/live/filesystem\.squashfs' "${SQ_MOUNT}/usr/lib/dayshield-installer/install.sh"
check "finalization helper writes admin auth store contract" \
    grep -q '/etc/dayshield/admin\.json' "${SQ_MOUNT}/usr/local/lib/dayshield/installer-finalize.sh"
check "finalization helper writes core config.json contract" \
    grep -q '/etc/dayshield/config/config\.json' "${SQ_MOUNT}/usr/local/lib/dayshield/installer-finalize.sh"
check "finalization helper writes nftables interface mapping contract" \
    grep -q '/etc/dayshield/config/nft-ifaces\.conf' "${SQ_MOUNT}/usr/local/lib/dayshield/installer-finalize.sh"
check "finalization helper seeds DHCP contract" \
    grep -q '/etc/dayshield/kea-dhcp4\.conf' "${SQ_MOUNT}/usr/local/lib/dayshield/installer-finalize.sh"
check "finalization helper seeds Unbound contract" \
    grep -q '/etc/unbound/unbound\.conf' "${SQ_MOUNT}/usr/local/lib/dayshield/installer-finalize.sh"
check "firstboot consumes marker before dayshield startup" \
    awk '/Consuming firstboot marker/{consume=NR} /systemctl start dayshield\.service/{start=NR} END{exit !(consume>0 && start>0 && consume<start)}' \
        "${SQ_MOUNT}/usr/lib/dayshield-installer/firstboot-run.sh"
umount "${SQ_MOUNT}" && rm -rf "${SQ_MOUNT}"
SQ_MOUNT=""

# ---------------------------------------------------------------------------
# 3. GRUB config sanity
# ---------------------------------------------------------------------------
echo ""
echo "--- GRUB config ---"
check "grub.cfg contains 'linux'"       grep -q 'linux\b' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg contains 'initrd'"      grep -q 'initrd\b' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg contains 'filesystem'"  grep -q 'filesystem' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg keeps live-config scope narrowed" \
    grep -q 'live-config\.components=hostname' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg includes fsck.mode=skip noise guard" \
    grep -q 'fsck\.mode=skip' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg includes UEFI local-disk fallback entry" \
    grep -q 'menuentry "Boot from local disk (UEFI firmware)"' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg includes BIOS local-disk fallback entry" \
    grep -q 'menuentry "Boot from local disk (BIOS)"' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg BIOS fallback tries alternate disk" \
    grep -q 'set root=(hd1)' "${ISO_MOUNT}/boot/grub/grub.cfg"

# ---------------------------------------------------------------------------
# 4. El Torito / boot metadata
# ---------------------------------------------------------------------------
echo ""
echo "--- Boot metadata ---"
if command -v xorriso &>/dev/null; then
    ELTORITO_TMP="$(mktemp)"
    xorriso -indev "${ISO}" -report_el_torito plain 2>/dev/null > "${ELTORITO_TMP}" || true
    if check "El Torito report contains UEFI boot image" \
           grep -Eq 'El Torito boot img.*UEFI|efiboot\.img' "${ELTORITO_TMP}"; then
        true
    fi
    # BIOS El Torito entry is optional for UEFI-only ISOs.
    if ! test -f "${ISO_MOUNT}/boot/grub/bios.img"; then
        echo "  [INFO] Skipping BIOS El Torito check (UEFI-only ISO - bios.img absent)"
    elif check "El Torito report contains BIOS boot image" \
           grep -q 'bios\.img' "${ELTORITO_TMP}"; then
        true
    fi
    if [[ ${FAIL} -gt 0 ]]; then
        echo "  xorriso report output:"
        sed 's/^/    /' "${ELTORITO_TMP}"
    fi
    rm -f "${ELTORITO_TMP}"
else
    echo "  [SKIP] xorriso not found; skipping El Torito metadata checks"
fi

# ---------------------------------------------------------------------------
# 5. initrd is non-empty
# ---------------------------------------------------------------------------
echo ""
echo "--- initrd ---"
INITRD_SIZE="$(stat -c%s "${ISO_MOUNT}/boot/initrd.img")"
check "initrd.img is non-empty (size=${INITRD_SIZE})"  test "${INITRD_SIZE}" -gt 0

# ---------------------------------------------------------------------------
# 6. QEMU boot tests (optional, require root and QEMU)
# ---------------------------------------------------------------------------
if ${QEMU_TEST}; then
    echo ""
    echo "--- QEMU boot tests ---"

    if ! command -v qemu-system-x86_64 &>/dev/null; then
        echo "  [SKIP] qemu-system-x86_64 not found"
    else
        QEMU_TIMEOUT="${QEMU_TIMEOUT:-90}"

        check "BIOS QEMU shows boot output" qemu_boot_probe

        if [[ -n "${OVMF_PATH}" ]] && [[ -f "${OVMF_PATH}" ]]; then
            check "UEFI QEMU shows boot output" qemu_boot_probe "${OVMF_PATH}"
        else
            echo "  [SKIP] UEFI test skipped (use --ovmf /path/to/OVMF.fd)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==> Verification summary: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
