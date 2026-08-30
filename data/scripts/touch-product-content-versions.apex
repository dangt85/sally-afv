// Data Cloud's ContentVersion data stream only ingests file versions
// created or updated *after* the stream was created (SETUP_GUIDE.md #10 /
// docs/superpowers/specs/2026-08-29-product-qa-vector-search-design.md
// S1). Every product manual here was loaded before that stream existed, so
// the initial ingestion picked up 0 records. Re-saving each ContentVersion
// with a real Description (previously blank) makes the incremental stream
// see them as updated, without altering the PDF content itself.
// Run with: sf apex run --file data/scripts/touch-product-content-versions.apex --target-org <alias>
List<ContentVersion> versions = [
    SELECT Id, Title, Description
    FROM ContentVersion
    WHERE FirstPublishLocationId IN (
        SELECT Id FROM Product2 WHERE ProductCode != null
    )
];

for (ContentVersion cv : versions) {
    cv.Description = 'Cairn Outdoor Co. product manual/guide, ingested into Data Cloud for the product Q&A vector search retriever.';
}
update versions;

System.debug('Touched ' + versions.size() + ' ContentVersion record(s).');
