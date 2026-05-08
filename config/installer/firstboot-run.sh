#!/usr/bin/env bash
# firstboot-run.sh - Executed once on the first boot after installation.
#
# Performs:
#   1. Regenerate SSH host keys
#   2. Regenerate ACME / TLS keys
#   3. Reset network configurations
#   4. Write a unique machine-id
#   5. Start dayshield-core
#   6. Remove firstboot marker so this does not run again

set -euo pipefail

FIRSTBOOT_MARKER="/etc/dayshield/.firstboot"
LOG_FILE="/var/log/dayshield-firstboot.log"

# Guard: only run once. The marker is created by the installer (finalize step)
# and removed at the end of this script.
if [[ ! -f "${FIRSTBOOT_MARKER}" ]]; then
    echo "==> First-boot marker not present; first-boot already completed. Exiting."
    exit 0
fi

exec >> "${LOG_FILE}" 2>&1

echo "==> DayShield first-boot initialisation: $(date -u)"
FAILED=0

# ---------------------------------------------------------------------------
# 1. SSH host keys
# ---------------------------------------------------------------------------
echo "--> Regenerating SSH host keys …"
rm -f /etc/ssh/ssh_host_*
if ! ssh-keygen -A; then
    echo "[ERROR] Failed to regenerate SSH host keys."
    FAILED=1
fi

# ---------------------------------------------------------------------------
# 2. Unique machine-id
# ---------------------------------------------------------------------------
echo "--> Generating machine-id …"
systemd-machine-id-setup --force 2>/dev/null || \
    tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id

# ---------------------------------------------------------------------------
# 3. ACME / TLS keys (if dayshield-acme is installed)
# ---------------------------------------------------------------------------
if command -v dayshield-acme &>/dev/null; then
    echo "--> Regenerating ACME keys …"
    if ! dayshield-acme regenerate-keys; then
        echo "[WARN] Failed to regenerate ACME keys."
    fi
fi

# ---------------------------------------------------------------------------
# 4. Network configuration reset
# ---------------------------------------------------------------------------
echo "--> Resetting network configuration …"

# Remove any stale DHCP leases
find /var/lib/dhcp/ -name '*.leases' -delete 2>/dev/null || true
find /var/lib/dhclient/ -name '*.leases' -delete 2>/dev/null || true

# Reload network units
systemctl daemon-reload || echo "WARNING: daemon-reload failed" >&2
systemctl restart systemd-networkd || echo "WARNING: systemd-networkd restart failed" >&2

# ---------------------------------------------------------------------------
# 5. Start dayshield-core
# ---------------------------------------------------------------------------
echo "--> Starting dayshield-core …"
systemctl enable dayshield.service || {
    echo "[ERROR] Failed to enable dayshield.service" >&2
    exit 1
}
systemctl start dayshield.service || {
    echo "[ERROR] Failed to start dayshield.service" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 6. Remove firstboot marker
# ---------------------------------------------------------------------------
if [[ ${FAILED} -eq 0 ]]; then
    echo "--> Removing firstboot marker …"
    rm -f "${FIRSTBOOT_MARKER}"
else
    echo "--> First-boot encountered errors; keeping marker for retry."
    exit 1
fi

echo "==> First-boot initialisation complete: $(date -u)"
