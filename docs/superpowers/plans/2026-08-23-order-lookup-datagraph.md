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
data graph rooted at `Individual`, joined out to `Sales Order` → `Sales Order
Product` → `Product`, queryable by either Account/Individual id or order
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
- Data Cloud ingestion (Data Streams) and Standard Data Model mapping for
  `Account`/`Order`/`OrderItem`/`Product2` are **already done** in
  `sally-prep` — do not redo them; Task 3 is a verification pass only.
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

## Task 3: Verify Data Cloud ingestion & mapping (recap, not a rebuild)

This is a guided checklist, not a code task — walked through together, live,
in `sally-prep`'s Data Cloud Setup. Since ingestion/mapping is already done,
this is a quick correctness pass before building the data graph on top of it
in Task 4. A mapping mistake here silently breaks the data graph later, so
it's worth the five minutes.

- [ ] **Step 1: Confirm the four Data Streams are running**

Data Cloud → Data Streams. Confirm four streams exist, sourced from the
Salesforce CRM connector (not the "Sales and Service Cloud" data kit): one
each for `Account` (filtered or confirmed to carry Person Accounts),
`Order`, `OrderItem`, `Product2`. Each should show a recent, successful
"Last Refresh."

- [ ] **Step 2: Confirm the Standard Data Model mapping**

Data Cloud → Data Model → filter to "Mapped" objects. Confirm:

| Salesforce object | Mapped Data Model Object |
| --- | --- |
| `Account` (Person Accounts) | `Individual` |
| `Order` | `Sales Order` |
| `OrderItem` | `Sales Order Product` |
| `Product2` | `Product` |

Note the *exact* DMO names shown in your org's canvas — they can vary
slightly by release/org (per `SETUP_GUIDE.md` §10). Write down whatever your
canvas actually shows; Task 4 references these names and needs the real
ones, not the table above verbatim if your org differs.

- [ ] **Step 3: Spot-check field-level mapping on the two objects the data graph will project fields from**

Click into the `Sales Order` DMO mapping and confirm `OrderNumber`,
`TotalAmount`, `Fulfillment_Status__c`, `Estimated_Delivery_Date__c` are all
mapped to DMO fields (custom fields map to custom DMO fields with the same
or a generated name — confirm they're present, not dropped). Same check on
`Individual` for whatever field carries the Account `Id` (should map to the
DMO's primary/party identifier).

- [ ] **Step 4: Confirm the relationships between the four DMOs exist in the Data Model canvas**

Still in Data Model, switch to the canvas/relationship view. Confirm
`Individual` → `Sales Order` → `Sales Order Product` → `Product` are linked
by relationship (not just independently mapped) — a data graph can only
traverse relationships that already exist here. If any link is missing, add
it now (this is schema-level, harmless to add if it's not already there):
relationship from `Sales Order` to `Individual` on the buyer/account
reference field, `Sales Order Product` to `Sales Order` on the order
reference field, `Sales Order Product` to `Product` on the product
reference field.

No commit for this task — it's a verification pass against existing org
config, no files change.

---

## Task 4: Build the Data Graph

Guided, hands-on walkthrough — the genuinely new part. Do this together, in
Data Cloud → Data Graphs → New.

- [ ] **Step 1: Understand what you're building before opening the UI**

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

- [ ] **Step 2: Choose the root object**

Root the data graph at `Individual` (not `Sales Order`). Rooting at
`Individual` is what makes "query by the caller's matched Account, get back
their order" a single call — the graph naturally nests that customer's
orders underneath. If you rooted at `Sales Order` instead, you'd need the
order id or number up front for every query, which defeats the known-caller
path this whole feature is for.

- [ ] **Step 3: Add the relationship chain**

In the data graph builder, starting from `Individual`:
1. Add the related object `Sales Order` (the relationship you confirmed/added
   in Task 3, Step 4) as a 1:many child.
2. Under `Sales Order`, add `Sales Order Product` as a 1:many child.
3. Under `Sales Order Product`, add `Product` as a many:1 relationship
   (lookup, not nested collection — a product is referenced, not owned, by
   the line item).

- [ ] **Step 4: Select fields to project at each level**

- `Individual`: the identifier field (whatever your org's canvas calls it —
  Task 3 Step 2), first name.
- `Sales Order`: `OrderNumber`, `TotalAmount`, the mapped
  `Fulfillment_Status__c` field, the mapped `Estimated_Delivery_Date__c`
  field, and the order's effective/created date field (needed for "most
  recent" sorting — check whichever date field your `Sales Order` mapping
  carries for `Order.EffectiveDate`).
- `Sales Order Product`: quantity, unit price (optional — nice to have for
  richer answers later, not required by `order_lookup`'s current output
  contract).
- `Product`: product name.

- [ ] **Step 5: Define lookup keys**

Add two lookup keys on the data graph:
1. `Individual`'s identifier field — the known-caller path (`AccountIdInput`
   in the agent action, Task 5).
2. `Sales Order.OrderNumber` — the explicit-order-number path (callers the
   ANI match didn't cover, or a caller asking about a different order than
   the one proactively surfaced).

Both need to resolve through the *same* data graph, since `order_lookup`
will call one action either way (per the spec's "full replace" decision).

- [ ] **Step 6: Save, publish/activate the data graph**

Give it a clear developer name — e.g. `Cairn_Order_Lookup_Graph` — you'll
need this exact name in Task 5. Publish/activate it.

- [ ] **Step 7: Sanity-check it's queryable, independent of the agent**

Use Data Cloud's Data Explorer (or the data graph's own "Query" preview
panel if your org's builder has one) to run a lookup by `Individual` id for
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

- [ ] **Step 1: Add the data graph as a retriever action, in Agent Builder**

Open `Cairn_Compass` in Agent Builder → `Order Lookup` topic → Actions → Add
Action → Data Cloud Retriever (or your org's equivalent label) → select the
`Cairn_Order_Lookup_Graph` data graph. Agent Builder generates an action with
inputs matching the lookup keys from Task 4 Step 5 and outputs matching the
projected fields from Task 4 Step 4.

- [ ] **Step 2: Record the generated action's exact shape**

Write down (you'll need these verbatim for Step 4): the action's
`developerName` (this becomes the `retriever://<name>` target), and its
input/output parameter names as Agent Builder generated them.

- [ ] **Step 3: Add the `AccountId` linked variable**

In `Cairn_Compass.agent`, in the `variables:` block, immediately after the
existing `FirstName` variable:

```
    AccountId: linked string
        source: @VoiceCall.Account__c
        description: "The Account Id matched from the caller's ANI in the inbound flow, if any. Empty when the ANI didn't match a single Person Account."
```

- [ ] **Step 4: Update `order_lookup`'s reasoning instructions**

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

- [ ] **Step 5: Retarget `order_lookup_action`**

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

- [ ] **Step 6: Deploy and preview**

Run: `sf project deploy start --target-org sally-prep --source-dir force-app/main/default/aiAuthoringBundles/Cairn_Compass`
Then AFDX: Preview This Agent, in **live** mode (Data Cloud dependency means
simulated mode can't meaningfully exercise this). Test two utterances:
1. As a known caller (preview tooling that lets you set the `VoiceCall`
   context's `Account__c`, or test via an actual routed call) — "what's the
   status of my order?" with no identifiers given. Expected: agent answers
   without asking for anything.
2. An order number spoken explicitly. Expected: still resolves correctly
   through the same action.

- [ ] **Step 7: Format and commit**

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
(`Individual`) and relationship chain (`Individual` → `Sales Order` →
`Sales Order Product` → `Product`) and the two lookup keys (Individual id,
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
