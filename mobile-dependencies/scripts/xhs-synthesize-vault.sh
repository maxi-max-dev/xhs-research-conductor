#!/usr/bin/env bash
# xhs-synthesize-vault.sh (v0.13, P4)
#
# Auto-synthesize a vault-ready report from a capture dir.
# Triggered by dispatch.sh cleanup after _retro.md is written.
#
# Goals (ship-to-C):
#   - User installs skill on fresh machine, runs dispatch, gets vault md
#     without any Claude / conductor intervention.
#   - Report meets user's 2 requirements:
#       1. Simple UI: verdict on first line
#       2. Source-traceable: every bundle has xhslink URL
#
# Strategy:
#   - Read _retro.md (whether mobile-written or fabricated)
#   - Extract verdict from first non-empty markdown section (mobile is told to write it)
#   - Extract bundles list (title + source_url + content summary)
#   - Render fixed-template vault md with frontmatter
#   - Copy to $VAULT_ROOT/<emoji-folder>/<topic>/<topic>_<date>.md
#
# Usage: xhs-synthesize-vault.sh <capture_dir> <topic_cn> <topic_slug> <test_id>
# Exit codes:
#   0 = vault md written
#   1 = no retro / capture dir empty (skip silently)
#   2 = no VAULT_ROOT env / vault unwritable
#
set -uo pipefail

CAP_DIR="${1:?Usage: xhs-synthesize-vault.sh <cap_dir> <topic_cn> <topic_slug> <test_id>}"
TOPIC_CN="${2:?topic_cn required}"
TOPIC_SLUG="${3:?topic_slug required}"
TEST_ID="${4:?test_id required}"

[ -d "$CAP_DIR" ] || { echo "no such dir: $CAP_DIR" >&2; exit 1; }

# v0.17: 视频 bundle (manifest type=video, 无 PNG) 单独计数
VIDEO_CT=0
for _d in "$CAP_DIR"/bundles/*/; do
  [ -f "${_d}manifest.json" ] || continue
  [ "$(jq -r '.type // ""' "${_d}manifest.json" 2>/dev/null)" = "video" ] && VIDEO_CT=$((VIDEO_CT + 1))
done

# v0.17: 没 retro 但视频道有产出也出报告 (纯视频主题的边界情况)
if [ ! -s "$CAP_DIR/_retro.md" ] && [ "$VIDEO_CT" -eq 0 ]; then
  echo "no retro: $CAP_DIR/_retro.md" >&2; exit 1
fi

VAULT="${VAULT_ROOT:-$HOME/Documents/xhs-research-reports}"
mkdir -p "$VAULT" 2>/dev/null || { echo "vault unwritable: $VAULT (set VAULT_ROOT env)" >&2; exit 2; }

DATE_STR=$(date +%Y-%m-%d)
BUNDLES_DIR="$CAP_DIR/bundles"
RETRO="$CAP_DIR/_retro.md"

# Decide vault folder by simple keyword heuristic.
# v0.16.3 — fully user-selectable output:
#   VAULT_ROOT        = report root dir (auto-created)
#   VAULT_FOLDER      = exact subfolder, overrides everything
#   XHS_FOLDER_STYLE  = plain (default: career/ | reviews/) | emoji (💼Career/ | 📚学习/工具评测/,
#                       matches an Obsidian emoji-vault layout) | flat (no subfolder)
XHS_FOLDER_STYLE="${XHS_FOLDER_STYLE:-plain}"
classify_folder() {
  local topic="$1" kind="reviews"
  case "$topic" in
    *笔试*|*面经*|*面试*|*校招*|*秋招*|*实习*|*offer*|*简历*) kind="career" ;;
  esac
  case "$XHS_FOLDER_STYLE" in
    flat)  echo "" ;;
    emoji) [ "$kind" = "career" ] && echo "💼Career/$TOPIC_CN" || echo "📚学习/工具评测/$TOPIC_CN" ;;
    *)     echo "$kind/$TOPIC_CN" ;;
  esac
}

VAULT_SUBFOLDER="${VAULT_FOLDER:-$(classify_folder "$TOPIC_CN")}"
VAULT_DIR="$VAULT/$VAULT_SUBFOLDER"
mkdir -p "$VAULT_DIR" || { echo "mkdir failed: $VAULT_DIR" >&2; exit 2; }
VAULT_FILE="$VAULT_DIR/${TOPIC_CN}_${DATE_STR}.md"

# Count valid bundles (v0.16.1: manifest + ≥1 PNG 才算, 和 dispatch/fabricate 同口径 —
# T30 真踩: 裸目录计数让 frontmatter 写 bundles: 3 而正文只有 2 篇)
BUNDLE_CT=0
for _d in "$BUNDLES_DIR"/*/; do
  [ -f "${_d}manifest.json" ] && ls "${_d}"*.png >/dev/null 2>&1 && BUNDLE_CT=$((BUNDLE_CT + 1))
done
# v0.17: 图文 0 但视频 ≥1 也出报告
if [ "$BUNDLE_CT" -eq 0 ] && [ "$VIDEO_CT" -eq 0 ]; then
  echo "0 bundles, skip vault" >&2; exit 1
fi

# v0.13: Prefer mobile retro's written sections (verdict + 笔记摘要),
# fall back to OCR extraction only when retro is auto-fabricated.

# Extract verdict from retro (mobile is instructed to put it under "## 一句话结论")
VERDICT=""
if grep -q "^## 一句话结论" "$RETRO" 2>/dev/null; then
  # Read everything between "## 一句话结论" and the next "## " heading
  VERDICT=$(awk '/^## 一句话结论/{flag=1; next} /^## /{flag=0} flag' "$RETRO" | grep -v "^[[:space:]]*$" | head -10)
fi

# Detect if retro was auto-fabricated (mobile silent abort case)
IS_FABRICATED="no"
if grep -q "Auto-fabricated retro" "$RETRO" 2>/dev/null; then
  IS_FABRICATED="yes"
fi

# Fabricate-style retro fallback verdict
if [ -z "$VERDICT" ]; then
  if [ ! -s "$RETRO" ] && [ "$VIDEO_CT" -ge 1 ]; then
    VERDICT="⚠️ 本次仅视频道有产出 (图文流没跑成), 结论看下方 🎬 视频文字稿自己判断."
  else
    VERDICT="⚠️ 本次未能从 retro 提取一句话结论 — 看下面笔记摘要自己判断."
  fi
fi

# v0.13: Extract 笔记摘要 section directly from retro (mobile wrote it well, no need to re-OCR)
BUNDLES_MD=""
if grep -q "^## 笔记摘要" "$RETRO" 2>/dev/null; then
  # Read between "## 笔记摘要" and next "## " (skip 工程笔记 / Outcome / etc.)
  BUNDLES_MD=$(awk '/^## 笔记摘要/{flag=1; next} /^## /{flag=0} flag' "$RETRO")
fi

# If no 笔记摘要 section (very old retro / mobile didn't follow template),
# fall back to building from manifests + OCR (kept as last-resort safety net)
if [ -z "$BUNDLES_MD" ]; then
  for b in "$BUNDLES_DIR"/*/; do
    name=$(basename "$b")
    [ -f "$b/manifest.json" ] || continue
    # v0.17: 视频 bundle 走独立的 🎬 节, 不进图文摘要
    [ "$(jq -r '.type // ""' "$b/manifest.json" 2>/dev/null)" = "video" ] && continue
    title=$(jq -r '.title // "无标题"' "$b/manifest.json" 2>/dev/null)
    source_url=$(jq -r '.source_url // ""' "$b/manifest.json" 2>/dev/null)
    pages=$(jq -r '.pages // .page_count // 0' "$b/manifest.json" 2>/dev/null)

    # Fallback: skip UI header lines (time / nav bar / decorative tokens)
    # Take lines starting from first line with ≥10 CJK chars (likely body text)
    ocr_snippet=""
    if [ -f "$b/ocr.md" ]; then
      ocr_snippet=$(awk '/^## page-01$/{flag=1; next} /^## page-/{flag=0} flag' "$b/ocr.md" 2>/dev/null \
        | grep -v "^[[:space:]]*$" \
        | awk 'NR>2 && length>20' \
        | head -5 | tr -d '\r')
    fi

    if [ -n "$source_url" ]; then
      BUNDLES_MD="${BUNDLES_MD}
### [${title}](${source_url}) (${pages}p)

${ocr_snippet}
"
    else
      BUNDLES_MD="${BUNDLES_MD}
### ${title} (${pages}p, no source URL)

> source_url 抓取失败, 笔记本身仍可信

${ocr_snippet}
"
    fi
  done
fi

# v0.17: 🎬 视频笔记节 — 标题+链接+口播文字稿摘录 (Whisper 自动转录, 原样摘录不代综合)
VIDEOS_MD=""
if [ "$VIDEO_CT" -ge 1 ]; then
  for b in "$BUNDLES_DIR"/*/; do
    [ -f "$b/manifest.json" ] || continue
    [ "$(jq -r '.type // ""' "$b/manifest.json" 2>/dev/null)" = "video" ] || continue
    v_title=$(jq -r '.title // "无标题"' "$b/manifest.json")
    v_url=$(jq -r '.source_url // ""' "$b/manifest.json")
    v_dur=$(jq -r '.duration_sec // 0' "$b/manifest.json")
    v_voice=$(jq -r '.voice_info // "unknown"' "$b/manifest.json")
    v_state=$(jq -r '.transcript // "missing"' "$b/manifest.json")
    # 摘录口播前 160 字 (python 切, 避免 cut -c 撕 UTF-8)
    v_excerpt=""
    if [ "$v_state" = "ok" ] && [ -f "$b/transcript.md" ]; then
      v_excerpt=$(awk '/^## 口播文字稿/{flag=1; next} flag' "$b/transcript.md" \
        | grep -v '^>' | grep -v '^[[:space:]]*$' \
        | python3 -c 'import sys; t=sys.stdin.read().strip(); print(t[:160] + ("……" if len(t)>160 else ""))' 2>/dev/null)
    fi
    VIDEOS_MD="${VIDEOS_MD}
### 🎬 [${v_title}](${v_url}) (${v_dur}s)
"
    if [ "$v_voice" = "low" ]; then
      VIDEOS_MD="${VIDEOS_MD}
> ⚠️ 口播极少 (可能纯 BGM/字幕视频), 关键信息或在画面里, 文字稿仅供参考
"
    fi
    if [ -n "$v_excerpt" ]; then
      VIDEOS_MD="${VIDEOS_MD}
${v_excerpt}

(完整文字稿: \`$(basename "$b")/transcript.md\`)
"
    else
      VIDEOS_MD="${VIDEOS_MD}
> ⚠️ 无文字稿 ($v_state), 只有元数据
"
    fi
  done
fi

# AI-generated content warning
AI_WARNING=""
if grep -rq "可能含AI生成内容" "$BUNDLES_DIR"/*/ocr.md 2>/dev/null; then
  AI_WARNING="
> ⚠️ 部分笔记被 XHS 平台标了 \"可能含AI生成内容\", 已在下方列出, 可信度降级."
fi

# Quality stamp
STAMP="signal: $BUNDLE_CT bundle"
[ "$VIDEO_CT" -ge 1 ] && STAMP="$STAMP + $VIDEO_CT video"
if [ "$IS_FABRICATED" = "yes" ]; then
  STAMP="$STAMP (auto-recovered, mobile silent abort)"
fi

# v0.17: 视频节 (有才渲染) + 数据来源口径按实际产出写
VIDEOS_SECTION=""
if [ "$VIDEO_CT" -ge 1 ]; then
  VIDEOS_SECTION="
## 🎬 视频笔记 ($VIDEO_CT 条, 口播已转文字)
$VIDEOS_MD"
  SOURCE_SCOPE="图文笔记 (截图+OCR) + 视频笔记 (yt-dlp 音轨 + Whisper 转文字)"
else
  SOURCE_SCOPE="仅含图文笔记 (vlog 已 filter; 要视频加 --videos N)"
fi

# Write vault md
cat > "$VAULT_FILE" <<EOF
---
topic: $TOPIC_CN
date: $DATE_STR
test_id: T$TEST_ID
source: XHS mobile capture (v0.17)
bundles: $BUNDLE_CT
videos: $VIDEO_CT
fabricated: $IS_FABRICATED
---

# $TOPIC_CN

## 一句话结论

$VERDICT
$AI_WARNING

## 笔记摘要 ($BUNDLE_CT 篇)
$BUNDLES_MD
$VIDEOS_SECTION

## 数据来源

- $STAMP
- 全部采自 XHS, $SOURCE_SCOPE
- 采集时间: $DATE_STR
- Capture dir: \`$CAP_DIR\`
- 想要更深: 复跑加 \`--mode deep\` (5 kw, 15-30 min)

## 想填补的 Coverage Gap

XHS 角度看不到的话题, 建议换源:
- 视频长评测 → B 站
- 价格变化 / 渠道差价 → 什么值得买
- 长期使用 (1 年+) → 知乎
- 海外/英文反馈 → reddit / YouTube
EOF

echo "✅ vault synthesized: $VAULT_FILE"
exit 0
