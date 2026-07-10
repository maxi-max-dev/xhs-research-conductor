---
name: xhs-research-conductor
description: XHS (小红书) 专用主题调研技能。给一个主题(如"某公司笔试"/"GLM 模型好用吗"/"应届生迷茫"), 自动扩词 → mobile 在 XHS app 内搜+采集 → 综合报告落 vault. **只做 XHS 这一个源** (其他源知乎/牛客/公众号由上游 agent 自己用 WebFetch 处理). 上游 agent 可并行调多 skill 合并结果. **默认 fast mode** (3 kw × 1 bundle × 4 页 ≈ 5-10 min); 用户说"深度/正经调研/精读"才走 `--deep` (5 kw × ≥4 bundle × 20 页 + 抓评论 ≈ 15-30 min). **v0.17 起带视频道**: 图文流之后自动收每 kw 的头部视频 (fast 1 条/kw, deep 2 条/kw), yt-dlp 抽音轨 + Whisper 转文字进报告.
trigger: 调研|研究|搜小红书|看看小红书|XHS 上|帮我搜|查一下|了解一下
version: 0.17
---

# XHS Research Conductor

## 🎯 是 / 不是

**是**: 总指挥. 串联 `xhs-research-lite` (思考框架) + mobile agent (采集) + OCR pipeline + vault 输出. 图文走截图+OCR (Note type filter mandatory); **视频走 v0.17 视频道** (mobile 图文流之后, dispatch 确定性收割 URL → yt-dlp 音轨 → Whisper 文字稿, 零截图零 LLM).

**不是**:
- ❌ 重新发明 XHS 采集 (走 `xhs-capture-*` scripts)
- ❌ 重新发明思考框架 (走 `xhs-research-lite`)
- ❌ 通用 web 研究 (只 XHS)
- ❌ **在 mobile 采集流里 capture 视频** — DetailFeedActivity 播放中 uiautomator 永不 idle, dump 必挂 (Test 11 死循环的底层死因, 2026-07-10 实锤). 视频只在视频道处理; 用户单发视频链接走 `xhs-open-link`/`xhs-video-note.sh`

**早死**: 主题在 XHS 几乎没人讨论 → 立刻告诉用户换源, 不要硬跑.

---

## 📞 触发

- "调研一下 X" / "看看小红书 X 怎么样" / "X 好用吗" / "X 公司笔试" / "帮我搜 X"
- 链接 (xhslink/xiaohongshu.com) → 走 `link-router`, 不走本 skill.

---

## ⚡️ Modes (v0.11)

| | `fast` (默认) | `deep` (`--mode deep`) |
|---|---|---|
| kw 数 | **3** (最分散的) | 最多 5 |
| 每 kw enter | **1 条** | 1-2 条 |
| 目标 bundle | **≥ 3** | ≥ 4 |
| carousel 每 bundle | **4 页 cap** | 20 页 |
| 评论抓取 | **skip** (靠 OCR 第一屏判断) | 跑 `xhs-capture-comments.sh` (v0.16: 确定性滚到评论区+多屏抓取+去重, 别手敲 swipe) |
| 🎬 视频/kw (v0.17) | **1 条** | 2 条 |
| 总耗时 | **≈ 5-10 min** (+视频道 ~1 min/条) | ≈ 15-30 min |
| 适用 | 快查/投简历前扫一眼/AirPods 值不值 | 公司面经/产品深度评测/雇主全景 |

**判别**: 用户没特别说 → fast. 出现"深度/正经/精读/完整/详细"或主题明显需要多维度 (例: "某公司作为雇主全面评估") → deep, 先跟用户确认 "走 deep 模式 ~20 min 可以吗" 再派.

**派发**: `xhs-research-dispatch.sh [--mode fast|deep] [--videos N] <test_id> <slug> <prefix> "<topic>" "<kw1>" ...`
(`--videos 0` 关视频道; 不传按 mode 默认 fast=1/deep=2, env `XHS_VIDEOS` 可覆盖)

**⭐ 多 kw + 弱模型的稳妥路径 = `xhs-research-serial.sh`** (一 kw 一 agent run 串行 loop):
LLM 单请求 ~10 min 墙是硬约束 — 多 kw 单 run 必在最后一个 kw 中途被杀 (v0.16.1 有 resume 接力
+ OCR salvage + 增量 retro 三重兜底, 结局是"慢一点但齐活"). 想要每个 kw 都干净单跑:
`xhs-research-serial.sh [--comments on|off] [--target N] [--pages N] --mode fast <id> <slug> <prefix> "<topic>" "<kw1>" "<kw2>" ...`

---

## 🔄 流水线

**0 vault history check** (≤ 1s) → **A 关键词扩展** (10s) → **B mobile 采集** (fast 5-10 min / deep 15-30 min) → **C 综合落 vault** (auto, ≤ 5s)

---

## Phase 0 — Vault History Check (v0.14, mandatory)

### 触发: 用户说 "调研 X / 看看小红书 X / X 怎么样"

### 必跑命令 (在派 mobile 之前):

```bash
$SCRIPTS_DIR/xhs-vault-history-check.sh "<topic_cn>" [topic_slug]
```

### 行为
- 在 vault grep filename 含主关键词 (第一个词) 的 md
- 按 freshness window 过滤: 笔试/面试 180 天, 工具评测 90 天, 时事 7 天, 默认 30 天
- 返回 path \t age \t size (按 size 降序, 最大的报告优先)

### 决策
- **找到** ≥1 报告且在 window 内: **不派 mobile**, 直接给用户报告 path + 摘要前 30 行. 问 "要重跑吗?" (默认不重跑)
- **找不到** / 用户明确要新数据: 派 mobile 走 Phase A-B-C

### 为什么这一步关键 (5/20 某公司笔试真踩)
用户问"调研某公司笔试", skill 默认全量 7 min mobile dispatch. 但 vault 早已有 5/14 跑的 16KB deep+多源报告 (XHS + 牛客 + 知乎). fast 单源跑出来还不如直接给现有的. Phase 0 把"查历史"前置, 避免无谓重跑.

### dispatch.sh 端兜底
即使 conductor (Claude) forgot Phase 0, `xhs-research-dispatch.sh` 自己也会跑 history check, 找到就 exit 0 + TG push + 不派 mobile. 真要重跑用 `--force`.

---

## Phase A — 关键词扩展

### 输入
- `topic` (用户给的主题)
- `intent` (推断: 求职/产品评测/工具选型/人生方法论/品牌调研)

### 步骤
1. 按 intent 选关键词模板 → 见 [`references/keyword_templates.md`](references/keyword_templates.md)
2. 写关键词 + 每个理由 (**fast = 3 个**, deep = 5 个)
3. 写 enter 笔记 3 级标准 (高优/中性/跳过) — 见 [`references/marketing_account_prefilter.md`](references/marketing_account_prefilter.md)
4. 评估 `source_fit_assessment: low/medium/high` — 信噪比 < 3 大概率发生在 `low`, 跑之前就告诉用户
5. 输出到 `${CAPTURE_DIR}/PLAN.md` (dispatch.sh 会自动写, 标 `mode=`)

### 关键约束
- **⛔ 上限**: kw 数硬上限由 mode 决定 (fast=3, deep=5). dispatch.sh 会校验, 超了 reject
- **🌐 多样性**: fast 3 词必须**最分散** (3 维度全覆盖, 不要 3 个都问"评测"); deep 5 词覆盖 3 维度
- **🎯 优先全称**: `哔哩哔哩` > `B站`. 全称出 OP 比例显著高
- **🎯 具体词强制** (人生方法论类): ≥ 2 词是 "具体年龄+具体状态" (e.g., `25岁 失业` ✅ vs `人迷茫怎么办` ❌)
- **⚖️ Prefilter 平衡**: L1 skip ≤ 60% 候选; ≥ 5 enter 候选; 每 kw 至少 1 bundle

---

## Phase B — 采集 (派 mobile agent)

### 派发前必跑 (mandatory)
```bash
~/.openclaw/workspace-mobile/scripts/xhs-setup.sh
```
6 项 self-check (ADB / tesseract / device / XHS app / login). 任一 ❌ → **不要派 mobile**, 把 fix 指导给用户, 等修完再派.

### Mobile 流程 — 每个 keyword 必跑 (v0.8 mandatory)

```
1. ENC=$(python3 -c "..." "<keyword>")
2. adb shell "am start -W -a android.intent.action.VIEW -d 'xhsdiscover://search/result?keyword=$ENC' com.xingin.xhs"
3. sleep 3
4. ./scripts/xhs-set-note-filter.sh   ⭐ MANDATORY: 应用 Note type filter, 排除 vlog/video/live
5. 现在 list 纯图文 — 走 L1 prefilter (放宽) + enter + capture 流程
```

**为什么 mandatory**: 不带 filter 的话 vlog 类笔记会跳 DetailFeedActivity (XHS immersive video feed), mobile 截图+OCR 架构吃不了视频 (播放中 uiautomator 永不 idle, dump 必挂), 严守铁律 8 skip 会陷入死循环 (Test 11 真踩). 加 filter 后纯图文, 0 视频干扰.

**视频怎么进报告 (v0.17 视频道)**: mobile 图文流跑完后, dispatch 主流程自己 (不经 LLM) 按 kw 重发搜索深链 → `xhs-set-note-filter.sh --type video` → `xhs-harvest-video-urls.sh` 在沉浸流里收 N 条分享链接 (分享面板开着时视频暂停, dump 才可用; Copy link 常要左滑一次) → `xhs-video-note.sh` 逐条 yt-dlp 抽音轨 (实测无需 cookies) + Whisper 转文字 → `bundles/<prefix>-vidK-N/` (manifest `type:video`, 无 PNG, 不进图文 bundle 计数). 跨 kw 撞车按 note_id 去重. 纯 BGM/字幕视频文字稿会标 ⚠️ low voice.

**用户单发视频链接**: 走 `xhs-open-link` skill 或直接 `xhs-video-note.sh '<url或分享文本>'`, 跟调研流程**不冲突**.

### 派发时**同步** spawn watchdog (v0.6 mandatory)
```bash
# 在 background 启外部 watchdog (mobile 内部 self-check 不可靠, Test 3/5 都暴露)
~/.openclaw/workspace-mobile/scripts/xhs-watchdog.sh $CAPTURE_DIR &
WATCHDOG_PID=$!

# 然后 dispatch mobile
openclaw agent --agent mobile ... &
MOBILE_PID=$!

# mobile 完成后 kill watchdog
wait $MOBILE_PID
kill $WATCHDOG_PID 2>/dev/null
```

watchdog 行为: 5 min progress stale → 自动写 STUCK.md, mobile 看到 STUCK 后自检退出.

### Backend
默认 `openclaw-mobile`. 检测: `test -f ~/.openclaw/workspace-mobile/AGENTS.md`.
**v0.16.2 任意 agent 可接**: dispatch 会把完整指令落盘到 `<capture_dir>/_directive.md`; 设
`XHS_AGENT_CMD=<你的命令>` 后 dispatch 改为调 `你的命令 <directive文件路径>` — 任何能读文件+
在本机跑 shell/adb 的 agent (Claude Code / Codex / 自写 runner) 都能当采集 worker.
其他 backend (playwright / manual) 见 [`references/mobile_dispatch_template.md`](references/mobile_dispatch_template.md).

### 设备 detection
`scripts/detect-emulator.sh` 自动找模拟器, 优先级:
1. `$ANDROID_SERIAL` (用户显式)
2. `$XHS_EMULATOR` (bluestacks / genymotion / avd)
3. 自动 detect: BlueStacks (5555) → Genymotion (6555) → AVD (emulator-5554) → 真机

### 派发
**首选: 跑封装好的 `xhs-research-dispatch.sh`** (v0.11, 已含 mode/单例/watchdog/TG/retro-fabricate). 默认 fast:
```bash
xhs-research-dispatch.sh 21 airpods4 ap4 "AirPods 4 值不值得" \
  "AirPods 4 评测" "AirPods 4 缺点" "AirPods 4 vs Pro"
# deep:
xhs-research-dispatch.sh --mode deep 22 acme-employer ace "某公司 雇主" \
  "某公司 实习" "某公司 内部" "某公司 离职" "某公司 加班" "某公司 CEO"
```

完整 message 模板见 [`references/mobile_dispatch_template.md`](references/mobile_dispatch_template.md). 关键约束:
- mobile 必须 follow **18 条铁律** (`XHS_RUNBOOK.md`)
- 关键铁律: 1 (no ad-hoc), 12 (prefilter audit trail), 13 (enter→bundle 3 min), 14 (focus self-check), 16 (note filter mandatory), 17 (bundle output_dir 独立), 18 ("可能含AI生成内容" 降级)
- 命令端 timeout 1900s; mobile 自身 stop = mode 目标 bundle 达成 或 30 min 触发

### 失败处理
| 返回 | 动作 |
|---|---|
| 达到 mode 目标 bundle (fast ≥ 3 / deep ≥ 4) | 进 Phase C |
| 部分 bundle (≥ 2) | 进 Phase C, 标小样本 |
| 0 bundle + BLOCKER | 不进 Phase C, 告诉用户原因 |
| 0 bundle + STUCK | 看 _progress.log 判断 prefilter 是否过严, 决定手动 retry 还是 abort |

---

## Phase C — 综合 (本 skill 做)

### 输入
所有 bundle 的 `ocr.md` + `manifest.json` + `_progress.log` + 主题原文. **deep mode 还有** `comments.json` (fast mode 没抓评论, 别去找). **v0.17 还有** 视频 bundle 的 `transcript.md` (笔记文案 + 口播文字稿) — conductor 做 Phase C 时把它当正文级材料一起分析; `voice_info: low` 的只当线索别当证据.

### 处理
1. **去重** (Test 2 学到): 按 manifest title + ocr 第 1 段, 重复者移 `_duplicates/`
2. **AI 生成内容剔除** (T13 真踩, 铁律 18): grep "可能含AI生成内容" → 该 bundle 直接降为 ⚠️ / C 级
3. **bundle 内容验证** (T13 真踩, 铁律 17): manifest title vs ocr 第 1 段如果话题对不上 (跨主题污染) → 标 ⚠️ + 在报告里说明
4. **A/B/C 分层** (按 `xhs-research-lite` 规则)
5. **营销号识别** (见 [`references/marketing_account_prefilter.md`](references/marketing_account_prefilter.md))
6. 写报告到 `${VAULT_ROOT}/<topic-folder>/<topic>_<date>.md`

### 报告
格式 + frontmatter + 诚实度规则 → [`references/report_format.md`](references/report_format.md). 关键:
- **信噪比 < 3 → 第一行 🚨**, 推荐换源, 不藏中部
- frontmatter 必含: `signal_to_noise`, `verdict_source_fit`, `data_freshness_days_avg`, `coverage_gap`

### 强制
- ⛔ 不读 PNG, 不调 LLM image tool (避免 5min 墙)
- ⛔ 不编造未在 OCR 出现的内容

### Self-learning log
每次跑完写 `_research_method_v<N>.md` 到 `~/.openclaw/_research_method_log/`. 跑 3 次 review pattern, 升 v 号.

---

## 🛡️ 常见失败模式

| 模式 | 信号 | 应对 |
|---|---|---|
| 主题在 XHS 没人讨论 | Phase A 列表页 0-1 候选 | 早死, 告用户换源 |
| Mobile freelance | _progress.log 出现 ad-hoc screencap | RUNBOOK 已硬绑死, 若发生 → 改 RUNBOOK |
| AskNow 占满首屏 | 进 SearchAgentPageActivity | Latest 排序绕开; Latest tab 自己也是 WebView, nav 笔记 cards 直接 tap |
| 中文输入失败 | 触发 "input failed" | 走 BlueStacks 剪贴板 / Clipper / ADBKeyboard 三层 |
| 全是营销号 | bundle OCR 全含"全网最全"等 | Phase C 标信噪比 ≤ 3 + 推荐换源 |
| mobile 卡死 | progress.log 5 min 无新 entry 或 无 bundle | mobile 应自写 STUCK; 若没 → conductor 手动 abort + 用 partial data |

---

## 📦 依赖

**必需**:
- `mobile` agent + `XHS_RUNBOOK.md` + `xhs-capture-*` scripts
- tesseract (`brew install tesseract tesseract-lang`)

**推荐**:
- `xhs-research-lite` skill (思考框架; 没装也能跑 — 关键词策略/A/B/C 分层规则已内嵌在本 repo `references/`)

**推荐**:
- vault 路径 (`$VAULT_ROOT` 或默认 `$HOME/Documents/xhs-research-reports`)
- BlueStacks Air + XHS app + 登录态

**可选**:
- `brainstorming` skill (复杂主题先想清楚再调)

---

## 🚀 示例

### fast (默认): 快查
"AirPods 4 值不值得?" → 3 kw: `AirPods 4 评测` / `AirPods 4 缺点` / `AirPods 4 vs Pro` (评测/痛点/对比 3 维度) → 5-10 min → 报告 `📚学习/工具评测/AirPods 4/AirPods 4_2026-05-18.md`

"GLM 模型好用吗?" → 3 kw: `GLM 评测` / `GLM 缺点` / `GLM vs GPT` → fast 出大方向即可.

### deep: 正经调研 (派之前先跟用户确认)
"某公司作为雇主全面评估" → `--mode deep`, 5 kw: `某公司 实习` / `某公司 内部` / `某公司 离职` / `某公司 加班` / `某公司 CEO` → 15-30 min, 抓评论, 全景报告.

"某公司笔试 + 面经全套" → `--mode deep`, 5 kw 覆盖笔试/面经/校招/实习/全称 → 报告 `💼Career/某公司/某公司 笔试_2026-05-18.md`

### 人生方法论 (低 source_fit 实证, 任意 mode)
"人迷茫怎么办" — ≥ 2 词必须具体 (e.g., `25岁 迷茫`). Test 2 实证信噪比 **1.7/10** (5/6 营销号). Phase A 评估 `source_fit_assessment: low` 应跑前告用户. 报告第一行 🚨 + 推荐豆瓣/即刻/知乎.

---

## 🔧 配置

```bash
export VAULT_ROOT="$HOME/Documents/xhs-research-reports"   # 报告根目录, 自动创建
export VAULT_FOLDER=""            # 精确指定报告子目录 (覆盖自动分类)
export XHS_FOLDER_STYLE="plain"   # plain(career/|reviews/) | emoji(💼Career/|📚学习/工具评测/) | flat
export XHS_CAPTURE_ROOT=""        # 原始采集目录 (默认 = 脚本目录旁的 captures/)
export XHS_CAPTURE_BACKEND="openclaw-mobile"   # 或 playwright / manual
export XHS_RESEARCH_LOG="$HOME/.openclaw/_research_method_log"
# v0.16: mobile agent 单次运行的模型/思考档覆盖 (默认都不传, 跟 agent 配置走).
# thinking 档位是 model-specific 的 (MiniMax-M3 只认 off/adaptive), 别硬编码.
export XHS_MODEL=""        # 例: "anthropic/claude-sonnet-5" — XHS 调研单独指强模型
export XHS_THINKING=""     # 例: "adaptive"
# v0.17 视频道
export XHS_VIDEOS=""           # 每 kw 收几条视频 (覆盖 mode 默认 fast=1/deep=2; 0=关)
export XHS_VIDEO_MAX_SEC=""    # 单条视频时长上限秒 (默认 900, 超限只留元数据)
export XHS_TRANSCRIBE_CMD=""   # 转录命令 (默认 ~/.openclaw/workspace/scripts/transcribe-file.sh;
                               # 缺席时视频 bundle 降级为 音轨+元数据)
```

跨机器移植时改 env vars 即可.

---

*v0.17 (2026-07-10, 视频道). 改进:*
*- 视频不再是盲区: dispatch 图文流之后跑视频道 (每 kw 收 fast=1/deep=2 条头部视频), 确定性 adb 收割分享链接 → yt-dlp 抽音轨 (实测无需 cookies) → Groq Whisper 转文字 → bundles/<prefix>-vidK-N/ (manifest type:video). 报告新增 "🎬 视频笔记" 节 (标题+链接+口播摘录+完整稿指路), frontmatter 加 videos: N. 纯 BGM/字幕视频按 transcript 字数标 ⚠️ low voice (e2e 实测逮到过纯 BGM 教程视频). 图文 0 但视频 ≥1 也出报告.*
*- 新脚本: xhs-video-note.sh (URL→文字稿 bundle, 单条视频链接也用它) + xhs-harvest-video-urls.sh (沉浸流收割: 分享面板开着时视频暂停 uiautomator 才能 dump — 这也是当年视频死循环的底层死因; Copy link 在面板第二行常要左滑). xhs-set-note-filter.sh 加 --type note|video (默认 note 字节级兼容).*
*- 视频道在 dispatch 主流程不在 cleanup trap: Ctrl-C 不会再拖几分钟收视频. 跨 kw 同视频按 note_id 去重. --videos N / XHS_VIDEOS 可调可关.*
*v0.16.3 (2026-07-06). 改进:*
*- 全面可移植: 所有路径改为相对脚本自身解析 (clone 到哪都能跑), XHS_SCRIPTS_DIR/XHS_CAPTURE_ROOT 可覆盖; OpenClaw 老安装位置解析结果不变.*
*- 任意分辨率/模拟器: 新增 xhs-geom.sh, 全部 tap/swipe 坐标按实际 wm size 等比换算 (基准 1440x2560, 该分辨率下恒等); 设备选择走 ANDROID_SERIAL/XHS_EMULATOR/自动探测.*
*- 输出全自选: VAULT_ROOT(自动建目录) + VAULT_FOLDER(精确指定) + XHS_FOLDER_STYLE=plain|emoji|flat; 分类词补"秋招".*
*v0.16.2 (2026-07-06). 改进:*
*- agent 无关化: dispatch 把完整指令落盘 `_directive.md`, `XHS_AGENT_CMD` 钩子可接任意 agent (Claude Code / Codex / 自写 runner) 当采集 worker; 默认路径 (OpenClaw mobile) 字节级不变.*
*- 文档隐私清理: 示例/案例全部通用化, 移除 dogfood 测试史明细表.*
*v0.16.1 (2026-07-06 凌晨, T30-T32 三轮压力测试). 改进:*
*- OCR salvage: cleanup 对"有 PNG 没 ocr.md"的截断 bundle 本地补跑 tesseract (T30: mobile 撞 ~10min 单请求墙死在 kw3 中途, 数据本可救).*
*- 增量 retro: mobile 每完成一个 bundle 立即覆盖式重写 _retro.md(暂定 verdict), 撞墙被杀时盘上永远有 verdict (T32 实测 1/3 阶段 retro 已在盘).*
*- synthesize-vault 计数改有效口径 (T30: frontmatter 写 3 正文只有 2 的撒谎修掉).*
*- T32 实证容灾链全通: 撞墙死 → resume agent 接力(M3→M2.7 fallback) → 黑名单跨 session 生效(跳过 FAIL 笔记换新候选) → 3/3 bundle + mobile 终版 retro.*
*v0.16 (2026-07-05, T28 e2e: 7/4 换模型后 3 kw 全灭 + STUCK 短路兜底 + lost_focus 3 连). 改进:*
*- P0: dispatch 去掉硬编码 `--thinking medium` (M3 只认 off/adaptive, 每派必死), 默认不传, 新增 XHS_THINKING/XHS_MODEL env 覆盖.*
*- P0: cleanup fabricate 不再被 STUCK.md 短路 (watchdog 报过 STUCK 但 agent 自愈恢复的场景, 好 bundle 白采且 exit 0).*
*- carousel surgical reset: 先读位置再决定滑不滑/滑几下, 不再盲扫 5 下 (单图笔记盲滑蹭返回手势 → 甩回搜索页).*
*- FAIL 纪律: FAIL 过的笔记进黑名单禁止重进, 同 kw 2 FAIL 弃 kw (T28 同一篇原地重试 3 次).*
*- 有效 bundle 计数: manifest.json + ≥1 PNG 才算 (startup self-check / cleanup / fabricate 三处统一口径), abort 壳目录不再虚报.*
*v0.13 (2026-05-19, T23 暴露 mobile 在 kw 中 silent abort, progress.log 撒谎写 enter 但实际没 capture; user push 修到 ship-C 标准). 改进:*
*- v0.13 P0: mobile message 加 enter 后 self-verify (test -d bundle + manifest + ≥1 PNG), 通过则写 "captured X" 行, 不通过则写 "FAIL: enter X" + 切下一个候选. dispatch cleanup 比对 enter vs captured 计数, 不一致打 WARN. T24 实证: 3 个 kw 全 captured (T23 是 2/3), 0 silent abort.*
*- v0.13 P2: xhs-get-note-url.sh 加 3 次 retry + sleep 1s, 解决 BlueStacks 剪贴板偶发 sync 失败. T24 实证: 3/3 bundle 都拿到 xhslink.*
*- v0.13 P3: xhs-capture-carousel.sh CONFIRM_STOP_THRESHOLD 从 2 改 1 (hash 同 1 次就停), 减少 single-image 多翻浪费 + manifest pages 准.*
*- v0.13 P4 (ship-C 核心): 新增 xhs-synthesize-vault.sh, dispatch cleanup auto-trigger. 从 retro 抓 "一句话结论" + "笔记摘要" 段直接 render 到 vault md, 加 frontmatter + Coverage Gap. 陌生人装 skill 跑 → 不依赖任何 Claude conductor → 直接拿到 vault 报告 5 秒能决定. T24 实证: vault md 1.6KB, verdict 一句话, 3 个 bundle 都带 xhslink.*
*- v0.13 mobile retro 模板硬化: 强制顶部 "## 一句话结论" + "## 笔记摘要" 用户视角段 (verdict 给 yes/no/看场景, 不要工程视角 "信噪比 X/10"). xhs-fabricate-retro.sh 兜底也按此格式产, mobile silent abort 时还是有 vault-friendly retro.*
*v0.12 (2026-05-19, T21 dogfood 暴露 Bug 1: openclaw gateway 6.5min timeout → embedded fallback → 整任务重跑 → 6 bundle/数据利用率 50%/耗时 10min 卡上界). 改进:*
*- v0.12: dispatch.sh mobile message 顶部加 startup self-check. mobile 收到任务先 `find $CAP_DIR/bundles -mindepth 1 -maxdepth 1 -type d | wc -l`, ≥ target 直接 fabricate retro + exit (resume 场景), 部分完成则接力跑缺的 kw, 0 bundle 才 fresh 跑. T22 实证: gateway 又 timeout 但 fresh agent self-check 直接 exit, 0 重跑, 耗时 7 min (T21 是 10 min). T23 跨主题 Notion vs Obsidian 通过 (2/3 bundle, kw2 silent abort 是另外一个新 bug, 留 v0.13).*
*v0.11 (2026-05-18, 用户反馈"v0.10 跑一次 1-2hr 太重"). 改进:*
*- v0.11: dispatch.sh 加 `--mode fast|deep`. **fast 默认** (3 kw × 1 bundle × 4 页 cap × skip 评论 ≈ 5-10 min), 投简历前快查 / AirPods 值不值这类用. deep (5 kw × ≥4 bundle × 20 页 + 抓评论 ≈ 15-30 min) 保留, 公司面经/雇主全景这类用. mobile message 也 mode-aware (bundle 目标 + 评论指令 + carousel pages 都跟 mode 走). KW 数 dispatch 端校验, fast > 3 reject.*
*- v0.10 (post-T20 dogfood, 用户反馈"报告偏 meta + 缺原始链接"): 新 `xhs-get-note-url.sh` (走 BlueStacks 剪贴板同步抓 xhslink). manifest.json `source_url` 第一次真填. 报告模板重排: research-first, skill telemetry 全降到末尾折叠 Appendix. 每条 A/B 级 OP 必须带 🔗 原始链接, 空 URL 显式 ⚠️.*
*- v0.6→v0.9 dogfooding 改 (T1-T20):*
*  - Test 1 某平台校招笔试 (5/10) → v0.3 多样性 + 全称 + prefilter 3 级*
*  - Test 2 人迷茫 (1.7/10 营销号红海, 0 audit) → v0.4 铁律 12 audit trail + 报告诚实度*
*  - Test 3 某AI产品 (0 bundle abort) → v0.5 铁律 13/14 + xhs-get-note-title.sh*
*  - Test 5 某IPO投研 (mobile stale 16min 没自报) → v0.6 xhs-watchdog.sh + 铁律 3*
*  - Test 14-17 mobile silent abort 4 次 → v0.9 watchdog process-aware + dispatch singleton + auto-fabricate retro*
*每版对应 retro log 在 `$XHS_RESEARCH_LOG/_research_method_v<N>.md`.*
