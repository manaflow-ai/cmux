//! ACP conformance case `registry_one_click_install` (goal competitive-acp-conformance, RFD 0167
//! row 9): an agent from the ACP Registry is added with one call, shows in the harness picker,
//! and a chat on it starts and answers. That one call is what Settings > Agents > Registry's Add
//! sends (`_acpmux/harness/add {registry: ID}`, AgentHarnesses.tsx's RegistryRow). The app sends
//! it on the unix socket (AgentHarnessCenter through AcpmuxEnvironment): an add runs a program,
//! so no other origin may ask, and this client connects as `Origin::Local`.
//!
//! The agent is GitHub Copilot from the fixture registry, an `npx` agent. A stand-in `npx` on
//! PATH checks it was asked for the registry's pinned package and arguments, then runs
//! fake_agent.py, so no network and no real CLI is involved.
//!
//! One test: the registry cache is read from ACPMUX_HOME and `npx` from PATH, both process-wide.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs a stand-in agent (fake_agent.py, behind a stand-in npx).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, PermissionPolicy, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt as _;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

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
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self { tx, rx, next: 0, notes: Vec::new() }
    }

    async fn request(&mut self, m: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .expect("timeout waiting for response")
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
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_registry_agent_added_in_one_call_starts_a_chat() {
    let scratch = daemon_env::Scratch::new("acp-registry-one-click");
    let root = std::fs::canonicalize(scratch.path()).unwrap();
    let acpmux_home = root.join("acpmux-home");
    let user = root.join("config").join("harnesses");
    let bin = root.join("bin");
    let cwd = root.join("work");
    let ran = root.join("npx-argv");
    for dir in [&acpmux_home, &bin, &cwd] {
        std::fs::create_dir_all(dir).unwrap();
    }

    // The stand-in npx: only the registry's pinned package with its arguments starts the agent.
    let npx = bin.join("npx");
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > {ran}\n\
         [ \"$1\" = -y ] && [ \"$2\" = @github/copilot@1.0.93 ] && [ \"$3\" = --acp ] || exit 64\n\
         exec python3 {agent}\n",
        ran = daemon_env::sh_quote(ran.to_str().unwrap()),
        agent = daemon_env::sh_quote(FAKE_AGENT),
    );
    std::fs::write(&npx, script).unwrap();
    std::fs::set_permissions(&npx, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut dirs = vec![bin.clone()];
    dirs.extend(std::env::split_paths(&path));
    // SAFETY: the only test in this binary, before the hub or any thread that reads the env.
    unsafe {
        std::env::set_var("ACPMUX_HOME", &acpmux_home);
        std::env::set_var("PATH", std::env::join_paths(dirs).unwrap());
    }
    // The registry as the daemon caches it after its fetch.
    acpmux::registry::save(&acpmux_home, include_bytes!("fixtures/acp-registry.json")).unwrap();

    let sources = ProfileSources { user_dir: Some(user.clone()), ..ProfileSources::default() };
    let config = root.join("config.json");
    Config {
        path: Some(config.clone()),
        profile_sources: sources.clone(),
        permission_policy: PermissionPolicy::ApproveAll,
        ..Config::default()
    }
    .save()
    .unwrap();
    let mut cfg = Config::load_from_with(&config, &sources).unwrap();
    assert!(cfg.resolve_harness("github-copilot-cli").is_err(), "not a harness before the add");
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, &acpmux_home).unwrap();
    let hub = Hub::new(cfg, store);
    let mut app = Client::connect(&hub);
    app.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();

    // The Registry tab lists it, and says it starts here through npx.
    let reg = app.request("_acpmux/registry", json!({})).await.expect("registry");
    let row = reg["agents"].as_array().unwrap().iter().find(|a| a["id"] == "github-copilot-cli");
    let row = row.unwrap_or_else(|| panic!("no copilot row: {reg}")).clone();
    assert_eq!(row["launch"], "npx", "{row}");
    assert_eq!(row["installed"], false, "{row}");

    // The one click: Add on its row.
    let added = app
        .request("_acpmux/harness/add", json!({"registry": "github-copilot-cli"}))
        .await
        .unwrap_or_else(|e| panic!("the registry add failed: {e}"));
    assert_eq!(added["id"], "github-copilot-cli", "{added}");
    let profile = std::fs::read_to_string(user.join("github-copilot-cli.toml")).unwrap();
    assert!(profile.contains("@github/copilot@1.0.93"), "pinned version: {profile}");

    // The harness picker reads it with no reload or restart.
    let picker = app.request(method::MUX_HARNESSES, json!({})).await.unwrap();
    let entry = &picker["harnesses"]["github-copilot-cli"];
    assert!(!entry.is_null(), "the picker lacks the added agent: {picker}");
    assert!(picker.to_string().contains("GitHub Copilot"), "{picker}");

    // A chat on it starts (the ACP initialize and session/new through npx) and answers.
    let started = app
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd, "mcpServers": [],
                   "_meta": {"acpmux": {"harness": "github-copilot-cli", "name": "registry-chat"}}}),
        )
        .await
        .unwrap_or_else(|e| panic!("the registry agent did not start: {e}"));
    let session = started["sessionId"].as_str().expect("sessionId").to_owned();
    let argv = std::fs::read_to_string(&ran).expect("npx never ran");
    assert_eq!(argv, "-y\n@github/copilot@1.0.93\n--acp\n", "npx argv");
    let answer = app
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await
        .unwrap_or_else(|e| panic!("the registry agent did not answer: {e}"));
    assert_eq!(answer["stopReason"], "end_turn", "{answer}");
}
