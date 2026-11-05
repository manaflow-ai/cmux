//! The signed-in Codex login is an account a codex chat routes onto by itself (Leo, 2026-11-05: "we
//! have code router, but we don't have the codex signed account, like auto routing permission"). A
//! codex chat on a router route that fails, with no fallback of its own, moves onto the built-in
//! `codex-login` route (the CLI's own login, no endpoint) while that login is signed in; with no
//! sign-in it is offered nothing.
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

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-codex-login-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("codex")).unwrap();
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
        "harnesses": {"fake-codex": {"argv": ["python3", FAKE], "family": "codex",
                                     "env": {"CODEX_HOME": root.join("codex")}}},
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
async fn a_failed_codex_route_moves_onto_the_signed_in_codex_login() {
    let root = scratch();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let hub = hub(&root);
    let mut local = client(&hub, Origin::Local);
    local
        .ok(
            "_acpmux/route/add",
            json!({"id": "router", "name": "Router", "kind": "custom-openai", "families": ["codex"],
                   "openaiBaseUrl": "http://127.0.0.1:9/o"}),
        )
        .await;
    local.ok("_acpmux/route/default.set", json!({"scope": "global", "routeId": "router"})).await;
    let new = local.ok("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let id = new["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(local.env_of(&id, "OPENAI_BASE_URL").await, "OPENAI_BASE_URL=http://127.0.0.1:9/o");
    let limit = json!({"sessionId": id, "prompt": [{"type": "text", "text": "limit: now"}]});

    // Signed out: the router's failure offers no account.
    let (failed, _) = local.call_text("session/prompt", limit.clone()).await;
    assert_eq!(failed["error"]["data"]["route"]["routeId"], "router", "{failed}");
    assert!(failed["error"]["data"].get("fallback").is_none(), "{failed}");

    // Signed in: the chat moves onto the Codex CLI's own login by itself.
    std::fs::write(root.join("codex").join("auth.json"), "{}").unwrap();
    let (failed, _) = local.call_text("session/prompt", limit.clone()).await;
    let fallback = &failed["error"]["data"]["fallback"];
    assert_eq!(fallback["routeId"], "codex-login", "{failed}");
    assert_eq!(fallback["applied"], true, "{failed}");
    let active = local.ok("_acpmux/route/list", json!({"sessionId": id})).await;
    assert_eq!(active["active"], json!({"routeId": "codex-login", "scope": "chat"}), "{active}");
    assert_eq!(local.env_of(&id, "OPENAI_BASE_URL").await, "OPENAI_BASE_URL=");
    // The login keeps the chat's own folder; the built-in route is not listed beside the CLI login.
    assert_eq!(
        local.env_of(&id, "CODEX_HOME").await,
        format!("CODEX_HOME={}", root.join("codex").display())
    );
    assert!(
        !active["routes"].as_array().unwrap().iter().any(|r| r["id"] == "codex-login"),
        "{active}"
    );

    // A failure on the login itself has nowhere further to go.
    let (failed, _) = local.call_text("session/prompt", limit).await;
    assert_eq!(failed["error"]["data"]["route"]["routeId"], "codex-login", "{failed}");
    assert!(failed["error"]["data"].get("fallback").is_none(), "{failed}");
}
