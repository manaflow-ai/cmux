//! An OpenCode chat's `task` subagent is a subagent of the chat (manaflow-ai/cmux#50203): OpenCode
//! reports it only as its `task` tool call, and acpmux showed it as nothing more, so its agent
//! type, its model and its own OpenCode session (what a fork of it takes) were seen nowhere.

#![cfg(unix)]

use crate::HERMETIC;

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
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The reply to one request, and every notification before it.
async fn call(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    method: &str,
    params: Value,
) -> (Value, Vec<Value>) {
    tx.send(Message::request(id, method, params).to_line()).await.unwrap();
    let mut seen = Vec::new();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(id)) {
            assert!(v.get("error").is_none(), "{method}: {v}");
            return (v["result"].clone(), seen);
        }
        seen.push(v);
    }
}

#[tokio::test]
async fn an_opencode_task_call_reports_its_subagent() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));

    let (created, _) = call(
        &tx,
        &mut rx,
        1,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": []}),
    )
    .await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    let prompt =
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "opencode-task"}]});
    let (_, seen) = call(&tx, &mut rx, 2, "session/prompt", prompt).await;

    let events: Vec<&Value> = seen
        .iter()
        .filter_map(|v| v.pointer("/params/_meta/acpmux/subagents").and_then(Value::as_array))
        .flatten()
        .collect();
    let running = events
        .iter()
        .find(|e| e["state"] == "running")
        .unwrap_or_else(|| panic!("no running subagent: {seen:#?}"));
    assert_eq!(running["id"], "chatcmpl-tool-oc1", "{running}");
    assert_eq!(running["kind"], "general", "{running}");
    assert_eq!(running["task"], "Reply PONG", "{running}");
    assert_eq!(running["parent"], Value::Null, "the chat's own subagent: {running}");
    let done = events
        .iter()
        .find(|e| e["state"] == "completed")
        .unwrap_or_else(|| panic!("its end: {events:#?}"));
    assert_eq!(done["model"], "opencode/big-pickle", "{done}");
    assert_eq!(done["agentSessionId"], "ses_child_oc1", "{done}");
    assert_eq!(done["lastMessage"], "PONG", "{done}");
    assert_eq!(done["toolCallId"], "chatcmpl-tool-oc1", "{done}");
}
