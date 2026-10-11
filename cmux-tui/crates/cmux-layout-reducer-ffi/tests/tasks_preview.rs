//! `tasks_preview` through the C ABI: the Tasks pane sends its confirmed
//! mirror (the owner's snapshot JSON) plus its pending intents and shows
//! what comes back, so its optimistic rows follow the owner's own rules.

use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use cmux_tasks_core::{Ctx, Envelope, Op, Origin, Principal, State, query, reduce};
use serde_json::{Value, json};
use std::collections::BTreeSet;

const ME: &str = "usr_leo";

fn call(request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"tasks_preview".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

/// An owner with two tasks, CMX-1 then CMX-2, as its snapshot shows them.
fn snapshot() -> Value {
    let me = Principal::user(ME);
    let mut state = State::new("team", "CMX");
    state.settings.default_status = "st_todo".into();
    for (i, id) in ["task_a", "task_b"].into_iter().enumerate() {
        let op: Op =
            serde_json::from_value(json!({"op": "task.create", "params": {"id": id, "title": id}}))
                .unwrap();
        let envelope = Envelope {
            actor: me.clone(),
            origin: Origin::User,
            key: format!("seed-{i}"),
            grants: BTreeSet::new(),
            op,
        };
        reduce(&mut state, &envelope, Ctx { now: 1 }).unwrap();
    }
    let mut statuses: Vec<_> = state.statuses.values().collect();
    statuses.sort_by_key(|s| (s.category.rank(), s.position));
    let tasks: Vec<_> = state.tasks.values().map(|t| query::view(&state, t)).collect();
    json!({
        "seq": state.seq,
        "me": me,
        "settings": state.settings,
        "statuses": statuses,
        "labels": [],
        "projects": [],
        "tasks": tasks,
        "sessions": [],
    })
}

fn preview(intents: Value) -> Value {
    let (code, body) = call(&json!({"mirror": snapshot(), "intents": intents, "now": 5}));
    assert_eq!(code, OK);
    body
}

fn task<'a>(body: &'a Value, id: &str) -> &'a Value {
    body["tasks"].as_array().unwrap().iter().find(|t| t["id"] == id).unwrap()
}

fn order(body: &Value) -> Vec<&str> {
    body["tasks"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect()
}

#[test]
fn no_intents_shows_the_mirror_in_manual_order() {
    let body = preview(json!([]));
    assert_eq!(order(&body), ["task_a", "task_b"]);
    assert_eq!(task(&body, "task_a")["key"], "CMX-1");
    assert_eq!(body["rejected"], json!([]));
}

#[test]
fn create_gets_the_owners_next_key_default_status_and_last_place() {
    let body = preview(json!([
        {"key": "k1", "op": "task.create", "params": {"id": "task_new", "title": "New"}}
    ]));
    let created = task(&body, "task_new");
    assert_eq!(created["key"], "CMX-3");
    assert_eq!(created["number"], 3);
    assert_eq!(created["status"], "st_todo");
    assert_eq!(created["status_name"], "Todo");
    assert_eq!(order(&body), ["task_a", "task_b", "task_new"]);
}

#[test]
fn move_places_the_task_where_the_owner_would() {
    let body = preview(json!([
        {"key": "k1", "op": "task.move", "params": {"task": "task_b", "before": "task_a"}}
    ]));
    assert_eq!(order(&body), ["task_b", "task_a"]);
}

#[test]
fn status_change_updates_category_and_name() {
    let body = preview(json!([
        {"key": "k1", "op": "task.update", "params": {"task": "task_a", "status": "st_in_progress"}}
    ]));
    let changed = task(&body, "task_a");
    assert_eq!(changed["status"], "st_in_progress");
    assert_eq!(changed["category"], "started");
    assert_eq!(changed["status_name"], "In Progress");
}

#[test]
fn delegate_derives_the_agent_for_me_and_assigns_me() {
    let body = preview(json!([
        {"key": "k1", "op": "task.delegate",
         "params": {"task": "task_a", "session": "asess_1", "harness": "codex"}}
    ]));
    let delegated = task(&body, "task_a");
    assert_eq!(delegated["delegate"]["principal"], "agt_codex-leo");
    assert_eq!(delegated["delegate"]["on_behalf_of"], ME);
    assert_eq!(delegated["assignee"]["id"], ME);
}

#[test]
fn intents_apply_in_order_and_refused_ones_change_nothing() {
    let body = preview(json!([
        {"key": "k1", "op": "task.archive", "params": {"task": "task_a"}},
        {"key": "k2", "op": "task.delegate",
         "params": {"task": "task_a", "session": "asess_1", "harness": "codex"}},
        {"key": "k3", "op": "task.update", "params": {"task": "task_missing", "status": "st_todo"}},
        {"key": "k4", "op": "task.nonsense", "params": {}}
    ]));
    assert_eq!(task(&body, "task_a")["archived"], true);
    assert_eq!(task(&body, "task_a")["delegate"], Value::Null);
    assert_eq!(body["rejected"], json!(["k2", "k3", "k4"]));
}

#[test]
fn a_mirror_that_is_not_a_snapshot_is_invalid() {
    let (code, _) = call(&json!({"mirror": {"tasks": []}, "intents": []}));
    assert_eq!(code, cmux_layout_reducer_ffi::ERR_INVALID);
}
