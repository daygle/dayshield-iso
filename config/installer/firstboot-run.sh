#!/usr/bin/env bash
# firstboot-run.sh — Executed once on the first boot after installation.
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

exec >> "${LOG_FILE}" 2>&1

echo "==> DayShield first-boot initialisation: $(date -u)"

# ---------------------------------------------------------------------------
# 1. SSH host keys
# ---------------------------------------------------------------------------
echo "--> Regenerating SSH host keys …"
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A

# ---------------------------------------------------------------------------
# 2. Unique machine-id
# ---------------------------------------------------------------------------
echo "--> Generating machine-id …"
systemd-machine-id-setup --force 2>/dev/null || \
    cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id

# ---------------------------------------------------------------------------
# 3. ACME / TLS keys (if dayshield-acme is installed)
# ---------------------------------------------------------------------------
if command -v dayshield-acme &>/dev/null; then
    echo "--> Regenerating ACME keys …"
    dayshield-acme regenerate-keys || true
fi

# ---------------------------------------------------------------------------
# 4. Network configuration reset
# ---------------------------------------------------------------------------
echo "--> Resetting network configuration …"

# Remove any stale DHCP leases
find /var/lib/dhcp/ -name '*.leases' -delete 2>/dev/null || true
find /var/lib/dhclient/ -name '*.leases' -delete 2>/dev/null || true

# Clear predictable interface name symlinks so they get recreated
rm -f /etc/systemd/network/10-*.link 2>/dev/null || true

# Reload network units
systemctl daemon-reload 2>/dev/null || true
systemctl restart systemd-networkd 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Start dayshield-core
# ---------------------------------------------------------------------------
echo "--> Starting dayshield-core …"
systemctl enable dayshield-core 2>/dev/null || true
systemctl start  dayshield-core 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Remove firstboot marker
# ---------------------------------------------------------------------------
echo "--> Removing firstboot marker …"
rm -f "${FIRSTBOOT_MARKER}"

echo "==> First-boot initialisation complete: $(date -u)"
