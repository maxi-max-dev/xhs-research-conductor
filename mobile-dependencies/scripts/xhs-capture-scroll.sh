#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
UDID="${ANDROID_SERIAL:-$("$SCRIPT_DIR/device-connect.sh")}"
# Default 15 (was 8). Long notes have many comments; the 8-page cap was
# silently truncating. End-of-content detection (looking for "- THE END -"
# or "暂无更多" / "没有更多了" in the dumped UI) stops earlier when we
# really reach the bottom.
MAX_PAGES="${1:-15}"
NAME="${2:-xhs-scroll}"
OUT_ROOT="${XHS_SCREENSHOT_DIR:-$(dirname "$SCRIPT_DIR")/screenshots}"
. "$SCRIPT_DIR/xhs-geom.sh"   # v0.16.3: proportional coords
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$OUT_ROOT/${NAME}-${RUN_ID}"
MANIFEST="$OUT_DIR/manifest.json"

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

# True (returns 0) if the current visible UI contains an end-of-content
# marker (e.g. "- THE END -" at the bottom of comments). Lets us stop
# before MAX_PAGES when we've truly reached the bottom of the note.
end_marker_visible() {
  local dump="/tmp/_xhs_scroll_endcheck.xml"
  "$ADB" -s "$UDID" shell uiautomator dump /sdcard/_xhs_scroll_endcheck.xml >/dev/null 2>&1 || return 1
  "$ADB" -s "$UDID" pull /sdcard/_xhs_scroll_endcheck.xml "$dump" >/dev/null 2>&1 || return 1
  grep -q -E '(- THE END -|暂无更多|没有更多了|没有更多评论|评论加载完成|END OF COMMENTS|已经到底了)' "$dump"
}

write_manifest() {
  local state="$1"
  local page_count="$2"
  local stop_reason="$3"
  jq -n \
    --arg mode "scroll" \
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
  local png="$OUT_DIR/scroll-$(printf '%02d' "$page").png"
  local jpg="$OUT_DIR/scroll-$(printf '%02d' "$page")-discord.jpg"
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

# Bail early if we're on the wrong screen — otherwise we silently scroll
# through someone else's profile / the home feed (the 2026-05-06 bug).
case "$FOCUS" in
  *NoteDetailActivity*|*NoteFeedActivity*|*VideoFeedActivity*|*MatrixVideoFeedActivity*) ;;
  *)
    echo "Refusing to scroll: focus is '$FOCUS'." >&2
    echo "Expected NoteDetailActivity (or similar). Run xhs-open-link.sh first." >&2
    write_manifest "aborted" 0 "wrong_focus"
    exit 3
    ;;
esac

# Let the activity finish its enter animation before we touch the screen.
sleep "${XHS_SETTLE_SECONDS:-2}"

prev="$(capture_page 1)"
captured=1
echo "Captured: $prev"

# If page 1 already shows the end marker (very short note), stop here.
if end_marker_visible; then
  echo "End-of-content marker already visible on page 1."
  stop_reason="end_marker"
fi

if [ "$MAX_PAGES" -gt 1 ] && [ "$stop_reason" != "end_marker" ]; then
  for page in $(seq 2 "$MAX_PAGES"); do
    "$ADB" -s "$UDID" shell input swipe "$(gx 720)" "$(gy 2050)" "$(gx 720)" "$(gy 700)" 550
    sleep 1.2

    # Bail if the swipe accidentally took us off the note (rare for pure
    # vertical swipes, but possible if xhs's pull-to-dismiss kicks in).
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

    prev_hash="$(shasum -a 256 "$prev" | awk '{print $1}')"
    current_hash="$(shasum -a 256 "$current" | awk '{print $1}')"

    if [ "$prev_hash" = "$current_hash" ]; then
      rm -f "$current" "${current:r}-discord.jpg"
      echo "Stopped: page $page matched previous screenshot."
      stop_reason="matched_previous"
      break
    fi

    echo "Captured: $current"
    captured="$page"
    prev="$current"

    # Now check end marker: if visible on this page, capture this one
    # (we already did) and stop. Don't waste a swipe to confirm.
    if end_marker_visible; then
      echo "End-of-content marker visible on page $page. Stopping."
      stop_reason="end_marker"
      break
    fi
  done
fi

write_manifest "complete" "$captured" "$stop_reason"
echo "Done: $OUT_DIR"
