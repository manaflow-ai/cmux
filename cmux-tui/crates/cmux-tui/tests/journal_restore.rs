#![cfg(unix)]

//! Journal-based session restoration. A fresh `server start` on the same
//! session and state root reconstructs the durable topology recorded in the
//! SQLite journal: workspace identity, order, and names; screens; split trees
//! with committed ratios; tab placements; and terminal resources represented
//! honestly as exited when their processes died while the daemon was down.
//! `session journal restore preview` must agree with that applied state.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use cmux_tui_core::terminal_host_runtime::{
    TerminalHostLiveness, load_terminal_host_records, terminal_host_record_liveness,
    terminal_host_root,
};
use serde_json::{Value, json};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

struct RestoreHarness {
    child: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    state: PathBuf,
    session: String,
}

impl RestoreHarness {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-journal-restore-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut harness = Self {
            child: None,
            socket: dir.join("mux.sock"),
            state: dir.join("state"),
            session: format!("journal-restore-{name}"),
            dir,
        };
        harness.restart();
        harness
    }

    fn restart(&mut self) {
        assert!(self.child.is_none());
        let config = self.dir.join("config.json");
        let child = Command::new(bin())
            .args(["--headless", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .arg("--state")
            .arg(&self.state)
            .env("CMUX_TUI_CONFIG", &config)
            // Deterministic default shell for panes created by `split`,
            // independent of the developer or CI login shell.
            .env("SHELL", "/bin/sh")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.child = Some(child);
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            if transport::connect(&self.socket).is_ok() {
                return;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        panic!("server did not accept connections at {}", self.socket.display());
    }

    fn host_root(&self) -> PathBuf {
        terminal_host_root(&self.state, &self.session)
    }

    /// Freeze the daemon, kill every terminal host process, then kill the
    /// daemon. The daemon can observe none of the exits, so the next start
    /// has to reconcile purely from the journal plus dead-process evidence.
    fn kill_hosts_and_daemon(&mut self, expected_hosts: usize) {
        self.signal_daemon(libc::SIGSTOP);
        let records = load_terminal_host_records(&self.host_root()).unwrap_or_default();
        assert_eq!(records.len(), expected_hosts, "unexpected live terminal host records");
        for (_, record) in &records {
            // SAFETY: the record PIDs are harness-owned terminal hosts.
            let _ = unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) };
        }
        for (path, record) in &records {
            let deadline = Instant::now() + Duration::from_secs(5);
            while terminal_host_record_liveness(path, record).ok()
                != Some(TerminalHostLiveness::Dead)
            {
                assert!(Instant::now() < deadline, "terminal host survived SIGKILL");
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        let mut child = self.child.take().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        let _ = fs::remove_file(&self.socket);
    }

    fn signal_daemon(&self, signal: libc::c_int) {
        let pid = self.child.as_ref().unwrap().id() as libc::pid_t;
        // SAFETY: the harness owns this child process and passes a platform
        // signal constant.
        assert_eq!(unsafe { libc::kill(pid, signal) }, 0);
    }

    fn cli(&self, args: &[&str]) -> Value {
        let output = self.cli_raw(args);
        assert!(
            output.status.success(),
            "cli {args:?} failed: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
            panic!(
                "cli {args:?} produced invalid JSON ({error}): {}",
                String::from_utf8_lossy(&output.stdout)
            )
        })
    }

    fn cli_raw(&self, args: &[&str]) -> Output {
        Command::new(bin())
            .args(["--json", "--socket"])
            .arg(&self.socket)
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            .unwrap()
    }

    fn snapshot(&self) -> Value {
        self.cli(&["session", "current", "snapshot"])
    }
}

impl Drop for RestoreHarness {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let records = load_terminal_host_records(&self.host_root()).unwrap_or_default();
        for (_, record) in &records {
            // SAFETY: test teardown owns these dedicated host processes.
            let _ = unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) };
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn request(path: &Path, value: Value) -> Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["data"].clone()
}

fn wait_for_host_records(root: &Path, expected: usize) {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let records = load_terminal_host_records(root).unwrap_or_default();
        if records.len() == expected {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "expected {expected} terminal host records, found {}",
            records.len()
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_all_terminals_exited(harness: &RestoreHarness, expected: usize) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let snapshot = harness.snapshot();
        let terminals = snapshot["terminals"].as_array().unwrap();
        if terminals.len() == expected
            && terminals.iter().all(|terminal| terminal["lifecycle"] == "exited")
        {
            return snapshot;
        }
        assert!(
            Instant::now() < deadline,
            "terminals did not settle as exited: {}",
            snapshot["terminals"]
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The collections that describe durable topology. Focus flags, layout
/// documents, ratios, names, and ordering all live inside these values.
const TOPOLOGY_COLLECTIONS: [&str; 4] = ["workspaces", "screens", "panes", "tabs"];

#[test]
fn server_restart_restores_topology_and_reports_terminals_exited() {
    let mut harness = RestoreHarness::start("topology");

    // Workspace "One": terminal T1, split right with a default shell (T2),
    // committed ratio 0.7, and a second tab (T3) beside T1.
    let first = request(
        &harness.socket,
        json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "name":"One","cols":120,"rows":32,
        }),
    );
    let first_pane = first["pane"].as_u64().unwrap();
    request(&harness.socket, json!({"id":2,"cmd":"split","pane":first_pane,"dir":"right"}));
    let tree = request(&harness.socket, json!({"id":3,"cmd":"list-workspaces"}));
    let split = tree["workspaces"][0]["screens"][0]["layout"]["split"]
        .as_u64()
        .expect("split id after split-right");
    request(&harness.socket, json!({"id":4,"cmd":"set-split-ratio","split":split,"ratio":0.7}));
    request(
        &harness.socket,
        json!({"id":5,"cmd":"run","argv":["/bin/cat"],"pane":first_pane,"cols":120,"rows":32}),
    );
    // Workspace "Two": one terminal, so restoration must keep workspace
    // identity, order, and names across more than one workspace.
    request(
        &harness.socket,
        json!({
            "id":6,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "name":"Two","cols":80,"rows":24,
        }),
    );
    wait_for_host_records(&harness.host_root(), 4);

    let before = harness.snapshot();
    assert_eq!(before["workspaces"].as_array().unwrap().len(), 2);
    assert_eq!(before["terminals"].as_array().unwrap().len(), 4);
    let ratio_before = split_ratio(&before);
    assert!((ratio_before - 0.7).abs() < 1e-6, "committed ratio missing before stop");

    harness.kill_hosts_and_daemon(4);
    harness.restart();
    let after = wait_for_all_terminals_exited(&harness, 4);

    // Durable topology survives byte for byte: identity, order, names,
    // screens, split tree with committed ratio, tab placements.
    for collection in TOPOLOGY_COLLECTIONS {
        assert_eq!(before[collection], after[collection], "{collection} changed across restart");
    }
    assert!((split_ratio(&after) - 0.7).abs() < 1e-6, "committed ratio lost across restart");
    for terminal in after["terminals"].as_array().unwrap() {
        assert_eq!(terminal["running"], false);
        assert_eq!(terminal["lifecycle"], "exited");
        assert_eq!(terminal["exit"]["outcome"]["kind"], "unknown", "{terminal}");
        assert!(
            !terminal["tab_ids"].as_array().unwrap().is_empty(),
            "exited terminal lost its tab placements: {terminal}"
        );
    }

    // A second restart replays the preserved state without mutating it.
    wait_for_host_records(&harness.host_root(), 0);
    harness.kill_hosts_and_daemon(0);
    harness.restart();
    let again = wait_for_all_terminals_exited(&harness, 4);
    for collection in TOPOLOGY_COLLECTIONS {
        assert_eq!(
            after[collection], again[collection],
            "{collection} changed across an idle restart"
        );
    }
    assert_eq!(after["terminals"], again["terminals"], "terminals changed across an idle restart");
}

#[test]
fn restore_preview_agrees_with_applied_restoration() {
    let mut harness = RestoreHarness::start("preview");

    let first = request(
        &harness.socket,
        json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "name":"Preview","cols":100,"rows":30,
        }),
    );
    let first_pane = first["pane"].as_u64().unwrap();
    request(&harness.socket, json!({"id":2,"cmd":"split","pane":first_pane,"dir":"down"}));
    let tree = request(&harness.socket, json!({"id":3,"cmd":"list-workspaces"}));
    let split = tree["workspaces"][0]["screens"][0]["layout"]["split"]
        .as_u64()
        .expect("split id after split-down");
    request(&harness.socket, json!({"id":4,"cmd":"set-split-ratio","split":split,"ratio":0.35}));
    wait_for_host_records(&harness.host_root(), 2);

    let checkpoint = harness.cli(&[
        "session",
        "current",
        "journal",
        "checkpoint",
        "create",
        "--idempotency-key",
        "restore-preview-checkpoint",
    ]);
    assert!(checkpoint["value"]["checkpoint_id"].is_string(), "{checkpoint}");

    harness.kill_hosts_and_daemon(2);
    harness.restart();
    let live = wait_for_all_terminals_exited(&harness, 2);

    let preview = harness.cli(&[
        "session",
        "current",
        "journal",
        "restore",
        "preview",
        "--checkpoint",
        "latest",
    ]);
    assert_eq!(preview["fully_reducible"], true, "{preview}");
    let projected = &preview["state"]["session_snapshot"];

    // The reduced model and the state a fresh server actually serves must
    // agree on every durable topology collection and on the terminals'
    // honest not-running representation. The reducer orders collections by
    // (index, id) while the live projection orders them by topology, so the
    // comparison is id-keyed; ordering itself is carried by the index fields
    // and layout documents inside the compared values.
    for collection in TOPOLOGY_COLLECTIONS {
        assert_eq!(
            sorted_by_id(&projected[collection]),
            sorted_by_id(&live[collection]),
            "restore preview and applied restore disagree on {collection}"
        );
    }
    assert_eq!(
        sorted_by_id(&projected["terminals"]),
        sorted_by_id(&live["terminals"]),
        "restore preview and applied restore disagree on terminals"
    );
    assert_eq!(
        projected["cursor"]["revision"], live["cursor"]["revision"],
        "restore preview and applied restore disagree on the resource cursor"
    );
}

fn sorted_by_id(collection: &Value) -> Vec<Value> {
    let mut values = collection
        .as_array()
        .unwrap_or_else(|| panic!("collection is not an array: {collection}"))
        .clone();
    values.sort_by(|left, right| left["id"].as_str().cmp(&right["id"].as_str()));
    values
}

/// Ratio of the single split screen in the snapshot. Screen collection
/// order is not tied to workspace order, so the split screen is located by
/// shape instead of by index.
fn split_ratio(snapshot: &Value) -> f64 {
    let mut ratios = snapshot["screens"]
        .as_array()
        .expect("snapshot screens is an array")
        .iter()
        .filter_map(|screen| screen["layout"]["root"]["ratio"].as_f64());
    let ratio = ratios.next().unwrap_or_else(|| panic!("no split screen: {}", snapshot["screens"]));
    assert!(ratios.next().is_none(), "more than one split screen: {}", snapshot["screens"]);
    ratio
}

/// JSONL journal read through the CLI, parsed leniently: every JSON object
/// anywhere in the stream that carries both `kind` and `sequence` is treated
/// as one journal record.
fn journal_records(harness: &RestoreHarness, extra: &[&str]) -> Vec<Value> {
    let mut args = vec!["--jsonl", "--socket"];
    let socket = harness.socket.to_str().unwrap().to_string();
    args.push(&socket);
    let mut tail_args =
        vec!["session", "current", "journal", "read", "--max-sensitivity", "sensitive"];
    tail_args.extend_from_slice(extra);
    let output = Command::new(bin())
        .args(&args)
        .args(&tail_args)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "journal read failed: {}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    let mut records = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let Ok(value) = serde_json::from_str::<Value>(line) else { continue };
        collect_records(&value, &mut records);
    }
    records
}

fn collect_records(value: &Value, records: &mut Vec<Value>) {
    match value {
        Value::Object(map) => {
            if map.get("kind").and_then(Value::as_str).is_some() && map.contains_key("sequence") {
                records.push(value.clone());
            }
            for child in map.values() {
                collect_records(child, records);
            }
        }
        Value::Array(items) => {
            for child in items {
                collect_records(child, records);
            }
        }
        _ => {}
    }
}

fn restore_outcomes(harness: &RestoreHarness) -> Vec<Value> {
    journal_records(harness, &["--kinds", "terminal.restore.applied"])
        .into_iter()
        .filter(|record| record["kind"] == "terminal.restore.applied")
        .collect()
}

/// Wait until the journal durably holds at least `min_bytes` of
/// terminal.output content committed after `after_sequence`, and the total
/// has stopped growing. The parser accepted the bytes before this is called;
/// the wait covers the asynchronous journal ingress commit, so a SIGKILL of
/// the daemon afterwards cannot lose the tail this test asserts on.
fn wait_for_journal_output_after(harness: &RestoreHarness, after_sequence: u64, min_bytes: u64) {
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut last = u64::MAX;
    loop {
        let total: u64 = journal_records(harness, &["--kinds", "terminal.output"])
            .iter()
            .filter(|record| {
                record["sequence"]
                    .as_str()
                    .and_then(|value| value.parse::<u64>().ok())
                    .or_else(|| record["sequence"].as_u64())
                    .is_some_and(|sequence| sequence > after_sequence)
            })
            .filter_map(|record| {
                record["payload"]["byte_count"]
                    .as_str()
                    .and_then(|value| value.parse::<u64>().ok())
                    .or_else(|| record["payload"]["byte_count"].as_u64())
            })
            .sum();
        if total >= min_bytes && total == last {
            return;
        }
        last = total;
        assert!(
            Instant::now() < deadline,
            "journal never committed {min_bytes} output bytes after sequence {after_sequence} \
             (saw {total})"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn screen_text(harness: &RestoreHarness, terminal_id: &str) -> String {
    let screen = harness.cli(&["terminal", terminal_id, "screen", "read"]);
    serde_json::to_string(&screen).unwrap()
}

fn first_terminal_id(snapshot: &Value) -> String {
    snapshot["terminals"][0]["id"].as_str().unwrap().to_string()
}

#[test]
fn restored_placeholder_replays_checkpoint_content() {
    let mut harness = RestoreHarness::start("checkpoint-content");
    request(
        &harness.socket,
        json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "name":"Content","cols":120,"rows":32,
        }),
    );
    wait_for_host_records(&harness.host_root(), 1);
    let terminal_id = first_terminal_id(&harness.snapshot());

    harness.cli(&["terminal", &terminal_id, "write", "--text", "JRA_BASE_9401\n"]);
    harness.cli(&[
        "terminal",
        &terminal_id,
        "screen",
        "wait",
        "--pattern",
        "JRA_BASE_9401",
        "--timeout-ms",
        "15000",
    ]);
    let checkpoint = harness.cli(&[
        "session",
        "current",
        "journal",
        "checkpoint",
        "create",
        "--idempotency-key",
        "restore-content-checkpoint",
    ]);
    let checkpoint_id = checkpoint["value"]["checkpoint_id"].as_str().unwrap().to_string();

    harness.kill_hosts_and_daemon(1);
    harness.restart();
    wait_for_all_terminals_exited(&harness, 1);

    // The exited placeholder serves the checkpoint's renderable content.
    let text = screen_text(&harness, &terminal_id);
    assert!(text.contains("JRA_BASE_9401"), "restored screen lost checkpoint content: {text}");

    // The materialization journaled its post-replay outcome.
    let outcomes = restore_outcomes(&harness);
    assert_eq!(outcomes.len(), 1, "{outcomes:?}");
    let payload = &outcomes[0]["payload"];
    assert_eq!(payload["outcome"], "applied", "{payload}");
    assert_eq!(payload["terminal_id"], Value::String(terminal_id), "{payload}");
    assert_eq!(payload["checkpoint_id"], Value::String(checkpoint_id), "{payload}");
    assert!(
        payload["content"] == "checkpoint" || payload["content"] == "checkpoint+tail",
        "{payload}"
    );
    assert_eq!(payload["degraded"], Value::Null, "{payload}");
}

#[test]
fn restored_placeholder_replays_the_output_tail_beyond_the_checkpoint() {
    let mut harness = RestoreHarness::start("tail-content");
    request(
        &harness.socket,
        json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "name":"Tail","cols":120,"rows":32,
        }),
    );
    wait_for_host_records(&harness.host_root(), 1);
    let terminal_id = first_terminal_id(&harness.snapshot());

    harness.cli(&["terminal", &terminal_id, "write", "--text", "JRA_BASE_9401\n"]);
    harness.cli(&[
        "terminal",
        &terminal_id,
        "screen",
        "wait",
        "--pattern",
        "JRA_BASE_9401",
        "--timeout-ms",
        "15000",
    ]);
    let checkpoint = harness.cli(&[
        "session",
        "current",
        "journal",
        "checkpoint",
        "create",
        "--idempotency-key",
        "restore-tail-checkpoint",
    ]);
    let source_sequence =
        checkpoint["value"]["source_sequence"].as_str().unwrap().parse::<u64>().unwrap();

    harness.cli(&["terminal", &terminal_id, "write", "--text", "JRA_TAIL_9402\n"]);
    harness.cli(&[
        "terminal",
        &terminal_id,
        "screen",
        "wait",
        "--pattern",
        "JRA_TAIL_9402",
        "--timeout-ms",
        "15000",
    ]);
    // The marker round-tripped through the pty (echo plus /bin/cat), so at
    // least its own length must land in the journal after the checkpoint.
    wait_for_journal_output_after(&harness, source_sequence, "JRA_TAIL_9402".len() as u64);

    harness.kill_hosts_and_daemon(1);
    harness.restart();
    wait_for_all_terminals_exited(&harness, 1);

    let text = screen_text(&harness, &terminal_id);
    assert!(text.contains("JRA_BASE_9401"), "restored screen lost checkpoint content: {text}");
    assert!(text.contains("JRA_TAIL_9402"), "restored screen lost the journaled tail: {text}");

    let outcomes = restore_outcomes(&harness);
    assert_eq!(outcomes.len(), 1, "{outcomes:?}");
    assert_eq!(outcomes[0]["payload"]["content"], "checkpoint+tail", "{}", outcomes[0]);
}

#[test]
fn restored_placeholder_rebuilds_from_the_journal_without_any_checkpoint() {
    let mut harness = RestoreHarness::start("no-checkpoint");
    request(
        &harness.socket,
        json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "name":"NoCkpt","cols":100,"rows":30,
        }),
    );
    wait_for_host_records(&harness.host_root(), 1);
    let terminal_id = first_terminal_id(&harness.snapshot());

    harness.cli(&["terminal", &terminal_id, "write", "--text", "JRA_TAIL_9402\n"]);
    harness.cli(&[
        "terminal",
        &terminal_id,
        "screen",
        "wait",
        "--pattern",
        "JRA_TAIL_9402",
        "--timeout-ms",
        "15000",
    ]);
    wait_for_journal_output_after(&harness, 0, "JRA_TAIL_9402".len() as u64);

    harness.kill_hosts_and_daemon(1);
    harness.restart();
    wait_for_all_terminals_exited(&harness, 1);

    let text = screen_text(&harness, &terminal_id);
    assert!(text.contains("JRA_TAIL_9402"), "restored screen lost journaled output: {text}");

    let outcomes = restore_outcomes(&harness);
    assert_eq!(outcomes.len(), 1, "{outcomes:?}");
    assert_eq!(outcomes[0]["payload"]["content"], "tail", "{}", outcomes[0]);
    assert_eq!(outcomes[0]["payload"]["checkpoint_id"], Value::Null, "{}", outcomes[0]);
}

#[test]
fn a_session_with_no_terminals_restores_nothing() {
    let mut harness = RestoreHarness::start("empty");
    let before = harness.snapshot();
    assert_eq!(before["terminals"].as_array().unwrap().len(), 0);
    assert_eq!(before["tabs"].as_array().unwrap().len(), 0);

    let mut child = harness.child.take().unwrap();
    child.kill().unwrap();
    child.wait().unwrap();
    let _ = fs::remove_file(&harness.socket);
    harness.restart();

    let after = harness.snapshot();
    assert_eq!(after["terminals"].as_array().unwrap().len(), 0);
    assert_eq!(after["tabs"].as_array().unwrap().len(), 0);
    assert!(
        restore_outcomes(&harness).is_empty(),
        "an empty session must not journal restoration outcomes"
    );
}
