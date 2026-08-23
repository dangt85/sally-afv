# Design: Order Lookup — Data Cloud Data Graph + ANI-Personalized Lookup

Date: 2026-08-23
Status: Approved for implementation planning

## Purpose

Replace the `order_lookup` topic's Flow-backed action
(`flow://Cairn_Order_Lookup`) with a Data Cloud data graph retriever action, per
`SETUP_GUIDE.md` §6.1 stage 3 / `REQUIREMENTS.md` §5.1 stage 3, and use it to
close the gap the caller-personalization screenshot illustrates: when the
inbound flow has already matched the caller's ANI to an Account, the agent
should surface that customer's order without asking them to repeat
identifying information it already has.

This spec covers:

1. A dedicated `Account__c` lookup field on `VoiceCall`, replacing the
   standard `RelatedRecordId` field the inbound flow currently sets.
2. Agent Script changes to `Cairn_Compass.agent`: a linked `AccountId`
   variable, updated `order_lookup` reasoning for the known-caller path, and
   retargeting `order_lookup_action` at the data graph retriever.
3. A guided walkthrough for building the Data Cloud data graph itself — the
   part of this build the user has not done before. (Data Stream ingestion and
   Standard Data Model mapping are assumed already done in `sally-prep`, per
   the user's confirmation, and are covered only as a quick recap/verification
   pass, not a from-scratch teach.)
4. Permission set and doc updates to keep `SETUP_GUIDE.md`/`REQUIREMENTS.md`
   in sync with reality, per this repo's working agreement.

Out of scope for this spec:

- Ingesting/mapping `Account`/`Order`/`OrderItem`/`Product2` into Data Cloud —
  already done.
- `company_faq` / `product_qa` retrievers (separate, unstructured/vector-search
  builds — `SETUP_GUIDE.md` §6.2–§6.3).
- Rebuilding `Cairn_Order_Lookup` (the Flow) — it's deleted once the data graph
  action is proven working, not kept as a fallback.

## 0. Starting state

- `VoiceCall.ContactName__c` (custom text field) and the standard
  `RelatedRecordId` field are set by `Cairn_Inbound` (Flow) on a single ANI
  match, via the `PersonAccountPhoneLookup` Apex invocable (SOSL phone search
  across Person Account phone fields).
- `Cairn_Compass.agent` already has a `FirstName` linked variable sourced from
  `VoiceCall.ContactName__c`, used in the welcome message — the personalized
  greeting already works.
- `order_lookup` currently always asks the caller for an order number, or
  full name plus phone/email, then calls `flow://Cairn_Order_Lookup`
  (`OrderNumberInput`/`CustomerNameInput`/`CustomerPhoneInput`/
  `CustomerEmailInput` → `OrderFound`/`OrderNumberOutput`/`TotalAmountOutput`/
  `FulfillmentStatusOutput`/`EstimatedDeliveryDateOutput`). The Flow's
  by-account branch (used for the name+contact path) already resolves to the
  single most recent order by `EffectiveDate desc` — that convention carries
  forward into the data graph design below.
- Data Cloud ingestion (Data Streams) and Standard Data Model mapping for
  `Account`→`Individual`, `Order`→`Sales Order`, `OrderItem`→`Sales Order
Product`, `Product2`→`Product` are already done in `sally-prep`.

## 1. Schema & Flow changes

New field: `force-app/main/default/objects/VoiceCall/fields/Account__c.field-meta.xml`
— a lookup to `Account`.

`Cairn_Inbound` flow (`UpdateVoiceCall` record-update element): replace the
`RelatedRecordId` input assignment with `Account__c` (both fed by
`varAccountId`). `ContactName__c` assignment is unchanged.

## 2. Agent Script changes (`Cairn_Compass.agent`)

New linked variable, alongside the existing `FirstName`/`VoiceCallId`:

```
AccountId: linked string
    source: @VoiceCall.Account__c
    description: "The Account Id matched from the caller's ANI in the inbound flow, if any. Empty when the ANI didn't match a single Person Account."
```

`order_lookup` reasoning instructions gain a known-caller branch: when
`@variables.AccountId` is set, skip asking for order number/name/phone/email
and call `look_up_order` immediately with just the account id — lead with the
most relevant order (most recent by effective date) the same way the answer
is currently led with after an explicit lookup. If the caller indicates the
surfaced order isn't the one they mean, fall back to asking for an order
number. When `AccountId` is empty, behavior is unchanged from today.

`order_lookup_action` changes:

- `target`: `flow://Cairn_Order_Lookup` → `retriever://<DataGraphRetrieverDeveloperName>`
  (name fixed once the retriever is built in §4).
- New input `AccountIdInput` wired to `@variables.AccountId`, added alongside
  the four existing inputs.
- Outputs unchanged: `OrderFound`, `OrderNumberOutput`, `TotalAmountOutput`,
  `FulfillmentStatusOutput`, `EstimatedDeliveryDateOutput`.

This preserves the topic's existing contract — same inputs (plus one),
same outputs — so only the action's backing implementation changes, matching
the stage-to-stage pattern already used for stage 1→2 in `SETUP_GUIDE.md`.

The exact shape Agent Builder generates for a data-graph retriever action
(parameter names, whether it needs a wrapping Agentforce Data Library like the
vector-search retrievers do) isn't nailed down in any reference available
right now — confirmed live in §5, then reflected back into the `.agent` file.

## 3. Data Cloud ingestion & mapping (recap, not a rebuild)

Since this part is already done, the walkthrough here is a short verification
pass before building the data graph on top of it — confirm in Data Cloud →
Data Model:

- `Individual` is mapped from the `Account` Data Stream (Person Accounts).
- `Sales Order` is mapped from the `Order` Data Stream.
- `Sales Order Product` (or your org's equivalent name) is mapped from the
  `OrderItem` Data Stream.
- `Product` is mapped from the `Product2` Data Stream.
- The relationships between these DMOs (Individual → Sales Order → Sales
  Order Product → Product) are wired in the Data Model canvas, not just the
  source-field mappings — a data graph can only traverse relationships that
  already exist in the Data Model.

## 4. Data Graph — the new part

Taught step-by-step during implementation, covering (at minimum):

1. What a data graph actually is in Data Cloud terms: a saved, denormalized
   JSON-shaped view assembled at query time from one or more related DMOs,
   rooted at a single "root" object — contrasted with a vector search index
   (unstructured/semantic) and a plain DMO query (single object, no nesting).
2. Root object choice: `Individual`, so a single query keyed by the caller's
   matched Account/Individual id can return that customer's orders nested
   underneath — this is what makes the "already knows who's calling" behavior
   possible in one call.
3. Building the relationship chain in the data graph definition: `Individual`
   → `Sales Order` (1:many) → `Sales Order Product` (1:many) → `Product`
   (many:1), including which fields to project at each level (order number,
   total, status, estimated delivery date; product name).
4. Defining lookup keys: by `Individual.Id` (the account-known path) and by
   `Sales Order.OrderNumber` (the explicit-order-number path, for callers the
   ANI match didn't cover) — both need to resolve through the same graph so
   one retriever action can serve both branches of `order_lookup`.
5. Publishing/activating the data graph and confirming it's queryable
   (Data Cloud query API / Data Explorer) before wiring it into the agent —
   sanity-check against 2–3 known seeded orders.

## 5. Wire-up in Agent Builder

- Add the published data graph as a retriever action on the `order_lookup`
  topic in Agent Builder (native Data Cloud retriever action — no additional
  Apex/Flow, per `SETUP_GUIDE.md` §6.1.3).
- Record the actual generated action name/inputs/outputs and reconcile them
  into `Cairn_Compass.agent` §2 above (the `.agent` file stays the source of
  truth for what's committed, even though this one action's schema originates
  in Data Cloud UI, not source).
- Delete `Cairn_Order_Lookup` (Flow) and its metadata once the data graph path
  is verified working, rather than keeping it as a dead fallback.

## 6. Permission set / doc updates

- `Cairn_Voice_Agent` permission set: drop the `Cairn_Order_Lookup` flow
  access (flow deleted in §5). Data Cloud retriever access for the agent's
  default agent user is managed in Data Cloud/Setup, not permission set
  metadata — flagged as a manual step, not something this spec adds to the
  permission set file.
- `SETUP_GUIDE.md` §6.1: mark stage 3 done; add the ANI-personalization
  behavior (known-caller path skips identifier collection) as part of the
  stage-3 description, since it's new behavior beyond what's currently
  documented there.
- `REQUIREMENTS.md` §5.1: same — note that the data graph also serves the
  ANI-matched known-caller path, not just explicit order-number/name+contact
  lookups.
- `SETUP_GUIDE.md` §10 (Known Gotchas): add an entry noting `VoiceCall.Account__c`
  replaces `RelatedRecordId` as the source of truth for the ANI-matched
  account, so anyone relying on `RelatedRecordId` elsewhere doesn't get
  surprised.

## 7. Testing / validation

- Preview `Cairn_Compass` in AFDX live mode (Data Cloud dependency means
  simulated mode can't meaningfully exercise this) against `sally-prep`:
  - A call from a seeded customer's phone number → welcome uses their first
    name, and asking about "my order" resolves without giving any
    identifiers.
  - A call from an unrecognized number → identical behavior to today (ask for
    order number or name+phone/email).
  - An explicit order number, spoken mid-call, overrides the proactively
    surfaced order.
- Confirm the data graph directly (Data Explorer or query API) returns
  correct nested order/line-item/product data for 2–3 seeded accounts before
  trusting the agent-level test above to isolate failures.

## 8. Follow-up (not detailed here)

- `company_faq`/`product_qa` retrievers — separate vector-search builds, no
  data graph involved.
- Whether `order_lookup` should eventually let a known caller ask about a
  _different_ one of their orders by relative description ("the one before
  that") rather than only by explicit order number — deferred, not designed
  here.
