# Design: Cairn Ranger — Agentforce Voice Agent (scaffold + stage-1 build)

Date: 2026-08-21
Status: Approved for implementation planning

## Purpose

Replace the Agentforce DX starter scaffold ("Local Info Agent" — a resort weather/
events/hours assistant) with the real Cairn Outdoor Co. voice agent described in
`docs/REQUIREMENTS.md` §4 and `docs/SETUP_GUIDE.md` §5. This spec covers:

1. Removing the starter scaffold.
2. Standing up the new agent's identity, voice-conversation system instructions,
   subagent/router structure, and session variables.
3. Building the first working stage of each subagent that doesn't depend on
   Data Cloud (Data360), which is not yet provisioned in either org.

Out of scope for this spec (tracked as follow-up work once Data360 is set up):
Data Cloud ingestion/mapping, data graphs, vector search indexes, and the
`company_faq`/`product_qa` retriever actions that depend on them.

## 1. Cleanup — remove the starter scaffold

Delete entirely:

- `force-app/main/default/aiAuthoringBundles/Local_Info_Agent/` (both files)
- `force-app/main/default/classes/CheckWeather.cls(-meta.xml)`
- `force-app/main/default/classes/WeatherService.cls(-meta.xml)`
- `force-app/main/default/classes/WeatherServiceTest.cls(-meta.xml)`
- `force-app/main/default/classes/CurrentDate.cls(-meta.xml)`
- `force-app/main/default/classes/CurrentDateTest.cls(-meta.xml)`
- `force-app/main/default/flows/Get_Resort_Hours.flow-meta.xml`
- `force-app/main/default/genAiPromptTemplates/Get_Event_Info.genAiPromptTemplate-meta.xml`

Repurpose, not delete (both currently grant only the weather `apexClass`
entries and `RunFlow`):

- `permissionsets/Resort_Agent.permissionset-meta.xml` →
  `Cairn_Voice_Agent.permissionset-meta.xml`. Strip the `CheckWeather` /
  `CurrentDate` / `WeatherService` `classAccesses` entries (starts empty,
  populated as real Apex actions are built in §5). Update `<label>` to
  "Cairn Voice Agent" and `<description>` to reflect Cairn.
- `permissionsets/Resort_Admin.permissionset-meta.xml` →
  `Cairn_Admin.permissionset-meta.xml`. Same treatment (also drops the
  `*Test` class entries). Update `<label>`/`<description>`.
- `permissionsetgroups/AFDX_Agent_Perms.permissionsetgroup-meta.xml`: change
  `<permissionSets>Resort_Agent</permissionSets>` →
  `<permissionSets>Cairn_Voice_Agent</permissionSets>`.
- `permissionsetgroups/AFDX_User_Perms.permissionsetgroup-meta.xml`: change
  `<permissionSets>Resort_Admin</permissionSets>` →
  `<permissionSets>Cairn_Admin</permissionSets>`.

Untouched: `Cairn_Data_Load` permission set, custom fields on `Account`/`Order`,
both permission-set-group shells themselves (names stay as-is — they're already
generic, not resort-specific).

## 2. New agent identity

New `AiAuthoringBundle` at
`force-app/main/default/aiAuthoringBundles/Cairn_Ranger/`:

- `config.developer_name`: `Cairn_Ranger`
- `config.agent_label`: `Ranger`
- `config.description`: something like "Cairn Outdoor Co.'s Agentforce Voice
  agent — handles order status, company FAQs, product Q&A, and escalation to
  a human agent."
- `config.default_agent_user`: placeholder `UPDATE_WITH_YOUR_DEFAULT_AGENT_USER`
  (same pattern as the starter — resolved per-org at deploy time, not
  committed as a real user).
- `system.messages.welcome`: short, voice-native, e.g. *"Hey there, this is
  Ranger with Cairn Outdoor. What can I help you with?"* — no "How may I
  assist you today," no self-description of capabilities up front.
- `system.messages.error`: short recovery line, not a stack-trace-flavored
  apology — e.g. *"Sorry, I hit a snag there — could you say that again?"*
- `language`: `default_locale: "en_US"`, with Spanish handled at the
  subagent/routing level via `caller_preferred_language`, not as an
  `additional_locales` translation of the whole agent (matches the two-queue,
  language-attributed-to-caller model in REQUIREMENTS.md §3.2, not a
  fully localized UI).

### Voice-conversation system instructions

`system.instructions` establishes voice-channel behavior norms, grounded in
documented conversational-design practice (see note in the design discussion —
no single citable "5 human truths" source was found, so this is written as five
concrete, testable rules rather than attributed to a named framework):

1. **Turns are short.** One idea per turn. Never read back more than ~3
   sentences or a short list (2-3 items) without pausing for the caller.
2. **No monologuing.** If an answer has multiple parts (e.g., several order
   line items), summarize first, then offer to go deeper — don't recite
   everything unprompted.
3. **Interruptions are normal, not errors.** If the caller talks over a
   response or changes topic mid-sentence, drop the current thread cleanly and
   follow the new one — never scold or re-ask the interrupted question
   verbatim.
4. **Sound like a person on the phone, not a form.** Contractions, plain
   words, no "Please hold while I process your request"-style filler; brief
   natural acknowledgments ("Got it," "One sec") are fine, silence during a
   lookup is not.
5. **Confirm before acting, state results plainly after.** Read back
   identifying details before an action that changes data (e.g., case
   creation) in one short sentence; after a lookup, lead with the answer, not
   a description of what was searched.

Plus the standard anti-prompt-injection / no-system-disclosure rules already
present in the starter's `off_topic`/`ambiguous_question` subagents (carried
forward — see §3).

## 3. Router + subagent structure

```
start_agent agent_router
├── order_lookup
├── company_faq
├── product_qa
├── escalate_to_agent
├── create_case
├── off_topic          (guardrail, carried from starter pattern)
└── unclear_request     (guardrail, carried from starter pattern — renamed
                          from the starter's "ambiguous_question")
```

`agent_router` reasoning determines intent and transitions via
`@utils.transition to @subagent.<name>`, same mechanism as the starter.

`off_topic` and `unclear_request` keep the starter's existing instruction
bodies nearly verbatim (they're already generic guardrail logic, not
resort-specific) — just renamed and re-labeled for Cairn.

## 4. Session variables

| Variable | Type | Purpose |
|---|---|---|
| `caller_preferred_language` | mutable string ("English"/"Spanish") | Set early (from caller-provided info or `Account.Preferred_Language__c` once looked up); drives which Amazon Connect queue `escalate_to_agent` targets, and which language a Knowledge answer should come from once `company_faq` is grounded. |
| `human_agent_available` | mutable boolean | Set by the outcome of the escalation attempt; gates whether `create_case` is the next step. |
| `caller_issue_summary` | mutable string | Short summary of the caller's unresolved issue, captured for `create_case`'s `Description`. |

Order-lookup identifiers (order number, name/phone/email) are passed as action
inputs on `order_lookup`'s Flow action, not stored as persistent variables —
they're single-use per lookup, matching the starter's pattern for
`check_weather`'s `dateToCheck`.

## 5. Stage-1 build (no Data Cloud dependency)

Built and wired end-to-end in this pass:

- **`order_lookup`** — Flow action querying `Order`/`OrderItem` by
  customer-provided identifiers (order number, or name+phone/email), returning
  order number, `TotalAmount`, `Fulfillment_Status__c`, and
  `Estimated_Delivery_Date__c`. Matches SETUP_GUIDE §6.1 stage 1. Flow named
  `Cairn_Order_Lookup`.
- **`escalate_to_agent`** — `@utils.escalate`, with the target queue chosen by
  `caller_preferred_language` (`Cairn Support – English` /
  `Cairn Support – Spanish`). Exact Agent-Script syntax for queue-specific
  escalation needs confirming against current Agent Script docs during
  implementation (the starter's escalate call takes no queue param) — flagged
  as an implementation-time lookup, not a design blocker.
- **`create_case`** — Flow action (declarative, consistent with
  `order_lookup`'s stage-1 pattern; no staged Apex upgrade planned for this
  one since REQUIREMENTS.md doesn't call for it) creating a `Case` from
  `caller_issue_summary` (+ caller identity, `caller_preferred_language`),
  invoked when `human_agent_available` is false or escalation fails. Fires as
  the explicit fallback described in REQUIREMENTS.md §4.5. Flow named
  `Cairn_Create_Case`.

Drafted (topic reasoning/instructions + action shape) but **not** wired to a
live backing action, pending Data Cloud setup:

- **`company_faq`** — subagent instructions written now (answer scope: return
  policy, shipping, cancellation, warranty, price match, rewards, store
  hours, how to reach a human — per REQUIREMENTS.md §3.4); action left as a
  documented placeholder pointing at the future Prompt Template + Data Cloud
  retriever (SETUP_GUIDE §6.2 stage 1).
- **`product_qa`** — subagent instructions written now (scope: specs,
  compatibility, troubleshooting, how-tos, grounded in linked product PDFs);
  action left as a documented placeholder pointing at the future Apex
  vector-search retriever (SETUP_GUIDE §6.3 — single-stage, no Flow/Apex-SOQL
  interim, since there's no non-Data-Cloud way to ground this one).

## 6. Testing / validation

- Preview `Cairn_Ranger` in AFDX simulated mode (`AFDX: Preview This Agent`)
  after scaffolding, before wiring live data — confirm router correctly
  dispatches a sample utterance per subagent, including one off-topic and one
  ambiguous utterance.
- Once `order_lookup`'s Flow is deployed and sample data is loaded in
  `sally-prep`, preview in live mode against 2-3 real seeded orders (matches
  Rehearsal Checklist item in SETUP_GUIDE §8).
- `escalate_to_agent` and `create_case` are logic-testable in simulated/live
  preview without needing real Amazon Connect connectivity for this pass
  (queue transfer itself is validated later, per SETUP_GUIDE §8's "Escalation
  actually rings into the correct Amazon Connect queue" checklist item).

## 7. Follow-up (separate spec, once Data Cloud is provisioned)

- Data Cloud ingestion/Data Stream setup for `Account`/`Order`/`OrderItem`/
  `Product2`, manual Standard Data Model mapping, `order_lookup` stage-2 Apex
  SOQL action, then stage-3 data graph (SETUP_GUIDE §6.1).
- Vector search index setup over Knowledge articles and product manual
  `ContentVersion`s.
- `company_faq` stage 1 (Prompt Template + DC retriever) and stage 2 (custom
  Apex vector-search retriever), `product_qa`'s Apex vector-search retriever.

This will need user guidance/decisions at each Data Cloud step (data streams,
mappings, data graphs, search indexes) and is deliberately not planned in
detail here.
