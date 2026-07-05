#!/usr/bin/env zsh
# detect-emulator.sh
# 自动检测可用的 Android 模拟器 / 真机, 输出 ADB UDID 给 xhs-capture-* 用.
#
# 优先级 (越上面越优先):
#   1. 环境变量 $ANDROID_SERIAL (用户显式指定)
#   2. 环境变量 $XHS_EMULATOR (e.g., bluestacks / genymotion / avd / detect)
#   3. 自动 detect:
#      - BlueStacks Air for Mac (127.0.0.1:5555)
#      - Genymotion (127.0.0.1:6555)
#      - Android Studio AVD (emulator-5554)
#      - 真机 (任意 connected device)
#
# 输出: ADB UDID (e.g., "127.0.0.1:5555" / "emulator-5554")
# 退出码: 0 success / 1 no device found / 2 ADB missing
set -euo pipefail

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"

# 找不到 ADB → fail with clear message
if ! [ -x "$ADB" ]; then
  ADB="$(command -v adb || true)"
  if [ -z "$ADB" ]; then
    echo "ADB not found. Install:" >&2
    echo "  brew install --cask android-platform-tools" >&2
    echo "Or set ANDROID_HOME / ADB env var." >&2
    exit 2
  fi
fi

# Priority 1: explicit serial
if [ -n "${ANDROID_SERIAL:-}" ]; then
  if "$ADB" devices | grep -Eq "^${ANDROID_SERIAL}[[:space:]]+device"; then
    printf '%s\n' "$ANDROID_SERIAL"
    exit 0
  fi
  echo "ANDROID_SERIAL=$ANDROID_SERIAL not connected. Try $ADB connect $ANDROID_SERIAL" >&2
  exit 1
fi

# Priority 2: explicit emulator brand
case "${XHS_EMULATOR:-detect}" in
  bluestacks)
    UDID="${BLUESTACKS_UDID:-127.0.0.1:5555}"
    "$ADB" connect "$UDID" >/dev/null 2>&1 || true
    ;;
  genymotion)
    UDID="${GENYMOTION_UDID:-127.0.0.1:6555}"
    "$ADB" connect "$UDID" >/dev/null 2>&1 || true
    ;;
  avd)
    UDID="${AVD_UDID:-emulator-5554}"
    ;;
  detect)
    # Priority 3: try each in order
    for candidate in 127.0.0.1:5555 127.0.0.1:6555 emulator-5554; do
      "$ADB" connect "$candidate" >/dev/null 2>&1 || true
      if "$ADB" devices | grep -Eq "^${candidate}[[:space:]]+device"; then
        UDID="$candidate"
        break
      fi
    done

    # Fallback: any connected device
    if [ -z "${UDID:-}" ]; then
      UDID=$("$ADB" devices | awk '/[[:space:]]device$/ {print $1; exit}')
    fi
    ;;
  *)
    echo "Unknown XHS_EMULATOR=$XHS_EMULATOR. Use: bluestacks / genymotion / avd / detect" >&2
    exit 1
    ;;
esac

# Wait briefly for device to register
if [ -n "${UDID:-}" ]; then
  timeout=10
  while [ $timeout -gt 0 ]; do
    if "$ADB" devices | grep -Eq "^${UDID}[[:space:]]+device"; then
      printf '%s\n' "$UDID"
      exit 0
    fi
    sleep 1
    timeout=$((timeout - 1))
  done
fi

echo "No Android device / emulator found." >&2
echo "Tried: BlueStacks (127.0.0.1:5555), Genymotion (127.0.0.1:6555), AVD (emulator-5554)" >&2
echo "" >&2
echo "Fix:" >&2
echo "  - Mac: brew install --cask bluestacks  (then launch & install XHS)" >&2
echo "  - Or run: \$ANDROID_HOME/emulator/emulator -avd <avd-name>  (AVD)" >&2
echo "  - Or set: export ANDROID_SERIAL=<your-device-id>  (real device)" >&2
echo "" >&2
echo "Check: \$ADB devices" >&2
exit 1
