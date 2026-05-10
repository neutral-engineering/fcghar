#!/usr/bin/env bash
# Boot a runner VM. Usage: vm-run.sh [--background]
#
# Picks the lowest free SLOT (0, 1, 2, …) automatically by scanning
# /tmp/fcghar/runner-*.pid; override with SLOT=N. Each slot gets its own
# IP (192.168.43.10+SLOT), MAC, tap (tap-runner-SLOT), drive, pidfile,
# logfile, and rendered firecracker config.
#
# - Foreground: execs firecracker; Ctrl-C stops the VM.
# - Background: detaches firecracker, redirects serial console to
#   runner-SLOT.log, writes pid to runner-SLOT.pid.
set -euo pipefail

cd "$(dirname "$0")"

BACKGROUND=0
if [ "${1:-}" = "--background" ]; then BACKGROUND=1; fi

FCGHAR_VAR="${FCGHAR_VAR:-/tmp/fcghar}"
CONFIG_TEMPLATE="configs/runner.json"
TEMPLATE="$FCGHAR_VAR/rootfs.xfs"
KERNEL="$FCGHAR_VAR/vmlinux"
INITRD="$FCGHAR_VAR/initrd"

VCPU="${VCPU:-4}"
MEM_MIB="${MEM_MIB:-4096}"

mkdir -p "$FCGHAR_VAR"

# Pick the lowest free slot by scanning pidfiles. A pidfile whose pid is
# dead counts as free (stale leftover from a crashed VM).
if [ -z "${SLOT:-}" ]; then
    SLOT=0
    while [ -f "$FCGHAR_VAR/runner-$SLOT.pid" ] \
        && kill -0 "$(cat "$FCGHAR_VAR/runner-$SLOT.pid")" 2>/dev/null; do
        SLOT=$((SLOT + 1))
    done
fi

if [ "$SLOT" -lt 0 ] || [ "$SLOT" -gt 244 ]; then
    echo "error: SLOT out of range (0..244): $SLOT" >&2; exit 2
fi

VM_IP="192.168.43.$((10 + SLOT))"
HOST="fcghar-runner-$SLOT"
TAP="tap-runner-$SLOT"
MAC="$(printf 'AA:FC:00:00:43:%02X' $((0x0A + SLOT)))"
RUN_DRIVE="$FCGHAR_VAR/runner-$SLOT.xfs"
PIDFILE="$FCGHAR_VAR/runner-$SLOT.pid"
LOGFILE="$FCGHAR_VAR/runner-$SLOT.log"
CONFIG="$FCGHAR_VAR/runner-$SLOT.config.json"

[ -f "$CONFIG_TEMPLATE" ] || { echo "error: missing $CONFIG_TEMPLATE" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "error: missing $TEMPLATE — run ./build-rootfs.sh first" >&2; exit 1; }
[ -f "$KERNEL" ]   || { echo "error: missing $KERNEL — run ./build-rootfs.sh first" >&2; exit 1; }
[ -f "$INITRD" ]   || { echo "error: missing $INITRD — run ./build-rootfs.sh first" >&2; exit 1; }
[ -r /dev/kvm ]    || { echo "error: /dev/kvm not readable; add yourself to group 'kvm'" >&2; exit 1; }

if ! ip link show "$TAP" >/dev/null 2>&1; then
    echo "error: $TAP not found — run ./net-up.sh (SLOTS=N if you need more)" >&2
    exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    if [ "$BACKGROUND" -eq 1 ]; then
        echo ">> slot $SLOT VM already running (pid $(cat "$PIDFILE")) — skipping"
        exit 0
    fi
    echo "error: slot $SLOT VM already running (pid $(cat "$PIDFILE"))" >&2
    exit 1
fi

echo ">> slot=$SLOT ip=$VM_IP host=$HOST tap=$TAP mac=$MAC vcpu=$VCPU mem=${MEM_MIB}MiB"

echo ">> staging $RUN_DRIVE from $TEMPLATE"
rm -f "$RUN_DRIVE"
cp --reflink=auto "$TEMPLATE" "$RUN_DRIVE"

echo ">> writing $CONFIG"
sed -e "s|__IP__|$VM_IP|g" \
    -e "s|__HOST__|$HOST|g" \
    -e "s|__TAP__|$TAP|g" \
    -e "s|__MAC__|$MAC|g" \
    -e "s|__DRIVE__|$RUN_DRIVE|g" \
    -e "s/\"vcpu_count\": *[0-9]\\+/\"vcpu_count\": $VCPU/" \
    -e "s/\"mem_size_mib\": *[0-9]\\+/\"mem_size_mib\": $MEM_MIB/" \
    "$CONFIG_TEMPLATE" > "$CONFIG"

if [ "$BACKGROUND" -eq 1 ]; then
    echo ">> starting firecracker in background (log: $LOGFILE)"
    setsid firecracker --no-api --config-file "$CONFIG" </dev/null >"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo "   pid $(cat "$PIDFILE")"
else
    echo ">> starting firecracker (foreground)"
    exec firecracker --no-api --config-file "$CONFIG"
fi
