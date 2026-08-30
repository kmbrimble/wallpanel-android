#!/usr/bin/env bash
# Shared helper: resolve a working adb serial for the WallPanel tablet.
#
# Android 11+ wireless debugging assigns a random port on every boot; the
# `adb tcpip 5555` pin used by these scripts is lost across a tablet reboot.
# Source this file, then call wallpanel_resolve_adb_serial, which:
#   1. tries the pinned <ip>:5555 first (the fast path, works until a reboot)
#   2. if that's unreachable, port-scans the tablet's ephemeral range to find
#      the port wireless debugging landed on, and connects to it
#   3. re-pins port 5555 on the device (`adb tcpip 5555`) and reconnects to
#      <ip>:5555, so the fast path works again next time
#   4. fails with a clear message on stderr and a non-zero return if none of
#      that gets a device into "device" state -- callers must not fall through
#      to a false success.
#
# Why a port scan and not `adb mdns services`: mdns discovery relies on
# multicast, which does not cross this container's Docker bridge, so it always
# returns zero services here. It failed closed (correct) but could never
# succeed, which made it dead code that read as functional. Do not reinstate it.
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

# Android picks the wireless-debugging port from the ephemeral range (Linux
# default 32768-60999); we start a little below it as cheap insurance. Scanning
# the whole 1024-65535 doubles the work for no observed benefit.
WALLPANEL_SCAN_FROM="${WALLPANEL_SCAN_FROM:-30000}"
WALLPANEL_SCAN_TO="${WALLPANEL_SCAN_TO:-60999}"
# Worst case (every port silently dropped) is
# (60999-30000) * 0.3s / 200 ~= 47s, so the 90s cap holds with margin and this
# can never hang a capture loop.
WALLPANEL_SCAN_PARALLEL="${WALLPANEL_SCAN_PARALLEL:-200}"
WALLPANEL_SCAN_PROBE_TIMEOUT="${WALLPANEL_SCAN_PROBE_TIMEOUT:-0.3}"
WALLPANEL_SCAN_MAX_SECONDS="${WALLPANEL_SCAN_MAX_SECONDS:-90}"
# An open port is not necessarily adbd (the app's own HTTP server may be up), so
# candidates are verified serially. In practice there are only one or two.
WALLPANEL_SCAN_MAX_CANDIDATES="${WALLPANEL_SCAN_MAX_CANDIDATES:-10}"

# Probes one TCP port using bash's /dev/tcp, so this needs no nc/nmap/ping --
# none of which are installed in this container. Echoes the port if open.
wallpanel_probe_port() {
    timeout "${WALLPANEL_SCAN_PROBE_TIMEOUT:-0.3}" \
        bash -c ":< /dev/tcp/$1/$2" 2>/dev/null && echo "$2"
}
export -f wallpanel_probe_port

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

    echo "[adb-device] $pinned unreachable -- port-scanning $ip:$WALLPANEL_SCAN_FROM-$WALLPANEL_SCAN_TO for the current wireless-debugging port" >&2

    local scan_start=$SECONDS open_ports
    open_ports=$(seq "$WALLPANEL_SCAN_FROM" "$WALLPANEL_SCAN_TO" \
        | timeout "$WALLPANEL_SCAN_MAX_SECONDS" \
              xargs -P "$WALLPANEL_SCAN_PARALLEL" -I{} \
              bash -c 'wallpanel_probe_port "$1" "$2"' _ "$ip" {} \
        | grep -vx 5555 | sort -n | head -n "$WALLPANEL_SCAN_MAX_CANDIDATES")
    local scan_seconds=$((SECONDS - scan_start))

    if [[ -z "$open_ports" ]]; then
        echo "[adb-device] FAIL: scanned $ip:$WALLPANEL_SCAN_FROM-$WALLPANEL_SCAN_TO in ${scan_seconds}s and found no open port. Either the tablet is off the network, or wireless debugging is disabled (open Settings > Developer options > Wireless debugging on the tablet to re-enable it). Not falling through to a false success." >&2
        return 1
    fi

    echo "[adb-device] scan finished in ${scan_seconds}s, candidate port(s): $(echo $open_ports | tr '\n' ' ')" >&2

    # An open port isn't necessarily adbd, so try each until one reports a
    # device. Serially: the adb server serialises connects anyway, and failed
    # candidates must be disconnected so they don't linger in `adb devices`.
    local port discovered=""
    for port in $open_ports; do
        local candidate="$ip:$port"
        timeout "$t" adb connect "$candidate" >/dev/null 2>&1
        if [[ "$(timeout "$t" adb -s "$candidate" get-state 2>/dev/null | tr -d '\r')" == "device" ]]; then
            discovered="$candidate"
            break
        fi
        timeout "$t" adb disconnect "$candidate" >/dev/null 2>&1
    done

    if [[ -z "$discovered" ]]; then
        echo "[adb-device] FAIL: none of the open ports on $ip ($(echo $open_ports | tr '\n' ' ')) is an adb daemon in 'device' state. If the tablet is prompting to allow USB debugging, accept it and retry. Not falling through to a false success." >&2
        return 1
    fi

    echo "[adb-device] found $discovered by port scan, re-pinning port 5555" >&2
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
