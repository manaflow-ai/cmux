//! Registry commits ride the journal writer's batch on a real headless
//! daemon: under terminal output, a terminal create commits its terminal
//! records (reserved, ready) and its effect receipt as writer intents, and a
//! topology write (`rename-workspace`) commits its resource patch as one (one
//! shared fsync per batch). None of them runs its own transaction on the
//! request thread, and the journal writer never takes the workspace registry
//! lock while requests wait for its receipts.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

/// Creates measured under output load. Each create commits two terminal
/// records (reserved, ready) and one effect receipt with its topology patch.
const CREATES: usize = 8;
/// Writer intents per create: terminal reserved, terminal ready, effect.
const INTENTS_PER_CREATE: usize = 3;
/// Topology writes measured under output load, one resource patch each.
const RENAMES: usize = 6;
const BUSY_TERMINALS: usize = 3;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-intents-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let tree = try_request(&self.socket, &serde_json::json!({"cmd": "list-workspaces"}));
        for workspace in
            tree.iter().flat_map(|tree| tree["data"]["workspaces"].as_array()).flatten()
        {
            let _ = try_request(
                &self.socket,
                &serde_json::json!({
                    "cmd": "close-workspace",
                    "key": workspace["key"],
                    "end_terminals": true,
                }),
            );
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// One request on a fresh connection; the whole response, or `None` when the
/// daemon cannot be reached. Never panics, so teardown can use it.
fn try_request(path: &Path, value: &serde_json::Value) -> Option<serde_json::Value> {
    let stream = transport::connect(path).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = try_request(path, &value).expect("daemon answers");
    assert_eq!(response["ok"], true, "{value} failed: {response}");
    response["data"].clone()
}

fn write_path(path: &Path) -> serde_json::Value {
    let stats =
        request(path, serde_json::json!({"cmd": "server-stats", "include": ["write_path"]}));
    stats["write_path"].clone()
}

fn counter(section: &serde_json::Value, name: &str) -> u64 {
    section[name].as_u64().unwrap_or_else(|| panic!("write_path.{name} missing: {section}"))
}

#[test]
fn terminal_creates_under_output_commit_effect_receipts_in_writer_batches() {
    let daemon = Daemon::start("creates");
    request(
        &daemon.socket,
        serde_json::json!({"cmd": "new-workspace", "name": "intents", "cols": 80, "rows": 24}),
    );
    let tree = request(&daemon.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let workspace = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "intents")
        .map(|workspace| workspace["id"].clone())
        .unwrap_or_else(|| panic!("list-workspaces omitted the new workspace: {tree}"));
    for _ in 0..BUSY_TERMINALS {
        request(
            &daemon.socket,
            serde_json::json!({
                "cmd": "create-terminal",
                "workspace": workspace,
                "argv": ["/bin/sh", "-c", "while :; do echo journal-effect-intents-output; sleep 0.01; done"],
                "cols": 80,
                "rows": 24,
            }),
        );
    }
    let before = write_path(&daemon.socket);
    for _ in 0..CREATES {
        request(
            &daemon.socket,
            serde_json::json!({
                "cmd": "create-terminal",
                "workspace": workspace,
                "argv": ["/bin/sh"],
                "cols": 80,
                "rows": 24,
            }),
        );
    }
    for index in 0..RENAMES {
        request(
            &daemon.socket,
            serde_json::json!({
                "cmd": "rename-workspace",
                "workspace": workspace,
                "name": format!("intents-{index}"),
            }),
        );
    }
    let after = write_path(&daemon.socket);
    let delta = |name: &str| counter(&after, name) - counter(&before, name);
    let expected = (CREATES * INTENTS_PER_CREATE + RENAMES) as u64;
    assert!(
        delta("effect_intents") >= expected,
        "{CREATES} creates and {RENAMES} renames committed only {} of {expected} registry \
         commits as writer intents: {after}",
        delta("effect_intents")
    );
    assert!(delta("effect_intent_batches") > 0, "no writer batch carried an intent: {after}");
    assert_eq!(delta("effect_intent_failures"), 0, "writer intents failed: {after}");
    assert_eq!(
        delta("request_effect_commits"),
        0,
        "creates or renames committed on the request thread: {after}"
    );
    assert_eq!(
        counter(&after, "writer_registry_locks"),
        0,
        "the journal writer took the workspace registry lock: {after}"
    );
}
