//! A new terminal's first text and its create's reply do not wait for the
//! disk (new-terminal-100x, PL-daemon).
//!
//! The daemon runs with `CMUX_TUI_DEBUG_SLOW_DURABLE_COMMIT_MS`: every flush
//! of the registry to disk takes that much longer, as on a busy disk. A
//! `new-tab` whose shell prints at once must show that text (the daemon's
//! `first_printable_output` mark, from the request's arrival) and answer
//! well before one slow flush: its commits are in the WAL, which a daemon
//! crash keeps, when it answers (`workspace_registry/wal_durability.rs`). With
//! `CMUX_TUI_DEBUG_SLOW_DISCOVERY_SYNC_MS` the
//! terminal host's discovery-file syncs are slow instead: the first text
//! may wait for one of them (the record's data barrier), not all.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// The extra time of each durable commit.
const SLOW_COMMIT_MS: u64 = 400;

fn temp_dir() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-first-text-{}-{stamp}", std::process::id()))
}

fn mark(trace: &Value, name: &str) -> Option<u64> {
    trace["marks"].as_array()?.iter().find(|mark| mark[0] == name).and_then(|mark| mark[1].as_u64())
}

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

/// One new-tab on a fresh daemon started with `debug_env`: the ms from the
/// request's arrival to its first text, and the ms the client waited for the
/// reply.
fn new_tab_first_text(debug_env: &[(&str, String)]) -> (u64, u64) {
    let dir = temp_dir();
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let spans = dir.join("spans.jsonl");
    // The default shell prints nothing, so no other terminal's output
    // journals (and flushes) while the measured create runs.
    let quiet = dir.join("quiet-shell");
    fs::write(&quiet, "#!/bin/sh\nexec sleep 600\n").unwrap();
    fs::set_permissions(&quiet, fs::Permissions::from_mode(0o755)).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_DEBUG_SPANS", &spans)
        .env("SHELL", &quiet)
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    for (key, value) in debug_env {
        command.env(key, value);
    }
    let mut daemon = command.spawn().unwrap();
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
    let tree = client.call(json!({"cmd": "list-workspaces"}));
    let pane = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|ws| ws["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .find(|pane| {
            pane["tabs"].as_array().into_iter().flatten().any(|tab| {
                tab == &base["surface"]
                    || tab["id"] == base["surface"]
                    || tab["surface"] == base["surface"]
            })
        })
        .map(|pane| pane["id"].clone())
        .unwrap_or_else(|| panic!("no pane holds the base surface: {tree}"));

    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0x100);
    let serial = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let terminal_id = format!("{:08x}00004000800{:013x}", std::process::id(), serial);
    let sent = Instant::now();
    let created = client.call(json!({"cmd": "new-tab", "pane": pane, "terminal_id": terminal_id,
        "cols": 80, "rows": 24, "env": {"SHELL": "/bin/sh"},
        "shell_args": ["-c", "printf ready; sleep 30"]}));
    let reply_ms = sent.elapsed().as_millis() as u64;
    // A terminal holder outlives the daemon on purpose: end it (and its
    // shells) with the test.
    let holder = debug_env
        .iter()
        .any(|(key, value)| *key == "CMUX_TUI_TERMINAL_HOST_MODEL" && value == "holder");
    let holder_pid = holder.then(|| {
        let resources = client
            .call(json!({"cmd": "terminal-resources", "surfaces": [created["surface"].clone()]}));
        let shell = resources["terminals"][0]["pid"].as_i64().unwrap_or(0);
        let out = Command::new("ps").args(["-o", "ppid=", "-p", &shell.to_string()]).output();
        out.ok()
            .and_then(|out| String::from_utf8_lossy(&out.stdout).trim().parse::<i32>().ok())
            .unwrap_or(0)
    });

    let deadline = Instant::now() + Duration::from_secs(30);
    let first_text_us = loop {
        let lines = fs::read_to_string(&spans).unwrap_or_default();
        let first = lines
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|trace| trace["terminal"] == terminal_id)
            .find_map(|trace| mark(&trace, "first_printable_output"));
        if let Some(first) = first {
            // The create's marks, for a failure message.
            let traces: Vec<&str> =
                lines.lines().filter(|line| line.contains(terminal_id.as_str())).collect();
            eprintln!("traces of {terminal_id}:\n{}", traces.join("\n"));
            break first;
        }
        assert!(Instant::now() < deadline, "no first_printable_output mark:\n{lines}");
        std::thread::sleep(Duration::from_millis(50));
    };
    // End every terminal host this test made: a durable host outlives a
    // killed daemon (cx-leo45).
    let identity = client.call(json!({"cmd": "identify"}));
    client.call(json!({"cmd": "shutdown-daemon", "pid": identity["pid"],
        "generation": identity["generation"], "force": true, "end_terminals": true}));
    let _ = daemon.wait();
    if let Some(pid) = holder_pid.filter(|pid| *pid > 1) {
        // SAFETY: SIGKILL of the holder this test's daemon started.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    let _ = fs::remove_dir_all(&dir);
    (first_text_us / 1000, reply_ms)
}

#[test]
fn a_new_terminals_first_text_and_reply_do_not_wait_for_the_disk() {
    let (first_text_ms, reply_ms) = new_tab_first_text(&[(
        "CMUX_TUI_DEBUG_SLOW_DURABLE_COMMIT_MS",
        SLOW_COMMIT_MS.to_string(),
    )]);
    assert!(
        first_text_ms < SLOW_COMMIT_MS,
        "the first text came {first_text_ms} ms after the request: it waited for a disk flush ({SLOW_COMMIT_MS} ms each)"
    );
    assert!(
        reply_ms < SLOW_COMMIT_MS,
        "the reply came after {reply_ms} ms: the create waited for a disk flush ({SLOW_COMMIT_MS} ms each)"
    );
}

/// The extra time of each terminal-host discovery-file sync (record, lease,
/// workspace mirror: `barrier_sync`).
const SLOW_DISCOVERY_SYNC_MS: u64 = 1000;

/// The host's discovery files (its record, liveness lease and workspace
/// mirror) are synced after its Ready, off the first text's path; only the
/// record's data barrier stays before it is published (a torn record after
/// a power cut would block an explicit reset).
#[test]
fn a_new_terminals_first_text_waits_for_at_most_one_discovery_file_sync() {
    let (first_text_ms, _) = new_tab_first_text(&[(
        "CMUX_TUI_DEBUG_SLOW_DISCOVERY_SYNC_MS",
        SLOW_DISCOVERY_SYNC_MS.to_string(),
    )]);
    assert!(
        first_text_ms < 2 * SLOW_DISCOVERY_SYNC_MS,
        "the first text came {first_text_ms} ms after the request: it waited for several discovery-file syncs ({SLOW_DISCOVERY_SYNC_MS} ms each)"
    );
}

/// Holder item 3: a terminal on the holder (`CMUX_TUI_TERMINAL_HOST_MODEL=
/// holder`) reports its first text to the create spans as a hosted one
/// does (`new_tab_first_text` fails without the `first_printable_output`
/// mark), so new-terminal-100x times it. Whether that text waits for a
/// durable commit is the hosted test's question above (registry commits,
/// the daemon-speed workstream), not this one's.
#[test]
fn a_holder_terminals_first_text_is_timed() {
    let (first_text_ms, _) =
        new_tab_first_text(&[("CMUX_TUI_TERMINAL_HOST_MODEL", "holder".to_string())]);
    assert!(first_text_ms < 30_000, "the first text came {first_text_ms} ms after the request");
}
