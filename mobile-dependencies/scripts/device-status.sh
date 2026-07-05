#!/usr/bin/env zsh
# Rewritten 2026-05-06: BlueStacks Air for Mac.
# Filename kept as device-status.sh for backward compatibility.
set -euo pipefail

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
SCRIPT_DIR="${0:A:h}"

UDID="$("$SCRIPT_DIR/device-connect.sh" 2>/dev/null || true)"

if [ -z "$UDID" ]; then
  echo "BlueStacks not reachable. Start BlueStacks app first: open /Applications/BlueStacks.app" >&2
  exit 1
fi

echo "ADB devices:"
"$ADB" devices -l
echo

model="$("$ADB" -s "$UDID" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
android_ver="$("$ADB" -s "$UDID" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
brand="$("$ADB" -s "$UDID" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"

echo "Device: $UDID"
echo "Brand: ${brand:-unknown}"
echo "Model: ${model:-unknown}"
echo "Android: ${android_ver:-unknown}"
echo

# pm list packages can be flaky on BlueStacks ADB — try twice
echo "Third-party packages:"
packages="$("$ADB" -s "$UDID" shell pm list packages -3 2>/dev/null | tr -d '\r' | sed 's/^package://')"
if [ -z "$packages" ]; then
  sleep 1
  packages="$("$ADB" -s "$UDID" shell pm list packages -3 2>/dev/null | tr -d '\r' | sed 's/^package://')"
fi
if [ -n "$packages" ]; then
  printf '%s\n' "$packages"
else
  echo "(empty or ADB shell unstable — retry: adb -s $UDID shell pm list packages -3)"
fi
