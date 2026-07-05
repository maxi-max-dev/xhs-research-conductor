# XHS_RUNBOOK.md - Xiaohongshu Mobile Workflow

Current lane: BlueStacks Air for Mac + Xiaohongshu Android app.

## 🚨 必须分批 (2026-05-14, 真踩过的坑)

**2026-05-13 19:33 incident**: 一个 xhs OCR 任务在同一个 mobile subagent 里连跑 6+ 张图,每张都用 LLM 的 `image` tool 做 OCR。第 7 turn 时 MiniMax-M2.7 单次请求**卡满 5 分钟 LLM timeout**,fallback 到 M2.5 也超时,整个 task abort。同一根因也炸过 `watcher-xhs-weekly-deals` cron 两次(consec=2)。

**强制规则**:

1. **绝对禁止用 LLM `image` tool 做批量 OCR**。`image` 一张图就往 chat history 塞几百到几千 token,5 张以上必撞 5min LLM 墙。OCR 走本地 `xhs-ocr-bundle.sh`(tesseract),评论走 `xhs-extract-comments.sh`(uiautomator UI dump)。这两个脚本输出到 disk 的 `ocr.md` / `comments.json`,你**读文本文件就够了**,不要把图喂回模型。

2. **流程必须分两段**:
   - **Stage 1 — 采集**:`xhs-open-link.sh` → `xhs-capture-carousel.sh` / `xhs-capture-scroll.sh` → `xhs-ocr-bundle.sh` → `xhs-extract-comments.sh`。**全程不调 LLM image tool**。产物是一个 bundle 目录,内含 `manifest.json` + `ocr.md` + `comments.json`。结束时把 bundle 路径返给调用方。
   - **Stage 2 — 分析**:**新开一个 subagent**(或者调用方主 agent),只读 bundle 里的文本文件(`ocr.md`、`comments.json`、`manifest.json`),写摘要。这一段对话里**没有任何截图**,context 干净,不会撞 5min 墙。

3. **单 stage 例外**:笔记 ≤ 3 张图 且 评论 < 20 条时,可以在同一个 subagent 内一次跑完两段(本地 OCR 后读文件,不调 `image` tool)。超过这个阈值必须 hand off。

4. **看一眼可以**:如果 user 只问"这是张什么图",**一次** `image` tool 调用 OK。不要在同一 session 里第二次调。

下面老内容保留作为 step-by-step reference,但**整体流程以本节为准**。

## State

- Emulator: BlueStacks Air for Mac
- ADB endpoint: `127.0.0.1:5555`
- App package: `com.xingin.xhs`
- Observed app version: `8.79.0`
- Login: Max re-installed + logged in on BlueStacks 2026-05-06 (XHS version 9.27.0)
- Last known good state: normal home feed, no immediate "Security Restrictions" screen

## Default Flow

0. If the task came from another agent, use `XHS_TASK_CARD.md` so `mobile` has the link, goal, capture mode, max pages, and output format. Do not rely on another agent's chat history.

1. Check device and ADB:

```zsh
./scripts/device-status.sh
```

2. Check Xiaohongshu state without interacting:

```zsh
./scripts/xhs-status.sh
```

3. If the app needs a fresh launch:

```zsh
./scripts/xhs-clean-launch.sh
```

3a. **If the task is "open this xhs link"** (xhslink / xiaohongshu.com note URL / xhs:// scheme), use:

```zsh
./scripts/xhs-open-link.sh '<url>'
```

This fires the system VIEW intent, follows redirects in Chrome, and auto-taps xhs's "Open in App" gateway page if Chrome lands on it. Exit code 0 means xhs is in the foreground and you can move on to step 4. See `skills/xhs-open-link/SKILL.md` for full behavior.

🚨 **2026-05-06 incident**: never skip step 3a even when `xhs-status.sh` shows xhs already in `NoteDetailActivity`. That focus only proves "xhs is on some note", not "xhs is on the note you were just asked about". Skipping 3a once already shipped a wrong-note capture (CharMing_'s 最近的喜欢 instead of the user's actual link). Always re-open the link for every fresh task; only reuse if you ran open-link yourself in the same task context and user hasn't given a new URL.

4. Inspect the screenshot before doing anything else.

If the note is an image carousel, capture every visible image page by swiping the carousel:

```zsh
./scripts/xhs-capture-carousel.sh 8 xhs-example
```

The first argument is the maximum number of pages to try. The script stops early if a swipe no longer changes the screenshot. It saves both PNG originals and Discord-safe JPG copies.

If the note has long body text or comments below the first screen, capture vertical scroll pages:

```zsh
./scripts/xhs-capture-scroll.sh 6 xhs-example-body
```

Run OCR on any capture bundle (carousel + body images only):

```zsh
./scripts/xhs-ocr-bundle.sh $HOME/.openclaw/workspace-mobile/screenshots/xhs-example-full-20260429-163300
```

**Comments must be extracted via UI dump, NOT OCR.** OCR mixes text from comment-attached images into the comment body — true 2026-05-07 incident: the author 小盖 commented "效果长这样" + a slide screenshot showing "王宁最想纠正的误解...", and OCR reported the slide's quote AS the comment text. Use:

```zsh
./scripts/xhs-extract-comments.sh <bundle>/comments.json
```

The script reads `parentCommentLayout` containers from `uiautomator dump` and outputs one JSON object per comment with `user`/`text`/`likes`/`attached_images`/`is_author`. Run it after each scroll page if comments span multiple screens, then merge by `(user, text[:30])`.

Every capture bundle should include `manifest.json`, original PNG screenshots, Discord-safe JPG copies, optionally `ocr.md`, and `comments.json`.

## Discord Image Sending

Xiaohongshu screenshots from Android are often RGBA PNG files. OpenClaw may fail before Discord upload with `Failed to optimize image` while trying to optimize PNGs. When sending a screenshot to Discord, first create a no-alpha JPG:

```zsh
./scripts/discord-safe-image.sh $HOME/.openclaw/workspace-mobile/screenshots/xhs-example.png /tmp/xhs-example-discord.jpg
```

Then send the JPG path instead of the original PNG.

## Allowed Low-Risk Actions

- Open the app.
- Take screenshots.
- Swipe through an image carousel for a user-requested note.
- Scroll vertically through a user-requested note body or comments when Max asks for it.
- OCR a local screenshot bundle.
- Read current foreground activity.
- Navigate slowly when Max asks for a narrow task.
- Search or inspect a small number of user-requested items.
- Stop and summarize the screen state.

## Stop Conditions

Stop and hand control to Max if any of these appear:

- Login, captcha, QR scan, SMS, phone, or account verification
- Account-risk, security, suspicious activity, or device exception prompt
- Permission dialog that changes account/device access
- Payment, purchase, refund, or wallet flow
- Publishing, commenting, following, liking, messaging, or any irreversible/social action
- Any request that would collect data at scale

## Automation Notes

- Do not use Appium against live Xiaohongshu unless Max explicitly asks to risk a test.
- Keep Appium helper packages uninstalled before launching Xiaohongshu:
  - `io.appium.settings`
  - `io.appium.uiautomator2.server`
  - `io.appium.uiautomator2.server.test`
  - `io.appium.unlock`
- Prefer ADB screenshot plus careful, low-frequency input.
- Do not attempt emulator fingerprint spoofing, root hiding, hooking, or platform-protection bypasses.

## Safe Automation Smoke Test

Use this to test mobile automation mechanics without touching reward apps or account-affecting flows:

```zsh
./scripts/mobile-loop-smoke.sh 3
```

This opens a local test page through ADB reverse, screenshots the screen, OCRs the `NEXT` button, waits a randomized delay, clicks it, logs each step, and closes the local HTTP server afterward.

---

## 🚨 执行纪律 (2026-05-15 加, 防 freelance)

2026-05-14 的某游戏公司笔试调研, mobile 把 PLAN 写得很好但执行时完全没调 capture 脚本, 全部 ad-hoc `exec-out screencap`, 产 0 bundle, 0 OCR. 复盘原文: "PLAN 写好了但执行时脑子空白, 全部用 ad-hoc exec-out screencap 代替". 下面 6 条铁律是这次的产物.

**对调研/采集类任务, 任何一条违反 → 当 turn 立即 STOP, 写 BLOCKER.md, 等指令.**

### 铁律 1: 禁止 ad-hoc 截图作为采集终点 + 必须 self-verify

- enter 笔记后, **唯一合法的图像采集动作**是: `xhs-capture-carousel.sh` / `xhs-capture-scroll.sh`
- `exec-out screencap` 只允许用于**诊断**(check 当前 activity, 调试 tap 位置), **不允许作为最终采集手段**
- 凡是产到 `captures/` 根目录而不在 bundle 子目录的 PNG, 都是违规

**单条笔记采集完必须产生**:
```
<bundle>/manifest.json
<bundle>/page-01.png  或 <bundle>/body-01.png  (至少 1 张)
<bundle>/ocr.md
<bundle>/comments.json  (如有评论, optional 但推荐)
```

**🔴 Self-verify (2026-05-15 加, Test 2 撒谎 bug)**:

mobile **不允许**在 `_progress.log` 写 "capturing X / bundle done" 类**假成果记录**. 每写一行 "bundle done", **必须先**:

```zsh
test -d "captures/<task>/<bundle-name>" \
  && test -f "captures/<task>/<bundle-name>/manifest.json" \
  && ls captures/<task>/<bundle-name>/*.png | head -1 \
  || { echo "[HH:MM] FAIL: $bundle no manifest/png — abort, not lying"; exit 1; }
```

- 写 "bundle X done" 时, 必须**先 verify** bundle dir 存在 + 含 manifest.json + 含至少 1 张 PNG
- 如果 verify 失败 → 在 progress.log 老老实实写 "FAIL: bundle X 没产物, mobile 在 freelance 用 screencap" 然后 STOP
- **绝对禁止**: 在没有 xhs-capture-* 输出的情况下, 把 `screen_NNN.png` (ad-hoc screencap) 包装成"已采集 bundle"
- **2026-05-15 Test 2 真踩**: mobile progress.log 假写 "capturing mimang_1_1, bundle 1/5 done", 实际 captures dir 0 个 mimang_X_X 子目录, 全是 screen_NNN.png. 这种**虚假报告**比真失败更糟, 因为它欺骗 conductor 跳过 retry.

**最终汇报**: mobile 跑完必须在 `_retro.md` 列出**真实**产物 (用 `find captures/<task> -name 'manifest.json'` 列), 不许 free-form 写 "5 个 bundle 都完成了". 如果 0 个 bundle, 就老实写 "0 valid bundle, 我违反了铁律 1".

### 铁律 2: AskNow AI 卡片处理

XHS 2026-05 起搜索结果首屏 60% 被 AskNow AI 摘要卡占据. 检测特征:
- 卡片顶部有"ai summarized notes & websites"标记
- 正文开头有 "🎮 岗位是做什么的?" / "💼 招聘要求看重什么?" 这类 emoji 小标题 + 摘要语气
- tap 进去后 URL 不是 `/note/<id>` 而是 AskNow 浮层

**应对**:
- 提交搜索后**默认 tap "Latest" 标签**, Latest 排序下 AI 卡片浓度显著降低
- 看到 AskNow 特征的笔记 → 直接跳过, 不要 tap 进去
- 同一搜索词如果前两屏 ≥80% 是 AI 卡片 + 营销号 → 收手, 换搜索词

### 铁律 3: 每 3 分钟 milestone 强制 + 5 min 无 bundle abort (v0.5 Test 3 升级 + v0.6 双保险)

- 每个明显进展 (开搜/进笔记/采集完成/换搜索词/碰到 stop 条件) 必须 append 一行到 `_progress.log`
- 格式: `[HH:MM] <stage> — <一句话状态>`
- 如果连续 5 分钟没有新 milestone (无论是在 think 还是在 tool call), 视为卡死, **自动 abort 当前任务**, 写 `STUCK.md` 描述卡在哪
- **v0.5 新增**: 5 分钟内**没有产新 bundle** (无论 progress.log 是否新), 也触发 abort + 写 STUCK.md
  - Test 3 翻车真实场景: mobile 每分钟 append "L1 prefilter check / waiting for L2 OCR", progress.log 一直更新, 但 0 bundle 产出 15 min. 这种 "progress 假活" 也算 stuck.

**v0.6 双保险机制** (Test 5 暴露: mobile 内部 self-check 不可靠, 走外部 watchdog 兜底):

**内部 self-check (mobile 主动, primary)**:
- 每次想 append progress.log 之前**先 check** 上一行时间戳
- 距离 now ≥ 5 min → 先写 STUCK.md 再 exit, 不要装"我还活着"继续 append
- 每次 enter 笔记后, **自查 STUCK.md 是否已存在** (watchdog 可能写了), 存在就立即 exit

**外部 watchdog (conductor 派, secondary)**:
- conductor dispatch mobile 时**同时** spawn `xhs-watchdog.sh <capture_dir> &` 在 background
- watchdog 每 60s check `_progress.log` size, 5 次没变 = 5 min stale → 自动写 STUCK.md
- watchdog 也 enforce 总 1900s timeout
- mobile 看到 watchdog 写的 STUCK.md → 立即停止 (铁律 3 自检)

**为什么双保险**: Test 3 + Test 5 都遇到 mobile silent stale 16+ min 没自报 — LLM agent 在长 think pass 中不会自动 wake up self-check. 外部 watchdog 是 OS-level 兜底.

- 这是给上游 (Claude Code / main agent) 看的, 让人知道你还活着

### 铁律 4: 同问题失败 3 次 → STOP + ask

- 如果同一类操作 (如"中文输入到搜索框" / "找笔记 URL" / "tap 笔记封面") 连续失败 3 次 → 立刻停
- 写 `BLOCKER.md` 描述: 你试了什么, 怎么失败的, 你猜的根因, 建议的解决方向
- **不要硬上**. 不要 freelance 找替代方案. 等上游决策.

### 铁律 5: UI 不匹配 runbook 描述 → escalate (静态: 文档过时)

- **触发**: XHS app 的某个界面跟 `XHS_RUNBOOK.md` 描述不一致 (元素位置变了 / 选项卡名变了 / 出现没见过的弹窗等)
- 这是**文档过时**问题, 不是 server-side drift (那是铁律 11)
- → 截图保存为 `UI_DRIFT_<HH-MM>.png`, 写 `UI_DRIFT.md` 描述差异
- **不要猜测继续操作**, 等上游确认 (可能需要更新 runbook)

### 铁律 6: 每条 bundle 完成立即落 vault (per-bundle 增量)

- **触发**: 每完成一条 bundle (OCR + comments 都跑完) 立刻执行
- copy `<bundle-dir>` 到 `$VAULT_ROOT/<topic-folder>/bundles/`
- 这是**增量 sync**, 防止 mobile 中途挂掉前面 bundle 丢失
- 跟铁律 10 的区别: 6 是 per-bundle 增量 (跑完一条就 sync 一条); 10 是 session 收尾时整 dir rsync (含 log/retro/misfire)
- vault root 默认 `$VAULT_ROOT` (默认 `$HOME/Documents/xhs-research-reports/`)
- 跟 user `feedback_outputs_to_vault.md` 一致

### 铁律 7: 留在 XHS app 内, 禁止 pivot 到浏览器 (2026-05-15 加, Test 1 freelance bug)

**2026-05-15 12:55 Test 1 (B 站笔试调研) 翻车原因**: mobile 在 XHS app 内中文输入失败 → 直接 `am start -a VIEW <xiaohongshu.com URL>` 跳到 Chrome 浏览器搜索. 这违反 AGENTS.md "Prefer official mobile apps when a web flow is unstable or redirect-heavy".

**铁律**:
- XHS 调研任务的**所有搜索/列表/笔记浏览**必须在 `com.xingin.xhs` app 内完成
- ⛔ **禁止**用 `am start -a VIEW` 跳到 `xiaohongshu.com` Chrome 网页版作为搜索/浏览手段
- ⛔ **禁止**任何 "app 不行就用浏览器" 的 freelance pivot
- ✅ **唯一允许**用 VIEW intent 的场景: 已经拿到具体 XHS 笔记 URL (xhslink/xiaohongshu.com/note/...), 调 `xhs-open-link.sh` 把它跳回 XHS app. **不是为了在 Chrome 里浏览**.

**app 内中文输入失败时的正确动作**:
1. 走 RUNBOOK "中文输入决策树" 三层兜底 (BlueStacks 剪贴板 → Clipper → ADBKeyboard)
2. 三层都失败 → 触发**铁律 4** (同问题 3 次 fail → STOP + 写 BLOCKER.md)
3. **不要**跳浏览器, **不要**用英文/拼音将就, **不要**找网页版替代

**为什么 app > web**:
- 网页版 XHS 内容残缺 (大多数笔记只能在 app 看), 数据质量低
- 网页版会强推 "下载 App" 弹窗 / 登录墙, 体验断裂
- 现有 `xhs-capture-*` 脚本全部针对 app UI, 网页版没有对应工具
- 信噪比和数据完整性差异显著, **app 数据不可被网页数据替代**

### 铁律 8: WebView 笔记跳过 (2026-05-15 加, Test 1 #4 bug)

`tap` 进笔记后**立即** check `currentFocus`:
- ✅ `NoteDetailActivity` → 走 capture 脚本
- ❌ 任何带 `WebView` / `Web` 的 activity → **立刻 back**, 标记跳过, 不计入 5 条上限
- 这类多是 "题库 / 汇总 / 全网最全" 营销号, capture 脚本不支持 WebView

### 铁律 9: Bundle 内容验证

每 bundle OCR 完后, `grep` ocr.md:
- 含目标关键词 token (e.g., "B站" / "笔试") → ✅ 保留
- 完全不含 → ❌ 移到 `_misfires/`, 不计入 5 条上限, 标 freelance bug
- 防 Test 1 #4 "B 站搜索 → 装了澳洲找工 bundle" 类型错误

### 铁律 10: session 收尾整 dir rsync 到 vault (全量 final sync)

- **触发**: mobile session 结束前 (写完 _retro.md 之后)
- `rsync -a $CAPTURE_DIR/ $VAULT_ROOT/<topic-folder>/_run_data/`
- 包含: bundle / ad-hoc PNG (诊断用) / log / retro / _misfires / STUCK.md / BLOCKER.md / UI_DRIFT.md
- 跟铁律 6 区别: 6 是 per-bundle 跑完一条 sync 一条 (防丢失); 10 是 session 结束整 dir sync (含失败诊断材料, 做 regression test 用)
- 失败 bundle 也保留, 不要清理

### PLAN 预筛 (营销号 prefilter)

列表页候选选择时, 命中以下 pattern **跳过, 不 enter**:
- 标题: `题库` / `汇总` / `全网最全` / `\d{4}-\d{4}` (年份范围) / `兄弟们 收藏不亏` / `为你整理`
- 这些 90% 是 WebView + 内容偏题 + 文末挂私域

### 铁律 11: 同 session 内 UI mid-drift → STOP (动态: server-side 变, 2026-05-15 Test 1 下午回归 bug)

**触发**: 同一个 mobile session 内, 某个动作 (deep link / tap 搜索框 / Latest 切换) 在 session 开头 work, 中途突然 → 落地不同 Activity / 行为不一致. **不是文档过时** (那是铁律 5), 是 XHS server-side 实验改了 routing 或 client-side 推新版.

**典型场景 (Test 1 真实踩到)**:
- 12:50 fire `xhsdiscover://search/result?keyword=B站 笔试` → `GlobalSearchActivity` (用户笔记列表) ✅
- 16:44 同样的 deep link → `SearchAgentPageActivity` (AskNow AI WebView) ❌
- XHS 在 session 期间做了 server-side 或 client-side 更新, 行为变了

**应对**:
1. 立刻停止当前任务
2. 写 `UI_DRIFT.md` 描述差异 (which deep link / which activity then-vs-now)
3. **不要**在退化的 UI 上硬上, 不要 freelance 找绕过 (e.g., 不要切 Chrome — 那是铁律 7)
4. 等上游 (Claude Code / 用户) 决定是否换策略

**预防 / 早检**:
- 每次切换搜索词前, fire deep link 后**立即** check `dumpsys window | grep mCurrentFocus`
- 如果落地 Activity 不是 `GlobalSearchActivity` (或 NoteDetailActivity 等已知好的) → 立即 STOP, 不要继续 tap

---

### 铁律 12: enter 笔记前必须做 L1 prefilter audit (2026-05-15 加, Test 2 营销号红海 bug)

**触发**: 在搜索结果列表页, 决定 tap 哪条笔记之前.

**规则**:
- enter 笔记前必须看标题, 按 PLAN 的 L1 prefilter 标准过一遍
- 命中跳过项 → **不 enter**, 在 `_progress.log` 写一行:
  ```
  [HH:MM] skip: "<title>" reason: L1-listicle/L1-emoji/L1-warning
  ```
- **绝对禁止**: 没看标题就 tap (Test 2 mobile 就是 quota 优先, 5/6 是营销号)
- **0 skip 记录 = 没做 prefilter**: 一次调研 5 条 enter, 应当配套 ≥ 5 条 skip 记录 (search 列表一屏就有 10+ 标题, 营销号至少占一半). 0 skip = mobile 跳过 prefilter.
- **平衡 (v0.5)**: L1 skip 不能 > 60% 候选, 至少留 5 个 enter. 过严就 relax (e.g., 拿掉 "教程"/"使用" 这种边缘词).

**Test 2 真踩**:
- 主题 "人迷茫怎么办", PLAN L1 写得严 (listicle / emoji / 警告 / 套话)
- mobile 进 GlobalSearchActivity 后直接 tap (360, 1150) 之类坐标, **跳过标题判断**
- 结果 6 个 bundle 里 5 个营销号 (#致乘风破浪的自己 / 30件事 / 人民日报金句 / 培训机构招生)
- 信噪比 1.7/10, 远低于预期 3-5/10

**为什么会发生**: mobile 在采集时优化的指标是 "5/5 quota 完成", 而不是 "5/5 quality"。要把 quality 评估前置到 mobile 端, 必须强制 audit trail (skip 记录)。

---

### 铁律 13: enter 笔记后 3 min 内必须产 bundle (2026-05-16 加, Test 3 prefilter 过严 bug)

**触发**: tap 笔记封面之后 (NoteDetailActivity 已经显示).

**规则**:
- enter 笔记后, **3 分钟内**必须运行 xhs-capture-carousel.sh / xhs-capture-scroll.sh 产 manifest.json + ≥1 PNG
- 超时 → 当前笔记标 misfire, back 到列表, 不算 1/5 quota
- **绝对禁止**: 进笔记后无限 L2 OCR / think / 等待
- L2 OCR 单页 ≤ 30s, 不要全文 carousel OCR 来判断要不要 capture (一旦 enter 就直接 capture, OCR 在 capture 之后做)

**Test 3 真踩**: mobile 在 GlobalSearchActivity 找到 A 级候选 "我让某AI产品做个 PPT", 但**没 tap 进去**, 在 prefilter / L2 想象阶段卡 7 min. 结果是: prefilter audit trail 完美, 但 0 bundle.

**修正 mental model**: prefilter 是为了**减少错的 enter**, 不是为了 100% 完美预判. 想 enter 就立刻 tap + capture. capture 完了再回头看 OCR 决定是否标 valid.

---

### 铁律 16: 每个 kw fire 后必跑 xhs-set-note-filter.sh (2026-05-17 加, 用户教的)

**触发**: 每次 fire `xhsdiscover://search/result?keyword=<X>` 之后, 在 enter 任何笔记之前.

**规则**: 强制跑 `./scripts/xhs-set-note-filter.sh` 把 search filter Note type 设成 "Note" (图文), 排除 Video / Live.

**为什么**: conductor skill **专做图文调研**, mobile 当前架构不支持视频 capture. 不带 filter → vlog 笔记跳 DetailFeedActivity → mobile 死循环 (Test 11 真踩). 加 filter 后:
- 所有 enter 100% 进 NoteDetailActivity
- 不再触发铁律 15 (DetailFeed 循环)
- 不再浪费 quota 在 vlog 候选上

**workflow**:
```bash
adb shell "am start -W -a android.intent.action.VIEW -d 'xhsdiscover://search/result?keyword=$ENC' com.xingin.xhs"
sleep 3
./scripts/xhs-set-note-filter.sh   # mandatory, ≤ 5 sec
# 现在 list 纯图文
```

**视频笔记单独 channel**: 用户主动发视频链接给 conductor 走 `xhs-open-link.sh` 直接采单条, 不在调研流程里. 两条 channel 分离, 互不影响.

**v0.8 验证**: T11→T12→T13 三次连续验证, 7/7 enter NoteDetailActivity, 0 DetailFeedActivity. Production-ready.

---

### 铁律 17: 每个 bundle 独立 output_dir, 禁止复用 (2026-05-17 加, T13 真踩)

**触发**: `xhs-capture-carousel.sh --output-dir <X>` 必须每个 bundle 唯一.

**真实场景 (T13)**: kim_2_2 manifest title 是 "某AI助手 两周使用体验" 但 OCR 内容是上一主题 T12 的. 推测: 上一个 bundle 的 screenshots 目录没清理, OCR 跑到错的图.

**规则**:
- `--output-dir <CAPTURE_DIR>/bundles/<bundle_name>` 必须唯一 per bundle
- 不要复用 `~/.openclaw/workspace-mobile/screenshots/` 默认路径
- xhs-capture-carousel.sh 内部应该在写之前 `rm -rf` 目标 dir (待加)
- bundle dir 写完后 `find $BUNDLE/screenshots -name '*.png'` 必须只属于该 note (验证)

**临时绕过**: 每次 capture 之前手动 `rm -rf $CAPTURE_DIR/screenshots/*` (TODO: script-side 永久 fix)

---

### 铁律 18: 看到 XHS "可能含AI生成内容" 标签 → 直接降为 C 级 (2026-05-17 加, T13 真踩)

**触发**: OCR 含字符串 "可能含AI生成内容" (XHS 平台自动标的, 不是用户加的).

**真实场景 (T13)**: kim_1_2 "某AI助手 使用测评" 被 XHS 自动标了 "可能含AI生成内容". AI 工具测评类内容很多本身就是 AI 写的 (用 AI 写吹捧该 AI 的笔记). 平台已识别, conductor 不应再当真实 OP.

**规则**:
- mobile 端: 不需特殊处理, 照常 capture (info 留着)
- conductor 端 (Phase C 综合): grep `"可能含AI生成内容" ocr.md` → 该 bundle **直接降为 ⚠️ / C 级**, 不进 A/B 推荐
- 标在报告里, 让用户知道平台标了 AI 嫌疑

**为什么不一开始就 skip**: 平台标签 ≠ 一定是 AI 写的, 有 false positive. 留 OCR 给用户自己看, 但不当真实数据.

---

### 铁律 15: DetailFeedActivity 循环 → STOP 当前 kw (2026-05-17 加, Test 11 海外留学主题卡 vlog)

**v0.8 更新**: 铁律 16 加 filter 后基本不会触发. 保留作兜底 (XHS UI 改了 filter 失败时还有保护).


**触发**: 同一 kw 内, 连续 ≥ 3 次 enter 笔记 → DetailFeedActivity (XHS 的 vlog / 视频 immersive 流)

**真实场景 (Test 11)**: 主题 "海外留学生活", kw "留学生 生活" / "留学 日常" 大量 vlog 视频笔记. mobile 严守铁律 8 skip DetailFeed, 但**整个 kw 全是 vlog**, mobile 死循环找图文笔记, conductor 端手动 kill 才停.

**规则**:
- 同 kw 内, 计数 `detail_feed_skip_count`
- ≥ 3 → 写 `[HH:MM] kw <X> all DetailFeedActivity (vlog) - 跳过整 kw` 然后 switch 下一个 kw
- 不要硬撞剩下 5+ 个候选都是 vlog 的列表

**为什么不一开始就识别**: search list 里 vlog 跟图文笔记**封面长得一样** (都是 square thumbnail), mobile 在 list 看不出来, 必须 tap 进去看 Activity 才知道. 所以**连续 skip 计数** 是唯一可行办法.

**v0.8 长期方向**: 加 xhs-capture-detailfeed.sh 支持视频笔记 (抓首帧 + 视频描述 text, 不抓视频本身).

---

### 铁律 14: 每个 turn 开头 check XHS focus (2026-05-16 加, Test 3 失焦 bug)

**触发**: mobile 每个 turn 开始, 在做任何 tap / capture 之前.

**规则**:
- 第一动作: `dumpsys window | grep mCurrentFocus`
- ✅ focus 含 `com.xingin.xhs` → 继续
- ❌ focus 是 `com.uncube.launcher3` / `null` / 其他包 → 立即 `xhs-clean-launch.sh` 重启 XHS, 然后**重新** fire 上次的 deep link
- 如果重启 3 次还失焦 → 触发**铁律 4** (STOP + BLOCKER.md)

**Test 3 真踩**: mobile abort 时 mCurrentFocus = null. XHS 已经被 OS 暂停, mobile 一直在对着 launcher 操作, 自然产不了 bundle. Mobile 没察觉.

---

## 🔑 中文搜索 — 已验证的方法 (2026-05-15 更新, **不用打字了**)

### ✅ 首选: XHS deep link scheme (绕过键盘)

**结论**: XHS 搜索完全**不需要输入文字**. 用 `xhsdiscover://search/result?keyword=<urlencoded>` deep link 直接弹到搜索结果页.

**已验证可用**:
```zsh
# 把关键词 url-encode
ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "B站 笔试")

# fire 搜索
adb -s 127.0.0.1:5555 shell "am start -W -a android.intent.action.VIEW \
  -d 'xhsdiscover://search/result?keyword=$ENCODED' com.xingin.xhs"
```

行为:
- 直接打开 `GlobalSearchActivity` 显示搜索结果
- 关键词出现在搜索栏顶部
- 默认落在 "Top" 排序 tab — 按**铁律 2** 你需要紧接着 tap "Latest" 来绕 AskNow AI 卡

**URL-encode 关键**:
- 中文字符必须 url-encode (e.g., "笔试" → `%E7%AC%94%E8%AF%95`)
- 空格 → `%20`
- ASCII 字母数字保持原样

**确认验证 (2026-05-15 12:50-13:10)**:
- ✅ 已知关键词 (在 Recent searches 里): 某公司笔试 — 直接出结果
- ✅ 全新关键词: "相机 推荐" — 直接出结果, 不需要先 Recent

### 备选: ADBKeyboard 广播 (已装但在 BlueStacks 上不稳)

如果 deep link 路径未来失效, 备用方案:
- APK 已装在 BlueStacks: `com.android.adbkeyboard/.AdbIME`
- 启用: `adb shell ime enable com.android.adbkeyboard/.AdbIME`
- 切换: `adb shell ime set com.android.adbkeyboard/.AdbIME`
- 广播: `adb shell "am broadcast -a ADB_INPUT_TEXT --es msg '<text>'"`
- **现状 (2026-05-15)**: IME 切换成功但 broadcast 不进 EditText, 在 BlueStacks Air 上没工作通. 留作备份, 不作首选.

### 不要用 (踩过坑)
- ❌ `adb shell input text "中文"` — 抛 NullPointerException, 不支持非 ASCII
- ❌ `am start -a android.intent.action.SEARCH --es query` — XHS 不响应 SEARCH intent
- ❌ 跳 Chrome 网页版 — 违反**铁律 7**, 直接 STOP

### 决策树 (调研类任务)
```
需要搜索 X
  ↓
url-encode X → fire xhsdiscover://search/result?keyword=<encoded>
  ↓ 成功 (一般 100% 成功)
落 GlobalSearchActivity → tap Latest tab → 走原标准 capture 流程
  ↓ 失败 (deep link 不响应)
触发**铁律 4**: 同问题失败 3 次 → STOP + BLOCKER.md
  ⛔ 不要 freelance 找 Chrome / web 版替代
```

### 其他需要中文输入的场景 (非搜索)
- 评论 / 发帖 / 私信: 走 ADBKeyboard 备选 (但通常**不应该**做这些操作 — 是 publishing 行为, 不属于调研 skill 范畴)
