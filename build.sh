#!/usr/bin/env bash
# Dell Latitude 5285 camera — build patched kernel modules
#
# Checks timestamps: only rebuilds modules whose source files are newer than
# the last-built .ko.  Safe to call repeatedly; exits 0 with nothing to do
# if everything is up to date.
#
# Output: compiled .ko files collected in ./build/artefacts/
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
KVER=$(uname -r)

# ── locate kernel headers ─────────────────────────────────────────────────────
SYSTEM_HEADERS="/lib/modules/${KVER}/build"
if [[ -f "${SYSTEM_HEADERS}/Makefile" ]]; then
    KSRC="$SYSTEM_HEADERS"
    echo "==> Using system kernel headers: $KSRC"
else
    KSRC=$(find "$REPO_ROOT/build/kernel" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
          | while read -r d; do [[ -f "$d/Makefile" ]] && echo "$d" && break; done)
    if [[ -z "$KSRC" ]]; then
        echo "ERROR: kernel headers not found." >&2
        echo "       Install them with: sudo apt-get install linux-headers-${KVER}" >&2
        echo "       Or place a matching source tree under $REPO_ROOT/build/kernel/" >&2
        exit 1
    fi
    echo "==> Using local kernel source: $KSRC"
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

# ── timestamp check ───────────────────────────────────────────────────────────
# Returns 0 (needs rebuild) if any source/header/Makefile in $1 is newer than
# the newest .ko already built there, or if no .ko exists yet.
needs_rebuild() {
    local src_dir="$1"
    local newest_ko
    newest_ko=$(find "$src_dir" -maxdepth 1 -name "*.ko" -printf '%T@ %p\n' 2>/dev/null \
                | sort -rn | head -1 | awk '{print $2}')
    [[ -z "$newest_ko" ]] && return 0
    find "$src_dir" -maxdepth 1 \( -name "*.c" -o -name "*.h" -o -name "Makefile" \) \
        -newer "$newest_ko" -print -quit | grep -q . && return 0
    return 1
}

# ── build ─────────────────────────────────────────────────────────────────────
built_any=0
for mod_dir in "${MODULES[@]}"; do
    abs_dir="$REPO_ROOT/$mod_dir"
    if needs_rebuild "$abs_dir"; then
        echo "==> Building $mod_dir ..."
        make -C "$KSRC" CC=x86_64-linux-gnu-gcc M="$abs_dir" modules
        built_any=1
    else
        echo "==> $mod_dir — up to date, skipping."
    fi
done

# ── collect artefacts ─────────────────────────────────────────────────────────
if [[ $built_any -eq 1 ]]; then
    echo "==> Collecting .ko files to $OUT/ ..."
    find "$REPO_ROOT/patches" -name "*.ko" -exec cp {} "$OUT/" \;
    echo "==> Build complete."
else
    echo "==> All modules up to date."
fi
