# Mobile 任务卡模板

> **v0.11**: 推荐**永远通过 `xhs-research-dispatch.sh [--mode fast|deep]`** 派发, 不要手搓 message. dispatch.sh 已含: 单例检查 / watchdog 启停 / TG push / cleanup / mode caps / auto-fabricate retro. 下面是 dispatch.sh 内部逻辑参考, 极少需要手动覆盖.

## Backend 抽象

| Backend | 适用 | 怎么调 |
|---|---|---|
| `openclaw-mobile` (默认) | 有 BlueStacks + XHS app + 登录态 | `openclaw agent --agent mobile --thinking medium --timeout 1900 --message "..."` |
| `playwright` (v1.x) | 无 mobile, 只有浏览器 | TBD |
| `manual` (兜底) | 啥都没有 | 告诉用户搜词 + 收用户截图到 `${CAPTURE_DIR}/` |

检测 openclaw-mobile:
```bash
test -f ~/.openclaw/workspace-mobile/AGENTS.md && echo "available"
```

## 首次跑前 (mandatory)

conductor 派 mobile **前**, 先跑一次:
```bash
~/.openclaw/workspace-mobile/scripts/xhs-setup.sh
```
6 项检查 (ADB / tesseract / device / XHS app / login). 任一 ❌ → 不要派 mobile, 把 fix 指导给用户 + 等 setup 后重派.

## 派发时 spawn watchdog (v0.6 mandatory)

```bash
CAP_DIR=/path/to/captures/<task>
~/.openclaw/workspace-mobile/scripts/xhs-watchdog.sh "$CAP_DIR" 5 60 &
WATCHDOG_PID=$!
# 然后 dispatch mobile (同样 background)
openclaw agent --agent mobile --thinking medium --timeout 1900 --message "..." > "$CAP_DIR/_mobile_run.log" 2>&1 &
MOBILE_PID=$!
# 等 mobile 完成 / 自杀, 然后 cleanup watchdog
wait $MOBILE_PID
kill $WATCHDOG_PID 2>/dev/null || true
```

watchdog 在 5 min progress stale 时自动写 STUCK.md, mobile 看到自检退出.

## 完整 message 模板

```
任务: <topic> 主题 XHS 调研 (mode=<fast|deep>)
PLAN: ${CAPTURE_DIR}/PLAN.md (已写好, 你直接读)
输出位置: ${CAPTURE_DIR}/  (你产生的所有文件放这)
Bundle 输出目录: 给 xhs-capture-* 传 XHS_SCREENSHOT_DIR=${CAPTURE_DIR}/bundles + 第二位置参数 <bundle-name>

⚡️ Mode caps (v0.11, dispatch.sh 已注入):
  - fast: 目标 ≥ 3 bundle, carousel 每 bundle 最多 4 页, **skip** xhs-extract-comments.sh
  - deep: 目标 ≥ 4 bundle, carousel 最多 20 页, **跑** xhs-extract-comments.sh

⭐ 笔记标题 + 原始链接抓取 (v0.10 mandatory: 没 URL 用户无法回溯原帖):
**enter 任何笔记后第一动作**, 在 capture 之前:
  TITLE=$(./scripts/xhs-get-note-title.sh)
  URL=$(./scripts/xhs-get-note-url.sh 2>/dev/null || echo "")
  export XHS_TITLE="$TITLE"
  export XHS_SOURCE_URL="$URL"
  export XHS_SCREENSHOT_DIR="${CAPTURE_DIR}/bundles"
  ./scripts/xhs-capture-carousel.sh <CAROUSEL_PAGES> <bundle-name>   # fast=4, deep=20
**body capture 同样 export 两个 var** (同笔记同 title + url)
manifest.json `title` + `source_url` 都不再是空字符串.

URL 抓取走 BlueStacks 剪贴板同步: 点 ... 菜单 → Copy link → pbpaste 拿 xhslink URL.
失败 (空字符串) 不阻塞 capture, 但 bundle 标 unverified, 报告里那条 OP 会显示 ⚠️ no source.

⚠️ 14 条铁律 (完整版见 XHS_RUNBOOK.md, 违反就 STOP + BLOCKER.md):
1. enter 笔记必走 xhs-capture-*, 禁 ad-hoc screencap. 写"bundle done"前必 self-verify (manifest.json + ≥1 PNG)
2. 优先 Latest 排序绕 AskNow (Latest tab tap 可能落 WebView, 直接 nav 笔记 cards)
3. 每 3 min 必写 _progress.log; 5 min 无 progress 或无 bundle = 自动 abort + STUCK.md
   **v0.6: 每 turn 开头 check `$CAPTURE_DIR/STUCK.md` 是否已存在 (watchdog 可能写了), 存在就立即写 _retro.md (含 "STUCK by watchdog at <time>") 然后 exit**
4. 同问题 fail 3 次 → STOP + BLOCKER.md
5. UI 不匹配 runbook → escalate
6. bundle + log + retro 全部 rsync 到 vault
7. 禁 pivot Chrome / web 版
8. WebView 笔记立即 back + 不计上限
9. Bundle OCR 含目标关键词 token 才算 valid
10. (合并到铁律 6)
11. UI mid-drift → STOP + UI_DRIFT.md
12. enter 笔记前必 L1 prefilter audit. _progress.log 写 `[HH:MM] skip: "<title>" reason: L1-xxx`. 0 skip = 没 prefilter
13. enter 笔记后 3 min 内必产 bundle. 超时 misfire + back, 不算 quota
14. 每 turn 开头 check mCurrentFocus 含 com.xingin.xhs; 不在 → xhs-clean-launch.sh 重启

⚠️ Prefilter 平衡:
- L1 skip ≤ 60% 候选; ≥ 5 enter 候选; 每 kw 至少 1 bundle
- 一个 kw 0 bundle 不能直接换 kw → 写 BLOCKER (PLAN L1 标准太严)

跑完返回 (写到 ${CAPTURE_DIR}/):
- _retro.md 列**真实**产物路径 (`find $CAPTURE_DIR -name manifest.json`)
- bundle 路径 list (全路径)
- _progress.log 摘要 (含 skip 记录)
```

## 超时

- 命令端 timeout: 1900s (~31 min)
- Mobile stop 条件: mode 目标 bundle 达成 (fast ≥3 / deep ≥4) / 30 min / 信噪比降 / 任一硬 stop

## 失败处理

| 返回 | 动作 |
|---|---|
| 达到 mode 目标 bundle (fast ≥3 / deep ≥4) | 进 Phase C |
| 部分 bundle (≥ 2) | 进 Phase C, 标小样本 |
| 0 bundle + BLOCKER | **不进 Phase C**, 告诉用户原因, 问换 backend / 换主题 |
| 0 bundle + STUCK | 看 _progress.log 判断 prefilter 是否过严, conductor 决定手动 retry 还是 abort |
