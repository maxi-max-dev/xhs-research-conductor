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
[ -s "$CAP_DIR/_retro.md" ] || { echo "no retro: $CAP_DIR/_retro.md" >&2; exit 1; }

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
[ "$BUNDLE_CT" -ge 1 ] || { echo "0 bundles, skip vault" >&2; exit 1; }

# v0.13: Prefer mobile retro's written sections (verdict + 笔记摘要),
# fall back to OCR extraction only when retro is auto-fabricated.

# Extract verdict from retro (mobile is instructed to put it under "## 一句话结论")
VERDICT=""
if grep -q "^## 一句话结论" "$RETRO"; then
  # Read everything between "## 一句话结论" and the next "## " heading
  VERDICT=$(awk '/^## 一句话结论/{flag=1; next} /^## /{flag=0} flag' "$RETRO" | grep -v "^[[:space:]]*$" | head -10)
fi

# Detect if retro was auto-fabricated (mobile silent abort case)
IS_FABRICATED="no"
if grep -q "Auto-fabricated retro" "$RETRO"; then
  IS_FABRICATED="yes"
fi

# Fabricate-style retro fallback verdict
if [ -z "$VERDICT" ]; then
  VERDICT="⚠️ 本次未能从 retro 提取一句话结论 — 看下面笔记摘要自己判断."
fi

# v0.13: Extract 笔记摘要 section directly from retro (mobile wrote it well, no need to re-OCR)
BUNDLES_MD=""
if grep -q "^## 笔记摘要" "$RETRO"; then
  # Read between "## 笔记摘要" and next "## " (skip 工程笔记 / Outcome / etc.)
  BUNDLES_MD=$(awk '/^## 笔记摘要/{flag=1; next} /^## /{flag=0} flag' "$RETRO")
fi

# If no 笔记摘要 section (very old retro / mobile didn't follow template),
# fall back to building from manifests + OCR (kept as last-resort safety net)
if [ -z "$BUNDLES_MD" ]; then
  for b in "$BUNDLES_DIR"/*/; do
    name=$(basename "$b")
    [ -f "$b/manifest.json" ] || continue
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

# AI-generated content warning
AI_WARNING=""
if grep -rq "可能含AI生成内容" "$BUNDLES_DIR"/*/ocr.md 2>/dev/null; then
  AI_WARNING="
> ⚠️ 部分笔记被 XHS 平台标了 \"可能含AI生成内容\", 已在下方列出, 可信度降级."
fi

# Quality stamp
STAMP="signal: $BUNDLE_CT bundle"
if [ "$IS_FABRICATED" = "yes" ]; then
  STAMP="$STAMP (auto-recovered, mobile silent abort)"
fi

# Write vault md
cat > "$VAULT_FILE" <<EOF
---
topic: $TOPIC_CN
date: $DATE_STR
test_id: T$TEST_ID
source: XHS mobile capture (v0.13)
bundles: $BUNDLE_CT
fabricated: $IS_FABRICATED
---

# $TOPIC_CN

## 一句话结论

$VERDICT
$AI_WARNING

## 笔记摘要 ($BUNDLE_CT 篇)
$BUNDLES_MD

## 数据来源

- $STAMP
- 全部采自 XHS, 仅含图文笔记 (vlog 已 filter)
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
