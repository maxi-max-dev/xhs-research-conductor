#!/usr/bin/env zsh
# xhs-harvest-video-urls.sh — 从 XHS 搜索结果收割视频笔记的分享链接 (v0.17 视频道)
#
# 原理: 搜索深链 → Video filter → 进第一条视频(落 DetailFeedActivity 沉浸流) →
#       循环 [分享 → dump 找 Copy link → pbpaste 收链接 → 上滑下一条]。
# 关键实测 (2026-07-10):
#   - DetailFeedActivity 播放中 uiautomator 永不 idle, dump 必挂;
#     但分享面板一开视频即暂停, dump 就能用 → 所有 dump 都在面板开着时做
#   - Copy link 在分享面板第二行, 常需左滑一次才露出来
#   - 沉浸流上滑 = 下一条搜索结果, 收割 N 条只需进场一次
#
# 用法: xhs-harvest-video-urls.sh [--count N] [--out FILE] "<keyword>"
#   --count N   收几条 (默认 2)
#   --out FILE  输出 TSV (url \t 剪贴板标题片段); 默认 stdout
# 退出码: 0=至少收到 1 条; 1=一条没收到; 2=参数/环境错误
set -uo pipefail
export LC_ALL=en_US.UTF-8
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # agent/launchd 环境常缺 homebrew

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
UDID="${ANDROID_SERIAL:-$("$SCRIPT_DIR/detect-emulator.sh")}"
. "$SCRIPT_DIR/xhs-geom.sh"

COUNT=2
OUT=""
KW=""
log() { echo "[harvest-video] $*" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --count) COUNT="${2:-2}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) KW="$1"; shift ;;
  esac
done
[ -z "$KW" ] && { log "ERROR: 缺 keyword"; exit 2; }

TMP_DUMP="${TMPDIR:-/tmp}/_xhs_harvest.xml"
PREV_CLIP=$(pbpaste 2>/dev/null || echo "")

adb_shell() { "$ADB" -s "$UDID" shell "$@"; }

focus_is() {
  local want="$1"
  adb_shell dumpsys window 2>/dev/null | grep mCurrentFocus | grep -q "$want"
}

dump_ui() {
  adb_shell uiautomator dump /sdcard/_xhs_hv.xml >/dev/null 2>&1 || return 1
  "$ADB" -s "$UDID" pull /sdcard/_xhs_hv.xml "$TMP_DUMP" >/dev/null 2>&1 || return 1
}

# 从 dump 里找文本节点中心坐标: node_center "Copy link|复制链接"
node_center() {
  python3 - "$TMP_DUMP" "$1" <<'PY'
import re, sys
x = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
pat = sys.argv[2]
for m in re.finditer(r'<node[^>]*text="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x):
    if re.search(pat, m.group(1)):
        x1, y1, x2, y2 = map(int, m.groups()[1:])
        print((x1+x2)//2, (y1+y2)//2)
        break
PY
}

# ── 1. 搜索深链 → GlobalSearchActivity ──
ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$KW")
adb_shell "am start -W -a android.intent.action.VIEW -d 'xhsdiscover://search/result?keyword=$ENC' com.xingin.xhs" >/dev/null 2>&1
sleep 3
if ! focus_is GlobalSearchActivity; then
  log "ERROR: 搜索深链没落到 GlobalSearchActivity"
  exit 2
fi

# ── 2. Video filter ──
if ! "$SCRIPT_DIR/xhs-set-note-filter.sh" --type video >/dev/null 2>&1; then
  log "ERROR: video filter 应用失败"
  exit 2
fi
sleep 1.5

# ── 3. 找第一张视频卡 (时长角标 m:ss 是视频卡的身份证, 角标在缩略图右下 → 往左上偏移进卡身) ──
dump_ui || { log "ERROR: 搜索列表 dump 失败"; exit 2; }
FIRST_CARD=$(python3 - "$TMP_DUMP" <<'PY'
import re, sys
x = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
best = None
for m in re.finditer(r'<node[^>]*text="(\d+:\d\d)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x):
    x1, y1, x2, y2 = map(int, m.groups()[1:])
    cx, cy = (x1+x2)//2, (y1+y2)//2
    if cy > 400:  # 过滤 filter bar 以上区域
        if best is None or cy < best[1]:
            best = (cx, cy)
if best:
    print(best[0]-150, best[1]-200)
PY
)
if [ -z "$FIRST_CARD" ]; then
  log "ERROR: 结果里没有视频卡 (该 kw 无视频或 filter 没生效)"
  exit 1
fi
adb_shell input tap ${=FIRST_CARD}
sleep 3
if ! focus_is DetailFeedActivity; then
  log "ERROR: 点卡片没进 DetailFeedActivity"
  exit 1
fi

# ── 4. 收割循环 ──
GOT=0
RESULTS=""
i=1
while [ "$i" -le "$COUNT" ]; do
  ok=0
  for attempt in 1 2; do
    printf '' | pbcopy 2>/dev/null   # 清空好判断是否真复制到了
    adb_shell input tap "$(gx 925)" "$(gy 2520)"   # 分享按钮 (底栏)
    sleep 2
    dump_ui || true
    CC=$(node_center 'Copy link|复制链接')
    if [ -z "$CC" ]; then
      # 第二行常要左滑一次
      adb_shell input swipe "$(gx 1000)" "$(gy 1465)" "$(gx 400)" "$(gy 1465)" 400
      sleep 1.5
      dump_ui || true
      CC=$(node_center 'Copy link|复制链接')
    fi
    if [ -n "$CC" ]; then
      adb_shell input tap ${=CC}
      sleep 2
      CLIP=$(pbpaste 2>/dev/null || echo "")
      URL=$(echo "$CLIP" | grep -oE 'https?://[^ "]+' | head -1)
      if [ -n "$URL" ]; then
        TITLE=$(echo "$CLIP" | sed -E 's|https?://.*||' | tr '\t\n' '  ' | sed 's/ *$//')
        RESULTS="${RESULTS}${URL}\t${TITLE}\n"
        GOT=$((GOT+1))
        log "✓ [$i/$COUNT] $URL ($TITLE)"
        ok=1
        break
      fi
      log "WARN: [$i/$COUNT] 点了 Copy link 但剪贴板没 URL (attempt $attempt)"
    else
      log "WARN: [$i/$COUNT] 分享面板找不到 Copy link (attempt $attempt)"
      adb_shell input keyevent KEYCODE_BACK   # 关掉可能开着的面板再试
      sleep 1
    fi
  done
  [ "$ok" -eq 0 ] && log "FAIL: 第 $i 条收割失败, 跳过"

  if [ "$i" -lt "$COUNT" ]; then
    # 上滑进下一条 (沉浸流)
    adb_shell input swipe "$(gx 720)" "$(gy 1900)" "$(gx 720)" "$(gy 700)" 300
    sleep 2.5
    if ! focus_is DetailFeedActivity; then
      log "WARN: 上滑后离开了视频流, 提前收工"
      break
    fi
  fi
  i=$((i+1))
done

# ── 5. 退场 + 还原剪贴板 ──
adb_shell input keyevent KEYCODE_BACK; sleep 1
printf '%s' "$PREV_CLIP" | pbcopy 2>/dev/null || true

if [ "$GOT" -eq 0 ]; then
  log "一条都没收到"
  exit 1
fi
if [ -n "$OUT" ]; then
  printf "%b" "$RESULTS" > "$OUT"
  log "✓ $GOT 条已写 $OUT"
else
  printf "%b" "$RESULTS"
fi
exit 0
