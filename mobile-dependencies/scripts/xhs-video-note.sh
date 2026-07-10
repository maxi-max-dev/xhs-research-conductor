#!/usr/bin/env zsh
# xhs-video-note.sh — 把一条 XHS 视频笔记变成文字稿 bundle (v0.17 视频道地基)
#
# 输入: xhslink.com 短链 / xiaohongshu.com 完整 URL / 分享剪贴板原文 (自动抠 URL)
# 产出: bundle 目录, 内含:
#   manifest.json  — note_id / title / description / uploader / duration / source_url / voice_info
#   transcript.md  — 标题+链接+文字稿 (Whisper, 默认 zh)
#   audio.mp3      — 音轨 (留档)
#
# 链路: URL 解析(短链 curl 跟重定向) → yt-dlp 抽音轨 (无需 cookies, 2026-07-10 实测) →
#       transcribe-file.sh (Groq Whisper) → manifest + transcript 落盘
#
# 用法:
#   xhs-video-note.sh [-o <bundle_dir>] [--no-transcribe] '<url 或 分享文本>'
#
# env:
#   XHS_CAPTURE_ROOT     采集根目录 (默认 = 脚本目录旁 captures/)
#   XHS_TRANSCRIBE_CMD   转录命令 (默认 ~/.openclaw/workspace/scripts/transcribe-file.sh;
#                        找不到则降级为只下载+元数据, manifest 标 transcript=missing)
#   XHS_VIDEO_MAX_SEC    时长上限秒 (默认 900; 超限跳过下载, 只留元数据, 防调研道被长视频卡死)
set -uo pipefail
export LC_ALL=en_US.UTF-8   # cron/launchd 的 C locale 会让 zsh 处理中文/emoji 时炸 "character not in range"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # agent/launchd 环境常缺 homebrew, 裸调 yt-dlp/jq 会撞空

SCRIPT_DIR="${0:A:h}"
CAP_ROOT="${XHS_CAPTURE_ROOT:-$(dirname "$SCRIPT_DIR")/captures}"
TRANSCRIBE_CMD="${XHS_TRANSCRIBE_CMD:-$HOME/.openclaw/workspace/scripts/transcribe-file.sh}"
MAX_SEC="${XHS_VIDEO_MAX_SEC:-900}"

OUT_DIR=""
DO_TRANSCRIBE=1
RAW=""
TITLE_HINT=""   # 收割侧从剪贴板拿到的标题, 只在 yt-dlp 标题抓空时兜底

log() { echo "[xhs-video-note] $*" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --title) TITLE_HINT="${2:-}"; shift 2 ;;
    --no-transcribe) DO_TRANSCRIBE=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) RAW="$RAW $1"; shift ;;
  esac
done

# 1. 从输入抠 URL (分享剪贴板原文是 "标题... http://xhslink.com/... Copy and open rednote")
URL=$(echo "$RAW" | grep -oE 'https?://[^ "]+' | head -1)
if [ -z "$URL" ]; then
  log "ERROR: 输入里没有 URL: $RAW"
  exit 2
fi

# 2. 短链解析成完整 URL (带 xsec_token; bare URL 服务端必 404, 2026-06-06 真踩)
case "$URL" in
  *xhslink.com*)
    EFF=$(curl -Ls -o /dev/null -w '%{url_effective}' --max-time 20 "$URL" 2>/dev/null)
    if [ -z "$EFF" ] || ! echo "$EFF" | grep -q "xiaohongshu.com"; then
      log "ERROR: 短链解析失败: $URL -> ${EFF:-空}"
      exit 3
    fi
    ;;
  *) EFF="$URL" ;;
esac

# 3. yt-dlp 元数据 (实测无需 cookies; 挂了大概率是笔记删了/风控, 报清楚)
#    走临时文件不过 shell 变量: zsh echo 会被 emoji/多字节炸出 "character not in range"
META_FILE=$(mktemp "${TMPDIR:-/tmp}/xhs_video_meta.XXXXXX")
trap 'rm -f "$META_FILE"' EXIT
if ! yt-dlp --no-update -J "$EFF" > "$META_FILE" 2>/dev/null || [ ! -s "$META_FILE" ]; then
  log "ERROR: yt-dlp 拿不到元数据 (笔记已删/风控/网络). URL: $EFF"
  exit 4
fi
NOTE_ID=$(jq -r '.id // "unknown"' "$META_FILE")
TITLE=$(jq -r '.title // "无标题"' "$META_FILE")
# yt-dlp 偶尔抓不到标题, 吐 "XiaoHongShu video #<id>" 兜底名 → 用收割侧标题顶上
case "$TITLE" in
  "XiaoHongShu video"*|无标题)
    [ -n "$TITLE_HINT" ] && TITLE="$TITLE_HINT"
    ;;
esac
DESC=$(jq -r '.description // ""' "$META_FILE")
UPLOADER=$(jq -r '.uploader // .uploader_id // "未知"' "$META_FILE")
DURATION=$(jq -r '.duration // 0' "$META_FILE" | cut -d. -f1)
DURATION="${DURATION:-0}"

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$CAP_ROOT/video-notes/$(date +%Y%m%d-%H%M%S)_${NOTE_ID:0:12}"
fi
mkdir -p "$OUT_DIR"

log "笔记: $TITLE (${DURATION}s, @$UPLOADER)"
log "bundle: $OUT_DIR"

# 4. 时长护栏 (防调研道被 30min 长视频卡死; 单条手动用可用 env 放开)
TRANSCRIPT_STATE="missing"
TRANSCRIPT_CHARS=0
VOICE_INFO="unknown"
if [ "$DURATION" -gt "$MAX_SEC" ]; then
  log "WARN: 时长 ${DURATION}s 超上限 ${MAX_SEC}s, 跳过下载转录 (XHS_VIDEO_MAX_SEC 可放开)"
  TRANSCRIPT_STATE="skipped_too_long"
else
  # 5. 抽音轨
  if ! yt-dlp --no-update -x --audio-format mp3 -o "$OUT_DIR/audio.%(ext)s" "$EFF" >/dev/null 2>&1 \
     || [ ! -s "$OUT_DIR/audio.mp3" ]; then
    log "ERROR: 音轨下载失败. URL: $EFF"
    exit 5
  fi

  # 6. 转录 (Groq Whisper zh; transcribe-file.sh 缺席则降级留元数据)
  if [ "$DO_TRANSCRIBE" -eq 1 ]; then
    if [ -x "$TRANSCRIBE_CMD" ]; then
      if "$TRANSCRIBE_CMD" -l zh -f txt -o "$OUT_DIR" "$OUT_DIR/audio.mp3" >/dev/null 2>&1 \
         && [ -s "$OUT_DIR/audio.txt" ]; then
        TRANSCRIPT_STATE="ok"
        TRANSCRIPT_CHARS=$(LC_ALL=en_US.UTF-8 wc -m < "$OUT_DIR/audio.txt" | tr -d ' ')
        # 纯 BGM/无口播视频 Whisper 会吐空/歌词渣, 标出来别当正文用
        if [ "$TRANSCRIPT_CHARS" -lt 80 ]; then VOICE_INFO="low"; else VOICE_INFO="ok"; fi
      else
        log "WARN: 转录失败, bundle 保留音轨+元数据"
        TRANSCRIPT_STATE="failed"
      fi
    else
      log "WARN: 找不到转录命令 $TRANSCRIBE_CMD, 只留音轨+元数据"
    fi
  fi
fi

# 7. manifest.json (与图文 bundle 的 manifest 同族: source_url + title 必有)
jq -n \
  --arg note_id "$NOTE_ID" --arg title "$TITLE" --arg desc "$DESC" \
  --arg uploader "$UPLOADER" --arg source_url "$URL" --arg url_effective "$EFF" \
  --arg tstate "$TRANSCRIPT_STATE" --arg voice "$VOICE_INFO" \
  --argjson duration "${DURATION:-0}" --argjson tchars "${TRANSCRIPT_CHARS:-0}" \
  '{type:"video", note_id:$note_id, title:$title, description:$desc, uploader:$uploader,
    duration_sec:$duration, source_url:$source_url, url_effective:$url_effective,
    transcript:$tstate, transcript_chars:$tchars, voice_info:$voice,
    harvested_at:(now|localtime|strftime("%Y-%m-%d %H:%M:%S"))}' > "$OUT_DIR/manifest.json"

# 8. transcript.md (给人和 Phase C 读的最终形态)
{
  echo "# $TITLE"
  echo ""
  echo "- 👤 作者: $UPLOADER"
  echo "- ⏱️ 时长: ${DURATION}s"
  echo "- 🔗 链接: $URL"
  if [ -n "$DESC" ]; then
    echo ""
    echo "## 笔记文案"
    echo ""
    echo "$DESC"
  fi
  echo ""
  echo "## 口播文字稿"
  echo ""
  case "$TRANSCRIPT_STATE" in
    ok)
      if [ "$VOICE_INFO" = "low" ]; then
        echo "> ⚠️ 文字稿极短 (${TRANSCRIPT_CHARS} 字), 可能是纯 BGM/字幕视频, 关键信息或在画面里"
        echo ""
      fi
      cat "$OUT_DIR/audio.txt"
      ;;
    skipped_too_long) echo "> ⚠️ 视频 ${DURATION}s 超时长上限, 未转录 (只有元数据)" ;;
    *) echo "> ⚠️ 转录未完成 ($TRANSCRIPT_STATE), 音轨在 bundle 内可手动重跑" ;;
  esac
} > "$OUT_DIR/transcript.md"

log "✓ done: transcript=$TRANSCRIPT_STATE chars=$TRANSCRIPT_CHARS"
echo "$OUT_DIR"
exit 0
