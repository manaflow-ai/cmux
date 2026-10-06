//! `_acpmux/web_modes`: the native relay reads the remote guard's own
//! asking-mode table and lists over the unix socket, never over a
//! WebSocket connection.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fcodex": {"argv": ["python3", FAKE], "family": "codex"},
            "fnomode": {"argv": ["python3", FAKE], "env": {"FAKE_NO_MODES": "1"}},
        },
        "defaultHarness": "fcodex",
        "permissionPolicy": "ask",
        // "agent" (Codex's non-asking default) is refused; "ask-more" is added.
        "webAskingModes": {"codex": ["agent", "ask-more"], "mine": ["careful"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn call(hub: &Arc<Hub>, origin: Origin, m: &str, params: Value) -> Value {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    in_tx.send(Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(20), out_rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

async fn session(hub: &Arc<Hub>, harness: &str) -> String {
    let p = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
    let r = call(hub, Origin::Local, "session/new", p).await;
    r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
}

#[tokio::test]
async fn the_unix_socket_reads_the_table_the_lists_and_a_session() {
    let hub = hub();
    let r = call(&hub, Origin::Local, "_acpmux/web_modes", json!({})).await;
    let v = &r["result"];
    assert_eq!(v["families"]["claude"], json!(["default", "plan"]), "{r}");
    assert_eq!(v["families"]["opencode"], json!(["plan"]), "{r}");
    // The refused entry is not there; the asking default stays first.
    assert_eq!(v["families"]["codex"], json!(["read-only", "ask-more"]), "{r}");
    assert_eq!(v["families"]["mine"], json!(["careful"]), "{r}");
    assert!(v.get("session").is_none(), "{r}");
    for f in ["modeId", "mode", "permissionMode", "approvalPolicy", "sandbox"] {
        assert!(v["modeFields"].as_array().unwrap().contains(&json!(f)), "{f}: {r}");
    }
    assert_eq!(
        v["freeConfigIds"],
        json!(["model", "effort", "reasoning_effort", "thought_level", "thinking"]),
        "{r}"
    );
    // A known session: its family and mode.
    let s = session(&hub, "fcodex").await;
    let r = call(&hub, Origin::Local, "_acpmux/web_modes", json!({"sessionId": s})).await;
    assert_eq!(
        r["result"]["session"],
        json!({"sessionId": s, "family": "codex", "mode": "normal"}),
        "{r}"
    );
    // No mode yet: null.
    let n = session(&hub, "fnomode").await;
    let r = call(&hub, Origin::Local, "_acpmux/web_modes", json!({"sessionId": n})).await;
    assert_eq!(r["result"]["session"]["mode"], Value::Null, "{r}");
    // An unknown session is no error and has no session key.
    let r = call(&hub, Origin::Local, "_acpmux/web_modes", json!({"sessionId": "nope"})).await;
    assert!(r.get("error").is_none() && r["result"].get("session").is_none(), "{r}");
}

#[tokio::test]
async fn asks_reports_the_guard_decision_for_a_config_value() {
    let hub = hub();
    let s = session(&hub, "fcodex").await;
    for (id, value, asks) in [
        ("mode", "read-only", true),
        ("mode", "ask-more", true),
        ("mode", "agent", false),
        ("mode", "agent-full-access", false),
        ("model", "anything", true),
        ("effort", "high", true),
        ("approval_policy", "never", false),
    ] {
        let p = json!({"sessionId": s, "configId": id, "value": value});
        let r = call(&hub, Origin::Local, "_acpmux/web_modes", p).await;
        assert_eq!(r["result"]["session"]["asks"], json!(asks), "{id}={value}: {r}");
    }
    // Without both configId and value: no asks.
    let r =
        call(&hub, Origin::Local, "_acpmux/web_modes", json!({"sessionId": s, "configId": "mode"}))
            .await;
    assert!(r["result"]["session"].get("asks").is_none(), "{r}");
}

#[tokio::test]
async fn every_websocket_origin_is_refused() {
    let hub = hub();
    for origin in [Origin::Web, Origin::LocalApp, Origin::Peer] {
        let r = call(&hub, origin, "_acpmux/web_modes", json!({})).await;
        let msg = r["error"]["message"].as_str().unwrap_or_default();
        assert!(msg.contains("only over the local unix socket"), "{origin:?}: {r}");
    }
}
