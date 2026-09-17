//! End-to-end tests through the real protocol handler with a fake agent.

use acpmux::config::{AgentProfile, Config, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::serve_connection;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

struct TestClient {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl TestClient {
    async fn request(&mut self, m: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout waiting for response")
                .expect("connection closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap() {
                if rid == Value::from(id) {
                    return match error {
                        Some(e) => Err(e.message),
                        None => Ok(result.unwrap_or(Value::Null)),
                    };
                }
            }
        }
    }

    /// Wait for a notification whose method matches, returning its params.
    async fn wait_for(&mut self, m: &str, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout waiting for notification")
                .expect("connection closed");
            if let Message::Notification { method: got, params } = Message::parse(&line).unwrap() {
                let p = params.unwrap_or(Value::Null);
                if got == m && pred(&p) {
                    return p;
                }
            }
        }
    }
}

async fn setup(policy: PermissionPolicy) -> (Arc<Hub>, TestClient) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        AgentProfile { kind: Default::default(), argv: vec!["python3".into(), fake.into()], env: BTreeMap::new(), description: None },
    );
    let mut cfg = Config { agents, default_agent: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = policy;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    (hub, client)
}

fn cwd() -> String {
    std::env::temp_dir().to_string_lossy().into_owned()
}

#[tokio::test]
async fn prompt_streams_and_records() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "one"}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(s["modes"]["currentModeId"], "normal");
    let r = c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]})).await.unwrap();
    assert_eq!(r["stopReason"], "end_turn");
    let session = hub.resolve("one").unwrap();
    let events = hub.events(&session.id, 0, 1000).unwrap();
    let kinds: Vec<&str> = events.iter().map(|e| e.kind.as_str()).collect();
    assert!(kinds.contains(&"user_message"), "{kinds:?}");
    assert!(kinds.contains(&"agent_message_chunk"), "{kinds:?}");
    assert!(kinds.contains(&"turn_end"), "{kinds:?}");
    let summary = hub.session_summary(&session);
    assert_eq!(summary["status"], "ready");
    assert_eq!(summary["turnCount"], 1);
    assert_eq!(summary["preview"], "echo: hi");
}

#[tokio::test]
async fn permission_is_routed_to_clients_and_answered() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // Fire the prompt without waiting for its response.
    c.next += 1;
    let prompt_id = c.next;
    c.tx.send(Message::request(prompt_id, method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: rm -rf /"}]})).to_line()).await.unwrap();
    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    assert_eq!(pending["request"]["toolCall"]["title"], "rm -rf /");
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
    c.request(method::MUX_PERMISSION_RESPOND, json!({"sessionId": id, "permissionId": pid, "optionId": "yes"})).await.unwrap();
    let done = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(done["msg"]["stopReason"], "end_turn");
    assert_eq!(hub.session_summary(&session)["preview"], "chose yes");
}

#[tokio::test]
async fn approve_all_policy_answers_without_a_client() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: write"}]})).await.unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose yes");
    let kinds: Vec<String> = hub.events(&id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "permission_auto"), "{kinds:?}");
}

#[tokio::test]
async fn cancel_stops_a_turn() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.next += 1;
    let prompt_id = c.next;
    c.tx.send(Message::request(prompt_id, method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "slow"}]})).to_line()).await.unwrap();
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk").await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line()).await.unwrap();
    let done = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(done["msg"]["stopReason"], "cancelled");
}

#[tokio::test]
async fn fork_copies_history_and_gets_its_own_agent() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "root"}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "first"}]})).await.unwrap();
    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd(), "_meta": {"acpmux": {"name": "branch"}}})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(fid, id);
    let forked = hub.resolve("branch").unwrap();
    let meta = forked.meta();
    assert_eq!(meta.parent_id.as_deref(), Some(id.as_str()));
    let kinds: Vec<String> = hub.events(&fid, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "user_message"), "{kinds:?}");
    assert!(kinds.iter().any(|k| k == "forked"), "{kinds:?}");
    // The fork can take prompts on its own agent process.
    let r = c.request(method::SESSION_PROMPT, json!({"sessionId": fid, "prompt": [{"type": "text", "text": "second"}]})).await.unwrap();
    assert_eq!(r["stopReason"], "end_turn");
}

#[tokio::test]
async fn set_mode_and_config_and_list() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "cfg"}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": "strict"})).await.unwrap();
    c.request(method::SESSION_SET_MODEL, json!({"sessionId": id, "modelId": "m2"})).await.unwrap();
    let session = hub.resolve("cfg").unwrap();
    let summary = hub.session_summary(&session);
    assert_eq!(summary["currentModeId"], "strict");
    assert_eq!(summary["model"], "m2");
    let list = c.request(method::SESSION_LIST, json!({})).await.unwrap();
    assert_eq!(list["sessions"].as_array().unwrap().len(), 1);
    let renamed = c.request(method::MUX_RENAME, json!({"sessionId": id, "newName": "renamed"})).await.unwrap();
    assert_eq!(renamed["name"], "renamed");
    assert!(c.request(method::MUX_RENAME, json!({"sessionId": id, "newName": "bad name"})).await.is_err());
}

#[tokio::test]
async fn kill_then_prompt_resumes_via_load() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "r"}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "a"}]})).await.unwrap();
    let session = hub.resolve("r").unwrap();
    hub.detach_child(&session).await;
    assert_eq!(hub.session_summary(&session)["status"], "idle");
    c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "b"}]})).await.unwrap();
    let kinds: Vec<String> = hub.events(&id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "resumed"), "{kinds:?}");
    assert!(kinds.iter().any(|k| k == "user_message_chunk.replay"), "{kinds:?}");
    assert_eq!(hub.session_summary(&session)["turnCount"], 2);
}

#[tokio::test]
async fn attach_replays_and_watch_broadcasts() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "w"}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "x"}]})).await.unwrap();
    let a = c.request(method::MUX_ATTACH, json!({"session": "w", "limit": 100})).await.unwrap();
    assert!(a["events"].as_array().unwrap().len() > 3);
    assert_eq!(a["session"]["name"], "w");
    c.request(method::MUX_WATCH, json!({})).await.unwrap();
    c.next += 1;
    let pid = c.next;
    c.tx.send(Message::request(pid, method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "y"}]})).to_line()).await.unwrap();
    let changed = c.wait_for(method::MUX_SESSION_CHANGED, |p| p["kind"] == "turn_end").await;
    assert_eq!(changed["session"]["turnCount"], 2);
}
