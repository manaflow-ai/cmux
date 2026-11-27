//! Harness magic prefetch (`hub/prefetch.rs`) through the hub: a prompt that names a file in the
//! session's folder reaches the agent with the file attached after the person's words, and the
//! turn's `turn_result` carries the counters.

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

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "family": "codex", "env": {"FAKE_ECHO_PREFETCH": "1"}}
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Client {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, method: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return (value, text);
            }
            if let Some(chunk) =
                value.pointer("/params/update/content/text").and_then(Value::as_str)
            {
                text.push_str(chunk);
            }
        }
    }
}

#[tokio::test]
async fn a_named_file_reaches_the_agent_and_the_turn_counts_it() {
    let _ = HERMETIC;
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join(".git")).unwrap();
    std::fs::write(dir.path().join("notes.md"), "alpha\nbeta\n").unwrap();
    std::fs::write(dir.path().join(".env"), "SECRET=1\n").unwrap();
    let hub = hub();
    let mut c = Client::new(&hub);
    let (made, _) = c
        .call(
            "session/new",
            json!({"cwd": dir.path(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}),
        )
        .await;
    let sid = made["result"]["sessionId"].as_str().unwrap().to_owned();
    let (reply, echoed) = c
        .call(
            "session/prompt",
            json!({"sessionId": sid, "prompt": [{"type": "text", "text": "read notes.md and .env"}]}),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(echoed.contains("read notes.md and .env<cmux-prefetch-context>"), "{echoed}");
    assert!(echoed.contains("     1\talpha\n     2\tbeta\n"), "{echoed}");
    assert!(!echoed.contains("SECRET"), "{echoed}");
    let (events, _) = c
        .call("_acpmux/events", json!({"sessionId": sid, "kinds": ["turn_result", "user_message"]}))
        .await;
    let events = events["result"]["events"].as_array().cloned().unwrap_or_default();
    let turn =
        events.iter().rev().find(|e| e["kind"] == "turn_result").expect("turn_result")["msg"]
            .clone();
    assert_eq!(turn["harnessMagic.prefetch.files"], 1, "{turn}");
    assert_eq!(turn["harnessMagic.prefetch.rereadAnyway"], 0, "{turn}");
    assert!(turn["harnessMagic.prefetch.tokens"].as_u64().unwrap() > 10, "{turn}");
    // The transcript keeps the person's words only.
    let said =
        events.iter().find(|e| e["kind"] == "user_message").expect("user_message").to_string();
    assert!(!said.contains("alpha"), "{said}");

    // A later prompt that names the file without a cue gets nothing.
    let (_, echoed) = c
        .call(
            "session/prompt",
            json!({"sessionId": sid, "prompt": [{"type": "text", "text": "notes.md again"}]}),
        )
        .await;
    assert!(!echoed.contains("<cmux-prefetch-context>"), "{echoed}");
}
