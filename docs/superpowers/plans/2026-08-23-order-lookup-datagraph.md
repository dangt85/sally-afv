# Order Lookup — Data Cloud Data Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Human note:** Tasks 3, 4, 5, and 8 involve live actions in the Data Cloud
> and Agent Builder Setup UI that no agent can perform — they are written as
> guided checklists for the user to work through interactively (narrated
> step-by-step), not as autonomous subagent work. Tasks 1, 2, 6, 7 are
> ordinary metadata/file edits and are safe to execute autonomously (by a
> subagent or inline). See "Execution note" at the end of this plan.

**Goal:** Replace `order_lookup`'s Flow-backed action with a Data Cloud data
graph retriever, and make the agent skip asking for identifiers when the
inbound flow already matched the caller's ANI to an Account.

**Architecture:** A new `VoiceCall.Account__c` lookup field, set by
`Cairn_Inbound` on a single ANI match, feeds a new `AccountId` linked variable
on `Cairn_Compass.agent`. `order_lookup`'s action retargets from
`flow://Cairn_Order_Lookup` to a `retriever://` action backed by a Data Cloud
data graph rooted at **`Account`** (corrected from `Individual` once Task 3
execution revealed `Individual`'s primary key is locked on this sandbox — see
Task 3's "What actually happened" note), joined out to `Sales Order` →
`Sales Order Product` → `Product`, queryable by either Account id or order
number — so the same action serves both the known-caller and
explicit-order-number paths.

**Tech Stack:** Salesforce DX (`sf` CLI), Agent Script (`AiAuthoringBundle`),
Flow, Data Cloud (Data Streams, Standard Data Model, Data Graphs), Agent
Builder.

**Spec:** `docs/superpowers/specs/2026-08-23-order-lookup-datagraph-design.md`

## Global Constraints

- Always pass `--target-org sally-prep` explicitly — never rely on a default
  org (project convention, `CLAUDE.md`).
- Format changed files with `npm run prettier` before considering a task done.
- All sample data referenced during testing is fictitious Cairn Outdoor Co.
  data already loaded in `sally-prep` — never substitute real data.
- Data Cloud Data Streams for `Account`/`Order`/`OrderItem`/`Product2` exist
  in `sally-prep` and are now **activated and mapped** (Task 3 is done — see
  its "What actually happened" note for the real field/DMO names and the two
  sandbox gotchas hit along the way).
- Data Cloud field-picker search matches on the **field label**, not the API
  name, and labels in this org don't always match what you'd guess from the
  API name (`Order.TotalAmount`'s label is "Order Amount", not "Total
  Amount") — if a field you know exists doesn't show up in a mapping search,
  try the label instead of the API name before assuming it's unmapped.
- This sandbox blocks **replacing** a DMO field's existing source mapping
  ("Switch Mapping is not supported on Sandbox Org") — this hit both
  `Individual`'s primary key (already locked to a pre-existing source) and
  `Sales Order`'s `Ship To Contact` field. The workaround both times was to
  map onto a different, still-unmapped target field instead of fighting the
  lock — don't attempt to delete/replace an existing mapping in `sally-prep`
  or `sally-demo` without expecting this.
- `Cairn_Order_Lookup` (Flow) is deleted once the data graph path is proven
  working (Task 7) — it is not kept as a fallback.

---

## Task 1: `VoiceCall.Account__c` lookup field

**Files:**

- Create: `force-app/main/default/objects/VoiceCall/fields/Account__c.field-meta.xml`

**Interfaces:**

- Produces: `VoiceCall.Account__c` (Lookup(Account)) — consumed by Task 2
  (Flow sets it) and Task 5 (agent's `AccountId` linked variable reads it).

- [ ] **Step 1: Create the field metadata**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Account__c</fullName>
    <externalId>false</externalId>
    <label>Account</label>
    <deleteConstraint>SetNull</deleteConstraint>
    <referenceTo>Account</referenceTo>
    <relationshipLabel>Voice Calls</relationshipLabel>
    <relationshipName>Voice_Calls</relationshipName>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

- [ ] **Step 2: Deploy to `sally-prep`**

Run: `sf project deploy start --target-org sally-prep --source-dir force-app/main/default/objects/VoiceCall`
Expected: `Deployed Source ... Account__c ... Created` (or `Changed` on
redeploy), no errors.

- [ ] **Step 3: Verify the field exists**

Run: `sf sobject describe --sobject VoiceCall --target-org sally-prep --json | python3 -c "import json,sys; f=[x for x in json.load(sys.stdin)['result']['fields'] if x['name']=='Account__c']; print(f)"`
Expected: one field dict with `"type": "reference"`, `"referenceTo": ["Account"]`.

No permission-set changes: the existing `ContactName__c`/`RelatedRecordId`
fields `Cairn_Inbound` already writes have no corresponding
`fieldPermissions` entries anywhere in the repo — `Cairn_Inbound` is a
`RoutingFlow`, which runs in system context (no FLS enforcement), so
`Account__c` needs none either, matching that established convention.

- [ ] **Step 4: Commit**

```bash
git add force-app/main/default/objects/VoiceCall/fields/Account__c.field-meta.xml
git commit -m "$(cat <<'EOF'
Add VoiceCall.Account__c lookup field

Dedicated field for the ANI-matched Account, feeding the agent's new
AccountId linked variable — replaces RelatedRecordId as the source of
truth (Task 2).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `Cairn_Inbound` flow — set `Account__c` instead of `RelatedRecordId`

**Files:**

- Modify: `force-app/main/default/flows/Cairn_Inbound.flow-meta.xml:213-217`

**Interfaces:**

- Consumes: `VoiceCall.Account__c` (Task 1).
- Produces: `VoiceCall.Account__c` populated on single ANI match — consumed by
  Task 5's `AccountId` linked variable.

- [ ] **Step 1: Edit the `UpdateVoiceCall` input assignment**

In `recordUpdates` → `UpdateVoiceCall`, replace:

```xml
<inputAssignments>
            <field>RelatedRecordId</field>
            <value>
                <elementReference>varAccountId</elementReference>
            </value>
        </inputAssignments>
```

with:

```xml
<inputAssignments>
            <field>Account__c</field>
            <value>
                <elementReference>varAccountId</elementReference>
            </value>
        </inputAssignments>
```

(The `ContactName__c` input assignment right above it is unchanged.)

- [ ] **Step 2: Deploy to `sally-prep`**

Run: `sf project deploy start --target-org sally-prep --source-dir force-app/main/default/flows/Cairn_Inbound.flow-meta.xml`
Expected: `Deployed Source ... Cairn_Inbound ... Changed`, no errors.

- [ ] **Step 3: Verify via Flow debug run**

In Setup → Flows → `Cairn Inbound` → Debug: supply a `recordId` for an
existing `VoiceCall` test record and an `input_record.FromPhoneNumber`
matching one of the seeded Person Accounts' phone numbers (see
`REQUIREMENTS.md` §3.2 for the customer list; get an actual phone value with
`sf data query --target-org sally-prep --query "SELECT Id, Phone FROM Account WHERE Preferred_Language__c != null LIMIT 1"`).
Expected: debug trace shows `Check_Single_Match` → `Single_Match` →
`UpdateVoiceCall`, and the field being set is now `Account__c`, not
`RelatedRecordId`. Confirm with:
`sf data query --target-org sally-prep --query "SELECT Id, Account__c, ContactName__c FROM VoiceCall WHERE Id = '<the test VoiceCall id>'"`
— `Account__c` should be populated with the matched Account's id.

(Full end-to-end proof — an actual inbound call routing through this flow —
happens in Task 8; this step only proves the field-assignment logic in
isolation.)

- [ ] **Step 4: Format and commit**

```bash
npm run prettier
git add force-app/main/default/flows/Cairn_Inbound.flow-meta.xml
git commit -m "$(cat <<'EOF'
Set VoiceCall.Account__c instead of RelatedRecordId on ANI match

Account__c is the dedicated field the agent's AccountId linked variable
reads from — RelatedRecordId is dropped as the source of truth.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Activate & map the Data Streams to the Standard Data Model — DONE

Guided, hands-on — walked through together, live, in `sally-prep`'s Data
Cloud Setup. Steps below are left as originally written for reproducing this
in `sally-demo`, but see **"What actually happened"** immediately after for
the real field names, the two sandbox-lock gotchas, and the one step (Account
→ `Individual`) that turned out to be unnecessary.

Data Streams for `Account`, `Order`, `OrderItem`, `Product2` already exist
but aren't activated or mapped yet. Order matters here: `Order` (→ `Sales
Order`) first, since it's the one that establishes the relationship back to
the account; then `OrderItem` (→ `Sales Order Product`), since it relates to
both `Sales Order` and `Product`; then `Product2` (→ `Product`) and `Account`
can happen in either order.

- [x] **Step 1: Activate all four Data Streams**

Data Cloud → Data Streams. For each of the four, activate it (this triggers
Data Cloud to create a Data Lake Object — DLO — from the stream; give it a
minute per stream). Confirm each shows a successful "Last Refresh" once
active before moving on — mapping against a DLO with zero rows still works,
but you won't be able to sanity-check field values until data has actually
landed.

- [x] **Step 2: Map `Order` → `Sales Order`**

Data Cloud → Data Model → New Mapping (or open the `Order` DLO directly and
choose "Map to Data Model"). Choose **"Map to an existing Data Model
Object"** — not "create new" — and search for `Sales Order` (or whatever
your org's canvas actually calls it; standard object names can vary
slightly by release, per `SETUP_GUIDE.md` §10 — use whatever you find, not
this literal string, and tell me what it's actually called).

Map at minimum:

- `Order.Id` → the Sales Order DMO's primary key field.
- `Order.OrderNumber` → its order number field.
- `Order.TotalAmount` → its total/amount field. Search the field picker by
  label, not API name — in `sally-prep` this field's label is **"Order
  Amount"**, so searching "total" finds nothing.
- `Order.AccountId` → a relationship-typed field pointing at `Account` (this
  is the link Task 4's data graph traverses — don't skip it). In `sally-prep`
  the auto-generated `Ship To Contact` field was already mapped to something
  else and is locked (sandbox can't switch it — see Global Constraints); use
  **`Bill To Account`** instead, which is both unmapped and the correct
  semantic fit for `AccountId` anyway. Mapping the field auto-creates the
  `Sales Order` → `Account` relationship, confirmed in Step 6.
- `Order.Fulfillment_Status__c`, `Order.Estimated_Delivery_Date__c` — these
  are custom fields with no standard DMO counterpart. Data Cloud lets you
  add new custom fields to a standard DMO during mapping; add both here
  rather than leaving them unmapped, since `order_lookup`'s output contract
  needs both.
- `Order.EffectiveDate` → map this too, even though the agent doesn't report
  it — the data graph needs it to sort "most recent order" (per the design
  spec's `EffectiveDate desc` convention).

Save the mapping.

- [x] **Step 3: Map `OrderItem` → `Sales Order Product`**

Same flow, mapping the `OrderItem` DLO to the standard DMO for line items
(commonly `Sales Order Product` or `Sales Order Line Item` — again, use
whatever your canvas actually offers).

Map at minimum:

- `OrderItem.Id` → primary key.
- `OrderItem.OrderId` → relationship field pointing at `Sales Order`.
- `OrderItem.Product2Id` → relationship field pointing at `Product`.
- `OrderItem.Quantity`, `OrderItem.UnitPrice` — optional, not required by
  `order_lookup`'s current output, but cheap to include now for a richer
  answer later. Skip `OrderItem.TotalPrice` — same "system-calculated on
  insert" quirk noted in `SETUP_GUIDE.md` §10 applies here; it exists on the
  source record so it's fine to map if you want it, just don't expect to
  write to it anywhere.

Save the mapping.

- [x] **Step 4: Map `Product2` → `Product`**

Map the `Product2` DLO to the standard `Product` DMO.

Map at minimum:

- `Product2.Id` → primary key.
- `Product2.Name` → product name field.
- `Product2.ProductCode` → SKU/product code field, if the DMO has one.

Save the mapping.

- [x] **Step 5: `Account` — no additional mapping needed**

Skip this. `Account` was already mapped to the standard `Account` DMO before
this project touched it (pre-existing in this org, alongside its own
Party/AccountContact/ContactPoint scaffolding — leave that alone, it's
unrelated and harmless). It already carries the real 6 Person Accounts with
correct `Account.Id`/`Name`. The original version of this step tried
additionally mapping `Account` → `Individual`, on the theory the data graph
would root there — that turned out to be unnecessary once the root object
changed to `Account` (see "What actually happened" below); skip it in a
fresh build.

- [x] **Step 6: Confirm the relationship from `Sales Order` to `Account`**

Data Cloud → Data Model → Relationships (Edit Relationships on the canvas).
Confirm a `Sales Order` → `Account` relationship exists via the field you
mapped `Order.AccountId` onto in Step 2 (in `sally-prep` this ended up being
`Bill To Account`, after `Ship To Contact` turned out to be the wrong
semantic fit — see below), targeting `Account`'s identifier field. Mapping a
source field onto an already-relationship-typed target field auto-creates
this relationship — you may not need to add it manually. Also confirm
`Sales Order Product`'s relationships to `Sales Order` and `Product` exist
(from the `OrderId`/`Product2Id` mappings in Steps 3–4). If any link is
missing, add it manually here before moving to Task 4 — a data graph can
only traverse relationships that exist in this canvas.

- [x] **Step 7: Let data catch up, then spot-check**

Streaming ingestion isn't instant — give it a few minutes. Then, in Data
Cloud's Data Explorer, query the `Sales Order` DMO and confirm you see rows
with real `OrderNumber`/`TotalAmount` values matching what
`sf data query --target-org sally-prep --query "SELECT OrderNumber, TotalAmount FROM Order LIMIT 5"`
shows you directly. If it's empty, don't assume the mapping is broken —
recheck after a few more minutes first.

No commit for this task — Data Cloud config lives in Data Cloud, not
`force-app` (consistent with how `SETUP_GUIDE.md` §6.1 already treats this
as a manual, on-camera build step, not deployable metadata).

### What actually happened (real field/DMO names, for `sally-demo` reproduction)

Verified directly against `sally-prep`'s Data Cloud via SOQL (`ssot__*__dlm`
objects are queryable like any other sobject) — row counts and sample values
cross-checked against core Salesforce and matched exactly:

- **`Sales Order`** (`ssot__SalesOrder__dlm`): `ssot__OrderNumber__c`,
  `ssot__TotalAmount__c` (mapped from `Order.TotalAmount`, labeled "Order
  Amount" in this org), `Fulfillment_Status__c`, `Estimated_Delivery_Date__c`
  (custom fields, no `ssot__` prefix), and `ssot__BillToAccountId__c` (mapped
  from `Order.AccountId` — **not** `ssot__ShipToContactId__c`, which was
  already locked to a different, empty mapping). Mapping `AccountId` onto
  `Bill To Account` auto-created the `Sales Order` → `Account` relationship.
- **`Sales Order Product`** (`ssot__SalesOrderProduct__dlm`): `ssot__SalesOrderId__c`,
  `ssot__ProductId__c`, `ssot__OrderedQuantity__c`, `ssot__UnitPriceAmount__c`
  — mapped cleanly on the first attempt, 329/329 rows match core `OrderItem`.
- **`Product`** (`ssot__Product__dlm`): `ssot__Name__c`, `ssot__ProductCode__c`
  — 132/132 rows match core `Product2` (only ~20 of which are real Cairn
  products; the rest are unrelated pre-existing `Product2` records already in
  the org — harmless noise, since no seeded order line item references them).
- **`Account`** (`ssot__Account__dlm`): already mapped before this project
  touched it (pre-existing CRM Data Kit scaffolding — `ssot__Id__c`,
  `ssot__Name__c` hold the real 6 Person Accounts correctly). This is the
  data graph's root object (see Task 4) — no `Individual` mapping needed.
- **Dead end, harmless, left in place:** an `Account` → `Individual` mapping
  (`Account.Id` → `ssot__PrimaryAccountId__c`, since `Individual`'s actual
  primary key was locked) was built while `Individual` was still the planned
  root object. Once the root changed to `Account`, this became unnecessary —
  it's unused by the data graph but doesn't hurt anything left mapped.

---

## Task 4: Build the Data Graph — DONE

Guided, hands-on walkthrough — the genuinely new part. Do this together, in
Data Cloud → Data Graphs → New. Steps below are left as originally written for
reproducing this in `sally-demo`, but see **"What actually happened"**
immediately after for the real UI mechanics (no `Individual`/lookup-key screen
exists the way originally assumed), the graph's actual name, and one open risk
carried into Task 5.

- [x] **Step 1: Understand what you're building before opening the UI**

A **data graph** is a saved, denormalized JSON-shaped view Data Cloud
assembles at query time by walking a chosen root DMO out across its mapped
relationships — contrast with:

- A **DMO query**: one flat object, no nesting.
- A **vector search index** (what `company_faq`/`product_qa` use):
  unstructured/semantic similarity search over text chunks — no structure,
  no relationships.

A data graph is the right tool here specifically because an "order" is
inherently multi-object (the order itself, its line items, the products on
those line items, the customer who placed it) — exactly the shape
`SETUP_GUIDE.md` §5.1 calls out as what a data graph is suited for.

- [x] **Step 2: Choose the root object**

Root the data graph at **`Account`** (not `Individual`, not `Sales Order`).

The original design called for rooting at `Individual` — that changed during
Task 3 execution once `Individual`'s primary key turned out to be locked on
this sandbox (see Task 3's "What actually happened"). `Account` achieves the
exact same goal: rooting there is what makes "query by the caller's matched
Account, get back their order" a single call — the graph naturally nests
that customer's orders underneath. It's also a more direct fit than
`Individual` ever would have been, since `VoiceCall.Account__c` (Task 1) is
already an Account id — no extra hop through an `Individual`-side field
needed. If you rooted at `Sales Order` instead, you'd need the order id or
number up front for every query, which defeats the known-caller path this
whole feature is for.

- [x] **Step 3: Add the relationship chain**

In the data graph builder, starting from `Account`:

1. Add the related object `Sales Order` (the `Bill To Account` relationship
   confirmed in Task 3, Step 6) as a 1:many child.
2. Under `Sales Order`, add `Sales Order Product` as a 1:many child.
3. Under `Sales Order Product`, add `Product` as a many:1 relationship
   (lookup, not nested collection — a product is referenced, not owned, by
   the line item).

- [x] **Step 4: Select fields to project at each level**

- `Account`: `ssot__Id__c` (the identifier field), `ssot__Name__c`.
- `Sales Order`: `ssot__OrderNumber__c`, `ssot__TotalAmount__c`, the mapped
  `Fulfillment_Status__c` field, the mapped `Estimated_Delivery_Date__c`
  field, and the order's effective/created date field (needed for "most
  recent" sorting — check whichever date field your `Sales Order` mapping
  carries for `Order.EffectiveDate`).
- `Sales Order Product`: `ssot__OrderedQuantity__c`, `ssot__UnitPriceAmount__c`
  (optional — nice to have for richer answers later, not required by
  `order_lookup`'s current output contract).
- `Product`: `ssot__Name__c`.

- [x] **Step 5: Define lookup keys**

Add two lookup keys on the data graph:

1. `Account`'s identifier field (`ssot__Id__c`) — the known-caller path
   (`AccountIdInput` in the agent action, Task 5) — matches
   `VoiceCall.Account__c` directly, no translation needed.
2. `Sales Order.OrderNumber` — the explicit-order-number path (callers the
   ANI match didn't cover, or a caller asking about a different order than
   the one proactively surfaced).

Both need to resolve through the _same_ data graph, since `order_lookup`
will call one action either way (per the spec's "full replace" decision).

- [x] **Step 6: Save, publish/activate the data graph**

Give it a clear developer name — e.g. `Cairn_Order_Lookup_Graph` — you'll
need this exact name in Task 5. Publish/activate it.

- [x] **Step 7: Sanity-check it's queryable, independent of the agent**

Use Data Cloud's Data Explorer (or the data graph's own "Query" preview
panel if your org's builder has one) to run a lookup by `Account` id for
2–3 seeded accounts (get real ids: `sf data query --target-org sally-prep --query "SELECT Id, Name FROM Account WHERE Preferred_Language__c != null LIMIT 3"`).
Expected: each query returns that customer's order(s) nested with line items
and product names — matching what `sf data query` shows you directly against
core Salesforce for the same account, as a cross-check
(`SELECT OrderNumber, TotalAmount, Fulfillment_Status__c, Estimated_Delivery_Date__c FROM Order WHERE AccountId = '<id>' ORDER BY EffectiveDate DESC`).
Also run one lookup by `OrderNumber` and confirm it returns the same shape.

If a freshly-graphed order doesn't show up, don't assume it's broken —
allow a few minutes for streaming ingestion to catch up (`SETUP_GUIDE.md`
§10's existing gotcha applies to the data graph too).

No commit for this task — the data graph lives in Data Cloud, not
`force-app` (consistent with how this repo already treats Data Cloud config:
`SETUP_GUIDE.md` §6.1 frames ingestion/mapping/data-graph steps as manual,
on-camera build steps, not deployable metadata — reproduced by hand in
`sally-demo` by re-following this same walkthrough, not by a metadata
deploy).

### What actually happened (real UI mechanics, graph name, and one open risk for Task 5)

Verified directly in `sally-prep`'s Data Cloud UI plus cross-checked against
core Salesforce via SOQL — matched exactly on every field tested:

- **Graph type — Standard, not Real-Time.** The New Data Graph wizard offers
  `Standard Data Graph` ("fast near real time performance") vs
  `Real-Time Data Graph` ("resides in Hot Layer, supports computation in
  milliseconds"). Despite this being for a voice agent, **Standard is
  correct**: Real-Time Data Graphs are consumed via the Web/Mobile SDK +
  Query API path for Journey Builder/Real-Time Interaction Management
  personalization — a different code path from the Data Cloud
  Retriever → Agent Builder grounding mechanism Task 5 needs. Standard Data
  Graphs are what's exposed to that retriever picker.
- **Root, chain, and fields built as planned** — `Account` (2 fields:
  `ssot__Id__c`, `ssot__Name__c`) → `Sales Order` (9 fields) →
  `Sales Order Product` (11 fields, a few more than the plan's minimum:
  `List Price Amount`, `Order Product Number`, `Total Price Amount` also
  included, harmless) → `Product` (6 fields, `Product Family`/`Description`
  also included beyond the plan's `Name`/`ProductCode` minimum).
- **`Order.EffectiveDate`'s real target field, undocumented in Task 3:**
  neither `Activated Date` (`ssot__ActivatedDateTime__c`) nor `Created Date`
  (`ssot__CreatedDate__c`) holds it — both are bulk-load timestamps, identical
  across every order. The actual field is **`Order Start Date`**
  (`ssot__OrderStartDate__c`) — confirmed by comparing 5 orders' values
  directly against core `Order.EffectiveDate`, exact match every time. Task
  3's "what actually happened" note should have listed this mapping and
  didn't; noting the gap here for anyone reproducing in `sally-demo`. The
  `Sales Order` node's **Sort and Limit** section (on the `Filters` tab) is
  set to `Sort Field: Order Start Date`, `Sort Order: Descending`,
  `Record Limit: 100` — this is what actually drives "most recent order"
  ordering, not a graph-level setting.
- **No "lookup keys" configuration screen exists in this builder**, despite
  the plan (and Data Graph API docs describing "primary/secondary lookup
  keys") assuming one. Ruled out every plausible candidate in the UI:
  - The `Filters` tab's `Filter Conditions` panel requires a literal
    `Value` — leaving it blank silently reverts to unset on save/refresh.
    It's a static data-scoping filter (e.g. "only Shipped orders"), not a
    runtime-bound query parameter.
  - `Edit Properties` only holds Name/API Name/Data Space/Description.
  - The `Preview` button is a **JSON schema preview** (field shapes/types),
    not a live query tool.
  - A field-level chevron dropdown exists only on Key/Foreign-Key-type rows
    (offering "Select as Root Key") — never on plain business fields like
    `Order Number`. Whatever "lookup key" means at the API level, it isn't
    configured here for arbitrary fields.
- **Empirically, only the root's primary key is queryable.** Data Cloud →
  Data Explorer → Objects → Data Graphs → `Compass Order Lookup` lists all 6
  rows keyed by `Account Id` (no filter/search control at all — it's a plain
  record browser, not a query tool), each with a `Json Blob` column holding
  the full nested payload. Verified account `001Sv00000gWLyyIAG` (Maria
  Alvarez)'s JSON: 20 nested orders, correctly sorted by `Order Start Date`
  descending, and order `00000226`'s fields (`TotalAmount` 1808,
  `Fulfillment_Status__c` "Processing", `Estimated_Delivery_Date__c`
  2026-08-28, `Order Start Date` 2026-08-21) matched core Salesforce's
  `Order` row for that `OrderNumber` exactly. **The known-caller
  (Account id) lookup path is fully proven.**
- **Open risk carried into Task 5 — the `OrderNumber` lookup path is
  unverified.** Data Explorer's Objects browser has no way to filter by
  `OrderNumber` (only `Account Id` at the `Account` root, or the internal
  `Sales Order Id` from within `Sales Order Product`'s foreign-key field —
  neither is the caller-facing order number). This may just be a limitation
  of Data Explorer's basic browser rather than the actual Data Graph Query
  API or Agent Builder's retriever-action generation, both of which are
  untested here — Task 5 needs to confirm, when building the retriever
  action, whether `OrderNumber` is a usable input. Considered building a
  second, `Sales Order`-rooted graph as a hedge, but rejected for now: it
  would likely reproduce the same problem under `Sales Order Id` (still an
  internal id, not `OrderNumber`, which was never mapped as a Key/Qualifier
  field in Task 3), and the plan's design explicitly wants **one** data
  graph serving both paths. If Task 5 proves `OrderNumber` truly isn't
  queryable through the retriever, revisit then — possibly by remapping
  `OrderNumber` as a Key Qualifier field in Data Model Mapping (Task 3
  territory), not by adding a second graph.
- **Graph name:** built as **`Compass Order Lookup`**
  (API name **`Compass_Order_Lookup`**) — not the plan's suggested
  `Cairn_Order_Lookup_Graph`. Task 5 must use `Compass_Order_Lookup` verbatim
  as the `retriever://` target.
- **Refresh schedule:** every 1 hour (Standard Data Graph, scheduled
  refresh — matches the "near real time," not instant, cadence Task 3
  already established for the underlying Data Streams).

---

## Task 5: Wire the data graph into `order_lookup`

Part UI (Agent Builder), part file edit (`Cairn_Compass.agent`) — done
together since the file edit depends on what Agent Builder generates.

**Files:**

- Modify: `force-app/main/default/aiAuthoringBundles/Cairn_Compass/Cairn_Compass.agent`

**Interfaces:**

- Consumes: `VoiceCall.Account__c` (Task 1), `Cairn_Order_Lookup_Graph` data
  graph (Task 4, or whatever name you actually gave it).
- Produces: `@variables.AccountId` — not consumed elsewhere in this plan, but
  is the linked variable future work (spec §8) would build on.

- [x] **Step 1: Add the data graph as a retriever action, in Agent Builder**

Open `Cairn_Compass` in Agent Builder → `Order Lookup` topic → Actions → Add
Action → Data Cloud Retriever (or your org's equivalent label) → select the
`Cairn_Order_Lookup_Graph` data graph. Agent Builder generates an action with
inputs matching the lookup keys from Task 4 Step 5 and outputs matching the
projected fields from Task 4 Step 4.

- [x] **Step 2: Record the generated action's exact shape**

Write down (you'll need these verbatim for Step 4): the action's
`developerName` (this becomes the `retriever://<name>` target), and its
input/output parameter names as Agent Builder generated them.

- [x] **Step 3: Add the `AccountId` linked variable**

In `Cairn_Compass.agent`, in the `variables:` block, immediately after the
existing `FirstName` variable:

```
    AccountId: linked string
        source: @VoiceCall.Account__c
        description: "The Account Id matched from the caller's ANI in the inbound flow, if any. Empty when the ANI didn't match a single Person Account."
```

- [x] **Step 4: Update `order_lookup`'s reasoning instructions**

Replace the `order_lookup` subagent's `reasoning.instructions` block:

```
    reasoning:
        instructions: |
            Callers here want to check an order's status, ask about a return,
            or ask to change or cancel an order.
            If you already know the caller's account (AccountId is set),
            don't ask for any identifiers — call look_up_order right away
            with just the account id, and lead with their most relevant
            order. If the caller indicates that's not the order they meant,
            ask for the order number and look it up again.
            If you don't know the caller's account, collect either the order
            number, or the caller's full name plus a phone number or email —
            whichever is fastest for the caller to give you. Don't ask for
            both if one is enough.
            Once you have enough to identify the order, call look_up_order.
            Say something short while it runs, since it isn't instant.
            If it finds an order, lead with the answer: report the order
            number, total, fulfillment status, and estimated delivery date in
            one short, natural sentence — don't read it back as a list of
            fields.
            If it doesn't find a matching order, apologize briefly, let the
            caller know you'll get them to someone who can look further into
            it, then hand them off.
            If the caller wants something self-service can't do (like
            changing or cancelling an order), hand them off the same way once
            you've looked up the order.
```

- [x] **Step 5: Retarget `order_lookup_action`**

Replace the action definition (still named `order_lookup_action`, so the
`actions:` reference in `reasoning.actions.look_up_order` above doesn't need
to change):

```
    actions:
        order_lookup_action:
            description: "Look up an order by the caller's known account, an order number, or the caller's full name plus a phone number or email. Returns whether a matching order was found, and if so its number, total, fulfillment status, and estimated delivery date."
            target: "retriever://<the developerName from Step 2>"
            inputs:
                AccountIdInput: string
                    description: "The caller's Account Id, if already known from the ANI match."
                OrderNumberInput: string
                    description: "The order number, if the caller gave one."
                CustomerNameInput: string
                    description: "The caller's full name — pair with a phone number or email to find their order."
                CustomerPhoneInput: string
                    description: "The caller's phone number — pair with their name to find their order."
                CustomerEmailInput: string
                    description: "The caller's email address — pair with their name to find their order."
            outputs:
                OrderFound: boolean
                    description: "Whether a matching order was found."
                    is_displayable: True
                OrderNumberOutput: string
                    description: "The order's number."
                    is_displayable: True
                TotalAmountOutput: object
                    complex_data_type_name: "lightning__currencyType"
                    description: "The order's total amount."
                    is_displayable: True
                FulfillmentStatusOutput: string
                    description: "The order's fulfillment status."
                    is_displayable: True
                EstimatedDeliveryDateOutput: date
                    description: "The order's estimated delivery date."
                    is_displayable: True
```

Reconcile the input/output names above against what Agent Builder actually
generated in Step 2 — if the generated retriever action's parameter names
differ (likely, since Data Cloud generates its own names from the data
graph's lookup keys/fields), rename the `inputs`/`outputs` keys to match
exactly, and update the `with` bindings in `reasoning.actions.look_up_order`
(§ Task 5, `agent-script-core-language` convention: `with <InputName> = ...`)
accordingly. The 5 output field names must stay whatever downstream
reasoning instructions already reference (`OrderFound`, etc.) — if Data
Cloud's generated output names differ, keep an explicit
`outputs: <GeneratedName>` and reference that name in reasoning text, rather
than silently renaming and breaking the "lead with the answer" instruction's
implicit contract with the outputs.

`CustomerNameInput`/`CustomerPhoneInput`/`CustomerEmailInput` stay wired the
same way they already are in `reasoning.actions.look_up_order` (`with
OrderNumberInput = ...` etc.) — only add `with AccountIdInput = @variables.AccountId`
to that block, since it's a linked variable, not caller-spoken input.

- [x] **Step 6: Deploy and preview**

Run: `sf project deploy start --target-org sally-prep --source-dir force-app/main/default/aiAuthoringBundles/Cairn_Compass`
Then AFDX: Preview This Agent, in **live** mode (Data Cloud dependency means
simulated mode can't meaningfully exercise this). Test two utterances:

1. As a known caller (preview tooling that lets you set the `VoiceCall`
   context's `Account__c`, or test via an actual routed call) — "what's the
   status of my order?" with no identifiers given. Expected: agent answers
   without asking for anything.
2. An order number spoken explicitly. Expected: still resolves correctly
   through the same action.

- [x] **Step 7: Format and commit**

```bash
npm run prettier
git add force-app/main/default/aiAuthoringBundles/Cairn_Compass/Cairn_Compass.agent
git commit -m "$(cat <<'EOF'
Wire order_lookup to the Data Cloud data graph retriever

Adds the AccountId linked variable (sourced from VoiceCall.Account__c)
and retargets order_lookup_action from the Flow to the data graph
retriever, so a caller whose ANI matched an Account gets their order
surfaced without repeating identifiers.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### What actually happened (retriever → Apex correction, and an unreadable API result)

Steps 1–2 above are **wrong and were not performed**: there is no no-code
Data Cloud retriever action for a data graph. Setup → Retrievers offers only
`Data Cloud: Retrieve data from a Data Cloud search index` — the mechanism
`company_faq`/`product_qa` use — which requires a DMO with a vector search
index and rejects a data graph outright ("No DMO with search index
available"). A data graph is reachable only through the Data Graph Query API.
So the action retargets to `apex://OrderLookupDataGraph`, not `retriever://`.
Step 3's `AccountId` linked variable already existed (commit `e571f3e`) and
needed no change.

- **Only the root primary key is a lookup key.** `getDataGraphData` and
  `getDataGraphDataWithLookupKeys` accept the root DMO's primary key (the
  Account id) — not nested fields like `Sales Order.OrderNumber`. Task 4's
  "two lookup keys" idea is therefore not achievable, and remapping
  `OrderNumber` as the Sales Order DMO's primary key would hit the same
  "Switch Mapping is not supported on Sandbox Org" lock as Task 3. Instead
  `OrderLookupDataGraph` resolves to an Account id first with plain SOQL
  against core CRM (`Order.OrderNumber` → `AccountId`, or name plus phone/email
  → `Account.Id`), then always queries the graph by that id. A caller the ANI
  already matched skips the resolve entirely.
- **`CdpQueryOutput.data` rows are not Apex `Map`s** — they are raw Java
  `com.google.gson.internal.LinkedTreeMap` objects. `JSON.serialize` on the
  list throws a clean `JSONException`, but calling _any_ `Map` method on a row
  (`get`, `keySet`, `size`, `toString`) faults the interpreter below the Apex
  layer: `try`/`catch` does not intercept it, and it surfaced variously as
  `InterpreterRuntimeException: Made lookup for method that does not exist:
com/salesforce/api/fast/Map.keySet()`, an opaque `UNKNOWN_EXCEPTION`, and —
  most misleadingly — a run with **zero debug output**, which looked like the
  method never executed. It had executed; the fault aborts the request before
  logs flush. (An empty `sf apex log list` is not evidence either way: without
  a TraceFlag, anonymous-Apex logs are never persisted as `ApexLog` rows.)
  `String.valueOf(row)` is safe — it dispatches to the Java `toString()` — and
  renders as `{json_blob__c=<the whole graph as JSON>, version__c=0}`. Cutting
  that payload out of the string and running `JSON.deserializeUntyped` on it
  yields ordinary Apex collections. That is what `parseRow` does, and it made
  `queryAnsiSqlV2`/REST-callout fallbacks unnecessary — the data graph itself
  is what the demo actually queries.
- **The known-caller path had to become deterministic.** Left to invoke
  `look_up_order` on its own, the reasoning LLM would not call an action it had
  no inputs to fill — it narrated "one sec, let me pull that up" and ended the
  turn, then on later attempts **fabricated** order numbers and totals
  (`#40389 / $148.50`, `#45219 / $87.50`, `#1043982 / $89.95` on successive
  runs). Three instruction rewrites, including an explicit "never invent an
  order's details", all failed. The fix is architectural: `order_lookup`'s
  `before_reasoning` hook now runs the action deterministically whenever
  `AccountId` is set and stores the result in `@variables.known_order_summary`,
  which the instructions interpolate — the real data is in the prompt before
  the model reasons, so there is nothing left to invent. This is why the Apex
  gained a sixth output, `OrderSummaryOutput`: Agent Script mutable variables
  are limited to `string`/`number`/`boolean`/`object` (`date` is
  action-parameter-only), so the five typed outputs cannot each be held in one.
- **`lightning__currencyType` is invalid for an Apex `Decimal` output.** The
  runtime rejected the Flow-era declaration with an exact instruction: use
  `lightning__numberType`. Worth knowing when porting any Flow action to Apex.
- **`sf agent preview` is drivable headlessly**, contrary to the assumption
  that a human had to run it. It is an Ink TUI needing a real pty, but
  `script -qc "…" /dev/null < fifo` with `stty cols 120 rows 45` works, and
  `--output-dir` writes machine-readable `transcript.jsonl` plus per-turn
  traces (the traces are what proved the action was never invoked). Linked
  variables are set with the **`$Context.` prefix** —
  `--context-variables '$Context.AccountId=…'`; without the prefix they are
  treated as state variables and silently do not resolve.

**Verified live in `sally-prep`** (Maria Alvarez, `001Sv00000gWLyyIAG`):

| Utterance                                                  | Result                                                                                                                    |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| "hey, I was wondering about my recent order" (ANI matched) | "Maria, your most recent order is 00000226 for $1,808, and it's still processing… August 28, 2026" — no identifiers asked |
| "actually I meant order 00000222" (same call)              | $1,127, Processing, August 30, 2026                                                                                       |
| "can you check order 00000216 for me?" (no ANI match)      | $1,224, Processing, August 29, 2026                                                                                       |

All values match core CRM exactly. The Apex was also exercised directly across
all six branches (known account, order number, name+email, name+phone,
insufficient identifiers, unknown order number) — the last two correctly return
`OrderFound = false` rather than failing.

**Two caveats for the recording:** the data graph refreshes hourly, so an order
created mid-demo will not appear until the next refresh; and `before_reasoning`
re-runs the graph query on every turn inside `order_lookup`, which adds a
round-trip per turn.

### Addendum (2026-08-29): unverified-caller order verification

Follow-on change, done after Task 5 was otherwise complete: an order number
alone was resolvable to an Account (and its data graph payload) with no other
check, for any caller the ANI didn't already match — a guessable order number
was sufficient to disclose someone else's order. `resolveAccountId`'s
name+phone/email branch had the same weakness once removed from consideration:
neither factor was verified against the order itself.

**What changed:**

- `OrderLookupDataGraph.Request` drops `CustomerNameInput`/`CustomerPhoneInput`/
  `CustomerEmailInput` and gains `OrderDateInput: Date`. `resolveAccountId` now
  requires `OrderNumberInput` **and** `OrderDateInput` together for a caller
  without a known `AccountIdInput`, and checks the resolved `Order.EffectiveDate`
  against `OrderDateInput` — a mismatch, or either input missing, returns no
  match, same as today's "order not found" path. The known-account path
  (`AccountIdInput` set) is unchanged and skips this check, since ANI already
  established identity.
- `order_lookup`'s reasoning instructions: an unidentified caller (empty
  `known_order_summary`) is now asked for the order number and the date it was
  placed together, not offered a "whichever is fastest" choice of order number
  or name+phone/email. If they can't give both, or the lookup doesn't match,
  the agent escalates immediately rather than trying another identifier. A
  match found this way gets a deliberately minimal reply — fulfillment status
  and estimated delivery date only, no name, no order number/total readback —
  since the caller still isn't personally identified. The ANI-verified path
  (ask-nothing, personalized, full detail) is unchanged.

**Verified in `sally-prep`** via headless `sf agent preview --use-live-actions`
(order `00000246`, placed `2026-08-21`, real fulfillment status `Processing`
and delivery date `2026-08-26` cross-checked against `sf data query`):

| Scenario                                                       | Result                                                                                                             |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Unidentified caller, correct order number + date               | "That order is still processing, with an estimated delivery date of August 26th." — no name, no order number/total |
| Unidentified caller, order number but can't recall the date    | Agent declines to look it up and escalates immediately, without trying another identifier                          |
| ANI-identified caller, no identifiers given (regression check) | Unchanged: personalized, full detail (order number, total, status, delivery date)                                  |

`REQUIREMENTS.md` §4 and `SETUP_GUIDE.md` §6.1.3 updated to match.

---

## Task 6: Remove `Cairn_Order_Lookup` (Flow) and update the permission set

**Files:**

- Delete: `force-app/main/default/flows/Cairn_Order_Lookup.flow-meta.xml`
- Modify: `force-app/main/default/permissionsets/Cairn_Voice_Agent.permissionset-meta.xml`

**Interfaces:**

- Consumes: Task 5's live-verified data graph action (don't run this task
  until Task 5, Step 6's preview passes — this is the point of no return for
  the Flow path).

- [ ] **Step 1: Confirm nothing else references the Flow**

Run: `grep -rn "Cairn_Order_Lookup" force-app/ docs/` — expect only the
permission set's `flowAccesses` entry (removed next) and doc mentions (Task
8 handles those). If anything else references it, stop and investigate
before deleting.

- [ ] **Step 2: Remove the `flowAccesses` entry**

In `Cairn_Voice_Agent.permissionset-meta.xml`, delete this block:

```xml
<flowAccesses>
        <flow>
Cairn_Order_Lookup;
  </flow>
        <enabled>true</enabled>
    </flowAccesses>
```

(Leave the `Cairn_Create_Case` `flowAccesses` block and all `fieldPermissions`/
`objectPermissions` blocks untouched — `Order`/`Account` object read access
is still needed for whatever reads the data graph's underlying source
objects.)

- [ ] **Step 3: Delete the Flow**

```bash
rm force-app/main/default/flows/Cairn_Order_Lookup.flow-meta.xml
```

- [ ] **Step 4: Deploy the permission set change, then delete the Flow from the org**

Run: `sf project deploy start --target-org sally-prep --source-dir force-app/main/default/permissionsets/Cairn_Voice_Agent.permissionset-meta.xml`
Then delete the Flow from `sally-prep` itself (destructive — deploying a
deletion requires a destructive changes manifest, or delete via Setup →
Flows → `Cairn Order Lookup` → deactivate, then delete):
`sf project delete source --target-org sally-prep --metadata Flow:Cairn_Order_Lookup --no-prompt`

- [ ] **Step 5: Verify**

Run: `sf project retrieve start --target-org sally-prep --metadata Flow:Cairn_Order_Lookup` —
expected: error, flow not found (confirms it's gone from the org, not just
local files).

- [ ] **Step 6: Commit**

```bash
git add -A force-app/main/default/flows/Cairn_Order_Lookup.flow-meta.xml force-app/main/default/permissionsets/Cairn_Voice_Agent.permissionset-meta.xml
git commit -m "$(cat <<'EOF'
Remove Cairn_Order_Lookup flow, now replaced by the data graph retriever

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update `SETUP_GUIDE.md` and `REQUIREMENTS.md`

**Files:**

- Modify: `docs/SETUP_GUIDE.md` §6.1, §10
- Modify: `docs/REQUIREMENTS.md` §5.1

**Interfaces:** None — doc-only task, no code dependencies.

- [ ] **Step 1: `SETUP_GUIDE.md` §6.1 — mark stage 3 as built, document the known-caller path**

Rewrite the `3. **Data360 Data Graph**` list item to reflect what was
actually built: the ingest/map sub-step stays (already done, described
correctly); the "build the data graph" sub-step should name the actual root
(`Account`) and relationship chain (`Account` → `Sales Order` →
`Sales Order Product` → `Product`) and the two lookup keys (Account id,
order number), matching Task 4 above; the "wire it up" sub-step should add a
sentence: when the inbound flow (§ new cross-reference, see Step 3 below) has
already matched the caller's ANI to an Account, `order_lookup` calls this
retriever with just the account id and skips asking for identifiers.

- [ ] **Step 2: `REQUIREMENTS.md` §5.1 — same update, higher-level**

Add one sentence to the stage-3 bullet: "The data graph also serves calls
where the caller's ANI has already been matched to an Account (see §2.3) —
those calls skip identifier collection entirely."

- [ ] **Step 3: `SETUP_GUIDE.md` §10 — add the `RelatedRecordId` → `Account__c` gotcha**

Add a new bullet to the Known Gotchas list:

```markdown
- `VoiceCall.Account__c` (custom lookup) is the source of truth for the
  ANI-matched Account, set by `Cairn_Inbound` — the standard `RelatedRecordId`
  field is no longer set by this flow. Don't rely on `RelatedRecordId` for
  this purpose elsewhere in the org.
```

- [ ] **Step 4: Format and commit**

```bash
npm run prettier
git add docs/SETUP_GUIDE.md docs/REQUIREMENTS.md
git commit -m "$(cat <<'EOF'
Document the ANI-personalized order lookup data graph build

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: End-to-end verification in `sally-prep`

Guided, manual — this is the rehearsal-checklist proof that everything built
in Tasks 1–7 actually works together, not just individually.

- [ ] **Step 1: Known-caller path, via a real or simulated inbound call**

Place (or simulate, if a real Amazon Connect test call isn't set up yet) an
inbound call from a phone number matching one of the 6 seeded Person
Accounts. Confirm:

- The welcome message uses their first name (already-working behavior,
  regression-check only).
- Asking "what's the status of my order" with zero identifiers given
  resolves to a real, correct order (cross-check against
  `sf data query --target-org sally-prep --query "SELECT OrderNumber, TotalAmount, Fulfillment_Status__c, Estimated_Delivery_Date__c FROM Order WHERE AccountId = '<that account's id>' ORDER BY EffectiveDate DESC LIMIT 1"`).

- [ ] **Step 2: Unmatched-caller path (regression check)**

Call from a number not in the seed data. Confirm `order_lookup` still asks
for an order number or name+phone/email, and resolves correctly when given
one — unchanged from the pre-this-feature behavior.

- [ ] **Step 3: Override path**

As a known caller, after the agent proactively surfaces an order, say a
different, valid order number belonging to the same account. Confirm the
agent looks that one up instead.

- [ ] **Step 4: Update the rehearsal checklist**

In `SETUP_GUIDE.md` §8, check off "Order lookup data graph returns the
correct order, line items, and customer/product details for at least 2–3
sample orders" if Steps 1–3 above passed for at least that many accounts.

No commit needed beyond Task 7's doc commit unless §8 checkbox state itself
needs a follow-up commit — if so, fold it into a small commit:

```bash
git add docs/SETUP_GUIDE.md
git commit -m "$(cat <<'EOF'
Check off order lookup data graph rehearsal item

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Execution note

Tasks 1, 2, 6, and 7 are ordinary file edits with objective pass/fail
verification — safe for autonomous execution (subagent-driven or inline).
Tasks 3, 4, 5, and 8 require a live Salesforce/Data Cloud UI and judgment
calls that depend on what your specific org's canvas actually shows (DMO
names, generated action shapes) — these are written as checklists to work
through together, live, narrated step-by-step, not delegated to a subagent.
Recommend: interleave — inline execution throughout, so the same session
handles both the file-edit tasks and narrates the UI walkthrough tasks in
order, rather than context-switching between a dispatched subagent and a
live UI session.
