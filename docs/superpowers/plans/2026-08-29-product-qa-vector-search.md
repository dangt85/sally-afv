# Product Q&A — Data Cloud Vector Search Retriever Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Human note:** Tasks 1 and 2 involve live actions in the Data Cloud Setup
> UI that no agent can perform — they are written as guided checklists to
> work through interactively (narrated step-by-step), not autonomous
> subagent work. Task 3 has one UI-dependent discovery step (Step 1) feeding
> into otherwise-ordinary Apex file work. Tasks 4 and 6 are ordinary file
> edits. Task 5 is a manual, live-preview verification pass. See "Execution
> note" at the end of this plan.

**Goal:** Replace `product_qa`'s "reason from general knowledge" placeholder
with a custom Apex vector-search retriever grounded in the actual PDF
manuals/guides already linked to each `Product2` record.

**Architecture:** The product manual `ContentVersion` files ingest into Data
Cloud via the Salesforce CRM file-attachment path, get indexed by a hybrid
(keyword + vector) search index, and are queried from a new Apex invocable
action (`ProductQnAVectorSearch`) using the async
`querySql`/`querySqlStatus`/`querySqlRows`/`cancelQuerySql` API — chosen over
`queryAnsiSqlV2` specifically for its timeout/cancel handling, so a slow
query can't leave a live voice call hanging. `product_qa`'s reasoning
instructions change from "answer from general knowledge" to "ground every
answer in the retriever's output, or say so and hand off" — the same
anti-fabrication discipline `order_lookup` already uses.

**Tech Stack:** Salesforce DX (`sf` CLI), Agent Script (`AiAuthoringBundle`),
Apex, Data Cloud/Data 360 (file-attachment ingestion, hybrid search index,
`ConnectApi.CdpQuery` async query API).

**Spec:** `docs/superpowers/specs/2026-08-29-product-qa-vector-search-design.md`

## Global Constraints

- Always pass `--target-org sally-prep` explicitly — never rely on a default
  org (project convention, `CLAUDE.md`).
- Format changed files with `npm run prettier` before considering a task
  done.
- All sample data referenced during testing is fictitious Cairn Outdoor Co.
  data already loaded in `sally-prep` (`REQUIREMENTS.md` §3.1) — never
  substitute real data.
- **No Apex test class for `ProductQnAVectorSearch`**, matching the existing
  `OrderLookupDataGraph` precedent (also has none): `ConnectApi` static
  methods can't be mocked with `Test.setMock`, so there's no meaningful way
  to unit-test the callout logic in isolation. Verification is via live
  anonymous Apex (Task 3, Step 5) and AFDX preview (Task 5) instead —
  consistent with how `OrderLookupDataGraph` was verified.
- Data Cloud config (Data Streams, DMOs, search index) lives in Data Cloud,
  not `force-app` — no metadata for it is checked in, matching how order
  lookup's data graph was built (only the Apex class and `.agent` file are
  source-controlled).
- Starting-point tuning numbers — poll budget `waitTimeMs=2000` × 3
  iterations (~6s), top-K `LIMIT 3` — are deliberately not final; adjust
  once real latency/quality is visible in `sally-prep` (spec §7), don't
  treat them as hard requirements.
- This is a from-zero build (spec §0): no Data Cloud ingestion, mapping, or
  search index exists yet for this content.

---

## Task 1: Ingest product manual `ContentVersion`s into Data Cloud

Guided, hands-on — done together, live, in `sally-prep`'s Data Cloud Setup.

- [ ] **Step 1: Confirm the starting state**

Run: `sf data query --target-org sally-prep --query "SELECT COUNT() FROM ContentVersion WHERE FirstPublishLocationId IN (SELECT Id FROM Product2 WHERE ProductCode != null)"`
Expected: 13 (the manuals/guides listed in `REQUIREMENTS.md` §3.1). Note this
number — it's what Step 4 below checks the ingested count against.

- [ ] **Step 2: Deploy the Content Bundle**

Data Cloud Setup → search "Ingest File Attachments from Salesforce CRM
Objects" (or the equivalent path Data Cloud's Setup search surfaces in this
org's release — the exact menu label can vary by release, same caveat
`SETUP_GUIDE.md` §10 already notes for Data Model object names). This
deploys a standard Content Bundle: Data Lake Objects, Data Model Objects,
and Data Streams for `ContentDocument`, `ContentVersion`, and
`ContentDocumentLink`. Follow the guided setup, selecting the org's default
connection (no S3/Azure/GCS involved — this ingests directly from Salesforce
CRM).

- [ ] **Step 3: Activate the resulting Data Streams**

Data Cloud → Data Streams. Activate each of the three streams the Content
Bundle created (`ContentDocument`, `ContentVersion`, `ContentDocumentLink`).
Give it a few minutes per stream, same as any other Data Stream activation
(`SETUP_GUIDE.md` §10's ingestion-isn't-instant gotcha applies here too).

- [ ] **Step 4: Verify the backfill risk from spec §1**

This is the step that resolves the open risk in the spec: Salesforce's
documentation notes the `ContentVersion` stream "ingests only file versions
created or updated after you create the data stream," and every manual PDF
here was already loaded before this task started.

In Data Cloud → Data Explorer, query the ingested `ContentVersion` DLO and
count rows. Compare against the 13 from Step 1.

- If the count matches: the initial full ingestion did backfill existing
  versions. Record this in the "What actually happened" section below and
  move to Task 2.
- If the count is 0 (or otherwise short): the backfill did not happen.
  Trigger a manual full refresh on the `ContentVersion` Data Stream if Data
  Cloud offers one; if not, re-save each of the 13 `ContentVersion` records
  to force a new version Data Cloud's incremental stream will pick up (e.g.
  `sf data update record --target-org sally-prep --sobject ContentVersion
--record-id <id> --values "Title=<same title>"` for each — a no-op content
  change is enough to trigger re-ingestion; don't actually alter the PDF
  content). Re-check the count after a few minutes.

- [ ] **Step 5: Confirm `ContentDocumentLink` still ties files to their `Product2` parent**

In Data Explorer, spot-check 2–3 ingested `ContentDocumentLink` rows against
`sf data query --target-org sally-prep --query "SELECT ContentDocumentId, LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId IN (SELECT Id FROM Product2 WHERE ProductCode != null) LIMIT 3"`
— confirm the ingested rows match. Not required by this build's retrieval
query (spec: no per-product filtering yet), but worth confirming now since a
future filter would depend on it, and it's a cheap check while already here.

No commit for this task — Data Cloud config lives in Data Cloud, not
`force-app` (Global Constraints).

### What actually happened

_(Fill in after execution: real Data Stream/DLO names, whether the backfill
risk from Step 4 materialized and what fixed it if so, final ingested row
count.)_

---

## Task 2: Build the hybrid search index

Guided, hands-on — done together, live, in `sally-prep`'s Data Cloud Setup.

- [ ] **Step 1: Create the search index**

Data Cloud → Search Index → New → Easy Setup. Select the ingested
`ContentVersion` DMO (from Task 1) as the source. Choose **hybrid** search
(keyword + vector), not pure vector — troubleshooting queries hinge on exact
terms ("won't ignite," "leaking seams") that pure semantic search can
under-rank (spec §2).

- [ ] **Step 2: Name and configure**

Name it `Compass_Product_QA_Index`, consistent with the order-lookup data
graph's `Compass_Order_Lookup` naming. Accept the default chunking/embedding
configuration — no hand-tuning until real retrieval quality against the
actual manuals says otherwise.

- [ ] **Step 3: Publish/activate**

Save and activate/publish the index. Note the exact index DMO API name and
the auto-created chunk DMO's API name Data Cloud generates — Task 3 needs
both verbatim.

- [ ] **Step 4: Sanity-check retrieval directly in Data Cloud, before any Apex**

Using Data Cloud's Search Index test/preview tool (or a raw SQL query via
Data Explorer's query tool, if the UI exposes one), run 2–3 searches
matching known manual content — e.g. a query like "won't ignite" should
surface a `BlazeLight Camp Stove` chunk; "leaking seams" should surface
`Alpine Peak 2 Tent`. Confirm relevant results come back before wiring up
Apex — same "verify the layer under you before building on it" discipline
used for the order-lookup data graph.

No commit for this task — Data Cloud config lives in Data Cloud, not
`force-app`.

### What actually happened

_(Fill in after execution: real index DMO name, chunk DMO name, and results
of the Step 4 sanity checks.)_

---

## Task 3: Apex retriever (`ProductQnAVectorSearch.cls`)

**Files:**

- Create: `force-app/main/default/classes/ProductQnAVectorSearch.cls`
- Create: `force-app/main/default/classes/ProductQnAVectorSearch.cls-meta.xml`

**Interfaces:**

- Consumes: `Compass_Product_QA_Index` and its chunk DMO (Task 2) — exact API
  names needed for the SQL in Step 3.
- Produces: `@InvocableMethod searchProductContent(List<Request>)` — a
  `Request` with `SearchQueryInput: String`, a `Result` with
  `ContentFound: Boolean` and `RetrievedContextOutput: String` — consumed by
  Task 4's `product_qa_action`.

- [ ] **Step 1: Discover the real `ConnectApi.QuerySqlInput`/`QuerySqlOutput` shapes**

The exact field names on `ConnectApi.QuerySqlInput`, `QuerySqlOutput`, and
what `querySqlStatus`/`querySqlRows` return aren't confirmed from
documentation alone (Salesforce's reference material covers the REST shape,
not a concrete Apex parsing example) — same discipline
`OrderLookupDataGraph.parseRow` used for the data graph's row-shape problem:
confirm empirically before writing the real class, don't guess.

Write a throwaway introspection script (don't commit it — scratchpad only)
and run it:

```apex
ConnectApi.QuerySqlInput input = new ConnectApi.QuerySqlInput();
System.debug('QuerySqlInput fields: ' + JSON.serialize(input));

ConnectApi.QuerySqlOutput submitResult = ConnectApi.CdpQuery.querySql(input);
System.debug('QuerySqlOutput shape: ' + JSON.serialize(submitResult));
```

Run: `sf apex run --target-org sally-prep --file <scratchpad-path>/introspect-query-sql.apex`
(An empty/invalid `sql` value is fine for this step — the goal is seeing the
field names in the serialized output and whatever error shape a bad query
produces, not a successful query.) Then repeat with a real `sql` value
against `Compass_Product_QA_Index` (from Task 2) to see `querySqlStatus`'s
and `querySqlRows`' real output shape once a query actually completes.
Record the confirmed field/method names for Step 3 below.

- [ ] **Step 2: Write the Request/Result classes and method skeleton**

```apex
/**
 * `product_qa`'s action: searches the Data Cloud hybrid search index built
 * over product manual content. See SETUP_GUIDE.md §6.3 — queried via the
 * async querySql API (not queryAnsiSqlV2) so a slow/stuck query can be
 * bounded and cancelled rather than leaving a live call hanging.
 */
public with sharing class ProductQnAVectorSearch {
  private static final String INDEX_TABLE = 'Compass_Product_QA_Index__dlm'; // confirm exact name from Task 2
  private static final Integer TOP_K = 3;
  private static final Integer POLL_WAIT_MS = 2000;
  private static final Integer MAX_POLLS = 3;

  public class Request {
    @InvocableVariable(label='Search Query' required=true)
    public String SearchQueryInput;
  }

  public class Result {
    @InvocableVariable(label='Content Found')
    public Boolean ContentFound;
    @InvocableVariable(label='Retrieved Context')
    public String RetrievedContextOutput;
  }

  @InvocableMethod(
    label='Search Product Manuals In Data Cloud'
    description='Searches the product manual/guide content in Data Cloud for excerpts relevant to the caller\'s product question.'
    category='Cairn Outdoor Co.'
  )
  public static List<Result> searchProductContent(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request req : requests) {
      results.add(searchOne(req));
    }
    return results;
  }
}
```

- [ ] **Step 3: Implement the query flow, using Step 1's confirmed shapes**

Fill in `searchOne` and its helpers, using the real field/method names Step
1 confirmed (the sketch below uses the names most likely to be correct based
on the Apex Reference method list, but **do not deploy this verbatim** —
substitute whatever Step 1 actually found):

```apex
  private static Result searchOne(Request req) {
    Result result = new Result();
    result.ContentFound = false;

    String searchQuery = req.SearchQueryInput;
    if (String.isBlank(searchQuery)) {
      return result;
    }

    String sql =
      'SELECT c.Chunk__c, h.hybrid_score__c ' +
      'FROM hybrid_search(table(' + INDEX_TABLE + '), \'' +
      String.escapeSingleQuotes(searchQuery) + '\', \'\', ' + TOP_K + ', ' +
      '\'{ "min_should_match": "-100%"}\') AS h ' +
      'ORDER BY h.hybrid_score__c DESC LIMIT ' + TOP_K;
      // JOIN clause to the chunk DMO added once Task 2's chunk DMO name is
      // confirmed — see spec §3 step 1 and this task's Step 1.

    ConnectApi.QuerySqlInput input = new ConnectApi.QuerySqlInput();
    input.sql = sql; // confirm field name in Step 1

    String queryId;
    try {
      ConnectApi.QuerySqlOutput submitResult = ConnectApi.CdpQuery.querySql(
        input
      );
      queryId = submitResult.queryId; // confirm field name in Step 1
    } catch (Exception e) {
      System.debug(LoggingLevel.ERROR, 'querySql submit failed: ' + e.getMessage());
      return result;
    }

    Boolean done = false;
    for (Integer i = 0; i < MAX_POLLS && !done; i++) {
      try {
        // confirm querySqlStatus's real signature/return shape in Step 1
        Object statusResult = ConnectApi.CdpQuery.querySqlStatus(
          queryId,
          (Long) POLL_WAIT_MS
        );
        done = isDone(statusResult); // implement once the status shape is known
      } catch (Exception e) {
        System.debug(LoggingLevel.ERROR, 'querySqlStatus failed: ' + e.getMessage());
        break;
      }
    }

    if (!done) {
      try {
        ConnectApi.CdpQuery.cancelQuerySql(queryId);
      } catch (Exception e) {
        System.debug(LoggingLevel.ERROR, 'cancelQuerySql failed: ' + e.getMessage());
      }
      return result;
    }

    try {
      // confirm querySqlRows' real return shape in Step 1
      Object rowsResult = ConnectApi.CdpQuery.querySqlRows(queryId, 0, TOP_K);
      List<String> excerpts = parseExcerpts(rowsResult); // implement once row shape is known
      if (!excerpts.isEmpty()) {
        result.ContentFound = true;
        result.RetrievedContextOutput = String.join(excerpts, '\n---\n');
      }
    } catch (Exception e) {
      System.debug(LoggingLevel.ERROR, 'querySqlRows failed: ' + e.getMessage());
    }

    return result;
  }
```

`isDone` and `parseExcerpts` are written from Step 1's real findings, not
guessed — document whatever the real shape turns out to be in a comment on
each method, the way `OrderLookupDataGraph.parseRow` documents its own
discovery. Add the `JOIN <chunk DMO>` clause to the SQL once Task 2's chunk
DMO name is confirmed, so the excerpt text (not just the score) is
selectable.

- [ ] **Step 4: Deploy**

Run: `sf project deploy start --target-org sally-prep --source-dir force-app/main/default/classes/ProductQnAVectorSearch.cls`
Expected: `Deployed Source ... ProductQnAVectorSearch ... Created`, no
errors.

- [ ] **Step 5: Verify directly via anonymous Apex, before touching the agent**

```apex
ProductQnAVectorSearch.Request req = new ProductQnAVectorSearch.Request();
req.SearchQueryInput = 'how do I clean my water filter';
List<ProductQnAVectorSearch.Result> results = ProductQnAVectorSearch.searchProductContent(
  new List<ProductQnAVectorSearch.Request>{ req }
);
System.debug('ContentFound: ' + results[0].ContentFound);
System.debug('RetrievedContextOutput: ' + results[0].RetrievedContextOutput);
```

Run: `sf apex run --target-org sally-prep --file <scratchpad-path>/verify-product-qa-search.apex`
Expected: `ContentFound = true`, and `RetrievedContextOutput` contains text
recognizable as coming from the `StreamPure Water Filter`'s cleaning/backwashing
how-to (`REQUIREMENTS.md` §3.1). Repeat for at least one more product/question
pair (e.g. "my headlamp won't charge" → `TrailBeam 500 Headlamp`).

- [ ] **Step 6: Format and commit**

```bash
git add force-app/main/default/classes/ProductQnAVectorSearch.cls force-app/main/default/classes/ProductQnAVectorSearch.cls-meta.xml
git commit -m "$(cat <<'EOF'
Add ProductQnAVectorSearch Apex retriever for product manual content

Queries the Compass_Product_QA_Index hybrid search index via the async
querySql/querySqlStatus/querySqlRows/cancelQuerySql API, with a bounded
poll budget so a slow query can't leave a live call hanging.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

### What actually happened

_(Fill in after execution: real `QuerySqlInput`/`QuerySqlOutput` field
names, the `querySqlStatus`/`querySqlRows` return shapes, the final SQL
including the chunk-DMO join, and the Step 5 verification transcript.)_

---

## Task 4: Wire `ProductQnAVectorSearch` into `product_qa`

**Files:**

- Modify: `force-app/main/default/aiAuthoringBundles/Cairn_Compass/Cairn_Compass.agent:246-270`

**Interfaces:**

- Consumes: `ProductQnAVectorSearch.searchProductContent` (Task 3) —
  `SearchQueryInput` → `ContentFound`/`RetrievedContextOutput`.

- [ ] **Step 1: Remove the placeholder comment**

Delete the `# PLACEHOLDER: no live grounding action yet...` comment block
(lines 249–252 as of this plan's writing).

- [ ] **Step 2: Replace the reasoning instructions**

Replace `product_qa`'s `reasoning.instructions` block:

```
    reasoning:
        instructions: |
            Answer the caller's product question by first calling
            search_product_content with their question, as close to
            verbatim as reasonable.
            Say something short while it runs, since it isn't instant.
            If it finds relevant content, ground your answer only in what
            it returned — cite the specific spec or troubleshooting step
            rather than a generic response. Give the headline answer first,
            then offer more detail only if asked.
            If it finds nothing relevant, don't fall back to general
            knowledge or guess — say you don't have that specific
            information and hand the caller off to a specialist instead.
            Never state a product detail you haven't actually gotten from
            search_product_content.
```

- [ ] **Step 3: Add the action**

Replace the `actions:` block (currently only `hand_off_to_specialist`):

```
        actions:
            search_product_content: @actions.product_qa_action
                description: "Search the product manuals/guides for content relevant to the caller's question. Returns whether anything relevant was found and, if so, the retrieved excerpts to ground the answer in."
                with SearchQueryInput = ...
            hand_off_to_specialist: @utils.transition to @subagent.escalate_to_agent
                description: "Connect the caller with a specialist when you can't resolve their product question."
```

Then add the action definition itself, in a new `actions:` block at the
`product_qa` subagent level (same structure as `order_lookup`'s
`order_lookup_action`):

```
    actions:
        product_qa_action:
            description: "Search the product manuals/guides for content relevant to the caller's question. Returns whether anything relevant was found and, if so, the retrieved excerpts to ground the answer in."
            target: "apex://ProductQnAVectorSearch"
            inputs:
                SearchQueryInput: string
                    description: "The caller's product question, as close to verbatim as reasonable."
            outputs:
                ContentFound: boolean
                    description: "Whether any relevant content was found."
                    is_displayable: True
                RetrievedContextOutput: string
                    description: "Retrieved excerpts from product manuals/guides relevant to the question."
                    is_displayable: True
```

- [ ] **Step 4: Deploy**

Run: `sf project deploy start --target-org sally-prep --source-dir force-app/main/default/aiAuthoringBundles/Cairn_Compass`
Expected: `Deployed Source ... Cairn_Compass ... Changed`, no errors.

- [ ] **Step 5: Preview, live mode**

`sf agent preview --target-org sally-prep --authoring-bundle Cairn_Compass --use-live-actions --output-dir ./transcripts`
(headless via the `script -qc "…" /dev/null < fifo` pattern from
`SETUP_GUIDE.md` §5, if driving it non-interactively). Ask: "how do I clean
my water filter?" Expected: the trace shows `search_product_content` fired,
and the spoken answer cites the `StreamPure Water Filter`'s actual
cleaning/backwashing content — not a generic answer. Read the trace, not just
the transcript, to confirm the action actually fired (same discipline
`SETUP_GUIDE.md` §5 calls out for order lookup).

- [ ] **Step 6: Format and commit**

```bash
npm run prettier
git add force-app/main/default/aiAuthoringBundles/Cairn_Compass/Cairn_Compass.agent
git commit -m "$(cat <<'EOF'
Wire product_qa to the Data Cloud vector search retriever

Replaces the general-knowledge placeholder with search_product_content,
grounded in ProductQnAVectorSearch. Reasoning now refuses to answer from
general knowledge when nothing relevant is found, mirroring order_lookup's
anti-fabrication discipline.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

### What actually happened

_(Fill in after execution: preview trace confirmation, any instruction
wording that needed adjustment to stop fabrication — check specifically for
the same failure mode `order_lookup` hit, per spec §4.)_

---

## Task 5: End-to-end verification in `sally-prep`

Guided, manual — the rehearsal-checklist proof that Tasks 1–4 work together,
matching `SETUP_GUIDE.md`'s before/after framing (spec §5).

- [ ] **Step 1: Confirm the "before" behavior is on record**

If not already captured earlier in this build, note (for the demo) what
`product_qa` said for 1–2 questions *before* Task 4's wiring — generic,
possibly asking the caller for details it should be able to look up. If
Task 4 is already deployed, this step is a skip — just note that the
before/after contrast was captured live during Task 4 Step 5 instead.

- [ ] **Step 2: Grounded answers, at least 2–3 questions per product category**

Using `sf agent preview --use-live-actions` against `sally-prep`, ask at
least 2–3 product questions spanning different categories from
`REQUIREMENTS.md` §3.1 — e.g.:

- "How do I set up my tent?" (Alpine Peak 2 Tent)
- "My camp stove won't ignite, what do I do?" (BlazeLight Camp Stove)
- "How do I charge my headlamp?" (TrailBeam 500 Headlamp)
- "How do I waterproof my boots?" (Ridgeline Hiking Boots)

For each, confirm via the trace that `search_product_content` fired and the
answer is specific to that product's actual manual content, not generic.

- [ ] **Step 3: Confirm the "nothing found" path degrades gracefully**

Ask an out-of-catalog product question (e.g. "how do I fix my kayak
paddle?" — Cairn doesn't sell kayaks). Expected: the agent says it doesn't
have that specific information and hands off, rather than guessing or
throwing an unhandled error to the caller. This also exercises the
poll-timeout/cancel fallback path indirectly (both "no rows" and
"timed out" collapse to the same `ContentFound = false` response, per spec
§3).

- [ ] **Step 4: Update the rehearsal checklist**

In `SETUP_GUIDE.md` §8, check off "Product Q&A Apex retriever returns
grounded answers for at least 2–3 product questions per product category
worth demoing" if Steps 1–3 above passed.

No separate commit for this task — folded into Task 6's doc commit.

---

## Task 6: Update `SETUP_GUIDE.md` and `REQUIREMENTS.md`

**Files:**

- Modify: `docs/SETUP_GUIDE.md` §6.3, §8, §10
- Modify: `docs/REQUIREMENTS.md` §5.3 (only if real behavior diverges from
  what's already written there)

**Interfaces:** None — doc-only task, no code dependencies.

- [ ] **Step 1: `SETUP_GUIDE.md` §6.3 — mark done, record real names**

Rewrite the single-paragraph description to name the real Data Cloud
objects built (Content Bundle streams from Task 1, `Compass_Product_QA_Index`
and its chunk DMO from Task 2), the `querySql` async pattern and why it was
chosen over `queryAnsiSqlV2` (spec §3), and the `ContentVersion`-backfill
finding from Task 1 Step 4 if it turned out to require a fix.

- [ ] **Step 2: `SETUP_GUIDE.md` §10 — add gotchas**

Add entries for: the confirmed `querySqlRows`/`querySqlStatus` shapes (Task
3, Step 1's findings — save the next implementer from re-discovering them),
and the `ContentVersion` backfill behavior (Task 1, Step 4's finding), even
if it turned out not to be a problem — record that it was checked and what
was found either way.

- [ ] **Step 3: Check off the §8 rehearsal item**

Confirm Task 5, Step 4 already checked the box; if not, check it now.

- [ ] **Step 4: `REQUIREMENTS.md` §5.3 — sync if needed**

Compare the current text against what was actually built. Update only if
real behavior diverges (e.g. if per-product filtering turned out to be
necessary after all, contra the spec's "out of scope" call) — otherwise
leave as-is, since it already accurately describes a single Apex
vector-search approach.

- [ ] **Step 5: Format and commit**

```bash
npm run prettier
git add docs/SETUP_GUIDE.md docs/REQUIREMENTS.md
git commit -m "$(cat <<'EOF'
Document the product Q&A vector search retriever build

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Execution note

Tasks 1 and 2 require the live Data Cloud Setup UI and judgment calls that
depend on what this org's canvas/wizard actually shows — written as
checklists to work through together, live, narrated step-by-step. Task 3's
Step 1 also requires a live org (to introspect the real `ConnectApi` shapes)
before its remaining steps become ordinary Apex file work. Task 4 is an
ordinary `.agent` file edit plus a live preview check. Task 5 is manual
verification. Task 6 is doc-only.

Recommend: inline execution throughout, interleaving the UI walkthrough
tasks with the file-edit tasks in order — same reasoning as the order-lookup
plan: Task 3 can't be written for real until Tasks 1–2's real object names
are known, so strict task-by-task order matters more here than usual.
