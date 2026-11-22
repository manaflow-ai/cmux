use std::path::PathBuf;

use serde_json::{Value, json};

use super::{
    DERIVED_FAILURE, Kind, declared_sizes, emptied, gallery, lengthen, long_text, render, widget,
};
use crate::cli::ext::design_system::System;

/// A VStack root holding a title and `rows` HStack rows of an icon and a label.
fn list(rows: usize) -> Value {
    let mut ops = vec![
        json!({"op": "create", "id": "root", "type": "VStack", "props": {"spacing": 4}}),
        json!({"op": "create", "id": "title", "type": "Text", "props": {"text": "To-do", "font": "headline", "lineLimit": 1}}),
    ];
    let mut children = vec![json!("title")];
    for i in 0..rows {
        let (row, icon, label) = (format!("r{i}"), format!("i{i}"), format!("t{i}"));
        ops.push(json!({"op": "create", "id": row, "type": "HStack", "props": {"spacing": 4}}));
        ops.push(
            json!({"op": "create", "id": icon, "type": "Icon", "props": {"symbol": "circle"}}),
        );
        ops.push(json!({"op": "create", "id": label, "type": "Text", "props": {"text": format!("Item {i}")}}));
        ops.push(json!({"op": "children", "id": row, "children": [icon, label]}));
        children.push(json!(row));
    }
    ops.push(json!({"op": "children", "id": "root", "children": children}));
    ops.push(json!({"op": "root", "id": "root"}));
    Value::Array(ops)
}

fn texts(ops: &[Value]) -> Vec<String> {
    ops.iter()
        .filter(|op| op["op"] == "create")
        .filter_map(|op| op["props"]["text"].as_str().map(str::to_string))
        .collect()
}

#[test]
fn a_state_name_says_what_it_shows() {
    assert_eq!(Kind::of("small"), Kind::Recorded);
    assert_eq!(Kind::of("small-clear-day"), Kind::Recorded);
    assert_eq!(Kind::of("medium-empty"), Kind::Empty);
    assert_eq!(Kind::of("small-no-network"), Kind::Error);
    assert_eq!(Kind::of("medium-offline"), Kind::Error);
    assert_eq!(Kind::of("medium-denied"), Kind::Error);
    assert_eq!(Kind::of("large-long-text"), Kind::LongText);
    // A word inside another does not count: "nonetheless" is not "none".
    assert_eq!(Kind::of("small-nonetheless"), Kind::Recorded);
}

#[test]
fn long_text_triples_words_and_keeps_numbers_and_case() {
    assert_eq!(lengthen("9:41"), "9:41");
    assert_eq!(lengthen("⛅️"), "⛅️");
    let long = lengthen("Lisbon");
    assert!(long.starts_with("Lisbon ") && long.chars().count() >= 28, "{long}");
    let upper = lengthen("MONDAY");
    assert_eq!(upper, upper.to_uppercase());
    let ops = long_text(&list(2)).unwrap();
    assert!(texts(&ops).iter().all(|t| t.chars().count() >= 28), "{:?}", texts(&ops));
}

#[test]
fn empty_takes_out_the_repeated_rows_and_keeps_the_rest() {
    let ops = emptied(&list(4)).unwrap();
    assert_eq!(texts(&ops), vec!["To-do"]);
    let root = ops.iter().find(|op| op["op"] == "children" && op["id"] == "root").unwrap();
    assert_eq!(root["children"], json!(["title"]));
    // Two rows are not a list, and a run of bare Texts is a layout, not rows.
    assert!(emptied(&list(2)).is_none());
}

#[test]
fn sizes_come_from_the_widget_interface_then_the_size_setting_then_the_recording() {
    let widget =
        json!({"implements": {"cmux.widget/1": {"options": {"sizes": ["large", "small"]}}}});
    assert_eq!(declared_sizes(&widget, &[]), vec!["small", "large"]);
    let section =
        json!({"settings": {"properties": {"size": {"enum": ["small", "medium", "large"]}}}});
    assert_eq!(declared_sizes(&section, &["small"]), vec!["small", "medium", "large"]);
    assert_eq!(declared_sizes(&Value::Null, &["medium"]), vec!["medium"]);
}

#[test]
fn each_declared_size_gets_long_text_empty_and_error_unless_the_widget_recorded_them() {
    let manifest = json!({"id": "local/todo", "name": {"en": "To-do"},
        "settings": {"properties": {"size": {"enum": ["small", "medium", "large"]}}}});
    let empty = list(0);
    let scenes = json!({
        "small": {"size": "small", "ops": list(4)},
        "medium": {"size": "medium", "ops": list(5)},
        "medium-empty": {"size": "medium", "ops": empty},
    });
    let record = widget("examples/extensions/todo", &manifest, &scenes, &System::cmux()).unwrap();
    let states: Vec<(String, String)> = record["states"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| (s["name"].as_str().unwrap().to_string(), s["kind"].as_str().unwrap().to_string()))
        .collect();
    let pairs: Vec<(&str, &str)> = states.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect();
    assert_eq!(
        pairs,
        vec![
            ("small", "recorded"),
            ("small-long-text", "long-text"),
            ("small-empty", "empty"),
            ("small-error", "error"),
            ("medium", "recorded"),
            ("medium-empty", "empty"),
            ("medium-long-text", "long-text"),
            ("medium-error", "error"),
        ]
    );
    let error = &record["states"][3];
    assert_eq!(error["failed"], DERIVED_FAILURE);
    assert_eq!(error["from"], "small");
    // Large is declared and not recorded: the gallery names what to record.
    assert_eq!(record["missing"][0]["size"], "large");
    // The long-text label has no lineLimit: the design check says so beside the tile.
    let long = &record["states"][1];
    assert!(
        long["warnings"].as_array().unwrap().iter().any(|w| w["check"] == "line-limit"),
        "{long}"
    );
}

#[test]
fn a_state_without_size_or_ops_is_refused_with_its_name() {
    let scenes = json!({"small": {"ops": []}});
    let problem = widget("w", &Value::Null, &scenes, &System::cmux()).unwrap_err();
    assert!(problem.contains("\"small\""), "{problem}");
}

#[test]
fn the_file_puts_one_op_per_line_and_reads_back_as_the_same_data() {
    let value = json!({"widgets": [{"states": [{"ops": [{"op": "root", "id": "a"}, {"op": "root", "id": "b"}]}]}]});
    let text = render(&value);
    assert!(text.contains("\n      {\"id\":\"a\",\"op\":\"root\"},\n"), "{text}");
    assert_eq!(serde_json::from_str::<Value>(&text).unwrap(), value);
}

/// The repository's widgets (`examples/extensions`) against the gallery's copy: run
/// `cmux ext preview examples/extensions --out webviews/src/apps/scene/fixtures/widget-previews.json`
/// from the repository root after changing a widget's preview/scenes.json.
#[test]
fn the_gallery_file_matches_the_example_widgets() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let examples = root.join("examples/extensions");
    let file = root.join("webviews/src/apps/scene/fixtures/widget-previews.json");
    if !examples.is_dir() || !file.is_file() {
        // A sparse checkout without them has nothing to compare.
        return;
    }
    // The file names folders as the command was given them: from the repository root.
    let fresh = gallery(&root, &[PathBuf::from("examples/extensions")]).unwrap();
    let committed: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert!(
        committed == fresh,
        "webviews/src/apps/scene/fixtures/widget-previews.json is stale: run cmux ext preview examples/extensions --out webviews/src/apps/scene/fixtures/widget-previews.json"
    );
}
