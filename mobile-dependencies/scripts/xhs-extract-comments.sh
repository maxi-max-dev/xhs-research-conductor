#!/usr/bin/env zsh
# xhs-extract-comments.sh [output.json]
#
# Dumps the current xhs note UI and extracts a structured list of visible
# comments. Avoids the 2026-05-07 bug where OCR mixed comment-attached
# image text into the comment body, producing false attributions like
# "@小盖: 王宁最想纠正的误解..." (the actual comment was "效果长这样" plus
# an attached slide screenshot showing that quote).
#
# Output JSON shape (one object per visible comment):
#   {
#     "user": "小盖",
#     "is_author": true,
#     "text": "效果长这样",
#     "likes": 0,
#     "attached_images": 1,
#     "bounds": "[238,160][1202,334]"
#   }
#
# Usage in flow:
#   ./scripts/xhs-open-link.sh '<url>'
#   ./scripts/xhs-capture-scroll.sh 8 my-note-body   # also captures images
#   # at any point while in NoteDetailActivity:
#   ./scripts/xhs-extract-comments.sh /tmp/my-comments.json
#
# Run multiple times during the scroll if the comment list is long; each
# invocation dumps the currently visible comments.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
OUT="${1:-/tmp/xhs_comments.json}"

if [ -x "$SCRIPT_DIR/device-connect.sh" ]; then
  UDID="$("$SCRIPT_DIR/device-connect.sh")"
else
  UDID="${ANDROID_SERIAL:-127.0.0.1:5555}"
fi

# Bail if not on a note detail screen — extracting comments off-page
# would mean walking the home feed RecyclerView, which produces nonsense.
focus="$("$ADB" -s "$UDID" shell dumpsys window 2>/dev/null \
  | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')"
case "$focus" in
  *NoteDetailActivity*|*NoteFeedActivity*) ;;
  *)
    echo "Refusing to extract: focus is '$focus'." >&2
    echo "Expected NoteDetailActivity. Run xhs-open-link.sh first." >&2
    exit 3
    ;;
esac

DUMP=/tmp/_xhs_extract_comments.xml
"$ADB" -s "$UDID" shell uiautomator dump /sdcard/_xhs_extract_comments.xml >/dev/null 2>&1 || {
  echo "uiautomator dump failed" >&2; exit 4
}
"$ADB" -s "$UDID" pull /sdcard/_xhs_extract_comments.xml "$DUMP" >/dev/null 2>&1 || {
  echo "adb pull failed" >&2; exit 4
}

python3 - "$DUMP" "$OUT" <<'PYEOF'
import json, re, sys
import xml.etree.ElementTree as ET

dump_path, out_path = sys.argv[1], sys.argv[2]
tree = ET.parse(dump_path)
root = tree.getroot()

# Resource-ids that are NOT comment image attachments (skip them when
# counting attached images).
NOT_ATTACHMENT_RIDS = {
    'com.xingin.xhs:id/lv_like',
    'com.xingin.xhs:id/mUserAvatarView',
    'com.xingin.xhs:id/avatarView',
    'com.xingin.xhs:id/iv_avatar',
    'com.xingin.xhs:id/comment_tag_view_author',
}

def walk(node):
    yield node
    for c in node:
        yield from walk(c)

comments = []
for n in root.iter('node'):
    if n.get('resource-id') != 'com.xingin.xhs:id/parentCommentLayout':
        continue

    user = ''
    text = ''
    likes = 0
    attached = 0
    is_author = False

    for child in walk(n):
        if child is n:
            continue
        crid = child.get('resource-id', '')
        ctext = child.get('text', '')
        ccls = child.get('class', '')

        if crid == 'com.xingin.xhs:id/tv_user_name' and ctext:
            user = ctext
        elif crid == 'com.xingin.xhs:id/tv_content' and ctext:
            text = ctext
        elif crid == 'com.xingin.xhs:id/tv_like_num' and ctext:
            try:
                likes = int(ctext.replace(',', '').replace('w', '0000'))
            except ValueError:
                likes = 0
        elif crid == 'com.xingin.xhs:id/comment_tag_view_author':
            is_author = True
        elif 'ImageView' in ccls and crid not in NOT_ATTACHMENT_RIDS:
            # If the ImageView has no recognizable role rid, treat as
            # an embedded image attachment.
            short = crid.split('/')[-1] if crid else ''
            if short and short not in {'iv_type', 'iv_image', 'lv_like'}:
                attached += 1
            elif not crid:
                # No rid — likely a content image
                attached += 1

    if not user:
        continue  # skip empty container

    comments.append({
        'user': user,
        'is_author': is_author,
        'text': text,
        'likes': likes,
        'attached_images': attached,
        'bounds': n.get('bounds', ''),
    })

with open(out_path, 'w') as f:
    json.dump({
        'count': len(comments),
        'comments': comments,
    }, f, ensure_ascii=False, indent=2)

# Also print a human-readable summary to stdout for quick inspection.
print(f"Extracted {len(comments)} comment(s) → {out_path}")
for c in comments:
    tag = ' [Author]' if c['is_author'] else ''
    img = f" 📎{c['attached_images']}img" if c['attached_images'] else ''
    likes = f" ❤{c['likes']}" if c['likes'] else ''
    text = c['text'][:80] + ('...' if len(c['text']) > 80 else '')
    print(f"  {c['user']}{tag}: {text}{likes}{img}")
PYEOF
