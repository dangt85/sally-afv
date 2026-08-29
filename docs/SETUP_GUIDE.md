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
- **Data Cloud (Data360)** provisioned in both orgs — for the order lookup data graph
  and for the vector search index backing the FAQ/Product Q&A Apex retrievers.
- **Amazon Connect** instance connected to both orgs via **Salesforce Service Cloud
  Voice**, with the two existing queues (`Cairn Support`,
  `Cairn Orders & Returns`) already configured — this is the "current state" the
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

`data/plans/` and `data/records/` are checked into git; `data/records/.generated/`
holds record files with org-specific IDs (Standard Pricebook, Person Account record
type) templated in at load time, and is git-ignored — see §4.1 step 3 and §4.2.

## 3. Deploying Metadata

```bash
sf project deploy start --target-org sally-prep
```

Repeat against `sally-demo` during the live build.

New custom fields deploy with **no field-level security** granted to any profile, so
the data load will fail with an `FlsError` until the user running it can write to
them. Assign the `Cairn_Data_Load` permission set (deployed above) to that user once,
per org:

```bash
sf org assign permset --target-org sally-prep --name Cairn_Data_Load
```

## 4. Loading Sample Data

The data plan follows Salesforce's **SObject Tree Save API** format
(`sf data import tree --plan <plan>.json`), per the sample data described in
`REQUIREMENTS.md` §3. A few objects don't fit a plain tree import cleanly — read this
section fully before building the plan files, since it drives how they need to be
laid out.

**Schema this plan depends on, beyond stock Product2/Account/Order/OrderItem:**

- `Order.Fulfillment_Status__c` (picklist: Processing / In Transit / Delivered /
  Cancelled) and `Order.Estimated_Delivery_Date__c` (date) — custom fields, deployed
  with the metadata (`force-app/main/default/objects/Order/fields/`). The agent
  reports `Fulfillment_Status__c` as "status," not the standard `Status` field, which
  every seed order leaves at `Activated` (required for the order to carry
  `OrderItem`s and roll up `TotalAmount`).
- `Account.Preferred_Language__c` (picklist: English / Spanish) — custom field on the
  Person Account, also deployed with the metadata
  (`force-app/main/default/objects/Account/fields/`).
- Knowledge Articles load into `Knowledge__kav` — the **default** Article Type
  Salesforce Knowledge creates automatically when the feature is enabled, not a
  custom one we defined. Our `sally-prep`/`sally-demo` org template happens to seed
  it with `FAQ_Question__c`, `FAQ_Answer__c`, and `Chat_Answer__c` fields, which the
  Knowledge article records in step 6 below populate (`Chat_Answer__c` as the short,
  voice-friendly response; `FAQ_Answer__c` as the fuller version). If a fresh org's
  `Knowledge__kav` doesn't have those fields, either add them or repoint
  `data/records/knowledge-articles.json` / `data/plans/03-knowledge-plan.json` at
  whatever article type + fields that org actually has — confirm with
  `sf sobject describe --sobject Knowledge__kav --target-org <alias>` before loading.

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
     | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['records'][0]['Id'])")
   sf data update record --target-org <alias> \
     --sobject Pricebook2 --record-id "$PB_ID" --values "IsActive=true"
   ```
   Then template `$PB_ID` into the PricebookEntry record file (e.g. via `envsubst` on
   a `.json.tpl` with a `${STANDARD_PRICEBOOK_ID}` placeholder) before running the
   plan that creates the `PricebookEntry` records (referencing `@ProductRefN` for
   `Product2Id`, and the resolved literal id for `Pricebook2Id`) —
   `data/plans/01-products-plan.json`. `Order` also requires a literal
   `Pricebook2Id`, so `orders-*.json.tpl` carries the same
   `${STANDARD_PRICEBOOK_ID}` placeholder.
4. **Person Accounts** — the Person Account record type `Id` is org-specific too, so
   `person-accounts.json.tpl` templates a `${PERSON_ACCOUNT_RECORD_TYPE_ID}`
   placeholder, resolved the same way by querying `RecordType` where
   `SObjectType = 'Account' AND IsPersonType = true`.
5. **Orders + OrderItems** — Accounts and Orders load together via
   `data/plans/02-customers-orders-plan.json`, so `Order.AccountId` can reference
   `@PersonAccountRefN` — a top-level field, which `@Ref` resolution handles fine
   across plan entries. `OrderItem.PricebookEntryId` can't work the same way: `@Ref`
   tokens only resolve on top-level record fields, not on fields nested inside a
   child relationship (`Order.OrderItems[].PricebookEntryId`) — confirmed against
   `sally-prep` (`MALFORMED_ID` on every `@PricebookEntryRefN`). So PricebookEntries
   load in the earlier, separate `01-products-plan.json` run, `load-data.sh` queries
   their real Ids by `Product2.ProductCode` right after, and `orders-*.json.tpl`
   carries `${PRICEBOOK_ENTRY_ID_<SKU>}` placeholders instead of `@Ref`s. Two more
   gotchas surfaced testing this against `sally-prep`: `Order.Status` can't be
   inserted as `Activated` — the API rejects it (`FAILED_ACTIVATION`) — so every seed
   order loads as `Draft` and `load-data.sh` flips it to `Activated` afterward with
   `activate-orders.apex`, scoped to accounts that have `Preferred_Language__c` set
   so it can never touch unrelated Draft orders already in the org; and
   `OrderItem.TotalPrice` is system-calculated, so it's omitted from the record data
   entirely rather than set. Orders are also split across
   `orders-01.json.tpl`/`-02`/`-03` (regenerate via `data/scripts/generate-orders.py`)
   because a single Order + its nested OrderItems all count against the SObject Tree
   Save API's 200-records-per-request cap.
6. **Knowledge Articles** (`Knowledge__kav`) — load as Draft via tree import
   (`data/plans/03-knowledge-plan.json`), then **publish** separately with
   `data/scripts/publish-knowledge-articles.apex` (uses
   `KbManagement.PublishingService.publishArticle`, run via `sf apex run --file`) —
   publishing is a workflow action, not a plain field update. Authored in English and
   Spanish, matching the two support queues.

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

- `order_lookup` — staged build from Flow → Apex (SOQL) → Data360 data graph; see
  §6.1. Returns order number, total, status, estimated delivery date.
- `company_faq` — staged build from Prompt Template + Data Cloud retriever → custom
  Apex vector-search retriever; see §6.2. Grounded in the Knowledge articles loaded
  in §4.1 step 6.
- `product_qa` — custom Apex vector-search retriever over linked product manuals; see
  §6.3.
- `escalate_to_agent` — transfers the live Voice call into the correct Amazon Connect
  queue (English/Spanish) based on the caller's language.
- `create_case` — invoked when `escalate_to_agent` isn't possible (no agent
  available); creates a `Case` capturing the caller's issue.

Preview each topic in simulated mode in VS Code (`AFDX: Preview This Agent`) before
wiring up real data, then switch to live mode once Apex/Flow/data are deployed.

`sf agent preview` is the CLI equivalent, and it can be scripted despite being an
interactive TUI — useful for regression-checking a topic without re-typing utterances
by hand:

```bash
mkfifo in.fifo
( sleep 28; printf 'what is the status of my order?'; sleep 2; printf '\r'; sleep 150 ) > in.fifo &
script -qc 'stty cols 120 rows 45; sf agent preview --target-org sally-prep \
  --authoring-bundle Cairn_Compass --use-live-actions \
  --context-variables "\$Context.AccountId=001Sv00000gWLyyIAG" \
  --output-dir ./transcripts' /dev/null < in.fifo
```

Two gotchas: linked variables need the **`$Context.` prefix** — without it they're
treated as state variables and silently don't resolve — and `--output-dir` writes
`transcript.jsonl` plus per-turn trace files. Read the traces, not just the
transcript: they list which actions actually fired, which is the only way to tell a
grounded answer from a confidently hallucinated one.

## 6. Grounding & Retrieval Build

### 6.1 Order Lookup

Build in stages against `sally-prep`; each stage should work end-to-end before
moving to the next.

1. **Flow** — declarative Flow action querying `Order`/`OrderItem` by
   customer-provided identifiers (order number, customer name/phone/email). Wire it
   into the `order_lookup` topic as the first working version.
2. **Apex (local SOQL)** — swap the Flow action for an Apex invocable action running
   the equivalent SOQL query. Same inputs/outputs as stage 1, so the topic wiring
   doesn't change, only the action implementation.
3. **Data360 Data Graph** — replace the Apex action with a Data Cloud data graph, in
   three steps:
   1. **Ingest & map** — configure Data Cloud ingestion (Data Stream) from Salesforce
      CRM for `Account` (Person Account), `Order`, `OrderItem`, and `Product2`, using
      the standard Salesforce Data Cloud connector for streaming ingestion. Skip the
      pre-built "Sales and Service Cloud" data kit's automatic mapping — manually map
      the ingested fields to Data Cloud's Standard Data Model objects (e.g.
      `Individual`, `Sales Order`, `Sales Order Product`, `Product`) in the Data Cloud
      Data Model canvas, so the mapping decisions are visible on camera rather than
      hidden behind the kit's defaults. Confirm the exact standard object/field names
      available in the org's Data Model canvas before mapping — Data Cloud's Standard
      Data Model can vary slightly by org/release.
   2. **Build the data graph** — build a data graph over the mapped standard objects,
      so a single query returns the order, its line items, the customer, and the
      ordered products. Root the graph at `Account` and sort the `Sales Order` node by
      `Order Start Date` descending (Filters tab → Sort and Limit) — that sort is what
      makes "my most recent order" resolvable. There is no lookup-key configuration
      screen in this builder, and only the root's primary key is queryable; see step 3.
   3. **Wire it up** — point `order_lookup_action` at an Apex invocable action
      (`apex://OrderLookupDataGraph`) that queries the data graph. There is **no**
      no-code retriever action for a data graph: Setup → Retrievers only offers a
      search-index retriever (the `product_qa`/`company_faq` mechanism in §6.3),
      which needs a DMO with a vector search index, not a data graph. A data graph is
      queried through the Data Graph Query API — from Apex via
      `ConnectApi.CdpQuery.getDataGraphData(graphName, accountId, 'default')`.
      Two things about that call are worth knowing before you write against it:
      - Its lookup key must be the **root DMO's primary key** (here, the Account id).
        Arbitrary nested fields like `Sales Order.OrderNumber` are not lookup keys, so
        the Apex resolves an order number to its Account id with a plain SOQL query
        against core `Order` first, then queries the graph by that id.
      - **A caller the ANI didn't already identify can't resolve an order by number
        alone** — an order number by itself is guessable and isn't proof it's really
        their order. `order_lookup_action`'s `OrderDateInput` (the date the order was
        placed) is required alongside `OrderNumberInput` for this path; the Apex
        resolves the order by number, then checks `Order.EffectiveDate` against
        `OrderDateInput` before returning anything — a mismatch, or either input
        missing, is treated the same as no match found. The `AccountIdInput` path
        (a caller the ANI already matched) skips this check entirely, since identity
        is already established. `order_lookup`'s reasoning instructions escalate to a
        human immediately if the caller can't supply both, rather than falling back to
        another identifier, and give a deliberately minimal reply (fulfillment status
        and estimated delivery date only — no name, no order number or total readback)
        when a match is found this way, since the caller still isn't personally
        identified the way an ANI match would establish.
      - The rows in `CdpQueryOutput.data` are raw Java maps, not Apex `Map`s. Calling
        any `Map` method on one (`get`, `keySet`, `size`, even `toString`) faults the
        Apex interpreter in a way `try`/`catch` cannot intercept, and the failure
        aborts the request before debug logs flush — so it looks like nothing ran.
        `String.valueOf(row)` is safe, and renders as
        `{json_blob__c=<the whole graph as JSON>, version__c=0}`; cut the payload out
        of that string and `JSON.deserializeUntyped` it into real Apex collections.
        See `OrderLookupDataGraph.parseRow`.
      - An Apex `Decimal` output must be declared `lightning__numberType` in the
        `.agent` file. The Flow-era `lightning__currencyType` is rejected at runtime.

      **Fetch the known caller's order deterministically, not by asking the LLM to.**
      `order_lookup`'s `before_reasoning` hook runs the action whenever `AccountId` is
      set and stores the result in `@variables.known_order_summary`, which the
      reasoning instructions interpolate. This is not a stylistic choice: left to
      decide for itself, the reasoning LLM would not call an action it had no inputs
      to fill — it either narrated "one sec, let me pull that up" and ended the turn,
      or **fabricated** plausible order numbers and totals. Several rounds of
      instruction wording, including an explicit "never invent an order's details",
      did not fix it; putting the real data in the prompt before the model reasons
      did. The Apex's `OrderSummaryOutput` exists for this hook, because Agent Script
      mutable variables are limited to `string`/`number`/`boolean`/`object` (`date` is
      action-parameter-only), so the five typed outputs can't each be held in one.

      Two caveats worth knowing on camera: the data graph refreshes hourly, so an
      order created mid-demo won't appear until the next refresh; and the
      `before_reasoning` hook re-runs the graph query on every turn inside
      `order_lookup`, which adds a round-trip per turn.

### 6.2 Company FAQ

1. **Prompt Template + Data Cloud retriever** — a Prompt Template action with a
   built-in Data Cloud/Knowledge retriever grounded on the Knowledge articles
   published in §4.1 step 6. Baseline version of `company_faq`.
2. **Custom Apex vector-search retriever** — replace the Prompt Template's retriever
   call with a custom Apex action that queries Data Cloud's vector search index
   directly over the Knowledge article content, skipping the Prompt Template
   retriever's orchestration overhead. Demo this as a before/after latency comparison
   against stage 1.

### 6.3 Product Q&A

A custom Apex action queries Data Cloud's vector search index directly over the
`Product2` records' linked `ContentVersion` manuals/guides — no data graph, no Prompt
Template retriever, single approach.

What "good" looks like here is a clear before/after: without grounding, the agent
gives a generic answer and asks the caller for details it should already be able to
look up. With the retriever wired in, the agent answers already grounded in the
specific product — citing the actual spec or troubleshooting step rather than a
generic response. That contrast is worth making visible on camera, not just the
final grounded answer.

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
- [ ] Order lookup data graph returns the correct order, line items, and
      customer/product details for at least 2–3 sample orders.
- [ ] A caller whose ANI matched an Account gets their most recent order without
      being asked for any identifiers, and is addressed by name.
- [ ] Every order number/total/status/date the agent says matches core CRM exactly —
      check the preview traces to confirm the action actually fired rather than the
      model answering from nothing.
- [ ] Product Q&A Apex retriever returns grounded answers for at least 2–3 product
      questions per product category worth demoing.
- [ ] Company FAQ Apex retriever returns grounded answers at lower latency than the
      Prompt Template baseline for at least 2–3 sample questions.
- [ ] Escalation actually rings into the correct Amazon Connect queue.
- [ ] Case creation fires correctly when escalation isn't available (simulate no
      agents available).
- [ ] Full run-of-show timed end-to-end at least once.

## 9. Live Demo Run-of-show (`sally-demo`)

Repeat, from a clean sandbox, on camera:

1. `sf org login web --alias sally-demo` (if not already authorized).
2. `sf project deploy start --target-org sally-demo`.
3. `sf org assign permset --target-org sally-demo --name Cairn_Data_Load` (§3).
4. `data/scripts/load-data.sh sally-demo`.
5. Walk through agent build/config live (per §5–7), narrating for the audience.
6. Live call demo covering the use cases in `REQUIREMENTS.md` §8 success criteria.

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
- Knowledge Articles load into `Knowledge__kav`, Salesforce's default Article Type —
  its `FAQ_Question__c`/`FAQ_Answer__c`/`Chat_Answer__c` fields come from the org
  template, not from `force-app`; re-check field names with `sf sobject describe` on
  any org that wasn't built from the same template (see §4).
- Some org templates (ours included) seed more than one `IsPersonType = true`
  Account record type. `load-data.sh` prefers the one named `PersonAccount`; if a
  target org doesn't have that exact `DeveloperName`, it falls back to whichever
  Person Account record type sorts first — check that's the intended one.
- Person Account and PricebookEntry record type/pricebook `Id`s are resolved live by
  `data/scripts/load-data.sh`, which writes rendered files to the git-ignored
  `data/records/.generated/`. Run the script rather than `sf data import tree`
  directly against the `.tpl` files — they contain unresolved `${...}` placeholders.
- `OrderItem.TotalPrice` is system-calculated from `Quantity` × `UnitPrice` — the API
  rejects it on insert (`INVALID_FIELD_FOR_INSERT_UPDATE`), so it's omitted from
  `orders-*.json.tpl` and left for the platform to compute (`Order.TotalAmount` then
  rolls up from that automatically).
- `load-data.sh` is **not idempotent** — every object it inserts (Products,
  ContentVersions, PricebookEntries, Person Accounts, Orders, Knowledge articles) is
  a plain `sf data import tree`/create, with no upsert or dedup. Re-running it against
  an org that already has this sample data creates a second set of everything.
  Clean up first (e.g. delete `Product2` by the SKUs in `REQUIREMENTS.md` §3.1,
  cascading to their `PricebookEntry`/`ContentDocument`, plus the 6 Person Accounts by
  `Preferred_Language__c != null`, which cascades to their Orders/OrderItems) before
  reloading into a non-empty `sally-prep`.
- Data Cloud ingestion is streaming, not instant — allow a few minutes after loading
  sample data before the order lookup data graph reflects it; don't assume it's
  broken if a freshly loaded order doesn't show up immediately.
- The Salesforce CRM data kit's automatic mapping is intentionally skipped for order
  lookup — `Account`/`Order`/`OrderItem`/`Product2` fields are mapped to Data Cloud's
  Standard Data Model by hand (§6.1) — double-check the mapping after any Data Cloud
  org refresh/reset.

## 11. References

- [Salesforce CLI — Import Data Reference (SObject Tree)](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/data_import_ref.htm)
- [Agentforce DX Developer Guide](https://developer.salesforce.com/docs/einstein/genai/guide/agent-dx.html)
- [Agent Script](https://developer.salesforce.com/docs/ai/agentforce/guide/agent-script.html)
