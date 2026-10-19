//! Images sent with a prompt stay with the chat (Leo, 2026-10-13: a sent prompt's images
//! vanished). The prompt's `user_message` names each image by its content hash, the bytes are
//! kept once under `<ACPMUX_HOME>/attachments`, and `_acpmux/attachment` hands an image back to
//! whoever can read the session, also after a restart. An id the session never sent reads nothing.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// A 1×1 PNG.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

fn hub(dir: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// The `user_message` records of `session`, oldest first.
async fn user_messages(c: &mut Client, session: &str) -> Vec<Value> {
    let reply =
        c.call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]})).await;
    reply["result"]["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
}

#[tokio::test]
async fn a_prompts_images_are_named_in_its_message_and_read_back_after_a_restart() {
    let root = std::env::temp_dir().join(format!("acpmux-prompt-images-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    acpmux::config::set_home_override(root.join("home"));
    let store = root.join("store");
    std::fs::create_dir_all(&store).unwrap();
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD.decode(PNG).unwrap();
    let id = sha256_hex(&bytes);

    let first = hub(&store);
    let mut c = client(&first);
    let session = c
        .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}))
        .await["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let reply = c
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [
                {"type": "text", "text": "what is this"},
                {"type": "image", "mimeType": "image/png", "data": PNG, "name": "shot.png"}
            ]}),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");

    let sent = user_messages(&mut c, &session).await;
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["text"], "what is this");
    assert_eq!(sent[0]["images"], json!([{"id": id, "mimeType": "image/png", "name": "shot.png"}]));
    // The log names the image; its bytes are kept apart, once.
    assert!(!sent[0].to_string().contains(PNG));

    let read = c.call("_acpmux/attachment", json!({"sessionId": session, "id": id})).await;
    assert_eq!(read["result"], json!({"mimeType": "image/png", "data": PNG}), "{read}");
    // An id this session never sent (or not a hash at all) reads nothing.
    let other = sha256_hex(b"someone else's image");
    for wrong in [other.as_str(), "../../etc/passwd"] {
        let refused =
            c.call("_acpmux/attachment", json!({"sessionId": session, "id": wrong})).await;
        assert!(refused.get("error").is_some(), "{wrong}: {refused}");
    }

    first.shutdown_all().await;
    drop(c);
    drop(first);
    let second = hub(&store);
    let mut c = client(&second);
    assert_eq!(user_messages(&mut c, &session).await[0]["images"][0]["id"], json!(id));
    let read = c.call("_acpmux/attachment", json!({"sessionId": session, "id": id})).await;
    assert_eq!(read["result"]["data"], json!(PNG), "{read}");
}
