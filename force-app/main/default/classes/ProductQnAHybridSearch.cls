/**
 * `product_qa`'s action: searches the Data Cloud hybrid search index built
 * over product manual content. See SETUP_GUIDE.md §6.3 — queried via the
 * async querySql API (not queryAnsiSqlV2) so a slow/stuck query can be
 * bounded and cancelled rather than leaving a live call hanging.
 */
public with sharing class ProductQnAHybridSearch {
  // Search index and its chunk DMO. The join is on the index row's
  // SourceRecordId__c (a pointer back to the source chunk) matching the
  // chunk table's own RecordId__c — NOT index.RecordId__c, which is the
  // vector row's own id and doesn't point anywhere. Confirmed both by a
  // live vector_search() probe returning real chunk content with this join,
  // and by Salesforce's own published example queries for this function
  // family. See Task 2 / SETUP_GUIDE.md §6.3 for how these DMOs were built.
  //
  // Both DLM names derive from the search index's required name,
  // Compass_Product_QnA (<index name>_index__dlm / _chunk__dlm) — see
  // SETUP_GUIDE.md §6.3 step 2.
  private static final String INDEX_TABLE = 'Compass_Product_QnA_index__dlm';
  private static final String CHUNK_TABLE = 'Compass_Product_QnA_chunk__dlm';

  // The chunk table's SecondarySourceRecordId__c (NOT SourceRecordId__c,
  // which is populated but useless here — confirmed live it holds a constant
  // User Id, apparently CreatedById, identical across every manual-PDF
  // chunk) points to the source ContentVersion whose PDF the chunk came
  // from. Confirmed live: joining it to ssot__ContentDocumentVersion__dlm's
  // primary key (ssot__Id__c) and pulling ssot__Title__c returns real,
  // sensible titles (e.g. a StreamPure Water Filter chunk joins to "StreamPure
  // Water Filter - Cleaning / Backwashing How-To"). A LEFT JOIN is used
  // (rather than an inner join) because the index's source DMO is
  // ssot__Product__dlm as well as this attachment DMO — a chunk sourced
  // from Product2 fields directly would have a null
  // SecondarySourceRecordId__c and must not be silently dropped just
  // because it doesn't have a manual title.
  private static final String CONTENT_VERSION_TABLE = 'ssot__ContentDocumentVersion__dlm';

  private static final Integer TOP_K = 3;
  private static final Integer MAX_POLLS = 3;

  // Caller-supplied search text is embedded directly into the SQL literal
  // below (after apostrophe-doubling) with no length limit otherwise — a
  // long, rambling voice-transcribed utterance would go straight into the
  // query. Capped defensively; see buildSql.
  private static final Integer MAX_QUERY_LENGTH = 400;

  // ConnectApi.QuerySqlStatus.completionStatus values observed live against
  // this org: 'Running' while the async query is still working,
  // 'ResultsProduced' once dataRows are ready (there may be other terminal
  // values this org hasn't produced yet, e.g. a failure state). Treat
  // anything other than 'Running' as done rather than allow-listing every
  // terminal value, so an as-yet-unseen one still degrades gracefully
  // instead of being mistaken for still-running.
  private static final String STATUS_RUNNING = 'Running';

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

  private static Result searchOne(Request req) {
    Result result = new Result();
    result.ContentFound = false;

    String searchQuery = trimToNull(req.SearchQueryInput);
    if (searchQuery == null) {
      return result;
    }

    ConnectApi.QuerySqlInput input = new ConnectApi.QuerySqlInput();
    input.sql = buildSql(searchQuery);

    String queryId;
    Boolean done;
    try {
      ConnectApi.QuerySqlOutput submitResult = ConnectApi.CdpQuery.querySql(
        input
      );
      queryId = submitResult.status.queryId;
      done = !STATUS_RUNNING.equals(
        submitResult.status.completionStatus.name()
      );
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'querySql submit failed: ' + e.getMessage()
      );
      return result;
    }

    // A fast query can already be finished by the time querySql returns —
    // confirmed live that completionStatus can already read ResultsProduced
    // on the submit response itself, so polling is skipped in that case.
    // But that same live check also showed submitResult.dataRows isn't
    // reliably populated even when completionStatus says done (e.g. a
    // one-row COUNT(*) came back with dataRows null on the submit response),
    // so rows are always fetched via querySqlRows rather than trusted from
    // the submit response — the only path confirmed to reliably return them.
    if (!done) {
      queryId = pollUntilDone(queryId);
      if (queryId == null) {
        return result;
      }
    }

    List<ConnectApi.QuerySqlRow> dataRows;
    try {
      ConnectApi.QuerySqlPageOutput pageResult = ConnectApi.CdpQuery.querySqlRows(
        queryId,
        0,
        TOP_K
      );
      dataRows = pageResult.dataRows;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'querySqlRows failed: ' + e.getMessage()
      );
      return result;
    }

    List<String> excerpts = parseExcerpts(dataRows);
    if (!excerpts.isEmpty()) {
      result.ContentFound = true;
      result.RetrievedContextOutput = String.join(excerpts, '\n---\n');
    }
    return result;
  }

  private static String buildSql(String searchQuery) {
    // Compass_Product_QnA's search index is confirmed rebuilt as Hybrid
    // (searchType HYBRID), so hybrid_search() is the real query here.
    //
    // This is Data Cloud's ANSI-SQL query layer, which escapes a literal
    // single quote by doubling it — unlike SOQL/SOSL's backslash escaping,
    // so String.escapeSingleQuotes (backslash-based) doesn't work here and
    // was confirmed live to break on an apostrophe ("won't") with a SQL
    // syntax error. This dialect also doesn't treat backslash as an escape
    // character at all, so backslash-based SOQL/SOSL escaping conventions
    // simply don't apply here — doubling is the only escaping this layer
    // needs or supports.
    String safeQuery = searchQuery.left(MAX_QUERY_LENGTH).replace('\'', '\'\'');

    // '-100%' as hybrid_search's min_should_match means the keyword-search
    // (BM25) arm requires zero query terms to match — i.e. it never filters
    // rows out on its own. This maximizes recall and keeps BM25 as one input
    // to the fusion rank alongside the vector-similarity arm, rather than a
    // hard keyword filter. This does NOT disable the keyword arm — the
    // fusion ranking still blends both scores; a reader shouldn't assume
    // "-100%" turns hybrid search back into pure vector search.
    return 'SELECT c.Chunk__c, v.ssot__Title__c, h.hybrid_score__c ' +
      'FROM hybrid_search(table(' +
      INDEX_TABLE +
      '), \'' +
      safeQuery +
      '\', \'\', ' +
      TOP_K +
      ', \'{ "min_should_match": "-100%"}\') AS h ' +
      'JOIN ' +
      CHUNK_TABLE +
      ' AS c ON h.SourceRecordId__c = c.RecordId__c ' +
      'LEFT JOIN ' +
      CONTENT_VERSION_TABLE +
      ' AS v ON c.SecondarySourceRecordId__c = v.ssot__Id__c ' +
      'ORDER BY h.hybrid_score__c DESC LIMIT ' +
      TOP_K;
  }

  // querySqlStatus takes only a queryId and has no server-side wait
  // parameter — but Apex has no safe way to sleep synchronously either: a
  // spin-wait against System.currentTimeMillis() keeps executing
  // instructions the whole time it's "waiting" (unlike a callout, which
  // suspends), so it burns real CPU-governor time rather than just
  // wall-clock time, and can push a transaction over the 10,000ms
  // synchronous CPU limit — a limit that isn't reliably catchable, so it
  // could abort the whole action instead of degrading to
  // ContentFound=false. Each querySqlStatus round trip already costs real
  // wall-clock latency on its own, so this just retries it back-to-back up
  // to MAX_POLLS times and relies on that natural latency for pacing,
  // rather than adding an artificial CPU-burning delay on top. Returns the
  // queryId once the query is done, or null if it never finished within the
  // poll budget (and cancels it in that case, so it doesn't linger
  // server-side).
  private static String pollUntilDone(String queryId) {
    Boolean done = false;
    for (Integer i = 0; i < MAX_POLLS && !done; i++) {
      try {
        ConnectApi.QuerySqlStatus status = ConnectApi.CdpQuery.querySqlStatus(
          queryId
        );
        done = !STATUS_RUNNING.equals(status.completionStatus.name());
      } catch (Exception e) {
        System.debug(
          LoggingLevel.ERROR,
          'querySqlStatus failed: ' + e.getMessage()
        );
        break;
      }
    }

    if (!done) {
      try {
        ConnectApi.CdpQuery.cancelQuerySql(queryId);
      } catch (Exception e) {
        System.debug(
          LoggingLevel.ERROR,
          'cancelQuerySql failed: ' + e.getMessage()
        );
      }
      return null;
    }
    return queryId;
  }

  // ConnectApi.QuerySqlRow is a proper ConnectApi output class here (unlike
  // the data graph's raw Gson-map rows in OrderLookupDataGraph) — its `row`
  // field is a real List<Object> that direct indexing works safely against.
  // buildSql's SELECT list is `c.Chunk__c, v.ssot__Title__c,
  // h.hybrid_score__c` — confirmed live via QuerySqlPageOutput.metadata that
  // column order is preserved, so the chunk text is always at index 0 and
  // the manual title at index 1; the score isn't currently needed.
  //
  // Each excerpt is prefixed with its source manual's title so the reasoning
  // LLM (and a human reading the trace) can tell which product/manual it
  // came from — with TOP_K=3 and no per-product filter, the 3 excerpts can
  // otherwise come from 3 different products with no signal which is which.
  // Title can be null (the LEFT JOIN — see CONTENT_VERSION_TABLE comment
  // above), in which case the chunk is still returned, just unlabeled,
  // rather than dropped.
  private static List<String> parseExcerpts(
    List<ConnectApi.QuerySqlRow> dataRows
  ) {
    List<String> excerpts = new List<String>();
    if (dataRows == null) {
      return excerpts;
    }
    for (ConnectApi.QuerySqlRow dataRow : dataRows) {
      if (dataRow.row == null || dataRow.row.isEmpty()) {
        continue;
      }
      String chunk = asString(dataRow.row[0]);
      if (String.isBlank(chunk)) {
        continue;
      }
      String title = dataRow.row.size() > 1 ? asString(dataRow.row[1]) : null;
      excerpts.add(String.isNotBlank(title) ? title + ': ' + chunk : chunk);
    }
    return excerpts;
  }

  private static String trimToNull(String value) {
    return String.isBlank(value) ? null : value.trim();
  }

  private static String asString(Object value) {
    return value == null ? null : String.valueOf(value);
  }
}
