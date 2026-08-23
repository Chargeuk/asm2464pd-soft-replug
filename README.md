# asm2464pd-soft-replug

**ASM2464PD USB4 enclosure stuck at USB 2.0 after boot — root cause and software fix.**

A USB4/USB 3.2 Gen 2x2 NVMe enclosure built on the **ASMedia ASM2464PD** bridge
enumerates at **USB 2.0 High Speed (480 Mbps, ~41 MB/s)** on every boot when it is
attached during power-on. Physically replugging the cable restores **20 Gbps
(Gen 2x2, ~1–2 GB/s)** — until the next reboot.

This repo documents the root cause and ships a **software fix**: a vendor SCSI
command that makes the bridge reboot itself and retrain the link, plus a systemd
unit that applies it automatically at boot. No cable touching, no extra hardware.

```
[  1.5s]  usb 5-1: new high-speed USB device number 2 using xhci-hcd    ← boots degraded
[ 14.4s]  usb 5-1: USB disconnect, device number 2                      ← fix fires
[ 17.4s]  usb 6-1: new SuperSpeed Plus Gen 2x2 USB device number 2      ← 20 Gbps, hands-free
```

## TL;DR

```bash
# Software replug: CPU-reset the ASM2464PD (it re-enumerates at full speed in ~3 s)
sg_raw /dev/sgX e8 50 00 00 00 00 00 00 00 00 00 00 00 00 00
```

> **⚠️ Do NOT send `e8 51`.** That variant halts the bridge until you physically
> unplug it. `0x50` = CPU reset (self-recovering), `0x51` = halt-for-disconnect.
>
> **⚠️ Unmount the filesystem first**, and make sure `/dev/sgX` really is the
> enclosure (see [Safety](#safety)). These are undocumented vendor commands —
> use at your own risk.

## Symptom

- Boot with the enclosure attached → `lsusb -t` shows the device at `480M` under
  the USB 2.0 root hub; the SuperSpeed companion bus logs **nothing** — no
  connect attempt, no link-training error.
- Replug while the OS is running → `new SuperSpeed Plus Gen 2x2 USB device`.
- Observed on an NVIDIA DGX Spark (GB10, aarch64, kernel 6.17), but the
  mechanism is platform-generic; any host whose early-boot xHCI comes up slower
  than the bridge's SuperSpeed polling window can trigger it.

## Root cause

**It's a boot-time race, not a cable, port, or power problem.**

Attach history recovered from persistent kernel logs over six weeks:

| Attach context | Link trained | Occurrences |
|---|---|---|
| Within ~1–3 s of a boot | USB 2.0, 480M | **16 / 16** |
| Into an already-running host (replug) | Gen 2x2, 20000M | **9 / 9** |

The decisive data point: a **65-hour host power-off** produced exactly the same
480M result as a 24-second warm reboot — so cutting power without changing the
*timing* fixes nothing.

At power-on the ASM2464PD runs its link ladder (USB4 → SuperSpeed → USB 2.0)
against a host xHCI that UEFI has not finished bringing up. It burns its bounded
SuperSpeed LFPS polling retries, drops to `SS.Disabled`, enables its USB 2.0
terminations, and stays there **for the life of that attach**. A device in
`SS.Disabled` presents no SuperSpeed receiver terminations, and a host can only
*detect* terminations — nothing the host does can command them back.

### Why the usual resets can't fix it

All of these were tested and all fail, because they reset the *host* side only:

| Attempted | Result |
|---|---|
| `usbX-portY/disable` cycle (HS + SS ports) | device re-enumerates, still 480M |
| Full xHCI controller unbind/rebind (HCRST, LTSSM restart from Rx.Detect) | still 480M |
| USB-2 suspend/resume, runtime PM, `authorized`, `usbreset` ioctl | no effect on SS terminations |

Cutting VBUS in software was impossible on this host: `HCCPARAMS1` bit 3
(PPC) = 0 — port power control not implemented, `PORTSC.PP` is read-only — and
every root hub reports `wHubCharacteristic 0x000a` ("No power switching"), so
`uhubctl` is a no-op. No Type-C/UCSI/PD driver, no VBUS regulator, no BMC.

The only thing that ever worked was making the **device** restart its ladder
while the host is ready — which a physical replug does, and which the vendor
reset below does in software.

## The fix

The ASM2464PD accepts vendor SCSI commands **even over the degraded USB 2.0
link**. The ASM246x family uses `0x50`-offset subcommands (vs the older
ASM236x):

| CDB | Function |
|---|---|
| `e4 06 50 07 f0 00` | Read 6-byte firmware version (XDATA `0x07F0`, mapped via `0x500000`) — harmless probe |
| `e8 50` + 13×`00` | **CPU reset** — MCU cold-boots, re-runs the attach ladder, trains full speed in ~3 s |
| `e8 51` + 13×`00` | Halt-for-disconnect — **stays down until a physical VBUS cycle. Avoid.** |

Command-set documentation: [cyrozap/usb-to-pcie-re](https://github.com/cyrozap/usb-to-pcie-re)
(ASM2x6x notes). Reset opcode confirmed from
[tinygrad/asm2464pd-firmware](https://github.com/tinygrad/asm2464pd-firmware) `flash.py`.

## Chargeuk fork: OWC Express 1M2 on DGX Spark

This fork includes a ready-to-review profile for this Spark installation:

- enclosure: OWC Express 1M2 (`1e91:de79`), ASM2464PD
- external filesystem UUID: `6952-8360`
- mounts: discovered dynamically from filesystem UUID `6952-8360` (currently
  `/mnt/external` and `/home/dan/ComfyUI/models`)
- ComfyUI: persistent `spark-comfyui-sidecar` controlled by
  `/home/dan/code/spark-comfyui-sidecar/sidecar.sh`

The recovery is deliberately fail-closed. It verifies that the configured UUID
belongs to the configured USB enclosure, stops ComfyUI, discovers and cleanly
stops every active direct or bind mount backed by that filesystem, sends only
the self-recovering `E8 50` command, rediscovers the disk by
UUID, checks the 20 Gbps two-lane link, performs a direct-read benchmark,
restores the captured mount state, and waits for the ComfyUI API to become
healthy. If a step fails, it attempts to restore the mounts and ComfyUI state.

New mounts do not need to be added to the script or configuration. A future
fstab/systemd mount or bind mount sourced from this filesystem is detected on
each run. Active manual mounts are also captured and reconstructed. Mount paths
containing whitespace are intentionally unsupported so discovery cannot parse
them ambiguously.

Application-critical mounts may be listed in `REQUIRED_MOUNT_TARGETS`; these
are guards, not the discovery list. The Spark profile requires the ComfyUI
models bind mount to be active before reset. When an idle automount is the base
for persistent bind mounts, the script pins the restored base mount for the
rest of the boot by stopping the automount trigger and explicitly restarting
the base mount, so systemd's idle timer cannot silently remove those binds.

The script never force-unmounts. If a desktop application, shell, Samba client,
or other process has an open file on the disk, recovery aborts, prints the
holders reported by `fuser`, and restores ComfyUI and any partially stopped
mounts. Close the listed application or file and rerun the recovery.

Safe inspection commands make no changes:

```bash
./usb-reset.sh --check
./usb-reset.sh --dry-run
```

`--check` exits non-zero when the link is degraded, which makes it useful in
monitoring. The guarded live recovery requires root:

```bash
sudo ./usb-reset.sh --recover
```

### Install on the Spark

Review `asm2464pd-soft-replug.conf.example`, then run:

```bash
sudo ./install.sh
sudo /usr/local/bin/usb-reset.sh --dry-run
systemctl list-timers usb-gen2x2-fix.timer
```

The installer preserves an existing `/etc/default/asm2464pd-soft-replug`
configuration. Mount paths are not configured there; the UUID is the mount
discovery anchor. The installer enables a timer that runs the one-shot recovery
45 seconds after each boot, plus the hourly link monitor. The recovery service
first checks the live link; an already healthy drive is not reset, but its base
mount is still pinned when persistent bind mounts depend on it. An absent drive
is skipped without failing the boot unit.

### Tests

```bash
bash -n usb-reset.sh usb-link-check.sh install.sh tests/*.sh
bash tests/test-usb-reset.sh
bash tests/test-systemd-units.sh
```

### Live validation

Validated on the configured DGX Spark on 2026-08-23:

- initial link: USB 2.0, `480M`, one receive/transmit lane
- after `E8 50`: USB 3.2 Gen 2x2, `20000M`, two receive/transmit lanes
- direct 1 GiB read through the ComfyUI models bind: **1.8 GB/s**
- `/mnt/external`, the dynamically discovered models bind, and the ComfyUI
  health endpoint remained active beyond the former 60-second automount timeout

## Generic upstream install

```bash
sudo install -m755 usb-reset.sh /usr/local/bin/
sudo install -m644 usb-gen2x2-fix.service /etc/systemd/system/
sudo install -m644 usb-gen2x2-fix.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable usb-gen2x2-fix.timer
```

For a different enclosure or host, copy and edit
`asm2464pd-soft-replug.conf.example`. At boot the unit checks the link and, only if degraded:
unmounts cleanly → sends the CPU reset → waits for re-enumeration → **verifies
by measured throughput, not exit code** → remounts. Healthy or absent device →
exits 0 untouched. If the reset ever fails, the unit exits non-zero and leaves
the disk unmounted rather than silently running 25–50× slow.

Optional: `usb-link-check.{sh,service,timer}` — an hourly/boot-time monitor
that writes a loud MOTD warning if the disk is ever found on a degraded link.

## Safety

- The script locates the enclosure **by VID:PID through sysfs** and resolves its
  `sg` node through the device path — it never guesses an `sg` number, so it
  cannot address another UAS device (a KVM's virtual-media drive, for example).
- It refuses to act if the filesystem cannot be unmounted cleanly.
- The reset does not touch flash. The dangerous opcodes in this family are the
  flash/config writes (`0xE3`, `0xE1`, `0xE5`) — this project sends none of them.
- Newer bridge firmware exists (this unit shipped `241129_85_00_00`; ASMedia has
  released up to
  [`250717_85_00_00`](https://www.station-drivers.com/index.php/en/component/remository/Drivers/Asmedia/ASM-2464-NVMe-USB-4.x-Controller-(40Gbps)/Asmedia-ASM2464-NVME-USB-4.x-Controller-Firmware-Version-250717_85_00_00/lang,en-gb/)
  on station-drivers), and since the race lives in the bridge's power-on link
  ladder a firmware change *could* address it — but ASMedia publishes no
  changelogs, **nothing confirms any release fixes this**, and flashing carries
  brick risk. If you do flash: match your unit's suffix line (`_85_00_00` for
  generic enclosures — avoid vendor-customized variants like `_85_4F_05`), and
  note the updater is Windows-only. The boot-time reset makes it unnecessary
  either way.

## Files

| File | Purpose |
|---|---|
| `usb-reset.sh` | Detect degraded link → vendor CPU reset → verify → remount |
| `asm2464pd-soft-replug.conf.example` | OWC Express 1M2 / DGX Spark profile |
| `install.sh` | Install scripts, profile, service and monitor |
| `usb-gen2x2-fix.service` | One-shot guarded recovery operation |
| `usb-gen2x2-fix.timer` | Starts recovery 45 seconds after boot |
| `usb-link-check.sh` + `.service`/`.timer` | Optional degraded-link monitor (MOTD + journal) |
| `tests/test-usb-reset.sh` | Fixture tests for safe device-node resolution |
| `tests/test-systemd-units.sh` | Checks delayed timer/service installation |

## Credits

- [cyrozap](https://github.com/cyrozap/usb-to-pcie-re) — ASM2x6x vendor command
  reverse engineering, without which none of this exists
- [tinygrad](https://github.com/tinygrad/asm2464pd-firmware) — open ASM2464PD
  firmware work that surfaced the working reset CDB

## License

Copyright © 2026 J&S Consultancy.
Licensed under the [GNU General Public License v3.0](LICENSE).
