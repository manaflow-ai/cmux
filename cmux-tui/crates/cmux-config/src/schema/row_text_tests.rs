use super::*;

/// The hash before rows were parsed one at a time: SHA-256 of every row
/// value in one array, serialized compact.
fn rows_hash_reference(text: &str) -> String {
    use sha2::{Digest, Sha256};
    let document: Value = serde_json::from_str(text).expect("parses");
    let rows = document["rows"].as_array().expect("rows").clone();
    let bytes = serde_json::to_vec(&rows).expect("serializes");
    Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

#[test]
fn the_schema_hash_equals_the_whole_array_hash() {
    assert_eq!(Schema::embedded().schema_hash, rows_hash_reference(&EMBEDDED.inflate()));
    let empty = r#"{"version":1,"sections":[],"rows":[]}"#;
    assert_eq!(Schema::parse(empty).expect("parses").schema_hash, rows_hash_reference(empty));
}

#[test]
fn embedded_rows_are_slices_of_one_compact_text_not_the_document() {
    let rows = &Schema::embedded().rows;
    assert!(!rows.is_empty());
    let mut next: Option<*const u8> = None;
    let mut kept = 0;
    for row in rows {
        let RowText::Embedded(text) = &row.raw else {
            panic!("{}: an embedded row holds its own box", row.key);
        };
        // Each row starts where the one before it ended: one text, in order.
        if let Some(next) = next {
            assert_eq!(text.as_ptr(), next, "{}: not in the shared text", row.key);
        }
        next = Some(text.as_bytes().as_ptr_range().end);
        let value: Value = serde_json::from_str(text).expect("row parses");
        assert_eq!(*text, serde_json::to_string(&value).expect("serializes"), "{}", row.key);
        kept += text.len();
    }
    // The kept text is the compact rows, well under the inflated document.
    assert!(kept * 10 < EMBEDDED.len() * 7, "kept {kept} of {}", EMBEDDED.len());
    // Another text keeps owned compact rows that give back the same values.
    let parsed = Schema::parse(&EMBEDDED.inflate()).expect("parses");
    assert_eq!(parsed.schema_hash, Schema::embedded().schema_hash);
    for (owned, embedded) in parsed.rows.iter().zip(rows) {
        assert!(matches!(owned.raw, RowText::Owned(_)));
        assert_eq!(owned.raw(), embedded.raw(), "{}", owned.key);
        assert_eq!(owned, embedded, "{}", owned.key);
    }
}
