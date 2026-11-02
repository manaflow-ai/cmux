//! A hub that runs in another process's runtime polls its requests on that runtime's workers, and
//! tokio gives a worker 2 MiB of stack unless the runtime asks for more. The cmux-tui tests run a
//! hub so (`agent_message_launch_credential`, `agent_message_reply_in_place`): on Linux their
//! `session/new` and `session/prompt` aborted with "has overflowed its stack", because a debug
//! build polled each request through 2.1-2.3 MiB of frames (`src/heap_future.rs`). This test
//! serves the same requests on workers of exactly tokio's default stack, whatever
//! `RUST_MIN_STACK` this process has (`support/daemon_env.rs` sets 8 MiB, the daemon's own).

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs the stand-in agent (tests/fake_agent.py) in its hub.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// tokio's worker stack when a runtime names none (tokio `runtime/builder.rs`).
const TOKIO_DEFAULT_WORKER_STACK: usize = 2 << 20;

#[test]
fn a_new_chat_and_its_prompt_are_served_on_a_default_tokio_worker_stack() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(TOKIO_DEFAULT_WORKER_STACK)
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        // Spawned: the connection and its requests run on the 2 MiB workers, not on this test's
        // thread.
        drop(tokio::spawn(serve_connection_with(hub, in_rx, out_tx, Origin::Local)));
        let mut client = Client(in_tx, out_rx, 0);
        let (reply, _) = client
            .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
            .await;
        assert!(reply.get("error").is_none(), "{reply}");
        let session = reply["result"]["sessionId"].as_str().unwrap().to_owned();
        let prompt = json!({"sessionId": session,
            "prompt": [{"type": "text", "text": "on a small stack"}]});
        let (reply, text) = client.call("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        assert!(text.contains("on a small stack"), "the agent echoed {text:?}");
    });
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
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
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
