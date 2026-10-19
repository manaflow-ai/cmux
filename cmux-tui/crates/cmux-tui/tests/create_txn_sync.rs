//! A creation's registry commits share one WAL sync (create-txn), over a
//! real daemon socket with the debug timing marks (`CMUX_TUI_DEBUG_SPANS`).
//!
//! `workspace.create` committed seven times in a row and each commit waited
//! for its own sync (`sqlite.commit`): about 22 ms of a 45 ms create on an
//! M6 Mac mini. Now every commit of a creation skips its own sync
//! (`sqlite.commit.deferred`), and the creation is durable
//! (`create_txn.synced`, after at most one `registry.wal_synced` of its own:
//! another thread may have synced its commits first) after its last commit
//! and before its reply. The created terminals are still there when the
//! daemon is killed right after the replies and started again. (A kill
//! keeps the page cache, so that part checks recovery, not the sync; the
//! mark order is the sync's evidence.)

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn temp_dir() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-create-txn-{}-{stamp}", std::process::id()))
}

fn start_daemon(dir: &Path) -> Child {
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--headless", "--socket"])
        .arg(dir.join("mux.sock"))
        .arg("--state")
        .arg(dir.join("state"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_DEBUG_SPANS", dir.join("spans.jsonl"))
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    while UnixStream::connect(dir.join("mux.sock")).is_err() {
        assert!(Instant::now() < deadline, "daemon did not listen in {}", dir.display());
        std::thread::sleep(Duration::from_millis(25));
    }
    child
}

fn request(dir: &Path, id: &str, operation: &str, params: Value) -> Value {
    let stream = UnixStream::connect(dir.join("mux.sock")).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let mut body = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": id,
        "operation": operation,
        "params": params,
    });
    if !operation.ends_with(".list") {
        body["idempotency_key"] = json!(id);
    }
    writeln!(writer, "{body}").unwrap();
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert!(!line.is_empty(), "daemon closed the connection before answering {id}");
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply["id"] == id {
            assert_eq!(reply["ok"], true, "{operation} failed: {reply}");
            return reply["result"].clone();
        }
    }
}

/// Names of `trace`'s marks, in order.
fn marks(trace: &Value) -> Vec<String> {
    trace["marks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|mark| mark[0].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn a_creation_syncs_its_commits_once_and_they_survive_a_daemon_kill() {
    let dir = temp_dir();
    fs::create_dir_all(&dir).unwrap();
    let mut daemon = start_daemon(&dir);
    let current = json!({"machine": "current", "session": "current"});
    let mut workspace = current.clone();
    workspace["name"] = json!("txn");
    workspace["initial_content"] = json!("terminal");
    workspace["argv"] = json!(["/bin/sleep", "600"]);
    let first = request(&dir, "txn-workspace-create", "workspace.create", workspace);
    let second = request(&dir, "txn-tab-create", "tab.create_terminal", current.clone());
    // A trace line is written just after its reply.
    let deadline = Instant::now() + Duration::from_secs(10);
    let (spans, creations) = loop {
        let spans = fs::read_to_string(dir.join("spans.jsonl")).unwrap_or_default();
        let creations: Vec<Value> = spans
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|trace| {
                trace["label"] == "resource:workspace.create"
                    || trace["label"] == "resource:tab.create_terminal"
            })
            .collect();
        if creations.len() >= 2 || Instant::now() >= deadline {
            break (spans, creations);
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    // Killed, not stopped: nothing may be left for a later request to sync.
    daemon.kill().unwrap();
    daemon.wait().unwrap();
    assert_eq!(creations.len(), 2, "one trace per creation:\n{spans}");
    for trace in &creations {
        let names = marks(trace);
        let label = &trace["label"];
        let own_syncs = names.iter().filter(|name| *name == "sqlite.commit").count();
        assert_eq!(own_syncs, 0, "{label}: a commit waited for its own sync: {names:?}");
        let deferred = names.iter().filter(|name| *name == "sqlite.commit.deferred").count();
        assert!(deferred >= 2, "{label}: expected its commits on the request thread: {names:?}");
        let syncs = names.iter().filter(|name| *name == "registry.wal_synced").count();
        assert!(syncs <= 1, "{label}: at most one WAL sync per creation: {names:?}");
        let durable = names.iter().position(|name| name == "create_txn.synced");
        let durable = durable.unwrap_or_else(|| panic!("{label}: never made durable: {names:?}"));
        let last_commit = names.iter().rposition(|name| name == "sqlite.commit.deferred").unwrap();
        let reply = names.iter().position(|name| name == "reply.sent").unwrap();
        assert!(
            last_commit < durable && durable < reply,
            "{label}: durable after the last commit and before the reply: {names:?}"
        );
    }

    // The daemon died right after the replies; the restarted one has both
    // terminals, adopted from their running hosts.
    let mut daemon = start_daemon(&dir);
    let terminals = request(&dir, "txn-terminal-list", "terminal.list", current);
    for created in [&first, &second] {
        let terminal = created["value"]["terminal_id"].as_str().unwrap();
        assert!(
            terminals.as_array().unwrap().iter().any(|listed| listed["id"] == terminal),
            "terminal {terminal} is gone after the restart: {terminals}"
        );
    }
    let _ = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--socket")
        .arg(dir.join("mux.sock"))
        .args(["daemon", "stop", "--force", "--end-terminals"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = daemon.kill();
    let _ = daemon.wait();
    let _ = fs::remove_dir_all(&dir);
}
