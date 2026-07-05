# Phase C — 报告格式

## 输出路径

`${VAULT_ROOT}/<topic-folder>/<topic>_<date>.md`

`<topic-folder>` 按 intent 自动选:
- 求职 → `💼Career/<公司或岗位>/`
- 工具评测 → `📚学习/工具评测/<工具名>/`
- 品牌 / 产品调研 → `🚀项目/调研/<主题>/`
- 人生方法论 → `💭Daily/思考/<主题>/`

## Frontmatter (mandatory, v0.10 加 `source_urls_present`)

```yaml
type: research
target: <topic>
collected_date: YYYY-MM-DD
source: XHS (via xhs-research-conductor v<X.Y>)
sample_size: <N> 条笔记 (A 级 / B 级 / C 级)
signal_to_noise: 0-10
verdict_source_fit: low/medium/high
data_freshness_days_avg: <平均: 报告生成日 - OP 发布日>
coverage_gap: <一句话: 哪些维度没采到>
source_urls_present: <N>/<total>     # v0.10 新增, 多少条 bundle 抓到原始 xhslink
status: <一句话>
```

## 结构 (v0.10 重排: research-first, skill telemetry 全降到末尾)

```
## 🎯 一句话结论
## 给你的 (≤ 5 bullets, 立即可用)
## 🟢 A 级 OP (max 3, 每条带 🔗 原始链接)
## 🟡 B 级 (听说/二手, 每条带 🔗)
## 🔴 噪音概貌 (cluster 汇总, ≤ 5 行)
## ⚠️ 注意 / 坑
## 📎 被跳过/降级的笔记一览 (只列被否的; A/B 已在上面带 🔗)
## <details>🔧 Appendix · skill run telemetry</details>    ← 折叠, skill 自身的 retro 全塞这
```

**v0.10 关键约束**: 每条引用的 A/B 级 OP 必须带 🔗 原始链接 (从 bundle manifest.json `source_url` 读). 空 URL 显式标 `⚠️ no source captured`, 不藏不忽略.

## 报告诚实度 (Test 2 retro 学到)

**信噪比 < 3** → 报告**第一行**就用 🚨 + 一句"XHS 不是这主题的合适源". 不要藏中部.

**信噪比 3-5** → 一句话 caveat 在第一段.

**强 pushback**: 即使 5 条全营销号也要写**为什么 XHS 是错的源** + 推荐替代源 (豆瓣 / 即刻 / 知乎 / 公众号 / B站 vlog). 给用户**信号本身的价值**, 不要因为"没抓到 A 级"就掩盖.

## 去重 (Test 2 retro 学到)

收到 mobile bundle list 后:
1. 按 manifest.json 的 `note_title` 相同 → 重复
2. ocr.md 第 1 段相同 (normalize: 去标点 / 空白) → 重复
3. 重复者只保留第一个 (按 timestamp), 第二个移 `_duplicates/`
4. 报告里**显式列出**去重事实 (e.g., "kw1 + kw3 抓到同一篇, kw3 作废")

## 强制规则

- ⛔ 不读 PNG, 不调 LLM image tool (避免 5min 墙)
- ⛔ 不编造未在 OCR 里出现的内容
- ✅ 严格 A/B/C 分层 (按 `xhs-research-lite` 规则)
- ✅ 营销号识别 (见 `marketing_account_prefilter.md`)

## 同时写 self-learning log

每次跑完写一份 `_research_method_v<N>.md` 到 `~/.openclaw/_research_method_log/`:
- 哪些步顺 / 痛
- 关键词扩展效果 (哪些词有结果)
- 营销号识别准确率
- 下次改什么
