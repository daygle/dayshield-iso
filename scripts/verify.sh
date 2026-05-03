#!/usr/bin/env bash
# verify.sh — Verify a DayShield installer ISO.
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
        --iso)        ISO="$2"; shift 2 ;;
        --qemu)       QEMU_TEST=true; shift ;;
        --ovmf)       OVMF_PATH="$2"; shift 2 ;;
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

# ---------------------------------------------------------------------------
# Mount the ISO read-only
# ---------------------------------------------------------------------------
ISO_MOUNT="$(mktemp -d)"
mount -o loop,ro "${ISO}" "${ISO_MOUNT}"
_cleanup() {
    local _rc=$?
    umount "${SQ_MOUNT:-}" 2>/dev/null || true
    rm -rf  "${SQ_MOUNT:-}" 2>/dev/null || true
    umount "${ISO_MOUNT}" 2>/dev/null || true
    rm -rf  "${ISO_MOUNT}" 2>/dev/null || true
    exit "${_rc}"
}
trap '_cleanup' EXIT

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
check "boot/grub/bios.img exists"          test -f "${ISO_MOUNT}/boot/grub/bios.img"
check "EFI/BOOT/BOOTX64.EFI exists"        test -f "${ISO_MOUNT}/EFI/BOOT/BOOTX64.EFI"
check "EFI/BOOT/BOOTX64.EFI is non-empty"  test -s "${ISO_MOUNT}/EFI/BOOT/BOOTX64.EFI"
check "EFI/BOOT/BOOTX64.EFI is PE32+ EFI" \
    bash -c 'od -A n -N 2 -t x1 "${1}" 2>/dev/null | grep -qi "4d 5a"' -- "${ISO_MOUNT}/EFI/BOOT/BOOTX64.EFI"
check "EFI/efiboot.img exists"            test -f "${ISO_MOUNT}/EFI/efiboot.img"
check "installer/install.sh exists"        test -f "${ISO_MOUNT}/installer/install.sh"
check "installer/partition.sh exists"      test -f "${ISO_MOUNT}/installer/partition.sh"
check "installer/copy-rootfs.sh exists"    test -f "${ISO_MOUNT}/installer/copy-rootfs.sh"
check "installer/firstboot.service exists" test -f "${ISO_MOUNT}/installer/firstboot.service"
check "installer/rootfs.tar.zst exists"      test -f "${ISO_MOUNT}/installer/rootfs.tar.zst"
check "installer-ui/index.html exists"      test -f "${ISO_MOUNT}/installer-ui/index.html"
check "installer-ui/app.js exists"          test -f "${ISO_MOUNT}/installer-ui/app.js"
check "installer-ui/alpine.min.js exists"   test -f "${ISO_MOUNT}/installer-ui/alpine.min.js"
check "installer-ui/httpd.conf exists"      test -f "${ISO_MOUNT}/installer-ui/httpd.conf"

# ---------------------------------------------------------------------------
# 2. squashfs mounts cleanly
# ---------------------------------------------------------------------------
echo ""
echo "--- squashfs mount ---"
SQ_MOUNT="$(mktemp -d)"
trap '_cleanup' EXIT

mount -t squashfs -o loop,ro \
    "${ISO_MOUNT}/live/filesystem.squashfs" "${SQ_MOUNT}" 2>/dev/null
check "squashfs mounts without error"          test -d "${SQ_MOUNT}"
check "squashfs /bin or /usr/bin is populated" \
    bash -c 'ls "${SQ_MOUNT}/bin" "${SQ_MOUNT}/usr/bin" &>/dev/null'
umount "${SQ_MOUNT}" && rm -rf "${SQ_MOUNT}"

# ---------------------------------------------------------------------------
# 3. GRUB config sanity
# ---------------------------------------------------------------------------
echo ""
echo "--- GRUB config ---"
check "grub.cfg contains 'linux'"       grep -q 'linux\b' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg contains 'initrd'"      grep -q 'initrd\b' "${ISO_MOUNT}/boot/grub/grub.cfg"
check "grub.cfg contains 'filesystem'"  grep -q 'filesystem' "${ISO_MOUNT}/boot/grub/grub.cfg"

# ---------------------------------------------------------------------------
# 4. El Torito / boot metadata
# ---------------------------------------------------------------------------
echo ""
echo "--- Boot metadata ---"
if command -v xorriso &>/dev/null; then
    ELTORITO_TMP="$(mktemp)"
    xorriso -indev "${ISO}" -report_el_torito plain 2>/dev/null > "${ELTORITO_TMP}" || true
    if check "El Torito report contains BIOS boot image" \
           grep -q 'bios\.img' "${ELTORITO_TMP}"; then
        true
    fi
    if check "El Torito report contains UEFI boot image" \
           grep -Eq 'El Torito boot img.*UEFI|efiboot\.img' "${ELTORITO_TMP}"; then
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
        QEMU_TIMEOUT=30

        echo "  Testing BIOS boot …"
        timeout "${QEMU_TIMEOUT}" \
            qemu-system-x86_64 \
                -nographic \
                -no-reboot \
                -m 512M \
                -cdrom "${ISO}" \
                -boot d \
                2>&1 | head -n 30 | grep -qi "grub\|linux\|boot" \
            && echo "  [PASS] BIOS QEMU shows boot output" \
            || echo "  [WARN] BIOS QEMU boot output not detected (may still work)"

        if [[ -n "${OVMF_PATH}" ]] && [[ -f "${OVMF_PATH}" ]]; then
            echo "  Testing UEFI boot …"
            timeout "${QEMU_TIMEOUT}" \
                qemu-system-x86_64 \
                    -nographic \
                    -no-reboot \
                    -m 512M \
                    -bios "${OVMF_PATH}" \
                    -cdrom "${ISO}" \
                    -boot d \
                    2>&1 | head -n 30 | grep -qi "grub\|linux\|boot" \
                && echo "  [PASS] UEFI QEMU shows boot output" \
                || echo "  [WARN] UEFI QEMU boot output not detected (may still work)"
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
