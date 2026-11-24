//! Harness breadth: every agent CLI that PATH discovery knows completes a chat turn under its own
//! harness id, launched with the argv discovery gives it, through the real protocol handler.
//!
//! Leo, 2026-11-23: "mapping out the various parts of the app, our various features,
//! capabilities, and what we want to do there". The feature map's `harness-breadth` row asks for
//! at least 10 harnesses driven over ACP; its done-when is that 10 harnesses each complete a
//! chat turn on CI. This is that matrix.
//!
//! Each row puts a stand-in named exactly like the vendor's program (`gemini`, `dsh`, `pi-acp`,
//! `cursor-agent`, `agy`...) in a scratch bin folder, runs `discover_harnesses_from` over it (the
//! same table a real PATH goes through), starts a chat on the harness id discovery gave it, and
//! sends one prompt. The stand-in records the arguments it was started with, so a row also
//! proves the launch argv (`acp`, `--experimental-acp`, `--mode acp`, `agent stdio`...) and the
//! kind (ACP, Claude Code over stdio, Codex app-server bridged in process).
//!
//! What it does not prove: that the vendor's own CLI still speaks ACP the way it did. The
//! stand-ins are tests/fake_agent.py (ACP), tests/fake_claude.py (Claude Code's stream-json)
//! and tests/fake_codex_app_server.py (codex app-server).

#![cfg(unix)]

use crate::daemon_env;

use acpmux::config::{Config, HarnessKind, PermissionPolicy, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_CODEX: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");

/// The least the feature map asks for.
const AT_LEAST: usize = 10;

/// One harness: its id, the program discovery looks for, the arguments discovery adds after the
/// program, how acpmux drives it, and the stand-in that plays it.
struct Row {
    id: &'static str,
    program: &'static str,
    args: &'static [&'static str],
    kind: HarnessKind,
    stand_in: &'static str,
}

const fn acp(id: &'static str, program: &'static str, args: &'static [&'static str]) -> Row {
    Row { id, program, args, kind: HarnessKind::Acp, stand_in: FAKE_AGENT }
}

/// Every harness PATH discovery adds by its program name (`config/discover.rs`). Not here:
/// `claude-sr` (the subrouter pool's `sr`, the same Claude Code adapter as `claude`) and `muse`
/// (an ACP harness only beside the separate `muse-acp` adapter).
const ROWS: &[Row] = &[
    Row {
        id: "claude",
        program: "claude",
        args: &[],
        kind: HarnessKind::ClaudeStdio,
        stand_in: FAKE_CLAUDE,
    },
    Row {
        id: "codex",
        program: "codex",
        args: &["app-server"],
        kind: HarnessKind::Acp,
        stand_in: FAKE_CODEX,
    },
    acp("gemini", "gemini", &["--experimental-acp"]),
    acp("opencode", "opencode", &["acp"]),
    acp("opencode-v2", "opencode2", &["acp"]),
    acp("deepseek", "dsh", &["--profile", "acp"]),
    acp("pi", "pi-acp", &[]),
    acp("omp", "omp", &["acp"]),
    acp("prime", "prime-agent", &["--mode", "acp"]),
    acp("grok", "grok", &["agent", "stdio"]),
    acp("cursor", "cursor-agent", &["acp"]),
    acp("hermes", "hermes", &["acp"]),
    acp("openclaw", "openclaw", &["acp"]),
    acp("antigravity", "agy", &["acp"]),
];

/// A scratch folder with `bin/<program>` for every row: a shell script that appends its
/// arguments to `bin/<program>.argv`, then runs the row's stand-in with them.
fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-breadth-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("bin")).unwrap();
    std::fs::create_dir_all(root.join("work")).unwrap();
    std::fs::create_dir_all(root.join("acpmux")).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    for row in ROWS {
        let bin = root.join("bin").join(row.program);
        let log = root.join("bin").join(format!("{}.argv", row.program));
        // Each argument ends in a NUL and each start in \x01: arguments may hold newlines.
        let script = format!(
            "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done >> {log}\nprintf '\\001' >> {log}\nexec python3 {} \"$@\"\n",
            daemon_env::sh_quote(row.stand_in),
            log = daemon_env::sh_quote(log.to_string_lossy()),
        );
        std::fs::write(&bin, script).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    root
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
    notes: Vec<(String, Value)>,
}

impl Client {
    fn connect(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::LocalApp));
        Self { tx, rx, next: 0, notes: Vec::new() }
    }

    async fn request(&mut self, m: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .unwrap_or_else(|_| panic!("no answer to {m} in 60 s"))
                .expect("connection closed");
            match Message::parse(&line).unwrap() {
                Message::Response { id: rid, result, error } if rid == id => {
                    return match error {
                        Some(e) => Err(e.message),
                        None => Ok(result.unwrap_or(Value::Null)),
                    };
                }
                Message::Notification { method, params } => {
                    self.notes.push((method, params.unwrap_or(Value::Null)));
                }
                _ => {}
            }
        }
    }

    /// The agent text the session streamed so far.
    fn said(&self, session: &str) -> String {
        self.notes
            .iter()
            .filter(|(m, p)| m == "session/update" && p["sessionId"] == session)
            .filter(|(_, p)| p["update"]["sessionUpdate"] == "agent_message_chunk")
            .filter_map(|(_, p)| p["update"]["content"]["text"].as_str())
            .collect()
    }
}

/// Discovery over the scratch bin folder alone: the real table, a PATH holding only stand-ins.
fn discovered(bin: &Path) -> std::collections::BTreeMap<String, acpmux::config::HarnessProfile> {
    let bin = bin.to_owned();
    acpmux::config::discover_harnesses_from(None, &move |name: &str| {
        let path = bin.join(name);
        path.is_file().then(|| path.to_string_lossy().into_owned())
    })
}

/// Discovery gives every row its harness id, its program and its launch arguments.
#[test]
fn discovery_names_every_row_with_its_launch_argv() {
    let root = scratch();
    let bin = root.join("bin");
    let found = discovered(&bin);
    for row in ROWS {
        let profile = found.get(row.id).unwrap_or_else(|| {
            panic!("{}: not discovered from {}; found {:?}", row.id, row.program, found.keys())
        });
        let mut want = vec![bin.join(row.program).to_string_lossy().into_owned()];
        want.extend(row.args.iter().map(|a| a.to_string()));
        assert_eq!(profile.argv, want, "{}", row.id);
        assert_eq!(profile.kind, row.kind, "{}", row.id);
    }
    assert!(ROWS.len() >= AT_LEAST, "{} harnesses, the map asks for {AT_LEAST}", ROWS.len());
    let _ = std::fs::remove_dir_all(&root);
}

/// Each discovered harness starts a chat under its own id and completes one turn; the program
/// it ran got exactly discovery's arguments.
#[tokio::test]
async fn every_discovered_harness_completes_a_chat_turn() {
    let root = scratch();
    let bin = root.join("bin");
    let path = root.join("acpmux").join("config.json");
    Config {
        path: Some(path.clone()),
        profile_sources: ProfileSources::none(),
        permission_policy: PermissionPolicy::ApproveAll,
        ..Config::default()
    }
    .save()
    .unwrap();
    let mut cfg = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
    cfg.harnesses.extend(discovered(&bin));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, &root.join("acpmux")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut c = Client::connect(&hub);
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();

    let mut passed = Vec::new();
    let mut failed = Vec::new();
    for row in ROWS {
        let outcome = turn(&mut c, &root, row).await;
        match outcome {
            Ok(()) => passed.push(row.id),
            Err(why) => failed.push(format!("{}: {why}", row.id)),
        }
    }
    // One line per run, read by CI logs and the feature map: how many harnesses completed a turn.
    eprintln!("harness breadth: {} of {} completed a turn: {passed:?}", passed.len(), ROWS.len());
    assert!(failed.is_empty(), "harnesses that did not complete a turn:\n{}", failed.join("\n"));
    assert!(
        passed.len() >= AT_LEAST,
        "{} harnesses completed a turn, want {AT_LEAST}",
        passed.len()
    );
    let _ = std::fs::remove_dir_all(&root);
}

async fn turn(c: &mut Client, root: &Path, row: &Row) -> Result<(), String> {
    let cwd = root.join("work");
    let started = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd, "mcpServers": [],
                   "_meta": {"acpmux": {"harness": row.id, "name": format!("breadth-{}", row.id)}}}),
        )
        .await
        .map_err(|e| format!("session/new: {e}"))?;
    let session =
        started["sessionId"].as_str().ok_or(format!("no sessionId: {started}"))?.to_owned();
    let text = format!("hello from {}", row.id);
    let answer = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .map_err(|e| format!("session/prompt: {e}"))?;
    if answer["stopReason"] != "end_turn" {
        return Err(format!("stopReason {}", answer["stopReason"]));
    }
    if c.said(&session).trim().is_empty() {
        return Err("the turn ended with no agent text".into());
    }
    // The program discovery found ran with discovery's arguments, in order (acpmux may add its
    // own around them: the Codex bridge puts `-c` options before `app-server`).
    let log = root.join("bin").join(format!("{}.argv", row.program));
    let starts = std::fs::read(&log).map_err(|e| format!("{} never ran: {e}", row.program))?;
    let starts = String::from_utf8_lossy(&starts);
    let want: Vec<&str> = row.args.to_vec();
    let ran_with = |start: &str| {
        let args: Vec<&str> = start.split('\0').filter(|a| !a.is_empty()).collect();
        want.is_empty() || args.windows(want.len()).any(|w| w == want.as_slice())
    };
    // Every start ends in \x01, so a start with no arguments is an empty piece before one.
    let mut pieces = starts.split('\u{1}');
    pieces.next_back();
    if !pieces.any(ran_with) {
        return Err(format!("{} never ran with {want:?}: {starts:?}", row.program));
    }
    let _ = c.request(method::SESSION_CLOSE, json!({"sessionId": session})).await;
    Ok(())
}
