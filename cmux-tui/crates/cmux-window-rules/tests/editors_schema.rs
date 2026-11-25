//! `editor.default`'s choices in the settings schema are `auto` and the editor table's ids, in its
//! order, with its names: one list, so a new editor cannot be missing from either.

use cmux_window_rules::editors::EDITORS;
use serde_json::Value;

fn find<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Object(map) if map.get("key").and_then(Value::as_str) == Some(key) => Some(value),
        Value::Object(map) => map.values().find_map(|value| find(value, key)),
        Value::Array(items) => items.iter().find_map(|value| find(value, key)),
        _ => None,
    }
}

#[test]
fn the_settings_schema_lists_the_editor_table() {
    let schema: Value =
        serde_json::from_str(include_str!("../../../../schemas/settings/source/browser.json"))
            .unwrap();
    let row = find(&schema, "editor.default").expect("editor.default row");
    let choices: Vec<(&str, &str)> = row["choices"]
        .as_array()
        .unwrap()
        .iter()
        .map(|choice| {
            (choice["value"].as_str().unwrap(), choice["title"]["text"].as_str().unwrap())
        })
        .collect();
    let mut expected = vec![("auto", "The First Editor Found")];
    expected.extend(EDITORS.iter().map(|editor| (editor.id, editor.name)));
    assert_eq!(choices, expected);
}
