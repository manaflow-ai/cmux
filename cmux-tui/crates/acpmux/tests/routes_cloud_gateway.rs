//! The `cmux` profile on a cmux Cloud machine (hq#11225; Leo, 2026-11-15: "We're doing it through
//! the gateway."). A Cloud machine runs no local CodeRouter, so its `cmux` route used to refuse
//! every start with `route.unavailable`. There the route now goes to the machine's own model plane
//! (`https://coderouter.cmux.internal`, from the image's model-plane env file) at the gateway's
//! model router path, with the image's public placeholder key: the machine's edge adds its own
//! credential, so no token is ever on the machine. A Mac with no CodeRouter still refuses.
//!
//! One test: the methods read acpmux's home from ACPMUX_HOME, a process-wide setting.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const ORIGIN: &str = "https://coderouter.cmux.internal";
const PLACEHOLDER: &str = "cmux-vm-edge-placeholder";

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-cloud-gateway-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    for dir in ["home", "user", "config/harnesses", "mac", "vm/etc/cmux"] {
        std::fs::create_dir_all(root.join(dir)).unwrap();
    }
    // A Cloud machine's records, as the image writes them.
    std::fs::write(root.join("vm/etc/cmux/vm-kind"), "owner\n").unwrap();
    std::fs::write(
        root.join("vm/etc/cmux/model-plane.env"),
        format!(
            "export CMUX_CODEROUTER_URL='{ORIGIN}'\nexport ANTHROPIC_API_KEY='{PLACEHOLDER}'\n"
        ),
    )
    .unwrap();
    std::fs::canonicalize(&root).unwrap()
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no reply in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn new_chat(&mut self, cwd: &Path) -> Value {
        let (reply, _) = self
            .call_text("session/new", json!({"cwd": cwd, "mcpServers": [], "harness": "cmux-fake"}))
            .await;
        reply
    }

    async fn env_of(&mut self, session: &str, name: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]});
        let (reply, mut text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        while !text.contains(&format!("{name}=")) {
            let line = tokio::time::timeout(Duration::from_secs(10), self.1.recv())
                .await
                .unwrap_or_else(|_| panic!("no env text: reply {reply}, text {text:?}"))
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
        let at = text.rfind(&format!("{name}=")).unwrap_or(0);
        text[at..].lines().next().unwrap_or("").to_owned()
    }
}

/// A hub whose `cmux-fake` profile is a stand-in Claude on the built-in `cmux` route, as the
/// built-in `cmux` profile is, reading the machine's records under `marker_root`.
fn hub(root: &Path, marker_root: PathBuf) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"cmux-fake": {"argv": ["python3", FAKE], "family": "claude",
                                    "env": {"ACPMUX_PROFILE_ROUTE": "cmux",
                                            "HOME": root.join("user")}}},
        "defaultHarness": "cmux-fake",
        "permissionPolicy": "approve-all",
        "autoResumeDelaysMs": [],
    }))
    .unwrap();
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_vm_marker_root(marker_root);
    hub
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_cmux_profile_starts_on_a_cloud_machine_through_its_gateway() {
    let root = scratch();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let cwd = root.join("config");

    // A Mac with no local CodeRouter: the route still refuses, and names why.
    let mac = hub(&root, root.join("mac"));
    let mut local = client(&mac);
    let refused = local.new_chat(&cwd).await;
    assert_eq!(refused["error"]["data"]["reason"], "route.unavailable", "{refused}");

    // A Cloud machine (no local CodeRouter either): the chat starts on the gateway's model router
    // path with the public placeholder, and no other credential reaches Claude.
    let vm = hub(&root, root.join("vm"));
    let mut local = client(&vm);
    let started = local.new_chat(&cwd).await;
    assert!(started.get("error").is_none(), "{started}");
    let id = started["result"]["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_BASE_URL").await,
        format!("ANTHROPIC_BASE_URL={ORIGIN}/router")
    );
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_AUTH_TOKEN").await,
        format!("ANTHROPIC_AUTH_TOKEN={PLACEHOLDER}")
    );
    assert_eq!(local.env_of(&id, "ANTHROPIC_API_KEY").await, "ANTHROPIC_API_KEY=");

    let _ = std::fs::remove_dir_all(&root);
}
