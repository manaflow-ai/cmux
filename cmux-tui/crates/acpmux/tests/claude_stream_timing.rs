//! What a Claude chat's log keeps of Claude Code's raw `stream_event` lines.
//!
//! Most of them (text and tool-input deltas) are dropped: the translated
//! `session/update` records carry their content. optchat-chief times each model
//! request from the log (`fold.rs` `time_request`: `message_start` and the first
//! `content_block_delta` after it give headers_ms and ttft_ms), so those two
//! stay in the log; every later delta of the request does not. A subagent's
//! lines (`parent_tool_use_id`) are not timed, so none of them stays, and one
//! streaming between a request's start and its first token does not take that
//! request's first delta.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::time::Duration;
use tokio::sync::mpsc;

/// One local client of the hub, through its connection.
struct TestClient {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl TestClient {
    async fn request(&mut self, m: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout waiting for response")
                .expect("connection closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                assert!(error.is_none(), "{m} failed: {error:?}");
                return result.unwrap_or(Value::Null);
            }
        }
    }
}

/// A client of a hub whose only harness runs `fake_claude.py` as Claude Code.
async fn claude_client() -> TestClient {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut harnesses = BTreeMap::new();
    harnesses.insert(
        "fakeclaude".to_owned(),
        HarnessProfile {
            kind: acpmux::config::HarnessKind::ClaudeStdio,
            argv: vec!["python3".into(), fake_claude.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses, default_harness: Some("fakeclaude".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub, in_rx, out_tx, Origin::Local));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await;
    c
}

/// The (event type, text or message id) of every `claude.stream_event` record in the log.
async fn logged_stream_events(c: &mut TestClient, id: &str) -> Vec<(String, String)> {
    let page = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 10_000}))
        .await;
    assert_ne!(page["hasMore"], true, "one page holds this short log: {page}");
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == "claude.stream_event")
        .map(|e| {
            let ev = &e["msg"]["event"];
            let what = ev
                .pointer("/message/id")
                .or_else(|| ev.pointer("/delta/text"))
                .and_then(Value::as_str)
                .unwrap_or("");
            (ev["type"].as_str().unwrap_or("").to_owned(), what.to_owned())
        })
        .collect()
}

#[tokio::test]
async fn a_claude_log_keeps_each_requests_start_and_first_delta_only() {
    let mut c = claude_client().await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                   "_meta": {"acpmux": {"harness": "fakeclaude", "name": "timing"}}}),
        )
        .await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "timing-probe"}]}),
    )
    .await;

    let pair = |t: &str, w: &str| (t.to_owned(), w.to_owned());
    assert_eq!(
        logged_stream_events(&mut c, &id).await,
        vec![
            pair("message_start", "msg_t1"),
            pair("content_block_delta", "msg_t1 one "),
            pair("message_start", "msg_t2"),
            pair("content_block_delta", "msg_t2 one "),
        ],
        "the log keeps each main request's message_start and first delta, no later delta and no subagent line"
    );
}
