#!/usr/bin/env bash
# xhs-fabricate-retro.sh
# When mobile silent-aborts (exits without writing _retro.md), generate one from bundles dir.
# Eliminates the "silent abort" failure mode — every dispatch now produces a retro.
#
# Usage: xhs-fabricate-retro.sh <capture_dir>
# Exit codes:
#   0 = fabricated successfully
#   1 = retro already exists (no-op)
#   2 = no bundles found (can't fabricate, leave STUCK behavior)

set -uo pipefail

CAP_DIR="${1:?Usage: xhs-fabricate-retro.sh <capture_dir>}"
[ -d "$CAP_DIR" ] || { echo "no such dir: $CAP_DIR" >&2; exit 2; }

RETRO="$CAP_DIR/_retro.md"
if [ -s "$RETRO" ]; then
  echo "retro already exists, no-op" >&2
  exit 1
fi

BUNDLES_DIR="$CAP_DIR/bundles"
# v0.16 (2026-07-05): 只数有效 bundle (manifest.json + ≥1 PNG), abort 壳目录不算.
BUNDLE_COUNT=0
for d in "$BUNDLES_DIR"/*/; do
  [ -f "${d}manifest.json" ] && ls "${d}"*.png >/dev/null 2>&1 && BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done

if [ "$BUNDLE_COUNT" -eq 0 ]; then
  echo "no bundles to fabricate from" >&2
  exit 2
fi

PROGRESS_LOG="$CAP_DIR/_progress.log"
TASK_NAME=$(basename "$CAP_DIR")
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Build bundle sections (v0.13: vault-friendly user-perspective format)
BUNDLE_SECTIONS=""
for b in "$BUNDLES_DIR"/*/; do
  name=$(basename "$b")
  [ -f "$b/manifest.json" ] || continue
  ls "$b"*.png >/dev/null 2>&1 || continue  # v0.16: abort 壳目录 (0 图) 跳过
  title=$(jq -r '.title // "无标题"' "$b/manifest.json" 2>/dev/null)
  source_url=$(jq -r '.source_url // ""' "$b/manifest.json" 2>/dev/null)
  pages=$(jq -r '.pages // .page_count // 0' "$b/manifest.json" 2>/dev/null)

  ocr_snippet=""
  if [ -f "$b/ocr.md" ]; then
    ocr_snippet=$(awk '/^## page-01$/{flag=1; next} /^## page-/{flag=0} flag' "$b/ocr.md" 2>/dev/null | grep -v "^[[:space:]]*$" | head -8 | tr -d '\r' | head -c 400)
  fi

  source_line="no source URL"
  if [ -n "$source_url" ]; then
    source_line="$source_url"
  fi

  BUNDLE_SECTIONS="${BUNDLE_SECTIONS}
### $title (${pages}p)
- Source: $source_line
- 核心观点 (OCR 摘要):

$ocr_snippet
"
done

# v0.13: Write user-perspective retro (matches mobile's required format from dispatch.sh)
# Mobile is supposed to write verdict; here we put a placeholder + actual OCR data.
cat > "$RETRO" <<EOF
# Auto-fabricated retro — $TASK_NAME

## 一句话结论

⚠️ 本次 mobile silent abort, conductor 兜底自动综合 $BUNDLE_COUNT 篇笔记. 没法基于 OCR 内容判断一句话 verdict, 看下方笔记摘要自己决定. (如果你看到这行, 说明 mobile prompt-level verdict 步骤没跑成, 应该 retry 任务或 deep mode.)

## 笔记摘要
$BUNDLE_SECTIONS

---

> ⚠️ **此 retro 是 dispatch cleanup auto-fabricate** (mobile 没写). 数据从 bundles 抽取, 未经 mobile 主观判断. 准确性受 OCR 限制.

**Triggered**: $TIMESTAMP
**By**: xhs-fabricate-retro.sh (auto-recovery)
**Bundle count**: $BUNDLE_COUNT

## Progress log (final state)

\`\`\`
$(tail -20 "$PROGRESS_LOG" 2>/dev/null || echo "(no progress log)")
\`\`\`

## Why mobile didn't write retro

T14-T16 都踩: mobile 在 silent abort 后 echo "aborted" + exit 0. Dispatch cleanup 见 exit=0 但无 retro/STUCK → 触发 fabricate. v0.13 加了 enter/captured 比对, 应该能识别撒谎 progress, 但 mobile 还是不写 retro 时这里兜底.
EOF

echo "✅ fabricated retro: $RETRO ($BUNDLE_COUNT bundles)"
exit 0
