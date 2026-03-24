# Dell Latitude 5285 2-in-1 — Dual Camera Linux Enablement

## Project goal
Upstream kernel patches to enable both cameras on the Dell Latitude 5285 2-in-1.
Tested on Ubuntu 25.10, kernel 6.17.0-19-generic.

---

## Hardware

| Component | ACPI ID | I2C addr | Bus |
|-----------|---------|----------|-----|
| Front camera (OV5670) | INT3479 | 0x36 | I2C4 / INT3446 |
| Back camera (OV8858)  | INT3477 | 0x10 | I2C2 / i2c-3 (i2c_designware.3 / 0000:00:15.2) |
| PMIC (TPS68470)       | INT3472:05 | 0x4D | I2C2 / i2c-3 |

GNVS base: 0xAAE22000 (stable across reboots — but now discovered dynamically via AML scanner).

---

## Current status (2026-03-19)

All cameras working ✅. Patches submitted upstream.

- intel-lpss IGNORE_RESOURCE_CONFLICTS for I2C4: ✅
- GNVS fix (C0TP/L0CL/L1CL → 0x02) via DSDT AML scanner: ✅
  - `dmesg: "Dell 5285 GNVS fix at 0x00000000aae22000: C0TP=0x02 L0CL=0x00 L1CL=0x00 -> 0x02"`
- ipu_bridge finds both INT3477 and INT3479: ✅
- Front camera (OV5670): ✅ working in Zoom and Chrome via PipeWire
- Back camera (OV8858): ✅ registered (mutually exclusive with front — IPU3 HW limit)
- VSIO regulator (S_I2C_CTL passthrough): ✅ vsio=1

**Note:** `cam -l` fails with EBUSY when PipeWire is running — PipeWire holds /dev/media0
exclusively. Use `cam -l` only in a TTY or after `systemctl --user stop pipewire`. This is
expected and does not indicate a problem.

**Non-critical warnings** (cosmetic only):
- "Unable to get rectangle N on pad 0/0: Inappropriate ioctl" — ov8858 lacks crop rectangle support
- "ov8858.yaml not found for IPA module ipu3" — no calibration file; falls back to uncalibrated.yaml

---

## Upstream submission

**Status: SUBMITTED 2026-03-19. Awaiting maintainer feedback.**

Single 5-patch series in `patches-for-submission/combined/`:

| # | Patch | Tree |
|---|-------|------|
| 1 | platform/x86: intel_lpss: add resource conflict quirk for Dell Latitude 5285 | mfd |
| 2 | platform/x86: int3472: tps68470: fix GNVS clock fields for Dell Latitude 5285 | platform/x86 |
| 3 | platform/x86: int3472: tps68470: add board data for Dell Latitude 5285 | platform/x86 |
| 4 | media: ipu-bridge: add sensor configuration for OV8858 (INT3477) | media |
| 5 | media: ov8858: add ACPI device ID INT3477 and vsio power supply | media |

All 5 patches are required for a working system. Each is self-contained and bisect-safe.

**Sent to:**
- To: linux-kernel@vger.kernel.org
- CC: lee@kernel.org, hansg@kernel.org, ilpo.jarvinen@linux.intel.com, djrscally@gmail.com,
  platform-driver-x86@vger.kernel.org, mchehab@kernel.org, sakari.ailus@linux.intel.com,
  jacopo.mondi@ideasonboard.com, nicholas@rothemail.net, linux-media@vger.kernel.org

**git send-email command:**
```bash
git send-email \
  --to=linux-kernel@vger.kernel.org \
  --cc=lee@kernel.org \
  --cc=platform-driver-x86@vger.kernel.org \
  --cc=hansg@kernel.org \
  --cc=ilpo.jarvinen@linux.intel.com \
  --cc=djrscally@gmail.com \
  --cc=linux-media@vger.kernel.org \
  --cc=mchehab@kernel.org \
  --cc=sakari.ailus@linux.intel.com \
  --cc=jacopo.mondi@ideasonboard.com \
  --cc=nicholas@rothemail.net \
  patches-for-submission/combined/000*.patch
```

**Upstream trees** (shallow clones, branch `dell-latitude-5285-camera`):
- `upstream/pdx86/` — Linux 7.0-rc1 base
- `upstream/media_stage/`

**Likely review points to anticipate:**
- Patch 2: AML scanning approach for GNVS address, DMI match specifics
- Patch 3: GPIO/regulator mapping, always_on VSIO justification
- Cross-subsystem dependency (all 5 patches needed together)

---

## Patches explained

### Problem 1 — I2C4 host adapter missing (patch 1)
BIOS exposes ACPI GEXP device and INT3446 (I2C4 controller) claiming the same MMIO region.
Kernel rejects INT3446 → OV5670's I2C bus never comes up.
Fix: DMI quirk applies QUIRK_IGNORE_RESOURCE_CONFLICTS for INT3446 on this machine.

### Problem 2 — ACPI _DEP returns wrong dependency (patch 2)
With I2C4 up, OV5670 still not created by ipu_bridge: `_DEP` on INT3479 returns the root
PCI bus handle instead of the INT3472 (PMIC) handle.
Root cause: BIOS leaves GNVS fields C0TP, L0CL, L1CL at zero.
Fix: TPS68470 probe scans DSDT/SSDTs for GNVS OperationRegion AML signature
(0x5B 0x80 "GNVS" 0x00), maps the region, writes 0x02 to all three fields before
ipu_bridge evaluates _DEP.
GNVS field offsets (from DSDT disassembly): C0TP=0x43A, L0CL=0x4F7, L1CL=0x549, size=0x0725.

### Problem 3 — No TPS68470 board data (patch 3)
int3472 driver has no entry for Dell 5285 → no PMIC regulators or GPIOs configured for
either camera.
Fix: full supply map and GPIO lookup tables for both sensors.

**TPS68470 GPIO mapping:**
- GPIO0–6: regular GPIOs (GPDO reg 0x27)
- GPIO7 = s_enable (SGPO reg 0x22 bit 0) — OV8858 powerdown/enable
- GPIO8 = s_idle  (SGPO reg 0x22 bit 1)
- GPIO9 = s_resetn (SGPO reg 0x22 bit 2) — OV8858 reset

**TPS68470 S_I2C architecture:**
- OV8858 is behind TPS68470's S_I2C passthrough (reg 0x43 S_I2C_CTL, bits[1:0] must be non-zero)
- VSIO regulator enable IS S_I2C_CTL (TPS68470_S_I2C_CTL_EN_MASK = GENMASK(1,0))
- VSIO marked always_on → S_I2C_CTL=0x03 from boot, passthrough active immediately

**Regulator mapping:**
- INT3477 (OV8858): CORE→dvdd, ANA→avdd, VIO→dovdd, VSIO→vsio
- INT3479 (OV5670): VSIO→avdd

### Problem 4 — OV8858 not supported (patches 4 & 5)
- ipu_bridge didn't know INT3477 → skipped at CSI-2 enumeration (patch 4, 360MHz)
- ov8858 driver had no ACPI match for INT3477, didn't request vsio supply (patch 5)

---

## Build system

**Kernel source:** `~/kernel-build/linux-source-6.17.0/`

**Build directories** (outside this repo):
- `~/tps68470_build/` → intel_skl_int3472_tps68470.ko
- `~/lpss_build/` → intel-lpss-acpi.ko, intel-lpss.ko, intel-lpss-pci.ko
- `~/ipu_bridge_build/` → ipu_bridge.ko
- `~/ov8858_build/` → ov8858.ko

**Build command:**
```bash
sudo make -C ~/kernel-build/linux-source-6.17.0 CC=x86_64-linux-gnu-gcc M=~/[build-dir] modules
```

**Install command:**
```bash
sudo zstd -f ~/[build-dir]/module.ko -o /lib/modules/6.17.0-19-generic/updates/dkms/module.ko.zst
```

Note: build artifacts are owned by root — use `sudo` for make.

**After any module install:**
```bash
sudo depmod -a
sudo update-initramfs -u -k $(uname -r)
# then reboot
```

**Module file inventory** (`/lib/modules/6.17.0-19-generic/updates/dkms/`):
- `intel-lpss-acpi.ko.zst` — IGNORE_RESOURCE_CONFLICTS patch
- `intel-lpss.ko.zst`, `intel-lpss-pci.ko.zst`
- `ipu_bridge.ko.zst` — INT3477 sensor entry patch
- `intel_skl_int3472_tps68470.ko.zst` — GNVS AML scanner + board data
- `ov8858.ko.zst` — INT3477 ACPI ID + vsio supply

**Config files:**
- `/etc/modprobe.d/dell-5285-camera.conf`
- `/etc/modules-load.d/dell-5285-lpss.conf`

---

## Critical pitfalls

### Module reload — DO NOT do this
Never `modprobe -r intel_skl_int3472_tps68470` then reload after boot.
`for_each_acpi_consumer_dev()` only works at boot when ACPI _DEP state is fresh.
After `acpi_gpiochip_add()` clears dependencies, reload gives 0 consumers → probe fails.
**Always test by rebooting.**

### Stale module in initramfs
Kernel loads modules from initramfs, NOT from /lib/modules directly.
After any install: must run `depmod -a` + `update-initramfs -u` + reboot.

Watch for uncompressed `.ko` files taking precedence over `.ko.zst`:
```bash
find /lib/modules/$(uname -r)/updates/dkms -name "*.ko" -not -name "*.zst"
# Delete any found after verifying the .ko.zst is correct
```

---

## Loopback streaming (Chrome/Zoom)

Front camera works in Chrome, Zoom, and ffmpeg via v4l2loopback ✅

**Config:** `/etc/modprobe.d/v4l2loopback.conf` — `exclusive_caps=1`

**GStreamer pipeline:**
```
libcamerasrc ! video/x-raw,format=NV12,width=1280,height=720 ! queue ! videoconvert ! video/x-raw,format=YUY2,width=1280,height=720 ! appsink
```

**Key ioctl details (kernel 6.17 — do not regress):**
- `sizeof(struct v4l2_format) = 208` (NOT 204) → ioctl: `0xc0d05605`
- 4-byte reserved field between `type` and `union fmt`: pack as `struct.pack('<II', type, 0) + pix + bytes(200 - len(pix))`
- With `exclusive_caps=1`: VIDIOC_S_FMT requires OUTPUT type (type=2)
- Must write one black frame immediately after S_FMT before consumers can STREAMON

Back camera: not streamed — IPU3 IMGU allows only one pipeline at a time.
GNOME Camera app: works when loopback service is stopped (expected — libcamerasrc holds exclusive access).
