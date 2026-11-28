use super::*;

fn op(request: Value) -> Value {
    call("snapshot.read", &request).expect("an op of this area").expect("a reply")
}

#[test]
fn absent_keys_answer_their_default_without_a_diagnostic() {
    let reply = op(json!({ "root": {} }));
    assert_eq!(reply["diagnostics"], json!([]));
    assert_eq!(reply["values"]["browser.showAgentCursor"], json!(true));
    assert_eq!(reply["values"]["ui.calm"], json!("off"));
}

#[test]
fn a_bad_toggle_keeps_its_default_and_says_so() {
    let reply = op(json!({ "root": { "browser": { "showAgentCursor": "yes" } } }));
    assert_eq!(reply["values"]["browser.showAgentCursor"], json!(true));
    assert_eq!(
        reply["diagnostics"],
        json!([{ "kind": "invalid_value", "path": "browser.showAgentCursor",
                 "message": "expected true or false" }])
    );
}

#[test]
fn a_set_toggle_is_taken() {
    let reply = op(json!({ "root": { "browser": { "showAgentCursor": false } } }));
    assert_eq!(reply["values"]["browser.showAgentCursor"], json!(false));
    assert_eq!(reply["diagnostics"], json!([]));
}

#[test]
fn a_choice_lists_its_values_quoted_or_bare() {
    let bad = json!({ "root": { "ui": { "calm": "loud" } } });
    let reply = op(bad.clone());
    assert_eq!(reply["values"]["ui.calm"], json!("off"));
    assert_eq!(
        reply["diagnostics"][0]["message"],
        json!("expected one of \"off\", \"calm\", \"still\"")
    );
    let mut bare = bad;
    bare["unquoted"] = json!(["ui.calm"]);
    assert_eq!(op(bare)["diagnostics"][0]["message"], json!("expected one of off, calm, still"));
    let good = op(json!({ "root": { "ui": { "calm": "still" } } }));
    assert_eq!(good["values"]["ui.calm"], json!("still"));
}

#[test]
fn a_named_number_clamps_and_says_so() {
    let row = Schema::embedded()
        .rows
        .iter()
        .find(|row| matches!(row.kind, Kind::Number(_)))
        .expect("a number row");
    let Kind::Number(range) = &row.kind else { unreachable!() };
    let root = crate::value::with_value(&json!({}), json!(range.max + 1000.0), &row.path);
    let reply = op(json!({ "root": root, "keys": [row.key] }));
    assert_eq!(reply["values"][&row.key], json!(range.max));
    assert_eq!(
        reply["diagnostics"][0]["message"],
        json!(format!("clamped to {}...{}", swift_double(range.min), swift_double(range.max)))
    );
    let root = crate::value::with_value(&json!({}), json!("x"), &row.path);
    let reply = op(json!({ "root": root, "keys": [row.key] }));
    assert_eq!(reply["diagnostics"][0]["message"], json!("expected a number"));
}

#[test]
fn keys_limit_the_read() {
    let reply = op(json!({ "root": {}, "keys": ["ui.calm"] }));
    assert_eq!(reply["values"].as_object().map(Map::len), Some(1));
}

#[test]
fn a_source_is_parsed_and_a_broken_one_is_a_problem() {
    let reply = op(json!({ "source": "{ // c\n \"ui\": { \"calm\": \"calm\" } }" }));
    assert_eq!(reply["values"]["ui.calm"], json!("calm"));
    assert!(op(json!({ "source": "{ \"ui\": " }))["problem"].is_string());
}

#[test]
fn a_root_that_is_not_an_object_is_unreadable() {
    let reply = op(json!({ "root": [1] }));
    assert_eq!(reply["diagnostics"][0]["kind"], json!("unreadable_file"));
    assert_eq!(reply["diagnostics"][0]["message"], json!("root is not an object"));
}

#[test]
fn swift_doubles_keep_their_point() {
    assert_eq!(swift_double(0.0), "0.0");
    assert_eq!(swift_double(1.5), "1.5");
    assert_eq!(swift_double(1000.0), "1000.0");
}
