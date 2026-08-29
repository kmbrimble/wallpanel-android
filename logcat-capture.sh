#!/bin/bash
DEV=192.168.0.52:5555
LOGDIR=/projects/wallpanel/logs
mkdir -p "$LOGDIR"
while true; do
  adb connect "$DEV" >/dev/null 2>&1
  STAMP=$(date +%Y%m%d-%H%M%S)
  adb -s "$DEV" logcat -b crash,main,system -v threadtime \
    >> "$LOGDIR/wallpanel-$STAMP.log" 2>> "$LOGDIR/capture-supervisor.log"
  echo "$(date -Is) logcat exited rc=$?, retrying" >> "$LOGDIR/capture-supervisor.log"
  sleep 30
done
