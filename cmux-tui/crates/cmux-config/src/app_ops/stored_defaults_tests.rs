use serde_json::json;

use super::*;

/// The Swift `SettingsSchema.unsetIsNotDefault` answers, pinned.
#[test]
fn a_reader_that_fills_the_key_keeps_its_written_default() {
    assert!(unset_is_not_default("editor.wordWrap"));
    assert!(unset_is_not_default("editor.autoClosingQuotes"));
    assert!(unset_is_not_default("agentPane.display.harnessPlacement"));
    assert!(!unset_is_not_default("editor.importFrom"));
    assert!(!unset_is_not_default("editor"));
    assert!(!unset_is_not_default("agentPane.display.harnessPlacementX"));
    assert!(!unset_is_not_default("appearance.chromeStyle"));
    let keys = call("stored_defaults.unset_is_not_default_keys", &json!({})).unwrap().unwrap();
    assert_eq!(keys["keys"].as_object().map(|keys| keys.len()), Some(2));
    let answer = call("stored_defaults.unset_is_not_default", &json!({"key": "editor.tabSize"}));
    assert_eq!(answer, Some(Ok(json!({ "is": true }))));
}

/// The Swift `storedDefaultsRecord` text, pinned: sorted keys, two spaces, a
/// final line break.
#[test]
fn the_record_names_what_went_what_stayed_and_the_text_before() {
    let request = json!({
        "dropped": {"appearance.chromeStyle": "flat-sidebar-line"},
        "kept": {"theme": "tokyo", "updates.downloadAutomatically": true},
        "before": "{\n  \"theme\": \"tokyo\"\n}\n",
    });
    let text = call("stored_defaults.record", &request).unwrap().unwrap()["text"].clone();
    let want = "{\n  \"before\": \"{\\n  \\\"theme\\\": \\\"tokyo\\\"\\n}\\n\",\n  \"dropped\": {\n    \
\"appearance.chromeStyle\": \"flat-sidebar-line\"\n  },\n  \"kept\": {\n    \"theme\": \"tokyo\",\n    \
\"updates.downloadAutomatically\": true\n  },\n  \"note\": \"cmux dropped these stored copies of defaults \
once, so each key follows its default again. To keep one, set it again in Settings or copy it back from \
`before`.\"\n}\n";
    assert_eq!(text, json!(want));
    let empty = record(&Map::new(), &Map::new(), "");
    assert!(empty.contains("\"dropped\": {},\n  \"kept\": {},"), "{empty}");
}

/// The Swift `settled`, pinned: a candidate the write left (someone set it
/// since the read) moves to kept with its value at the write; one the file
/// no longer holds keeps the value read; a removed one stays dropped.
#[test]
fn a_key_set_since_the_read_is_kept_with_its_new_value() {
    let request = json!({
        "dropped": {"a.x": 1, "b.y": true, "c.z": "old"},
        "kept": {"theme": "tokyo"},
        "candidates": [
            {"id": "a.x", "path": ["a", "x"], "value": 1},
            {"id": "b.y", "path": ["b", "y"], "value": true},
            {"id": "c.z", "path": ["c", "z"], "value": "old"},
        ],
        "removed": [["a", "x"]],
        "before": "{ // set since\n \"b\": {\"y\": false}, }",
    });
    let answer = call("stored_defaults.settled", &request).unwrap().unwrap();
    assert_eq!(answer["dropped"], json!({"a.x": 1}));
    assert_eq!(answer["kept"], json!({"theme": "tokyo", "b.y": false, "c.z": "old"}));
}

/// A `before` that does not parse keeps each value read.
#[test]
fn an_unreadable_file_keeps_the_values_read() {
    let request = json!({
        "dropped": {"a.x": 1},
        "kept": {},
        "candidates": [{"id": "a.x", "path": ["a", "x"], "value": 1}],
        "removed": [],
        "before": "{ not json",
    });
    let answer = call("stored_defaults.settled", &request).unwrap().unwrap();
    assert_eq!(answer, json!({"dropped": {}, "kept": {"a.x": 1}}));
}
