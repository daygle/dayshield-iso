#!/usr/bin/env bash
# build-iso.sh — Main entrypoint for the DayShield ISO builder.
#
# Usage:
#   build-iso.sh [--rootfs rootfs.tar.zst] [--output dayshield.iso] [--arch amd64]
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

if [[ ! -f "${ROOTFS}" ]]; then
    echo "ERROR: rootfs archive not found: ${ROOTFS}" >&2
    exit 1
fi

# Resolve to absolute path
ROOTFS="$(realpath "${ROOTFS}")"
OUTPUT="$(realpath "${OUTPUT}")"

# ---------------------------------------------------------------------------
# Build directory (deterministic structure inside working directory)
# ---------------------------------------------------------------------------
BUILD_DIR="${REPO_ROOT}/build"
export BUILD_DIR ARCH CONFIG_DIR REPO_ROOT

echo "==> DayShield ISO Builder"
echo "    rootfs  : ${ROOTFS}"
echo "    output  : ${OUTPUT}"
echo "    arch    : ${ARCH}"
echo "    build   : ${BUILD_DIR}"
[[ -n "${INSTALLER_UI_DIR}" ]] && echo "    installer-ui: ${INSTALLER_UI_DIR}"

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
if [[ -n "${INSTALLER_UI_DIR}" ]]; then
    run_step inject-installer-ui.sh --installer-ui "${INSTALLER_UI_DIR}"
fi

run_step build-squashfs.sh
run_step build-kernel.sh
run_step build-initrd.sh
run_step build-bootloader.sh
ASSEMBLE_ARGS=(--output "${OUTPUT}")
[[ -n "${INSTALLER_UI_DIR}" ]] && ASSEMBLE_ARGS+=(--installer-ui "${INSTALLER_UI_DIR}")
ASSEMBLE_ARGS+=(--rootfs "${ROOTFS}")
run_step assemble-iso.sh "${ASSEMBLE_ARGS[@]}"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
run_step cleanup.sh

echo ""
echo "==> ISO built successfully: ${OUTPUT}"
echo "    Size: $(du -sh "${OUTPUT}" | cut -f1)"
