#!/usr/bin/env bash
# On-device smoke test for a WallPanel dev-flavoured debug APK.
#
# Usage: scripts/smoke-device.sh <path-to-apk>
#
# Installs the APK (refusing anything but the dev application ID so this can
# never touch the two production installs), launches it, watches it for
# crashes/focus-loss/service-death, throws a monkey at it, checks again, then
# always uninstalls on exit. Prints RESULT: PASS or RESULT: FAIL and exits
# non-zero on failure. Fails closed (clear message, no hang, no false PASS)
# if the device is unreachable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./adb-device.sh
source "$SCRIPT_DIR/adb-device.sh"

DEV_APP_ID="xyz.wallpanel.app.kmb.dev"
SERVICE_CLASS="xyz.wallpanel.app.network.WallPanelService"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-/root/.android-sdk/build-tools/34.0.0}"
AAPT2="$BUILD_TOOLS/aapt2"
ADB_TIMEOUT=15
WAIT_SECONDS=60
POLL_INTERVAL=5
MONKEY_EVENTS=500
MONKEY_SEED=12345

FAILURES=()
INSTALLED=0
PKG=""

log() { echo "[smoke] $*" >&2; }
fail_reason() { FAILURES+=("$1"); log "FAIL: $1"; }

cleanup() {
    if [[ "$INSTALLED" -eq 1 && -n "$PKG" ]]; then
        log "Uninstalling $PKG"
        timeout "$ADB_TIMEOUT" adb -s "$SERIAL" uninstall "$PKG" >/dev/null 2>&1 \
            || log "warning: uninstall of $PKG failed or app was already gone"
    fi
}
trap cleanup EXIT

die() {
    log "FAIL: $1"
    echo "RESULT: FAIL"
    exit 1
}

APK="${1:-}"
[[ -n "$APK" ]] || die "usage: smoke-device.sh <path-to-apk>"
[[ -f "$APK" ]] || die "APK not found: $APK"
[[ -x "$AAPT2" ]] || die "aapt2 not found or not executable at $AAPT2"

# --- device reachability: fail closed, never hang ---
# SMOKE_SERIAL is a raw serial override (used to test the unreachable-device
# path deterministically); anything else goes through the resilient resolver,
# which falls back to mdns discovery + re-pinning port 5555 if the tablet
# rebooted and lost its tcpip pin.
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

# --- parse applicationId from the APK itself, never trust the filename ---
BADGING=$("$AAPT2" dump badging "$APK" 2>/dev/null) || die "aapt2 dump badging failed for $APK"
APK_PKG=$(printf '%s\n' "$BADGING" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
[[ -n "$APK_PKG" ]] || die "could not parse applicationId out of $APK"
if [[ "$APK_PKG" != "$DEV_APP_ID" ]]; then
    die "refusing to run: APK applicationId is '$APK_PKG', expected exactly '$DEV_APP_ID' -- this script will not touch anything but the dev app"
fi
PKG="$APK_PKG"

LAUNCH_ACTIVITY=$(printf '%s\n' "$BADGING" | sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p")
[[ -n "$LAUNCH_ACTIVITY" ]] || die "could not parse launchable-activity out of $APK"

# --- install ---
log "Installing $APK as $PKG"
if ! timeout 90 adb -s "$SERIAL" install -r -d "$APK" >/tmp/smoke-install.log 2>&1 \
    || grep -qi "Failure" /tmp/smoke-install.log; then
    cat /tmp/smoke-install.log >&2
    die "adb install failed"
fi
INSTALLED=1

get_pid() {
    # One retry to absorb a single flaky adb round-trip; a real process death
    # is still empty on the second try.
    local p
    p=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
    if [[ -z "$p" ]]; then
        sleep 1
        p=$(timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
    fi
    printf '%s' "$p"
}

device_time() {
    # Must be a single quoted argument for the REMOTE shell -- an unquoted local
    # invocation lets adb rejoin "+%m-%d" and "%H:%M:%S.000" as separate argv
    # entries, so the device only sees "+%m-%d" and date silently drops the rest.
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell "date '+%m-%d %H:%M:%S.000'" 2>/dev/null | tr -d '\r'
}

check_crash_buffer() {
    local since="$1"
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" logcat -b crash -t "$since" 2>/dev/null \
        | grep -E "FATAL EXCEPTION|Abort message"
}

check_window_focus() {
    # The device's screen-timeout can put it back to sleep during the ~60s wait,
    # at which point mCurrentFocus reports null regardless of what's actually in
    # front -- wake it immediately before reading focus state, every time.
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    sleep 1
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys window 2>/dev/null \
        | grep -i "mCurrentFocus" | grep -F "$PKG/$LAUNCH_ACTIVITY"
}

check_service_running() {
    timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell dumpsys activity services "$PKG" 2>/dev/null \
        | grep -F "$SERVICE_CLASS"
}

# AppExceptionHandler intercepts uncaught exceptions and relaunches the app via
# an alarm rather than letting the default handler write "FATAL EXCEPTION" to
# the crash buffer -- so a real crash can leave the crash buffer silent and the
# process "alive" (just a different one). Treat any pid change as a FAIL.
run_checks() {
    local phase="$1" launch_time="$2" baseline_pid="$3"
    local ok=1

    local cur_pid
    cur_pid=$(get_pid)
    if [[ -z "$cur_pid" ]]; then
        fail_reason "[$phase] process not alive (pidof $PKG empty)"
        ok=0
    elif [[ "$cur_pid" != "$baseline_pid" ]]; then
        fail_reason "[$phase] process pid changed ($baseline_pid -> $cur_pid): app restarted, likely after a crash"
        ok=0
    fi

    local crash_hits
    crash_hits=$(check_crash_buffer "$launch_time")
    if [[ -n "$crash_hits" ]]; then
        fail_reason "[$phase] crash buffer shows FATAL EXCEPTION or Abort message since launch"
        ok=0
    fi

    if [[ -z "$(check_window_focus)" ]]; then
        fail_reason "[$phase] expected activity ($PKG/$LAUNCH_ACTIVITY) does not have window focus"
        ok=0
    fi

    if [[ -z "$(check_service_running)" ]]; then
        fail_reason "[$phase] $SERVICE_CLASS is not running"
        ok=0
    fi

    [[ $ok -eq 1 ]]
}

# --- wake the device: an asleep screen never grants window focus to the launched
# activity, which would otherwise produce a false FAIL unrelated to app health ---
log "Waking device"
timeout "$ADB_TIMEOUT" adb -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

# --- launch ---
LAUNCH_TIME=$(device_time)
[[ -n "$LAUNCH_TIME" ]] || die "could not read device time before launch"
log "Launching $PKG/$LAUNCH_ACTIVITY at device time $LAUNCH_TIME"
timeout 30 adb -s "$SERIAL" shell am start -W -n "$PKG/$LAUNCH_ACTIVITY" >/tmp/smoke-launch.log 2>&1
LAUNCH_RC=$?
cat /tmp/smoke-launch.log >&2
if [[ $LAUNCH_RC -ne 0 ]] || grep -qiE "^Error|does not exist|Exception" /tmp/smoke-launch.log; then
    fail_reason "am start failed or reported an error launching $PKG/$LAUNCH_ACTIVITY"
fi

sleep 3
BASELINE_PID=$(get_pid)
if [[ -z "$BASELINE_PID" ]]; then
    fail_reason "[startup] process did not come up after launch"
else
    log "Waiting ${WAIT_SECONDS}s (baseline pid=$BASELINE_PID)..."
    elapsed=3
    while [[ $elapsed -lt $WAIT_SECONDS ]]; do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        p=$(get_pid)
        if [[ -z "$p" || "$p" != "$BASELINE_PID" ]]; then
            log "process state changed during wait (pid now '${p:-<none>}'), ending wait early"
            break
        fi
    done

    run_checks "post-launch" "$LAUNCH_TIME" "$BASELINE_PID" || true

    # --- monkey ---
    log "Running monkey against $PKG (seed=$MONKEY_SEED, events=$MONKEY_EVENTS)"
    timeout 90 adb -s "$SERIAL" shell monkey -p "$PKG" -s "$MONKEY_SEED" --pct-syskeys 0 "$MONKEY_EVENTS" \
        >/tmp/smoke-monkey.log 2>&1
    MONKEY_RC=$?
    cat /tmp/smoke-monkey.log >&2
    if [[ $MONKEY_RC -ne 0 ]] || grep -qiE "CRASH|ANR|monkey aborted" /tmp/smoke-monkey.log; then
        fail_reason "monkey reported a crash/ANR/abort (exit=$MONKEY_RC)"
    fi

    sleep 2
    run_checks "post-monkey" "$LAUNCH_TIME" "$BASELINE_PID" || true
fi

echo
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    echo "RESULT: PASS"
    echo "$PKG launched cleanly, held window focus, kept $SERVICE_CLASS running, and survived a $MONKEY_EVENTS-event monkey run with no crash/ANR/restart."
    exit 0
else
    echo "RESULT: FAIL"
    printf ' - %s\n' "${FAILURES[@]}"
    exit 1
fi
