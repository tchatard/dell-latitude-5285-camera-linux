#!/usr/bin/env bash
# Dell Latitude 5285 camera fix — install helper
# Run from the repository root.
# Kernel module *building* is not automated here; see README.md for build steps.
set -euo pipefail

KVER=$(uname -r)
INST=/lib/modules/${KVER}/updates/dkms

###############################################################################
# 1. Config files
###############################################################################
echo "==> Installing modprobe / modules-load config..."
sudo cp config/modprobe.d/v4l2loopback.conf      /etc/modprobe.d/
sudo cp config/modprobe.d/dell-5285-camera.conf  /etc/modprobe.d/
sudo cp config/modules-load.d/dell-5285-lpss.conf /etc/modules-load.d/

###############################################################################
# 2. v4l2loopback
###############################################################################
echo "==> Installing v4l2loopback-dkms..."
sudo apt-get install -y v4l2loopback-dkms

###############################################################################
# 3. GStreamer / libcamera dependencies for the loopback service
###############################################################################
echo "==> Installing Python / GStreamer / libcamera packages..."
sudo apt-get install -y \
    python3-gi python3-gi-cairo gir1.2-gstreamer-1.0 \
    gstreamer1.0-plugins-base gstreamer1.0-libcamera

###############################################################################
# 4. Patched kernel modules (must already be built — see README)
###############################################################################
echo "==> Checking for built .ko files..."
MISSING=0
for f in \
    patches/lpss/intel-lpss-acpi.ko \
    patches/tps68470/intel_skl_int3472_tps68470.ko \
    patches/ipu_bridge/ipu_bridge.ko \
    patches/ov8858/ov8858.ko
do
    if [[ ! -f "$f" ]]; then
        echo "    MISSING: $f  (build it first — see README)"
        MISSING=1
    fi
done

if [[ $MISSING -eq 0 ]]; then
    echo "==> Installing patched kernel modules to ${INST}..."
    sudo mkdir -p "${INST}"
    for ko in \
        patches/lpss/intel-lpss-acpi.ko \
        patches/lpss/intel-lpss.ko \
        patches/lpss/intel-lpss-pci.ko \
        patches/tps68470/intel_skl_int3472_tps68470.ko \
        patches/ipu_bridge/ipu_bridge.ko \
        patches/ov8858/ov8858.ko
    do
        [[ -f "$ko" ]] || continue
        base=$(basename "$ko")
        sudo zstd -f "$ko" -o "${INST}/${base}.zst"
        echo "    installed ${base}.zst"
        # Remove any uncompressed copy that would take precedence
        if [[ -f "${INST}/${base}" ]]; then
            sudo rm -f "${INST}/${base}"
            echo "    removed stale uncompressed ${INST}/${base}"
        fi
    done
    echo "==> Running depmod and update-initramfs..."
    sudo depmod -a
    sudo update-initramfs -u -k "${KVER}"
else
    echo ""
    echo "Build the missing modules first (see README), then re-run this script."
fi

###############################################################################
# 5. Loopback service
###############################################################################
echo "==> Installing loopback service..."
install -Dm755 loopback/dell5285-camera-loopback ~/.local/bin/dell5285-camera-loopback
install -Dm644 loopback/dell5285-camera-loopback.service \
    ~/.config/systemd/user/dell5285-camera-loopback.service

systemctl --user daemon-reload
systemctl --user enable dell5285-camera-loopback.service
echo "    Service enabled (will start on next graphical login, or run:"
echo "    systemctl --user start dell5285-camera-loopback.service)"

###############################################################################
echo ""
echo "Done. Reboot to load the patched kernel modules."
