#!/usr/bin/env zsh
# xhs-watchdog.sh (v0.9 — process-aware + TG push)
# 外部 watchdog: 监控 mobile 的 _progress.log + 进程存活, 异常自动写 STUCK.md + 推 Telegram.
# v0.9 修 T14 真踩: mobile silently aborted, progress 卡 5 min 但 watchdog 还在等 stale → 1 小时没发现.
#
# 用法 (conductor 派 mobile 时同时 spawn):
#   ./xhs-watchdog.sh <capture_dir> [mobile_pid] [stale_minutes] [check_interval_seconds]
#   - mobile_pid 可传 "auto" (默认), watchdog 自己 pgrep 找 openclaw agent
#   - mobile_pid 传具体 PID 时, 用 kill -0 精确判断
#
# 行为 (v0.9):
#   - 每 60s 多重 check:
#     a) progress.log 5 min 没变 → STUCK
#     b) mobile 进程没了 (auto-pgrep 或 kill -0) → STUCK (新, T14 真踩)
#     c) 总 timeout 1900s → STUCK
#   - retro / blocker / stuck 文件出现 → exit 0 (mobile 自己结束)
#   - 任一 STUCK 立刻 push Telegram (Friday bot) — v0.9 新
#   - 完成 (retro 出现) 也 push (告诉用户 "done")
set -uo pipefail   # NOTE: no -e, 推送 / pgrep 失败不能终止 watchdog

CAPTURE_DIR="${1:?Usage: xhs-watchdog.sh <capture_dir> [mobile_pid|auto] [stale_minutes] [check_interval]}"
MOBILE_PID="${2:-auto}"
STALE_MIN="${3:-5}"
CHECK_INTERVAL="${4:-60}"

# ========== Telegram push helper (silent on fail) ==========
TG_PUSH="$(dirname "$0")/xhs-tg-push.sh"
TASK_NAME=$(basename "$CAPTURE_DIR")
push_tg() {
  [ -x "$TG_PUSH" ] && "$TG_PUSH" "$1" "$2" 2>/dev/null || true
}

# ========== Mobile alive check ==========
mobile_alive() {
  if [ "$MOBILE_PID" = "auto" ]; then
    pgrep -f "openclaw.*agent.*mobile" >/dev/null 2>&1
  else
    kill -0 "$MOBILE_PID" 2>/dev/null
  fi
}

# ========== Init ==========
[ -d "$CAPTURE_DIR" ] || { echo "$CAPTURE_DIR not found" >&2; exit 2; }

STALE_THRESHOLD=$((STALE_MIN * 60 / CHECK_INTERVAL))
TIMEOUT=${XHS_WATCHDOG_TIMEOUT:-1900}
START=$(date +%s)

PROGRESS_FILE="$CAPTURE_DIR/_progress.log"
STUCK_FILE="$CAPTURE_DIR/STUCK.md"

# Init grace: progress.log 首次出现
# 注意: init 阶段不查 mobile_alive (pgrep race-condition 误报, v0.9 真踩)
# 等 progress.log 出现后才信任 mobile_alive check
INIT_GRACE="${XHS_WATCHDOG_GRACE:-600}"
end_init=$(($(date +%s) + INIT_GRACE))
while [ ! -f "$PROGRESS_FILE" ] && [ $(date +%s) -lt $end_init ]; do
  sleep 10
done
[ -f "$PROGRESS_FILE" ] || {
  cat > "$STUCK_FILE" <<EOF
# STUCK — watchdog init grace timeout
**Triggered**: $(date +"%Y-%m-%d %H:%M:%S")
**Reason**: mobile didn't write _progress.log within ${INIT_GRACE}s
EOF
  push_tg "🚨 $TASK_NAME init timeout" "${INIT_GRACE}s 内 mobile 没写 progress.log"
  exit 3
}

prev_size=$(wc -c < "$PROGRESS_FILE" 2>/dev/null || echo 0)
stale_count=0

push_tg "▶️ $TASK_NAME 开始" "watchdog 监控启动 ($(date +%H:%M:%S))"

# ========== Main loop ==========
while true; do
  # 1. mobile 已结束 (clean)
  if [ -f "$CAPTURE_DIR/_retro.md" ]; then
    BUNDLE_CT=$(find "$CAPTURE_DIR/bundles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    push_tg "✅ $TASK_NAME 完成" "$BUNDLE_CT bundles, retro 已写. 总耗时 $(( ($(date +%s) - START) / 60 )) min"
    exit 0
  fi
  if [ -f "$CAPTURE_DIR/BLOCKER.md" ]; then
    push_tg "⚠️ $TASK_NAME BLOCKER" "mobile escalated. 看 BLOCKER.md"
    exit 0
  fi
  if [ -f "$STUCK_FILE" ]; then
    # mobile 自己写的 STUCK — 也推一下
    push_tg "🚨 $TASK_NAME STUCK (mobile self)" "$(head -20 $STUCK_FILE)"
    exit 0
  fi

  # 2. 总 timeout
  elapsed=$(($(date +%s) - START))
  if [ $elapsed -gt $TIMEOUT ]; then
    cat > "$STUCK_FILE" <<EOF
# STUCK — watchdog timeout
**Triggered**: $(date +"%Y-%m-%d %H:%M:%S")
**Reason**: total session $elapsed s > timeout $TIMEOUT s
progress.log final state:
\`\`\`
$(tail -10 "$PROGRESS_FILE")
\`\`\`
Bundles:
$(find "$CAPTURE_DIR" -name "manifest.json" 2>/dev/null | sed 's/^/  /')
EOF
    push_tg "🚨 $TASK_NAME TIMEOUT" "1900s 上限到, mobile 没完成. 看 STUCK.md"
    exit 0
  fi

  # 3. mobile 进程死了 check (T14 真踩, v0.9 新)
  if ! mobile_alive; then
    cat > "$STUCK_FILE" <<EOF
# STUCK — mobile process disappeared

**Triggered**: $(date +"%Y-%m-%d %H:%M:%S")
**By**: xhs-watchdog.sh (process-aware check, v0.9)
**Reason**: mobile process ($([ "$MOBILE_PID" = "auto" ] && echo "auto-detect openclaw.*mobile" || echo "PID $MOBILE_PID")) no longer alive

This is T14 failure mode: mobile silently exited without writing _retro.md/_BLOCKER.md/STUCK.md.

progress.log final state:
\`\`\`
$(tail -10 "$PROGRESS_FILE")
\`\`\`

Bundles produced before death:
$(find "$CAPTURE_DIR" -name "manifest.json" 2>/dev/null | sed 's/^/  /')

_mobile_run.log tail:
\`\`\`
$(tail -10 "$CAPTURE_DIR/_mobile_run.log" 2>/dev/null || echo "(empty)")
\`\`\`

Conductor should:
1. Salvage partial bundles
2. Re-dispatch if too few bundles
EOF
    BUNDLE_CT=$(find "$CAPTURE_DIR/bundles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    push_tg "🚨 $TASK_NAME mobile 死了" "进程不在了, 只采了 $BUNDLE_CT bundle. 看 STUCK.md, 可能要重跑"
    echo "watchdog: mobile process gone, wrote STUCK.md + pushed TG"
    exit 0
  fi

  # 4. progress.log stale check (老逻辑, 兜底)
  curr_size=$(wc -c < "$PROGRESS_FILE" 2>/dev/null || echo 0)
  if [ "$curr_size" = "$prev_size" ]; then
    stale_count=$((stale_count + 1))
    if [ $stale_count -ge $STALE_THRESHOLD ]; then
      cat > "$STUCK_FILE" <<EOF
# STUCK — watchdog progress stale
**Triggered**: $(date +"%Y-%m-%d %H:%M:%S")
**Reason**: _progress.log unchanged for ${STALE_MIN} min
progress.log final state:
\`\`\`
$(tail -10 "$PROGRESS_FILE")
\`\`\`
Bundles before stale:
$(find "$CAPTURE_DIR" -name "manifest.json" 2>/dev/null | sed 's/^/  /')
EOF
      push_tg "🚨 $TASK_NAME progress 卡住" "${STALE_MIN} min 没新进度, mobile 还活着但没动. 看 STUCK.md"
      exit 0
    fi
  else
    stale_count=0
    prev_size=$curr_size
  fi

  sleep $CHECK_INTERVAL
done
