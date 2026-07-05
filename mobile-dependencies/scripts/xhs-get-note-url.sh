#!/usr/bin/env zsh
# xhs-get-note-url.sh
#
# Get the canonical share URL of the currently-open XHS note.
# Prints URL to stdout on success. Exits 0 / 1.
#
# How: tap the "..." menu (moreOperateIV) -> tap "Copy link" / "复制链接"
# in the XHS share sheet. BlueStacks syncs the Android clipboard to the
# Mac pasteboard, so we read it via `pbpaste` and extract the xhslink URL.
#
# Requires:
#   - Foreground = com.xingin.xhs/NoteDetailActivity
#   - BlueStacks host<->guest clipboard sync ON (default for BlueStacks Air)
#   - ADB shell access (see xhs-open-link.sh for the BlueStacks config caveat)

set -uo pipefail

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
TMP_DUMP="${TMPDIR:-/tmp}/_xhs_get_note_url.xml"

log() { echo "[xhs-get-note-url] $*" >&2; }

# 1. Verify foreground
focus=$($ADB shell dumpsys window 2>/dev/null | grep mCurrentFocus | head -1)
if ! echo "$focus" | grep -q "NoteDetailActivity"; then
  log "ERROR: foreground is not NoteDetailActivity. focus=$focus"
  exit 1
fi

# 2. Snapshot Mac clipboard so we can restore it afterward
prev_clip=$(pbpaste 2>/dev/null || echo "")

dump_ui() {
  $ADB shell uiautomator dump /sdcard/_xhs_url.xml >/dev/null 2>&1 || return 1
  $ADB pull /sdcard/_xhs_url.xml "$TMP_DUMP" >/dev/null 2>&1 || return 1
}

# 3. Find "..." button (moreOperateIV) and tap
dump_ui || { log "ERROR: uiautomator dump failed before menu open"; exit 1; }
more_coords=$(python3 - "$TMP_DUMP" <<'PY'
import re, sys
with open(sys.argv[1]) as f: x = f.read()
m = re.search(r'<node[^>]+resource-id="com\.xingin\.xhs:id/moreOperateIV"[^>]+bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x)
if m:
    x1, y1, x2, y2 = map(int, m.groups())
    print(f"{(x1+x2)//2} {(y1+y2)//2}")
PY
)
if [ -z "$more_coords" ]; then
  log "ERROR: moreOperateIV button not found in UI dump"
  exit 1
fi
$ADB shell input tap $more_coords
sleep 2

# 4. Find Copy link / 复制链接 in share sheet and tap
dump_ui || { log "ERROR: uiautomator dump failed after menu open"; exit 1; }
copy_coords=$(python3 - "$TMP_DUMP" <<'PY'
import re, sys
with open(sys.argv[1]) as f: x = f.read()
for label in ("Copy link", "复制链接"):
    m = re.search(
        r'<node[^>]+text="' + re.escape(label) + r'"[^>]+bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
        x,
    )
    if m:
        x1, y1, x2, y2 = map(int, m.groups())
        print(f"{(x1+x2)//2} {(y1+y2)//2}")
        break
PY
)
if [ -z "$copy_coords" ]; then
  log "ERROR: 'Copy link' / '复制链接' not in share sheet"
  $ADB shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  exit 1
fi
$ADB shell input tap $copy_coords
sleep 2

# 5. Read clipboard, extract xhslink URL (v0.13: retry 3x with longer sleep, BlueStacks sync is slow)
url=""
for attempt in 1 2 3; do
  new_clip=$(pbpaste 2>/dev/null || echo "")
  url=$(printf '%s' "$new_clip" | grep -oE 'https?://xhslink\.com/[a-zA-Z0-9/]+' | head -1)
  if [ -n "$url" ]; then
    break
  fi
  log "attempt $attempt: clipboard empty, retry in 1s"
  sleep 1
done

# 6. Restore previous clipboard (best effort)
printf '%s' "$prev_clip" | pbcopy 2>/dev/null || true

# 7. Verify focus still in NoteDetailActivity (sanity for downstream capture)
post_focus=$($ADB shell dumpsys window 2>/dev/null | grep mCurrentFocus | head -1)
if ! echo "$post_focus" | grep -q "NoteDetailActivity"; then
  log "WARN: focus drifted after copy. focus=$post_focus"
fi

if [ -z "$url" ]; then
  log "WARN: clipboard 3x retry failed, trying fallback methods..."

  # Fallback B (v0.15): extract noteId from NoteDetailActivity intent / UI dump.
  # XHS NoteDetailActivity intent data field looks like:
  #   xhsdiscover://item/<24-hex-noteId> or
  #   https://www.xiaohongshu.com/explore/<24-hex-noteId>
  # Either way we can synthesize https://www.xiaohongshu.com/explore/<noteId>
  # which is canonical (not xhslink short-form, but works for source linking).
  NOTE_ID=""

  # Try 1: dumpsys activity recents → find last NoteDetailActivity intent data
  NOTE_ID=$($ADB shell dumpsys activity recents 2>/dev/null \
    | grep -oE '(xhsdiscover://item/|xiaohongshu\.com/explore/|/discovery/item/)[a-f0-9]{24}' \
    | head -1 \
    | grep -oE '[a-f0-9]{24}$' \
    || true)

  # Try 2: uiautomator dump → look for noteId in any attribute (content-desc, resource-id paths)
  if [ -z "$NOTE_ID" ]; then
    $ADB shell uiautomator dump /sdcard/_xhs_url_fb.xml >/dev/null 2>&1
    $ADB pull /sdcard/_xhs_url_fb.xml "$TMP_DUMP" >/dev/null 2>&1
    NOTE_ID=$(grep -oE '[a-f0-9]{24}' "$TMP_DUMP" 2>/dev/null | head -1 || true)
    $ADB shell rm /sdcard/_xhs_url_fb.xml >/dev/null 2>&1
  fi

  if [ -n "$NOTE_ID" ]; then
    url="https://www.xiaohongshu.com/explore/$NOTE_ID"
    log "fallback success: synthesized canonical URL from noteId $NOTE_ID"
  else
    log "ERROR: all URL extraction methods failed (clipboard + dumpsys + uiautomator)"
    log "clipboard content (first 200 chars): $(printf '%s' "$new_clip" | head -c 200)"
    rm -f "$TMP_DUMP"
    exit 1
  fi
fi

# Cleanup
rm -f "$TMP_DUMP"
$ADB shell rm /sdcard/_xhs_url.xml >/dev/null 2>&1 || true

echo "$url"
