#!/usr/bin/env bash
# Dell Latitude 5285 camera fix — install helper
#
# Run as: sudo ./install.sh
#
# Builds (timestamp-checked), installs modules, signs for Secure Boot,
# and sets up the loopback service.  This is the only script you need.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root: sudo $0" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
KVER=$(uname -r)
INST=/lib/modules/${KVER}/updates/dkms
ARTEFACTS="$REPO_ROOT/build/artefacts"

# Resolve the real (non-root) user when invoked via sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_UID=$(id -u "$REAL_USER")

###############################################################################
# 1. Config files
###############################################################################
echo "==> Installing modprobe / modules-load config..."
cp config/modprobe.d/v4l2loopback.conf      /etc/modprobe.d/
cp config/modprobe.d/dell-5285-camera.conf  /etc/modprobe.d/
cp config/modules-load.d/dell-5285-lpss.conf /etc/modules-load.d/

###############################################################################
# 2. v4l2loopback
###############################################################################
echo "==> Installing v4l2loopback-dkms..."
apt-get install -y v4l2loopback-dkms

###############################################################################
# 3. GStreamer / libcamera dependencies for the loopback service
###############################################################################
echo "==> Installing Python / GStreamer / libcamera packages..."
apt-get install -y \
    python3-gi python3-gi-cairo gir1.2-gstreamer-1.0 \
    gstreamer1.0-plugins-base gstreamer1.0-libcamera

###############################################################################
# 4. Build (timestamp-checked) + install patched kernel modules
###############################################################################
echo "==> Checking / building kernel modules..."
"$REPO_ROOT/build.sh"

echo "==> Installing patched kernel modules to ${INST}..."
mkdir -p "${INST}"
for ko in \
    "$ARTEFACTS/intel-lpss-acpi.ko" \
    "$ARTEFACTS/intel-lpss.ko" \
    "$ARTEFACTS/intel-lpss-pci.ko" \
    "$ARTEFACTS/intel_skl_int3472_tps68470.ko" \
    "$ARTEFACTS/ipu_bridge.ko" \
    "$ARTEFACTS/ov8858.ko"
do
    [[ -f "$ko" ]] || { echo "    MISSING: $ko — did build.sh fail?"; exit 1; }
    base=$(basename "$ko")
    zstd -f "$ko" -o "${INST}/${base}.zst"
    echo "    installed ${base}.zst"
    # Remove any uncompressed copy that would take precedence
    [[ -f "${INST}/${base}" ]] && rm -f "${INST}/${base}"
done

###############################################################################
# 5. Sign modules (Secure Boot) + depmod + update-initramfs
###############################################################################
echo ""
echo "==> Signing kernel modules for Secure Boot..."
"$REPO_ROOT/sign-modules.sh"

###############################################################################
# 6. Loopback service (installed as the real user, not root)
###############################################################################
echo "==> Installing loopback service for user $REAL_USER..."
install -Dm755 loopback/dell5285-camera-loopback \
    "$REAL_HOME/.local/bin/dell5285-camera-loopback"
install -Dm644 loopback/dell5285-camera-loopback.service \
    "$REAL_HOME/.config/systemd/user/dell5285-camera-loopback.service"

XDG_RUNTIME_DIR="/run/user/${REAL_UID}" \
    sudo -u "$REAL_USER" systemctl --user daemon-reload
XDG_RUNTIME_DIR="/run/user/${REAL_UID}" \
    sudo -u "$REAL_USER" systemctl --user enable dell5285-camera-loopback.service

echo "    Service enabled for $REAL_USER."

###############################################################################
echo ""
echo "Done. Reboot to load the patched kernel modules."
