#!/usr/bin/env zsh
# xhs-cleanup.sh — Force-stop XHS app and Chrome to leave a clean device state.
#
# Why: leftover XHS/Chrome state caused two recurring bugs across tasks:
#   1. Scan ends, XHS stays foreground → next search hits previous result page.
#   2. xhs-open-link redirects through Chrome → tabs/intents accumulate; mobile
#      taps land on a stale gateway page from a prior link.
#
# Usage:
#   xhs-cleanup.sh             # close both XHS and Chrome (default)
#   xhs-cleanup.sh --xhs       # close XHS only
#   xhs-cleanup.sh --browser   # close Chrome only
#
# Idempotent. Exits 0 even when apps aren't running or ADB is down (so callers
# can wrap with `|| true` without masking real errors).

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"

CLOSE_XHS=1
CLOSE_BROWSER=1
while [ $# -gt 0 ]; do
  case "$1" in
    --xhs)     CLOSE_XHS=1; CLOSE_BROWSER=0; shift ;;
    --browser) CLOSE_XHS=0; CLOSE_BROWSER=1; shift ;;
    --all)     CLOSE_XHS=1; CLOSE_BROWSER=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "[xhs-cleanup] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[xhs-cleanup] $*" >&2; }

if [ -x "$SCRIPT_DIR/device-connect.sh" ]; then
  UDID="$("$SCRIPT_DIR/device-connect.sh" 2>/dev/null || true)"
else
  UDID="${ANDROID_SERIAL:-127.0.0.1:5555}"
fi
if [ -z "$UDID" ]; then
  log "no device, skipping cleanup"
  exit 0
fi

if [ "$CLOSE_XHS" = "1" ]; then
  if "$ADB" -s "$UDID" shell am force-stop com.xingin.xhs 2>/dev/null; then
    log "closed XHS (com.xingin.xhs)"
  fi
fi

if [ "$CLOSE_BROWSER" = "1" ]; then
  if "$ADB" -s "$UDID" shell am force-stop com.android.chrome 2>/dev/null; then
    log "closed Chrome (com.android.chrome)"
  fi
fi

"$ADB" -s "$UDID" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true

exit 0
