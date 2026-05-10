#!/usr/bin/env bash
# Bring up the fcghar VM networking:
#
# - fcghar-br0   192.168.43.1/24   NAT'd to host's default route
# - tap-runner-0 .. tap-runner-(SLOTS-1)  attached to the bridge, ready for
#                                         vm-run.sh to pick from.
#
# SLOTS defaults to 8. Idempotent. Needs sudo.
set -euo pipefail

if [ "${EUID:-$UID}" -ne 0 ]; then
    exec sudo --preserve-env=SUDO_USER,SLOTS "$0" "$@"
fi

SLOTS="${SLOTS:-8}"
BRIDGE="fcghar-br0"
SUBNET="192.168.43.0/24"
HOST_IP="192.168.43.1/24"

TAP_USER="${SUDO_USER:-${USER:-root}}"

DEFAULT_IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
if [ -z "${DEFAULT_IFACE:-}" ]; then
    echo "warning: no default route detected; NAT rules will be skipped" >&2
fi

if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    ip link add "$BRIDGE" type bridge
fi
ip addr replace "$HOST_IP" dev "$BRIDGE"
ip link set "$BRIDGE" up

for i in $(seq 0 $((SLOTS - 1))); do
    TAP="tap-runner-$i"
    if ! ip link show "$TAP" >/dev/null 2>&1; then
        ip tuntap add "$TAP" mode tap user "$TAP_USER"
    fi
    ip link set "$TAP" master "$BRIDGE"
    ip link set "$TAP" up
done

ensure_iptables_rule() {
    local table="$2" chain="$4"
    shift 4
    if ! iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
        iptables -t "$table" -A "$chain" "$@"
    fi
}

if [ -n "${DEFAULT_IFACE:-}" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    ensure_iptables_rule -t nat -A POSTROUTING -s "$SUBNET" -o "$DEFAULT_IFACE" -j MASQUERADE
    ensure_iptables_rule -t filter -A FORWARD -i "$BRIDGE" -o "$DEFAULT_IFACE" -j ACCEPT
    ensure_iptables_rule -t filter -A FORWARD -o "$BRIDGE" -i "$DEFAULT_IFACE" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

echo "ok. $BRIDGE up at $HOST_IP, taps: tap-runner-0 .. tap-runner-$((SLOTS - 1))"
