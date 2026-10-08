//! D13 (cx-44j.38): a remote device never controls a Claude Code session
//! the Mac started. Its process runs with the user's own Claude permission
//! rules (allow rules run tools with no acpmux request), so the remote floor
//! cannot hold there. A prompt, a permission answer or a mode set from the
//! Web is refused with `remote.local_claude_session`; reads stay. A Web
//! request may not adopt, fork, load or resume such a session either. A
//! session on another harness keeps Web control.

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
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("arlc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            "fclaude": {"argv": ["python3", FAKE], "family": "claude"},
            "ftarget": {"argv": ["python3", FAKE], "family": "target"},
        },
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        "webAskingModes": {"target": ["strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn new_session(&mut self, d: &Path, harness: &str) -> String {
        let p = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        let r = self.call("session/new", p).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", p).await
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

#[tokio::test]
async fn a_web_device_cannot_control_a_claude_session_the_mac_started_but_can_read_it() {
    let d = dir("control");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let r = web.prompt(&s, "hi").await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let text = r["error"]["message"].as_str().unwrap_or_default();
    assert!(text.contains("Start a new chat from this device"), "{text}");
    for (m, p) in [
        ("session/set_mode", json!({"sessionId": s, "modeId": "plan"})),
        (
            "_acpmux/permission_respond",
            json!({"sessionId": s, "permissionId": "p1", "optionId": "allow_once"}),
        ),
    ] {
        let r = web.call(m, p).await;
        assert_eq!(reason(&r), "remote.local_claude_session", "{m}: {r}");
    }
    // Nor change or end it.
    for (m, p) in [
        ("_acpmux/set_rules", json!({"sessionId": s, "rules": null})),
        ("_acpmux/set_policy", json!({"sessionId": s, "policy": "ask"})),
        ("_acpmux/kill", json!({"sessionId": s, "purge": true})),
        ("session/close", json!({"sessionId": s})),
    ] {
        let r = web.call(m, p).await;
        assert_eq!(reason(&r), "remote.local_claude_session", "{m}: {r}");
    }
    // Reads stay available.
    let r = web.call("_acpmux/events", json!({"sessionId": s, "limit": 50})).await;
    assert!(r["result"]["events"].is_array(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_claude_adapter_session_the_mac_started_is_refused_too() {
    let d = dir("adapter");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "fclaude").await;
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = web.prompt(&s, "hi").await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_device_cannot_copy_or_adopt_a_claude_session_the_mac_started() {
    let d = dir("copy");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let r = web
        .call("session/fork", json!({"sessionId": s, "cwd": d.join("work"), "mcpServers": []}))
        .await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let adopt = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {
        "harness": "fakeclaude", "adopt": {"agentSessionId": "fake-claude-session", "harness": "fakeclaude"}}}});
    let r = web.call("session/new", adopt).await;
    assert_eq!(reason(&r), "remote.adopt_refused", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_session_on_another_harness_keeps_web_control() {
    let d = dir("other");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "ftarget").await;
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "strict"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = web.prompt(&s, "hi").await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}
