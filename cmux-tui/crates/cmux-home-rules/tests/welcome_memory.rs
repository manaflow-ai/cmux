//! Parity with `ChiefMemoryInspectorModelTests`: the decoders, the calls each action makes, the trail.

use cmux_home_rules::call;
use cmux_home_rules::welcome::memory::{Target, decode, open_trail, reload_calls};
use serde_json::{Value, json};

fn changes() -> Value {
    json!({"changes": [
        {"id": 2, "at": "t2", "op": "delete", "target": {"node": "0+8"}, "old": "x", "new": "(deleted by the user)", "stale": [], "undone": true},
        {"id": 1, "at": "t1", "op": "edit", "target": {"message": 5}, "old": "secret", "new": "fine", "stale": ["4+4"], "undone": false}
    ], "stale": ["4+4"]})
}

fn node() -> Value {
    json!({"name": "4+1", "level": 0, "start": 4, "n": 1, "built": true, "text": "user: hello",
           "message": {"id": 4, "kind": "user", "text": "hello there", "bytes": 11}})
}

#[test]
fn reload_reads_the_counts_the_view_and_the_changes() {
    let calls = serde_json::to_value(reload_calls(&[])).unwrap();
    assert_eq!(
        calls,
        json!([
            {"path": "/api/status", "query": {}},
            {"path": "/api/view", "query": {}},
            {"path": "/api/memory/changes", "query": {}},
        ])
    );
    let status = decode(
        "status",
        &json!({"messages": 64, "nodes_built": 127, "stale": ["4+4"], "editable": true}),
    )
    .unwrap();
    assert_eq!(status["messages"], 64);
    assert_eq!(status["editable"], true);
    let view = decode("view", &json!({"lines": [
        {"name": "0+32", "level": 5, "start": 0, "n": 32, "built": true, "text": "the start"},
        {"name": "32+32", "level": 5, "start": 32, "n": 32, "built": true, "text": "later", "stale": true}]})).unwrap();
    let names: Vec<&str> =
        view["lines"].as_array().unwrap().iter().map(|l| l["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["0+32", "32+32"]);
    assert_eq!(view["lines"][1]["stale"], true);
    let decoded = decode("changes", &changes()).unwrap();
    assert_eq!(decoded["changes"][0]["id"], 2);
    assert_eq!(decoded["changes"][1]["target"], json!({"message": 5}));
    assert_eq!(decoded["changes"][0]["target"], json!({"node": "0+8"}));
    let stale = call("welcome.memoryIsStale", &json!({"status": status, "name": "4+4"})).unwrap();
    assert_eq!(stale["stale"], true);
    assert_eq!(
        serde_json::to_value(reload_calls(&["0+8".into()])).unwrap()[3]["query"]["name"],
        "0+8"
    );
}

#[test]
fn opening_a_line_zooms_and_back_returns() {
    let mut trail = open_trail(&[], "0+8");
    trail = open_trail(&trail, "4+1");
    assert_eq!(trail, ["0+8", "4+1"]);
    let text =
        call("welcome.memoryTextOf", &json!({"target": {"message": 4}, "detail": node()})).unwrap();
    assert_eq!(text["text"], "hello there");
    let out = call("welcome.memoryOpen", &json!({"trail": trail, "name": "0+8"})).unwrap();
    assert_eq!(out["trail"], json!(["0+8"]), "opening a node on the trail cuts the trail there");
    assert_eq!(out["call"], json!({"path": "/api/node", "query": {"name": "0+8"}}));
    let back = call("welcome.memoryBack", &json!({"trail": ["0+8"]})).unwrap();
    assert_eq!(back, json!({"changed": true, "clearDetail": true, "call": null, "trail": []}));
    let back = call("welcome.memoryBack", &json!({"trail": ["0+8", "4+1"]})).unwrap();
    assert_eq!(back["call"]["query"]["name"], "0+8");
}

#[test]
fn an_edit_sends_the_target_and_text_then_reads_again() {
    let start = call("welcome.memoryTextOf", &json!({"target": {"node": "4+1"}, "detail": node()}))
        .unwrap();
    assert_eq!(start["text"], "user: hello", "the edit starts from the current text");
    let out = call(
        "welcome.memoryChangeCall",
        &json!({"action": "edit", "target": {"message": 4}, "text": "hello, edited"}),
    )
    .unwrap();
    assert_eq!(
        out["call"],
        json!({"path": "/api/memory/edit", "query": {"target": "message:4", "text": "hello, edited"}})
    );
    assert_eq!(out["reloadAfter"], true);
    assert_eq!(out["endEditAfter"], true);
}

#[test]
fn a_delete_names_its_target() {
    let out =
        call("welcome.memoryChangeCall", &json!({"action": "delete", "target": {"message": 5}}))
            .unwrap();
    assert_eq!(
        out["call"],
        json!({"path": "/api/memory/delete", "query": {"target": "message:5"}})
    );
    assert_eq!(out["endEditAfter"], false);
}

#[test]
fn undo_last_undoes_the_newest_change_not_yet_undone() {
    let decoded = decode("changes", &changes()).unwrap();
    let out = call("welcome.memoryUndoLast", &json!({"changes": decoded["changes"]})).unwrap();
    assert_eq!(
        out["call"],
        json!({"path": "/api/memory/undo", "query": {"change": "1"}}),
        "change 2 is already undone"
    );
    let out = call("welcome.memoryChangeCall", &json!({"action": "undo", "change": 2})).unwrap();
    assert_eq!(out["call"]["query"], json!({"change": "2"}));
}

#[test]
fn errors_describe_themselves() {
    let refused = call(
        "welcome.memoryDescribe",
        &json!({"error": {"kind": "refused", "message": "the new text is 600 bytes; at most 512 fit here"}}),
    )
    .unwrap();
    assert_eq!(refused["text"], "the new text is 600 bytes; at most 512 fit here");
    let unreachable =
        call("welcome.memoryDescribe", &json!({"error": {"kind": "unreachable"}})).unwrap();
    assert!(!unreachable["text"].as_str().unwrap().is_empty());
    let bad = call("welcome.memoryDecode", &json!({"kind": "status", "body": "not json"})).unwrap();
    assert_eq!(bad["malformed"], true);
}

#[test]
fn search_trims_and_an_empty_query_clears() {
    let out = call("welcome.memorySearch", &json!({"query": "  secret "})).unwrap();
    assert_eq!(out["call"], json!({"path": "/api/search", "query": {"q": "secret"}}));
    assert_eq!(call("welcome.memorySearch", &json!({"query": "  "})).unwrap()["clearHits"], true);
    let hits = decode(
        "search",
        &json!({"hits": [{"type": "message", "id": 5, "kind": "user", "snippet": "my [secret]", "name": "5+1"}]}),
    );
    assert!(hits.is_some());
}

#[test]
fn targets_name_the_change_paths_query() {
    assert_eq!(Target::Message(42).query_value(), "message:42");
    assert_eq!(Target::Line("0+8".into()).query_value(), "node:0+8");
    let both =
        call("welcome.memoryTargetQuery", &json!({"target": {"message": 1, "node": "x"}})).unwrap();
    assert_eq!(both["query"], "message:1", "a message wins, as in Swift");
}
