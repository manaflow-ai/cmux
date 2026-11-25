//! The palette's scope navigation over the C ABI, as the macOS app calls it: `scopeGraph` and
//! `navReduce` requests in the JSON the Swift value types synthesize (`PaletteScopeDescriptor`,
//! `PaletteNavState`, `PaletteNavEvent`), answered on a ranker handle with no entries installed.
//! Pins the behaviour the Swift `PaletteNavReducer` and `PaletteScopeGraph` had before they moved.

use cmux_palette_ranker::ffi::{
    OK, cmux_palette_ranker_free, cmux_palette_ranker_new, cmux_palette_ranker_rank,
};
use serde_json::{Value, json};

fn call(request: &Value) -> (i32, Value) {
    let bytes = serde_json::to_vec(request).unwrap();
    let ranker = cmux_palette_ranker_new();
    let (mut response, mut response_len) = (std::ptr::null(), 0usize);
    // SAFETY: a live handle, readable request bytes and writable out pointers.
    let code = unsafe {
        cmux_palette_ranker_rank(
            ranker,
            bytes.as_ptr(),
            bytes.len(),
            &mut response,
            &mut response_len,
        )
    };
    // SAFETY: the response stays valid until the next call on this handle.
    let answer = unsafe { std::slice::from_raw_parts(response, response_len) }.to_vec();
    // SAFETY: the handle from `cmux_palette_ranker_new`, freed once.
    unsafe { cmux_palette_ranker_free(ranker) };
    let value = serde_json::from_slice(&answer)
        .unwrap_or(Value::String(String::from_utf8_lossy(&answer).into()));
    (code, value)
}

fn descriptor(id: &str, prefix: Option<&str>, keywords: &[&str], parents: Value) -> Value {
    let mut value = json!({
        "id": id, "title": id, "symbol": "command", "placeholder": "",
        "keywords": keywords, "parents": parents, "emptyQuerySelection": 0, "owner": "client",
    });
    if let Some(prefix) = prefix {
        value["prefix"] = json!(prefix);
    }
    value
}

fn graph() -> Value {
    let (code, graph) = call(&json!({
        "operation": "scopeGraph",
        "root": descriptor("root", None, &[], json!({"root": {}})),
        "scopes": [
            descriptor("tabs", Some("@"), &["tabs"], json!({"root": {}})),
            descriptor("workspaces", Some("#"), &["ws"], json!({"root": {}})),
            descriptor("actions", Some(">"), &["actions"], json!({"anywhere": {}})),
            descriptor("late", Some("@"), &["tabs", "late"], json!({"only": {"_0": ["root"]}})),
        ],
        "assigned": {"workspaces": "%", "actions": "x"},
    }));
    assert_eq!(code, OK, "{graph}");
    graph
}

#[test]
fn scope_graph_applies_user_prefixes_and_reports_collisions() {
    let graph = graph();
    let prefixes: Vec<_> =
        graph["scopes"].as_array().unwrap().iter().map(|s| s["prefix"].clone()).collect();
    assert_eq!(prefixes, [json!("@"), json!("%"), json!(">"), Value::Null]);
    assert_eq!(graph["scopes"][3]["keywords"], json!(["late"]));
    assert_eq!(graph["root"]["parents"], json!({"only": {"_0": []}}));
    assert_eq!(
        graph["problems"],
        json!([
            {"prefixCollision": {"_0": "late", "with": "tabs", "prefix": "@"}},
            {"keywordCollision": {"_0": "late", "with": "tabs", "keyword": "tabs"}},
        ])
    );
}

struct Palette {
    graph: Value,
    state: Value,
}

impl Palette {
    fn send(&mut self, event: Value) -> Value {
        let (code, reply) = call(&json!({
            "operation": "navReduce",
            "graph": self.graph,
            "config": {"prefixEntry": true, "keywordEntry": true, "maxDepth": 8},
            "state": self.state,
            "event": event,
        }));
        assert_eq!(code, OK, "{reply}");
        self.state = reply["state"].clone();
        reply["effects"].clone()
    }

    fn top(&self) -> &Value {
        self.state["levels"].as_array().unwrap().last().unwrap()
    }
}

#[test]
fn a_session_through_the_c_abi() {
    let mut palette =
        Palette { graph: graph(), state: json!({"isOpen": false, "levels": [], "nextLevelID": 1}) };
    assert_eq!(
        palette.send(json!({"open": {"query": ""}})),
        json!([{"load": {"levelID": 1, "scope": "root", "query": "", "generation": 1}}])
    );
    // The batch for generation 1 selects the first row.
    palette.send(json!({"results": {"levelID": 1, "generation": 1, "replace": true, "isFinal": true,
        "provisional": false, "rows": [{"id": "a", "isEnabled": true}, {"id": "b", "isEnabled": true}]}}));
    assert_eq!(palette.top()["selection"], "a");
    // A typed prefix enters Tabs with the rest of the text.
    assert_eq!(
        palette.send(json!({"setQuery": {"_0": "@foo", "allowsScopeEntry": true}})),
        json!([
            {"load": {"levelID": 2, "scope": "tabs", "query": "foo", "generation": 1}},
            {"announceEntered": {"_0": "tabs"}},
        ])
    );
    assert_eq!(palette.top()["entry"], json!({"prefix": {"_0": "@"}}));
    // Escape pops back to the root, which reloads and keeps its row.
    assert_eq!(
        palette.send(json!({"escape": {}})),
        json!([
            {"cancel": {"levelID": 2}},
            {"load": {"levelID": 1, "scope": "root", "query": "", "generation": 2}},
            {"announceLeft": {"to": "root"}},
        ])
    );
    assert_eq!(palette.top()["selection"], "a");
    // Return on stale rows waits; the fresh batch runs its default row.
    palette.send(json!({"setQuery": {"_0": "b", "allowsScopeEntry": true}}));
    assert_eq!(palette.send(json!({"activate": {}})), json!([]));
    assert_eq!(
        palette.send(
            json!({"results": {"levelID": 1, "generation": 3, "replace": true, "isFinal": true,
            "provisional": false, "rows": [{"id": "b", "isEnabled": true}]}})
        ),
        json!([{"run": {"levelID": 1, "rowID": "b"}}])
    );
    // Escape clears the text, then closes and dismisses.
    palette.send(json!({"escape": {}}));
    assert_eq!(
        palette.send(json!({"escape": {}})),
        json!([{"cancel": {"levelID": 1}}, {"dismiss": {}}])
    );
    assert_eq!(palette.state["isOpen"], false);
}

#[test]
fn a_bad_request_is_refused_not_a_panic() {
    let (code, _) = call(&json!({"operation": "navReduce", "graph": {}, "event": {"nope": {}}}));
    assert_eq!(code, cmux_palette_ranker::ffi::ERR_INVALID);
}
