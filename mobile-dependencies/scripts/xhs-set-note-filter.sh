#!/usr/bin/env zsh
# xhs-set-note-filter.sh — set XHS search filter by note type (默认 Note = 纯图文, 排除 video / live)
# 必须先 fire deep link 到 GlobalSearchActivity, 然后跑这脚本
# 1. tap (92, 195) — 打开 All tab 旁边的 ≡ filter 图标
# 2. tap Note type 行的目标按钮 — Note(894,622) / Video(546,622), 同一行 (v0.17 实测)
# 3. KEYCODE_BACK — 关 panel 应用 filter (Hide 按钮容易误触下面 note card)
#
# 用法: xhs-set-note-filter.sh [--type note|video]   # 默认 note, 完全向后兼容
set -euo pipefail

FILTER_TYPE="note"
if [ "${1:-}" = "--type" ]; then
  FILTER_TYPE="${2:-note}"
fi
case "$FILTER_TYPE" in
  note|video) ;;
  *) echo "Unknown --type '$FILTER_TYPE' (note|video)" >&2; exit 1 ;;
esac

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

# Step 2: tap target button on the "Note type" row (Note=纯图文 / Video=视频)
if [ "$FILTER_TYPE" = "video" ]; then
  "$ADB" -s "$UDID" shell input tap "$(gx 546)" "$(gy 622)"
else
  "$ADB" -s "$UDID" shell input tap "$(gx 894)" "$(gy 622)"
fi
sleep 1

# Step 3: close panel with BACK (Hide button at 1096,1244 risky — easy to hit note below)
"$ADB" -s "$UDID" shell input keyevent KEYCODE_BACK
sleep 1.5

# Verify still in GlobalSearchActivity (not accidentally entered note)
FOCUS=$("$ADB" -s "$UDID" shell dumpsys window 2>&1 | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')
case "$FOCUS" in
  *GlobalSearchActivity*)
    echo "✓ ${FILTER_TYPE} filter applied. Now in $FOCUS"
    exit 0
    ;;
  *)
    echo "Warning: ended in $FOCUS, BACK may have over-shot." >&2
    exit 4
    ;;
esac
