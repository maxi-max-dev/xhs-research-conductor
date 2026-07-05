# 报告 标准模板 (v0.10, ≤ 80 行 / report, research-first)

固化模板, 不再每次重新设计. 复制粘贴改字段.

核心原则 (v0.10 改): 报告主体回答**用户的研究问题**, 不是 "skill 跑得怎么样". skill telemetry 全部塞到末尾 Appendix, 可折叠. 每条引用的 OP 必须带 🔗 原始链接 (从 mobile bundle 的 manifest.json `source_url` 读), 用户能一键回到原帖. 空 URL 标 ⚠️.

```markdown
---
type: research
target: <topic>
date: 2026-MM-DD
test_id: <N>
source: XHS via xhs-research-conductor v<X.Y>
bundles: <total> (A: <n_A>, B: <n_B>, C: <n_C>)
source_fit: low | medium | high
source_urls_present: <N>/<total>     # 多少条 bundle 抓到了原始链接
mobile_time_min: <N>
watchdog_triggered: false | true
---

# <Topic> · XHS 视角 · <date>

> 🎯 TL;DR (≤ 50 字, 1 段): <核心结论, 直接回答 topic>

---

## 给你的 (≤ 5 bullets, 立即可用)

- <bullet 1, 用户实操>
- <bullet 2>
- ...

---

## 🟢 A 级 OP (max 3 篇, ≤ 80 字/篇)

### <标题> (@作者 @ 地点)
- 🔗 <https://xhslink.com/o/xxx>    ← v0.10 mandatory, 空就写 `⚠️ no source captured`
- 数据: X 赞 / Y 收藏 / Z 评
- 核心: "<OP 引一句>"
- 你看什么: <1 行 actionable>

(重复 max 3 次)

---

## 🟡 B 级 (听说/二手, max 3 条, 1 行/条)

- <标题> (@作者) — 🔗 <url 或 ⚠️> — 一句核心
- ...

---

## 🔴 噪音概貌 (≤ 5 行)

Mobile 跳过 <N> 条, 主要 cluster:
- <cluster 1>: X 条 (e.g., 培训机构 / 翻译号 / 网图大全)
- <cluster 2>: ...

→ 哪些值得用户**自己再看一眼** (营销号也是行业话术信号), 哪些纯垃圾.

---

## ⚠️ 注意 / 坑

- <用户实操中可能踩的, 1-3 条>

---

## 📎 被跳过 / 降级的笔记一览 (A/B 已在上面, 这里只列被否的, 供你 spot check agent 判断)

L1 跳过 (没 enter, 标题来自搜索结果):
- "<标题>" — L1-marketing (培训机构话术)
- "<标题>" — L1-stale (>2 年老贴)
- ...

C 级 (entered 后 OCR 判噪音):
- "<标题>" (@作者) — 🔗 <url 或 ⚠️> — 噪音类型 (e.g., 营销号 / 翻译号 / 网图大全)
- ...

→ 用途: 你怀疑 agent 把真有料的判成噪音了, 在这里找;
   反过来也行——你看到 cluster 里"培训机构 X 条"觉得意外, 可以在这里看具体是哪些被这么标的.

---

<details>
<summary>🔧 Appendix · skill run telemetry (折叠, 默认不看)</summary>

| 指标 | 结果 |
|---|---|
| Mobile time | X min |
| Watchdog triggered | false/true |
| Bundle count | N |
| A 级率 | N/total |
| URL 抓取率 | <N>/<total> |
| 新发现 / bug | <如有> |

</details>
```

## 改造原则 (v0.10)

1. TL;DR 强制 ≤ 50 字 — 不要写"一段话结论" 100+ 字
2. A 级 OP 限 3 篇 — 即使 5/5 都 A 级也只摘 3 篇最深, 其他用户自己看 bundle
3. 每篇 OP 限 80 字 — title + url + 1 quote + 1 actionable. 不再罗列全部金句
4. 每条引用的笔记**必须**带 🔗 (URL 或 ⚠️ 标识), 否则用户回溯不了原帖
5. 噪音概貌 ≤ 5 行 — cluster 汇总, 不列详情
6. Skill telemetry 全部塞 `<details>` 折叠块, 不污染主体
7. 不要在报告里加 ship 决策 / methodology 反思 — 那些去 `_research_method_v<N>.md`, 不进用户报告

## 反例 (Test 1-20 写过的)

- ❌ 500+ 字 "TL;DR" (实际是 mini 报告全部内容)
- ❌ 把 OP 5346 字深度帖全文摘抄 (用户去 bundle 看就行)
- ❌ "v0.X dogfooding 验证" 占报告 1/3 (移到 retro log 或折叠 Appendix)
- ❌ "给你的 next actions" 1-2-3-4-5-6-7 (太多, 用户记不住)
- ❌ A 级 OP 不带原始链接 (v0.10 新硬铁律: 没链接 = 不可验证 = 报告价值减半)
