#!/usr/bin/env bash
# xhs-research-serial.sh (2026-06-07)
#
# Run a multi-keyword XHS research by dispatching ONE mobile-agent run PER
# KEYWORD, serially — each per-kw run kept SMALL so it finishes under the
# ~10min model-request (LLM single-call) timeout.
#
# WHY THIS EXISTS (2026-06-07 真踩):
#   `xhs-research-dispatch.sh --mode deep` packs 5 kw × ≥4 bundle × 20 页 + 评论
#   into ONE `openclaw agent --agent mobile` run (~25 min target). The model
#   provider times out a single agent run around ~10 min → the 6/7 run died at
#   14m25s with tokens 0 (garbage UI-dump output) and the continuation hung with
#   no announce. A single agent run simply cannot do 25 min of continuous
#   tool-calling. Fix = one keyword per agent run, looped serially; each run
#   is small (default target 2 bundle, carousel 6 页, comments on) ≈ 5-7 min.
#
# Usage:
#   xhs-research-serial.sh [--dry-run] [--comments on|off] [--target N] [--pages N] [--mode fast|deep] \
#       <id> <slug> <prefix> "<topic_cn>" "<kw1>" "<kw2>" ...
#
# Example (the 6/7 task, done right):
#   xhs-research-serial.sh --comments on R1 ai-diary aidv "本地隐私AI日记/语音复盘" \
#       "AI日记" "录音转写总结" "本地AI笔记" "AI情绪日记" "录音笔平替"
#
# Each keyword i → :
#   XHS_BUNDLE_TARGET / XHS_CAROUSEL_PAGES / XHS_COMMENTS overrides +
#   xhs-research-dispatch.sh --mode <mode> --force <id>_<i> <slug>-kw<i> <prefix> "<topic>: <kw>" "<kw>"
# dispatch.sh blocks until that mobile run finishes, so the loop is naturally
# serial; dispatch.sh's own singleton check is a second guard against overlap.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY=0
COMMENTS=on
TARGET=2
PAGES=6
MODE=fast
GAP=5

while true; do
  case "${1:-}" in
    --dry-run)  DRY=1; shift ;;
    --comments) COMMENTS="${2:-on}"; shift 2 ;;
    --target)   TARGET="${2:-2}"; shift 2 ;;
    --pages)    PAGES="${2:-6}"; shift 2 ;;
    --mode)     MODE="${2:-fast}"; shift 2 ;;
    --gap)      GAP="${2:-5}"; shift 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 5 ]; then
  echo "Usage: $0 [--dry-run] [--comments on|off] [--target N] [--pages N] [--mode fast|deep] <id> <slug> <prefix> <topic_cn> <kw1> [kw2...]" >&2
  exit 1
fi

ID="$1"; SLUG="$2"; PREFIX="$3"; TOPIC="$4"; shift 4
KWS=("$@")
N=${#KWS[@]}

echo "=== xhs-research-serial: $N keyword(s), mode=$MODE target=$TARGET pages=$PAGES comments=$COMMENTS dry=$DRY ==="
echo "topic: $TOPIC"

i=0
FAIL=0
for kw in "${KWS[@]}"; do
  i=$((i+1))
  kw_slug="$(echo "$kw" | tr ' /' '--')"
  sub_id="${ID}_${i}"
  sub_slug="${SLUG}-kw${i}-${kw_slug}"
  echo
  echo "########## [$i/$N] keyword: $kw ##########"
  if [ "$DRY" -eq 1 ]; then
    echo "DRY: XHS_BUNDLE_TARGET=$TARGET XHS_CAROUSEL_PAGES=$PAGES XHS_COMMENTS=$COMMENTS \\"
    echo "     $SCRIPT_DIR/xhs-research-dispatch.sh --mode $MODE --force $sub_id $sub_slug $PREFIX \"$TOPIC: $kw\" \"$kw\""
    continue
  fi
  XHS_BUNDLE_TARGET="$TARGET" XHS_CAROUSEL_PAGES="$PAGES" XHS_COMMENTS="$COMMENTS" \
    "$SCRIPT_DIR/xhs-research-dispatch.sh" --mode "$MODE" --force "$sub_id" "$sub_slug" "$PREFIX" "$TOPIC: $kw" "$kw"
  rc=$?
  echo "[$i/$N] keyword '$kw' dispatch exit=$rc"
  [ "$rc" -ne 0 ] && FAIL=$((FAIL+1))
  # let the emulator settle between runs
  [ "$i" -lt "$N" ] && sleep "$GAP"
done

echo
echo "=== serial run done. $((N-FAIL))/$N keywords dispatched cleanly. capture dirs: ==="
ls -d "${XHS_CAPTURE_ROOT:-$(dirname "$SCRIPT_DIR")/captures}/$(date +%Y-%m-%d)-${SLUG}-kw"* 2>/dev/null || echo "(none — check logs)"
echo "=== bundles per kw ==="
for d in "${XHS_CAPTURE_ROOT:-$(dirname "$SCRIPT_DIR")/captures}/$(date +%Y-%m-%d)-${SLUG}-kw"*/; do
  [ -d "$d" ] || continue
  bc=$(find "$d/bundles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  echo "  $(basename "$d"): $bc bundle(s)"
done

exit "$FAIL"
