#!/usr/bin/env bash
# Monitor the configured ASM2464PD enclosure's negotiated USB link.
# SPDX-License-Identifier: GPL-3.0-only

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/default/asm2464pd-soft-replug}"
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
VID="${VID:-1e91}"
PID="${PID:-de79}"
WANT_SPEED="${WANT_SPEED:-20000}"
WANT_RX_LANES="${WANT_RX_LANES:-2}"
WANT_TX_LANES="${WANT_TX_LANES:-2}"
MOTD="${MOTD:-/etc/motd.d/99-usb-link}"
STAMP="${STAMP:-/var/lib/misc/usb-link-check.state}"
SYSFS_ROOT="${SYSFS_ROOT:-/sys}"

find_dev() {
    local d
    for d in "$SYSFS_ROOT"/bus/usb/devices/*-*; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        [[ "$(<"$d/idVendor")" == "$VID" && "$(<"$d/idProduct")" == "$PID" ]] || continue
        printf '%s' "$d"
        return 0
    done
    return 1
}

dev=$(find_dev) || {
    logger -t usb-link-check "enclosure ${VID}:${PID} not attached"
    rm -f "$MOTD" 2>/dev/null
    exit 0
}

speed=$(<"$dev/speed")
rx=$(cat "$dev/rx_lanes" 2>/dev/null || echo '?')
tx=$(cat "$dev/tx_lanes" 2>/dev/null || echo '?')

if [[ "$speed" == "$WANT_SPEED" && "$rx" == "$WANT_RX_LANES" && "$tx" == "$WANT_TX_LANES" ]]; then
    logger -t usb-link-check "OK: ${speed}M ${rx}/${tx} lanes"
    rm -f "$MOTD" 2>/dev/null
    printf 'ok %s %s %s\n' "$speed" "$rx" "$tx" > "$STAMP" 2>/dev/null
    exit 0
fi

message="OWC Express 1M2 is degraded: ${speed}M (${rx}/${tx} lanes), expected ${WANT_SPEED}M ${WANT_RX_LANES}/${WANT_TX_LANES}"
logger -p user.warning -t usb-link-check "$message"
mkdir -p "$(dirname "$MOTD")" 2>/dev/null
cat > "$MOTD" <<EOF

  ## USB DISK DEGRADED ##
  $message
  Run: sudo usb-reset.sh --recover

EOF
printf 'degraded %s %s %s\n' "$speed" "$rx" "$tx" > "$STAMP" 2>/dev/null
exit 1
