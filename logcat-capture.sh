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
SUPLOG="$LOGDIR/capture-supervisor.log"
mkdir -p "$LOGDIR"

# A live supervisor proves only that the retry loop is alive, not that anything
# is being captured: while the tablet was offline for two days the loop retried
# every 30s and --status still said "capture running". Treat the capture as
# healthy only if the newest log has actually grown recently.
STALE_AFTER_SECONDS="${WALLPANEL_CAPTURE_STALE_SECONDS:-180}"

# That same two-day retry loop grew capture-supervisor.log to 2MB of identical
# "could not reach tablet" lines, so cap it. Trimmed in place with `cat >` so the
# inode survives -- the running `adb logcat` holds this file open on stderr, and
# an mv would send its writes to an orphaned inode.
SUPLOG_MAX_BYTES="${WALLPANEL_SUPLOG_MAX_BYTES:-262144}"
sup_log() {
    printf '%s %s\n' "$(date -Is)" "$*" >> "$SUPLOG"
    local size
    size=$(stat -c%s "$SUPLOG" 2>/dev/null || echo 0)
    if (( size > SUPLOG_MAX_BYTES )); then
        tail -c $(( SUPLOG_MAX_BYTES / 2 )) "$SUPLOG" > "$SUPLOG.tmp" 2>/dev/null \
            && cat "$SUPLOG.tmp" > "$SUPLOG"
        rm -f "$SUPLOG.tmp"
    fi
}

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
    if ! capture_running; then
        echo "capture NOT running"
        exit 1
    fi
    NEWEST=$(ls -t "$LOGDIR"/wallpanel-*.log 2>/dev/null | head -1)
    if [[ -z "$NEWEST" ]]; then
        echo "capture STALLED: supervisor alive (pid $(cat "$PIDFILE")) but no capture log exists"
        exit 2
    fi
    AGE=$(( $(date +%s) - $(stat -c%Y "$NEWEST") ))
    if (( AGE <= STALE_AFTER_SECONDS )); then
        echo "capture running (pid $(cat "$PIDFILE")), newest log: $NEWEST, grew ${AGE}s ago"
        exit 0
    fi
    echo "capture STALLED: supervisor alive (pid $(cat "$PIDFILE")) but $NEWEST has not grown for ${AGE}s (tablet offline?)"
    exit 2
fi

if capture_running; then
    sup_log "capture already running (pid $(cat "$PIDFILE")), not starting a second one"
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

sup_log "capture supervisor started (pid $$)"

while true; do
  DEV=$(wallpanel_resolve_adb_serial 2>>"$SUPLOG")
  if [ -z "$DEV" ]; then
    sup_log "could not reach tablet at ${WALLPANEL_TABLET_IP}, retrying"
    sleep 30
    continue
  fi
  # Retention, run each time round the loop: cheap enough to not need cron, and
  # the loop is the only thing guaranteed to be alive whenever logs are growing.
  find "$LOGDIR" -maxdepth 1 -name 'wallpanel-*.log' -type f -mtime +7 -delete 2>/dev/null

  STAMP=$(date +%Y%m%d-%H%M%S)
  # Silence known per-frame noise only -- deliberately no `*:S` catch-all, so an
  # unexpected tag still lands in the log. The MediaTek camera HAL logs across a
  # dozen tags per frame; those dominate the volume and say nothing about how the
  # panel behaves. Tag names must match exactly or the filter silently does
  # nothing: the trailing colon in threadtime output is the format's delimiter and
  # the padding is to 8 characters, neither is part of the tag.
  adb -s "$DEV" logcat -b crash,main,system -v threadtime \
    Camera3-OutputStream:S BufferQueueProducer:S BufferQueueDebug:S \
    UserExperience:S AppOps:S ProcessStats:S SurfaceFlinger:S \
    GoogleInputMethodService:S DropBoxManagerService:S \
    AeAlgo:S GPUIMAGEROTATE:S S_Bokeh:S ifunc_cam_dmax:S cam_dfs:S \
    MtkCam/TPI_S_FB:S GPUAUX:S NormalPipe:S LMVDrv:S Hal3ARaw:S \
    MtkCam/fdNodeImp:S tsf_core:S CompositionEngine:S libPerfCtl:S \
    hwcomposer:S \
    >> "$LOGDIR/wallpanel-$STAMP.log" 2>> "$SUPLOG" &
  LOGCAT_PID=$!
  wait "$LOGCAT_PID"
  sup_log "logcat exited rc=$?, retrying"
  LOGCAT_PID=""
  sleep 30
done
