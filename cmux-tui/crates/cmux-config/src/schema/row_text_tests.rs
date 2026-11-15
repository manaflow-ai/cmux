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
    assert_eq!(Schema::embedded().schema_hash, rows_hash_reference(EMBEDDED));
    let empty = r#"{"version":1,"sections":[],"rows":[]}"#;
    assert_eq!(Schema::parse(empty).expect("parses").schema_hash, rows_hash_reference(empty));
}

#[test]
fn embedded_rows_keep_slices_of_the_compiled_text_not_heap_copies() {
    let range = EMBEDDED.as_bytes().as_ptr_range();
    let rows = &Schema::embedded().rows;
    assert!(!rows.is_empty());
    for row in rows {
        let RowText::Embedded(text) = &row.raw else {
            panic!("{}: an embedded row holds a heap copy", row.key);
        };
        let start = text.as_ptr();
        assert!(range.contains(&start), "{}: not a slice of the embedded text", row.key);
    }
    // Another text keeps owned compact rows that give back the same values.
    let parsed = Schema::parse(EMBEDDED).expect("parses");
    assert_eq!(parsed.schema_hash, Schema::embedded().schema_hash);
    for (owned, embedded) in parsed.rows.iter().zip(rows) {
        assert!(matches!(owned.raw, RowText::Owned(_)));
        assert_eq!(owned.raw(), embedded.raw(), "{}", owned.key);
        assert_eq!(owned, embedded, "{}", owned.key);
    }
}
