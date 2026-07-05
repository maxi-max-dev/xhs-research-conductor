# Quickstart — xhs-research-conductor

> **3 步上手** XHS 调研 skill. 用了之后任何 agent (Claude Code / OpenClaw / Codex) 都能给你做小红书主题调研, 自动出 Obsidian vault 报告.

## 前提

- macOS (M-chip 原生 BlueStacks Air; Win/Linux 可用其他模拟器, 见底部)
- 一个 Claude 账号或其他 LLM agent
- 30 分钟时间 (首次装 BlueStacks + XHS app + 登录)

---

## Step 1 — 装系统依赖 (5 分钟)

```bash
# ADB (Android 设备桥)
brew install --cask android-platform-tools

# tesseract OCR (本地中文识别, 不走 LLM image tool)
brew install tesseract tesseract-lang
```

验证:
```bash
adb --version    # 应输出版本号
tesseract --list-langs | grep chi_sim   # 应有 chi_sim
```

---

## Step 2 — 装模拟器 + XHS app + 登录 (10 分钟)

### A. 装 BlueStacks Air (推荐)

```bash
brew install --cask bluestacks
open /Applications/BlueStacks.app
```

> 也可以用 Genymotion / Android Studio AVD / 真机. skill 会自动 detect 任意一个 (见 `detect-emulator.sh`).

### B. 装 XHS app

1. 在 BlueStacks 里打开 Play Store (Google 账号登录)
2. 搜 "小红书" → install
3. 或 sideload APK: `adb -s 127.0.0.1:5555 install xhs.apk`

### C. 登录 XHS

1. 打开 XHS app
2. **手机号登录 + 验证码** (推荐, 比微信 / 微博稳定)
3. 完成后停在 "首页" feed (不是任何 onboarding / 引导页)

---

## Step 3 — clone skill + 自检 + 跑第一个调研 (15 分钟)

### A. clone skill

```bash
# 如果你用 OpenClaw:
git clone https://github.com/<user>/xhs-research-conductor ~/.openclaw/workspace/skills/xhs-research-conductor

# 把 mobile dependencies (RUNBOOK + scripts) 链到 mobile workspace:
mkdir -p ~/.openclaw/workspace-mobile
cp ~/.openclaw/workspace/skills/xhs-research-conductor/mobile-dependencies/XHS_RUNBOOK.md ~/.openclaw/workspace-mobile/
cp ~/.openclaw/workspace/skills/xhs-research-conductor/mobile-dependencies/scripts/*.sh ~/.openclaw/workspace-mobile/scripts/
chmod +x ~/.openclaw/workspace-mobile/scripts/*.sh
```

### B. 自检

```bash
~/.openclaw/workspace-mobile/scripts/xhs-setup.sh
```

应该看到:
```
[1/5] ADB                        ✅
[2/5] tesseract + chi_sim        ✅
[3/5] device connected           ✅
[4/5] XHS app installed          ✅
[5/5] XHS logged in              ✅
🎉 Setup complete!
```

任一 ❌ → 按 fix 指导处理后重跑.

### C. 配置 vault 路径 (optional)

默认存到 Obsidian iCloud vault. 改其他位置:
```bash
# in ~/.zshrc
export VAULT_ROOT="$HOME/Documents/research-notes"
export XHS_RESEARCH_LOG="$HOME/.xhs-research-logs"
```

### D. 跑第一个调研

在 Claude Code / OpenClaw 里说:

> "调研一下 某公司校招笔试"

(或任何主题: `GLM 模型好用吗` / `25 岁失业怎么办` / `某AI产品 体验` / `某公司 实习`)

skill 会:
1. Phase A: 自动生成 5 个 XHS 搜索词
2. Phase B: 派 mobile agent 在 XHS app 内 (BlueStacks) 实际搜 + 看 + 截图 + OCR
3. Phase C: 综合落 vault `<topic-folder>/<topic>_<date>.md`

总耗时 15-30 min. 你看 vault 报告即可.

---

## 常见问题

### Q: 我是 Windows / Linux?
A: skill 用 BlueStacks Air (Mac only). Win/Linux 可以装 **Genymotion** 或 **Android Studio AVD**. `detect-emulator.sh` 会自动认这两种 (优先级 BlueStacks > Genymotion > AVD).

### Q: 我不想装 BlueStacks?
A: v1.x 计划加 playwright backend (走 XHS 网页版). 现在: 试 Genymotion 或 AVD.

### Q: 搜出来全是营销号怎么办?
A: skill 有 3 级 prefilter + 报告会写 `verdict_source_fit: low` + 推荐换源 (豆瓣/即刻/知乎). 不会硬挤出来一份糖衣报告.

### Q: mobile agent 跑飞了怎么办?
A: 14 条铁律已经硬绑死 mobile (see `XHS_RUNBOOK.md`). 任一违反 → 立即 STOP + 写 BLOCKER.md. 不会 freelance.

### Q: 5min LLM 墙撞过吗?
A: skill 全程**不调 LLM image tool**, OCR 走 tesseract 本地. carousel 多到 12 页也没事.

---

## 调试 / 学习

- **看 Test history**: 4 个真实主题的 retro 在 `references/` (公司笔试 / 人生方法论 / AI 产品 / 雇主评估)
- **改 PLAN 阶段策略**: `references/keyword_templates.md`
- **改营销号 prefilter**: `references/marketing_account_prefilter.md`
- **改报告格式**: `references/report_format.md`
- **看 mobile 的 14 条铁律**: `mobile-dependencies/XHS_RUNBOOK.md`

---

## License

MIT. See `LICENSE`.

## Issues / PR

GitHub: [xhs-research-conductor issues](https://github.com/<user>/xhs-research-conductor/issues) — 跨平台 (Win / Linux) 测试 PR 特别欢迎.
