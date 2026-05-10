#!/usr/bin/env bash
# Tear down what net-up.sh built. Idempotent — missing pieces are not errors.
set -uo pipefail

if [ "${EUID:-$UID}" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

BRIDGE="fcghar-br0"
SUBNET="192.168.43.0/24"

DEFAULT_IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')

if [ -n "${DEFAULT_IFACE:-}" ]; then
    iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -t filter -D FORWARD -i "$BRIDGE" -o "$DEFAULT_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -t filter -D FORWARD -o "$BRIDGE" -i "$DEFAULT_IFACE" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi

# Remove every tap-runner-* tap (and the legacy un-suffixed tap-runner if it
# happens to be lying around from an older revision).
for tap in $(ip -o link show 2>/dev/null \
                | awk -F': ' '/tap-runner/ {print $2}' \
                | awk '{print $1}' \
                | sed 's/@.*//'); do
    ip link set "$tap" down 2>/dev/null || true
    ip tuntap del "$tap" mode tap 2>/dev/null || true
done

if ip link show "$BRIDGE" >/dev/null 2>&1; then
    ip link set "$BRIDGE" down 2>/dev/null || true
    ip link delete "$BRIDGE" type bridge 2>/dev/null || true
fi

echo "ok. removed $BRIDGE and all tap-runner-* taps."
