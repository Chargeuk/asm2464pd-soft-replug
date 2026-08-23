#!/usr/bin/env bash
# Install the DGX Spark recovery service and link monitor.
# SPDX-License-Identifier: GPL-3.0-only

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run this installer with sudo." >&2; exit 1; }
base_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v sg_raw >/dev/null 2>&1 || {
    echo "sg_raw is missing; install the sg3-utils package first." >&2
    exit 1
}

install -m 0755 "$base_dir/usb-reset.sh" /usr/local/bin/usb-reset.sh
install -m 0755 "$base_dir/usb-link-check.sh" /usr/local/bin/usb-link-check.sh
install -m 0644 "$base_dir/usb-gen2x2-fix.service" /etc/systemd/system/usb-gen2x2-fix.service
install -m 0644 "$base_dir/usb-link-check.service" /etc/systemd/system/usb-link-check.service
install -m 0644 "$base_dir/usb-link-check.timer" /etc/systemd/system/usb-link-check.timer

if [[ ! -e /etc/default/asm2464pd-soft-replug ]]; then
    install -m 0644 "$base_dir/asm2464pd-soft-replug.conf.example" /etc/default/asm2464pd-soft-replug
    echo "Installed the DGX Spark profile at /etc/default/asm2464pd-soft-replug"
else
    echo "Preserved existing /etc/default/asm2464pd-soft-replug"
fi

systemctl daemon-reload
systemctl enable usb-gen2x2-fix.service usb-link-check.timer
echo "Installed and enabled. Run 'usb-reset.sh --dry-run' before the first recovery."
