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

#[test]
fn a_mirror_of_event_entities_previews_like_a_snapshot() {
    // Events carry bare tasks tagged `entity`, without the view fields;
    // the pane mirrors them as they arrive.
    let mut mirror = snapshot();
    for task in mirror["tasks"].as_array_mut().unwrap() {
        let task = task.as_object_mut().unwrap();
        for field in ["key", "category", "status_name"] {
            task.remove(field);
        }
        task.insert("entity".into(), json!("task"));
    }
    let intents = json!([
        {"key": "k1", "op": "task.create", "params": {"id": "task_new", "title": "New"}}
    ]);
    let (code, body) = call(&json!({"mirror": mirror, "intents": intents, "now": 5}));
    assert_eq!(code, OK);
    assert_eq!(order(&body), ["task_a", "task_b", "task_new"]);
    assert_eq!(task(&body, "task_a")["key"], "CMX-1");
    assert_eq!(task(&body, "task_new")["key"], "CMX-3");
}

/// The mirror as the Swift pane holds it: its own items, trimmed to what it
/// shows (no descriptions, creators, timestamps or agent classes; settings
/// with the key prefix only), as a demo owner or the socket filled them.
fn pane_mirror() -> Value {
    json!({
        "seq": 4,
        "me": {"kind": "user", "id": ME},
        "settings": {"key_prefix": "CMX"},
        "statuses": [
            {"id": "st_backlog", "name": "Backlog", "category": "backlog", "position": 1, "color": 8},
            {"id": "st_todo", "name": "Todo", "category": "unstarted", "position": 2, "color": 7},
            {"id": "st_in_progress", "name": "In Progress", "category": "started", "position": 3, "color": 3}
        ],
        "labels": [{"id": "lbl_bug", "name": "bug", "color": 1, "archived": false}],
        "projects": [{"id": "prj_app", "name": "App", "archived": false}],
        "tasks": [
            {"id": "task_1", "key": "CMX-1", "number": 1, "title": "One", "status": "st_todo",
             "category": "unstarted", "priority": "high", "labels": ["lbl_bug"], "sort_key": "03",
             "updated_at": 7, "archived": false, "deleted": false,
             "delegate": {"principal": "agt_claude-leo", "harness": "claude", "on_behalf_of": ME},
             "assignee": {"kind": "user", "id": ME}},
            {"id": "task_7", "key": "CMX-7", "number": 7, "title": "Seven", "status": "st_backlog",
             "category": "backlog", "priority": "none", "labels": [], "sort_key": "06",
             "updated_at": 0, "archived": false, "deleted": false,
             "attention": "needs_input"}
        ],
        "sessions": [
            {"id": "asess_1", "task": "task_1", "status": "working", "plan": [],
             "agent": {"principal": "agt_claude-leo", "harness": "claude", "on_behalf_of": ME}}
        ]
    })
}

#[test]
fn a_pane_mirror_previews_with_the_owners_defaults() {
    let intents = json!([
        {"key": "k1", "op": "task.create", "params": {"id": "task_new", "title": "New"}},
        {"key": "k2", "op": "task.update", "params": {"task": "task_7", "status": "st_in_progress"}},
        {"key": "k3", "op": "task.delegate",
         "params": {"task": "task_1", "session": "asess_2", "harness": "claude"}},
        {"key": "k4", "op": "task.delegate",
         "params": {"task": "task_7", "session": "asess_3", "harness": "codex"}}
    ]);
    let (code, body) = call(&json!({"mirror": pane_mirror(), "intents": intents, "now": 9}));
    assert_eq!(code, OK);
    // The next key follows the highest number; the default status is the
    // owner's default for a team that never changed it.
    let created = task(&body, "task_new");
    assert_eq!(created["key"], "CMX-8");
    assert_eq!(created["status"], "st_backlog");
    assert_eq!(order(&body), ["task_1", "task_7", "task_new"]);
    assert_eq!(task(&body, "task_7")["category"], "started");
    // The mirrored session still blocks a second claude session on task_1.
    assert_eq!(body["rejected"], json!(["k3"]));
    assert_eq!(task(&body, "task_7")["delegate"]["principal"], "agt_codex-leo");
    assert_eq!(task(&body, "task_1")["priority"], "high");
}
