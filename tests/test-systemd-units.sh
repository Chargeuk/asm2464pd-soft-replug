#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

grep -qx 'OnBootSec=45s' "$repo_dir/usb-gen2x2-fix.timer"
grep -qx 'Unit=usb-gen2x2-fix.service' "$repo_dir/usb-gen2x2-fix.timer"
grep -qx 'WantedBy=timers.target' "$repo_dir/usb-gen2x2-fix.timer"
grep -q 'usb-gen2x2-fix.timer' "$repo_dir/install.sh"

if grep -q '^WantedBy=' "$repo_dir/usb-gen2x2-fix.service"; then
    echo 'service must be timer-triggered, not directly enabled' >&2
    exit 1
fi

printf 'systemd unit tests: PASS\n'
