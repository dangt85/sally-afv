/**
 * `company_faq`'s action: searches the Data Cloud vector search index built
 * over Knowledge article content, replacing the Prompt Template/ADL baseline
 * (standard AnswerQuestionsWithKnowledge action) with a direct query that
 * skips its orchestration overhead. See SETUP_GUIDE.md §6.2 — queried via
 * the async querySql API (not queryAnsiSqlV2) so a slow/stuck query can be
 * bounded and cancelled rather than leaving a live call hanging. Mirrors
 * ProductQnAHybridSearch.cls (§6.3), but plain vector_search() rather than
 * hybrid_search() — REQUIREMENTS.md §5.2 specifies vector-search for this
 * stage, and FAQ questions don't hinge on exact troubleshooting phrases the
 * way product manual content does.
 */
public with sharing class CompanyFAQVectorSearch {
  // Search index and its chunk DMO, named after the Cairn_Knowledge Data
  // Cloud search index it's built over (<index name>_index__dlm /
  // _chunk__dlm) — confirmed live to exist in sally-prep even while the
  // index is still populating (schema exists before rows do).
  private static final String INDEX_TABLE = 'Cairn_Knowledge_index__dlm';
  private static final String CHUNK_TABLE = 'Cairn_Knowledge_chunk__dlm';

  // Confirmed live via CdpQuery in sally-prep: Knowledge__kav is already
  // ingested into Data Cloud as ssot__KnowledgeArticleVersion__dlm (separate
  // from the Cairn_Knowledge ADL's own internals). FAQ_Question_c__c/
  // FAQ_Answer_c__c/Chat_Answer_c__c are the content fields; ssot__Name__c
  // is the article title; ssot__Id__c is the primary key joined against
  // below.
  private static final String KNOWLEDGE_TABLE = 'ssot__KnowledgeArticleVersion__dlm';

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
    label='Search Company FAQ In Data Cloud'
    description='Searches the company FAQ/Knowledge content in Data Cloud for excerpts relevant to the caller\'s policy question.'
    category='Cairn Outdoor Co.'
  )
  public static List<Result> searchFAQContent(List<Request> requests) {
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

    // A fast query can already be finished by the time querySql returns, but
    // submitResult.dataRows isn't reliably populated even when done — see
    // ProductQnAHybridSearch.cls for the confirmed live behavior this
    // mirrors. Rows are always fetched via querySqlRows instead.
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
    // This is Data Cloud's ANSI-SQL query layer, which escapes a literal
    // single quote by doubling it — unlike SOQL/SOSL's backslash escaping.
    // See ProductQnAHybridSearch.cls for the confirmed-live detail; same
    // dialect, same escaping.
    String safeQuery = searchQuery.left(MAX_QUERY_LENGTH).replace('\'', '\'\'');

    // vector_search()'s signature confirmed live: (table, query text, '',
    // top_k) — the empty string is a required positional argument (its
    // purpose wasn't probed further; omitting it or passing top_k in its
    // place both failed with a type-mismatch error).
    //
    // Join: the index row's SourceRecordId__c points to the chunk table's
    // own RecordId__c, same as ProductQnAHybridSearch's hybrid_search join —
    // confirmed live only as far as the query compiling and running clean,
    // not yet against real data (Cairn_Knowledge index is still populating
    // as of this build). The chunk table's SecondarySourceRecordId__c is
    // used (via LEFT JOIN, so a null doesn't drop the row) to resolve the
    // source article's title, on the same reasoning as the product retriever
    // — SourceRecordId__c on the chunk table was confirmed there to be a
    // useless constant, not a real pointer. Re-verify both joins once the
    // index has rows; this index has only one source object (Knowledge),
    // unlike product's two, so the SourceRecordId__c-is-useless gotcha may
    // not actually apply here — adjust if a live probe shows otherwise.
    return 'SELECT c.Chunk__c, v.ssot__Name__c, s.score__c ' +
      'FROM vector_search(table(' +
      INDEX_TABLE +
      '), \'' +
      safeQuery +
      '\', \'\', ' +
      TOP_K +
      ') AS s ' +
      'JOIN ' +
      CHUNK_TABLE +
      ' AS c ON s.SourceRecordId__c = c.RecordId__c ' +
      'LEFT JOIN ' +
      KNOWLEDGE_TABLE +
      ' AS v ON c.SecondarySourceRecordId__c = v.ssot__Id__c ' +
      'ORDER BY s.score__c DESC LIMIT ' +
      TOP_K;
  }

  // See ProductQnAHybridSearch.cls for why this retries back-to-back with no
  // artificial delay rather than spin-waiting.
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

  // buildSql's SELECT list is `c.Chunk__c, v.ssot__Name__c, s.score__c` — the
  // chunk text is at index 0, the article title at index 1; the score isn't
  // currently needed. Each excerpt is prefixed with its source article's
  // title so the reasoning LLM (and a human reading the trace) can tell
  // which policy area it came from. Title can be null (the LEFT JOIN — see
  // buildSql), in which case the chunk is still returned, just unlabeled,
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
