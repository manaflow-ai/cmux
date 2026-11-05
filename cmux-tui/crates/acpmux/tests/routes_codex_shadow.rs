//! A second ChatGPT account is a shadow home that shares everything but its login with the Codex
//! CLI's own (Leo, 2026-11-05, pointing at T3 Code: "Shadow home path ... Keeps auth.json separate
//! while sharing state from CODEX_HOME"), and routing moves a chat between the enabled, signed-in
//! logins by itself (Leo: "the codex signed account, like auto routing permission"). A codex chat
//! on the CLI's own login that hits its limit moves onto the shadow account and resumes the same
//! conversation there; a limit there moves it back; an account turned off is never moved onto.
//!
//! One test: the methods read acpmux's and Codex's homes from ACPMUX_HOME and CODEX_HOME, process-wide.

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

/// A Codex login as `codex login` leaves it: tokens (an empty `auth.json` is not one).
const SIGNED_IN: &str = r#"{"tokens": {"access_token": "x"}}"#;

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-codex-shadow-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("base")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
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

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let (reply, _) = self.call_text(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    async fn err(&mut self, m: &str, params: Value) -> Value {
        let (reply, _) = self.call_text(m, params).await;
        reply.get("error").cloned().unwrap_or_else(|| panic!("{m} did not fail: {reply}"))
    }

    async fn env_of(&mut self, session: &str, name: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]});
        let (reply, mut text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        // The reply can overtake the turn's last streamed update.
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
        // A turn that ran before this one may have streamed text first.
        let at = text.rfind(&format!("{name}=")).unwrap_or(0);
        text[at..].to_owned()
    }
}

fn hub(root: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake-codex": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake-codex",
        "permissionPolicy": "approve-all",
        // No automatic continuation runs behind this test's own prompts (`auto_resume.rs`).
        "autoResumeDelaysMs": [],
    }))
    .unwrap();
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_codex_chat_moves_between_its_signed_in_logins_and_keeps_its_conversation() {
    let root = scratch();
    let (base, work) = (root.join("base"), root.join("work"));
    std::fs::write(base.join("auth.json"), SIGNED_IN).unwrap();
    std::fs::write(base.join("config.toml"), "model = 'x'").unwrap();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("CODEX_HOME", &base);
    }
    let hub = hub(&root);
    let mut local = client(&hub, Origin::Local);
    let added = local
        .ok(
            "_acpmux/route/add",
            json!({"id": "work", "name": "Work", "kind": "direct-subscription", "families": ["codex"],
                   "accountHome": work, "shadow": true}),
        )
        .await;
    assert_eq!(added["shadowOf"], json!(base), "{added}");
    assert_eq!(std::fs::read_to_string(work.join("config.toml")).unwrap(), "model = 'x'");
    assert!(!work.join("auth.json").exists(), "the shadow keeps its own login");

    let new = local.ok("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let id = new["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(local.env_of(&id, "CODEX_HOME").await, format!("CODEX_HOME={}", base.display()));
    let started =
        local.ok("_acpmux/info", json!({"sessionId": id})).await["agentSessionId"].clone();
    let limit = json!({"sessionId": id, "prompt": [{"type": "text", "text": "limit: now"}]});

    // The shadow is not signed in yet (an empty login file is not a login): nothing to move onto.
    std::fs::write(work.join("auth.json"), "{}").unwrap();
    let (failed, _) = local.call_text("session/prompt", limit.clone()).await;
    assert!(failed["error"]["data"].get("fallback").is_none(), "{failed}");

    // Signed in: the limit moves the chat onto it, in the same conversation.
    std::fs::write(work.join("auth.json"), SIGNED_IN).unwrap();
    let (failed, _) = local.call_text("session/prompt", limit.clone()).await;
    assert_eq!(failed["error"]["data"]["fallback"]["routeId"], "work", "{failed}");
    assert_eq!(failed["error"]["data"]["fallback"]["applied"], true, "{failed}");
    assert_eq!(local.env_of(&id, "CODEX_HOME").await, format!("CODEX_HOME={}", work.display()));
    let info = local.ok("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info["agentSessionId"], started, "the same conversation: {info}");

    // Its limit moves the chat back onto the CLI's own login.
    let (failed, _) = local.call_text("session/prompt", limit.clone()).await;
    assert_eq!(failed["error"]["data"]["fallback"]["routeId"], "codex-login", "{failed}");
    assert_eq!(local.env_of(&id, "CODEX_HOME").await, format!("CODEX_HOME={}", base.display()));

    // The accounts list names both, signed in and on; one turned off is never moved onto.
    let listed = local.ok("_acpmux/accounts", json!({"family": "codex"})).await;
    let ids: Vec<&str> =
        listed["accounts"].as_array().unwrap().iter().filter_map(|a| a["id"].as_str()).collect();
    assert_eq!(ids, ["codex-login", "work"], "{listed}");
    assert_eq!(listed["accounts"][1]["signedIn"], true, "{listed}");
    assert_eq!(listed["accounts"][1]["shadowOf"], json!(base), "{listed}");
    let off = local.ok("_acpmux/account/set", json!({"id": "work", "enabled": false})).await;
    assert_eq!(off["enabled"], false, "{off}");
    let mut app = client(&hub, Origin::LocalApp);
    app.err("_acpmux/account/set", json!({"id": "work", "enabled": true})).await;
    let (failed, _) = local.call_text("session/prompt", limit.clone()).await;
    assert!(failed["error"]["data"].get("fallback").is_none(), "{failed}");
    // Not as a named fallback with autoFallback either.
    local
        .ok(
            "_acpmux/route/edit",
            json!({"id": "codex-login", "fallback": ["work"], "autoFallback": true}),
        )
        .await;
    let (failed, _) = local.call_text("session/prompt", limit).await;
    assert!(failed["error"]["data"].get("fallback").is_none(), "{failed}");
    assert_eq!(local.env_of(&id, "CODEX_HOME").await, format!("CODEX_HOME={}", base.display()));

    // An edit that clears `enabled` turns the account back on.
    let edited = local.ok("_acpmux/route/edit", json!({"id": "work", "enabled": null})).await;
    assert_eq!(edited["enabled"], true, "{edited}");
    // A shadow needs a folder of its own.
    local
        .err(
            "_acpmux/route/add",
            json!({"id": "homeless", "kind": "direct-subscription", "families": ["codex"],
                   "shadow": true}),
        )
        .await;
}
