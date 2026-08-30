#!/usr/bin/env bash
# Renderer-crash resilience check, run against the PRODUCTION app.
#
# Usage: scripts/smoke-renderer-crash.sh <signed-prod-arm64-apk>
#
# This installs the candidate APK over xyz.wallpanel.app.kmb -- the real wall
# panel -- runs its crash cycles there, and restores the previous release on
# failure. That is deliberate; see "Why production" below.
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
# appeared after each kill. On PASS the candidate is left installed and
# running. On FAIL (or any unexpected exit) the previous release-out/ APK is
# reinstalled and relaunched, so a failed test never leaves a dead panel.
#
# Why production, not the .dev app:
#   The dev app cannot obtain a WebView renderer on this tablet. It requests
#   SandboxedProcessService1, whose ServiceRecord never gets a bound process,
#   while the production app gets SandboxedProcessService0 and works normally.
#   Force-stopping prod and the launcher did not change it, and `pm clear` on
#   dev only left it with no configured URL and therefore no WebView at all.
#   The cause is unexplained and deliberately NOT under investigation -- it
#   affects only the harness, never the shipping app. Testing the signed
#   production artifact is better evidence regardless: it is the exact thing
#   that ships, on the exact config it ships onto.
#
# Safety gates, all before the device is touched -- each refuses outright:
#   * the candidate's applicationId must be the production one
#   * the candidate must be signed with the same key as the app on the device
#     (an install over prod is rejected otherwise, and so would the rollback be)
#   * a restore APK matching the installed versionCode must exist in
#     release-out/, so there is always a way back
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./adb-device.sh
source "$SCRIPT_DIR/adb-device.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_ID="xyz.wallpanel.app.kmb"
LAUNCH_ACTIVITY="xyz.wallpanel.app.ui.activities.BrowserActivityNative"
RELEASE_DIR="${WALLPANEL_RELEASE_DIR:-$REPO_ROOT/release-out}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-/root/.android-sdk/build-tools/34.0.0}"
AAPT2="$BUILD_TOOLS/aapt2"
APKSIGNER="$BUILD_TOOLS/apksigner"
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
INSTALLED=0
PASSED=0
RESTORE_APK=""
SERIAL=""
PREV_STAYON=""

log() { echo "[renderer-smoke] $*" >&2; }
fail_reason() { FAILURES+=("$1"); log "FAIL: $1"; }

# Refusals happen before anything is installed, so they must not trigger the
# restore trap -- hence INSTALLED gating it rather than this function.
die() {
    log "FAIL: $1"
    echo "RESULT: FAIL"
    exit 1
}

launch_and_check() {
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell am start -n "$APP_ID/$LAUNCH_ACTIVITY" >/dev/null 2>&1
    sleep 10
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys window 2>/dev/null \
        | grep -i "mCurrentFocus" | grep -F "$APP_ID/$LAUNCH_ACTIVITY"
}

# Restores the panel unless the run passed. Registered only after a successful
# candidate install, so a preflight refusal can never "restore" over nothing.
restore_panel() {
    # Put the display timeout back however we found it, pass or fail.
    if [[ -n "$PREV_STAYON" ]]; then
        timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell settings put global stay_on_while_plugged_in "$PREV_STAYON" >/dev/null 2>&1
    fi
    [[ "$INSTALLED" -eq 1 && "$PASSED" -eq 0 ]] || return 0
    log "Restoring the previous release: $(basename "$RESTORE_APK")"
    if ! timeout 300 adb -s "$SERIAL" install -r -d "$RESTORE_APK" >/dev/null 2>&1; then
        log "RESTORE FAILED: could not reinstall $RESTORE_APK -- the panel may be left on the candidate build. Reinstall it by hand: adb -s $SERIAL install -r -d $RESTORE_APK"
        return 0
    fi
    if [[ -n "$(launch_and_check)" ]]; then
        log "Restore OK: $APP_ID reinstalled from $(basename "$RESTORE_APK") and foregrounded"
    else
        log "RESTORE INCOMPLETE: reinstalled $(basename "$RESTORE_APK") but $APP_ID/$LAUNCH_ACTIVITY does not have window focus -- check the panel"
    fi
}
trap restore_panel EXIT

# --- preflight: the candidate APK -------------------------------------------

CANDIDATE="${1:-}"
[[ -n "$CANDIDATE" ]] || die "no APK given. Usage: $(basename "$0") <signed-prod-arm64-apk>"
[[ -f "$CANDIDATE" ]] || die "APK not found: $CANDIDATE"
[[ -x "$AAPT2" ]] || die "aapt2 not found at $AAPT2 (set ANDROID_BUILD_TOOLS)"
[[ -x "$APKSIGNER" ]] || die "apksigner not found at $APKSIGNER (set ANDROID_BUILD_TOOLS)"

# The badging line also carries platformBuildVersionName/Code, so match the
# first occurrence of each field rather than letting a greedy regex run to the
# last one.
badging_field() {
    "$AAPT2" dump badging "$1" 2>/dev/null | grep -m1 '^package:' \
        | grep -o "$2='[^']*'" | head -1 | sed "s/^$2='//; s/'$//"
}

CANDIDATE_ID=$(badging_field "$CANDIDATE" name)
CANDIDATE_VC=$(badging_field "$CANDIDATE" versionCode)
[[ -n "$CANDIDATE_ID" ]] || die "could not read the applicationId from $CANDIDATE"

if [[ "$CANDIDATE_ID" != "$APP_ID" ]]; then
    die "refusing to run: $CANDIDATE has applicationId '$CANDIDATE_ID', but this script installs over the production app '$APP_ID'. Build the prod release variant, not a dev/debug one."
fi
log "Candidate: $(basename "$CANDIDATE") ($CANDIDATE_ID, versionCode $CANDIDATE_VC)"

# --- preflight: the device and a way back -----------------------------------

if [[ -n "${SMOKE_SERIAL:-}" ]]; then
    SERIAL="$SMOKE_SERIAL"
    log "Connecting to $SERIAL"
    timeout "$ADB_TIMEOUT" adb connect "$SERIAL" >/dev/null 2>&1
    STATE=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" get-state 2>/dev/null | tr -d '\r' || true)
    [[ "$STATE" == "device" ]] || die "device $SERIAL unreachable (get-state='$STATE')"
else
    SERIAL=$(wallpanel_resolve_adb_serial) || die "could not reach the tablet at $WALLPANEL_TABLET_IP -- see the [adb-device] messages above"
    log "Connected to $SERIAL"
fi

INSTALLED_VC=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys package "$APP_ID" 2>/dev/null \
    | sed -n 's/.*versionCode=\([0-9]\+\).*/\1/p' | head -1)
[[ -n "$INSTALLED_VC" ]] || die "$APP_ID does not appear to be installed on $SERIAL -- refusing to run, since there would be nothing to restore"
log "Installed on the panel: $APP_ID versionCode $INSTALLED_VC"

if [[ "$CANDIDATE_VC" -lt "$INSTALLED_VC" ]]; then
    die "refusing to run: candidate versionCode $CANDIDATE_VC is older than the installed $INSTALLED_VC. A downgrade needs a deliberate 'adb install -r -d', which is the rollback path, not a test."
fi

# Match the restore APK by versionCode read from the APK itself -- the
# versionName has spaces ("0.12.0 Build 0-kmb.2") while filenames use dashes,
# so deriving the filename from the version string would be fragile.
shopt -s nullglob
for apk in "$RELEASE_DIR"/*.apk; do
    vc=$(badging_field "$apk" versionCode)
    id=$(badging_field "$apk" name)
    if [[ "$vc" == "$INSTALLED_VC" && "$id" == "$APP_ID" ]]; then
        RESTORE_APK="$apk"
        # Prefer the arm64 split, which is what this tablet actually runs.
        [[ "$apk" == *arm64* ]] && break
    fi
done
shopt -u nullglob

if [[ -z "$RESTORE_APK" ]]; then
    die "refusing to run: no APK in $RELEASE_DIR matches the installed versionCode $INSTALLED_VC, so there would be no way back if the test fails. Put the currently-installed release there first."
fi
log "Restore point: $(basename "$RESTORE_APK")"

signer_digest() {
    "$APKSIGNER" verify --print-certs "$1" 2>/dev/null \
        | sed -n 's/.*certificate SHA-256 digest: *\([0-9a-f]*\).*/\1/p' | head -1
}

CANDIDATE_SIG=$(signer_digest "$CANDIDATE")
RESTORE_SIG=$(signer_digest "$RESTORE_APK")
[[ -n "$CANDIDATE_SIG" ]] || die "refusing to run: $CANDIDATE is not signed (apksigner found no certificate). An install over $APP_ID would be rejected. Sign the arm64-v8a split with the release key first -- see CLAUDE.md 'Release signing'."
[[ -n "$RESTORE_SIG" ]] || die "could not read the signer certificate from the restore APK $RESTORE_APK"
if [[ "$CANDIDATE_SIG" != "$RESTORE_SIG" ]]; then
    die "refusing to run: $CANDIDATE is signed with a different key than the app on the panel (candidate $CANDIDATE_SIG vs installed $RESTORE_SIG). Android would reject both the install and the rollback. Sign it with the release key -- see CLAUDE.md 'Release signing'."
fi
log "Signature matches the installed app ($CANDIDATE_SIG)"

# --- install the candidate ---------------------------------------------------

# Chromium won't activate a renderer's service bindings for an app that isn't
# visible, so a display that sleeps during the idle wait makes the renderer
# vanish and the test unrunnable. Hold the display on for the duration and put
# the setting back on exit. This does not weaken the idle wait: it injects no
# input, so the app's inactivity timer still fires and the screensaver still
# mounts.
PREV_STAYON=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')
[[ "$PREV_STAYON" =~ ^[0-9]+$ ]] || PREV_STAYON=""
timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell svc power stayon true >/dev/null 2>&1
timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

log "Installing the candidate over $APP_ID"
if ! timeout 300 adb -s "$SERIAL" install -r "$CANDIDATE" >/dev/null 2>&1; then
    die "could not install $CANDIDATE over $APP_ID -- the panel is untouched, still on versionCode $INSTALLED_VC"
fi
INSTALLED=1

if [[ -z "$(launch_and_check)" ]]; then
    fail_reason "candidate installed but $APP_ID/$LAUNCH_ACTIVITY never took window focus"
fi

get_pid() {
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

# Parses `dumpsys activity services` for the ServiceRecord owned by our app
# component (xyz.wallpanel.app.kmb/org.chromium.content.app.SandboxedProcessServiceN:M)
# and returns the renderer's own pid from the following app=ProcessRecord{...} line.
# This is the deterministic form: `am crash <pid>` on this targets the renderer
# specifically, unlike `am crash <package>`, which can non-deterministically hit
# either the main process or an associated renderer depending on what's alive.
get_renderer_pid() {
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys activity services 2>/dev/null \
        | awk -v pkg="$APP_ID" '
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
        | grep -i "mCurrentFocus" | grep -F "$APP_ID/$LAUNCH_ACTIVITY")
    if [[ -z "$hit" ]]; then
        timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        sleep 2
        hit=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys window 2>/dev/null \
            | grep -i "mCurrentFocus" | grep -F "$APP_ID/$LAUNCH_ACTIVITY")
    fi
    printf '%s' "$hit"
}

BASELINE_PID=$(get_pid)
if [[ -z "$BASELINE_PID" ]]; then
    fail_reason "$APP_ID is not running after install -- cannot crash a renderer it doesn't have"
else
    log "Production app running as pid $BASELINE_PID"
fi

# --- crash cycles ------------------------------------------------------------

if [[ ${#FAILURES[@]} -eq 0 ]]; then
for cycle in $(seq 1 "$CYCLES"); do
    log "--- cycle $cycle/$CYCLES ---"
    log "Waiting ${IDLE_WAIT_SECONDS}s untouched so the screensaver's inactivity timeout can fire"
    sleep "$IDLE_WAIT_SECONDS"

    RENDERER_PID=$(get_renderer_pid)
    if [[ -z "$RENDERER_PID" ]]; then
        fail_reason "[cycle $cycle] no renderer process found for $APP_ID (has a WebView ever loaded content?)"
        break
    fi
    log "Found renderer pid $RENDERER_PID (ServiceRecord for $APP_ID)"

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
        fail_reason "[cycle $cycle] main activity ($APP_ID/$LAUNCH_ACTIVITY) does not have window focus after renderer crash"
        break
    fi

    NEW_RENDERER_PID=$(get_renderer_pid)
    if [[ -z "$NEW_RENDERER_PID" || "$NEW_RENDERER_PID" == "$RENDERER_PID" ]]; then
        fail_reason "[cycle $cycle] no fresh renderer process appeared after the crash (WebView was not rebuilt)"
        break
    fi

    log "Cycle $cycle OK: app pid unchanged ($APP_PID_AFTER), focus held, new renderer pid $NEW_RENDERER_PID"
done
fi

echo
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    # Leave the candidate installed and confirm the panel is actually showing
    # the dashboard: focus alone can't tell a live WebView from a dead one, so
    # require a bound renderer too.
    FINAL_FOCUS=$(launch_and_check)
    FINAL_RENDERER=$(get_renderer_pid)
    if [[ -n "$FINAL_FOCUS" && -n "$FINAL_RENDERER" ]]; then
        PASSED=1
        echo "RESULT: PASS"
        echo "$APP_ID (versionCode $CANDIDATE_VC) survived $CYCLES consecutive renderer crashes with window focus held and a fresh renderer each time."
        echo "The candidate is left installed and foregrounded, showing the dashboard (renderer pid $FINAL_RENDERER)."
        exit 0
    fi
    fail_reason "cycles passed but the panel is not left showing the dashboard (focus='${FINAL_FOCUS:-none}', renderer='${FINAL_RENDERER:-none}')"
fi

echo "RESULT: FAIL"
printf ' - %s\n' "${FAILURES[@]}"
echo "Restoring the previous release (versionCode $INSTALLED_VC) -- see [renderer-smoke] messages for the outcome."
exit 1
