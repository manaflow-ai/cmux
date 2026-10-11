//! REMOTE-SANDBOX spawn canary: a `sandbox-exec` that does not sandbox (a
//! stand-in that drops the profile and runs the command) is caught at the
//! spawn; the remote chain's Claude Code never starts.
#![cfg(target_os = "macos")]

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const NO_SANDBOX: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_sandbox_exec.sh");

#[tokio::test]
async fn a_remote_chain_spawn_is_refused_when_the_canary_shows_no_sandbox() {
    let d = std::env::temp_dir().join(format!("arsc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    let d = std::fs::canonicalize(&d).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_remote_sandbox_exec(PathBuf::from(NO_SANDBOX));
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Web));
    let mut call = async |id: i64, m: &str, p: Value| -> Value {
        in_tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), out_rx.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    };
    let r = call(1, "session/new", json!({"cwd": d.join("work"), "mcpServers": []})).await;
    let refused = match r["result"]["sessionId"].as_str() {
        None => r,
        Some(s) => {
            let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": "argv"}]});
            call(2, "session/prompt", p).await
        }
    };
    let text = refused.to_string();
    assert!(text.contains("shows no sandbox"), "{text}");
    assert_eq!(refused["error"]["data"]["reason"], json!("remote.sandbox_refused"), "{refused}");
    let _ = std::fs::remove_dir_all(&d);
}
