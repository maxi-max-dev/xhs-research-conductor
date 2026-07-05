#!/usr/bin/env zsh
# xhs-set-note-filter.sh — set XHS search filter to Note type only (排除 video / live)
# 必须先 fire deep link 到 GlobalSearchActivity, 然后跑这脚本
# 1. tap (92, 195) — 打开 All tab 旁边的 ≡ filter 图标
# 2. tap (894, 622) — 选 "Note" (Note type 行)
# 3. KEYCODE_BACK — 关 panel 应用 filter (Hide 按钮容易误触下面 note card)
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
UDID="${ANDROID_SERIAL:-$("$SCRIPT_DIR/detect-emulator.sh")}"
. "$SCRIPT_DIR/xhs-geom.sh"   # v0.16.3: proportional coords

# Verify in GlobalSearchActivity first
FOCUS=$("$ADB" -s "$UDID" shell dumpsys window 2>&1 | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')
case "$FOCUS" in
  *GlobalSearchActivity*) ;;
  *)
    echo "Not in GlobalSearchActivity. focus=$FOCUS. Fire deep link first." >&2
    exit 2
    ;;
esac

# Step 1: open filter panel (tap ≡ icon at All tab right side)
"$ADB" -s "$UDID" shell input tap "$(gx 92)" "$(gy 195)"
sleep 1.5

# Verify panel open by checking for "Note type" text
"$ADB" -s "$UDID" shell uiautomator dump /sdcard/_xhs_filter_check.xml >/dev/null 2>&1
if ! "$ADB" -s "$UDID" shell cat /sdcard/_xhs_filter_check.xml 2>/dev/null | grep -q "Note type"; then
  echo "Filter panel didn't open after tap (92,195). Check XHS version." >&2
  exit 3
fi

# Step 2: tap "Note" button (image+text note, not video, not live)
"$ADB" -s "$UDID" shell input tap "$(gx 894)" "$(gy 622)"
sleep 1

# Step 3: close panel with BACK (Hide button at 1096,1244 risky — easy to hit note below)
"$ADB" -s "$UDID" shell input keyevent KEYCODE_BACK
sleep 1.5

# Verify still in GlobalSearchActivity (not accidentally entered note)
FOCUS=$("$ADB" -s "$UDID" shell dumpsys window 2>&1 | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')
case "$FOCUS" in
  *GlobalSearchActivity*)
    echo "✓ Note filter applied. Now in $FOCUS"
    exit 0
    ;;
  *)
    echo "Warning: ended in $FOCUS, BACK may have over-shot." >&2
    exit 4
    ;;
esac
