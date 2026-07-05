#!/bin/sh
# xhs-geom.sh — source this AFTER $ADB and $UDID are set.
# All original tap/swipe coords were tuned on a 1440x2560 portrait screen.
# gx/gy scale a reference coord to the ACTUAL device resolution, so any
# emulator size works (v0.16.3). On 1440x2560 they are exact identity.
# If `wm size` fails, falls back to the reference (= old behavior).
_XHS_SZ=$("$ADB" -s "$UDID" shell wm size 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | tail -1)
SCREEN_W="${_XHS_SZ%x*}"
SCREEN_H="${_XHS_SZ#*x}"
case "${SCREEN_W:-}" in ''|*[!0-9]*) SCREEN_W=1440 ;; esac
case "${SCREEN_H:-}" in ''|*[!0-9]*) SCREEN_H=2560 ;; esac
gx() { echo $(( $1 * SCREEN_W / 1440 )); }
gy() { echo $(( $1 * SCREEN_H / 2560 )); }
