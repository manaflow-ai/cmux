//! `_acpmux/chat_fork {harness, agentSessionId, cwd}`: Fork Conversation of a terminal agent
//! whose own CLI has no fork (Muse: `muse resume` only). acpmux starts the harness's ACP agent
//! once, asks it `session/fork` of the terminal's session, and answers the new session id, which
//! the app then resumes in a new terminal (`muse resume <id>`). The agent is never left running.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

async fn call(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    m: &str,
    params: Value,
) -> Value {
    tx.send(Message::request(id, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(id)) {
            return v;
        }
    }
}

async fn connect(
    harnesses: Value,
    origin: Origin,
) -> (Arc<Hub>, mpsc::Sender<String>, mpsc::Receiver<String>) {
    let _ = &HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({"harnesses": harnesses})).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    call(
        &tx,
        &mut rx,
        1,
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}),
    )
    .await;
    (hub, tx, rx)
}

fn muse(env: Value) -> Value {
    json!({"muse": {"argv": ["python3", FAKE], "family": "muse", "env": env}})
}

/// A terminal Muse forks through its ACP agent: the answer is the agent's new session id.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chat_fork_a_terminal_muse_session_forks_through_its_acp_agent() {
    let (_hub, tx, mut rx) =
        connect(muse(json!({"FAKE_SESSION_PREFIX": "muse-fork-"})), Origin::Local).await;
    let reply = call(
        &tx,
        &mut rx,
        2,
        "_acpmux/chat_fork",
        json!({"harness": "muse", "agentSessionId": "01a1802b-9ee5-7312-830f-ca44184d261e", "cwd": "/tmp"}),
    )
    .await;
    assert_eq!(reply["result"]["agentSessionId"], "muse-fork-1", "{reply}");
    assert_eq!(reply["result"]["harness"], "muse", "{reply}");
}

/// An agent that does not offer session/fork says so instead of a bare internal error.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chat_fork_an_agent_without_session_fork_is_refused_with_the_reason() {
    let (_hub, tx, mut rx) = connect(muse(json!({"FAKE_NO_FORK": "1"})), Origin::Local).await;
    let reply = call(
        &tx,
        &mut rx,
        2,
        "_acpmux/chat_fork",
        json!({"harness": "muse", "agentSessionId": "s-1", "cwd": "/tmp"}),
    )
    .await;
    let message = reply["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("does not offer session/fork"), "{reply}");
}

/// A harness with no ACP profile here, and a session id that is not one plain token, are refused.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chat_fork_an_unknown_harness_or_a_bad_session_id_is_refused() {
    let (_hub, tx, mut rx) = connect(muse(json!({})), Origin::Local).await;
    let unknown = call(
        &tx,
        &mut rx,
        2,
        "_acpmux/chat_fork",
        json!({"harness": "nope", "agentSessionId": "s-1", "cwd": "/tmp"}),
    )
    .await;
    assert!(
        unknown["error"]["message"].as_str().unwrap_or_default().contains("no ACP harness"),
        "{unknown}"
    );
    let bad = call(
        &tx,
        &mut rx,
        3,
        "_acpmux/chat_fork",
        json!({"harness": "muse", "agentSessionId": "a; rm -rf ~", "cwd": "/tmp"}),
    )
    .await;
    assert!(bad.get("error").is_some(), "{bad}");
}

/// The fork runs the person's agent with their login: only the local unix socket asks for it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chat_fork_a_web_connection_cannot_fork_a_terminal_chat() {
    let (_hub, tx, mut rx) = connect(muse(json!({})), Origin::Web).await;
    let reply = call(
        &tx,
        &mut rx,
        2,
        "_acpmux/chat_fork",
        json!({"harness": "muse", "agentSessionId": "s-1", "cwd": "/tmp"}),
    )
    .await;
    assert!(reply.get("error").is_some(), "{reply}");
}
