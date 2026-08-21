# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this project is

A Salesforce DX project for an **Agentforce Voice demo**, recorded for the
[CodeWithSally](https://www.youtube.com/@CodeWithSally) YouTube channel. The
fictitious scenario, sample data requirements, and agent use cases are defined in
[`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) — read that first for *what* we're
building. [`docs/SETUP_GUIDE.md`](docs/SETUP_GUIDE.md) has the *how* — org setup,
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
- Product Q&A grounding: primarily a Data360 (Data Cloud) data graph; a custom Apex
  vector-search retriever is the documented low-latency alternate.
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
- This repo currently ships a generic starter agent ("Local Info Agent" — weather,
  local events, resort hours) from the Agentforce DX template. Treat it as scaffold
  to be replaced by the Cairn Outdoor Co. agent, not as something to build on top of.
- Follow the standard git safety rules: don't force-push, don't run destructive
  `sf`/`git` commands against either org without confirming, and never commit real
  credentials — org auth lives in `sf org login`, not in files.
