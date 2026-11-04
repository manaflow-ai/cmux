//! The Agent setup viewer's requests (`_acpmux/agent_setup`, `_acpmux/agent_setup/save`): what a
//! chat's agent is told beside the person's messages, read from the same functions the cmux MCP
//! servers answer with, and the chat's preset's system prompt, which only the unix socket and the
//! app's pane proven as the person read or save.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";
const PROMPT: &str = "You review diffs for the team.\n";
const EDITED: &str = "You review diffs for the team, briefly.\n";

/// A private state directory (the config's own, which holds `presets/`), removed when dropped.
struct State(PathBuf);

impl Drop for State {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn hub(state: &State) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.path = Some(state.0.join("config.json"));
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    async fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        let mut c = Client(in_tx, out_rx, 0);
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    /// The app's agent pane, proven as the person with this launch's key (`hub/person.rs`).
    async fn person_app(hub: &Arc<Hub>) -> Self {
        hub.person.enroll(KEY, true).unwrap();
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::LocalApp,
            ConnAuth::LocalApp,
        ));
        let mut c = Client(in_tx, out_rx, 0);
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &r["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            KEY,
            acpmux::hub::person::TRANSPORT_APP,
            challenge["nonce"].as_str().unwrap_or_else(|| panic!("{r}")),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

/// A chat started over the unix socket from preset `tuned`, which carries [`PROMPT`].
async fn chat(hub: &Arc<Hub>) -> (Client, String) {
    let mut local = Client::new(hub, Origin::Local, ConnAuth::Local).await;
    let set = local
        .call(
            "_acpmux/presets",
            json!({"name": "tuned", "set": {"harness": "fakeclaude", "systemPrompt": PROMPT}}),
        )
        .await;
    assert!(set.get("error").is_none(), "{set}");
    let r = local
        .call(
            "session/new",
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"preset": "tuned"}}}),
        )
        .await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    (local, id)
}

fn state(name: &str) -> State {
    let dir =
        std::env::temp_dir().join(format!("acpmux-agent-setup-{name}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    State(dir)
}

#[tokio::test]
async fn the_setup_names_the_harness_prompt_and_reads_the_preset_prompt() {
    let state = state("read");
    let hub = hub(&state);
    let (mut local, id) = chat(&hub).await;
    let r = local.call("_acpmux/agent_setup", json!({"sessionId": id})).await;
    let setup = &r["result"];
    assert_eq!(setup["family"], "claude", "{r}");
    assert_eq!(setup["harnessPrompt"]["source"], "Claude Code", "{r}");
    assert!(setup["servers"].is_array(), "{r}");
    assert_eq!(setup["preset"]["name"], "tuned", "{r}");
    assert_eq!(setup["preset"]["systemPrompt"], PROMPT, "{r}");
    assert_eq!(setup["preset"]["editable"], true, "{r}");
}

#[tokio::test]
async fn the_persons_pane_saves_the_preset_prompt_for_new_sessions() {
    let state = state("save");
    let hub = hub(&state);
    let (_local, id) = chat(&hub).await;
    let mut app = Client::person_app(&hub).await;
    let read = app.call("_acpmux/agent_setup", json!({"sessionId": id})).await;
    assert_eq!(read["result"]["preset"]["systemPrompt"], PROMPT, "{read}");
    assert_eq!(read["result"]["preset"]["editable"], true, "{read}");
    let saved = app
        .call("_acpmux/agent_setup/save", json!({"sessionId": id, "systemPrompt": EDITED}))
        .await;
    assert_eq!(saved["result"]["preset"]["systemPrompt"], EDITED, "{saved}");
    let file = state.0.join("presets").join("tuned").join("system.md");
    assert_eq!(std::fs::read_to_string(file).unwrap(), EDITED);
    // A plain string only: the prompt's text or null.
    let bad =
        app.call("_acpmux/agent_setup/save", json!({"sessionId": id, "systemPrompt": 3})).await;
    assert!(bad.get("error").is_some(), "{bad}");
}

#[tokio::test]
async fn no_other_connection_reads_or_saves_the_preset_prompt() {
    let state = state("refuse");
    let hub = hub(&state);
    let (_local, id) = chat(&hub).await;
    // The app's pane that did not prove the person key, and a Web client.
    for (origin, auth) in
        [(Origin::LocalApp, ConnAuth::LocalApp), (Origin::Web, ConnAuth::ListenerToken)]
    {
        let mut c = Client::new(&hub, origin, auth).await;
        let read = c.call("_acpmux/agent_setup", json!({"sessionId": id})).await;
        assert!(!read.to_string().contains("review diffs"), "{origin:?} read it: {read}");
        if read.get("result").is_some() {
            assert_eq!(read["result"]["preset"]["editable"], false, "{origin:?}: {read}");
            assert_eq!(read["result"]["preset"]["hasSystemPrompt"], true, "{origin:?}: {read}");
        }
        let saved = c
            .call("_acpmux/agent_setup/save", json!({"sessionId": id, "systemPrompt": "be evil"}))
            .await;
        assert!(saved.get("error").is_some(), "{origin:?} saved it: {saved}");
    }
    let file = state.0.join("presets").join("tuned").join("system.md");
    assert_eq!(std::fs::read_to_string(file).unwrap(), PROMPT);
}
