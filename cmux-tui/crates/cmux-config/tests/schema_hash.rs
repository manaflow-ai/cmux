//! `schema_hash` is computed when the schema loads, not read from the export:
//! a committed hash line changed in every settings pull request, so two of
//! them could never merge (#21946). It is SHA-256 of the rows as compact JSON,
//! lowercase hex, and moves exactly when a row does.

use cmux_config::Schema;
use serde_json::{Value, json};

fn document(rows: Value) -> String {
    json!({"version": 1, "sections": [], "page": {"categories": []}, "rows": rows}).to_string()
}

fn row(key: &str, default: bool) -> Value {
    json!({
        "key": key, "path": key.split('.').collect::<Vec<_>>(), "section": "general",
        "group": {"text": "Group", "key": "group"}, "title": {"text": "Title", "key": "title"},
        "kind": "toggle", "default": default, "keywords": [], "agent_settable": false,
        "kept_on_reset_all": false, "validation": "portable", "accepts": [true, false], "refuses": ["yes"],
    })
}

#[test]
fn a_document_without_a_schema_hash_parses_and_hashes_its_rows() {
    let rows = json!([row("terminal.bell", true)]);
    let schema = Schema::parse(&document(rows.clone())).expect("parses");
    let hash = schema.schema_hash;
    assert_eq!(hash.len(), 64, "{hash}");
    assert!(
        hash.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "{hash}"
    );
    assert_eq!(
        Schema::parse(&document(rows)).expect("parses").schema_hash,
        hash,
        "same rows, same hash"
    );
}

#[test]
fn the_schema_hash_moves_when_a_row_does_and_not_otherwise() {
    let base =
        Schema::parse(&document(json!([row("terminal.bell", true)]))).expect("parses").schema_hash;
    let changed =
        Schema::parse(&document(json!([row("terminal.bell", false)]))).expect("parses").schema_hash;
    assert_ne!(base, changed);
    let mut renamed = serde_json::from_str::<Value>(&document(json!([row("terminal.bell", true)])))
        .expect("json");
    renamed["version"] = json!(2);
    renamed["sections"] = json!([{"id": "general", "title": {"text": "General", "key": "general"}, "symbol": "gear"}]);
    assert_eq!(
        Schema::parse(&renamed.to_string()).expect("parses").schema_hash,
        base,
        "only rows count"
    );
}

#[test]
fn the_embedded_schema_has_a_hash_and_no_committed_one() {
    assert_eq!(Schema::embedded().schema_hash.len(), 64);
    let committed: Value =
        serde_json::from_str(include_str!("../../../../schemas/settings/settings-schema.json"))
            .expect("json");
    assert!(
        committed.get("schema_hash").is_none(),
        "settings-schema.json still commits schema_hash"
    );
}
