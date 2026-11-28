//! `_acpmux/session_resources`: a live chat reports its agent's processes and their memory, read
//! from the OS; a chat whose agent has not started or has ended reports none. The hover cards'
//! Memory for an agent chat reads it (Leo 2026-11-27: "it should be the ram usage").

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
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Result<Value, Value> {
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
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }
}

#[tokio::test]
async fn a_live_chat_reports_its_agents_memory() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    let created = c
        .call(
            "session/new",
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}),
        )
        .await
        .expect("session/new");
    let id = created["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.call("session/prompt", prompt).await.expect("session/prompt");

    let live =
        c.call("_acpmux/session_resources", json!({"sessionId": id})).await.expect("resources");
    // The interim proof's read: the whole reply, as the hover card gets it.
    eprintln!("session_resources (live): {live}");
    assert_eq!(live["sessionId"], json!(id), "{live}");
    assert_eq!(live["running"], json!(true), "{live}");
    let processes = live["processes"].as_array().expect("processes");
    assert!(!processes.is_empty(), "{live}");
    let root = live["pid"].as_u64().expect("the agent's pid");
    let row = processes.iter().find(|p| p["pid"].as_u64() == Some(root)).expect("the agent's row");
    assert!(
        row["memoryBytes"].as_u64().unwrap_or(0) > 1 << 20,
        "a python agent holds over 1 MiB: {live}"
    );
    let sum: u64 = processes.iter().filter_map(|p| p["memoryBytes"].as_u64()).sum();
    assert_eq!(live["memoryBytes"].as_u64(), Some(sum), "{live}");

    // Its process ends: nothing runs, nothing is measured.
    c.call("session/close", json!({"sessionId": id})).await.expect("close");
    let closed =
        c.call("_acpmux/session_resources", json!({"sessionId": id})).await.expect("resources");
    eprintln!("session_resources (closed): {closed}");
    assert_eq!(closed["running"], json!(false), "{closed}");
    assert_eq!(closed["processes"], json!([]), "{closed}");

    // An unknown chat is an error, not an empty card.
    assert!(c.call("_acpmux/session_resources", json!({"sessionId": "nope"})).await.is_err());
}
