#!/usr/bin/env bash
# xhs-vault-history-check.sh (v0.14, R1)
#
# Pre-dispatch check: 在 vault 里 grep 同主题已有报告.
# 找到 + 在 freshness window 内 → exit 0 + print 报告 path (调用方决定是否复用).
# 没找到 / 过期 → exit 1.
#
# 设计目的 (5/20 某公司笔试踩坑):
# - 用户问 "调研 X", skill 默认全量重跑 7 min, 不查 vault 已有报告
# - 实际 5/14 已经有某公司 16KB 详细报告 (deep + 多源), 比 v0.13 fast 还全
# - 这一步把 "查历史" 前置, 避免无谓重跑
#
# Usage: xhs-vault-history-check.sh <topic_cn> [topic_slug]
# Output (on success): tab-separated lines: <path>\t<age_days>\t<size_bytes>
# Exit codes:
#   0 = found ≥1 report within freshness window
#   1 = no report found / all expired
#   2 = vault not accessible

set -uo pipefail

TOPIC_CN="${1:?Usage: xhs-vault-history-check.sh <topic_cn> [slug]}"
TOPIC_SLUG="${2:-}"

VAULT="${VAULT_ROOT:-$HOME/Documents/xhs-research-reports}"
[ -d "$VAULT" ] || { echo "vault not found: $VAULT" >&2; exit 2; }

# Freshness window by topic type heuristic (days)
# - 笔试/面试: 半年 (题型/流程稳定)
# - 工具评测/产品: 3 月 (版本更新快)
# - 时事/价格: 1 周
# - default: 1 月
freshness_days() {
  case "$TOPIC_CN" in
    *笔试*|*面试*|*面经*|*校招*|*实习*|*简历*) echo 180 ;;
    *评测*|*体验*|*vs*|*对比*|*选哪个*|*好用*|*缺点*) echo 90 ;;
    *价格*|*降价*|*今天*|*最近*|*现在*) echo 7 ;;
    *) echo 30 ;;
  esac
}

WINDOW=$(freshness_days)

# Search keywords: split TOPIC_CN by spaces, also use slug if provided
KWS=()
for w in $TOPIC_CN; do
  # only keep words ≥ 2 chars (skip "vs" / "的" etc but keep meaningful CJK terms)
  [ ${#w} -ge 2 ] && KWS+=("$w")
done
[ -n "$TOPIC_SLUG" ] && KWS+=("$TOPIC_SLUG")

# If no usable keywords, abort
[ ${#KWS[@]} -gt 0 ] || { echo "no usable keywords from topic: $TOPIC_CN" >&2; exit 1; }

# Search vault: PRIMARY keyword anchor.
# First word in topic is typically the proper noun (某公司 / AirPods / Notion).
# Match by filename only — content match is expensive + introduces false positives.
# This catches related reports (e.g. "某公司 笔试" → also surfaces "某公司 面试准备")
# which is useful: user often wants to see existing context, not just exact match.
PRIMARY_KW="${KWS[0]}"
FOUND=$(find "$VAULT" -type f -name "*.md" \
  -not -path "*/归档/*" -not -path "*/🗂️归档/*" -not -path "*/_archive/*" \
  -iname "*${PRIMARY_KW}*" 2>/dev/null)

# Dedupe + filter by mtime within window
if [ -n "$FOUND" ]; then
  NOW=$(date +%s)
  RESULTS=""
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0)
    [ "$mtime" -gt 0 ] || continue
    age_days=$(( (NOW - mtime) / 86400 ))
    if [ "$age_days" -le "$WINDOW" ]; then
      size=$(wc -c < "$path" | tr -d ' ')
      RESULTS="${RESULTS}${path}	${age_days}d	${size}B
"
    fi
  done <<< "$FOUND"

  # Dedupe + sort by size desc (biggest report first, likely most comprehensive)
  if [ -n "$RESULTS" ]; then
    echo "$RESULTS" | sort -u | awk -F'\t' 'NF>=3' | sort -t'\t' -k3 -rn
    exit 0
  fi
fi

# No report found within window
echo "no vault report for '$TOPIC_CN' within ${WINDOW} days" >&2
exit 1
