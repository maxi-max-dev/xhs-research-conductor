#!/usr/bin/env zsh
# Updated 2026-05-06 for BlueStacks: BlueStacks ADB has known issue with `pm path`
# (returns "error: closed"). Use `dumpsys package` instead — that works reliably.
# Removed `set -e` so flaky ADB calls degrade gracefully without killing the script.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
UDID="${ANDROID_SERIAL:-$("$SCRIPT_DIR/device-connect.sh")}"
OUT="${1:-/tmp/xhs_status.png}"

echo "Device: $UDID"

# BlueStacks-friendly: dumpsys package works (pm path doesn't).
dump_out="$("$ADB" -s "$UDID" shell dumpsys package com.xingin.xhs 2>&1 || true)"
xhs_version="$(echo "$dump_out" | grep -m1 'versionName=' | awk -F= '{print $2}' | tr -d '\r' | xargs)"

if [ -z "$xhs_version" ]; then
  # Fallback: check foreground (works even when dumpsys flaky)
  focus_check="$("$ADB" -s "$UDID" shell dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | head -3 || true)"
  if echo "$focus_check" | grep -q "com.xingin.xhs"; then
    echo "XHS installed (detected via foreground focus, version unknown)"
  else
    echo "XHS NOT detected. Verify visually in BlueStacks. ADB may also be flaky — retry."
    exit 2
  fi
else
  echo "XHS installed: version $xhs_version"
fi

# Foreground app (always useful context)
focus="$("$ADB" -s "$UDID" shell dumpsys window 2>/dev/null | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r' || true)"
echo "Focus: ${focus:-unknown}"

# Appium helper detection — via dumpsys
echo "Appium helper packages:"
found_helper=0
for pkg in io.appium.settings io.appium.uiautomator2.server io.appium.uiautomator2.server.test io.appium.unlock; do
  if "$ADB" -s "$UDID" shell dumpsys package "$pkg" 2>/dev/null | grep -q 'versionName='; then
    echo "  $pkg"
    found_helper=1
  fi
done
if [ "$found_helper" = "0" ]; then
  echo "  (none)"
fi

# Screenshot
"$ADB" -s "$UDID" exec-out screencap -p > "$OUT" 2>/dev/null && echo "Screenshot: $OUT" || echo "Screenshot failed (ADB exec-out unstable, retry)"
