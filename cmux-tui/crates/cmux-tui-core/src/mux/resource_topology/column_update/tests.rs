use super::*;

const COLUMN: &str = "split_00000000000000000000000000000011";

fn parse(fields: Value) -> anyhow::Result<ColumnUpdate> {
    ColumnUpdate::parse(fields.as_object().unwrap())
}

fn code(error: anyhow::Error) -> String {
    error.downcast_ref::<ResourceError>().map(|error| error.code.clone()).unwrap_or_default()
}

/// The router's catalog check rejects wrong types first, but the parser
/// must not read a wrong type as an absent field either.
#[test]
fn column_update_parse_rejects_wrong_field_types() {
    for fields in [
        serde_json::json!({"column": COLUMN, "dock": "true", "width": 0.5}),
        serde_json::json!({"column": COLUMN, "dock": 1, "width": 0.5}),
        serde_json::json!({"column": COLUMN, "width": "0.5", "dock": true}),
        serde_json::json!({"column": COLUMN, "dock": true, "edge": 1}),
        serde_json::json!({"column": COLUMN, "dock": true, "mode": false}),
        serde_json::json!({"column": COLUMN, "dock": null, "width": 0.5}),
    ] {
        let error = parse(fields.clone()).err().unwrap_or_else(|| panic!("{fields} parsed"));
        assert_eq!(code(error), "validation.invalid", "{fields}");
    }
}

#[test]
fn column_update_parse_reads_pinned_and_allow_tabs() {
    let update =
        parse(serde_json::json!({"column": COLUMN, "pinned": true, "allow_tabs": false})).unwrap();
    assert_eq!((update.pinned, update.allow_tabs), (Some(true), Some(false)));
    let unpin = parse(serde_json::json!({"column": COLUMN, "pinned": false})).err().unwrap();
    assert_eq!(code(unpin), "validation.invalid", "a pinned column stays pinned");
    let typed = parse(serde_json::json!({"column": COLUMN, "allow_tabs": "yes"})).err().unwrap();
    assert_eq!(code(typed), "validation.invalid");
}

#[test]
fn column_update_parse_accepts_well_typed_fields() {
    let update = parse(serde_json::json!({
        "column": COLUMN,
        "dock": true,
        "edge": "left",
        "mode": "overlay",
        "width": 0.5,
    }))
    .unwrap();
    assert!(update.dock.flatten().is_some());
    assert_eq!(update.width, Some(0.5));
}
