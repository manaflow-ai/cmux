//! No request waits for the journal writer (PL-daemon, best-effort
//! journal, perf-lead.md D1).
//!
//! The daemon runs with `CMUX_TUI_DEBUG_JOURNAL_WRITER_STALL_MS=1000`: the
//! journal writer waits a second before each batch, as a writer busy with
//! other work. Creates, splits, renames, moves and closes must still answer
//! well under that second: their registry commits do not ride the writer's
//! batch, and their replies do not wait for its receipt.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// How long the writer waits before each batch.
const STALL_MS: u64 = 1000;

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    fn call(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.writer, "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the socket");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == json!(self.next) && reply.get("ok").is_some() {
                assert_eq!(reply["ok"], true, "{request} failed: {reply}");
                return reply["data"].clone();
            }
        }
    }

    /// `call`, and how long its reply took.
    fn timed(&mut self, request: Value) -> (Value, u64) {
        let sent = Instant::now();
        let data = self.call(request);
        (data, sent.elapsed().as_millis() as u64)
    }
}

/// The ids of the workspace and pane whose tab is `surface`.
fn placement(client: &mut Client, surface: &Value) -> (Value, Value) {
    let tree = client.call(json!({"cmd": "list-workspaces"}));
    for workspace in tree["workspaces"].as_array().into_iter().flatten() {
        for screen in workspace["screens"].as_array().into_iter().flatten() {
            for pane in screen["panes"].as_array().into_iter().flatten() {
                for tab in pane["tabs"].as_array().into_iter().flatten() {
                    if tab == surface || &tab["id"] == surface || &tab["surface"] == surface {
                        return (workspace["id"].clone(), pane["id"].clone());
                    }
                }
            }
        }
    }
    panic!("no pane holds {surface}: {tree}");
}

#[test]
fn no_request_waits_for_a_stalled_journal_writer() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-stall-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let quiet = dir.join("quiet-shell");
    fs::write(&quiet, "#!/bin/sh\nexec sleep 600\n").unwrap();
    fs::set_permissions(&quiet, fs::Permissions::from_mode(0o755)).unwrap();
    let mut daemon = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_DEBUG_JOURNAL_WRITER_STALL_MS", STALL_MS.to_string())
        .env("SHELL", &quiet)
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    let stream = loop {
        if let Ok(stream) = UnixStream::connect(&socket) {
            break stream;
        }
        assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
        std::thread::sleep(Duration::from_millis(25));
    };
    stream.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
    let mut client =
        Client { writer: stream.try_clone().unwrap(), reader: BufReader::new(stream), next: 0 };
    let base = client.call(json!({"cmd": "new-workspace", "name": "base", "cols": 80, "rows": 24}));
    let (base_workspace, base_pane) = placement(&mut client, &base["surface"]);

    let mut slowest: Vec<(&str, u64)> = Vec::new();
    let (other, ms) =
        client.timed(json!({"cmd": "new-workspace", "name": "other", "cols": 80, "rows": 24}));
    slowest.push(("new-workspace", ms));
    let (other_workspace, _) = placement(&mut client, &other["surface"]);
    let (tab, ms) =
        client.timed(json!({"cmd": "new-tab", "pane": base_pane, "cols": 80, "rows": 24}));
    slowest.push(("new-tab", ms));
    let (_, ms) = client.timed(json!({"cmd": "split", "pane": base_pane, "dir": "right",
        "cols": 40, "rows": 24}));
    slowest.push(("split", ms));
    let (_, ms) = client.timed(json!({"cmd": "rename-workspace", "workspace": base_workspace,
        "name": "renamed"}));
    slowest.push(("rename-workspace", ms));
    let (_, ms) = client.timed(json!({"cmd": "move-tab-to-workspace", "surface": tab["surface"],
        "workspace": other_workspace}));
    slowest.push(("move-tab-to-workspace", ms));
    let (_, ms) = client.timed(json!({"cmd": "close-surface", "surface": tab["surface"]}));
    slowest.push(("close-surface", ms));

    let identity = client.call(json!({"cmd": "identify"}));
    client.call(json!({"cmd": "shutdown-daemon", "pid": identity["pid"],
        "generation": identity["generation"], "force": true, "end_terminals": true}));
    let _ = daemon.wait();
    let _ = fs::remove_dir_all(&dir);
    let waited: Vec<_> = slowest.iter().filter(|(_, ms)| *ms >= STALL_MS / 2).collect();
    assert!(
        waited.is_empty(),
        "these requests waited for the stalled journal writer ({STALL_MS} ms per batch): {waited:?}"
    );
}
