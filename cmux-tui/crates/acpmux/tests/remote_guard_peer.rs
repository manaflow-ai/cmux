//! A proven peer (`Control::Peer`: the owner's own daemon) starts a session
//! as the same user would over ssh: "acpmux is too belt and suspenders there"
//! (Leo). It may name any policy at `session/new`, and with no folder it gets
//! a scratch folder named after the session. A Web connection, and a peer
//! forwarding for its own Web client (`via: web`), keep the Web's rules.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const WEB_ONLY: &str = "never from a remote WebSocket connection";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "webRoots": [std::env::temp_dir()],
        "webAskingModes": {"fake": ["normal", "strict"]},
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

fn err(v: &Value) -> String {
    v["error"]["message"].as_str().unwrap_or_default().to_owned()
}

fn policy(hub: &Arc<Hub>, r: &Value) -> Option<String> {
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("session/new failed: {r}"));
    hub.resolve(id).unwrap().meta().permission_policy.clone()
}

#[tokio::test]
async fn a_proven_peer_starts_an_approve_all_session_and_the_web_still_cannot() {
    let hub = hub();
    let cwd = std::env::temp_dir();
    let new = |meta: Value| json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}});

    let r = call(&hub, Origin::Peer, "session/new", new(json!({"policy": "approve-all"}))).await;
    assert_eq!(policy(&hub, &r).as_deref(), Some("approve-all"), "{r}");

    for (origin, meta) in [
        (Origin::Web, json!({"policy": "approve-all"})),
        (Origin::Peer, json!({"policy": "approve-all", "via": "web"})),
    ] {
        let r = call(&hub, origin, "session/new", new(meta.clone())).await;
        assert!(err(&r).contains(WEB_ONLY), "{origin:?} {meta}: {r}");
    }
    // Only the policy at start: a peer's later widening keeps the Web's rule.
    let r = call(&hub, Origin::Peer, "session/new", new(json!({}))).await;
    let id = r["result"]["sessionId"].as_str().unwrap().to_owned();
    let r = call(
        &hub,
        Origin::Peer,
        "_acpmux/set_policy",
        json!({"sessionId": id, "policy": "approve-all"}),
    )
    .await;
    assert!(err(&r).contains(WEB_ONLY), "{r}");
}

#[tokio::test]
async fn a_proven_peer_with_no_folder_gets_a_scratch_folder_named_after_the_session() {
    let hub = hub();
    let name = format!("lane/x {}", std::process::id());
    let r = call(
        &hub,
        Origin::Peer,
        "session/new",
        json!({"mcpServers": [], "_meta": {"acpmux": {"name": name, "policy": "approve-all"}}}),
    )
    .await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}"));
    let cwd = hub.resolve(id).unwrap().meta().cwd.clone();
    let scratch_root = cwd.parent().unwrap();
    assert!(scratch_root.starts_with(std::fs::canonicalize(std::env::temp_dir()).unwrap()), "{r}");
    assert!(
        scratch_root.file_name().unwrap().to_string_lossy().starts_with("acpmux-peer-scratch-"),
        "{r}"
    );
    assert_eq!(cwd, scratch_root.join(format!("lane-x-{}", std::process::id())), "{r}");
    assert!(cwd.is_dir());
    let mode =
        std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&cwd).unwrap().permissions());
    assert_eq!(mode & 0o077, 0, "owner-only");

    // A Web connection with no folder is still refused.
    let r = call(&hub, Origin::Web, "session/new", json!({"mcpServers": []})).await;
    assert!(err(&r).contains("cwd is refused"), "{r}");
    let _ = std::fs::remove_dir_all(&cwd);
}
