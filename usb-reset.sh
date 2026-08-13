#!/usr/bin/env bash
# usb-reset.sh - automatically recover an ASM2464PD enclosure from its
# boot-time USB 2.0 (480M) fallback to USB 3.2 Gen 2x2 (20000M). No replug needed.
#
# Part of asm2464pd-soft-replug. Copyright (C) 2026 J&S Consultancy.
# SPDX-License-Identifier: GPL-3.0-only
#
# THE FIX (proven live 2026-08-13, see FINDINGS.md):
#   Vendor SCSI command 0xE8 0x50 reboots the ASM2464PD's MCU. The bridge
#   disconnects, cold-boots its firmware, re-runs its attach ladder against the
#   now-ready host, and trains Gen 2x2 in ~3 seconds. This is a software replug.
#   Command set documented by cyrozap/usb-to-pcie-re; reset opcode confirmed via
#   tinygrad/asm2464pd-firmware (ASM246x uses 0x50-offset subcommands).
#     0xE4 (0x50-mapped XDATA read) = fw version @0x5007f0  -> read-only probe
#     0xE8 0x50 = CPU reset  -> full reboot, self-re-enumerates   <- THE FIX
#     0xE8 0x51 = halt-for-disconnect -> stays down until VBUS cycle. DO NOT USE.
#
# WHY the fallback happens: the bridge races UEFI at power-on. Attach during
# boot -> 480M (16/16 boots); attach with Linux up -> Gen2x2 (9/9). VBUS cannot
# be cut in software on this host (HCCPARAMS1 bit3 PPC=0, all 12 root hubs
# report "No power switching"), so the MCU reboot is the only software path.
#
# SAFETY: the target is located by VID:PID through sysfs, never by guessing an
# sg number. The KVM (NVDA8000:01, also a UAS device) can never match 2d01:3666.
#
# Install: sudo install -m755 usb-reset.sh /usr/local/bin/

set -uo pipefail

VID=2d01 PID=3666            # ITHOO USB4.0 SSD Drive Enclosure (ASM2464PD)
MOUNT="/mnt/usb2t"
WANT_SPEED=20000
MIN_MBPS=200                 # USB 2.0 tops out ~41; Gen2x2 measured 1200
REMOUNT=0

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# --- locate the enclosure's USB device dir by VID:PID -----------------------
find_dev() {
    local d
    for d in /sys/bus/usb/devices/*-*; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        [[ "$(<"$d/idVendor")" == "$VID" && "$(<"$d/idProduct")" == "$PID" ]] || continue
        printf '%s' "$d"; return 0
    done
    return 1
}

# --- resolve its sg node THROUGH the device dir (never guess a number) ------
find_sg() {
    local d="$1" sg
    sg=$(ls -d "$d"/*/host*/target*/*/scsi_generic/sg* 2>/dev/null | head -1)
    [[ -n "$sg" ]] && printf '/dev/%s' "$(basename "$sg")"
}

find_blk() {
    local d="$1" b
    b=$(ls -d "$d"/*/host*/target*/*/block/* 2>/dev/null | head -1)
    [[ -n "$b" ]] && printf '%s' "$(basename "$b")"
}

measure() {
    local blk="$1"
    sudo dd if="/dev/$blk" of=/dev/null bs=1M count=2048 iflag=direct 2>&1 \
        | awk '/copied/{print $(NF-1), $NF}'
}

# --- main -------------------------------------------------------------------
dev=$(find_dev) || die "enclosure ${VID}:${PID} not present on any bus"
speed=$(<"$dev/speed")
log "enclosure at $dev, link=${speed}M rx=$(cat "$dev/rx_lanes" 2>/dev/null)/tx=$(cat "$dev/tx_lanes" 2>/dev/null)"

if [[ "$speed" == "$WANT_SPEED" ]]; then
    log "already at ${WANT_SPEED}M - nothing to do"
    exit 0
fi

sg=$(find_sg "$dev") || die "no sg node under $dev"
log "degraded link. resetting bridge MCU via $sg (0xE8 0x50)"

if mountpoint -q "$MOUNT"; then
    sync
    sudo umount "$MOUNT" || die "cannot unmount $MOUNT (fuser -vm $MOUNT to see holder)"
    log "unmounted $MOUNT"
    REMOUNT=1
fi

# the software replug: CPU-reset the ASM2464PD; it re-enumerates in ~3 s
timeout 10 sudo sg_raw "$sg" e8 50 00 00 00 00 00 00 00 00 00 00 00 00 00 \
    || log "sg_raw returned nonzero (expected if device dropped mid-command)"

# wait for it to come back (up to 30 s)
newdev=""
for _ in $(seq 1 15); do
    sleep 2
    newdev=$(find_dev) && break
done
[[ -n "$newdev" ]] || die "device did not re-enumerate after reset - physical replug required"

sleep 2   # let the SCSI layer finish attaching
speed=$(<"$newdev/speed")
rx=$(cat "$newdev/rx_lanes" 2>/dev/null || echo '?')
tx=$(cat "$newdev/tx_lanes" 2>/dev/null || echo '?')
blk=$(find_blk "$newdev")
log "re-enumerated: link=${speed}M lanes=${rx}/${tx} blk=/dev/${blk:-unknown}"

if [[ "$speed" != "$WANT_SPEED" ]]; then
    [[ "$REMOUNT" == 1 && -n "$blk" ]] && sudo mount "$MOUNT" && log "remounted $MOUNT"
    die "still ${speed}M after MCU reset - physical replug required"
fi

[[ -n "$blk" ]] || die "no block device appeared"
read -r mbps unit <<<"$(measure "$blk")"
log "throughput: ${mbps} ${unit} (Gen2x2 baseline: 1.2 GB/s; USB2 was 41 MB/s)"

if [[ "$REMOUNT" == 1 ]] || ! mountpoint -q "$MOUNT"; then
    sudo mount "$MOUNT" && log "remounted $MOUNT"
fi

# an exit code is not proof - gate on the measurement
case "$unit" in
    GB/s) ok=1 ;;
    MB/s) ok=$(awk -v m="$mbps" -v min="$MIN_MBPS" 'BEGIN{print (m+0 > min) ? 1 : 0}') ;;
    *)    ok=0 ;;
esac
[[ "$ok" == 1 ]] || die "link says ${speed}M but throughput is ${mbps} ${unit}"

log "OK: ${WANT_SPEED}M ${rx}/${tx} lanes, ${mbps} ${unit}, $MOUNT mounted"
