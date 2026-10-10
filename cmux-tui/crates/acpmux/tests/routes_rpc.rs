//! Routes (ROUTES R1-R3; Lawrence 2026-10-09: "if i have a claude thread
//! that i want to switch from proxy A to proxy B, we need to be able to do
//! that without quit/restarting, very seamlessly"). Over the daemon socket:
//! routes are added as files with secrets as references only, a default
//! route reaches the harness env with every other provider variable
//! scrubbed, a chat switches to another route and its harness restarts on
//! it resuming the same agent session (idle, after a turn, or now after a
//! cancel), a failed turn names its route and fallback, and a route that
//! cannot start leaves the chat where it was.
//!
//! One test: the methods read acpmux's home from ACPMUX_HOME, a process-wide
//! setting.

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
    let root = std::env::temp_dir().join(format!("acpmux-routes-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
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

    /// Start a prompt without waiting for its reply; returns once its first
    /// streamed text arrives (the turn is running).
    async fn start_prompt(&mut self, session: &str, text: &str) {
        self.2 += 1;
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        self.0.send(Message::request(self.2, "session/prompt", prompt).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("the turn did not start in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.pointer("/params/update/content/text").is_some() {
                return;
            }
        }
    }

    async fn env_of(&mut self, session: &str, name: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]});
        let (reply, text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        // A turn that ran before this one may have streamed text first.
        let at = text.rfind(&format!("{name}=")).unwrap_or(0);
        text[at..].to_owned()
    }
}

fn reason(error: &Value) -> &str {
    error["data"]["reason"].as_str().unwrap_or("")
}

fn hub(root: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "claude",
                               "env": {"ANTHROPIC_API_KEY": "zzprofilekey"}}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_switches_from_proxy_a_to_proxy_b_without_a_restart() {
    let root = scratch();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("ROUTES_TEST_KEY", "zzroutekey");
        // A provider variable the daemon inherited: a route never passes it on.
        std::env::set_var("ANTHROPIC_AUTH_TOKEN", "zzinherited");
    }
    let hub = hub(&root);
    let mut local = client(&hub, Origin::Local);

    // Routes are files; a secret is a reference, never the value.
    let a = local
        .ok(
            "_acpmux/route/add",
            json!({"id": "proxy-a", "name": "Proxy A", "kind": "subrouter",
                   "anthropicBaseUrl": "http://127.0.0.1:9/a"}),
        )
        .await;
    assert_eq!(a["kind"], "subrouter", "{a}");
    assert!(root.join("config").join("routes").join("proxy-a.toml").exists());
    local
        .ok(
            "_acpmux/route/add",
            json!({"id": "proxy-b", "kind": "custom-anthropic", "anthropicBaseUrl": "http://127.0.0.1:9/b",
                   "auth": "api-key", "secret": "env:ROUTES_TEST_KEY"}),
        )
        .await;
    let inline = local
        .err(
            "_acpmux/route/add",
            json!({"id": "leaky", "kind": "custom-anthropic", "anthropicBaseUrl": "http://127.0.0.1:9/c",
                   "auth": "api-key", "secret": "sk-ant-zzz"}),
        )
        .await;
    assert_eq!(reason(&inline), "route.secret_inline", "{inline}");
    assert!(!root.join("config").join("routes").join("leaky.toml").exists());
    let dup = local
        .err(
            "_acpmux/route/add",
            json!({"id": "proxy-a", "kind": "subrouter", "anthropicBaseUrl": "http://x"}),
        )
        .await;
    assert_eq!(reason(&dup), "route.exists", "{dup}");
    let listed = local.ok("_acpmux/route/list", json!({})).await;
    let ids: Vec<&str> =
        listed["routes"].as_array().unwrap().iter().filter_map(|r| r["id"].as_str()).collect();
    assert_eq!(ids, ["proxy-a", "proxy-b"], "{listed}");
    let shown = local.ok("_acpmux/route/show", json!({"id": "proxy-b"})).await;
    assert_eq!(shown["secret"], "env:ROUTES_TEST_KEY", "the reference only: {shown}");

    // Only the unix socket writes routes; Web never reads them.
    let mut app = client(&hub, Origin::LocalApp);
    app.err(
        "_acpmux/route/add",
        json!({"id": "x", "kind": "subrouter", "anthropicBaseUrl": "http://x"}),
    )
    .await;
    app.ok("_acpmux/route/list", json!({})).await;
    let mut web = client(&hub, Origin::Web);
    web.err("_acpmux/route/list", json!({})).await;

    // The default route reaches the harness; the profile's key and the
    // inherited token do not.
    local.ok("_acpmux/route/default.set", json!({"scope": "global", "routeId": "proxy-a"})).await;
    let new = local.ok("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let id = new["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_BASE_URL").await,
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9/a"
    );
    assert_eq!(local.env_of(&id, "ANTHROPIC_API_KEY").await, "ANTHROPIC_API_KEY=");
    assert_eq!(local.env_of(&id, "ANTHROPIC_AUTH_TOKEN").await, "ANTHROPIC_AUTH_TOKEN=");
    let agent_session =
        local.ok("_acpmux/info", json!({"sessionId": id})).await["agentSessionId"].clone();
    assert!(agent_session.is_string(), "{agent_session}");

    // Switch the chat: the harness restarts on proxy B and resumes the same
    // agent session; A's endpoint is gone and B's key is there.
    let switched = local
        .ok(
            "_acpmux/chat/route.set",
            json!({"sessionId": id, "routeId": "proxy-b", "when": "after-turn"}),
        )
        .await;
    assert_eq!(switched["applied"], "now", "an idle chat switches now: {switched}");
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_BASE_URL").await,
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9/b"
    );
    assert_eq!(local.env_of(&id, "ANTHROPIC_API_KEY").await, "ANTHROPIC_API_KEY=zzroutekey");
    let info = local.ok("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info["agentSessionId"], agent_session, "the same agent session resumed: {info}");
    let active = local.ok("_acpmux/route/list", json!({"sessionId": id})).await;
    assert_eq!(active["active"], json!({"routeId": "proxy-b", "scope": "chat"}), "{active}");

    // During a turn: "now" stops it and switches; "after-turn" lets it end.
    local.start_prompt(&id, "slow").await;
    let now = local
        .ok("_acpmux/chat/route.set", json!({"sessionId": id, "routeId": "proxy-a", "when": "now"}))
        .await;
    assert_eq!(now["applied"], "after-cancel", "{now}");
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_BASE_URL").await,
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9/a"
    );
    local.start_prompt(&id, "slow").await;
    let later =
        local.ok("_acpmux/chat/route.set", json!({"sessionId": id, "routeId": "proxy-b"})).await;
    assert_eq!(later["applied"], "after-turn", "{later}");
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_BASE_URL").await,
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9/b"
    );
    let info = local.ok("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info["agentSessionId"], agent_session, "still the same agent session: {info}");

    // A failed turn names its route and the fallback to offer; with
    // autoFallback the chat moves onto it by itself.
    local.ok("_acpmux/route/edit", json!({"id": "proxy-b", "fallback": ["proxy-a"]})).await;
    let limit = json!({"sessionId": id, "prompt": [{"type": "text", "text": "limit: now"}]});
    let (failed, _) = local.call_text("session/prompt", limit.clone()).await;
    let data = &failed["error"]["data"];
    assert_eq!(data["route"]["routeId"], "proxy-b", "{failed}");
    assert_eq!(data["fallback"], json!({"routeId": "proxy-a", "name": "Proxy A"}), "{failed}");
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_BASE_URL").await,
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9/b"
    );
    local.ok("_acpmux/route/edit", json!({"id": "proxy-b", "autoFallback": true})).await;
    let (failed, _) = local.call_text("session/prompt", limit).await;
    assert_eq!(failed["error"]["data"]["fallback"]["applied"], true, "{failed}");
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_BASE_URL").await,
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9/a"
    );

    // A route that cannot start (the local CodeRouter is not running) is
    // refused before the binding changes: the chat stays on proxy A.
    local.ok("_acpmux/route/add", json!({"id": "local", "kind": "local-coderouter"})).await;
    let down =
        local.err("_acpmux/chat/route.set", json!({"sessionId": id, "routeId": "local"})).await;
    assert_eq!(reason(&down), "route.unavailable", "{down}");
    assert_eq!(
        local.env_of(&id, "ANTHROPIC_BASE_URL").await,
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9/a"
    );

    // The probe names the failure instead of a sign-in banner.
    let probe = local.ok("_acpmux/route/test", json!({"id": "proxy-a"})).await;
    assert_eq!(probe["status"], "unreachable", "{probe}");

    // Remove keeps a backup; restore brings the same file back.
    let removed = local.ok("_acpmux/route/remove", json!({"id": "proxy-a"})).await;
    assert!(!root.join("config").join("routes").join("proxy-a.toml").exists());
    let restored = local.ok("_acpmux/route/restore", json!({"backup": removed["backup"]})).await;
    assert_eq!(restored["name"], "Proxy A", "{restored}");

    let _ = std::fs::remove_dir_all(&root);
}
