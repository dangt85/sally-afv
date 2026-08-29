# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this project is

A Salesforce DX project for an **Agentforce Voice demo**, recorded for the
[CodeWithSally](https://www.youtube.com/@CodeWithSally) YouTube channel. The
fictitious scenario, sample data requirements, and agent use cases are defined in
[`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) — read that first for _what_ we're
building. [`docs/SETUP_GUIDE.md`](docs/SETUP_GUIDE.md) has the _how_ — org setup,
data loading mechanics, agent build steps. Keep both docs in sync with reality as the
build progresses; they're the run-of-show for a live recording, not just planning
artifacts.

## Orgs

Two Salesforce sandbox orgs, aliased exactly as below — always pass `--target-org`
explicitly, never rely on a default:

- `sally-prep` — rehearsal/build org. Most work happens here first.
- `sally-demo` — kept clean; only touched to rehearse the "from scratch" live build,
  or during the actual recording. Don't leave half-finished experiments here.

## Tech stack

- Salesforce DX (`sf` CLI), Agentforce (Agent Script / `AiAuthoringBundle`), Apex,
  Flow.
- Sample data loaded via `sf data import tree --plan` (SObject Tree Save API), not
  Data Loader or manual UI entry — see `docs/SETUP_GUIDE.md` §4 for the specific
  ordering/gotchas (standard Pricebook id, ContentVersion linking, Knowledge
  publishing).
- Order lookup grounding: staged build (Flow → Apex/SOQL → Data360 data graph) — the
  only place a Data Cloud data graph is used, backed by CRM data ingested and
  manually mapped to Data Cloud's Standard Data Model rather than the built-in
  Salesforce CRM connector/data kit. See `docs/REQUIREMENTS.md` §5.1. The final stage
  is `OrderLookupDataGraph` (Apex): a data graph has no no-code retriever action, so
  it's queried through `ConnectApi.CdpQuery`. Two constraints shape that class and
  are easy to rediscover the hard way — the graph is only queryable by its **root**
  DMO's primary key (hence the SOQL resolve step), and the rows it returns are raw
  Gson maps that fault the Apex interpreter uncatchably if you call any `Map` method
  on them. `SETUP_GUIDE.md` §6.1.3 has the details.
- Company FAQ and Product Q&A grounding: both use a custom Apex vector-search
  retriever querying Data Cloud's vector search index directly (no data graph); FAQ
  additionally has a Prompt Template + Data Cloud retriever baseline stage it
  upgrades from, for a latency comparison. See `docs/REQUIREMENTS.md` §5.2–§5.3.
- Voice: Amazon Connect + Salesforce Service Cloud Voice is the primary/current-state
  integration; Agentforce Contact Center (AFCC) is the documented alternate.

## Working agreements

- All sample data (customers, orders, products) is **fictitious** — never substitute
  real people, addresses, or company data into it.
- Everything must be reproducible from a clean sandbox: metadata deploy + data plan
  load should work identically against `sally-prep` and `sally-demo`. Avoid steps
  that only work because of leftover state from a previous run.
- Format changed files with the project's Prettier config before considering a change
  done: `npm run prettier`.
- The Agentforce DX template's starter agent ("Local Info Agent") and its example
  components have been removed. `Cairn_Compass` is the only agent — build on it.
- Don't remove `Cairn_Voice_Agent.permissionset-meta.xml` from `.prettierignore`:
  `@prettier/plugin-xml` appends a semicolon to its `<flow>` text nodes, which makes
  the file undeployable ("no FlowDefinition named `Cairn_Order_Lookup;` found").
- `sf agent preview` can be driven headlessly despite being an Ink TUI: give it a pty
  (`script -qc "…" /dev/null < fifo`, with `stty cols 120 rows 45`) and use
  `--output-dir` for machine-readable transcripts and per-turn traces. Linked
  variables need the `$Context.` prefix (`--context-variables '$Context.AccountId=…'`);
  without it they're treated as state variables and silently don't resolve. The traces
  are the only reliable way to tell whether an action actually fired or the model just
  made the answer up.
- Follow the standard git safety rules: don't force-push, don't run destructive
  `sf`/`git` commands against either org without confirming, and never commit real
  credentials — org auth lives in `sf org login`, not in files.
