#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
UDID="${ANDROID_SERIAL:-$("$SCRIPT_DIR/device-connect.sh")}"
# Default 20 (was 8). xhs notes routinely run 10-15 images; the 8-page cap
# was silently truncating long notes (2026-05-06 incident). The hash-match
# early stop catches real end-of-carousel, so 20 is just a safety ceiling.
MAX_PAGES="${1:-20}"
NAME="${2:-xhs-carousel}"
OUT_ROOT="${XHS_SCREENSHOT_DIR:-$(dirname "$SCRIPT_DIR")/screenshots}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$OUT_ROOT/${NAME}-${RUN_ID}"
MANIFEST="$OUT_DIR/manifest.json"
. "$SCRIPT_DIR/xhs-geom.sh"   # v0.16.3: proportional coords, any resolution
RESET_TO_FIRST="${XHS_RESET_TO_FIRST:-1}"
RESET_SWIPES="${XHS_RESET_SWIPES:-5}"
# xhs detail page has an iOS-style "swipe-from-left-edge to go back" gesture.
# On a 1440-wide portrait screen, that zone reaches roughly the first ~20%
# (X < ~288). Keep ALL swipe X coords inside [350, 1090] so we never
# touch the back-gesture zone or the right-edge bezel.
SWIPE_X_LEFT="${XHS_SWIPE_X_LEFT:-$(gx 400)}"
SWIPE_X_RIGHT="${XHS_SWIPE_X_RIGHT:-$(gx 1080)}"
SWIPE_Y="${XHS_SWIPE_Y:-$(gy 1280)}"
SETTLE_SECONDS="${XHS_SETTLE_SECONDS:-2}"

mkdir -p "$OUT_DIR"

if ! [[ "$MAX_PAGES" =~ '^[0-9]+$' ]] || [ "$MAX_PAGES" -lt 1 ]; then
  echo "MAX_PAGES must be a positive integer." >&2
  exit 2
fi

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

xhs_version() {
  "$ADB" -s "$UDID" shell dumpsys package com.xingin.xhs | awk -F= '/versionName=/{print $2; exit}' | tr -d '\r' || true
}

current_focus() {
  "$ADB" -s "$UDID" shell dumpsys window | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r' || true
}

# xhs's carousel exposes its position via the image view's accessibility
# content-desc, e.g. "Picture, No.3Zhang,Shared12Zhang, swipe left or
# right with two fingers to view more content" (Zhang = 张). Chinese UI
# uses "第3张,共12张". Returns "X Y" (current total) when found, empty
# otherwise. Active carousel is the FIRST match — profile fallback views
# may have multiple thumbnails with the same desc shape, but the active
# one is at index 0 of the layout.
carousel_position() {
  local dump=/tmp/_xhs_carousel_pos.xml
  "$ADB" -s "$UDID" shell uiautomator dump /sdcard/_xhs_carousel_pos.xml >/dev/null 2>&1 || return 1
  "$ADB" -s "$UDID" pull /sdcard/_xhs_carousel_pos.xml "$dump" >/dev/null 2>&1 || return 1
  python3 - "$dump" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    xml = f.read()
patterns = [
    r'No\.(\d+)Zhang,\s*Shared(\d+)Zhang',
    r'第\s*(\d+)\s*张\s*[,，]\s*共\s*(\d+)\s*张',
]
for p in patterns:
    m = re.search(p, xml)
    if m:
        print(f'{m.group(1)} {m.group(2)}')
        break
PYEOF
}

write_manifest() {
  local state="$1"
  local page_count="$2"
  local stop_reason="$3"
  jq -n \
    --arg mode "carousel" \
    --arg status "$state" \
    --arg created_at "$STARTED_AT" \
    --arg updated_at "$(timestamp)" \
    --arg device "$UDID" \
    --arg app_package "com.xingin.xhs" \
    --arg app_version "$APP_VERSION" \
    --arg focus "$FOCUS" \
    --arg name "$NAME" \
    --arg output_dir "$OUT_DIR" \
    --arg source_url "${XHS_SOURCE_URL:-}" \
    --arg title "${XHS_TITLE:-}" \
    --arg stop_reason "$stop_reason" \
    --argjson max_pages "$MAX_PAGES" \
    --argjson page_count "$page_count" \
    '{
      mode: $mode,
      status: $status,
      created_at: $created_at,
      updated_at: $updated_at,
      device: $device,
      app_package: $app_package,
      app_version: $app_version,
      focus: $focus,
      name: $name,
      source_url: $source_url,
      title: $title,
      output_dir: $output_dir,
      max_pages: $max_pages,
      page_count: $page_count,
      stop_reason: $stop_reason
    }' > "$MANIFEST"
}

capture_page() {
  local page="$1"
  local png="$OUT_DIR/page-$(printf '%02d' "$page").png"
  local jpg="$OUT_DIR/page-$(printf '%02d' "$page")-discord.jpg"
  "$ADB" -s "$UDID" exec-out screencap -p > "$png"
  "$SCRIPT_DIR/discord-safe-image.sh" "$png" "$jpg" >/dev/null
  printf '%s\n' "$png"
}

STARTED_AT="$(timestamp)"
APP_VERSION="$(xhs_version)"
FOCUS="$(current_focus)"
write_manifest "running" 0 ""
stop_reason="max_pages_or_complete"

echo "Device: $UDID"
echo "Output: $OUT_DIR"

# Sanity: bail if we're NOT on a note-detail-like activity. Otherwise the
# swipes happen on the home feed and silently navigate into random notes
# / profiles, which is exactly the bug we hit on 2026-05-06.
case "$FOCUS" in
  *NoteDetailActivity*|*NoteFeedActivity*|*VideoFeedActivity*|*MatrixVideoFeedActivity*) ;;
  *)
    echo "Refusing to swipe: focus is '$FOCUS'." >&2
    echo "Expected NoteDetailActivity (or similar). Run xhs-open-link.sh first." >&2
    write_manifest "aborted" 0 "wrong_focus"
    exit 3
    ;;
esac

# Let the activity finish its enter animation before we touch the screen.
sleep "$SETTLE_SECONDS"

if [ "$RESET_TO_FIRST" = "1" ]; then
  # v0.16 surgical reset (2026-07-05, T28 真踩 lost_focus 3 连): blind 固定 5 下
  # 右滑在单图/读不到位置的笔记上会蹭到返回手势, 直接甩回搜索页. 刚进的笔记本来
  # 就在第 1 张 — 先读位置: 第 1 张不滑; 第 N 张精确滑 N-1 下; 读不到位置不盲滑.
  RESET_POS="$(carousel_position || true)"
  RESET_CUR="$(echo "$RESET_POS" | awk '{print $1}')"
  if [ -n "$RESET_CUR" ] && [ "$RESET_CUR" -gt 1 ]; then
    n=$((RESET_CUR - 1))
    [ "$n" -gt "$RESET_SWIPES" ] && n="$RESET_SWIPES"
    echo "Reset: at page $RESET_CUR, swiping back $n time(s)."
    for _ in $(seq 1 "$n"); do
      "$ADB" -s "$UDID" shell input swipe "$SWIPE_X_LEFT" "$SWIPE_Y" "$SWIPE_X_RIGHT" "$SWIPE_Y" 250
      sleep 0.2
    done
    # Re-check focus after reset swipes — if we accidentally backed out,
    # don't keep swiping on the wrong screen.
    POST_RESET_FOCUS="$(current_focus)"
    case "$POST_RESET_FOCUS" in
      *NoteDetailActivity*|*NoteFeedActivity*|*VideoFeedActivity*|*MatrixVideoFeedActivity*) ;;
      *)
        echo "Lost focus during reset swipes: '$POST_RESET_FOCUS'." >&2
        write_manifest "aborted" 0 "lost_focus_during_reset"
        exit 4
        ;;
    esac
  fi
fi

prev="$(capture_page 1)"
captured=1
echo "Captured: $prev"

# Read X/Y position before any swipe. If xhs gives us a precise total,
# we can stop deterministically instead of relying on hash matches.
INITIAL_POS="$(carousel_position)"
if [ -n "$INITIAL_POS" ]; then
  TOTAL_PAGES="$(echo "$INITIAL_POS" | awk '{print $2}')"
  echo "Carousel reports: page $(echo "$INITIAL_POS" | awk '{print $1}')/$TOTAL_PAGES"
  if [ "$TOTAL_PAGES" = "1" ]; then
    echo "Only 1 image in this note; nothing to swipe."
    write_manifest "complete" 1 "single_image"
    echo "Done: $OUT_DIR"
    exit 0
  fi
fi

# Confirm-stop counter: hash matches OR position-stuck on N consecutive
# checks before we declare end-of-carousel. Defends against momentary
# swipe failures (the user's 2026-05-06 observation: "should swipe a few
# times, if same then it's the end").
# v0.13: default 1 (was 2). When position desc isn't available, hash
# matched once already means single-image. CONFIRM_STOP=2 was wasting
# ~1 swipe (~1.5s) per single-image note + producing duplicate pages
# inflating manifest page_count. Set XHS_CONFIRM_STOP=2 explicitly if
# you suspect false-positive early breaks.
CONFIRM_STOP_THRESHOLD="${XHS_CONFIRM_STOP:-1}"
prev_pos="$INITIAL_POS"
unchanged_count=0

if [ "$MAX_PAGES" -gt 1 ]; then
  for page in $(seq 2 "$MAX_PAGES"); do
    "$ADB" -s "$UDID" shell input swipe "$SWIPE_X_RIGHT" "$SWIPE_Y" "$SWIPE_X_LEFT" "$SWIPE_Y" 450
    sleep 1.2

    # Bail if the swipe accidentally exited the note.
    NOW_FOCUS="$(current_focus)"
    case "$NOW_FOCUS" in
      *NoteDetailActivity*|*NoteFeedActivity*|*VideoFeedActivity*|*MatrixVideoFeedActivity*) ;;
      *)
        echo "Lost focus on page $page: '$NOW_FOCUS'." >&2
        stop_reason="lost_focus"
        break
        ;;
    esac

    current="$(capture_page "$page")"

    # Primary stop: position == total
    cur_pos="$(carousel_position)"
    if [ -n "$cur_pos" ]; then
      cur_x="$(echo "$cur_pos" | awk '{print $1}')"
      cur_total="$(echo "$cur_pos" | awk '{print $2}')"
      echo "  position: $cur_x/$cur_total"

      if [ "$cur_pos" = "$prev_pos" ]; then
        unchanged_count=$((unchanged_count + 1))
      else
        unchanged_count=0
      fi
      prev_pos="$cur_pos"

      # If we reached the last image, capture this one and stop.
      if [ "$cur_x" = "$cur_total" ]; then
        echo "Captured: $current (last page $cur_x/$cur_total)"
        captured="$page"
        stop_reason="last_page"
        break
      fi

      # If position is stuck (swipe didn't advance) for N rounds, stop.
      if [ "$unchanged_count" -ge "$CONFIRM_STOP_THRESHOLD" ]; then
        rm -f "$current" "${current:r}-discord.jpg"
        echo "Stopped: position stuck at $cur_x for $unchanged_count rounds."
        stop_reason="position_stuck"
        break
      fi
    fi

    # Fallback stop: hash match (when position desc isn't available, e.g.
    # video carousels or unusual layouts). Also use confirm-stop logic.
    prev_hash="$(shasum -a 256 "$prev" | awk '{print $1}')"
    current_hash="$(shasum -a 256 "$current" | awk '{print $1}')"

    if [ "$prev_hash" = "$current_hash" ]; then
      # Hash matched. If we have position info AND it's advancing, this is
      # weird (image identical but position different) — keep going. Otherwise
      # treat as a confirm-stop signal.
      if [ -z "$cur_pos" ]; then
        unchanged_count=$((unchanged_count + 1))
        if [ "$unchanged_count" -ge "$CONFIRM_STOP_THRESHOLD" ]; then
          rm -f "$current" "${current:r}-discord.jpg"
          echo "Stopped: hash matched $unchanged_count consecutive times."
          stop_reason="matched_previous"
          break
        fi
      fi
    fi

    echo "Captured: $current"
    captured="$page"
    prev="$current"
  done
fi

write_manifest "complete" "$captured" "$stop_reason"
echo "Done: $OUT_DIR"
