# Design: Product Q&A — Data Cloud Vector Search Retriever

Date: 2026-08-29
Status: Approved for implementation planning

## Purpose

Replace the `product_qa` subagent's "reason from general knowledge" placeholder
with a custom Apex vector-search retriever grounded in the actual PDF
manuals/troubleshooting guides already linked to each `Product2` record, per
`SETUP_GUIDE.md` §6.3 / `REQUIREMENTS.md` §5.3. Ingestion source is the
`ContentVersion`/`ContentDocumentLink` records loaded during the sample data
build (`REQUIREMENTS.md` §3.1) — no new sample data needed, only the Data
Cloud ingestion, search index, and Apex/agent wiring on top of it.

This spec covers:

1. Ingesting the product manual `ContentVersion` files into Data Cloud via the
   Salesforce CRM file-attachment ingestion path (not the generic external
   blob storage path order lookup's structured Data Streams used).
2. Building a hybrid (keyword + vector) search index over the ingested
   content.
3. A new Apex invocable action (`ProductQnAVectorSearch`) that queries the
   index via the `querySql`/`querySqlStatus`/`querySqlRows`/`cancelQuerySql`
   async API, with a bounded poll budget so a slow query can't leave a live
   call hanging.
4. Agent Script changes to `Cairn_Compass.agent`'s `product_qa` subagent:
   wire the new action in, and change the reasoning instructions from
   "answer from general knowledge" to "ground every answer in the retriever's
   output, same discipline as `order_lookup`'s anti-fabrication rule."
5. Doc updates to keep `SETUP_GUIDE.md`/`REQUIREMENTS.md` in sync with
   reality, per this repo's working agreement.

Out of scope for this spec:

- `company_faq`'s parallel vector-search build (`SETUP_GUIDE.md` §6.2) — a
  separate, later effort, even though it shares the same Data Cloud
  mechanics.
- Per-product filtering on the search input (e.g. an explicit
  `ProductNameInput`/SKU filter) — the free-text question alone is the query
  for this first pass; add a filter later only if hybrid search's own
  ranking doesn't discriminate well enough between products in practice.
- Re-touching or reloading the sample PDFs — the existing `ContentVersion`
  records loaded by `data/scripts/load-data.sh` are the ingestion source
  as-is (see §1 risk 1 below for the one thing that could force a re-touch).
- Any change to `order_lookup` or the data graph it already uses.

## 0. Starting state

- The 8 products (`REQUIREMENTS.md` §3.1) each have at least one PDF manual,
  troubleshooting guide, or how-to loaded as a `ContentVersion` linked to
  their `Product2` record via `ContentDocumentLink`
  (`FirstPublishLocationId` set at insert time — `SETUP_GUIDE.md` §4.1 step
  2). These files already exist in `sally-prep`.
- No Data Cloud ingestion, mapping, or search index exists yet for this
  content — this is a from-zero build, unlike order lookup's data graph work
  (where CRM ingestion/mapping was already done before that spec started).
- `product_qa`'s `.agent` definition currently has no `before_reasoning`
  hook, no actions, and a `# PLACEHOLDER` comment noting the future
  `product_qa_retriever` action — see `Cairn_Compass.agent` lines 246–270.
- No Data Cloud metadata (Data Streams, DMOs, search indexes, data graphs) is
  checked into `force-app` anywhere in this repo — all of it, including
  order lookup's data graph, was built by hand in the Data Cloud UI and is
  documented in `SETUP_GUIDE.md` rather than deployed. This build follows
  the same pattern: only the Apex class and `.agent` changes are checked in.

## 1. Data Cloud ingestion — new part, taught step-by-step

1. **Ingest file attachments**: use Data Cloud's purpose-built "Ingest File
   Attachments from Salesforce CRM Objects" path, which deploys a standard
   Content Bundle (Data Lake Objects + Data Model Objects + Data Streams for
   `ContentDocument`, `ContentVersion`, `ContentDocumentLink`) — ingesting
   directly from Salesforce CRM, no S3/Azure/GCS intermediary needed (that's
   the generic "unstructured data from external storage" path, which doesn't
   apply here since the files already live in Salesforce).
2. **Known risk, verify first**: Salesforce's own documentation notes the
   `ContentVersion` stream "ingests only file versions created or updated
   after you create the data stream." Every manual PDF here was already
   loaded before this build starts. This gets verified against `sally-prep`
   as the very first hands-on step, before building anything on top of it —
   if the initial full ingestion doesn't backfill existing versions, the
   fallback is triggering a full refresh or touching/re-saving the affected
   `ContentVersion` records after the stream exists. Do not assume backfill
   works; confirm row counts in the ingested DLO match the 13 seeded PDFs.
3. **Mapping**: confirm `ContentDocumentLink` survives ingestion and still
   ties each file back to its `Product2` parent — not required for this
   spec's retrieval query (§3), but worth confirming now since a future
   per-product filter (explicitly out of scope above) would depend on it.

## 2. Search index (chunking + embedding)

- Build a **hybrid** (keyword + vector) search index — Data Cloud → Search
  Index → New — over the ingested `ContentVersion` DMO, using Easy Setup's
  default chunking/embedding config to start. No hand-tuning of chunk
  size/overlap until real retrieval quality against the actual manuals says
  otherwise.
- Hybrid over pure vector: troubleshooting queries often hinge on exact
  terms ("won't ignite," "leaking seams") that pure semantic search can
  under-rank; Salesforce's own reference retriever implementation blends
  `keyword_score__c`/`vector_score__c` into `hybrid_score__c` for this
  reason.
- Name it `Compass_Product_QA_Index`, consistent with the order-lookup data
  graph's `Compass_Order_Lookup` naming.
- Publish/activate, then sanity-check retrieval directly in Data Cloud (Data
  Explorer or a raw SQL query) for 2–3 known manuals before wiring up Apex —
  same "verify the layer under you before building on it" discipline used
  for the order-lookup data graph.

## 3. Apex retriever (`ProductQnAVectorSearch.cls`)

- `@InvocableMethod`, category `Cairn Outdoor Co.`, matching
  `OrderLookupDataGraph`'s convention.
- **Request**: single `SearchQueryInput: string` — the caller's product
  question, verbatim. No product-name/SKU filter input (see Out of scope).
- **Query flow**, using the `querySql` async API (chosen over
  `queryAnsiSqlV2` specifically for its timeout/cancel handling, which a
  live voice call needs):
  1. Build the SQL: `hybrid_search(...)` against the index DMO with the
     caller's question, joined to the chunk DMO, ordered by
     `hybrid_score__c desc`, `LIMIT 3` (top-K starting point).
  2. Submit via `ConnectApi.CdpQuery.querySql(QuerySqlInput)` → get back a
     `queryId`.
  3. Poll `ConnectApi.CdpQuery.querySqlStatus(queryId, waitTimeMs)` in a
     bounded loop — `waitTimeMs = 2000`, max 3 iterations (~6s total
     budget). Stop polling once status reports done.
  4. On success: fetch rows via `querySqlRows(queryId, 0, 3)` and flatten
     into the response (see below). The exact row/column
     shape `querySqlRows` returns isn't nailed down from documentation alone
     (Salesforce's reference material covers the REST shape, not a concrete
     Apex parsing example) — confirmed empirically against `sally-prep`
     during implementation, same discipline `OrderLookupDataGraph.parseRow`
     used for the data graph's raw-Gson-row problem. Document whatever is
     found in a comment on the parsing method, the way `parseRow` documents
     its own discovery.
  5. On poll-budget exhaustion, or any query error/exception: call
     `ConnectApi.CdpQuery.cancelQuerySql(queryId)` and fall through to the
     same "nothing found" response as a real empty result — no separate
     error path, since `product_qa`'s reasoning instructions already need to
     handle "retriever found nothing relevant" as a case (§4).
- **Result**:
  - `ContentFound: boolean` — whether any rows came back (from a real
    result, not from a timeout/cancel — those are indistinguishable to the
    caller and both mean "don't answer from this").
  - `RetrievedContextOutput: string`, `is_displayable: True` — the top-K
    chunks flattened into one string, plainly labeled (e.g. product/title
    plus excerpt per chunk), for the reasoning LLM to synthesize from. Flat
    and factual, not formatted as a final answer — same reasoning as
    `OrderLookupDataGraph.summarize`: the model puts it in its own words,
    it doesn't invent beyond it.

## 4. Agent Script changes (`product_qa` subagent)

In `Cairn_Compass.agent`:

- Remove the `# PLACEHOLDER` comment block (lines 249–252).
- Add `product_qa_action`:
  ```
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
- Reasoning instructions change from "answer using general knowledge of
  specs, compatibility, troubleshooting, and how-tos" to: call
  `product_qa_action` with the caller's question every turn a new product
  question comes in, ground the answer only in `RetrievedContextOutput`, and
  if `ContentFound` is false, say so honestly (don't guess) and hand off to
  a specialist rather than falling back to general knowledge — mirroring
  `order_lookup`'s explicit "never invent" language, since the same
  fabrication risk documented there (`SETUP_GUIDE.md` §6.1.3) applies here:
  an LLM given no real content to work from will generate a plausible-
  sounding answer unless explicitly told its only source of truth is the
  retriever's output.
- No `before_reasoning` hook — unlike `order_lookup`, there's no "known
  product" to prefetch before the caller states their question; the
  question text itself is the query, so this stays a plain
  reasoning-triggered action call each turn.
- `hand_off_to_specialist` action is unchanged.

## 5. Testing / validation

- Preview `Cairn_Compass` in AFDX live mode against `sally-prep` (Data Cloud
  dependency means simulated mode can't meaningfully exercise this, same as
  order lookup) for at least 2–3 questions per product category, per
  `SETUP_GUIDE.md`'s rehearsal checklist item.
- Confirm the documented before/after contrast (`SETUP_GUIDE.md` §6.3):
  before wiring, the placeholder gives a generic answer and may ask the
  caller for details it should be able to look up; after wiring, the answer
  cites the actual product's manual content. Capture both for the demo.
- Confirm the poll-budget/cancel path doesn't surface to the caller as a
  hard error — simulate a slow or failing query if there's a way to (e.g. a
  deliberately malformed index name during a throwaway test) and confirm
  the agent's fallback ("I couldn't find that, let me connect you") fires
  instead of an unhandled exception reaching the caller.

## 6. Doc updates

- `SETUP_GUIDE.md` §6.3: mark done, replace the single-paragraph description
  with the real object/index names (`Compass_Product_QA_Index`), the
  `querySql` async pattern, and the `ContentVersion`-backfill gotcha from
  §1 if it turns out to bite.
- `REQUIREMENTS.md` §5.3: confirm wording still matches once built; update
  only if the real behavior diverges from what's already stated there.
- `SETUP_GUIDE.md` §10 (Known Gotchas): add whatever `querySqlRows`'
  row-shape turns out to be (§3 step 4), plus the `ContentVersion` backfill
  finding, so neither has to be rediscovered later.

## 7. Follow-up (not detailed here)

- `company_faq`'s vector-search retriever — separate build, same mechanics.
- Per-product filtering on the search input, if hybrid search's ranking
  doesn't reliably surface the right product's manual in practice.
- Tuning the poll budget (2s × 3) and top-K (3) once real latency and
  retrieval quality are visible in `sally-prep`.
