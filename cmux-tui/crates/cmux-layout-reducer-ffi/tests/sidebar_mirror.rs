//! The sidebar mirror through the C ABI the app calls
//! (`cmux_sidebar_mirror_*`): a confirmed document, an optimistic move that
//! shows at once, its echoed batch that confirms it, a refused intent, a
//! revision gap, and the drop acceptance table of a drag.

use std::ffi::CStr;

use cmux_layout_reducer_ffi::sidebar_mirror::Mirror;
use cmux_layout_reducer_ffi::{
    cmux_sidebar_mirror_apply_batch, cmux_sidebar_mirror_apply_intent,
    cmux_sidebar_mirror_drag_begin, cmux_sidebar_mirror_free, cmux_sidebar_mirror_load,
    cmux_sidebar_mirror_new, cmux_sidebar_mirror_string_free, cmux_sidebar_mirror_view,
};
use serde_json::{Value, json};

type Entry = unsafe extern "C" fn(*mut Mirror, *const u8, usize) -> *mut std::ffi::c_char;

fn call(mirror: *mut Mirror, entry: Entry, input: &Value) -> Value {
    let bytes = serde_json::to_vec(input).unwrap();
    // SAFETY: a live mirror and a readable buffer; the result is freed once.
    unsafe {
        let text = entry(mirror, bytes.as_ptr(), bytes.len());
        assert!(!text.is_null());
        let value = serde_json::from_slice(CStr::from_ptr(text).to_bytes()).unwrap();
        cmux_sidebar_mirror_string_free(text);
        value
    }
}

fn workspace(id: &str, section: &str, session: &str, order: &str) -> Value {
    json!({"id": id, "section": section, "order": order,
           "body": {"type": "workspace", "ref": {"session_id": session, "workspace_id": id}}})
}

fn doc() -> Value {
    json!({
        "revision": "4",
        "sections": [
            {"id": "sec_pinned", "kind": {"type": "pinned"}, "region": "top", "order": "V",
             "shows_title": false, "keeps_closed": true},
            {"id": "sec_m_a", "kind": {"type": "machine", "session_id": "a"}, "order": "V"},
            {"id": "sec_m_b", "kind": {"type": "machine", "session_id": "b"}, "order": "W", "title": "B"},
        ],
        "items": [
            workspace("ws_1", "sec_m_a", "a", "V"),
            workspace("ws_2", "sec_m_a", "a", "W"),
            workspace("ws_3", "sec_m_b", "b", "V"),
        ],
    })
}

fn live() -> Value {
    json!({"live": [
        {"session_id": "a", "workspace_id": "ws_1", "title": "one"},
        {"session_id": "a", "workspace_id": "ws_2", "title": "two"},
        {"session_id": "b", "workspace_id": "ws_3", "title": "three"},
    ]})
}

fn keys(rows: &Value) -> Vec<String> {
    rows.as_array().unwrap().iter().map(|row| row["key"].as_str().unwrap().to_string()).collect()
}

#[test]
fn mirror_shows_intents_until_their_echo_and_refuses_cross_machine() {
    let mirror = cmux_sidebar_mirror_new();
    assert_eq!(call(mirror, cmux_sidebar_mirror_load, &doc())["revision"], "4");
    let rows = call(mirror, cmux_sidebar_mirror_view, &live());
    assert_eq!(keys(&rows), ["sec_m_a", "ws_1", "ws_2", "sec_m_b", "ws_3"]);

    // An optimistic pin shows at once; Pinned draws no header.
    let pin = json!({"idempotency_key": "k1", "ops": [{"op": "pin", "items": ["ws_2"]}]});
    let applied = call(mirror, cmux_sidebar_mirror_apply_intent, &pin);
    assert_eq!(applied["ok"], true, "{applied}");
    let rows = call(mirror, cmux_sidebar_mirror_view, &live());
    assert_eq!(keys(&rows), ["ws_2", "sec_m_a", "ws_1", "sec_m_b", "ws_3"]);

    // A cross-machine move is refused and leaves the rows as they were.
    let cross = json!({"idempotency_key": "k2", "ops": [{"op": "move", "items": ["ws_3"],
        "to": {"section": "sec_m_a"}}]});
    assert_eq!(call(mirror, cmux_sidebar_mirror_apply_intent, &cross)["refusal"], "cross_machine");

    // The acceptance table: ws_3 may go to Pinned but not into machine a.
    let table = call(mirror, cmux_sidebar_mirror_drag_begin, &json!({"items": ["ws_3"]}));
    assert_eq!(table["ws_2"]["before"], true, "{table}");
    assert_eq!(table["ws_1"]["refusal"], "cross_machine");
    assert_eq!(table["ws_3"]["refusal"], "self");

    // A batch with a revision gap asks for a refetch and changes nothing.
    let gap = json!({"revision": "7", "previous_revision": "6", "changes": []});
    assert_eq!(call(mirror, cmux_sidebar_mirror_apply_batch, &gap)["refetch"], true);

    // The echo: the daemon's rows for the pin; the intent is dropped.
    let mut moved = workspace("ws_2", "sec_pinned", "a", "V");
    moved["shows_label"] = json!(true);
    let echo = json!({"changes": [
        {"kind": "state_upsert", "resource": "sidebar_item", "id": "ws_2", "value": moved},
        {"kind": "state_upsert", "resource": "sidebar_doc", "id": "user",
         "value": {"revision": "5", "previous_revision": "4", "idempotency_key": "k1"}},
    ]});
    let confirmed = call(mirror, cmux_sidebar_mirror_apply_batch, &echo);
    assert_eq!(confirmed["dropped"], json!(["k1"]), "{confirmed}");
    let rows = call(mirror, cmux_sidebar_mirror_view, &live());
    assert_eq!(keys(&rows), ["ws_2", "sec_m_a", "ws_1", "sec_m_b", "ws_3"]);

    // A rejected intent is dropped and its rows go back.
    let unpin = json!({"idempotency_key": "k3", "ops": [{"op": "unpin", "items": ["ws_2"]}]});
    assert_eq!(call(mirror, cmux_sidebar_mirror_apply_intent, &unpin)["ok"], true);
    let rejected = json!({"idempotency_key": "k3", "rejected": true});
    assert_eq!(call(mirror, cmux_sidebar_mirror_apply_batch, &rejected)["dropped"], json!(["k3"]));
    let rows = call(mirror, cmux_sidebar_mirror_view, &live());
    assert_eq!(keys(&rows)[0], "ws_2");
    // SAFETY: freed once.
    unsafe { cmux_sidebar_mirror_free(mirror) };
}
