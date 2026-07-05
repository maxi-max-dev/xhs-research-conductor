# xhs-research-conductor

> Topic → Phase 0 vault history check → keyword brainstorm → XHS mobile capture → OCR → auto-synthesize vault report. **Conductor skill** that orchestrates existing skills + mobile agent, doesn't reinvent.

**Status**: v0.16.3 (32 dogfood tests T1-T32, 2026-05 → 2026-07). ship-to-C ready. Fast mode ≈ 5-10 min with a strong mobile model; with weaker/slower models expect 15-30 min — the run survives LLM single-request timeouts via auto-resume + OCR salvage + incremental retro (T32-verified). Auto vault md output, no Claude conductor介入 required for end-user.

---

## What this is

You say: **"调研一下 GLM 模型好用吗"** / **"看看某公司校招笔试怎么考"** / **"AirPods 4 值不值"**

The skill:
1. **Phase 0** — Grep vault for existing report on same topic (within freshness window: 笔试 180d / 工具评测 90d / default 30d). Found → 短路 return existing path, no rerun
2. **Phase A** — Brainstorm 3 (fast) or 5 (deep) search terms tailored to topic intent
3. **Phase B** — Delegate to **mobile agent** to open XHS (小红书) app and capture
4. Capture relevant notes via `xhs-capture-carousel.sh` / `xhs-capture-scroll.sh`
5. Run local OCR (tesseract chi_sim+eng)
6. **Phase C** — Auto-synthesize vault md (`xhs-synthesize-vault.sh`): 一句话结论 + 笔记摘要 (with xhslink URLs) + Coverage Gap

What it's **NOT**:
- Not a general web research skill (XHS-only by design)
- Not a publishing skill (read-only research, no posting)
- Not an XHS scraper (uses the actual app via Android emulator, not API)

---

## Requirements

| Dependency | Why | Install |
|---|---|---|
| An agent runner | Executes the capture directive (opens XHS app, drives scripts) | Default: OpenClaw `mobile` agent in `~/.openclaw/workspace-mobile/`. **Any agent works** — set `XHS_AGENT_CMD` (see Bring your own agent) |
| Android emulator + XHS app + login | Capture backend | [BlueStacks Air](https://www.bluestacks.com/) (M-chip native, free) |
| ADB | Connect to emulator | `brew install --cask android-platform-tools` |
| tesseract + chi_sim | Local OCR | `brew install tesseract tesseract-lang` |
| jq | manifest parsing | `brew install jq` |
| python3 | URL encoding + UI dump parsing | usually preinstalled |

Optional:
- Obsidian vault (vault path configurable via `VAULT_ROOT` env)
- Telegram bot (for progress push, configured per OpenClaw scripts)

---

## Installation

```bash
# 1. clone — anywhere you like (v0.16.3: all paths resolve relative to the
#    scripts' own location; no hardcoded install dir)
git clone <repo-url> ~/xhs-research-conductor
chmod +x ~/xhs-research-conductor/mobile-dependencies/scripts/*.sh

# (OpenClaw users only) put the skill + scripts where OpenClaw looks:
#   git clone <repo-url> ~/.openclaw/workspace/skills/xhs-research-conductor
#   cp ~/.openclaw/workspace/skills/xhs-research-conductor/mobile-dependencies/scripts/* \
#      ~/.openclaw/workspace-mobile/scripts/

# 2. install brew deps
brew install tesseract tesseract-lang jq
brew install --cask android-platform-tools bluestacks

# 3. emulator → install XHS app → 登录 (one-time). BlueStacks is the tested
#    default; any emulator works (see Any emulator below)

# 4. verify
~/xhs-research-conductor/mobile-dependencies/scripts/xhs-setup.sh   # should be 6/6 pass
```

`xhs-setup.sh` is self-healing (v0.14): if BlueStacks ADB offline, it will adb kill+restart, auto-launch BlueStacks, retry XHS launch via 3 fallbacks (monkey → am start resolved activity → VIEW intent on deep link).

### Any emulator (v0.16.3)

Device selection (`detect-emulator.sh`, used by every script):
1. `ANDROID_SERIAL` env — point at ANY adb device, emulator or real phone
2. `XHS_EMULATOR` env — `bluestacks` / `genymotion` / `avd`
3. Auto-detect: BlueStacks (`:5555`) → Genymotion (`:6555`) → AVD (`emulator-5554`) → first real device

All tap/swipe coordinates were tuned on 1440x2560; since v0.16.3 they scale proportionally to your actual `wm size` resolution (exact identity on 1440x2560, best-effort elsewhere — same-ish aspect ratios work best; grossly different aspect ratios are untested). BlueStacks-specific niceties (self-heal, clipboard URL capture) degrade gracefully on other emulators.

---

## Configuration

`~/.zshrc` or `~/.bashrc`:

```bash
# Vault root (where reports auto-land). Default: ~/Documents/xhs-research-reports
# Obsidian users: point it at your vault, e.g.
#   export VAULT_ROOT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/<YourVault>"
export VAULT_ROOT="$HOME/Documents/xhs-research-reports"

# Self-learning log location.
export XHS_RESEARCH_LOG="$HOME/.openclaw/_research_method_log"

# Optional (v0.16): per-run model / thinking override for the mobile agent.
# Thinking levels are model-specific — leave unset unless you know your model.
export XHS_MODEL=""       # e.g. "anthropic/claude-sonnet-5"
export XHS_THINKING=""    # e.g. "adaptive"
```

### Bring your own agent (v0.16.2)

The only OpenClaw-specific line in the whole pipeline is the agent spawn. Dispatch always writes the full capture directive to `<capture_dir>/_directive.md`; set `XHS_AGENT_CMD` and dispatch will invoke **your command** with the directive file path as its single argument instead of the OpenClaw mobile agent. Everything else (watchdog, resume, OCR salvage, retro fabricate, vault synthesis) is agent-agnostic shell.

```bash
# Example adapter: Claude Code as the capture worker
cat > ~/bin/xhs-agent-claude.sh <<'SH'
#!/bin/bash
exec claude -p "$(cat "$1")" --permission-mode acceptEdits
SH
chmod +x ~/bin/xhs-agent-claude.sh
export XHS_AGENT_CMD="$HOME/bin/xhs-agent-claude.sh"
```

Requirements for the agent: it runs on the same machine, can execute shell (the `xhs-*.sh` scripts referenced in the directive), and follows the directive's progress-log/retro contract. The OpenClaw path is the battle-tested default; the hook itself is new — treat it as experimental and read `_progress.log` on your first run.

---

## Usage

### Via natural language

Trigger phrases:
- "调研一下 X" / "research X"
- "看看小红书 X 怎么样"
- "X 怎么样" / "X 好用吗" / "X 笔试" / "X 面经" / "X 值不值"

### Or directly

```bash
# fast (default, 5-10 min, 3 kw × 1 bundle × 4 pages cap)
xhs-research-dispatch.sh 21 airpods4 ap4 "AirPods 4 值不值得" \
  "AirPods 4 评测" "AirPods 4 缺点" "AirPods 4 vs Pro"

# deep (15-30 min, 5 kw × ≥4 bundle × 20 pages + comments)
xhs-research-dispatch.sh --mode deep 22 acme acm "某公司 校招 笔试" \
  "某公司 笔试" "某公司 面经" "某公司 校招" "某公司 实习" "某公司 员工体验"

# force rerun (skip Phase 0 history check)
xhs-research-dispatch.sh --force 23 airpods4 ap4 "AirPods 4 值不值得" ...

# serial: one keyword per agent run, looped (recommended for multi-kw with
# slower models — each run stays under the ~10 min LLM single-request wall)
xhs-research-serial.sh --comments on --target 2 --pages 6 --mode fast \
  24 notion-vs-obsidian nvo "Notion vs Obsidian" "Notion 缺点" "Obsidian 上手" "Notion vs Obsidian"
```

### Output — fully user-selectable (v0.16.3)

Each successful run produces:
- `<VAULT_ROOT>/<folder>/<topic>_<date>.md` — **main report you read** (auto-synthesized)
- `<XHS_CAPTURE_ROOT>/<date>-<slug>/_retro.md` — mobile's own retro (verdict + 笔记摘要)
- `<XHS_CAPTURE_ROOT>/<date>-<slug>/bundles/<bundle>/{manifest.json,ocr.md,page-NN.png}` — raw capture
- `<XHS_CAPTURE_ROOT>/<date>-<slug>/_progress.log` — execution timeline (enter / captured / FAIL / startup)
- `$XHS_RESEARCH_LOG/_research_method_v<N>.md` — skill self-evolution log

Where everything lands is yours to choose:

| Env | Controls | Default |
|---|---|---|
| `VAULT_ROOT` | report root dir (auto-created) | `~/Documents/xhs-research-reports` |
| `VAULT_FOLDER` | exact report subfolder, overrides classification | — |
| `XHS_FOLDER_STYLE` | `plain` (career/ \| reviews/) / `emoji` (💼Career/ \| 📚学习/工具评测/, for Obsidian emoji vaults) / `flat` (no subfolder) | `plain` |
| `XHS_CAPTURE_ROOT` | raw captures dir | `<repo>/mobile-dependencies/captures` |
| `XHS_SCRIPTS_DIR` | scripts location override | where the scripts live |

Topic auto-classification (plain/emoji styles): 笔试/面试/校招/秋招/实习/简历 → career, everything else → reviews.

---

## How it compares

Plenty of excellent XHS data tools exist — [MediaCrawler](https://github.com/NanmiCoder/MediaCrawler) (Playwright crawler, structured data at scale), [xiaohongshu-mcp](https://github.com/xpzouying/xiaohongshu-mcp) (headless-browser MCP for AI assistants), XHS-Downloader, etc. If you need raw data, use those — they're more mature at collection.

This project is a different layer: a **research methodology conductor**. Keyword-strategy templates, marketing-account prefiltering, signal-to-noise scoring, and honest reports that tell you to *stop using XHS for this topic* when the signal isn't there. It drives the real Android app (login-walled content included) and is honest about every limitation below. As far as we know nothing open-source does this layer yet.

---

## Architecture (v0.16.3)

```
User: "调研 X"
  ↓
Phase 0  — xhs-vault-history-check.sh
            Found within window → exit, return path  ← Most common path
            Not found → continue
  ↓
Phase A  — Conductor (Claude) brainstorms kw (3 fast / 5 deep)
  ↓
Phase B  — xhs-research-dispatch.sh
            ├─ Singleton check (no concurrent mobile)
            ├─ Defensive cleanup (XHS + Chrome close)
            ├─ Spawn mobile agent + watchdog
            ├─ mobile: startup self-check (resume / fresh / 接力)
            ├─ mobile: per-kw flow (fire deep link → filter → enter → capture → self-verify)
            ├─ mobile: incremental retro after EVERY bundle (v0.16.1 — verdict survives mid-run death)
            └─ Trap: enter vs captured 比对 + OCR salvage on truncated bundles + fabricate retro if silent abort
  ↓
Phase C  — xhs-synthesize-vault.sh (auto-trigger in dispatch cleanup)
            Read mobile retro → render vault md with frontmatter
  ↓
End cleanup — xhs-cleanup.sh (force-stop XHS + Chrome, prevent stale state)
```

18 mobile 铁律 in `XHS_RUNBOOK.md` enforce capture discipline (no ad-hoc screencap, prefilter audit, focus self-check, etc).

---

## Design philosophy

1. **Conductor not soloist**: Skill orchestrates existing pieces (mobile agent / OCR / xhs-research-lite). Doesn't reinvent.
2. **XHS-only by design**: Sharp on one source. Cross-source (XHS + 牛客 + 知乎) is v1.0+ epic, not v0.x.
3. **Execution discipline > clever prompts**: Mobile LLM agents freelance under pressure. Hard rules in RUNBOOK + dispatch sanity checks beat smart prompts. 5/19 T23 silent abort 真踩 → v0.13 enter/captured self-verify.
4. **Honest about limits**: If topic has 0-1 hits, say so + suggest alternative source (B 站 for 视频 / 牛客 for 笔试 / 知乎 for 长期). Don't churn fake reports.
5. **Phase 0 first**: User asks "调研 X" — first check if you already have a report. 5/20 dogfood: vault 早已有 16KB 详细报告, skill 默认全量重跑是浪费 + 产出更差.

---

## Known limitations (v0.16.2)

- **Default backend is the OpenClaw mobile agent** (battle-tested). `XHS_AGENT_CMD` plugs in any other CLI agent, but that hook is new and lightly tested. Playwright (no-emulator) backend is v1.x.
- **LLM ~10 min single-request wall is a hard constraint**: a multi-kw fast run WILL get killed mid-final-kw on slower models. v0.16.1 recovers automatically (resume agent + blacklist discipline + OCR salvage + incremental retro; T32-verified end-to-end), but total time stretches to 15-30 min. Use `xhs-research-serial.sh` for clean per-kw runs.
- **Emulator flakiness is real**: BlueStacks adbd can die mid-run (self-heal restarts it, costs ~5-10 min). Not fixable at this layer.
- **Only 图文 notes** (vlog skipped via filter, 铁律 16). Video link → use separate `xhs-open-link` skill.
- **English kw better for 海外 brand** (T12 finding, 海外券商类实证). 国产 brand 用中文.
- **source URL偶发 fail**: BlueStacks 剪贴板 sync 偶发慢, v0.13 加了 3-retry 但还有 ~10% miss rate. T26 1/3 bundle 无 URL.
- **Signal-to-noise variable by domain**:
  - 工具评测 / 公司笔试: 7-8/10
  - 人生方法论 / 情感: 1-3/10 (skill 会 pushback 建议换源)
  - niche AI 工具: medium-high
- **Mobile session 30 min cap** (`timeout_ms` 1900s). Large topics need deep mode + retry.
- **Gateway timeout 6.5 min** (openclaw internal): triggers embedded fallback. v0.12 startup self-check 已兜底, fresh agent 看到 bundle target 已达就 exit, 不重跑.
- **freshness window**: 笔试/面试 180d, 工具评测/产品 90d, 时事/价格 7d, default 30d. 超过的会重跑.

---

## Roadmap

- [x] v0.1-v0.8: 3-phase pipeline + 18 铁律 + filter mandatory + retro
- [x] v0.9: watchdog process-aware + dispatch singleton + auto-fabricate retro
- [x] v0.10: `xhs-get-note-url.sh` (BlueStacks 剪贴板抓 xhslink), source URL in manifest
- [x] v0.11: `--mode fast|deep` + KW count validation
- [x] v0.12: mobile startup self-check (fix gateway timeout reset → 整任务重跑)
- [x] v0.13: enter vs captured self-verify + URL retry + carousel single-image early break + **auto-synthesize vault md**
- [x] v0.14: **Phase 0 vault history check** (5/20 某公司真痛点) + BlueStacks self-heal
- [x] v0.14.1: `xhs-cleanup.sh` + dispatch defensive XHS/Chrome close
- [x] v0.15: source URL fallback chain — miss rate down (0/6 miss in T28-T32)
- [x] v0.16: surgical carousel reset (position-aware, no blind swipes) + FAIL blacklist discipline + valid-bundle counting + `XHS_MODEL`/`XHS_THINKING` overrides (model-specific thinking levels killed every run after a model swap — hardcode nothing)
- [x] v0.16.1: OCR salvage on truncated bundles + incremental retro + count consistency (survives the ~10 min LLM wall, T30-T32)
- [x] v0.16.2: **agent-agnostic runner hook** `XHS_AGENT_CMD` — bring your own agent (Claude Code / Codex / custom)
- [x] v0.16.3: **portable everywhere** — clone-anywhere paths, resolution-proportional coordinates (any emulator size), user-selectable output (`VAULT_ROOT`/`VAULT_FOLDER`/`XHS_FOLDER_STYLE`/`XHS_CAPTURE_ROOT`)
- [ ] v0.17: freshness auto-prompt ("report is X days old, rerun?") instead of silent skip
- [ ] **v1.0: Cross-source** (XHS + 牛客 + 知乎 + B 站) — major architecture epic, separate worker per source + conductor merge layer. Estimated 4-8 hr build + 2-3 weeks dogfood.
- [ ] v1.1+: Playwright backend (no emulator), Cursor / Cline / Codex adapters

**Test history**: 32 dogfood tests over two months (2026-05 → 2026-07) drove every version above — every rule in `XHS_RUNBOOK.md` and every fallback in dispatch exists because a real run broke without it. Per-version retros land in `$XHS_RESEARCH_LOG`.

---

## Credits

- Thinking framework inspired by the author's `xhs-research-lite` skill (keyword strategy + A/B/C 分层 rules are embedded in this repo's `references/`)
- Mobile execution: `XHS_RUNBOOK.md` (18 铁律, real-踩出来的)
- Built and iterated with [Claude Code](https://claude.com/claude-code) talking directly to OpenClaw mobile agent

---

## License

MIT — see [LICENSE](LICENSE).
