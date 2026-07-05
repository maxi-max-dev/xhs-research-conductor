#!/usr/bin/env bash
# xhs-capture-comments.sh <bundle_dir> [max_scrolls]   (2026-06-07)
#
# Deterministically capture a note's comments: scroll DOWN to the comment
# section and run xhs-extract-comments.sh at each scroll, merging unique
# comments into <bundle_dir>/comments.json.
#
# WHY: relying on the mobile LLM agent to hand-roll "swipe → extract → swipe →
# extract → merge" is unreliable — it runs extract-comments while still on the
# carousel/正文 (no comment nodes there) and gets count=0 (2026-06-07 真踩: 4/4
# bundle 评论全空). This script makes it one deterministic call. Must be on the
# note's NoteDetailActivity when called.
#
# Usage:
#   xhs-capture-comments.sh /path/to/bundle 5

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
UDID="${ANDROID_SERIAL:-$("$SCRIPT_DIR/device-connect.sh" 2>/dev/null || echo 127.0.0.1:5555)}"
. "$SCRIPT_DIR/xhs-geom.sh"   # v0.16.3: proportional coords

BUNDLE="${1:-}"
MAX="${2:-5}"
if [ -z "$BUNDLE" ]; then echo "Usage: $0 <bundle_dir> [max_scrolls]" >&2; exit 1; fi
mkdir -p "$BUNDLE"

# Settle: carousel capture can leave focus transiently null/animating. Wait
# briefly for NoteDetailActivity to come back before extracting.
for _ in 1 2 3 4; do
  focus="$("$ADB" -s "$UDID" shell dumpsys window 2>/dev/null | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')"
  case "$focus" in *NoteDetailActivity*) break ;; esac
  sleep 1
done
case "$focus" in
  *NoteDetailActivity*) ;;
  *) echo "[capture-comments] WARN: not on NoteDetailActivity (focus=$focus). Extracting anyway." >&2 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract at current position, then scroll down and extract again, repeatedly.
for k in $(seq 1 "$MAX"); do
  "$SCRIPT_DIR/xhs-extract-comments.sh" "$TMP/c_${k}.json" >/dev/null 2>&1 || true
  # scroll down (swipe up) to load more comments
  "$ADB" -s "$UDID" shell input swipe "$(gx 720)" "$(gy 2000)" "$(gx 720)" "$(gy 600)" 500 >/dev/null 2>&1 || true
  sleep 1.2
done
# one final extract after the last scroll
"$SCRIPT_DIR/xhs-extract-comments.sh" "$TMP/c_final.json" >/dev/null 2>&1 || true

# Merge unique comments (by user + first 24 chars of text) into bundle/comments.json
python3 - "$BUNDLE/comments.json" "$TMP"/*.json <<'PY'
import json, sys
out = sys.argv[1]
files = sys.argv[2:]
seen = set(); merged = []
for f in files:
    try:
        d = json.load(open(f))
    except Exception:
        continue
    for c in d.get('comments', []):
        t = (c.get('text') or '').strip()
        if not t:
            continue
        key = (c.get('user', ''), t[:24])
        if key in seen:
            continue
        seen.add(key); merged.append(c)
json.dump({'count': len(merged), 'comments': merged}, open(out, 'w'), ensure_ascii=False, indent=2)
print(f'[capture-comments] merged {len(merged)} unique comments -> {out}')
PY
