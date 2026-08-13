#!/usr/bin/env bash
# usb-link-check.sh - detect an ASM2464PD enclosure running at a degraded
# link and make that LOUD. Run at boot and hourly.
#
# Part of asm2464pd-soft-replug. Copyright (C) 2026 J&S Consultancy.
# SPDX-License-Identifier: GPL-3.0-only
#
# Why this exists: on 2026-08-13 the disk was found to have been running at USB 2.0
# (41 MB/s instead of ~2 GB/s) since 2026-08-08, across three reboots, silently.
# The link only trains Gen 2x2 when the device attaches AFTER Linux is up, so every
# boot with the drive attached comes up degraded. See FINDINGS.md.
#
# Exit: 0 = healthy (or absent), 1 = degraded.

set -uo pipefail

VID=2d01 PID=3666
WANT_SPEED=20000
MOTD=/etc/motd.d/99-usb-link
STAMP=/var/lib/misc/usb-link-check.state

find_dev() {
    local d
    for d in /sys/bus/usb/devices/*-*; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        [[ "$(<"$d/idVendor")" == "$VID" && "$(<"$d/idProduct")" == "$PID" ]] || continue
        printf '%s' "$d"; return 0
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

if [[ "$speed" == "$WANT_SPEED" && "$rx" == 2 && "$tx" == 2 ]]; then
    logger -t usb-link-check "OK: ${speed}M ${rx}/${tx} lanes"
    rm -f "$MOTD" 2>/dev/null
    printf 'ok %s\n' "$speed" > "$STAMP" 2>/dev/null
    exit 0
fi

# --- degraded ---------------------------------------------------------------
logger -p user.warning -t usb-link-check \
    "DEGRADED: /mnt/usb2t link is ${speed}M (${rx}/${tx} lanes), expected ${WANT_SPEED}M 2/2 - replug required"

mkdir -p "$(dirname "$MOTD")" 2>/dev/null
cat > "$MOTD" <<EOF

  ##  USB DISK DEGRADED  ##
  /mnt/usb2t is linked at ${speed}M (${rx}/${tx} lanes), not ${WANT_SPEED}M 2/2.
  That is ~41 MB/s instead of ~2 GB/s.

  Cause: the enclosure was attached during boot. It only trains Gen 2x2 when it
  attaches AFTER Linux is up. Physically replug it, then run:  usb-reset.sh
  Details: FINDINGS.md

EOF
printf 'degraded %s\n' "$speed" > "$STAMP" 2>/dev/null
exit 1
