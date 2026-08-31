/**
 * `product_qa`'s action: searches the Data Cloud hybrid search index built
 * over product manual content. See SETUP_GUIDE.md §6.3 — queried via the
 * async querySql API (not queryAnsiSqlV2) so a slow/stuck query can be
 * bounded and cancelled rather than leaving a live call hanging.
 */
public with sharing class ProductQnAVectorSearch {
  // Search index (hybrid_score__c) and its chunk DMO, joined on RecordId__c —
  // both DMOs share that value space, so it's the join key. See Task 2 /
  // SETUP_GUIDE.md §6.3 for how these DMOs were built.
  private static final String INDEX_TABLE = 'Compass_Product_QnA_index__dlm';
  private static final String CHUNK_TABLE = 'Compass_Product_QnA_chunk__dlm';
  private static final Integer TOP_K = 3;
  private static final Integer POLL_WAIT_MS = 2000;
  private static final Integer MAX_POLLS = 3;

  // ConnectApi.QuerySqlStatus.completionStatus values observed live against
  // this org: 'Running' while the async query is still working, 'Finished'
  // once dataRows are ready. Treat anything other than 'Running' as done
  // rather than allow-listing every terminal value, in case a status this
  // org hasn't produced yet (e.g. a failure state) shows up later.
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
    List<ConnectApi.QuerySqlRow> dataRows;
    try {
      ConnectApi.QuerySqlOutput submitResult = ConnectApi.CdpQuery.querySql(
        input
      );
      queryId = submitResult.status.queryId;
      // A fast query can already be finished by the time querySql returns —
      // in that case its rows travel on the submit response itself and there
      // is nothing to poll.
      if (!STATUS_RUNNING.equals(submitResult.status.completionStatus.name())) {
        dataRows = submitResult.dataRows;
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'querySql submit failed: ' + e.getMessage()
      );
      return result;
    }

    if (dataRows == null) {
      queryId = pollUntilDone(queryId);
      if (queryId == null) {
        return result;
      }
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
    // single quote by doubling it — unlike SOQL/SOSL's backslash escaping,
    // so String.escapeSingleQuotes (backslash-based) doesn't work here and
    // was confirmed live to break on an apostrophe ("won't") with a SQL
    // syntax error.
    return 'SELECT c.Chunk__c, h.hybrid_score__c ' +
      'FROM hybrid_search(table(' +
      INDEX_TABLE +
      '), \'' +
      searchQuery.replace('\'', '\'\'') +
      '\', \'\', ' +
      TOP_K +
      ', \'{ "min_should_match": "-100%"}\') AS h ' +
      'JOIN ' +
      CHUNK_TABLE +
      ' AS c ON h.RecordId__c = c.RecordId__c ' +
      'ORDER BY h.hybrid_score__c DESC LIMIT ' +
      TOP_K;
  }

  // querySqlStatus takes only a queryId — there's no server-side wait, so
  // this loop supplies its own pause between polls. Apex has no Thread.sleep,
  // so a busy-wait against System.currentTimeMillis() is the conventional
  // way to burn a fixed amount of wall-clock time synchronously; kept short
  // (POLL_WAIT_MS x MAX_POLLS = 6s) to stay well under the governor's
  // synchronous CPU-time limit. Returns the queryId once the query is done,
  // or null if it never finished (and cancels it in that case, so it doesn't
  // linger server-side).
  private static String pollUntilDone(String queryId) {
    Boolean done = false;
    for (Integer i = 0; i < MAX_POLLS && !done; i++) {
      busyWait(POLL_WAIT_MS);
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

  private static void busyWait(Integer milliseconds) {
    Long start = System.currentTimeMillis();
    while (System.currentTimeMillis() - start < milliseconds) {
      // Intentional busy-wait — see pollUntilDone's comment.
    }
  }

  // ConnectApi.QuerySqlRow is a proper ConnectApi output class here (unlike
  // the data graph's raw Gson-map rows in OrderLookupDataGraph) — its `row`
  // field is a real List<Object> that direct indexing works safely against.
  // Column order matches the SELECT list in buildSql: c.Chunk__c first.
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
      if (String.isNotBlank(chunk)) {
        excerpts.add(chunk);
      }
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
