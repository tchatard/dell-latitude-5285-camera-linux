#!/usr/bin/env bash
# Dell Latitude 5285 camera — Secure Boot module signing helper
#
# Run from the repository root as root: sudo -E ./sign-modules.sh
#
# TWO-PHASE workflow:
#
#   Phase 1 — first run (MOK not yet enrolled):
#     Generates mok/mok.key + mok/mok.crt, queues the key for UEFI enrollment,
#     then exits and asks you to reboot.  On the next boot, the blue MOK Manager
#     screen appears — choose "Enroll MOK", confirm with the password you set.
#
#   Phase 2 — after reboot with MOK enrolled:
#     Re-run this script.  It will decompress each installed .ko.zst, embed the
#     cryptographic signature, recompress, then regenerate the initramfs.
#
# IMPORTANT: keep mok/mok.key private.  It is listed in .gitignore.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
MOK_DIR="$REPO_ROOT/mok"
MOK_KEY="$MOK_DIR/mok.key"
MOK_CERT="$MOK_DIR/mok.crt"
MOK_DER="$MOK_DIR/mok.der"

KVER=$(uname -r)
INST="/lib/modules/$KVER/updates/dkms"

# Modules to sign (base names without .ko.zst)
# ipu3_imgu is a staging kernel module not signed with a MOK-trusted key by Ubuntu,
# so Secure Boot rejects it without our signature.
MODULES=(
    intel-lpss-acpi
    intel-lpss
    intel-lpss-pci
    ipu_bridge
    intel_skl_int3472_tps68470
    ov8858
    ipu3-imgu
)

# ── helpers ──────────────────────────────────────────────────────────────────
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ── root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

# ── locate sign-file ─────────────────────────────────────────────────────────
find_sign_file() {
    local ksrc
    ksrc=$(find "$REPO_ROOT/build/kernel" -maxdepth 1 -name 'linux-source-*' -type d 2>/dev/null | head -1)
    local candidates=(
        "${ksrc:+$ksrc/scripts/sign-file}"
        "/usr/src/linux-headers-$KVER/scripts/sign-file"
        "/usr/src/linux-headers-${KVER%%-generic}/scripts/sign-file"
        "/usr/src/linux-headers-${KVER%-*}/scripts/sign-file"
    )
    for f in "${candidates[@]}"; do
        [[ -x "$f" ]] && { echo "$f"; return; }
    done
    # last resort: search /usr/src
    find /usr/src -name sign-file -type f -executable 2>/dev/null | head -1
}

SIGN_FILE=$(find_sign_file)
# sign-file is only needed in phase 2; we validate it there.

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — generate MOK and queue enrollment
# ─────────────────────────────────────────────────────────────────────────────
generate_and_enroll() {
    info "Generating Machine Owner Key (MOK) in $MOK_DIR/ ..."
    mkdir -p "$MOK_DIR"
    chmod 700 "$MOK_DIR"

    openssl req -new -x509 -newkey rsa:2048 \
        -keyout "$MOK_KEY" \
        -out    "$MOK_CERT" \
        -days   3650 \
        -subj   "/CN=Dell 5285 Camera Modules MOK/" \
        -nodes
    openssl x509 -in "$MOK_CERT" -outform DER -out "$MOK_DER"
    chmod 600 "$MOK_KEY"

    info "Queuing MOK for UEFI enrollment (mokutil --import)..."
    echo ""
    echo "  You will be asked to choose a one-time password."
    echo "  Remember it — you must enter it in the MOK Manager screen on next boot."
    echo ""
    mokutil --import "$MOK_DER"

    echo ""
    info "MOK queued successfully."
    echo ""
    echo "  Next steps:"
    echo "    1. Reboot now."
    echo "    2. At the blue MOK Manager screen:"
    echo "         Enroll MOK → Continue → enter your password → Reboot"
    echo "    3. After booting back in, re-run this script as root to sign the modules."
    echo ""
    echo "  Key files saved in: $MOK_DIR/"
    echo "  Add mok/mok.key to .gitignore if not already done."
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — sign installed modules
# ─────────────────────────────────────────────────────────────────────────────
sign_modules() {
    [[ -x "$SIGN_FILE" ]] || \
        die "sign-file not found or not executable (looked in kernel source and headers dirs).\n    Build the kernel modules first, or install linux-headers-$KVER."

    [[ -f "$MOK_KEY"  ]] || die "MOK private key not found: $MOK_KEY"
    [[ -f "$MOK_CERT" ]] || die "MOK certificate not found: $MOK_CERT"

    info "Signing modules in $INST/ ..."
    local signed=0 skipped=0
    local tmpko

    for mod in "${MODULES[@]}"; do
        # Check updates/dkms first, then fall back to searching the full module tree
        local zst="$INST/${mod}.ko.zst"
        if [[ ! -f "$zst" ]]; then
            zst=$(find "/lib/modules/$KVER" -name "${mod}.ko.zst" 2>/dev/null | head -1)
        fi
        if [[ -z "$zst" || ! -f "$zst" ]]; then
            echo "    SKIP (not installed): $mod"
            (( skipped++ )) || true
            continue
        fi

        tmpko=$(mktemp --suffix=".ko")
        trap 'rm -f "$tmpko"' EXIT

        # decompress
        zstd -d "$zst" -o "$tmpko" -f -q

        # sign (signature is appended to the .ko ELF file)
        "$SIGN_FILE" sha256 "$MOK_KEY" "$MOK_CERT" "$tmpko"

        # recompress in-place
        zstd -f -q "$tmpko" -o "$zst"
        rm -f "$tmpko"
        trap - EXIT

        echo "    signed: ${mod}.ko.zst"
        (( signed++ )) || true
    done

    echo ""
    info "$signed module(s) signed, $skipped skipped."

    info "Running depmod + update-initramfs..."
    depmod -a
    update-initramfs -u -k "$KVER"

    echo ""
    info "Done.  Reboot to load the signed modules with Secure Boot active."
}

# ─────────────────────────────────────────────────────────────────────────────
# DISPATCH — detect which phase we are in
# ─────────────────────────────────────────────────────────────────────────────

# If MOK key doesn't exist yet, always run phase 1.
if [[ ! -f "$MOK_KEY" ]]; then
    generate_and_enroll
    exit 0
fi

# MOK key exists — check if it is enrolled in the firmware.
# Use --import as a probe: if already enrolled it prints "already enrolled"
# and exits immediately without prompting for a password.  Both --test-key
# and --list-enrolled can be unreliable on Ubuntu with sudo-rs.
if mokutil --import "$MOK_DER" </dev/null 2>&1 | grep -qi "already enrolled"; then
    info "MOK is enrolled. Running phase 2 (module signing)..."
    sign_modules
else
    # Key exists but is not enrolled yet.
    # Could be waiting for the next boot, or enrollment was missed/declined.
    if mokutil --list-new 2>/dev/null | grep -q "Dell 5285"; then
        echo ""
        echo "  MOK enrollment is still pending — it has not been confirmed in UEFI yet."
        echo "  Reboot and select 'Enroll MOK' in the MOK Manager screen."
        echo ""
        echo "  If you need to re-queue the enrollment password, run:"
        echo "    sudo mokutil --import $MOK_DER"
    else
        echo ""
        echo "  MOK exists locally but is not enrolled and not pending."
        echo "  Re-queuing enrollment..."
        echo ""
        mokutil --import "$MOK_DER"
        echo ""
        echo "  Reboot and select 'Enroll MOK' in the MOK Manager, then re-run this script."
    fi
fi
