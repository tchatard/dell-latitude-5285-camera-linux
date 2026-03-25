# Dell Latitude 5285 2-in-1 — Camera fix for Linux (kernel 6.17+)

This documents how to get both cameras working on the **Dell Latitude 5285 2-in-1**
under Ubuntu 25.10 with kernel 6.17, including Chrome (Google Meet) and Zoom.

**Hardware:**
- Front: OV5670 (ACPI: INT3479, I2C4 / i2c_designware.4)
- Back: OV8858 (ACPI: INT3477, I2C2 / i2c_designware.3)
- PMIC / clock / GPIO: TPS68470 (ACPI: INT3472, addr 0x4D, same I2C2 bus)
- ISP: Intel IPU3 (ipu3_cio2 + ipu3-imgu)

The OV8858 is daisy-chained behind the TPS68470's S_I2C port, so the PMIC
must be fully initialised (clocks, regulators, GPIOs, S_I2C_CTL) before the
sensor can be reached.

The IPU3 IMGU can only run **one** camera pipeline at a time — front and back
are mutually exclusive.

---

## Repository layout

```
patches/
  lpss/             intel-lpss-acpi.c + Makefile
  tps68470/         tps68470.c, tps68470_board_data.c, tps68470.h, common.c + Makefile
  ipu_bridge/       ipu-bridge.c + Makefile
  ov8858/           ov8858.c + Makefile
loopback/
  dell5285-camera-loopback          producer script (libcamera → v4l2loopback)
  dell5285-camera-loopback.service  systemd user unit
config/
  modprobe.d/
    v4l2loopback.conf               exclusive_caps=1, video_nr=50,51
    dell-5285-camera.conf           softdep load ordering
  modules-load.d/
    dell-5285-lpss.conf             autoload intel-lpss-acpi at boot
install.sh                          guided install script
```

---

## What needed patching and why

Five kernel modules required out-of-tree patches. Patches are submitted upstream
but may not have landed yet in your kernel.

### 1. `intel-lpss-acpi` — I2C4 resource conflict

The OV5670 lives on I2C4, described by ACPI node INT3446. On this machine
INT3446 conflicts with a legacy ACPI resource and the driver refuses to bind
without `IGNORE_RESOURCE_CONFLICTS`.

**Fix:** DMI quirk matching Dell Latitude 5285 + INT3446 → set
`LPSS_SHARED_CLK | IGNORE_RESOURCE_CONFLICTS`.

### 2. `intel_skl_int3472_tps68470` — GNVS fix

The TPS68470 uses ACPI GNVS fields `L0CL` / `L1CL` to choose a clock
frequency. On this machine GNVS is not initialised by the BIOS before the
driver probes, leaving the fields at 0x00. This disables the clock outputs,
so neither sensor can be reached over I2C.

**Fix:** At probe time, read the GNVS base from the `_DSM` method output,
then write `L0CL = L1CL = 0x02` (19.2 MHz) before enabling any consumer.

> **Critical — module cannot be reloaded after boot.**
> The probe uses `for_each_acpi_consumer_dev()` to build the clock consumer
> list. This works only at boot when ACPI `_DEP` state is intact.
> After the initial load, `acpi_gpiochip_add()` clears the dependencies, so a
> `modprobe -r / modprobe` cycle gives 0 consumers → probe fails → no
> clocks/regulators. **Always test by rebooting, not reloading.**

### 3. `intel_skl_int3472_tps68470` — board data for Dell 5285

The driver needs a board-data entry for this machine telling it which TPS68470
GPIOs are reset/powerdown for each sensor, and which regulators map to which
supply names.

**Fix:** Added `tps68470_board_data` entry for Dell 5285:
- INT3479 (OV5670): GPIO3 = reset (ACTIVE_LOW), GPIO4 = powerdown (ACTIVE_LOW)
- INT3477 (OV8858): GPIO9 = s_resetn (ACTIVE_LOW), GPIO7 = s_enable (ACTIVE_LOW)
- Regulators: CORE→dvdd/INT3477, ANA→avdd/INT3477, VIO→dovdd/INT3477,
  VSIO→avdd/INT3479 and vsio/INT3477
- VSIO marked `always_on` so S_I2C_CTL (register 0x43) is set from the
  moment TPS68470 probes — required for I2C passthrough to OV8858.

> **TPS68470 GPIO note:** GPIO7 and GPIO9 are not regular GPIOs (GPDO reg 0x27);
> they are the SGPO outputs (reg 0x22 bits 0 and 2) that the driver exposes as
> `s_enable` and `s_resetn`. The board data uses the virtual GPIO numbers the
> driver exposes, not raw register offsets.

### 4. `ipu_bridge` — OV8858 / INT3477 sensor entry

The ipu_bridge module has a table of known sensors and their link frequencies.
OV8858 (INT3477) was absent.

**Fix:** Added INT3477 entry with link frequency 360 MHz.

### 5. `ov8858` — INT3477 ACPI ID and `vsio` supply

The ov8858 driver's ACPI match table lacked INT3477, and its supply name array
did not include `vsio` (needed because TPS68470 VSIO maps to vsio/INT3477 in
the board data above). The original array also had a duplicate `"dvdd"`.

**Fix:** Added `{"INT3477", 0}` to `ov8858_of_match`, replaced the duplicate
`"dvdd"` with `"vsio"` in `ov8858_supply_names[]`.

---

## Building and installing the patched modules

Prerequisites:

```bash
sudo apt install linux-source-$(uname -r) build-essential zstd \
                 gcc-x86-64-linux-gnu
```

Unpack the kernel source (adjust path as needed):

```bash
KVER=$(uname -r)
mkdir -p ~/kernel-build
cd ~/kernel-build
tar xf /usr/src/linux-source-${KVER}.tar.bz2
```

Build and install each module — repeat for `patches/lpss`, `patches/tps68470`,
`patches/ipu_bridge`, `patches/ov8858`:

```bash
KVER=$(uname -r)
KSRC=~/kernel-build/linux-source-${KVER}
INST=/lib/modules/${KVER}/updates/dkms
BUILD_DIR=patches/lpss          # change for each module

sudo make -C "$KSRC" CC=x86_64-linux-gnu-gcc M=$(pwd)/${BUILD_DIR} modules

# Install all .ko files produced (example: intel-lpss-acpi.ko)
for ko in ${BUILD_DIR}/*.ko; do
    sudo zstd -f "$ko" -o ${INST}/$(basename ${ko}).zst
done
```

After installing all modules:

```bash
sudo depmod -a
sudo update-initramfs -u -k $(uname -r)
# Reboot — do not attempt modprobe -r/modprobe without rebooting.
```

> **Stale module pitfall:** The kernel loads modules from the initramfs at boot,
> not directly from `/lib/modules`. Forgetting `update-initramfs` means the old
> module is used. Also watch for uncompressed `.ko` files in `updates/dkms/` —
> they take precedence over `.ko.zst`:
>
> ```bash
> find /lib/modules/$(uname -r)/updates/dkms -name "*.ko" ! -name "*.zst"
> # Delete any hits after verifying the corresponding .ko.zst is correct.
> ```

---

## Configuration files

Install with `install.sh` (see below) or manually:

```bash
sudo cp config/modprobe.d/v4l2loopback.conf     /etc/modprobe.d/
sudo cp config/modprobe.d/dell-5285-camera.conf  /etc/modprobe.d/
sudo cp config/modules-load.d/dell-5285-lpss.conf /etc/modules-load.d/
```

**`config/modprobe.d/dell-5285-camera.conf`** — load ordering:
```
softdep ipu3_cio2 pre: intel_skl_int3472_tps68470 ov5670 ov8858
softdep ov5670   pre: intel_skl_int3472_tps68470
softdep ov8858   pre: intel_skl_int3472_tps68470
```

**`config/modprobe.d/v4l2loopback.conf`** — loopback devices:
```
options v4l2loopback devices=2 video_nr=50,51 exclusive_caps=1,1 card_label="Front Camera,Back Camera"
```

---

## v4l2loopback — making cameras visible to Chrome and Zoom

The IPU3 cameras are exposed through libcamera, but Chrome and Zoom expect a
V4L2 device. A v4l2loopback device bridges them.

```bash
sudo apt install v4l2loopback-dkms python3-gi python3-gi-cairo gir1.2-gstreamer-1.0 \
                 gstreamer1.0-plugins-base gstreamer1.0-libcamera
```

### Why `exclusive_caps=1,1` is required

With `exclusive_caps=1` per device, each advertises only `V4L2_CAP_VIDEO_CAPTURE`.
Chrome/PipeWire use this flag to distinguish cameras from video output devices.
Without it (or if only the first device gets `exclusive_caps=1`), Chrome will not
list the device at all.

### Why `v4l2sink` does not work here

With `exclusive_caps=1`, v4l2loopback does not advertise `V4L2_CAP_VIDEO_OUTPUT`,
so GStreamer's `v4l2sink` element refuses to open it. The `write()` syscall path
is the only producer API available; consumers use the standard CAPTURE streaming
API as normal.

### The `struct v4l2_format` reserved-field bug (kernel 6.17)

On kernel 6.17, `struct v4l2_format` is **208 bytes**, not 204:

```
type     (4 bytes)
reserved (4 bytes)   ← grown in kernel 6.17 headers
union fmt (200 bytes)
```

The correct ioctl number is `0xc0d05605`. Using 204 gives `0xc0cc5605` and
silently corrupts every `VIDIOC_S_FMT` call — the format appears to succeed
but the device stays at its default BGR4 640×480.

Verify on your kernel:

```bash
strace -e raw=ioctl v4l2-ctl -d /dev/video50 \
    --set-fmt-video=width=1280,height=720,pixelformat=YUYV 2>&1 | grep 5605
# 0xc0d05605 = 208 bytes (correct for kernel 6.17)
# 0xc0cc5605 = 204 bytes (wrong, older headers)
```

Also note: with `exclusive_caps=1`, `VIDIOC_S_FMT` requires
`V4L2_BUF_TYPE_VIDEO_OUTPUT` (type=2). Passing CAPTURE (type=1) returns `EINVAL`.

### Installing the loopback service

```bash
cp loopback/dell5285-camera-loopback ~/.local/bin/
chmod +x ~/.local/bin/dell5285-camera-loopback
cp loopback/dell5285-camera-loopback.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dell5285-camera-loopback.service
```

The daemon is fully automatic: it starts a libcamera pipeline when an app opens
a loopback device and tears it down when the app closes it. Camera switching
(front ↔ back) is handled transparently — the IPU3 IMGU constraint (one pipeline
at a time) is enforced internally.

---

## Camera visibility in Chrome and Zoom

Both `/dev/video50` (front) and `/dev/video51` (back) are visible and functional
in Zoom, Chrome, and GNOME Camera.

**Zoom** enumerates V4L2 devices directly (`/dev/video*`). Both loopback devices
appear in the camera list. Selecting either one starts the corresponding libcamera
pipeline via the daemon.

**Chrome** uses the XDG Camera Portal (PipeWire / WirePlumber). Both devices
appear because `exclusive_caps=1,1` ensures each reports only
`V4L2_CAP_VIDEO_CAPTURE` — Chrome rejects any device with the `V4L2_CAP_VIDEO_OUTPUT`
flag. WirePlumber creates Video/Source nodes for both and they are available
through the portal.

**Switching cameras:** apps typically close the current camera and reopen the
selected one. The daemon detects this via inotify and switches the active
libcamera pipeline automatically (with a ~2 s startup delay for the new pipeline).

---

## Known cosmetic warnings (safe to ignore)

```
Unable to get rectangle N on pad 0/0: Inappropriate ioctl
```
OV8858's kernel driver lacks crop rectangle support; libcamera sets a default.

```
ov8858.yaml not found for IPA module ipu3
```
No calibration tuning file exists for OV8858 in libcamera. Falls back to
`uncalibrated.yaml`. Camera works; image quality may be slightly off.

---

## Ubuntu GNOME Camera app

GNOME Camera works while the loopback service is running. The daemon only holds
a libcamera pipeline when an app is actively consuming a loopback device; when
idle the pipeline is in NULL state and libcamera is fully released. GNOME Camera
therefore gets exclusive access as long as no loopback consumer (Zoom, Chrome)
is open at the same time.

---

## Tested on

- Machine: Dell Latitude 5285 2-in-1
- OS: Ubuntu 25.10
- Kernel: 6.17.0-19-generic
- libcamera: system package (Ubuntu 25.10)
- v4l2loopback-dkms: system package
- Working in: Chrome (Google Meet), Zoom, GNOME Camera, ffmpeg, GStreamer
- Both front (OV5670) and back (OV8858) cameras work and are switchable
