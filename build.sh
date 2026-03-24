#!/usr/bin/env bash
# Dell Latitude 5285 camera — build patched kernel modules
#
# Run from the repository root (sudo required for kernel make).
#
# Expects the kernel source tree at ./build/linux-source-<version>/.
# To set up: mv ~/kernel-build/linux-source-X.Y.Z ./build/
#
# Output: compiled .ko files collected in ./build/artefacts/
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
KVER=$(uname -r)
KVER_BASE="${KVER%%-*}"   # e.g. 6.17.0-19-generic → 6.17.0

# ── locate kernel source ──────────────────────────────────────────────────────
KSRC=$(find "$REPO_ROOT/build/kernel" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
      | while read -r d; do [[ -f "$d/Makefile" ]] && echo "$d" && break; done)
if [[ -z "$KSRC" ]]; then
    echo "ERROR: kernel source not found under $REPO_ROOT/build/kernel/" >&2
    echo "       Move it there first, e.g.:" >&2
    echo "         mv ~/kernel-build/linux-$KVER_BASE $REPO_ROOT/build/kernel/" >&2
    exit 1
fi

OUT="$REPO_ROOT/build/artefacts"
mkdir -p "$OUT"

# ── module source directories ─────────────────────────────────────────────────
MODULES=(
    patches/lpss
    patches/tps68470
    patches/ipu_bridge
    patches/ov8858
)

# ── build ─────────────────────────────────────────────────────────────────────
for mod_dir in "${MODULES[@]}"; do
    abs_dir="$REPO_ROOT/$mod_dir"
    echo "==> Building $mod_dir ..."
    sudo make -C "$KSRC" CC=x86_64-linux-gnu-gcc M="$abs_dir" modules
done

# ── collect artefacts ─────────────────────────────────────────────────────────
echo "==> Collecting .ko files to $OUT/ ..."
find "$REPO_ROOT/patches" -name "*.ko" -exec cp {} "$OUT/" \;

echo ""
echo "Done. Built modules are in $OUT/"
echo "Run ./install.sh to install them, then reboot."
