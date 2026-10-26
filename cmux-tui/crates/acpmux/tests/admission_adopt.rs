//! Adopts of one conversation at this host's lane cap (`hub/admission.rs`): an
//! adopt of a conversation a session holds attaches there and starts nothing, so
//! concurrent adopts of one conversation converge on one session, never a refusal
//! for the duplicates that lost the race for the one lane.
//!
//! Stand-in agents (fake_agent.py). One test function: HOME and FLEET_ORIGIN are
//! read from this process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::adopt::HarnessHomes;
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
        "harnesses": {"fakecodex": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fakecodex",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// One `session/new` on a connection of its own: its reply.
async fn new_session(hub: &Arc<Hub>, params: Value) -> Value {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    in_tx.send(Message::request(1, "session/new", params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(30), out_rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_adopts_of_one_conversation_at_the_cap_get_the_one_session() {
    let root = std::env::temp_dir().join(format!("acpmux-admadopt-{}", uuid::Uuid::now_v7()));
    let home = root.join("home");
    let registry = home.join(".ssh/config.d/fleet-registry.json");
    std::fs::create_dir_all(registry.parent().unwrap()).unwrap();
    // Room for one session on this host.
    let machines = json!({"machines": {"test-box": {"lanes": {"max_lanes": 1}}}});
    std::fs::write(&registry, machines.to_string()).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"));
        std::env::set_var("FLEET_ORIGIN", "test-box");
        std::env::remove_var("FLEET_REGISTRY");
    }
    // One Codex conversation recorded in a project folder.
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let chat = uuid::Uuid::now_v7().to_string();
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T09-00-00-{chat}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let record = json!({"type": "session_meta", "payload": {"id": chat, "cwd": project}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();

    let hub = hub();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    let adopt = json!({"mcpServers": [], "_meta": {"acpmux":
        {"harness": "fakecodex", "adopt": {"agentSessionId": chat}}}});
    let replies = futures::future::join_all(
        (0..8).map(|_| tokio::spawn(new_session_owned(hub.clone(), adopt.clone()))),
    )
    .await;
    let replies: Vec<Value> = replies.into_iter().map(Result::unwrap).collect();
    for r in &replies {
        assert!(r.get("error").is_none(), "every adopt gets the one session: {replies:#?}");
    }
    let ids: std::collections::HashSet<&str> =
        replies.iter().filter_map(|r| r["result"]["sessionId"].as_str()).collect();
    assert_eq!(ids.len(), 1, "one session: {replies:#?}");

    let _ = std::fs::remove_dir_all(&root);
}

async fn new_session_owned(hub: Arc<Hub>, params: Value) -> Value {
    new_session(&hub, params).await
}
