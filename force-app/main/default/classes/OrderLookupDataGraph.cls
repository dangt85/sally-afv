/**
 * `order_lookup`'s action: reads the caller's order out of the Data Cloud data
 * graph. See SETUP_GUIDE.md §6.1.3 — a data graph has no no-code retriever
 * action, so it's queried through the Data Graph Query API from Apex.
 */
public with sharing class OrderLookupDataGraph {
  // Account -> Sales Order -> Sales Order Product -> Product, with the Sales
  // Order node sorted newest-first (that sort is what makes orders[0] "most
  // recent"). Refreshes hourly, so a just-created order won't be here yet.
  private static final String DATA_GRAPH_NAME = 'Compass_Order_Lookup';
  private static final String DATA_GRAPH_VERSION = 'default';
  private static final String ORDERS_NODE = 'ssot__SalesOrder__dlm';

  // Markers used to cut the graph payload out of a result row — see parseRow.
  private static final String BLOB_KEY = 'json_blob__c=';
  private static final String BLOB_END = ', version__c=';

  public class Request {
    @InvocableVariable(label='Account Id')
    public String AccountIdInput;
    @InvocableVariable(label='Order Number')
    public String OrderNumberInput;
    @InvocableVariable(label='Order Date')
    public Date OrderDateInput;
  }

  public class Result {
    @InvocableVariable(label='Order Found')
    public Boolean OrderFound;
    @InvocableVariable(label='Order Number')
    public String OrderNumberOutput;
    @InvocableVariable(label='Total Amount')
    public Decimal TotalAmountOutput;
    @InvocableVariable(label='Fulfillment Status')
    public String FulfillmentStatusOutput;
    @InvocableVariable(label='Estimated Delivery Date')
    public Date EstimatedDeliveryDateOutput;
    @InvocableVariable(label='Order Summary')
    public String OrderSummaryOutput;
  }

  @InvocableMethod(
    label='Look Up Order In Data Cloud'
    description='Finds a caller\'s order in the Compass_Order_Lookup Data Cloud data graph — by the account already matched from their ANI, or by an order number plus the date it was placed (both required together, since a caller the ANI didn\'t already identify can\'t be trusted on an order number alone).'
    category='Cairn Outdoor Co.'
  )
  public static List<Result> lookUpOrder(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request req : requests) {
      results.add(findOne(req));
    }
    return results;
  }

  private static Result findOne(Request req) {
    Result result = new Result();
    result.OrderFound = false;

    String orderNumber = trimToNull(req.OrderNumberInput);
    String accountId = resolveAccountId(req);
    if (String.isBlank(accountId)) {
      return result;
    }

    List<Object> orders = fetchOrders(accountId);
    if (orders == null || orders.isEmpty()) {
      return result;
    }

    // With no order number to go on, the caller means "my order" — the graph
    // sorts Sales Order newest-first, so that's simply the first node.
    Map<String, Object> order = orderNumber == null
      ? (Map<String, Object>) orders[0]
      : findByNumber(orders, orderNumber);
    if (order == null) {
      return result;
    }

    result.OrderFound = true;
    result.OrderNumberOutput = asString(order.get('ssot__OrderNumber__c'));
    result.TotalAmountOutput = asDecimal(order.get('ssot__TotalAmount__c'));
    result.FulfillmentStatusOutput = asString(
      order.get('Fulfillment_Status__c')
    );
    result.EstimatedDeliveryDateOutput = asDate(
      order.get('Estimated_Delivery_Date__c')
    );
    result.OrderSummaryOutput = summarize(result);
    return result;
  }

  // order_lookup's before_reasoning hook pre-fetches the known caller's order
  // and holds it in a variable, and Agent Script variables can only be
  // string/number/boolean/object — so the five typed outputs can't each be held
  // in one, and this flat line stands in for them. Keeping it factual and
  // unformatted lets the agent put it into its own words without inventing
  // anything, which is the whole point: left to call the action on its own
  // judgement, the LLM fabricated order numbers instead.
  private static String summarize(Result result) {
    List<String> parts = new List<String>{
      'order ' + result.OrderNumberOutput
    };
    if (result.TotalAmountOutput != null) {
      parts.add('total $' + result.TotalAmountOutput.setScale(2).format());
    }
    if (String.isNotBlank(result.FulfillmentStatusOutput)) {
      parts.add('fulfillment status ' + result.FulfillmentStatusOutput);
    }
    if (result.EstimatedDeliveryDateOutput != null) {
      parts.add(
        'estimated delivery ' + result.EstimatedDeliveryDateOutput.format()
      );
    }
    return String.join(parts, ', ');
  }

  // The graph is only queryable by its root Account's id, so every path has to
  // arrive at one first. A caller the inbound flow already matched by ANI
  // arrives with it in hand and skips this entirely. A caller ANI didn't
  // identify has to prove it's really their order: an order number alone is
  // guessable, so it only resolves when the caller also gives the date the
  // order was placed and it matches the record — either input missing, or a
  // date mismatch, is treated the same as no match.
  private static String resolveAccountId(Request req) {
    String knownAccountId = trimToNull(req.AccountIdInput);
    if (knownAccountId != null) {
      return knownAccountId;
    }

    String orderNumber = trimToNull(req.OrderNumberInput);
    if (orderNumber == null || req.OrderDateInput == null) {
      return null;
    }
    List<Order> orders = [
      SELECT AccountId, EffectiveDate
      FROM Order
      WHERE OrderNumber = :orderNumber
      LIMIT 1
    ];
    if (orders.isEmpty() || orders[0].EffectiveDate != req.OrderDateInput) {
      return null;
    }
    return orders[0].AccountId;
  }

  private static List<Object> fetchOrders(String accountId) {
    ConnectApi.CdpQueryOutput queryOutput = ConnectApi.CdpQuery.getDataGraphData(
      DATA_GRAPH_NAME,
      accountId,
      DATA_GRAPH_VERSION
    );
    if (
      queryOutput == null ||
      queryOutput.data == null ||
      queryOutput.data.isEmpty()
    ) {
      return null;
    }
    Map<String, Object> root = parseRow(queryOutput.data[0]);
    return root == null ? null : (List<Object>) root.get(ORDERS_NODE);
  }

  // ConnectApi hands each row back as a raw Java map rather than an Apex Map:
  // calling any Map method on it faults the interpreter in a way try/catch
  // can't intercept. Its toString() is safe, though, and the row renders as
  // `{json_blob__c=<the whole graph as JSON>, version__c=0}` — so cut that
  // payload out of the string and parse it into real Apex collections.
  private static Map<String, Object> parseRow(Object row) {
    String raw = String.valueOf(row);
    Integer startIndex = raw.indexOf(BLOB_KEY);
    if (startIndex < 0) {
      return null;
    }
    startIndex += BLOB_KEY.length();

    Integer endIndex = raw.lastIndexOf(BLOB_END);
    if (endIndex <= startIndex) {
      // json_blob__c came last in the map; drop the map's own closing brace.
      endIndex = raw.length() - 1;
    }

    try {
      return (Map<String, Object>) JSON.deserializeUntyped(
        raw.substring(startIndex, endIndex)
      );
    } catch (Exception e) {
      // A caller mid-conversation is better served by "I couldn't find it"
      // than by a hard failure, so report the shape problem and move on.
      System.debug(
        LoggingLevel.ERROR,
        'Unparseable data graph row: ' + e.getMessage()
      );
      return null;
    }
  }

  private static Map<String, Object> findByNumber(
    List<Object> orders,
    String orderNumber
  ) {
    for (Object entry : orders) {
      Map<String, Object> order = (Map<String, Object>) entry;
      if (orderNumber.equals(asString(order.get('ssot__OrderNumber__c')))) {
        return order;
      }
    }
    return null;
  }

  private static String trimToNull(String value) {
    return String.isBlank(value) ? null : value.trim();
  }

  private static String asString(Object value) {
    return value == null ? null : String.valueOf(value);
  }

  private static Decimal asDecimal(Object value) {
    return value == null ? null : Decimal.valueOf(String.valueOf(value));
  }

  private static Date asDate(Object value) {
    return value == null ? null : Date.valueOf(String.valueOf(value));
  }
}
