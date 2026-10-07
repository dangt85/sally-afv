public with sharing class PersonAccountPhoneLookup {
  public class Request {
    @InvocableVariable(required=true label='Phone Number')
    public String phoneNumber;
  }

  public class Result {
    @InvocableVariable(label='Match Count')
    public Integer matchCount;
    @InvocableVariable(label='Matched Account Id')
    public Id accountId;
    @InvocableVariable(label='Matched First Name')
    public String firstName;
  }

  @InvocableMethod(
    label='Find Person Account By Phone'
    description='Searches all phone fields on Person Accounts for a match against the given phone number.'
    category='Cairn Outdoor Co.'
  )
  public static List<Result> lookupByPhone(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request req : requests) {
      results.add(matchOne(req.phoneNumber));
    }
    return results;
  }

  private static Result matchOne(String phoneNumber) {
    Result result = new Result();
    result.matchCount = 0;

    String searchTerm = toSearchTerm(phoneNumber);
    if (String.isBlank(searchTerm)) {
      return result;
    }

    // LIMIT 2: the caller only needs to know 0 / 1 / more-than-1, so the
    // search index can stop as soon as a second match turns up.
    List<List<SObject>> searchResults = [
      FIND :searchTerm
      IN PHONE FIELDS
      RETURNING Account(Id, FirstName WHERE IsPersonAccount = TRUE LIMIT 2)
    ];
    List<Account> matches = (List<Account>) searchResults[0];

    result.matchCount = matches.size();
    if (result.matchCount == 1) {
      result.accountId = matches[0].Id;
      result.firstName = matches[0].FirstName;
    }
    return result;
  }

  // ANI arrives in E.164 (leading "1" country code for US/Canada); stored
  // Person Account phone data is domestic 10-digit. Strip the country code so
  // the search term lines up with how those values are indexed.
  private static String toSearchTerm(String phoneNumber) {
    if (String.isBlank(phoneNumber)) {
      return '';
    }
    String digits = phoneNumber.replaceAll('[^0-9]', '');
    return digits.length() == 11 && digits.startsWith('1')
      ? digits.substring(1)
      : digits;
  }
}
