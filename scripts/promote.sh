#!/usr/bin/env bash
# promote.sh — install a signed arm64 release to the production app, verify it
# actually renders, and roll back automatically if it doesn't.
#
# Usage: scripts/promote.sh <signed-arm64-apk>
#   SMOKE_SERIAL=<serial>   override device (else scripts/adb-device.sh resolves it)
#
# WHY THIS EXISTS
#   `adb install -r` does NOT restart the foreground app on this launcher (found
#   while promoting kmb.3, handled manually at the time, never documented until
#   now). The old release policy ran panel-render-probe.sh BEFORE install, which
#   only proves the panel was alive on the PREVIOUS build -- it never confirms
#   the new build renders anything. A build that shows a blank page would have
#   promoted green. This script closes that gap: install, explicitly relaunch,
#   then probe the NEW build, and roll back automatically if it fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./adb-device.sh
source "$SCRIPT_DIR/adb-device.sh"

PROD_APP_ID="xyz.wallpanel.app.kmb"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-/root/.android-sdk/build-tools/34.0.0}"
AAPT2="$BUILD_TOOLS/aapt2"
RELEASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/release-out"
ADB_TIMEOUT=15

log() { echo "[promote] $*" >&2; }
die() { log "FAIL: $1"; echo "RESULT: FAIL"; exit 1; }

APK="${1:-}"
[[ -n "$APK" ]] || die "usage: promote.sh <signed-arm64-apk>"
[[ -f "$APK" ]] || die "APK not found: $APK"
[[ -x "$AAPT2" ]] || die "aapt2 not found or not executable at $AAPT2"

# --- parse applicationId from the APK itself, never trust the filename ---
BADGING=$("$AAPT2" dump badging "$APK" 2>/dev/null) || die "aapt2 dump badging failed for $APK"
APK_PKG=$(printf '%s\n' "$BADGING" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
if [[ "$APK_PKG" != "$PROD_APP_ID" ]]; then
    die "refusing to promote: APK applicationId is '$APK_PKG', expected exactly '$PROD_APP_ID'"
fi

LAUNCH_ACTIVITY=$(printf '%s\n' "$BADGING" | sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p")
[[ -n "$LAUNCH_ACTIVITY" ]] || die "could not parse launchable-activity out of $APK"

if [[ -n "${SMOKE_SERIAL:-}" ]]; then
    SERIAL="$SMOKE_SERIAL"
    timeout "$ADB_TIMEOUT" adb connect "$SERIAL" >/dev/null 2>&1
else
    SERIAL=$(wallpanel_resolve_adb_serial) || die "could not reach the tablet at $WALLPANEL_TABLET_IP"
fi
log "Connected to $SERIAL"

# --- find the currently-installed release to roll back to on failure ---
# By policy every promoted APK is kept at release-out/WallPanelApp-arm64-<versionName>.apk;
# the previous release is the newest one there that isn't the one being installed now.
PREV_APK=$(ls -t "$RELEASE_DIR"/WallPanelApp-arm64-*.apk 2>/dev/null \
    | grep -v -- '-aligned\.apk$' \
    | grep -v -- '-signed\.apk$' \
    | grep -vF "/$(basename "$APK")" \
    | head -1)
if [[ -z "$PREV_APK" ]]; then
    log "warning: no previous release-out APK found to roll back to -- a failed probe below cannot be auto-recovered"
fi

relaunch() {
    local pkg="$1"
    log "Relaunching $pkg/$LAUNCH_ACTIVITY"
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    # A plain `am start` after `install -r` can re-bind to an already-running
    # process still holding the OLD dex in memory -- force-stop first so the
    # new APK is what actually loads.
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell am force-stop "$pkg" >/dev/null 2>&1
    timeout 30 adb -s "$SERIAL" shell am start -W -n "$pkg/$LAUNCH_ACTIVITY" >/tmp/promote-launch.log 2>&1
    local rc=$?
    cat /tmp/promote-launch.log >&2
    if [[ $rc -ne 0 ]] || grep -qiE "^Error|does not exist|Exception" /tmp/promote-launch.log; then
        return 1
    fi
    sleep 3
    return 0
}

probe() {
    local tag="$1"
    bash "$SCRIPT_DIR/panel-render-probe.sh" "$tag"
}

# --- install the new build ---
log "Installing $APK as $PROD_APP_ID"
if ! timeout 90 adb -s "$SERIAL" install -r "$APK" >/tmp/promote-install.log 2>&1 \
    || grep -qi "Failure" /tmp/promote-install.log; then
    cat /tmp/promote-install.log >&2
    die "adb install failed, nothing changed on device -- old build is still running"
fi

if ! relaunch "$PROD_APP_ID"; then
    die "relaunch of $PROD_APP_ID after install failed -- see am start output above. Old code may still be resident; do not assume the panel is healthy."
fi

log "Probing the newly-installed build"
if probe "post-install"; then
    echo "RESULT: PASS"
    echo "$PROD_APP_ID promoted, relaunched, and confirmed rendering the dashboard."
    exit 0
fi

log "Post-install probe FAILED -- new build does not appear to be rendering the dashboard"
if [[ -z "$PREV_APK" ]]; then
    die "no previous release-out APK available to roll back to. Panel is left on the FAILED build. Physical attention required."
fi

log "Rolling back to $(basename "$PREV_APK")"
if ! timeout 90 adb -s "$SERIAL" install -r -d "$PREV_APK" >/tmp/promote-rollback.log 2>&1 \
    || grep -qi "Failure" /tmp/promote-rollback.log; then
    cat /tmp/promote-rollback.log >&2
    die "PROMOTION FAILED AND ROLLBACK ALSO FAILED. Panel is in an unknown state on $PROD_APP_ID. Physical attention required immediately."
fi

if ! relaunch "$PROD_APP_ID"; then
    die "PROMOTION FAILED; rollback APK installed but relaunch failed. Physical attention required."
fi

log "Probing after rollback"
if probe "post-rollback"; then
    echo "RESULT: FAIL"
    echo "The new build ($APK) failed the post-install render probe and was NOT promoted."
    echo "Rolled back to $(basename "$PREV_APK") and confirmed it is rendering again. Panel is healthy on the OLD build."
    exit 1
else
    echo "RESULT: FAIL"
    echo "PROMOTION FAILED AND ROLLBACK DID NOT RESTORE RENDERING."
    echo "Panel state is unknown. Physical attention required immediately -- do not retry automatically."
    exit 1
fi
