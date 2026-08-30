#!/usr/bin/env bash
# Shared helper: resolve a working adb serial for the WallPanel tablet.
#
# Android 11+ wireless debugging assigns a random port on every boot; the
# `adb tcpip 5555` pin used by these scripts is lost across a tablet reboot.
# Source this file, then call wallpanel_resolve_adb_serial, which:
#   1. tries the pinned <ip>:5555 first (the fast path, works until a reboot)
#   2. if that's unreachable, discovers the tablet's current wireless-debugging
#      port via `adb mdns services` and connects to it
#   3. re-pins port 5555 on the device (`adb tcpip 5555`) and reconnects to
#      <ip>:5555, so the fast path works again next time
#   4. fails with a clear message on stderr and a non-zero return if none of
#      that gets a device into "device" state -- callers must not fall through
#      to a false success.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/adb-device.sh"
#   SERIAL=$(wallpanel_resolve_adb_serial) || exit 1
#
# The tablet's IP is read from $WALLPANEL_TABLET_IP, default 192.168.0.52 --
# not hardcoded, so a different device/subnet doesn't require editing every
# script. This file only defines functions/variables; it does not set -e/-u
# itself and inherits whatever the sourcing script has set.

WALLPANEL_TABLET_IP="${WALLPANEL_TABLET_IP:-192.168.0.52}"
WALLPANEL_ADB_TIMEOUT="${WALLPANEL_ADB_TIMEOUT:-15}"

# Prints a working "ip:port" serial to stdout and returns 0 on success.
# Prints nothing to stdout and returns 1 on failure; diagnostics go to stderr
# so callers can pass them straight through to their own log function.
wallpanel_resolve_adb_serial() {
    local ip="${1:-$WALLPANEL_TABLET_IP}"
    local t="$WALLPANEL_ADB_TIMEOUT"
    local pinned="$ip:5555"

    timeout "$t" adb connect "$pinned" >/dev/null 2>&1
    if [[ "$(timeout "$t" adb -s "$pinned" get-state 2>/dev/null | tr -d '\r')" == "device" ]]; then
        echo "$pinned"
        return 0
    fi

    echo "[adb-device] $pinned unreachable -- discovering the tablet's current wireless-debugging port via mdns" >&2
    local mdns discovered_port discovered
    mdns=$(timeout "$t" adb mdns services 2>/dev/null)
    discovered_port=$(printf '%s\n' "$mdns" | grep -F "${ip}:" | grep -v ":5555\b" | head -1 | sed -n "s/.*${ip//./\\.}:\\([0-9]\\+\\).*/\\1/p")

    if [[ -z "$discovered_port" ]]; then
        echo "[adb-device] FAIL: no mdns service found for $ip. 'adb mdns services' returned:" >&2
        printf '%s\n' "$mdns" | sed 's/^/[adb-device]   /' >&2
        echo "[adb-device] Either the tablet isn't advertising (open Settings > Developer options > Wireless debugging on the tablet to force it to broadcast), or this container's network can't receive mDNS multicast from the tablet's subnet. Not falling through to a false success." >&2
        return 1
    fi

    discovered="$ip:$discovered_port"
    echo "[adb-device] found $discovered via mdns, connecting and re-pinning port 5555" >&2
    timeout "$t" adb connect "$discovered" >/dev/null 2>&1
    if [[ "$(timeout "$t" adb -s "$discovered" get-state 2>/dev/null | tr -d '\r')" != "device" ]]; then
        echo "[adb-device] FAIL: connected to $discovered but its state is not 'device' -- giving up" >&2
        return 1
    fi

    timeout "$t" adb -s "$discovered" tcpip 5555 >/dev/null 2>&1
    sleep 2
    timeout "$t" adb connect "$pinned" >/dev/null 2>&1
    if [[ "$(timeout "$t" adb -s "$pinned" get-state 2>/dev/null | tr -d '\r')" == "device" ]]; then
        echo "$pinned"
        return 0
    fi

    echo "[adb-device] FAIL: re-pinned port 5555 on the device but $pinned did not come back reachable -- it may still only be reachable at $discovered" >&2
    return 1
}
