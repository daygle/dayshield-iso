#!/usr/bin/env bash
# build-iso.sh - Main entrypoint for the DayShield ISO builder.
#
# Usage:
#   build-iso.sh [--rootfs rootfs.tar.zst] [--rootfs-sha256 <sha256>] [--installer-ui path] [--output dayshield.iso] [--arch amd64]
#
# All sub-scripts are expected to live alongside this script.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ROOTFS=""
OUTPUT="dayshield.iso"
ARCH="amd64"
INSTALLER_UI_DIR=""
ROOTFS_SHA256=""
: "${ALLOW_NETWORK_FETCH:="0"}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs)
            ROOTFS="$2"; shift 2 ;;
        --output)
            OUTPUT="$2"; shift 2 ;;
        --arch)
            ARCH="$2"; shift 2 ;;
        --installer-ui)
            INSTALLER_UI_DIR="$2"; shift 2 ;;
        --rootfs-sha256)
            ROOTFS_SHA256="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1 ;;
    esac
done

if [[ -z "${ROOTFS}" ]]; then
    echo "ERROR: --rootfs <rootfs.tar.zst> is required." >&2
    exit 1
fi

if [[ -z "${INSTALLER_UI_DIR}" ]]; then
    echo "ERROR: --installer-ui <path-to-installer-ui-dir> is required." >&2
    exit 1
fi

if [[ ! -f "${ROOTFS}" ]]; then
    echo "ERROR: rootfs archive not found: ${ROOTFS}" >&2
    exit 1
fi

# Resolve paths to absolute paths.
ROOTFS="$(realpath "${ROOTFS}")"
OUTPUT_DIR="$(dirname "${OUTPUT}")"
if [[ "${OUTPUT_DIR}" != "." ]] && [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi
OUTPUT="$(cd "${OUTPUT_DIR}" && pwd -P)/$(basename "${OUTPUT}")"

verify_rootfs_archive() {
    local archive="$1"
    local expected_hash="${2:-}"
    local sidecar_hash=""

    if [[ -z "${expected_hash}" ]] && [[ -f "${archive}.sha256" ]]; then
        sidecar_hash="$(awk '{print $1; exit}' "${archive}.sha256" | tr -d '[:space:]')"
        expected_hash="${sidecar_hash}"
    fi

    if [[ -z "${expected_hash}" ]]; then
        echo "ERROR: rootfs checksum verification is required." >&2
        echo "       Provide --rootfs-sha256 <sha256> or ${archive}.sha256." >&2
        exit 1
    fi

    if ! [[ "${expected_hash}" =~ ^[A-Fa-f0-9]{64}$ ]]; then
        echo "ERROR: invalid SHA256 value for rootfs: ${expected_hash}" >&2
        exit 1
    fi

    local actual_hash
    actual_hash="$(sha256sum "${archive}" | awk '{print $1}')"
    if [[ "${actual_hash}" != "${expected_hash,,}" ]]; then
        echo "ERROR: rootfs SHA256 mismatch." >&2
        echo "       expected: ${expected_hash,,}" >&2
        echo "       actual  : ${actual_hash}" >&2
        exit 1
    fi
}

verify_rootfs_archive "${ROOTFS}" "${ROOTFS_SHA256}"

# ---------------------------------------------------------------------------
# Build directory (deterministic structure inside working directory)
# ---------------------------------------------------------------------------
BUILD_DIR="${REPO_ROOT}/build"
export BUILD_DIR ARCH CONFIG_DIR REPO_ROOT ALLOW_NETWORK_FETCH

echo "==> DayShield ISO Builder"
echo "    rootfs  : ${ROOTFS}"
echo "    output  : ${OUTPUT}"
echo "    arch    : ${ARCH}"
echo "    build   : ${BUILD_DIR}"
echo "    installer-ui: ${INSTALLER_UI_DIR}"
echo "    allow-network-fetch: ${ALLOW_NETWORK_FETCH}"

validate_installer_ui() {
    local dir="$1"
    local missing=0
    for file in index.html styles.css app.js alpine.min.js tailwind.min.js httpd.conf systemd/installer-ui.service systemd/installer-ui-web.service; do
        if [ ! -e "${dir}/${file}" ]; then
            echo "ERROR: missing installer UI asset: ${file}" >&2
            missing=1
        fi
    done
    if [ "${missing}" -ne 0 ]; then
        exit 1
    fi
}

validate_installer_ui "${INSTALLER_UI_DIR}"

# ---------------------------------------------------------------------------
# Helper: run a sub-script with consistent environment
# ---------------------------------------------------------------------------
run_step() {
    local step="$1"; shift
    echo ""
    echo "------------------------------------------------------------"
    echo "STEP: ${step}"
    echo "------------------------------------------------------------"
    "${SCRIPT_DIR}/${step}" "$@"
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
run_step extract-rootfs.sh  --rootfs "${ROOTFS}"

# Inject installer UI files into the live rootfs before squashfs is built
run_step inject-installer-ui.sh --installer-ui "${INSTALLER_UI_DIR}"

# Embed CLI installer scripts into the live rootfs BEFORE the squashfs is
# frozen.  This ensures /usr/lib/dayshield-installer/ is present in the live
# session after switch_root so that install.sh and firstboot-run.sh are found.
run_step embed-installer-scripts.sh

# Ensure live-boot / live-config are present in the live rootfs so that:
#   1. The squashfs contains the live-boot scripts needed by the live session.
#   2. mkinitramfs (build-initrd.sh) can include the live-boot initramfs hook.
# This is a no-op if the packages are already installed.
run_step ensure-live-boot.sh

run_step build-squashfs.sh
run_step build-kernel.sh
run_step build-initrd.sh
run_step build-bootloader.sh
ASSEMBLE_ARGS=(--output "${OUTPUT}")
ASSEMBLE_ARGS+=(--installer-ui "${INSTALLER_UI_DIR}")
ASSEMBLE_ARGS+=(--rootfs "${ROOTFS}")
run_step assemble-iso.sh "${ASSEMBLE_ARGS[@]}"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
run_step cleanup.sh

echo ""
echo "==> ISO built successfully: ${OUTPUT}"
echo "    Size: $(du -sh "${OUTPUT}" | cut -f1)"
echo "    Checksum: ${OUTPUT}.sha256"
