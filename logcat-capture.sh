#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./scripts/adb-device.sh
source "$SCRIPT_DIR/scripts/adb-device.sh"

LOGDIR=/projects/wallpanel/logs
mkdir -p "$LOGDIR"
while true; do
  DEV=$(wallpanel_resolve_adb_serial 2>>"$LOGDIR/capture-supervisor.log")
  if [ -z "$DEV" ]; then
    echo "$(date -Is) could not reach tablet at ${WALLPANEL_TABLET_IP} (pinned port and mdns discovery both failed), retrying" >> "$LOGDIR/capture-supervisor.log"
    sleep 30
    continue
  fi
  STAMP=$(date +%Y%m%d-%H%M%S)
  adb -s "$DEV" logcat -b crash,main,system -v threadtime \
    Camera3-OutputStream:S BufferQueueProducer:S BufferQueueDebug:S \
    UserExperience:S AppOps:S ProcessStats:S SurfaceFlinger:S \
    GoogleInputMethodService:S DropBoxManagerService:S \
    >> "$LOGDIR/wallpanel-$STAMP.log" 2>> "$LOGDIR/capture-supervisor.log"
  echo "$(date -Is) logcat exited rc=$?, retrying" >> "$LOGDIR/capture-supervisor.log"
  sleep 30
done
