#!/bin/bash
# Continuous logcat capture for the wall panel.
#
# Usage: ./logcat-capture.sh            # run the supervisor loop (blocks)
#        ./logcat-capture.sh --status   # report whether a capture is running
#
# Safe to invoke repeatedly: a PID file guards against a second copy, so a
# start hook can fire this unconditionally without stacking duplicate captures
# (two `adb logcat` readers on one device double the write rate and interleave
# into the same log).
#
# The tablet's address is resolved through scripts/adb-device.sh rather than a
# hardcoded port, because a tablet reboot drops the `adb tcpip 5555` pin and
# Android re-assigns wireless debugging to a random port.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./scripts/adb-device.sh
source "$SCRIPT_DIR/scripts/adb-device.sh"

LOGDIR="${WALLPANEL_LOGDIR:-$SCRIPT_DIR/logs}"
PIDFILE="$LOGDIR/capture.pid"
mkdir -p "$LOGDIR"

# True if a live capture already owns the PID file. Uses /proc rather than ps,
# which isn't installed in this container.
capture_running() {
    local pid
    [[ -f "$PIDFILE" ]] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/proc/$pid" ]] || return 1
    # Guard against PID reuse by a process that isn't ours.
    grep -q "logcat-capture" "/proc/$pid/cmdline" 2>/dev/null
}

if [[ "${1:-}" == "--status" ]]; then
    if capture_running; then
        echo "capture running (pid $(cat "$PIDFILE")), newest log: $(ls -t "$LOGDIR"/wallpanel-*.log 2>/dev/null | head -1)"
        exit 0
    fi
    echo "capture NOT running"
    exit 1
fi

if capture_running; then
    echo "$(date -Is) capture already running (pid $(cat "$PIDFILE")), not starting a second one" >> "$LOGDIR/capture-supervisor.log"
    exit 0
fi

echo $$ > "$PIDFILE"
LOGCAT_PID=""
# Kill the adb reader too. Killing only the supervisor leaves an orphaned
# `adb logcat` still appending to its file; the next start then runs a second
# reader against the same device, doubling the write rate and splitting the
# record across two files.
cleanup() {
    [[ -n "$LOGCAT_PID" ]] && kill "$LOGCAT_PID" 2>/dev/null
    rm -f "$PIDFILE"
}
# A signal trap that only cleans up would let bash resume the loop afterwards:
# the supervisor would survive its own SIGTERM having already deleted its PID
# file, so the next start would see no owner and run a second supervisor. Exit
# explicitly.
on_signal() {
    cleanup
    exit 143
}
trap cleanup EXIT
trap on_signal INT TERM

echo "$(date -Is) capture supervisor started (pid $$)" >> "$LOGDIR/capture-supervisor.log"

while true; do
  DEV=$(wallpanel_resolve_adb_serial 2>>"$LOGDIR/capture-supervisor.log")
  if [ -z "$DEV" ]; then
    echo "$(date -Is) could not reach tablet at ${WALLPANEL_TABLET_IP}, retrying" >> "$LOGDIR/capture-supervisor.log"
    sleep 30
    continue
  fi
  STAMP=$(date +%Y%m%d-%H%M%S)
  adb -s "$DEV" logcat -b crash,main,system -v threadtime \
    Camera3-OutputStream:S BufferQueueProducer:S BufferQueueDebug:S \
    UserExperience:S AppOps:S ProcessStats:S SurfaceFlinger:S \
    GoogleInputMethodService:S DropBoxManagerService:S \
    >> "$LOGDIR/wallpanel-$STAMP.log" 2>> "$LOGDIR/capture-supervisor.log" &
  LOGCAT_PID=$!
  wait "$LOGCAT_PID"
  echo "$(date -Is) logcat exited rc=$?, retrying" >> "$LOGDIR/capture-supervisor.log"
  LOGCAT_PID=""
  sleep 30
done
