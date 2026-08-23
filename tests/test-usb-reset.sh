#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

dev="$fixture/sys/bus/usb/devices/1-1"
mkdir -p "$dev/1-1:1.0/host0/target0:0:0/0:0:0:0/scsi_generic/sg7"
mkdir -p "$dev/1-1:1.0/host0/target0:0:0/0:0:0:0/block/sdz"
printf '1e91\n' > "$dev/idVendor"
printf 'de79\n' > "$dev/idProduct"
printf '480\n' > "$dev/speed"
printf '1\n' > "$dev/rx_lanes"
printf '1\n' > "$dev/tx_lanes"

export SYSFS_ROOT="$fixture/sys"
export DEV_ROOT="$fixture/dev"
export CONFIG_FILE="$fixture/no-config"
export ASM2464PD_LIB_ONLY=1
# shellcheck source=../usb-reset.sh
source "$repo_dir/usb-reset.sh"

[[ "$(find_dev)" == "$dev" ]]
[[ "$(find_sg "$dev")" == "$fixture/dev/sg7" ]]
[[ "$(find_blk "$dev")" == sdz ]]
[[ "$(read_link_state "$dev")" == "480 1 1" ]]

# Mock findmnt/systemd to prove that future direct and bind mounts are
# discovered dynamically and ordered with bind mounts before the base mount.
fake_bin="$fixture/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
cat <<'MOUNTS'
/mnt/external /dev/sdz2 exfat rw,relatime
/home/dan/ComfyUI/models /dev/sdz2[/comfyui/models] exfat rw,relatime
/srv/future-checkpoints /dev/sdz2[/comfyui/models/checkpoints] exfat rw,relatime
MOUNTS
EOF
cat > "$fake_bin/systemd-escape" <<'EOF'
#!/usr/bin/env bash
kind=mount
for arg in "$@"; do
    [[ "$arg" == --suffix=* ]] && kind=${arg#--suffix=}
done
target=${!#}
target=${target#/}
printf '%s.%s\n' "${target//\//-}" "$kind"
EOF
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    is-active) [[ "${!#}" == *.mount ]] ;;
    show) printf '/run/systemd/generator/%s\n' "${!#}" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/findmnt" "$fake_bin/systemd-escape" "$fake_bin/systemctl"

FINDMNT_BIN="$fake_bin/findmnt"
SYSTEMCTL_BIN="$fake_bin/systemctl"
SYSTEMD_ESCAPE_BIN="$fake_bin/systemd-escape"
capture_mount_state /dev/sdz2

[[ ${#MOUNT_TARGETS[@]} == 3 ]]
[[ " ${MOUNT_TARGETS[*]} " == *" /srv/future-checkpoints "* ]]
[[ "${MOUNT_TARGETS[2]}" == /mnt/external ]]
[[ "${MOUNT_SOURCES[2]}" == /dev/sdz2 ]]

# Regression: after the sidecar successfully disappears, container_running
# returns 1. stop_comfyui itself must still return success under `set -e`.
touch "$fixture/comfy-control"
chmod +x "$fixture/comfy-control"
COMFYUI_CONTROL="$fixture/comfy-control"
container_checks=0
container_running() {
    container_checks=$((container_checks + 1))
    (( container_checks == 1 ))
}
run_as_comfyui() { return 0; }
stop_comfyui
[[ $COMFYUI_WAS_RUNNING == 1 ]]

printf 'usb-reset fixture tests: PASS\n'
