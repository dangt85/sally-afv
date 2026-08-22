@isTest
private class PersonAccountPhoneLookupTest {
  @TestSetup
  static void setup() {
    Id personAccountRecordTypeId = [
      SELECT Id
      FROM RecordType
      WHERE SObjectType = 'Account' AND IsPersonType = TRUE
      LIMIT 1
    ]
    .Id;

    insert new List<Account>{
      new Account(
        RecordTypeId = personAccountRecordTypeId,
        FirstName = 'Maria',
        LastName = 'Alvarez',
        Phone = '(555) 010-1111'
      ),
      new Account(
        RecordTypeId = personAccountRecordTypeId,
        FirstName = 'James',
        LastName = 'Whitfield',
        Phone = '555.010.2222'
      ),
      new Account(
        RecordTypeId = personAccountRecordTypeId,
        FirstName = 'Linh',
        LastName = 'Tran',
        Phone = '555.010.2222'
      )
    };
  }

  // Test context never invokes the real search index, so each test tells
  // Apex what the next SOSL query should return (per Test.setFixedSearchResults).

  @isTest
  static void singleMatchReturnsFirstName() {
    Account maria = [SELECT Id FROM Account WHERE FirstName = 'Maria' LIMIT 1];
    Test.setFixedSearchResults(new List<Id>{ maria.Id });

    PersonAccountPhoneLookup.Request req = new PersonAccountPhoneLookup.Request();
    req.phoneNumber = '+15550101111';

    Test.startTest();
    List<PersonAccountPhoneLookup.Result> results = PersonAccountPhoneLookup.lookupByPhone(
      new List<PersonAccountPhoneLookup.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results[0].matchCount);
    System.assertEquals(maria.Id, results[0].accountId);
    System.assertEquals('Maria', results[0].firstName);
  }

  @isTest
  static void multipleMatchesReturnsNoFirstName() {
    List<Account> dupes = [
      SELECT Id
      FROM Account
      WHERE FirstName IN ('James', 'Linh')
    ];
    Test.setFixedSearchResults(new List<Id>{ dupes[0].Id, dupes[1].Id });

    PersonAccountPhoneLookup.Request req = new PersonAccountPhoneLookup.Request();
    req.phoneNumber = '15550102222';

    List<PersonAccountPhoneLookup.Result> results = PersonAccountPhoneLookup.lookupByPhone(
      new List<PersonAccountPhoneLookup.Request>{ req }
    );

    System.assertEquals(2, results[0].matchCount);
    System.assertEquals(null, results[0].firstName);
  }

  @isTest
  static void noMatchReturnsZeroCount() {
    Test.setFixedSearchResults(new List<Id>());

    PersonAccountPhoneLookup.Request req = new PersonAccountPhoneLookup.Request();
    req.phoneNumber = '9995551234'; // 10-digit, no country code - covers that branch too

    List<PersonAccountPhoneLookup.Result> results = PersonAccountPhoneLookup.lookupByPhone(
      new List<PersonAccountPhoneLookup.Request>{ req }
    );

    System.assertEquals(0, results[0].matchCount);
  }

  @isTest
  static void blankPhoneNumberReturnsZeroCountWithoutQuerying() {
    PersonAccountPhoneLookup.Request req = new PersonAccountPhoneLookup.Request();
    req.phoneNumber = null;

    List<PersonAccountPhoneLookup.Result> results = PersonAccountPhoneLookup.lookupByPhone(
      new List<PersonAccountPhoneLookup.Request>{ req }
    );

    System.assertEquals(0, results[0].matchCount);
  }
}
