#!/usr/bin/env zsh
set -euo pipefail

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
SCRIPT_DIR="${0:A:h}"
UDID="${ANDROID_SERIAL:-$("$SCRIPT_DIR/device-connect.sh")}"

if ! "$ADB" devices -l | grep -Eq "^${UDID}[[:space:]]+device"; then
  echo "Device $UDID is not connected."
  exit 1
fi

for pkg in io.appium.settings io.appium.uiautomator2.server io.appium.uiautomator2.server.test io.appium.unlock; do
  "$ADB" -s "$UDID" uninstall "$pkg" >/dev/null 2>&1 || true
done

if ! "$ADB" -s "$UDID" shell pm path com.xingin.xhs >/dev/null 2>&1; then
  echo "Xiaohongshu is not installed on $UDID."
  exit 2
fi

"$ADB" -s "$UDID" shell am force-stop com.xingin.xhs
"$ADB" -s "$UDID" shell monkey -p com.xingin.xhs 1
