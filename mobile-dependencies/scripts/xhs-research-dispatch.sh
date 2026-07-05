#!/usr/bin/env bash
# xhs-research-dispatch.sh (v0.13, fast/deep 双模 + startup self-check + enter/captured verify + auto-synthesize vault)
#
# 一个原子化的 dispatch — 跑完一次完整的 conductor session:
#   1. 单例检查: 已有 mobile 跑则 reject (T14 真踩: 2 mobile 并发竞态 → progress.log 互相覆盖)
#   2. 显式 PID: spawn 后立即抓 $!, 传给 watchdog (避免 pgrep race)
#   3. 监控 + TG: watchdog v0.9 进程感知 + 全程 TG 推 (start/bundle/stuck/done)
#   4. 清理 trap: 任何退出路径 (Ctrl-C / kill / error / done) 都 kill watchdog + 最后 push
#
# v0.11 mode:
#   fast (默认): 3 kw × 1 bundle, carousel 4 页 cap, skip 评论. 约 5-10 min.
#   deep:        5 kw × ≥4 bundle, carousel 20 页, 抓评论. 约 15-30 min.
#
# 用法:
#   xhs-research-dispatch.sh [--mode fast|deep] <test_id> <topic_slug> <bundle_prefix> "<topic_chinese>" "<kw1>" ... "<kwN>"
#
# 例子:
#   # fast (3 kw)
#   xhs-research-dispatch.sh 21 airpods4 ap4 "AirPods 4 值不值得" \
#     "AirPods 4 评测" "AirPods 4 缺点" "AirPods 4 vs Pro"
#
#   # deep (5 kw)
#   xhs-research-dispatch.sh --mode deep 22 city-food ctf "某城市 中餐外卖" \
#     "某城市 中餐 外卖" "某城市 中餐" "某城市 中国菜" "某城市 川菜" "某城市 餐厅推荐"
#
# 退出码:
#   0 = mobile 完成 (retro.md 存在)
#   2 = singleton check 失败 (已有 mobile 在跑)
#   3 = STUCK (watchdog 触发)
#   其他 = openclaw agent error

set -uo pipefail   # NOTE: no -e, 推送失败不能终止 dispatch

# ========== Args ==========
MODE="fast"
FORCE=0
while true; do
  case "${1:-}" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) break ;;
  esac
done
if [ "$MODE" != "fast" ] && [ "$MODE" != "deep" ]; then
  echo "❌ --mode must be fast or deep, got: '$MODE'" >&2
  exit 1
fi

if [ $# -lt 5 ]; then
  echo "Usage: $0 [--mode fast|deep] [--force] <test_id> <topic_slug> <bundle_prefix> <topic_chinese> <kw1>...[kwN]" >&2
  exit 1
fi

TEST_ID="$1"
TOPIC_SLUG="$2"
BUNDLE_PREFIX="$3"
TOPIC_CN="$4"
shift 4
KWS=("$@")
KW_COUNT=${#KWS[@]}

# Mode-specific caps
if [ "$MODE" = "fast" ]; then
  CAROUSEL_PAGES=4
  BUNDLE_TARGET=3
  KW_MAX=3
  COMMENTS_DIRECTIVE="⛔ fast mode: **跳过评论 extraction** — 不跑 \$SCRIPTS_DIR/xhs-extract-comments.sh (用户要快, 评论靠 OCR 第一屏判断够了)"
else
  CAROUSEL_PAGES=20
  BUNDLE_TARGET=4
  KW_MAX=5
  COMMENTS_DIRECTIVE="⭐ deep mode: 每个 bundle OCR 完后跑 \$SCRIPTS_DIR/xhs-extract-comments.sh \$CAP_DIR/bundles/<bundle>/comments.json 抓评论"
fi

if [ "$KW_COUNT" -gt "$KW_MAX" ]; then
  echo "❌ $MODE mode allows max $KW_MAX kw, got $KW_COUNT. 砍 kw 或换 --mode deep." >&2
  exit 1
fi

DATE_STR=$(date +%Y-%m-%d)
# v0.16.3 portable paths: scripts dir = where this file lives; captures next to it.
# On an OpenClaw install this resolves to the exact old paths; env overrides win.
SCRIPTS_DIR="${XHS_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CAP_ROOT="${XHS_CAPTURE_ROOT:-$(dirname "$SCRIPTS_DIR")/captures}"
CAP_DIR="$CAP_ROOT/${DATE_STR}-${TOPIC_SLUG}"

# ========== Phase 0: Vault history check (v0.14, R1+R2) ==========
# 5/20 某公司笔试真踩: vault 早已有 16KB 详细报告 (deep + 多源), 但 skill
# 默认全量重跑 7 min, 浪费时间且产出更差. v0.14 加 history check, 找到
# 同主题报告就短路 + 提示用户用现成的; 用户真要重跑加 --force.
if [ "$FORCE" -eq 0 ]; then
  EXISTING=$("$SCRIPTS_DIR/xhs-vault-history-check.sh" "$TOPIC_CN" "$TOPIC_SLUG" 2>/dev/null || true)
  if [ -n "$EXISTING" ]; then
    EXISTING_TOP=$(echo "$EXISTING" | head -1)
    echo "♻️ vault 已有同主题报告 (在 freshness window 内):"
    echo "$EXISTING" | head -5
    echo ""
    echo "默认行为: skip dispatch, 用现成报告. 真要重跑请加 --force"
    "$SCRIPTS_DIR/xhs-tg-push.sh" "♻️ T${TEST_ID} ${TOPIC_SLUG} skip dispatch" "vault 已有同主题报告: $(echo "$EXISTING_TOP" | awk -F'\t' '{print $1}')" 2>/dev/null || true
    exit 0
  fi
fi

# ========== Singleton check (T14 真踩) ==========
# 用 process name (-x) 匹配, 避免 pgrep -f 误抓自己 (脚本 message 里有 openclaw 字串)
EXISTING_PIDS=$(pgrep -x "openclaw" 2>/dev/null; pgrep -x "openclaw-agent" 2>/dev/null)
# Exclude this script's PID and parent PID
EXISTING_PIDS=$(echo "$EXISTING_PIDS" | grep -v "^$$\$" | grep -v "^$PPID\$" | grep -v "^\$" || true)
# Further filter: only count mobile-worker processes (have -m flag or "mobile" in cmdline)
REAL_MOBILE_PIDS=""
for pid in $EXISTING_PIDS; do
  if ps -p $pid -o args= 2>/dev/null | grep -qE "agent.*mobile|--agent mobile"; then
    REAL_MOBILE_PIDS="$REAL_MOBILE_PIDS $pid"
  fi
done
if [ -n "$REAL_MOBILE_PIDS" ]; then
  echo "❌ singleton check failed: another mobile worker already running: $REAL_MOBILE_PIDS"
  echo "   kill them first: kill $REAL_MOBILE_PIDS"
  "$SCRIPTS_DIR/xhs-tg-push.sh" "❌ T${TEST_ID} dispatch rejected" "已有 mobile PIDs: $REAL_MOBILE_PIDS" 2>/dev/null || true
  exit 2
fi

# ========== Defensive start cleanup (v0.14) ==========
# 防御性: 上次 task 可能因为 Ctrl-C / 异常没跑到 trap cleanup, 留下 XHS 或 Chrome
# 残留 (Chrome 滞留在旧 xhslink gateway 是真踩, 下次 mobile 误触上一页).
"$SCRIPTS_DIR/xhs-cleanup.sh" 2>/dev/null || true

# ========== Setup ==========
mkdir -p "$CAP_DIR/bundles"

# Build kw list for PLAN
KW_PLAN=""
for kw in "${KWS[@]}"; do
  KW_PLAN="${KW_PLAN}, ${kw}"
done
KW_PLAN="${KW_PLAN#, }"

cat > "$CAP_DIR/PLAN.md" <<EOF
# PLAN — ${TOPIC_CN} (Test ${TEST_ID}, v0.13 dispatch, mode=${MODE})

${KW_COUNT} kw: ${KW_PLAN}
bundle prefix: ${BUNDLE_PREFIX}
mode: ${MODE} (target ${BUNDLE_TARGET} bundle, carousel ${CAROUSEL_PAGES} 页 cap, comments=$([ "$MODE" = "fast" ] && echo skip || echo on))
v0.8 filter mandatory + v0.9 TG per-bundle + singleton enforcement + v0.10 URL capture + v0.11 mode caps + v0.12 startup self-check + v0.13 captured-verify + auto vault
EOF

# v0.16 (2026-07-05): 有效 bundle = 有 manifest.json 且 ≥1 PNG. abort 在 reset 阶段
# 的壳目录 (只有 status=aborted 的 manifest, 0 图) 不算, 防止"报告显示 3 条实际 1 条".
valid_bundle_count() {
  local ct=0 d
  for d in "$CAP_DIR"/bundles/*/; do
    [ -f "${d}manifest.json" ] && ls "${d}"*.png >/dev/null 2>&1 && ct=$((ct + 1))
  done
  echo "$ct"
}

# ========== Cleanup trap ==========
WD_PID=""
MOB_PID=""
cleanup() {
  local exit_code=$?
  echo "cleanup: exit=$exit_code"
  [ -n "$WD_PID" ] && kill "$WD_PID" 2>/dev/null

  # v0.13 enter vs captured 比对 (T23 真踩: mobile 写 "enter X" 但实际没 capture, 撒谎 progress)
  if [ -f "$CAP_DIR/_progress.log" ]; then
    ENTERED=$(grep -c "^\[.*\] enter " "$CAP_DIR/_progress.log" 2>/dev/null || echo 0)
    CAPTURED=$(grep -c "^\[.*\] captured " "$CAP_DIR/_progress.log" 2>/dev/null || echo 0)
    LIE_COUNT=$((ENTERED - CAPTURED))
    if [ "$LIE_COUNT" -gt 0 ]; then
      echo "[cleanup] WARN: $LIE_COUNT enter 行无对应 captured 行 (mobile silent capture failure)" >> "$CAP_DIR/_progress.log"
    fi
  fi

  # v0.16.1 OCR salvage (T30 真踩): mobile 撞 ~10min 单请求墙死在 kw 中途时,
  # bundle 里往往已有 manifest+PNG 只差 ocr.md. OCR 是本地 tesseract 几秒的事,
  # 没理由跟着 agent 一起死 —— cleanup 补跑, 让截断数据也进报告.
  for _d in "$CAP_DIR"/bundles/*/; do
    if ls "${_d}"*.png >/dev/null 2>&1 && [ ! -s "${_d}ocr.md" ]; then
      echo "cleanup: OCR salvage on $(basename "$_d")"
      "$SCRIPTS_DIR/xhs-ocr-bundle.sh" "${_d%/}" >/dev/null 2>&1 || true
    fi
  done

  # v0.9 patch: auto-fabricate retro if mobile silent-aborted
  # 2026-07-05 fix: 不再被 STUCK.md 短路 —— watchdog 写过 STUCK 但 agent 后来自愈
  # 恢复继续采 (adb 掉线重启场景) 时, 旧条件会跳过 fabricate → 好 bundle 白采且 exit 0.
  # 只要没 retro 且有 ≥1 bundle 就兜底 fabricate.
  if [ ! -s "$CAP_DIR/_retro.md" ]; then
    BUNDLE_CT=$(valid_bundle_count)
    if [ "$BUNDLE_CT" -ge 1 ]; then
      echo "cleanup: no retro from mobile, fabricating from $BUNDLE_CT valid bundles"
      "$SCRIPTS_DIR/xhs-fabricate-retro.sh" "$CAP_DIR" || true
    fi
  fi

  # v0.13 auto-synthesize vault report (P4: ship-C 必需, 陌生人没 Claude 帮合成)
  if [ -s "$CAP_DIR/_retro.md" ]; then
    "$SCRIPTS_DIR/xhs-synthesize-vault.sh" "$CAP_DIR" "$TOPIC_CN" "$TOPIC_SLUG" "$TEST_ID" 2>&1 | head -20 || true
  fi

  # Last-mile TG push
  if [ -s "$CAP_DIR/_retro.md" ]; then
    BUNDLE_CT=$(valid_bundle_count)
    if grep -q "Auto-fabricated retro" "$CAP_DIR/_retro.md"; then
      "$SCRIPTS_DIR/xhs-tg-push.sh" "♻️ T${TEST_ID} ${TOPIC_SLUG} 完成 (auto-recovered)" "$BUNDLE_CT bundle, mobile silent abort 后 conductor 兜底 fabricate retro" 2>/dev/null || true
    else
      "$SCRIPTS_DIR/xhs-tg-push.sh" "✅ T${TEST_ID} ${TOPIC_SLUG} 完成 (clean)" "$BUNDLE_CT bundle, mobile 主动写了 retro" 2>/dev/null || true
    fi
  elif [ -s "$CAP_DIR/STUCK.md" ]; then
    "$SCRIPTS_DIR/xhs-tg-push.sh" "🚨 T${TEST_ID} ${TOPIC_SLUG} STUCK" "exit=$exit_code, 看 STUCK.md" 2>/dev/null || true
  else
    "$SCRIPTS_DIR/xhs-tg-push.sh" "❌ T${TEST_ID} ${TOPIC_SLUG} 0 bundle" "exit=$exit_code, mobile 啥都没采到" 2>/dev/null || true
  fi

  # v0.14 end-of-task cleanup: 关掉 XHS + Chrome, 不留状态给下次 task.
  # 修 Bug 1 (XHS 不自动关, 下次搜索撞旧界面) + Bug 2 (Chrome tab 累积, 下次 tap 撞上一页 gateway).
  "$SCRIPTS_DIR/xhs-cleanup.sh" 2>/dev/null || true

  exit $exit_code
}
trap cleanup EXIT INT TERM

# ========== Build mobile message ==========
KW_LIST_FMT=""
for i in "${!KWS[@]}"; do
  KW_LIST_FMT="${KW_LIST_FMT}\n${i}. ${KWS[$i]}"
done

MSG=$(cat <<MSGEND
任务: ${TOPIC_CN} (Test ${TEST_ID}, v0.13 dispatch, **mode=${MODE}**)

🔴🔴🔴 启动第一动作 (MANDATORY, 在 fire 任何 kw 之前 — T21 真踩: gateway timeout 触发 embedded fallback → 整任务重跑):

1. 跑命令 (v0.16: 只数有效 bundle = 有 manifest.json 且 ≥1 PNG, 半成品/abort 壳目录不算 — T28 真踩):
   BUNDLE_CT=\$(for d in $CAP_DIR/bundles/*/; do [ -f "\$d/manifest.json" ] && ls "\$d"*.png >/dev/null 2>&1 && echo 1; done 2>/dev/null | wc -l | tr -d ' ')
   echo "[startup] existing valid bundles: \$BUNDLE_CT" >> $CAP_DIR/_progress.log

2. 如果 \$BUNDLE_CT >= ${BUNDLE_TARGET}: 这是 fallback resume 场景, 之前 session 已采集完
   - 跑: $SCRIPTS_DIR/xhs-fabricate-retro.sh $CAP_DIR
   - 跑 TG: $SCRIPTS_DIR/xhs-tg-push.sh "♻️ T${TEST_ID} ${TOPIC_SLUG} resume" "self-check: 已有 \$BUNDLE_CT bundle, 直接 retro, 不重跑"
   - 立即 exit 0, **绝对禁止**重跑任何 kw

3. 如果 0 < \$BUNDLE_CT < ${BUNDLE_TARGET}: 上次跑了一半, 接力跑缺的部分
   - 把已 capture 过的 keyword 在 _progress.log 里 grep "enter ${BUNDLE_PREFIX}_" 找出来 (取已存在 bundle 对应的 kw idx)
   - 从下一个 kw 开始跑, **不要**重跑已有 bundle 对应的 kw
   - 新 bundle 命名沿用 ${BUNDLE_PREFIX}_<X>_<Y> (不要换 prefix)

4. 如果 \$BUNDLE_CT = 0: 正常 fresh 跑全流程

⚡️ Mode caps (v0.12):
  - mode: ${MODE}
  - kw 数: ${KW_COUNT} (上限 ${KW_MAX})
  - 目标 bundle: ≥ ${BUNDLE_TARGET}
  - carousel 每 bundle 最多: ${CAROUSEL_PAGES} 页
  - 评论: ${COMMENTS_DIRECTIVE}

🔥🔥🔥 绝对铁律 (T14+T15 真踩: silent "aborted" 没 retro 没 STUCK):

无论你什么时候停 (正常完成 / abort / 卡死 / 时间到), exit 之前 **必须** 写以下之一:
  - $CAP_DIR/_retro.md (≥ ${BUNDLE_TARGET} bundle 成功时)
  - $CAP_DIR/STUCK.md (任何 abort / 异常 — 写出原因)

**禁止只 echo "aborted" 然后 exit**. 这违反铁律 3 (5min stale → abort+写 STUCK). 你之前 T14 T15 都犯了, 不要再犯.

⭐ v0.16.1 增量 retro (T30 真踩: 单 run ~10min 撞模型请求墙, 你会在最后一个 kw 中途被杀,
根本到不了"最后写 retro"那步 → 报告没 verdict):
**每完成一个 bundle (OCR 完) 后, 立即覆盖式重写 $CAP_DIR/_retro.md**, 内容 = 目前所有
bundle 的 "## 一句话结论"(基于已有数据的暂定 verdict) + "## 笔记摘要". 最后一个 kw 完成后
再写最终版. 这样无论你在哪一步被杀, 盘上永远有带 verdict 的 retro.

⭐⭐⭐ v0.9 强制 TG push 协议 (mandatory — 不 push 算 fail):

每完成 1 个 bundle (OCR 写完之后) 必须立刻跑:
  $SCRIPTS_DIR/xhs-tg-push.sh "✅ T${TEST_ID} <bundle_name>: <title> (<N>p)"

每切 kw 时:
  $SCRIPTS_DIR/xhs-tg-push.sh "🔄 T${TEST_ID} kw<N>: <keyword>"

遇 BLOCKER:
  $SCRIPTS_DIR/xhs-tg-push.sh "🚨 T${TEST_ID} BLOCKER: <reason>"

完成 (写完 _retro.md 之前):
  $SCRIPTS_DIR/xhs-tg-push.sh "✅ T${TEST_ID} ${TOPIC_SLUG} 完成 <N> bundle (mode=${MODE})"

⭐ v0.8 mandatory: 每个 kw fire 后立即跑 $SCRIPTS_DIR/xhs-set-note-filter.sh

每 kw 流程:
1. ENC=\$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "<keyword>")
2. adb shell "am start -W -a android.intent.action.VIEW -d 'xhsdiscover://search/result?keyword=\$ENC' com.xingin.xhs"
3. sleep 3
4. $SCRIPTS_DIR/xhs-set-note-filter.sh
5. enter + 抓 title + 抓 URL + capture (v0.10 新流程):
   TITLE=\$($SCRIPTS_DIR/xhs-get-note-title.sh)
   URL=\$($SCRIPTS_DIR/xhs-get-note-url.sh 2>/dev/null || echo "")   ⭐ v0.10: BlueStacks 剪贴板同步抓 xhslink
   export XHS_TITLE="\$TITLE"
   export XHS_SOURCE_URL="\$URL"                                       ⭐ 让 xhs-capture-carousel.sh 写进 manifest.json source_url
   export XHS_SCREENSHOT_DIR="$CAP_DIR/bundles"
   $SCRIPTS_DIR/xhs-capture-carousel.sh ${CAROUSEL_PAGES} ${BUNDLE_PREFIX}_<X>_<Y>   ⭐ v0.11: 第 1 arg = MAX_PAGES cap
   URL 失败 (空字符串) 不阻塞, 报告会标 ⚠️ no source
6. OCR ($SCRIPTS_DIR/xhs-ocr-bundle.sh $CAP_DIR/bundles/${BUNDLE_PREFIX}_<X>_<Y>*)
7. 评论: 见上面 mode 指令 (fast skip / deep 抓)
8. ⭐ v0.13 强制 self-verify (T23 真踩: mobile 在 progress.log 撒谎写 "enter X" 但实际没 capture):
   BDIR=\$(ls -d $CAP_DIR/bundles/${BUNDLE_PREFIX}_<X>_<Y>* 2>/dev/null | head -1)
   if [ -z "\$BDIR" ] || [ ! -f "\$BDIR/manifest.json" ] || ! ls \$BDIR/*.png >/dev/null 2>&1; then
     echo "[HH:MM] FAIL: enter ${BUNDLE_PREFIX}_<X>_<Y> (title: <title>, 原因看 manifest stop_reason)" >> $CAP_DIR/_progress.log
     # 不要 silent abort, 切换到下一个候选笔记继续, 这条不计 quota
     # 🔴 v0.16 FAIL 纪律 (T28 真踩: 同一篇笔记原地重试 3 次打转到超时):
     #   - FAIL 过的笔记按 title 进黑名单, **绝对禁止重进同一篇** (哪怕你觉得刚才是意外)
     #   - 回搜索列表换下一个候选 (按 L1 prefilter 顺序)
     #   - 同一 kw 累计 2 次 FAIL → 放弃该 kw: 写 "[HH:MM] skip kw<N>: 2 FAILs" 进 progress.log,
     #     TG push "⚠️ T${TEST_ID} kw<N> skipped (2 FAILs)", 直接进下一个 kw
   else
     echo "[HH:MM] captured ${BUNDLE_PREFIX}_<X>_<Y>: \$TITLE" >> $CAP_DIR/_progress.log
     # 这里才算 1 个 valid bundle, 切下一个 kw
   fi
9. ⭐ TG push 完成报告 (上面, captured 成功才 push)

${KW_COUNT} kw:${KW_LIST_FMT}

放宽 L1 prefilter — 信噪比 AI 综合时再判. 每 kw 至少 1 bundle. fast mode 单 kw 1 bundle 即可切下一个, 不要恋战.

⭐ v0.13 progress.log 协议:
- "[HH:MM] enter <bundle>: <title>" = 刚 tap 进笔记, **还没** capture (可能失败)
- "[HH:MM] captured <bundle>: <title>" = capture 成功 (bundle dir + manifest + ≥1 PNG 都验证过)
- "[HH:MM] FAIL: enter <bundle> 但 capture 失败" = enter 了但 capture 没成, 这条不算 quota
- bundle 计数 (quota): 只数 "captured" 行, 不数 "enter" 行
- 这是为了让 dispatch cleanup 能比对 enter vs captured, 发现 silent capture failure

每 enter 写 $CAP_DIR/_progress.log (append only, 不 truncate)
≥ ${BUNDLE_TARGET} **captured** bundle 写 _retro.md 然后 exit.

⭐⭐⭐ v0.13 强制 retro 格式 (P4: 用户拿到 vault 报告要 5 秒做决定):

_retro.md 必须以下面这个模板开头 (固定顺序, 不要换):

\`\`\`
# ${TOPIC_CN} - XHS 实证

## 一句话结论

<这里写一行用户视角 verdict, 直接告诉他"值不值/选哪个/能不能干". 不要写 "数据完整 ✅" 这种工程视角. 100 字内. 用 OCR 看到的实际意见综合.>

## 笔记摘要

### <第一篇笔记 title> (<N>p)
- Source: <xhslink URL 或 "no source">
- 核心观点: <2-3 句, 从 OCR 抽取的实际内容, 不要主观转述>

### <第二篇笔记 title> (<N>p)
- Source: <URL>
- 核心观点: <...>

(每个 bundle 一段)
\`\`\`

下面可以加你自己的工程笔记 (## Outcome / Metric 表 / Technical Notes), conductor 端会跳过这些.

判断 verdict 的方法:
1. 看 OCR 第一段 ≈ 笔记标题 (例: "Notion真是个流氓软件" → 强负面)
2. 看 OCR 内容主要倾向 (例: 3 篇有 2 篇负面, 1 篇正面 → 偏负面)
3. 看用户的隐含需求 (topic 含 "选哪个" → verdict 给推荐; 含 "值不值" → verdict 给 yes/no/看场景)

**不允许的 verdict**: "信噪比 X/10" / "采到 N 篇" / "v0.13 跑通" — 这些是工程视角, 用户不关心.

Capture dir: $CAP_DIR
MSGEND
)

# ========== Dispatch ==========
# Open file for mobile log, get FD
exec 3>"$CAP_DIR/_mobile_run.log"

# v0.16.2 agent-agnostic hook: directive always lands on disk. Default runner =
# OpenClaw mobile agent (battle-tested path, byte-identical to before). Set
# XHS_AGENT_CMD to plug in ANY agent — it is invoked with one arg (the directive
# file path) and must read it + drive the xhs-*.sh scripts on this machine.
printf '%s\n' "$MSG" > "$CAP_DIR/_directive.md"

# Spawn mobile (detached so we can monitor)
# No hardcoded --thinking: levels are model-specific (M3 only takes off/adaptive,
# 2026-07-04 全灭真踩). Omit by default; XHS_THINKING / XHS_MODEL override per run.
if [ -n "${XHS_AGENT_CMD:-}" ]; then
  $XHS_AGENT_CMD "$CAP_DIR/_directive.md" >&3 2>&1 &
else
  openclaw agent --agent mobile ${XHS_THINKING:+--thinking "$XHS_THINKING"} ${XHS_MODEL:+--model "$XHS_MODEL"} -m "$MSG" >&3 2>&1 &
fi
MOB_PID=$!
exec 3>&-
echo "mobile spawned PID=$MOB_PID"

# Start watchdog with EXPLICIT PID (avoid pgrep race)
"$SCRIPTS_DIR/xhs-watchdog.sh" "$CAP_DIR" "$MOB_PID" 5 60 > "$CAP_DIR/_watchdog.log" 2>&1 &
WD_PID=$!
echo "watchdog spawned PID=$WD_PID monitoring mobile $MOB_PID"

# Initial TG push (dispatch confirmation)
"$SCRIPTS_DIR/xhs-tg-push.sh" "▶️ T${TEST_ID} ${TOPIC_SLUG} 派发 (mode=${MODE})" "${TOPIC_CN} | ${KW_COUNT} kw | target ≥${BUNDLE_TARGET} bundle | mobile PID=$MOB_PID, wd PID=$WD_PID" 2>/dev/null || true

# Wait for mobile to finish (this is the main blocking point)
wait $MOB_PID
MOB_EXIT=$?
echo "mobile exited with $MOB_EXIT"

# Cleanup runs via trap
exit $MOB_EXIT
