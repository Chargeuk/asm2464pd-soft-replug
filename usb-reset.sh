#!/usr/bin/env bash
# Recover an ASM2464PD enclosure that trained at USB 2.0 during boot.
# SPDX-License-Identifier: GPL-3.0-only

set -Eeuo pipefail
export LC_ALL=C

CONFIG_FILE="${CONFIG_FILE:-/etc/default/asm2464pd-soft-replug}"
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

VID="${VID:-1e91}"
PID="${PID:-de79}"
WANT_SPEED="${WANT_SPEED:-20000}"
WANT_RX_LANES="${WANT_RX_LANES:-2}"
WANT_TX_LANES="${WANT_TX_LANES:-2}"
FS_UUID="${FS_UUID:-6952-8360}"
MIN_MBPS="${MIN_MBPS:-200}"
BENCH_MIB="${BENCH_MIB:-512}"
REQUIRED_PATHS="${REQUIRED_PATHS:-/mnt/external/comfyui/models /mnt/external/comfyui/output-sidecar}"
REQUIRED_MOUNT_TARGETS="${REQUIRED_MOUNT_TARGETS:-/home/dan/ComfyUI/models}"
PIN_AUTOMOUNTS_WITH_BINDS="${PIN_AUTOMOUNTS_WITH_BINDS:-1}"
COMFYUI_USER="${COMFYUI_USER:-dan}"
COMFYUI_CONTROL="${COMFYUI_CONTROL:-/home/dan/code/spark-comfyui-sidecar/sidecar.sh}"
COMFYUI_CONTAINER="${COMFYUI_CONTAINER:-spark-comfyui-sidecar}"
COMFYUI_HEALTH_URL="${COMFYUI_HEALTH_URL:-http://127.0.0.1:8190/system_stats}"
SYSFS_ROOT="${SYSFS_ROOT:-/sys}"
DEV_ROOT="${DEV_ROOT:-/dev}"
LOCK_FILE="${LOCK_FILE:-/run/lock/asm2464pd-soft-replug.lock}"
FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SYSTEMD_ESCAPE_BIN="${SYSTEMD_ESCAPE_BIN:-systemd-escape}"

MODE=recover
COMFYUI_WAS_RUNNING=0
STORAGE_STOPPED=0
STORAGE_PARTITION=""
declare -a MOUNT_TARGETS=()
declare -a MOUNT_SOURCES=()
declare -a MOUNT_FSTYPES=()
declare -a MOUNT_OPTIONS=()
declare -a MOUNT_UNITS=()
declare -a AUTOMOUNT_UNITS=()
declare -a MOUNT_UNIT_WAS_ACTIVE=()
declare -a AUTOMOUNT_WAS_ACTIVE=()
HAS_BIND_MOUNTS=0

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: usb-reset.sh [--check | --dry-run | --recover]

  --check    Report the enclosure, mounts and ComfyUI state; make no changes.
  --dry-run  Validate the recovery target and show what would be changed.
  --recover  Perform the guarded recovery (default; requires root).
EOF
}

find_dev() {
    local d found=""
    for d in "$SYSFS_ROOT"/bus/usb/devices/*-*; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        [[ "$(<"$d/idVendor")" == "$VID" && "$(<"$d/idProduct")" == "$PID" ]] || continue
        [[ -z "$found" ]] || die "more than one ${VID}:${PID} enclosure is attached"
        found="$d"
    done
    [[ -n "$found" ]] || return 1
    printf '%s' "$found"
}

find_sg() {
    local d="$1" root path
    root=$(readlink -f "$d") || return 1
    path=$(find "$root" -path '*/scsi_generic/sg*' -print -quit 2>/dev/null)
    [[ -n "$path" ]] && printf '%s/%s' "$DEV_ROOT" "$(basename "$path")"
}

find_blk() {
    local d="$1" root path
    root=$(readlink -f "$d") || return 1
    # sysfs block entries can be directories or symlinks depending on kernel.
    path=$(find "$root" -path '*/block/*' -print -quit 2>/dev/null)
    [[ -n "$path" ]] && printf '%s' "$(basename "$path")"
}

read_link_state() {
    local dev="$1" speed rx tx
    speed=$(<"$dev/speed")
    rx=$(cat "$dev/rx_lanes" 2>/dev/null || printf '?')
    tx=$(cat "$dev/tx_lanes" 2>/dev/null || printf '?')
    printf '%s %s %s' "$speed" "$rx" "$tx"
}

partition_path() {
    local path="$DEV_ROOT/disk/by-uuid/$FS_UUID"
    [[ -e "$path" ]] || return 1
    readlink -f "$path"
}

verify_partition_belongs_to_enclosure() {
    local dev="$1" partition="$2" enclosure_blk parent
    enclosure_blk=$(find_blk "$dev") || die "no block device exists below $dev"
    parent=$(lsblk -ndo PKNAME "$partition" 2>/dev/null || true)
    [[ "$parent" == "$enclosure_blk" ]] ||
        die "$partition belongs to ${parent:-unknown}, not enclosure block device $enclosure_blk"
}

unit_name_for_path() {
    local kind="$1" target="$2"
    "$SYSTEMD_ESCAPE_BIN" --path --suffix="$kind" "$target"
}

unit_is_active() {
    "$SYSTEMCTL_BIN" is-active --quiet "$1" 2>/dev/null
}

unit_has_fragment() {
    [[ -n "$("$SYSTEMCTL_BIN" show -p FragmentPath --value "$1" 2>/dev/null || true)" ]]
}

# Capture every active mount whose backing source is this exact partition.
# findmnt reports bind mounts as /dev/sdXN[/path/inside/filesystem], so future
# bind mounts are included without adding paths to this script or its config.
# Records are sorted with bind/deeper mounts first for safe teardown.
capture_mount_state() {
    local partition="$1" target source fstype options priority depth record
    local mount_unit automount_unit mount_active automount_active
    local -a records=()

    MOUNT_TARGETS=()
    MOUNT_SOURCES=()
    MOUNT_FSTYPES=()
    MOUNT_OPTIONS=()
    MOUNT_UNITS=()
    AUTOMOUNT_UNITS=()
    MOUNT_UNIT_WAS_ACTIVE=()
    AUTOMOUNT_WAS_ACTIVE=()
    STORAGE_PARTITION="$partition"
    HAS_BIND_MOUNTS=0

    while read -r target source fstype options; do
        [[ -n "$target" && -n "$source" ]] || continue
        if [[ "$source" == "$partition["* ]]; then
            priority=0
            HAS_BIND_MOUNTS=1
        else
            priority=1
        fi
        depth=${target//[^\/]/}
        depth=${#depth}
        printf -v record '%d\t%04d\t%s\t%s\t%s\t%s' "$priority" "$depth" "$target" "$source" "$fstype" "$options"
        records+=("$record")
    done < <("$FINDMNT_BIN" -rn -S "$partition" -o TARGET,SOURCE,FSTYPE,OPTIONS)

    ((${#records[@]} > 0)) || die "filesystem $partition has no active mounts"
    mapfile -t records < <(printf '%s\n' "${records[@]}" | sort -t $'\t' -k1,1n -k2,2nr)

    for record in "${records[@]}"; do
        IFS=$'\t' read -r _ _ target source fstype options <<<"$record"
        mount_unit=$(unit_name_for_path mount "$target")
        automount_unit=$(unit_name_for_path automount "$target")
        mount_active=0
        automount_active=0
        # Every kernel mount is represented by a .mount unit, but only units
        # with a fragment can be started again. Manual mounts use the captured
        # source/type/options fallback below instead.
        unit_is_active "$mount_unit" && unit_has_fragment "$mount_unit" && mount_active=1
        unit_is_active "$automount_unit" && unit_has_fragment "$automount_unit" && automount_active=1
        MOUNT_TARGETS+=("$target")
        MOUNT_SOURCES+=("$source")
        MOUNT_FSTYPES+=("$fstype")
        MOUNT_OPTIONS+=("$options")
        MOUNT_UNITS+=("$mount_unit")
        AUTOMOUNT_UNITS+=("$automount_unit")
        MOUNT_UNIT_WAS_ACTIVE+=("$mount_active")
        AUTOMOUNT_WAS_ACTIVE+=("$automount_active")
    done

    local required found i
    for required in $REQUIRED_MOUNT_TARGETS; do
        found=0
        for i in "${!MOUNT_TARGETS[@]}"; do
            [[ "${MOUNT_TARGETS[$i]}" == "$required" ]] && found=1
        done
        (( found == 1 )) || die "required mount is not active: $required"
    done
}

container_running() {
    command -v docker >/dev/null 2>&1 || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$COMFYUI_CONTAINER" 2>/dev/null || true)" == true ]]
}

run_as_comfyui() {
    if [[ "$(id -un)" == "$COMFYUI_USER" ]]; then
        "$@"
    else
        runuser -u "$COMFYUI_USER" -- "$@"
    fi
}

report_state() {
    local dev="$1" speed rx tx sg blk partition i
    read -r speed rx tx <<<"$(read_link_state "$dev")"
    sg=$(find_sg "$dev" || true)
    blk=$(find_blk "$dev" || true)
    partition=$(partition_path || true)
    log "USB ${VID}:${PID}: $dev, ${speed}M, lanes ${rx}/${tx}, sg=${sg:-none}, block=${blk:-none}"
    log "filesystem UUID $FS_UUID: ${partition:-not present}"
    for i in "${!MOUNT_TARGETS[@]}"; do
        log "mounted: ${MOUNT_TARGETS[$i]} <- ${MOUNT_SOURCES[$i]} (unit=${MOUNT_UNITS[$i]}, automount=${AUTOMOUNT_WAS_ACTIVE[$i]})"
    done
    if container_running; then
        log "ComfyUI container $COMFYUI_CONTAINER: running"
    else
        log "ComfyUI container $COMFYUI_CONTAINER: stopped/absent"
    fi
}

stop_comfyui() {
    container_running || return 0
    [[ -x "$COMFYUI_CONTROL" ]] || die "ComfyUI control script is not executable: $COMFYUI_CONTROL"
    COMFYUI_WAS_RUNNING=1
    log "stopping persistent ComfyUI sidecar before unmount"
    run_as_comfyui "$COMFYUI_CONTROL" service --disable
    container_running && die "ComfyUI container did not stop"
    return 0
}

stop_storage() {
    local partition="$1" i target unit automount
    sync
    # Set this before the first stop so a failure halfway through restores any
    # units that were already stopped (for example, when an SMB handle is busy).
    STORAGE_STOPPED=1
    for i in "${!MOUNT_TARGETS[@]}"; do
        target=${MOUNT_TARGETS[$i]}
        unit=${MOUNT_UNITS[$i]}
        automount=${AUTOMOUNT_UNITS[$i]}
        if [[ ${AUTOMOUNT_WAS_ACTIVE[$i]} == 1 ]]; then
            log "stopping discovered automount $automount"
            if ! "$SYSTEMCTL_BIN" stop "$automount"; then
                fuser -vm "$target" 2>&1 || true
                die "could not stop $automount; close the listed filesystem users and retry"
            fi
        fi
        if [[ ${MOUNT_UNIT_WAS_ACTIVE[$i]} == 1 ]]; then
            log "stopping discovered mount $unit ($target)"
            if ! "$SYSTEMCTL_BIN" stop "$unit"; then
                fuser -vm "$target" 2>&1 || true
                die "could not unmount $target; close the listed filesystem users and retry"
            fi
        elif mountpoint -q "$target"; then
            log "unmounting discovered non-systemd mount $target"
            if ! umount "$target"; then
                fuser -vm "$target" 2>&1 || true
                die "could not unmount $target; close the listed filesystem users and retry"
            fi
        fi
    done
    if "$FINDMNT_BIN" -rn -S "$partition" -o TARGET | grep -q .; then
        "$FINDMNT_BIN" -rn -S "$partition" -o TARGET,SOURCE >&2 || true
        die "$partition still has active mounts; refusing to reset a live filesystem"
    fi
    return 0
}

start_storage() {
    local partition="$1" i target unit automount required source subpath base_target=""
    # Teardown order is bind/deep first; reverse it so the base filesystem is
    # restored before mounts sourced from paths inside it.
    for ((i=${#MOUNT_TARGETS[@]}-1; i>=0; i--)); do
        target=${MOUNT_TARGETS[$i]}
        source=${MOUNT_SOURCES[$i]}
        unit=${MOUNT_UNITS[$i]}
        automount=${AUTOMOUNT_UNITS[$i]}
        if [[ ${AUTOMOUNT_WAS_ACTIVE[$i]} == 1 ]]; then
            log "starting previously active automount $automount"
            "$SYSTEMCTL_BIN" start "$automount"
        fi
        if [[ ${MOUNT_UNIT_WAS_ACTIVE[$i]} == 1 ]]; then
            log "starting previously active mount $unit ($target)"
            "$SYSTEMCTL_BIN" start "$unit"
        else
            mkdir -p "$target"
            if [[ "$source" == "$partition["* ]]; then
                [[ -n "$base_target" ]] || die "cannot restore bind mount $target before a base mount"
                subpath=${source#*\[}
                subpath=${subpath%\]}
                log "restoring discovered bind mount $target from ${base_target}${subpath}"
                mount --bind "${base_target}${subpath}" "$target"
            else
                log "restoring discovered non-systemd mount $target"
                mount -t "${MOUNT_FSTYPES[$i]}" -o "${MOUNT_OPTIONS[$i]}" "$partition" "$target"
            fi
        fi
        mountpoint -q "$target" || die "$target did not remount"
        [[ "$source" == "$partition" ]] && base_target="$target"
    done
    for required in $REQUIRED_PATHS; do
        [[ -d "$required" ]] || die "required path is missing after remount: $required"
    done
    # An idle automount can tear down dependent bind mounts after its timeout.
    # Leave the base filesystem mounted, but stop its trigger for this boot.
    if [[ "$PIN_AUTOMOUNTS_WITH_BINDS" == 1 && "$HAS_BIND_MOUNTS" == 1 ]]; then
        for i in "${!MOUNT_TARGETS[@]}"; do
            if [[ "${MOUNT_SOURCES[$i]}" == "$partition" && ${AUTOMOUNT_WAS_ACTIVE[$i]} == 1 ]]; then
                log "pinning ${MOUNT_TARGETS[$i]} because persistent bind mounts depend on it"
                "$SYSTEMCTL_BIN" stop "${AUTOMOUNT_UNITS[$i]}"
                # Stopping an automount also stops the mount it triggered on
                # this system. Start the base mount explicitly so it remains
                # mounted without an idle trigger.
                "$SYSTEMCTL_BIN" start "${MOUNT_UNITS[$i]}"
                mountpoint -q "${MOUNT_TARGETS[$i]}" || die "pinning unexpectedly unmounted ${MOUNT_TARGETS[$i]}"
            fi
        done
    fi
    STORAGE_STOPPED=0
}

start_comfyui() {
    (( COMFYUI_WAS_RUNNING == 1 )) || return 0
    log "restarting persistent ComfyUI sidecar"
    run_as_comfyui "$COMFYUI_CONTROL" service
    local attempt
    for attempt in $(seq 1 90); do
        if curl -fsS --max-time 3 "$COMFYUI_HEALTH_URL" >/dev/null 2>&1; then
            log "ComfyUI health check passed: $COMFYUI_HEALTH_URL"
            COMFYUI_WAS_RUNNING=0
            return 0
        fi
        sleep 2
    done
    die "ComfyUI did not become healthy within 180 seconds"
}

restore_after_failure() {
    local rc=$?
    (( rc != 0 )) || return 0
    trap - EXIT
    log "recovery failed; attempting to restore the pre-run service state"
    if (( STORAGE_STOPPED == 1 )); then
        start_storage "$STORAGE_PARTITION" || log "ERROR: automatic storage restoration failed"
    fi
    if (( COMFYUI_WAS_RUNNING == 1 )) && (( STORAGE_STOPPED == 0 )); then
        start_comfyui || log "ERROR: automatic ComfyUI restoration failed"
    fi
    exit "$rc"
}

measure_mbps() {
    local partition="$1" output value unit
    output=$(dd if="$partition" of=/dev/null bs=1M count="$BENCH_MIB" iflag=direct 2>&1)
    log "dd: $(tail -n 1 <<<"$output")" >&2
    read -r value unit <<<"$(awk '/copied/{print $(NF-1), $NF}' <<<"$output")"
    case "$unit" in
        GB/s) awk -v n="$value" 'BEGIN { printf "%.0f", n * 1000 }' ;;
        MB/s) awk -v n="$value" 'BEGIN { printf "%.0f", n }' ;;
        kB/s) awk -v n="$value" 'BEGIN { printf "%.0f", n / 1000 }' ;;
        *) return 1 ;;
    esac
}

main() {
    case "${1:-}" in
        ""|--recover) MODE=recover ;;
        --check) MODE=check ;;
        --dry-run) MODE=dry-run ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac

    local dev speed rx tx sg partition newdev mbps attempt
    dev=$(find_dev) || die "enclosure ${VID}:${PID} is not attached"
    partition=$(partition_path) || die "filesystem UUID $FS_UUID is not present"
    verify_partition_belongs_to_enclosure "$dev" "$partition"
    capture_mount_state "$partition"
    report_state "$dev"
    read -r speed rx tx <<<"$(read_link_state "$dev")"

    if [[ "$MODE" == check ]]; then
        [[ "$speed" == "$WANT_SPEED" && "$rx" == "$WANT_RX_LANES" && "$tx" == "$WANT_TX_LANES" ]]
        return
    fi

    sg=$(find_sg "$dev") || die "no SCSI-generic node exists below $dev"
    [[ -e "$sg" ]] || die "resolved SCSI-generic node does not exist: $sg"

    if [[ "$speed" == "$WANT_SPEED" && "$rx" == "$WANT_RX_LANES" && "$tx" == "$WANT_TX_LANES" ]]; then
        log "already at ${WANT_SPEED}M with ${rx}/${tx} lanes; nothing to do"
        return
    fi

    if [[ "$MODE" == dry-run ]]; then
        log "DRY RUN: discovered ${#MOUNT_TARGETS[@]} mount(s); would stop them in the order shown above, reset via $sg, then restore the captured state"
        return
    fi

    [[ $EUID -eq 0 ]] || die "--recover must run as root"
    command -v sg_raw >/dev/null 2>&1 || die "sg_raw is required (package: sg3-utils)"
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another recovery is already running"
    trap restore_after_failure EXIT

    stop_comfyui
    stop_storage "$partition"

    log "sending ASM2464PD CPU reset E8 50 to $sg"
    timeout 10 sg_raw "$sg" e8 50 00 00 00 00 00 00 00 00 00 00 00 00 00 ||
        log "sg_raw returned non-zero as the bridge disconnected (expected)"

    # The disappearing old sysfs shell may still match VID:PID after its block
    # children are gone. Accept only a fully attached device whose block node
    # is the parent of the configured filesystem UUID.
    newdev=""
    partition=""
    local candidate candidate_partition candidate_blk candidate_parent
    for attempt in $(seq 1 60); do
        sleep 1
        candidate=$(find_dev || true)
        [[ -n "$candidate" ]] || continue
        candidate_blk=$(find_blk "$candidate" || true)
        [[ -n "$candidate_blk" ]] || continue
        candidate_partition=$(partition_path || true)
        [[ -n "$candidate_partition" ]] || continue
        candidate_parent=$(lsblk -ndo PKNAME "$candidate_partition" 2>/dev/null || true)
        [[ "$candidate_parent" == "$candidate_blk" ]] || continue
        newdev="$candidate"
        partition="$candidate_partition"
        break
    done
    [[ -n "$newdev" && -n "$partition" ]] ||
        die "enclosure block device and filesystem UUID did not settle within 60 seconds"
    udevadm settle --timeout=20 || die "udev did not settle after enclosure reset"
    sleep 1
    verify_partition_belongs_to_enclosure "$newdev" "$partition"
    read -r speed rx tx <<<"$(read_link_state "$newdev")"
    log "re-enumerated at ${speed}M with lanes ${rx}/${tx}; partition=$partition"
    [[ "$speed" == "$WANT_SPEED" && "$rx" == "$WANT_RX_LANES" && "$tx" == "$WANT_TX_LANES" ]] ||
        die "link is ${speed}M ${rx}/${tx}, expected ${WANT_SPEED}M ${WANT_RX_LANES}/${WANT_TX_LANES}"

    mbps=$(measure_mbps "$partition") || die "could not parse direct-read benchmark"
    log "measured direct-read throughput: ${mbps} MB/s (minimum ${MIN_MBPS} MB/s)"
    awk -v actual="$mbps" -v minimum="$MIN_MBPS" 'BEGIN { exit !(actual >= minimum) }' ||
        die "throughput remained below the healthy threshold"

    start_storage "$partition"
    start_comfyui
    trap - EXIT
    log "OK: ${speed}M ${rx}/${tx} lanes, ${mbps} MB/s, storage mounted, ComfyUI restored"
}

if [[ "${ASM2464PD_LIB_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
