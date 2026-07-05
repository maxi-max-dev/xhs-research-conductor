#!/usr/bin/env zsh
# xhs-get-note-title.sh
# 抓当前 NoteDetailActivity 的笔记标题
# 用法: TITLE=$(./xhs-get-note-title.sh)
#       然后 export XHS_TITLE="$TITLE" 给 xhs-capture-* 用
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
UDID="${ANDROID_SERIAL:-$("$SCRIPT_DIR/device-connect.sh" 2>/dev/null || echo 127.0.0.1:5555)}"

# 验证当前在 NoteDetailActivity
FOCUS=$("$ADB" -s "$UDID" shell dumpsys window 2>/dev/null | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')
case "$FOCUS" in
  *NoteDetailActivity*|*NoteFeedActivity*|*VideoFeedActivity*|*MatrixVideoFeedActivity*) ;;
  *)
    echo "Not on note detail page. Focus: $FOCUS" >&2
    exit 2
    ;;
esac

DUMP=/tmp/_xhs_note_title.xml
"$ADB" -s "$UDID" shell uiautomator dump /sdcard/_xhs_note_title.xml >/dev/null 2>&1
"$ADB" -s "$UDID" pull /sdcard/_xhs_note_title.xml "$DUMP" >/dev/null 2>&1

# 用 python 从 XML 抽 title
# heuristic: 笔记标题在 TextView, text length 10-100, 不是 "Say something..." / "Comment" / nav 等
python3 - "$DUMP" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    xml = f.read()

# 过滤掉这些 UI 元素 (不是 title)
blacklist = {
    'Say something...', 'Drop a comment...', 'Share your thoughts...',
    'Comment Box', 'You may like', 'Translate', 'Reply', 'Pinned',
    'Follow', 'Following', 'For You', 'Author', 'No comments yet',
    'Share', 'Save', 'Like', 'Mention', 'Hashtag', 'Auto-translate'
}

candidates = re.findall(r'text="([^"]{8,120})"', xml)
# 第一个长 text 通常是 caption (标题段落), 之后是 hashtag / body
for c in candidates:
    c = c.strip()
    if c in blacklist:
        continue
    if c.startswith('#'):
        continue
    if re.match(r'^\d+(\.\d+)?[wk]?\s*(comment|like|share|view)', c, re.I):
        continue
    if re.match(r'^[\d:]+\s*[APM]?', c):  # timestamps like "11:43"
        continue
    print(c)
    break
PYEOF
