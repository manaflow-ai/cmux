//! A new workspace's terminal host writes its record once, naming the
//! workspace, and its create answers without a second synced record write
//! (PL-daemon).
//!
//! The daemon runs with `CMUX_TUI_DEBUG_SLOW_DISCOVERY_SYNC_MS`: every sync
//! of a terminal-host discovery file (record, lease, workspace mirror) takes
//! that much longer, as on a busy disk. A `new-workspace` used to launch its
//! host with no workspace in the record and then rewrite the record with a
//! data and a directory sync on the request path (the deprecated recovery
//! mirror): three slow syncs before the reply. Now the host's first record
//! names the workspace, so at most the record's own data barrier is left.
//! A tab moved to another workspace rewrote its host's record (two syncs) on
//! the request path too; now the rewrite is queued off it.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// The extra time of each discovery-file sync.
const SLOW_SYNC_MS: u64 = 1000;

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
}

/// The id of the workspace whose pane holds `surface`.
fn workspace_of(client: &mut Client, surface: &Value) -> Value {
    let tree = client.call(json!({"cmd": "list-workspaces"}));
    for workspace in tree["workspaces"].as_array().into_iter().flatten() {
        for screen in workspace["screens"].as_array().into_iter().flatten() {
            for pane in screen["panes"].as_array().into_iter().flatten() {
                for tab in pane["tabs"].as_array().into_iter().flatten() {
                    if tab == surface || &tab["id"] == surface || &tab["surface"] == surface {
                        return workspace["id"].clone();
                    }
                }
            }
        }
    }
    panic!("no pane holds {surface}: {tree}");
}

#[test]
fn a_new_workspace_answers_after_at_most_one_discovery_file_sync() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-ws-sync-{}-{stamp}", std::process::id()));
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
        .env("CMUX_TUI_DEBUG_SLOW_DISCOVERY_SYNC_MS", SLOW_SYNC_MS.to_string())
        .env("CMUX_TUI_DEBUG_SPANS", dir.join("spans.jsonl"))
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
    // The first workspace starts the spare host the next one adopts.
    client.call(json!({"cmd": "new-workspace", "name": "base", "cols": 80, "rows": 24}));
    let mut slowest = 0;
    let mut created = Vec::new();
    for round in 0..3 {
        let sent = Instant::now();
        created.push(client.call(
            json!({"cmd": "new-workspace", "name": format!("w{round}"), "cols": 80, "rows": 24}),
        ));
        slowest = slowest.max(sent.elapsed().as_millis() as u64);
    }
    // A tab moved to another workspace renames its host's recovery mirror;
    // the move does not wait for that write.
    let target = workspace_of(&mut client, &created[2]["surface"]);
    let sent = Instant::now();
    client.call(json!({"cmd": "move-tab-to-workspace", "surface": created[0]["surface"],
        "workspace": target}));
    let move_ms = sent.elapsed().as_millis() as u64;
    assert_eq!(workspace_of(&mut client, &created[0]["surface"]), target, "the tab did not move");
    // End every terminal host this test made: a durable host outlives a
    // killed daemon (cx-leo45).
    let identity = client.call(json!({"cmd": "identify"}));
    client.call(json!({"cmd": "shutdown-daemon", "pid": identity["pid"],
        "generation": identity["generation"], "force": true, "end_terminals": true}));
    let _ = daemon.wait();
    // The creates' marks, for a failure message.
    eprintln!("{}", fs::read_to_string(dir.join("spans.jsonl")).unwrap_or_default());
    let _ = fs::remove_dir_all(&dir);
    assert!(
        move_ms < SLOW_SYNC_MS,
        "a tab move answered after {move_ms} ms: it waited for its host record's rewrite ({SLOW_SYNC_MS} ms per sync)"
    );
    assert!(
        slowest < 2 * SLOW_SYNC_MS,
        "a new workspace answered after {slowest} ms: it waited for more than one discovery-file sync ({SLOW_SYNC_MS} ms each)"
    );
}
