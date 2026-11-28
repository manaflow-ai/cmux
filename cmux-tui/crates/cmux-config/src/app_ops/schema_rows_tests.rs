//! `schema.rows` answers what the per-row ops answer, for many rows in one call.

use serde_json::{Value, json};

use crate::app_ops::{OpError, call};
use crate::schema::Schema;

fn op(name: &str, request: Value) -> Value {
    call(name, &request).unwrap_or_else(|error| panic!("{name} {request}: {error:?}"))
}

fn rows(request: Value) -> Vec<Value> {
    let answer = op("schema.rows", request);
    answer["rows"].as_array().cloned().unwrap_or_else(|| panic!("no rows: {answer}"))
}

#[test]
fn every_row_matches_the_per_row_ops() {
    let root = json!({
        "terminal": {"fontSize": 15, "cursorStyle": "nonsense"},
        "appearance": {"background": "daily"},
        "sidebar": {"workspaceRow": {"secondLineOrder": ["branch"]}},
    });
    let file = json!({"terminal": {"fontSize": 15}});
    let all = rows(json!({"root": root, "stored_root": file}));
    assert_eq!(all.len(), Schema::embedded().rows.len());
    for answer in &all {
        let key = answer["key"].as_str().expect("key");
        let read = |name: &str, root: &Value| op(name, json!({"key": key, "root": root}));
        assert_eq!(answer["stored"], read("schema.stored", &file)["value"], "{key}");
        assert_eq!(answer["effective"], read("schema.effective", &root)["value"], "{key}");
        assert_eq!(answer["customized"], read("schema.customized", &file)["customized"], "{key}");
        assert_eq!(answer["toggled"], read("schema.toggled", &root)["value"], "{key}");
        assert_eq!(answer["inherited"], read("schema.inherited", &root)["value"], "{key}");
        assert!(answer.get("options").is_none(), "{key}");
    }
}

#[test]
fn keys_keep_their_order_and_a_section_filters() {
    let keys = ["terminal.fontSize", "appearance.theme"];
    let answered: Vec<Value> =
        rows(json!({"root": {}, "keys": keys})).iter().map(|row| row["key"].clone()).collect();
    assert_eq!(answered, json!(keys).as_array().cloned().expect("keys"));

    let section = &Schema::embedded().rows[0].section;
    let in_section = rows(json!({"root": {}, "section": section}));
    let expected = Schema::embedded().rows.iter().filter(|row| &row.section == section).count();
    assert_eq!(in_section.len(), expected);
    assert!(matches!(
        call("schema.rows", &json!({"root": {}, "keys": ["no.such"]})),
        Err(OpError::Invalid(_))
    ));
}

#[test]
fn the_palette_matches_the_per_row_options() {
    let root = json!({"terminal": {"cursorStyle": "bar"}});
    let palette = json!({"theme_colors": [{"red": 1.0, "green": 0.0, "blue": 0.0}]});
    let all = rows(json!({"root": root, "palette": palette}));
    for answer in &all {
        let key = answer["key"].as_str().expect("key");
        let single = op(
            "schema.palette_options",
            json!({
                "key": key,
                "current": answer["effective"],
                "inherited": answer["inherited"],
                "theme_colors": palette["theme_colors"],
            }),
        );
        assert_eq!(answer["options"], single["options"], "{key}");
        assert_eq!(answer["summary"], single["summary"], "{key}");
    }
}

#[test]
fn a_pending_value_is_the_palette_s_current_one() {
    let key = "editor.cursorStyle";
    let pending = rows(json!({
        "root": {}, "keys": [key], "palette": {"current": {key: "underline"}},
    }));
    let single = op("schema.palette_options", json!({"key": key, "current": "underline"}));
    assert_eq!(pending[0]["options"], single["options"]);
}

#[test]
fn every_need_is_asked_at_once_then_answered() {
    let background = "appearance.background";
    let root = json!({"appearance": {"backdropArt": "wheat-field-with-cypresses"}});
    let keys = json!([background, "terminal.fontSize"]);
    let need = op("schema.rows", json!({"root": root, "keys": keys}));
    assert_eq!(need["need"]["arts"], json!(["wheat-field-with-cypresses"]));

    let arts = json!({"wheat-field-with-cypresses": "van-gogh-starry-night"});
    let answered = rows(json!({"root": root, "keys": keys, "arts": arts}));
    assert_eq!(answered[0]["stored"], json!("van-gogh-starry-night"));

    let own = json!({"appearance": {"background": "file:///tmp/me.png"}});
    let need = op("schema.rows", json!({"root": own, "keys": keys, "palette": {}}));
    assert_eq!(need["need"]["selections"], json!(["file:///tmp/me.png"]));
    let selections = json!({"file:///tmp/me.png": {"id": "file:///tmp/me.png", "title": "me.png"}});
    let answered = rows(json!({"root": own, "keys": keys, "palette": {"selections": selections}}));
    let single = op(
        "schema.palette_options",
        json!({
            "key": background,
            "current": "file:///tmp/me.png",
            "selection": selections["file:///tmp/me.png"],
        }),
    );
    assert_eq!(answered[0]["options"], single["options"]);
}
