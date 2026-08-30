#!/usr/bin/env bash
# Renderer-crash resilience check for the running dev app.
#
# Usage: scripts/smoke-renderer-crash.sh
#
# Requires xyz.wallpanel.app.kmb.dev to already be installed and running
# (e.g. via scripts/smoke-device.sh, or a manual install+launch) -- this
# script does not install/launch/uninstall anything itself.
#
# Repeatedly finds the app's current WebView renderer process (via
# `dumpsys activity services`, which ties a ServiceRecord under the app's own
# component to the renderer's PID) and kills it with `adb shell am crash
# <pid>`, which reproduced the exact "Render process ... wasn't handled by
# all associated webviews" abort documented in REVIEW.md. A single crash
# only reproduces the abort intermittently (whether the screensaver's
# unprotected WebView happens to be attached at the time), so this loops
# several cycles and fails on the first cycle that shows the app didn't
# survive cleanly.
#
# PASS means: the app process survived N consecutive renderer kills, kept
# window focus on the main activity, and a fresh renderer ServiceRecord
# appeared after each kill. As of this script being written, REVIEW.md
# documents why this currently FAILS (an unprotected screensaver WebView) --
# that failure is expected and this script is not meant to pass yet.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./adb-device.sh
source "$SCRIPT_DIR/adb-device.sh"

DEV_APP_ID="xyz.wallpanel.app.kmb.dev"
LAUNCH_ACTIVITY="xyz.wallpanel.app.ui.activities.BrowserActivityNative"
ADB_TIMEOUT=15
CYCLES="${SMOKE_RENDERER_CYCLES:-4}"
SETTLE_SECONDS=5
# REVIEW.md: the screensaver's WebView has no onRenderProcessGone handler, and
# only mounts after configuration.inactivityTime (default 30000ms) of no touch
# input. A crash fired well within that window never has the screensaver's
# WebView attached, so it can't reproduce the failure this script exists to
# check for -- wait past the default inactivity timeout, untouched, before
# each crash so the screensaver has a real chance to be showing.
IDLE_WAIT_SECONDS="${SMOKE_RENDERER_IDLE_WAIT:-35}"

FAILURES=()
log() { echo "[renderer-smoke] $*" >&2; }
fail_reason() { FAILURES+=("$1"); log "FAIL: $1"; }

die() {
    log "FAIL: $1"
    echo "RESULT: FAIL"
    exit 1
}

if [[ -n "${SMOKE_SERIAL:-}" ]]; then
    SERIAL="$SMOKE_SERIAL"
    log "Connecting to $SERIAL"
    timeout "$ADB_TIMEOUT" adb connect "$SERIAL" >/dev/null 2>&1
    STATE=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" get-state 2>/dev/null | tr -d '\r' || true)
    [[ "$STATE" == "device" ]] || die "device $SERIAL unreachable (get-state='$STATE')"
else
    SERIAL=$(wallpanel_resolve_adb_serial) || die "could not reach the tablet at $WALLPANEL_TABLET_IP (pinned port and mdns discovery both failed -- see [adb-device] messages above)"
    log "Connected to $SERIAL"
fi

get_pid() {
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell pidof "$DEV_APP_ID" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

# Never crash anything but the dev app's own renderer: refuse to proceed
# unless the dev app is actually the one currently installed and running.
BASELINE_PID=$(get_pid)
[[ -n "$BASELINE_PID" ]] || die "$DEV_APP_ID is not running -- install and launch it first (this script does not do that itself)"
log "Dev app running as pid $BASELINE_PID"

# Parses `dumpsys activity services` for the ServiceRecord owned by our app
# component (xyz.wallpanel.app.kmb.dev/org.chromium.content.app.SandboxedProcessService0:N)
# and returns the renderer's own pid from the following app=ProcessRecord{...} line.
# This is the deterministic form: `am crash <pid>` on this targets the renderer
# specifically, unlike `am crash <package>`, which can non-deterministically hit
# either the main process or an associated renderer depending on what's alive.
get_renderer_pid() {
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys activity services 2>/dev/null \
        | awk -v pkg="$DEV_APP_ID" '
            /ServiceRecord/ { in_record = (index($0, pkg "/org.chromium.content.app.SandboxedProcessService") > 0) }
            in_record && /app=ProcessRecord/ { print; exit }
        ' \
        | sed -n 's/.*ProcessRecord{[^ ]* \([0-9]\+\):.*/\1/p'
}

check_window_focus() {
    # One retry with a longer settle: a wake+focus-read race (not a real crash
    # symptom) can transiently report no focus right after injecting a crash.
    local hit
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    sleep 1
    hit=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys window 2>/dev/null \
        | grep -i "mCurrentFocus" | grep -F "$DEV_APP_ID/$LAUNCH_ACTIVITY")
    if [[ -z "$hit" ]]; then
        timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        sleep 2
        hit=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys window 2>/dev/null \
            | grep -i "mCurrentFocus" | grep -F "$DEV_APP_ID/$LAUNCH_ACTIVITY")
    fi
    printf '%s' "$hit"
}

for cycle in $(seq 1 "$CYCLES"); do
    log "--- cycle $cycle/$CYCLES ---"
    log "Waiting ${IDLE_WAIT_SECONDS}s untouched so the screensaver's inactivity timeout can fire"
    sleep "$IDLE_WAIT_SECONDS"

    RENDERER_PID=$(get_renderer_pid)
    if [[ -z "$RENDERER_PID" ]]; then
        fail_reason "[cycle $cycle] no renderer process found for $DEV_APP_ID (has a WebView ever loaded content?)"
        break
    fi
    log "Found renderer pid $RENDERER_PID (ServiceRecord for $DEV_APP_ID)"

    APP_PID_BEFORE=$(get_pid)
    [[ -n "$APP_PID_BEFORE" ]] || { fail_reason "[cycle $cycle] app process not alive before crash injection"; break; }

    log "Crashing renderer pid $RENDERER_PID"
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell am crash "$RENDERER_PID" >/dev/null 2>&1

    sleep "$SETTLE_SECONDS"

    APP_PID_AFTER=$(get_pid)
    if [[ -z "$APP_PID_AFTER" ]]; then
        fail_reason "[cycle $cycle] app process died and did not come back (pidof empty)"
        break
    fi
    if [[ "$APP_PID_AFTER" != "$APP_PID_BEFORE" ]]; then
        fail_reason "[cycle $cycle] app process restarted ($APP_PID_BEFORE -> $APP_PID_AFTER) -- the renderer crash was not handled, the app itself aborted"
        break
    fi

    if [[ -z "$(check_window_focus)" ]]; then
        fail_reason "[cycle $cycle] main activity ($DEV_APP_ID/$LAUNCH_ACTIVITY) does not have window focus after renderer crash"
        break
    fi

    NEW_RENDERER_PID=$(get_renderer_pid)
    if [[ -z "$NEW_RENDERER_PID" || "$NEW_RENDERER_PID" == "$RENDERER_PID" ]]; then
        fail_reason "[cycle $cycle] no fresh renderer process appeared after the crash (WebView was not rebuilt)"
        break
    fi

    log "Cycle $cycle OK: app pid unchanged ($APP_PID_AFTER), focus held, new renderer pid $NEW_RENDERER_PID"
done

echo
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    echo "RESULT: PASS"
    echo "$DEV_APP_ID survived $CYCLES consecutive renderer crashes with window focus held and a fresh renderer each time."
    exit 0
else
    echo "RESULT: FAIL"
    printf ' - %s\n' "${FAILURES[@]}"
    exit 1
fi
