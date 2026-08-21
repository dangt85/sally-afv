# Setup Guide — Agentforce Voice Demo

This is the working, technical companion to [`REQUIREMENTS.md`](./REQUIREMENTS.md).
It's written as a run-of-show: build and rehearse everything here against
`sally-prep`, then repeat the same steps live against `sally-demo`.

## 1. Prerequisites

- **Salesforce CLI** (`sf`) installed and up to date (`sf update`).
- Two Salesforce **SDO sandbox orgs**, both Agentforce-enabled:
  - `sally-prep` — rehearsal org.
  - `sally-demo` — clean org used for the live recording.
- **Person Accounts** enabled in both orgs (this cannot be toggled via CLI/metadata —
  confirm with `sf org display --target-org <alias>` / Setup → Account Settings
  before relying on it; request enablement ahead of time if it's missing).
- **Data Cloud (Data360)** provisioned in both orgs, for the data graph use case.
- **Amazon Connect** instance connected to both orgs via **Salesforce Service Cloud
  Voice**, with the two existing queues (`Cairn Support – English`,
  `Cairn Support – Spanish`) already configured — this is the "current state" the
  demo starts from.
- VS Code with **Salesforce Extensions** + **Agentforce DX** extension, or
  Cursor/Claude Code for the pro-code agent build.

Authorize both orgs once, aliased exactly as above so the rest of this guide (and any
scripts) can assume those alias names:

```bash
sf org login web --alias sally-prep
sf org login web --alias sally-demo
```

Never assume a default org for destructive or org-specific commands — always pass
`--target-org sally-prep` or `--target-org sally-demo` explicitly.

## 2. Project Structure

```
force-app/main/default/       # agent metadata (aiAuthoringBundles, flows, classes, ...)
data/
  plans/                      # sf data import tree plan definitions
  records/                    # SObject tree JSON record files referenced by plans
  files/                      # sample PDF manuals/how-tos, base64'd into ContentVersion records
  scripts/                    # orchestrator script(s) + any Apex helper scripts
docs/
  REQUIREMENTS.md
  SETUP_GUIDE.md
```

(`data/` doesn't exist yet — it gets created when the sample data is built out.)

## 3. Deploying Metadata

```bash
sf project deploy start --target-org sally-prep
```

Repeat against `sally-demo` during the live build.

## 4. Loading Sample Data

The data plan follows Salesforce's **SObject Tree Save API** format
(`sf data import tree --plan <plan>.json`), per the sample data described in
`REQUIREMENTS.md` §3. A few objects don't fit a plain tree import cleanly — read this
section fully before building the plan files, since it drives how they need to be
laid out.

### 4.1 Load order & why

1. **Products** (`Product2`) — plain tree records, no external dependencies.
2. **Product files** (`ContentVersion`) — inserted in the **same plan run** as
   Products, so their `FirstPublishLocationId` field can reference a product's
   `@ProductRefN` reference id directly. Setting `FirstPublishLocationId` at insert
   time creates the `ContentDocumentLink` to the product automatically — no separate
   linking step needed. Keep sample PDFs small; `VersionData` is inline base64.
3. **Standard Pricebook activation + PricebookEntries** — the Standard Pricebook
   record itself already exists in every org (it can't be created), and its `Id` is
   org-specific, so it can't be hardcoded into a committed JSON file that has to work
   in both `sally-prep` and `sally-demo`. Handle this as a small scripted step, not a
   tree import:
   ```bash
   PB_ID=$(sf data query --target-org <alias> \
     --query "SELECT Id FROM Pricebook2 WHERE IsStandard=true" --json \
     | jq -r '.result.records[0].Id')
   sf data update record --target-org <alias> \
     --sobject Pricebook2 --record-id "$PB_ID" --values "IsActive=true"
   ```
   Then template `$PB_ID` into the PricebookEntry record file (e.g. via `envsubst` on
   a `.json.tpl` with a `${STANDARD_PRICEBOOK_ID}` placeholder) before running the
   plan that creates the `PricebookEntry` records (referencing `@ProductRefN` for
   `Product2Id`, and the resolved literal id for `Pricebook2Id`).
4. **Person Accounts** — plain tree records.
5. **Orders + OrderItems** — in the same plan run as Person Accounts, so `Order`
   records can reference `@PersonAccountRefN` for `AccountId`; `OrderItem` records
   nest under their parent `Order` and reference the `PricebookEntry` ids resolved in
   step 3 (literal ids, since those weren't created via tree ref in this run — either
   look them up with `sf data query` right before generating this file, or keep
   PricebookEntries in the *same* overall plan run so they can also be referenced by
   `@PricebookEntryRefN`).
6. **Knowledge Articles** — load as Draft via tree import, then **publish**
   separately; publishing is a workflow action, not a plain field update, so it needs
   either a small Apex snippet using `KbManagement.PublishingService.publishArticle`
   run via `sf apex run --file`, or a manual publish pass in Setup. Author English and
   Spanish variants where practical, matching the two support queues.

### 4.2 Running it

Wrap the above into a single orchestrator script (`data/scripts/load-data.sh`) that
takes the target org alias as an argument, so the exact same script runs against
`sally-prep` during rehearsal and `sally-demo` live:

```bash
data/scripts/load-data.sh sally-prep
# ...on demo day...
data/scripts/load-data.sh sally-demo
```

## 5. Building the Agent

Author the agent as an **Agent Script** (`AiAuthoringBundle`), matching the five use
cases in `REQUIREMENTS.md` §4 — one topic/subagent per use case is a reasonable
starting split:

- `order_lookup` — Apex/Flow action querying `Order`/`OrderItem` by customer-provided
  identifiers, returns order number, total, status, estimated delivery date.
- `company_faq` — Knowledge retrieval grounded in the articles loaded in §4.1 step 6.
- `product_qa` — grounded in the Data360 data graph (§6) or the Apex retriever
  alternate.
- `escalate_to_agent` — transfers the live Voice call into the correct Amazon Connect
  queue (English/Spanish) based on the caller's language.
- `create_case` — invoked when `escalate_to_agent` isn't possible (no agent
  available); creates a `Case` capturing the caller's issue.

Preview each topic in simulated mode in VS Code (`AFDX: Preview This Agent`) before
wiring up real data, then switch to live mode once Apex/Flow/data are deployed.

## 6. Product Q&A Grounding

### 6.1 Primary: Data360 Data Graph

Build a Data Cloud data graph over the `Product2` records and their linked
`ContentVersion` manuals/guides, and wire it into the `product_qa` topic as a
retrieval action — a data graph that lets the agent answer product-specific
questions grounded in real product content rather than free-form generation.

What "good" looks like here is a clear before/after: without the data graph, the
agent gives a generic answer and asks the caller for details it should already be
able to look up. With the data graph, one retrieval call assembles product spec,
manual, and troubleshooting content in place of several manual lookups, and the
agent answers already grounded in the specific product — citing the actual spec or
troubleshooting step rather than a generic response. That contrast (generic vs.
grounded, multiple lookups vs. one call) is worth making visible on camera, not just
the final grounded answer.

### 6.2 Alternate: Custom Apex Retriever

If Data360 setup time or query latency becomes a risk for the live segment, fall back
to (or additionally demo) a custom Apex action that performs vector search directly
over the product content — lower latency, fully custom, good talking point on "here's
what's happening under the hood" vs. the managed Data360 path.

## 7. Voice Channel Setup

### 7.1 Primary: Amazon Connect + Salesforce Voice

This is the "before" state already running for Cairn Outdoor Co. — document/screen
record the existing setup (two queues, Salesforce Service Cloud Voice adapter) before
adding the Agentforce Voice agent in front of it, then show:

- The agent answering calls that used to go straight to a human.
- `escalate_to_agent` handing off into the same English/Spanish Amazon Connect
  queues, mid-call, with context.

### 7.2 Alternate: Agentforce Contact Center (AFCC)

Optional second segment: same agent, but fronted by AFCC instead of Amazon Connect,
as the "native CCaaS" story for orgs not already invested in Amazon Connect.

## 8. Rehearsal Checklist (`sally-prep`)

- [ ] Metadata deploys clean to a fresh sandbox.
- [ ] `data/scripts/load-data.sh sally-prep` runs end-to-end with no manual fixups.
- [ ] All five use cases pass manual QA in the Agentforce DX preview panel.
- [ ] Data360 data graph returns grounded answers for at least 2–3 product questions
      per product category worth demoing.
- [ ] Escalation actually rings into the correct Amazon Connect queue.
- [ ] Case creation fires correctly when escalation isn't available (simulate no
      agents available).
- [ ] Full run-of-show timed end-to-end at least once.

## 9. Live Demo Run-of-show (`sally-demo`)

Repeat, from a clean sandbox, on camera:

1. `sf org login web --alias sally-demo` (if not already authorized).
2. `sf project deploy start --target-org sally-demo`.
3. `data/scripts/load-data.sh sally-demo`.
4. Walk through agent build/config live (per §5–7), narrating for the audience.
5. Live call demo covering the use cases in `REQUIREMENTS.md` §8 success criteria.

## 10. Known Gotchas

- Standard Pricebook `Id` is org-specific — never hardcode it in committed data files
  (see §4.1 step 3).
- `ContentVersion.FirstPublishLocationId` must be set in the **same** tree import run
  as the `Product2` records it references, or the `@ProductRefN` reference won't
  resolve.
- Knowledge articles inserted via tree import land as **Draft** — they won't show up
  in agent retrieval until published.
- Person Accounts can't be enabled via CLI/metadata — verify it's on before building
  anything that depends on it.

## 11. References

- [Salesforce CLI — Import Data Reference (SObject Tree)](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/data_import_ref.htm)
- [Agentforce DX Developer Guide](https://developer.salesforce.com/docs/einstein/genai/guide/agent-dx.html)
- [Agent Script](https://developer.salesforce.com/docs/ai/agentforce/guide/agent-script.html)
