Continue the Data Cloud order-lookup work on branch `feature/data360-enhancement` in
this repo. Read `docs/superpowers/plans/2026-08-23-order-lookup-datagraph.md` — Tasks
1–4 are done and committed (Task 4's "What actually happened" section has the real
data graph name, field/DMO mechanics, and one open risk you need to resolve first).

I'm ready to start Task 5: Wire the data graph into `order_lookup`. Walk me through it
step-by-step, live, in `sally-prep`'s Agent Builder UI — I'll perform the UI actions and
report back screenshots/results, you verify each step against the org (via
`sf data query --target-org sally-prep` for data checks, and by reading
`Cairn_Compass.agent` before/after edits) before we move to the next one. Don't assume a
step worked — confirm it, the same way we verified Tasks 3 and 4.

**Before anything else**, resolve Task 4's open risk: when you add the Data Cloud
Retriever action in Agent Builder pointing at the `Compass_Order_Lookup` data graph,
check whether `OrderNumber` (`ssot__OrderNumber__c`, nested under `Sales Order`) shows up
as a usable input parameter. Task 4 could only prove the graph is queryable by `Account
Id` (the root's primary key) via Data Cloud's Data Explorer — that tool had no way to
filter by `OrderNumber`, so it's unconfirmed whether the retriever/agent action can
actually look up by order number, which the whole "explicit order-number path" in the
design depends on. If Agent Builder's generated action doesn't expose `OrderNumber` as an
input, stop and flag it — don't silently drop that path or force a workaround; Task 4's
note suggests remapping `OrderNumber` as a Key Qualifier field in Data Model Mapping
(Task 3 territory) as the likely fix if this happens, but confirm the failure mode first.

Once that's settled, continue through Task 5's remaining steps (linked variable, retarget
`order_lookup_action`, deploy, live preview of both the known-caller and explicit-order-
number utterances). Mark Task 5 done in the plan doc (same style as Tasks 3–4 — check off
steps, add a "what actually happened" note for anything that deviated) and stop there —
Task 6 (removing the old Flow) is separate follow-up work.
