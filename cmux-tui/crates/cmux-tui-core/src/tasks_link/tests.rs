//! The Tasks page link against a real owner (`cmux_tasks::server::serve`)
//! on a socket in a temporary directory.

use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{call, owner_params, routed_reply};
use crate::{Mux, MuxEvent, SurfaceOptions};

struct Owner {
    dir: std::path::PathBuf,
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn start_owner(name: &str) -> (Owner, std::path::PathBuf) {
    // Unix socket paths are short (about 104 bytes on macOS).
    let dir = std::path::PathBuf::from("/tmp")
        .join(format!("ctl-{name}-{}", crate::workspace_registry::new_uuid_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let cmux_tasks::owner::Owner::Local(owner) =
        cmux_tasks::owner::resolve(Some("local"), Some(dir.clone())).unwrap()
    else {
        unreachable!()
    };
    let engine = cmux_tasks::engine::Engine::open(
        &owner.dir,
        &owner.team,
        "CMX",
        cmux_tasks::engine::system_clock(),
    )
    .unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let serving = owner.clone();
    std::thread::spawn(move || {
        let _ = cmux_tasks::server::serve(&serving, engine, move || ready_tx.send(()).unwrap());
    });
    ready_rx.recv().unwrap();
    (Owner { dir }, owner.socket)
}

fn params(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap()
}

fn mux_with_owner(name: &str) -> (Arc<Mux>, Owner) {
    let mux = Mux::new_for_test(name, SurfaceOptions::default());
    let (owner, socket) = start_owner(name);
    mux.control_clients.tasks.set_socket(socket);
    (mux, owner)
}

use std::sync::Arc;

fn next_tasks_event(events: &crate::MuxEventReceiver) -> Value {
    loop {
        match events.recv_timeout(Duration::from_secs(5)).expect("a tasks-changed event") {
            MuxEvent::TasksChanged(payload) => return payload.as_ref().clone(),
            _ => continue,
        }
    }
}

#[test]
fn snapshot_then_mutation_reaches_subscribers_with_its_seq() {
    let (mux, _owner) = mux_with_owner("tasks-link-flow");
    let events = mux.subscribe();
    let snapshot = call(&mux, "tasks.snapshot", Map::new()).unwrap();
    assert_eq!(snapshot["seq"], 0);
    assert!(snapshot["statuses"].as_array().is_some_and(|s| !s.is_empty()), "{snapshot}");

    let created = call(
        &mux,
        "tasks.create",
        params(json!({"id": "task_page1", "title": "From the page", "idempotency_key": "k1"})),
    )
    .unwrap();
    assert_eq!(created.get("seq"), Some(&json!(1)), "{created}");
    assert_eq!(created.get("replay"), Some(&json!(false)), "{created}");
    assert!(
        created.get("result").is_some_and(|result| result.get("result").is_none()),
        "{created}"
    );

    let event = next_tasks_event(&events);
    assert_eq!(event["event"], "tasks-changed");
    assert_eq!(event["change"]["seq"], 1);
    assert_eq!(event["change"]["tx"], "k1");
    assert_eq!(event["change"]["origin"], "user");
    assert_eq!(event["change"]["change"]["value"]["id"], "task_page1");

    // A second snapshot is a fresh read: it holds the new task.
    let again = call(&mux, "tasks.snapshot", Map::new()).unwrap();
    assert_eq!(again["seq"], 1);
    assert!(again["tasks"].as_array().unwrap().iter().any(|task| task["id"] == "task_page1"));
}

#[test]
fn owner_refusal_and_missing_key_are_errors() {
    let (mux, _owner) = mux_with_owner("tasks-link-refuse");
    let missing = call(&mux, "tasks.archive", params(json!({"task": "task_none"}))).unwrap_err();
    assert_eq!(missing.code, "validation.invalid", "{missing:?}");
    let refused =
        call(&mux, "tasks.archive", params(json!({"task": "task_none", "idempotency_key": "k2"})))
            .unwrap_err();
    assert_eq!(refused.details["extra"]["code"], "tasks.not_found", "{refused:?}");
    let unknown = call(&mux, "tasks.delete", params(json!({"task": "x", "idempotency_key": "k3"})))
        .unwrap_err();
    assert_eq!(unknown.details["extra"]["code"], "tasks.usage", "{unknown:?}");
}

#[test]
fn a_missing_owner_is_unreachable() {
    let mux = Mux::new_for_test("tasks-link-missing", SurfaceOptions::default());
    mux.control_clients.tasks.set_socket(std::path::PathBuf::from("/tmp/ctl-no-such-owner.sock"));
    let error = call(&mux, "tasks.snapshot", Map::new()).unwrap_err();
    assert_eq!(error.details["extra"]["code"], "tasks.owner_unreachable", "{error:?}");
}

#[test]
fn a_delegate_sends_its_agent_session_as_the_owner_session() {
    let delegate = owner_params(
        "delegate",
        params(json!({"task": "task_1", "agent_session": "asess_1", "harness": "codex"})),
    );
    assert_eq!(
        Value::Object(delegate),
        json!({"task": "task_1", "session": "asess_1", "harness": "codex"})
    );
    let update = owner_params("update", params(json!({"task": "task_1", "agent_session": "x"})));
    assert_eq!(Value::Object(update), json!({"task": "task_1", "agent_session": "x"}));
}

#[test]
fn a_routed_reply_has_the_op_result_at_the_top_level() {
    let owner = json!({"result": {"id": "task_1"}, "seq": 3, "replay": true});
    assert_eq!(
        routed_reply(owner, 4),
        json!({"result": {"id": "task_1"}, "seq": 4, "replay": true})
    );
    assert_eq!(routed_reply(json!(7), 2), json!({"result": 7, "seq": 2, "replay": false}));
}
