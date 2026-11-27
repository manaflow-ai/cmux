//! Parity with `HomeMessageRoutingTests`, `HomeMentionsTests`, `HomeComposerCheckTests` and the
//! composer source's gates.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("compose.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

#[test]
fn quoted_text_is_a_markdown_quote() {
    let out = op("routing.quoted", json!({"text": "error: build failed\n\nat main.swift:12"}));
    assert_eq!(out, "> error: build failed\n>\n> at main.swift:12\n\n");
}

#[test]
fn compose_adds_on_a_new_line() {
    assert_eq!(op("routing.compose", json!({"text": "hi", "own": ""})), "hi");
    assert_eq!(op("routing.compose", json!({"text": "\nhi", "own": "draft"})), "draft\nhi");
    assert_eq!(op("routing.compose", json!({"text": "hi", "own": "draft\n"})), "draft\nhi");
    assert_eq!(op("routing.compose", json!({"text": "hi", "listed": false})), Value::Null);
}

#[test]
fn mention_links_with_brackets_softened() {
    assert_eq!(
        op("routing.mention", json!({"title": "a [b]", "link": "cmux://c"})),
        "[a (b)](cmux://c) "
    );
    assert_eq!(
        op("routing.mention", json!({"title": " ", "link": "cmux://c"})),
        "[cmux://c](cmux://c) "
    );
}

#[test]
fn suggestions_source_names() {
    let out = op(
        "routing.suggestions",
        json!({"source": "homeMembers", "members": [{"id": "u", "name": "U", "source": "team"}]}),
    );
    assert_eq!(out["choices"], json!([{"value": "u", "title": "U"}]));
    assert_eq!(op("routing.suggestions", json!({"source": "nope"}))["source"], Value::Null);
}

#[test]
fn composer_source_refuses_other_conversations() {
    let ok = op("composerSource.snapshot", json!({"conversation": "cmux.home.new-message"}));
    assert_eq!(ok["ok"], true);
    let bad = op("composerSource.snapshot", json!({"conversation": "c1"}));
    assert_eq!(bad["ok"], false);
}

#[test]
fn compose_ops_are_listed() {
    let listed: Vec<String> =
        serde_json::from_value(call("ops.list", &json!({})).unwrap()).unwrap();
    let compose = listed.iter().filter(|n| n.starts_with("compose.")).count();
    assert!(compose >= 50, "{compose}");
}
