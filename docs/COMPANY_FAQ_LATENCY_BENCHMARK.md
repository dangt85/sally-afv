# Company FAQ Latency Benchmark — OOTB vs. Apex Retriever

Measured results backing the before/after latency comparison referenced in
[`REQUIREMENTS.md`](./REQUIREMENTS.md) §5.2 and [`SETUP_GUIDE.md`](./SETUP_GUIDE.md)
§6.2: the custom Apex vector-search retriever is expected to be faster than the
out-of-the-box "Answer Questions with Knowledge" action because it skips that
action's orchestration overhead. This document records the actual numbers.

## Methodology

- **Org**: `sally-prep`.
- **Tool**: `sf agent preview --authoring-bundle Cairn_Compass --use-live-actions`,
  driven headlessly (per `CLAUDE.md`'s pty pattern), against real Data Cloud/Apex —
  not simulated actions.
- **Stages compared**:
  1. **OOTB baseline** — standard `AnswerQuestionsWithKnowledge` action against the
     `Cairn_Knowledge` Agentforce Data Library (`company_faq` subagent as of commit
     `dd250fd`).
  2. **Current** — custom Apex `CompanyFAQVectorSearch` action querying Data Cloud's
     vector search index directly (`company_faq` subagent as of HEAD, `dacd3b9`).
- The two stages don't run side by side in the live agent, so each was benchmarked
  by temporarily swapping the `company_faq` subagent block (and, for stage 1, a
  temporary permission-set deploy restoring `Knowledge__kav` field access) back to
  the earlier commit's version, then restoring current state afterward. Neither
  `sally-prep` nor the git working tree were left modified by the benchmark.
- **Trials**: 7 FAQ questions (one per documented policy topic, from
  `tests/Cairn_Compass-testing-center.yaml`) × 3 reps each = 21 trials per stage, 42
  total. Each trial used a fresh preview session (no shared conversation context
  across trials).
- **Latency** = timestamp of the agent's answering turn minus the timestamp of the
  immediately preceding user turn, from each session's `transcript.jsonl`.
- **Validity check**: every trial's trace file was inspected to confirm the
  retrieval action actually fired, rather than trusting a plausible-sounding reply —
  per this repo's working agreement that traces are the only reliable signal an
  action ran.

## Results

| Stage                                             | Valid trials | Mean  | Median | Min   | Max    | Stdev |
| ------------------------------------------------- | ------------ | ----- | ------ | ----- | ------ | ----- |
| **Stage 1 — OOTB** `AnswerQuestionsWithKnowledge` | 21/21        | 6.66s | 6.16s  | 5.49s | 10.36s | 1.29s |
| **Stage 2 — Apex** `CompanyFAQVectorSearch`       | 21/21        | 4.40s | 3.80s  | 3.44s | 5.81s  | 0.90s |

All 42 trials had their retrieval action confirmed fired via trace inspection; none
were excluded.

## Takeaway

The custom Apex vector-search retriever is **~34% faster on mean latency (2.27s
saved)** and **~38% faster on median latency (2.36s saved)** than the OOTB
Prompt Template/Data Cloud retriever baseline, with lower variance as well —
confirming the "skips the standard action's orchestration overhead" claim in
`REQUIREMENTS.md` §5.2 with measured numbers.

## Anomaly

Stage 1's two slowest trials (9.0s–10.4s) were both the "store hours/location"
question — noticeably worse than its other trials, which clustered around 6s.
Stage 2 showed no comparable outlier on that same question, which if anything
widens the gap for that specific query.
