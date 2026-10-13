//! A cmux terminal's launch credential names that one terminal
//! (plans/cmux-next/identity.md section 2). acpmux serves many terminals, so
//! no agent it starts may act as the terminal that started acpmux: a value in
//! acpmux's own environment or in a preset never reaches the harness. Its own
//! binary, so setting the process environment touches no other test.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const NAME: &str = "CMUX_LAUNCH_CREDENTIAL";

#[tokio::test]
async fn no_agent_inherits_the_terminal_launch_credential() {
    // SAFETY: the only test in this binary sets it before any agent starts.
    unsafe { std::env::set_var(NAME, "cmuxlc1.kinherited.e30.inherited") };
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "presets": {"sub": {"harness": "fake", "env": {NAME: "cmuxlc1.kpreset.e30.preset", "OTHER": "kept"}}},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub, in_rx, out_tx, Origin::Local));
    let mut client = Client(in_tx, out_rx, 0);
    for preset in [None, Some("sub")] {
        let mut params = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
        if let Some(preset) = preset {
            params["_meta"] = json!({"acpmux": {"preset": preset}});
        }
        let (reply, _) = client.call("session/new", params).await;
        assert!(reply.get("error").is_none(), "{reply}");
        let session = reply["result"]["sessionId"].as_str().unwrap().to_owned();
        let prompt =
            |text: &str| json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let (_, value) = client.call("session/prompt", prompt(&format!("env: {NAME}"))).await;
        assert_eq!(value, format!("{NAME}="), "{preset:?}: the agent got a launch credential");
        if preset.is_some() {
            let (_, other) = client.call("session/prompt", prompt("env: OTHER")).await;
            assert_eq!(other, "OTHER=kept", "the rest of the preset env stays");
        }
    }
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// The reply to one request, and the agent text streamed before it.
    async fn call(&mut self, method: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return (value, text);
            }
            if let Some(t) = value.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }
}
