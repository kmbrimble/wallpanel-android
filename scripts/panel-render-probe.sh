#!/usr/bin/env bash
#
# panel-render-probe.sh — does the panel actually have the dashboard on screen?
#
# Usage: scripts/panel-render-probe.sh [tag]
#   SMOKE_SERIAL=<serial>   override device (else scripts/adb-device.sh resolves it)
#   PROBE_DIR=<dir>         where to keep captures (default: mktemp -d)
#
# Exit status: 0 = RENDERING, 1 = not rendering, 2 = could not probe.
#
# WHY THIS EXISTS
#   Both smoke scripts assert process liveness, window focus and a bound renderer.
#   On 2026-08-30 all three were true while the panel sat on Home Assistant's own
#   loading screen, permanently, after a single renderer crash. None of those
#   assertions can tell a working panel from a wedged one. This can.
#
# HOW IT DECIDES — two independent signals, both required for RENDERING:
#   size   The dashboard carries two live IR camera feeds, so a rendered frame
#          compresses to ~1.2MB. The clock screensaver is ~42KB; HA's loading
#          screen is ~20KB. Size alone would be fooled by any busy static image.
#   delta  Two captures 3s apart. Live camera noise makes consecutive frames
#          differ in ~1.2M bytes. A stuck page is byte-identical, or nearly so.
#
# KNOWN LIMITS — read before trusting a verdict
#   * The size signal assumes a dashboard containing live camera feeds. On a
#     static dashboard a healthy panel would look "LARGE-BUT-IDENTICAL", not
#     RENDERING. Retune SIZE_MIN/the delta rule if the dashboard changes.
#   * Screensaver (~42KB) and HA-loading (~20KB) both fall under SIZE_SMALL. This
#     reports "small" for both; it does not claim to tell them apart.
#   * SMALL-BUT-CHANGING means an animated spinner — a live but stuck frontend.
#     That is a real observed state, not noise.
#   * This is a heuristic. For anything load-bearing, look at the PNG.
#
# It deliberately does NOT tap the screen: a tap on a live dashboard could
# actuate a Home Assistant control. Dismiss the screensaver yourself if needed.
set -uo pipefail

SIZE_MIN=500000     # above this, with frame delta, means a live dashboard
SIZE_SMALL=200000   # below this means screensaver or a loading/blank page

TAG="${1:-probe}"
DIR="${PROBE_DIR:-$(mktemp -d)}"
mkdir -p "$DIR"

SERIAL="${SMOKE_SERIAL:-}"
if [[ -z "$SERIAL" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SERIAL="$(bash "$HERE/adb-device.sh" 2>/dev/null | tail -1)"
    SERIAL="${SERIAL:-192.168.0.52:5555}"
fi

capture() { # capture <destination>
    adb -s "$SERIAL" shell screencap -p /sdcard/_probe.png >/dev/null 2>&1 || return 1
    adb -s "$SERIAL" pull /sdcard/_probe.png "$1" >/dev/null 2>&1 || return 1
    [[ -s "$1" ]]
}

a="$DIR/${TAG}_a.png"; b="$DIR/${TAG}_b.png"
if ! capture "$a"; then echo "[$TAG] could not capture from $SERIAL"; exit 2; fi
sleep 3
if ! capture "$b"; then echo "[$TAG] could not capture from $SERIAL"; exit 2; fi

sa=$(stat -c%s "$a"); sb=$(stat -c%s "$b")
identical=$(cmp -s "$a" "$b" && echo yes || echo no)
delta=$(cmp -l "$a" "$b" 2>/dev/null | wc -l)

if   [[ $sa -gt $SIZE_MIN && $identical == no ]]; then verdict="RENDERING"; rc=0
elif [[ $sa -lt $SIZE_SMALL && $identical == yes ]]; then verdict="STATIC-SMALL (screensaver, or stuck/blank page)"; rc=1
elif [[ $sa -lt $SIZE_SMALL ]]; then verdict="SMALL-BUT-CHANGING (animated spinner — live but stuck frontend)"; rc=1
else verdict="LARGE-BUT-IDENTICAL (frozen dashboard image?)"; rc=1
fi

echo "[$TAG] sizeA=$sa sizeB=$sb identical=$identical deltabytes=$delta -> $verdict"
echo "[$TAG] captures: $a $b"
exit $rc
