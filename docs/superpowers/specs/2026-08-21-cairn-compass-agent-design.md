# Design: Compass — Agentforce Voice Agent (scaffold + stage-1 build)

Date: 2026-08-21
Status: Approved for implementation planning

Supersedes the earlier "Cairn Ranger" design (deleted from the working tree
during cleanup). That design assumed Amazon Connect + English/Spanish queues;
this one reflects the pivot to Agentforce Contact Center (AFCC) only, with
queues split by function instead of language.

## Purpose

Replace the Agentforce DX starter scaffold ("Local Info Agent") with the real
Cairn Outdoor Co. voice agent described in `docs/REQUIREMENTS.md` §4 and
`docs/SETUP_GUIDE.md` §5. This spec covers:

1. The new agent's identity, voice-conversation system instructions,
   subagent/router structure, and session variables.
2. Building the first working stage of each subagent that doesn't depend on
   Data Cloud (Data360), which is not yet provisioned in either org.
3. Updating `REQUIREMENTS.md`/`SETUP_GUIDE.md` to reflect the AFCC-only pivot
   and the new queue names.

Out of scope for this spec (tracked as follow-up work):

- AFCC infrastructure setup (Queues, Omni-Channel voice service channel,
  Contact Center configuration) — not yet started in either org.
- Data Cloud ingestion/mapping, data graphs, vector search indexes, and the
  `company_faq`/`product_qa` retriever actions that depend on them.

## 0. Starting state

Cleanup of the starter scaffold is already done (performed by the user before
this spec was written): `aiAuthoringBundles/Local_Info_Agent/`,
`CheckWeather`/`CurrentDate`/`WeatherService` Apex classes and tests,
`Get_Resort_Hours.flow-meta.xml`, `Get_Event_Info.genAiPromptTemplate-meta.xml`,
`Resort_Admin`/`Resort_Agent` permission sets, and both permission set groups
are all removed from `force-app`. What remains: `Cairn_Data_Load` permission
set, and the custom fields `Account.Preferred_Language__c`,
`Order.Fulfillment_Status__c`, `Order.Estimated_Delivery_Date__c`.

## 1. New agent identity

New `AiAuthoringBundle` at
`force-app/main/default/aiAuthoringBundles/Cairn_Compass/`:

- `config.developer_name`: `Cairn_Compass`
- `config.agent_label`: `Compass`
- `config.description`: "Cairn Outdoor Co.'s Agentforce Voice agent — handles
  order status, company FAQs, product Q&A, and escalation to a human agent."
- `config.default_agent_user`: placeholder `UPDATE_WITH_YOUR_DEFAULT_AGENT_USER`
  (resolved per-org at deploy time, not committed as a real user).
- `system.messages.welcome`: short, voice-native, e.g. _"Hey, this is Compass
  with Cairn Outdoor — what can I help you with?"_ — no "How may I assist you
  today," no self-description of capabilities up front.
- `system.messages.error`: short recovery line, e.g. _"Sorry, I hit a snag
  there — could you say that again?"_
- `language`: `default_locale: "en_US"` only. No language-based branching —
  `Account.Preferred_Language__c` stays in the schema but is not read by the
  agent or by escalation routing (English-only for this build, per decision;
  bilingual support is explicitly deferred, not designed out).

### Voice-conversation system instructions

`system.instructions` establishes voice-channel behavior as concrete,
testable rules:

1. **Turns are short.** One idea per turn. Never read back more than ~3
   sentences or a short list (2–3 items) without pausing for the caller.
2. **No monologuing.** If an answer has multiple parts (e.g., several order
   line items), summarize first, then offer to go deeper — don't recite
   everything unprompted.
3. **Interruptions are normal, not errors.** If the caller talks over a
   response or changes topic mid-sentence, drop the current thread cleanly and
   follow the new one — never scold or re-ask the interrupted question
   verbatim.
4. **Context continuity.** Never re-ask for information already given earlier
   in the same call (order number, name, issue description, etc.).
5. **Gricean cooperative-conversation maxims:**
   - _Quantity_ — say enough to answer, not more.
   - _Quality_ — don't state unverified things as fact; ground lookups in
     real data, don't guess at order/product details.
   - _Relation_ — stay relevant to what was actually asked.
   - _Manner_ — be brief, unambiguous, and orderly; avoid obscure phrasing.
6. **Sound like a person on the phone, not a form.** Contractions, plain
   words, no "Please hold while I process your request"-style filler; brief
   natural acknowledgments ("Got it," "One sec") are fine, silence during a
   lookup is not.
7. **Personality: warm & casual.** Light outdoorsy warmth ("happy to track
   that down for you") without being chatty or slowing the call down.
8. **Confirm before acting, state results plainly after.** Read back
   identifying details before an action that changes data (e.g., case
   creation) in one short sentence; after a lookup, lead with the answer, not
   a description of what was searched.

Plus the standard anti-prompt-injection / no-system-disclosure guardrail
instructions, carried into the `off_topic`/`unclear_request` subagents (§3).

## 2. Router + subagent structure

```
start_agent agent_router
├── order_lookup
├── company_faq
├── product_qa
├── escalate_to_agent
├── create_case
├── off_topic          (guardrail)
└── unclear_request     (guardrail)
```

`agent_router` reasons over caller intent and transitions via
`@utils.transition to @subagent.<name>`.

## 3. Queue routing (AFCC, intent-based)

Queues are **Orders & Returns** and **Customer Support** (function-based, not
language-based). New session variable:

- `queue_target` — mutable string enum (`Orders_Returns` / `Customer_Support`),
  default `Customer_Support`.

`order_lookup` sets `queue_target = Orders_Returns` before any hand-off to
escalation (covers order status, returns, cancellations). `company_faq` and
`product_qa` leave it at the default `Customer_Support`. `escalate_to_agent`
reads `queue_target` to pick the AFCC queue to transfer into — no caller-facing
menu, no re-classification at escalation time.

## 4. Session variables

| Variable                | Type                | Purpose                                                                                     |
| ----------------------- | ------------------- | ------------------------------------------------------------------------------------------- |
| `queue_target`          | mutable string enum | Drives which AFCC queue `escalate_to_agent` transfers into (§3).                            |
| `human_agent_available` | mutable boolean     | Set by the outcome of the escalation attempt; gates whether `create_case` runs next.        |
| `caller_issue_summary`  | mutable string      | Short summary of the caller's unresolved issue, captured for `create_case`'s `Description`. |

Order-lookup identifiers (order number, name/phone/email) are passed as action
inputs on `order_lookup`'s Flow action, not stored as persistent variables —
single-use per lookup.

## 5. Stage-1 build (no Data Cloud dependency)

Built and wired end-to-end in this pass:

- **`order_lookup`** — Flow action (`Cairn_Order_Lookup`) querying
  `Order`/`OrderItem` by customer-provided identifiers (order number, or
  name+phone/email), returning order number, `TotalAmount`,
  `Fulfillment_Status__c`, and `Estimated_Delivery_Date__c`. Matches
  `SETUP_GUIDE.md` §6.1 stage 1.
- **`escalate_to_agent`** — queue transfer keyed on `queue_target` (§3), into
  the AFCC `Orders & Returns` / `Customer Support` queue.
- **`create_case`** — Flow action (`Cairn_Create_Case`) creating a `Case` from
  `caller_issue_summary` (+ caller identity), invoked when
  `human_agent_available` is false or escalation fails.

Drafted (topic reasoning/instructions + action shape) but **not** wired to a
live backing action, pending Data Cloud setup:

- **`company_faq`** — subagent instructions written now (answer scope: return
  policy, shipping, cancellation, warranty, price match, rewards, store hours,
  how to reach a human — per `REQUIREMENTS.md` §3.4); action left as a
  documented placeholder pointing at the future Prompt Template + Data Cloud
  retriever (`SETUP_GUIDE.md` §6.2 stage 1).
- **`product_qa`** — subagent instructions written now (scope: specs,
  compatibility, troubleshooting, how-tos, grounded in linked product PDFs);
  action left as a documented placeholder pointing at the future Apex
  vector-search retriever (`SETUP_GUIDE.md` §6.3 — single-stage, no interim).

A new `Cairn_Voice_Agent` permission set grants the agent's runtime user
access to the Flow(s)/Apex built in this pass — starts covering
`Cairn_Order_Lookup` and `Cairn_Create_Case`, grows as later stages add Apex
actions.

## 6. Docs to update

- **`REQUIREMENTS.md`** §2.3 (current-state narrative: Cairn's contact center
  runs on AFCC, human-only, queues split by function — not Amazon Connect,
  not language), §6 (telephony approach: AFCC only, drop the Amazon Connect
  primary/alternate framing), §7/§8 (out-of-scope and success criteria
  references to Amazon Connect → AFCC).
- **`SETUP_GUIDE.md`** §1 (prerequisites: AFCC provisioned instead of Amazon
  Connect + Salesforce Voice; drop the two named Connect queues, note the two
  AFCC queues as a to-do), §5 (`escalate_to_agent` targets AFCC queues by
  function, not Amazon Connect queues by language), §7 (rewrite as AFCC setup
  steps; drop the primary/alternate split since AFCC is now the only path).

## 7. Testing / validation

- Preview `Cairn_Compass` in AFDX simulated mode (`AFDX: Preview This Agent`)
  before wiring live data — confirm the router dispatches correctly per
  subagent, including one off-topic and one unclear-request utterance.
- Once `Cairn_Order_Lookup` is deployed and sample data is loaded in
  `sally-prep`, preview in live mode against 2–3 real seeded orders (matches
  `SETUP_GUIDE.md` §8's rehearsal checklist).
- `escalate_to_agent` and `create_case` are logic-testable in simulated/live
  preview without needing real AFCC connectivity for this pass — actual queue
  transfer is validated later, once AFCC infra exists (§ Follow-up).

## 8. Follow-up (separate work, not detailed here)

- **AFCC infrastructure**: two Queue records (`Orders_Returns`,
  `Customer_Support`), Omni-Channel voice service channel, Contact Center
  configuration — needs step-by-step guidance once started.
- **Data Cloud (Data360)**: ingestion/Data Stream setup for
  `Account`/`Order`/`OrderItem`/`Product2`, manual Standard Data Model
  mapping, `order_lookup` stage-2 Apex SOQL action, then stage-3 data graph
  (`SETUP_GUIDE.md` §6.1); vector search index setup over Knowledge articles
  and product manual `ContentVersion`s; `company_faq` stage 1/2 and
  `product_qa`'s Apex vector-search retriever. Needs user guidance/decisions
  at each step — deliberately not planned in detail here.
