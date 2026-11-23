//! The mirror's `project` and `plan` calls: they read the shown document
//! (the confirmed one with the pending intents), and `project` keeps its
//! rows for the next `drag_begin` as `view` does.

use cmux_layout_reducer_ffi::sidebar_mirror::Mirror;
use serde_json::{Value, json};

fn document() -> Value {
    json!({
        "revision": "1",
        "sections": [{"id": "sec_m_mini", "kind": {"type": "machine", "session_id": "mini"}, "order": "a"}],
        "items": [
            {"id": "itm_w_mini_a1", "section": "sec_m_mini", "order": "a",
             "body": {"type": "workspace", "ref": {"session_id": "mini", "workspace_id": "a1"}}},
            {"id": "g1", "section": "sec_m_mini", "order": "b",
             "body": {"type": "group", "name": "Group"}},
        ],
    })
}

fn call(mirror: &mut Mirror, method: fn(&mut Mirror, &[u8]) -> Value, input: &Value) -> Value {
    method(mirror, &serde_json::to_vec(input).unwrap())
}

fn request() -> Value {
    json!({"live": [{"session_id": "mini", "workspace_id": "a1"}, {"session_id": "mini", "workspace_id": "new"}], "collapsed": []})
}

#[test]
fn project_draws_the_pending_rename_and_the_unplaced_workspace() {
    let mut mirror = Mirror::new();
    assert_eq!(
        call(&mut mirror, Mirror::load, &document())["ok"],
        json!(true),
        "the document loads"
    );
    let rename = json!({"idempotency_key": "k1", "ops": [{"op": "group.update", "id": "g1", "patch": {"name": "Renamed"}}]});
    assert_eq!(call(&mut mirror, Mirror::apply_intent, &rename)["ok"], json!(true));
    let projection = call(&mut mirror, Mirror::project, &request());
    let nodes = projection["machines"]["mini"].as_array().expect("mini's nodes");
    assert_eq!(
        nodes[0],
        json!({"type": "workspace", "ref": {"session_id": "mini", "workspace_id": "a1"}, "item": "itm_w_mini_a1"})
    );
    assert_eq!(nodes[1]["group"]["name"], json!("Renamed"), "the pending rename draws");
    assert_eq!(projection["unplaced"], json!([{"session_id": "mini", "workspace_id": "new"}]));
    assert_eq!(projection["sections"][0]["type"], json!("workspaces"));
    // Its rows are the last view's: a drag reads them.
    let table = call(&mut mirror, Mirror::drag_begin, &json!({"items": ["itm_w_mini_a1"]}));
    assert!(table.get("g1").is_some(), "{table}");
}

#[test]
fn project_answers_an_error_for_a_bad_request() {
    let mut mirror = Mirror::new();
    let answer = mirror.project(b"{");
    assert!(answer.get("error").is_some_and(Value::is_string), "{answer}");
}

#[test]
fn plan_reads_the_shown_document() {
    let mut mirror = Mirror::new();
    call(&mut mirror, Mirror::load, &document());
    let subgroup = json!({"plan": "subgroup", "parent": "g1", "id": "g2", "name": "Sub"});
    assert_eq!(
        call(&mut mirror, Mirror::plan, &subgroup),
        json!({"ok": true, "ops": [{"op": "group.create", "id": "g2", "name": "Sub", "items": [],
                                     "to": {"section": "sec_m_mini", "parent": "g1"}}]})
    );
    // A group a pending intent made is a parent already.
    let create = json!({"idempotency_key": "k2", "ops": [{"op": "group.create", "id": "g_new", "name": "New", "items": [],
                                                           "to": {"section": "sec_m_mini"}}]});
    assert_eq!(call(&mut mirror, Mirror::apply_intent, &create)["ok"], json!(true));
    let under_new = json!({"plan": "subgroup", "parent": "g_new", "id": "g3", "name": "Sub"});
    assert_eq!(call(&mut mirror, Mirror::plan, &under_new)["ok"], json!(true));
    let unknown = json!({"plan": "subgroup", "parent": "nope", "id": "g3", "name": "Sub"});
    assert_eq!(call(&mut mirror, Mirror::plan, &unknown), json!({"refusal": "unknown_group"}));
    let host = json!({"plan": "host_group", "session": "mini"});
    assert_eq!(
        call(&mut mirror, Mirror::plan, &host),
        json!({"ok": true, "ops": [{"op": "section.update", "id": "sec_m_mini", "patch": {"host_group": true}}]})
    );
}
