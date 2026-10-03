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
    start_server_with(dir, cmux_tasks::identity::Identity::local(Principal::user("usr_a")))
}

fn start_server_with(
    dir: &std::path::Path,
    identity: cmux_tasks::identity::Identity,
) -> LocalOwner {
    let Owner::Local(owner) = resolve(Some("local"), Some(dir.to_owned())).unwrap() else {
        unreachable!()
    };
    let engine = Engine::open(&owner.dir, &owner.team, "CMX", system_clock()).unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let serving = owner.clone();
    thread::spawn(move || {
        let identity = std::sync::Arc::new(identity);
        cmux_tasks::server::serve(&serving, engine, identity, move || ready_tx.send(()).unwrap())
            .unwrap();
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
    let mut watcher = Conn::open(&owner, None, "CMX").unwrap();
    assert!(!watcher.is_in_process());
    watcher.call("task.subscribe", json!({}), None).unwrap();
    let snapshot = loop {
        if let ServerLine::Snapshot { snapshot } = watcher.read_line().unwrap() {
            break snapshot;
        }
    };
    assert_eq!(snapshot["seq"], 0);

    let mut writer = Conn::open(&owner, None, "CMX").unwrap();
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
    let mut a = Conn::open(&owner, None, "CMX").unwrap();
    let mut b = Conn::open(&owner, None, "CMX").unwrap();
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
    let run = || {
        cmux_tasks::cli::run(
            &[
                "task",
                "create",
                "--title",
                "Once",
                "--idempotency-key",
                "retry-1",
                "--data",
                data.as_str(),
            ]
            .map(str::to_owned),
        )
    };
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
    let me = cmux_tasks::identity::Caller::person(Principal::user("usr_a"));
    let request = || cmux_tasks::protocol::Request {
        id: 1,
        op: "task.create".to_owned(),
        params: json!({"title": "no id"}),
        key: Some("k".to_owned()),
        origin: None,
        credential: None,
        epoch: None,
    };
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

/// P8: a caller never states its actor. A hello naming an actor is refused,
/// and the request after it acts as the local person.
#[test]
fn a_hello_that_states_an_actor_is_refused() {
    use std::io::{BufRead, BufReader, Write};
    let dir = short_tempdir();
    let owner = start_server(dir.path());
    let stream = std::os::unix::net::UnixStream::connect(&owner.socket).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let mut reader = BufReader::new(stream);
    let hello = json!({"hello": {"actor": {"kind": "agent", "principal": "agt_mux", "class": "mux",
        "harness": "x", "on_behalf_of": "usr_a"}}});
    writeln!(writer, "{hello}").unwrap();
    let mut text = String::new();
    reader.read_line(&mut text).unwrap();
    let line: ServerLine = serde_json::from_str(&text).unwrap();
    let ServerLine::Err { id: 0, err } = line else { panic!("expected a refusal, got {text}") };
    assert_eq!(err.code, ErrorCode::Usage);
    assert!(err.message.contains("actor_not_accepted"), "{}", err.message);
    let request = json!({"id": 1, "op": "task.create", "key": "k1",
        "params": {"id": "task_1", "title": "t"}});
    writeln!(writer, "{request}").unwrap();
    text.clear();
    reader.read_line(&mut text).unwrap();
    let reply: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(reply["ok"]["result"]["key"], "CMX-1", "{text}");
    drop(writer);
    let state = cmux_tasks::store::Store::open(&owner.dir, "local", "CMX");
    // The server still holds the lock; read the log instead.
    assert!(matches!(state, Err(cmux_tasks::store::OpenError::Locked)));
    let log = std::fs::read_dir(owner.dir.join("log")).unwrap().next().unwrap().unwrap().path();
    let record: serde_json::Value =
        serde_json::from_str(std::fs::read_to_string(log).unwrap().lines().next().unwrap())
            .unwrap();
    assert_eq!(record["actor"], json!({"kind": "user", "id": "usr_a"}));
    assert_eq!(record["stamp"], json!({"kind": "user", "id": "user_local"}));
}

/// The CLI copies `CMUX_LAUNCH_CREDENTIAL` into its hello. Until P8 ships
/// `credential.verify`, every credential is an unknown key id: the request
/// acts as the local person instead of failing.
#[test]
fn a_credential_with_an_unknown_kid_acts_as_the_local_person() {
    let dir = short_tempdir();
    let owner = start_server(dir.path());
    let mut conn = Conn::open(&owner, Some("cmuxlc1.k0.e30.mac"), "CMX").unwrap();
    let (reply, _) = conn
        .call("task.create", json!({"id": "task_1", "title": "t"}), Some("k1".to_owned()))
        .unwrap();
    assert_eq!(reply["result"]["key"], "CMX-1");
    let (task, _) = conn.call("task.get", json!({"task": "CMX-1"}), None).unwrap();
    assert_eq!(task["created_by"], json!({"kind": "user", "id": "usr_a"}), "{task}");
}

/// An oversized credential is refused with its own code (exit 4) and a
/// settle line, so a client never waits for a reply that will not come.
#[test]
fn an_oversized_credential_is_refused_and_settled() {
    let dir = short_tempdir();
    let owner = start_server(dir.path());
    let big = "x".repeat(5000);
    let mut conn = Conn::open(&owner, Some(&big), "CMX").unwrap();
    let err = conn
        .call("task.create", json!({"id": "task_1", "title": "t"}), Some("k1".to_owned()))
        .unwrap_err();
    assert_eq!(err.code, ErrorCode::CredentialInvalid);
    assert_eq!(err.code.exit_code(), 4);
}

/// A verifier for tests: `good-<acp id>` is that ACP session on `sess_h`,
/// `closed` is refused, anything else is an unknown key id.
struct TestVerifier;

impl cmux_tasks::identity::CredentialVerifier for TestVerifier {
    fn verify(&self, credential: &str) -> cmux_tasks::identity::Verdict {
        use cmux_tasks::identity::Verdict;
        if let Some(acp) = credential.strip_prefix("good-") {
            return Verdict::Valid(cmux_tasks_core::Actor::AcpSession {
                id: acp.to_owned(),
                host: "sess_h".to_owned(),
                agent: None,
            });
        }
        if credential == "closed" {
            return Verdict::Invalid("closed ACP session".to_owned());
        }
        Verdict::UnknownKid
    }
}

struct Raw {
    writer: std::os::unix::net::UnixStream,
    reader: std::io::BufReader<std::os::unix::net::UnixStream>,
}

impl Raw {
    fn connect(owner: &LocalOwner) -> Self {
        let stream = std::os::unix::net::UnixStream::connect(&owner.socket).unwrap();
        let writer = stream.try_clone().unwrap();
        Self { writer, reader: std::io::BufReader::new(stream) }
    }

    fn send(&mut self, value: serde_json::Value) {
        use std::io::Write;
        writeln!(self.writer, "{value}").unwrap();
    }

    fn recv(&mut self) -> serde_json::Value {
        use std::io::BufRead;
        let mut text = String::new();
        self.reader.read_line(&mut text).unwrap();
        serde_json::from_str(&text).unwrap()
    }
}

fn verified_server(dir: &std::path::Path) -> LocalOwner {
    let identity =
        cmux_tasks::identity::Identity::new(Principal::user("usr_a"), Box::new(TestVerifier));
    start_server_with(dir, identity)
}

/// End to end with a verifier: the stamp of a valid credential reaches the
/// log, a per-request credential overrides the hello's, and a refused
/// request still gets its settle line.
#[test]
fn verified_credentials_stamp_requests_and_refusals_settle() {
    let dir = short_tempdir();
    let owner = verified_server(dir.path());
    let mut raw = Raw::connect(&owner);
    raw.send(json!({"hello": {"credential": "good-acp_1"}}));
    raw.send(json!({"id": 1, "op": "task.create", "key": "k1",
        "params": {"id": "task_1", "title": "t"}}));
    assert_eq!(raw.recv()["ok"]["result"]["key"], "CMX-1");
    assert_eq!(raw.recv()["settled"]["id"], 1);
    // The per-request credential wins over the hello's.
    raw.send(json!({"id": 2, "op": "task.create", "key": "k2", "credential": "good-acp_2",
        "params": {"id": "task_2", "title": "t"}}));
    assert_eq!(raw.recv()["ok"]["result"]["key"], "CMX-2");
    assert_eq!(raw.recv()["settled"]["id"], 2);
    // A refused credential: an error line, then its settle line.
    raw.send(json!({"id": 3, "op": "task.create", "key": "k3", "credential": "closed",
        "params": {"id": "task_3", "title": "t"}}));
    let err = raw.recv();
    assert_eq!(err["id"], 3);
    assert_eq!(err["err"]["code"], "credential_invalid", "{err}");
    assert_eq!(raw.recv()["settled"]["id"], 3);
    let log = std::fs::read_dir(owner.dir.join("log")).unwrap().next().unwrap().unwrap().path();
    let text = std::fs::read_to_string(log).unwrap();
    let stamps: Vec<serde_json::Value> = text
        .lines()
        .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()["stamp"].clone())
        .collect();
    assert_eq!(
        stamps,
        vec![
            json!({"kind": "acp_session", "id": "acp_1", "host": "sess_h"}),
            json!({"kind": "acp_session", "id": "acp_2", "host": "sess_h"}),
        ]
    );
}

/// A hello is accepted only as the first line.
#[test]
fn a_late_hello_is_refused() {
    let dir = short_tempdir();
    let owner = verified_server(dir.path());
    let mut raw = Raw::connect(&owner);
    raw.send(json!({"id": 1, "op": "task.settings.get"}));
    assert!(raw.recv().get("ok").is_some());
    assert_eq!(raw.recv()["settled"]["id"], 1);
    raw.send(json!({"hello": {"credential": "good-acp_1"}}));
    let err = raw.recv();
    assert_eq!(err["id"], 0);
    assert!(err["err"]["message"].as_str().unwrap().contains("first line"), "{err}");
}

/// Coordinator condition: the in-process path (the CLI and `cmux mcp` when
/// no owner socket answers) takes the owner's single-writer lock and
/// refuses, never waits or shares, when another writer holds it.
#[test]
fn two_writers_never_open_the_store_at_once() {
    let dir = short_tempdir();
    let Owner::Local(owner) = resolve(Some("local"), Some(dir.path().to_owned())).unwrap() else {
        unreachable!()
    };
    let mut first = Conn::open(&owner, None, "CMX").unwrap();
    assert!(first.is_in_process(), "no server runs, so the first caller holds the lock");
    let second = Conn::open(&owner, None, "CMX").err().expect("a second writer is refused");
    assert_eq!(second.code, ErrorCode::OwnerUnreachable);
    assert!(matches!(
        Engine::open(&owner.dir, &owner.team, "CMX", system_clock()),
        Err(cmux_tasks::store::OpenError::Locked)
    ));
    first
        .call("task.create", json!({"id": "task_1", "title": "t"}), Some("k1".to_owned()))
        .unwrap();
    drop(first);
    // The lock is released with the writer.
    let mut next = Conn::open(&owner, None, "CMX").unwrap();
    let (task, _) = next.call("task.get", json!({"task": "CMX-1"}), None).unwrap();
    assert_eq!(task["title"], "t");
}
