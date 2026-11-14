use cmux_config::{EditKind, MAX_EDITS, Target};
use serde_json::{Map, Value, json};

use super::{edits, schema_json};

fn fields(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(members) => members,
        _ => Map::new(),
    }
}

/// `settings.edit`'s `edits` become the owner's edits in order; `value`
/// is the value set or expected, JSON null included.
#[test]
fn settings_edit_reads_each_edit_kind() {
    let parsed = edits(&fields(json!({"edits": [
        {"op": "set", "key": "appearance.chromeStyle", "value": "card"},
        {"op": "set_unset", "path": ["layout", "panePadding"], "value": 4},
        {"op": "reset", "key": "appearance.backdropArt"},
        {"op": "reset_unchanged", "key": "appearance.backgroundBlur", "value": null},
    ]})))
    .expect("the edits parse");
    let kinds: Vec<_> = parsed.iter().map(|edit| edit.kind.clone()).collect();
    assert_eq!(
        kinds,
        vec![
            EditKind::Set(json!("card")),
            EditKind::SetUnset(json!(4)),
            EditKind::Reset,
            EditKind::ResetUnchanged(Value::Null),
        ]
    );
    assert_eq!(
        parsed.get(1).map(|edit| edit.target.clone()),
        Some(Target::Path(vec!["layout".to_string(), "panePadding".to_string()]))
    );
}

/// A malformed edit is validation.invalid, before the owner sees the op.
#[test]
fn settings_edit_refuses_a_malformed_edit() {
    let too_many: Vec<Value> =
        (0..=MAX_EDITS).map(|_| json!({"op": "reset", "key": "a.b"})).collect();
    for bad in [
        json!({}),
        json!({"edits": []}),
        json!({"edits": too_many}),
        json!({"edits": [{"op": "reset", "key": "a.b", "value": 1}]}),
        json!({"edits": [{"op": "set", "key": "a.b"}]}),
        json!({"edits": [{"op": "set_unset", "key": "a.b"}]}),
        json!({"edits": [{"op": "move", "key": "a.b", "value": 1}]}),
        json!({"edits": [{"key": "a.b", "value": 1}]}),
        json!({"edits": [{"op": "set", "value": 1}]}),
        json!({"edits": [{"op": "set", "key": "a.b", "path": ["a", "b"], "value": 1}]}),
        json!({"edits": [{"op": "set", "key": "a.b", "value": 1, "if_unset": true}]}),
        json!({"edits": ["a.b"]}),
    ] {
        let error = edits(&fields(bad.clone())).err();
        assert_eq!(
            error.as_ref().map(|error| error.code.as_str()),
            Some("validation.invalid"),
            "{bad}"
        );
    }
}

/// `settings.schema` carries each row's one-line `summary` (the only
/// text a Settings row draws under its title) apart from the long
/// `help`, and the typed schema row reads the same line.
#[test]
fn settings_schema_rows_carry_the_summary_line() {
    let wire = schema_json();
    let rows = wire["rows"].as_array().expect("settings.schema lists rows");
    let row = rows
        .iter()
        .find(|row| row["key"] == "appearance.backdropArt")
        .expect("appearance.backdropArt is a schema row");
    assert_eq!(row["summary"]["text"], "Painting behind the window", "{row}");
    assert_eq!(row["summary"]["key"], "settings.appearance.backdropArt.summary", "{row}");
    assert_ne!(row["summary"], row["help"], "the summary is not the help text");

    let schema = cmux_config::Schema::embedded();
    let typed = schema.row("appearance.backdropArt").and_then(|row| row.summary.as_ref());
    assert_eq!(typed.map(|text| text.text.as_str()), Some("Painting behind the window"));
    assert_eq!(
        typed.and_then(|text| text.key.as_deref()),
        Some("settings.appearance.backdropArt.summary")
    );
    for row in &schema.rows {
        if let Some(summary) = &row.summary {
            assert!(
                summary.text.chars().count() <= 60,
                "{}: a summary is one line of at most 60 characters",
                row.key
            );
        }
    }
}
