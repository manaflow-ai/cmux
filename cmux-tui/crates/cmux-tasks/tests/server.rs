//! End to end over the Unix socket: two clients, one subscriber, group
//! commit, a dispatcher claim race, and the CLI in-process mode.

#![cfg(unix)]

use std::sync::mpsc;
use std::thread;

use cmux_tasks::client::Conn;
use cmux_tasks::engine::{Engine, system_clock};
use cmux_tasks::owner::{LocalOwner, Owner, resolve};
use cmux_tasks::protocol::{ErrorCode, ServerLine};
use cmux_tasks_core::ids::Principal;
use serde_json::json;

fn start_server(dir: &std::path::Path) -> LocalOwner {
    let Owner::Local(owner) = resolve(Some("local"), Some(dir.to_owned())).unwrap() else {
        unreachable!()
    };
    let engine = Engine::open(&owner.dir, &owner.team, "CMX", system_clock()).unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let serving = owner.clone();
    thread::spawn(move || {
        cmux_tasks::server::serve(&serving, engine, move || ready_tx.send(()).unwrap()).unwrap();
    });
    ready_rx.recv().unwrap();
    owner
}

fn short_tempdir() -> tempfile::TempDir {
    // Unix socket paths are limited to about 104 bytes on macOS.
    tempfile::Builder::new().prefix("ct").tempdir_in("/tmp").unwrap()
}

#[test]
fn subscriber_sees_commits_from_another_client() {
    let dir = short_tempdir();
    let owner = start_server(dir.path());
    let me = Principal::user("usr_a");
    let mut watcher = Conn::open(&owner, &me, "CMX").unwrap();
    assert!(!watcher.is_in_process());
    watcher.call("task.subscribe", json!({}), None).unwrap();
    let snapshot = loop {
        if let ServerLine::Snapshot { snapshot } = watcher.read_line().unwrap() {
            break snapshot;
        }
    };
    assert_eq!(snapshot["seq"], 0);

    let mut writer = Conn::open(&owner, &me, "CMX").unwrap();
    let (reply, seq) = writer
        .call("task.create", json!({"id": "task_1", "title": "Ship Tasks"}), Some("k1".to_owned()))
        .unwrap();
    assert_eq!(reply["result"]["key"], "CMX-1");
    assert_eq!(seq, 1);
    // Retrying the same key is a replay, not a second task.
    let (again, _) = writer
        .call("task.create", json!({"id": "task_1", "title": "Ship Tasks"}), Some("k1".to_owned()))
        .unwrap();
    assert_eq!(again["replay"], true);

    let event = loop {
        if let ServerLine::Event { event } = watcher.read_line().unwrap() {
            break event;
        }
    };
    assert_eq!(event.body.kind, "task.created");
    assert_eq!(event.tx, "k1");
    assert_eq!(event.seq, 1);
}

#[test]
fn only_one_dispatcher_claims_a_session() {
    let dir = short_tempdir();
    let owner = start_server(dir.path());
    let me = Principal::user("usr_a");
    let mut a = Conn::open(&owner, &me, "CMX").unwrap();
    let mut b = Conn::open(&owner, &me, "CMX").unwrap();
    a.call("task.create", json!({"id": "task_1", "title": "x"}), Some("c".to_owned())).unwrap();
    a.call(
        "task.delegate",
        json!({"task": "CMX-1", "session": "asess_1", "harness": "codex"}),
        Some("d".to_owned()),
    )
    .unwrap();
    let first = a.call(
        "task.session.claim",
        json!({"session": "asess_1", "host": "mac-a"}),
        Some("ca".to_owned()),
    );
    let second = b.call(
        "task.session.claim",
        json!({"session": "asess_1", "host": "mac-b"}),
        Some("cb".to_owned()),
    );
    assert!(first.is_ok());
    assert_eq!(second.unwrap_err().code, ErrorCode::Conflict);
}

#[test]
fn cli_works_in_process_without_a_server() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().to_str().unwrap().to_owned();
    let run = |args: &[&str]| {
        let mut all: Vec<String> = args.iter().map(|s| (*s).to_owned()).collect();
        all.extend(["--data".to_owned(), data.clone()]);
        cmux_tasks::cli::run(&all)
    };
    assert_eq!(
        run(&["task", "create", "--title", "First", "--priority", "high"]),
        std::process::ExitCode::SUCCESS
    );
    assert_eq!(
        run(&["task", "update", "CMX-1", "--status", "Todo"]),
        std::process::ExitCode::SUCCESS
    );
    assert_eq!(run(&["task", "list", "--json"]), std::process::ExitCode::SUCCESS);
    assert_eq!(run(&["task", "view", "CMX-9"]), std::process::ExitCode::from(3));
    assert_eq!(run(&["task", "update", "CMX-1", "--bogus"]), std::process::ExitCode::from(2));
    let engine = Engine::open(dir.path(), "local", "CMX", system_clock()).unwrap();
    let task = engine.state().tasks.values().next().unwrap();
    assert_eq!(task.status, "st_todo");
}

/// Review finding (MEDIUM): retrying a create with the printed idempotency
/// key failed, because the CLI minted a new task id each run.
#[test]
fn cli_retry_with_the_same_key_reuses_the_create() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().to_str().unwrap().to_owned();
    let run = || cmux_tasks::cli::run(&["task", "create", "--title", "Once", "--idempotency-key", "retry-1", "--data", data.as_str()].map(str::to_owned));
    assert_eq!(run(), std::process::ExitCode::SUCCESS);
    assert_eq!(run(), std::process::ExitCode::SUCCESS, "a retry with the same key is a replay");
    let engine = Engine::open(dir.path(), "local", "CMX", system_clock()).unwrap();
    assert_eq!(engine.state().tasks.len(), 1);
}

/// MCP and code mode may omit generated ids: the owner derives them from
/// the idempotency key, so a retry still converges.
#[test]
fn owner_derives_omitted_ids_from_the_key() {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::open(dir.path(), "local", "CMX", system_clock()).unwrap();
    let me = Principal::user("usr_a");
    let request = || cmux_tasks::protocol::Request { id: 1, op: "task.create".to_owned(), params: json!({"title": "no id"}), key: Some("k".to_owned()), origin: None };
    let first = engine.handle(&me, request()).unwrap().reply.unwrap();
    let again = engine.handle(&me, request()).unwrap().reply.unwrap();
    assert_eq!(first["result"]["id"], again["result"]["id"]);
    assert_eq!(again["replay"], true);
}

/// Review finding (MEDIUM): without a hello, the server used its own
/// environment, so a server started in an agent shell stamped every
/// person's change as the agent's.
#[test]
fn a_connection_without_hello_acts_as_the_local_person() {
    let env = |name: &str| match name {
        "USER" => Some("lawrence".to_owned()),
        "CMUX_AGENT_PRINCIPAL" => Some("agt_claude-lawrence".to_owned()),
        _ => None,
    };
    assert_eq!(cmux_tasks::owner::person_from(env), Principal::user("usr_lawrence"));
}
