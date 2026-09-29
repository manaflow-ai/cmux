//! End-to-end tests through the real protocol handler with a fake agent.

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
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
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
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
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
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
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
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
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "one"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(s["modes"]["currentModeId"], "normal");
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await
        .unwrap();
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
    c.tx.send(
        Message::request(
            prompt_id,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: rm -rf /"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    assert_eq!(pending["request"]["toolCall"]["title"], "rm -rf /");
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "yes"}),
    )
    .await
    .unwrap();
    let done = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(done["msg"]["stopReason"], "end_turn");
    assert_eq!(hub.session_summary(&session)["preview"], "chose yes");
}

#[tokio::test]
async fn approve_all_policy_answers_without_a_client() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: write"}]}),
    )
    .await
    .unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose yes");
    let kinds: Vec<String> =
        hub.events(&id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "permission_auto"), "{kinds:?}");
}

#[tokio::test]
async fn cancel_stops_a_turn() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.next += 1;
    let prompt_id = c.next;
    c.tx.send(
        Message::request(
            prompt_id,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "slow"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let done = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(done["msg"]["stopReason"], "cancelled");
}

#[tokio::test]
async fn fork_copies_history_and_gets_its_own_agent() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "root"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "first"}]}),
    )
    .await
    .unwrap();
    let f = c
        .request(
            method::SESSION_FORK,
            json!({"sessionId": id, "cwd": cwd(), "_meta": {"acpmux": {"name": "branch"}}}),
        )
        .await
        .unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(fid, id);
    let forked = hub.resolve("branch").unwrap();
    let meta = forked.meta();
    assert_eq!(meta.parent_id.as_deref(), Some(id.as_str()));
    let kinds: Vec<String> =
        hub.events(&fid, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "user_message"), "{kinds:?}");
    assert!(kinds.iter().any(|k| k == "forked"), "{kinds:?}");
    // The fork can take prompts on its own agent process.
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": fid, "prompt": [{"type": "text", "text": "second"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
}

#[tokio::test]
async fn set_mode_and_config_and_list() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "cfg"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": "strict"}))
        .await
        .unwrap();
    c.request(method::SESSION_SET_MODEL, json!({"sessionId": id, "modelId": "m2"})).await.unwrap();
    let session = hub.resolve("cfg").unwrap();
    let summary = hub.session_summary(&session);
    assert_eq!(summary["currentModeId"], "strict");
    assert_eq!(summary["model"], "m2");
    let list = c.request(method::SESSION_LIST, json!({})).await.unwrap();
    assert_eq!(list["sessions"].as_array().unwrap().len(), 1);
    let renamed = c
        .request(method::MUX_RENAME, json!({"sessionId": id, "newName": "renamed"}))
        .await
        .unwrap();
    assert_eq!(renamed["name"], "renamed");
    assert!(
        c.request(method::MUX_RENAME, json!({"sessionId": id, "newName": "bad name"}))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn kill_then_prompt_resumes_via_load() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "r"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "a"}]}),
    )
    .await
    .unwrap();
    let session = hub.resolve("r").unwrap();
    hub.detach_child(&session).await;
    assert_eq!(hub.session_summary(&session)["status"], "idle");
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "b"}]}),
    )
    .await
    .unwrap();
    let kinds: Vec<String> =
        hub.events(&id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "resumed"), "{kinds:?}");
    assert!(kinds.iter().any(|k| k == "user_message_chunk.replay"), "{kinds:?}");
    assert_eq!(hub.session_summary(&session)["turnCount"], 2);
    // The saved mode and options were re-asserted on the respawned agent.
    let replayed = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .any(|e| e.kind == "config" && e.msg.get("replayed") == Some(&json!(true)));
    assert!(replayed, "{kinds:?}");
}

#[tokio::test]
async fn attach_replays_and_watch_broadcasts() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "w"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "x"}]}),
    )
    .await
    .unwrap();
    let a = c.request(method::MUX_ATTACH, json!({"session": "w", "limit": 100})).await.unwrap();
    assert!(a["events"].as_array().unwrap().len() > 3);
    assert_eq!(a["session"]["name"], "w");
    c.request(method::MUX_WATCH, json!({})).await.unwrap();
    c.next += 1;
    let pid = c.next;
    c.tx.send(
        Message::request(
            pid,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "y"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    let changed = c.wait_for(method::MUX_SESSION_CHANGED, |p| p["kind"] == "turn_end").await;
    assert_eq!(changed["session"]["turnCount"], 2);
}

// ------------------------------------------------------- orchestration

#[tokio::test]
async fn wait_resolves_on_permission_then_on_ready() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "w"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let seq0 = hub.session_summary(&hub.resolve(&id).unwrap())["stateSeq"].as_u64().unwrap();
    c.next += 1;
    let prompt_id = c.next;
    c.tx.send(
        Message::request(
            prompt_id,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: rm -rf /"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    // Wait for the permission with a seq gate so a stale state cannot satisfy it.
    let w = c.request(method::MUX_WAIT, json!({"sessions": ["w"], "until": ["permission"], "afterSeq": {id.clone(): seq0}, "timeoutMs": 10000})).await.unwrap();
    assert_eq!(w["timedOut"], false, "{w}");
    assert_eq!(w["resolved"][0]["pendingPermissions"], 1, "{w}");
    assert_eq!(w["resolved"][0]["matched"][0], "permission");
    // Not ready yet: a short wait for ready times out.
    let w2 = c
        .request(
            method::MUX_WAIT,
            json!({"sessions": [id.clone()], "until": ["ready"], "timeoutMs": 300}),
        )
        .await
        .unwrap();
    assert_eq!(w2["timedOut"], true, "{w2}");
    let pid = hub.resolve(&id).unwrap().pending_permissions()[0].0.clone();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "yes"}),
    )
    .await
    .unwrap();
    let w3 = c
        .request(method::MUX_WAIT, json!({"sessions": [id.clone()], "timeoutMs": 10000}))
        .await
        .unwrap();
    assert_eq!(w3["timedOut"], false, "{w3}");
    assert_eq!(w3["resolved"][0]["status"], "ready");
    // No names: nothing in flight resolves at once with an empty list.
    let w4 = c.request(method::MUX_WAIT, json!({"timeoutMs": 500})).await.unwrap();
    assert_eq!(w4["sessions"].as_array().unwrap().len(), 0);
    // Bad state name is a usage error.
    assert!(
        c.request(method::MUX_WAIT, json!({"sessions": [id], "until": ["bogus"]})).await.is_err()
    );
}

#[tokio::test]
async fn turn_markers_history_and_cursor() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "h"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "first prompt"}]}),
    )
    .await
    .unwrap();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: write"}]}),
    )
    .await
    .unwrap();
    let events = hub.events(&id, 0, 1000).unwrap();
    let kinds: Vec<&str> = events.iter().map(|e| e.kind.as_str()).collect();
    assert!(kinds.contains(&"turn_started"), "{kinds:?}");
    let results: Vec<&Value> =
        events.iter().filter(|e| e.kind == "turn_result").map(|e| &e.msg).collect();
    assert_eq!(results.len(), 2, "{kinds:?}");
    assert_eq!(results[0]["status"], "completed");
    assert_eq!(results[0]["stopReason"], "end_turn");
    let h = c.request(method::MUX_HISTORY, json!({"sessionId": id, "limit": 10})).await.unwrap();
    let turns = h["turns"].as_array().unwrap();
    assert_eq!(turns.len(), 2, "{h}");
    assert_eq!(turns[0]["prompt"], "first prompt");
    assert_eq!(turns[0]["status"], "completed");
    assert!(turns[0]["wallMs"].is_u64());
    assert_eq!(turns[1]["permissions"], 1);
    // A cursor beyond the log is an error, not a silent empty page.
    let err = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 999_999}))
        .await
        .unwrap_err();
    assert!(err.contains("cursor_future"), "{err}");
    let last = hub.session_summary(&hub.resolve(&id).unwrap())["lastSeq"].as_u64().unwrap();
    let page = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": last - 1}))
        .await
        .unwrap();
    assert_eq!(page["events"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn tags_rules_and_unread() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "t"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // Tags with and without expiry.
    let v = c.request(method::MUX_TAG, json!({"sessionId": id, "set": {"task": "review", "owner": "orchestrator"}, "ttlSeconds": 3600})).await.unwrap();
    assert_eq!(v["tags"]["task"], "review");
    let v =
        c.request(method::MUX_TAG, json!({"sessionId": id, "remove": ["owner"]})).await.unwrap();
    assert!(v["tags"].get("owner").is_none());
    assert_eq!(v["tags"]["task"], "review");
    // Rules: deny rm under an ask policy answers without a client.
    assert!(
        c.request(method::MUX_SET_RULES, json!({"sessionId": id, "rules": {"bogus": 1}}))
            .await
            .is_err()
    );
    let v = c
        .request(
            method::MUX_SET_RULES,
            json!({"sessionId": id, "rules": {"autoDeny": ["rm"], "autoApprove": ["ls"]}}),
        )
        .await
        .unwrap();
    assert_eq!(v["rules"], true);
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: rm -rf /"}]}),
    )
    .await
    .unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose no");
    let autos: Vec<Value> = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "permission_auto")
        .map(|e| e.msg)
        .collect();
    assert_eq!(autos.last().unwrap()["rule"], "deny");
    // This client saw that turn end: not unread.
    assert_eq!(hub.session_summary(&session)["unread"], false);
    // Detach, then a second client sends a slow prompt and disconnects
    // mid-turn, like `acpmux send --no-wait`, so nobody is attached when it ends.
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    {
        let (in_tx2, in_rx2) = mpsc::channel(64);
        let (out_tx2, _out_rx2) = mpsc::channel(4096);
        tokio::spawn(serve_connection(hub.clone(), in_rx2, out_tx2));
        in_tx2
            .send(
                Message::request(
                    1,
                    method::SESSION_PROMPT,
                    json!({"sessionId": id, "prompt": [{"type": "text", "text": "slow"}]}),
                )
                .to_line(),
            )
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(150)).await;
        drop(in_tx2);
    }
    let w = c.request(method::MUX_WAIT, json!({"sessions": [id.clone()], "until": ["ready"], "afterSeq": {id.clone(): hub.session_summary(&session)["stateSeq"].as_u64().unwrap()}, "timeoutMs": 10000})).await.unwrap();
    assert_eq!(w["timedOut"], false, "{w}");
    // Unread: nobody was attached when the turn ended.
    assert_eq!(hub.session_summary(&session)["unread"], true);
    assert_eq!(hub.session_summary(&session)["attached"], 0);
    let w = c
        .request(
            method::MUX_WAIT,
            json!({"sessions": [id.clone()], "until": ["done"], "timeoutMs": 2000}),
        )
        .await
        .unwrap();
    assert_eq!(w["resolved"][0]["unread"], true, "{w}");
    c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert_eq!(hub.session_summary(&session)["unread"], false);
    assert_eq!(hub.session_summary(&session)["attached"], 1);
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    assert_eq!(hub.session_summary(&session)["attached"], 0);
    // Clearing rules returns to the policy.
    let v =
        c.request(method::MUX_SET_RULES, json!({"sessionId": id, "rules": null})).await.unwrap();
    assert_eq!(v["rules"], false);
}

#[tokio::test]
async fn restart_marks_unknown_outcome() {
    use acpmux::store::EventRecord;
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
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
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "crash"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
    )
    .await
    .unwrap();
    let last = hub.session_summary(&hub.resolve(&id).unwrap())["lastSeq"].as_u64().unwrap();
    hub.shutdown_all().await;
    drop(hub);
    // Simulate a crash mid-turn: a turn_started with no turn_result.
    let store2 = acpmux::store::open(&cfg.store, &dir).unwrap();
    store2
        .append(
            &id,
            &EventRecord {
                seq: last + 1,
                at: 0,
                dir: "mux".into(),
                kind: "turn_started".into(),
                msg: json!({"prompt": "lost"}),
            },
        )
        .unwrap();
    let hub2 = Hub::new(cfg, store2);
    let events = hub2.events(&id, last, 100).unwrap();
    let final_kind = events.last().map(|e| e.kind.clone()).unwrap_or_default();
    assert_eq!(
        final_kind,
        "turn_result",
        "{:?}",
        events.iter().map(|e| &e.kind).collect::<Vec<_>>()
    );
    assert_eq!(events.last().unwrap().msg["detail"], "outcome_unknown");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn limit_error_fails_over_to_the_fallback_profile() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: Some("fake-pool".into()),
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    agents.insert(
        "fake-pool".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
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
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "fo"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]}),
    )
    .await
    .unwrap();
    // The direct profile reports a usage limit; the pool profile answers.
    // The fake agent echoes the same prompt text, so the failover reply is
    // the echo of the limit prompt from the second process.
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "limit: now"}]}),
        )
        .await;
    let session = hub.resolve(&id).unwrap();
    let kinds: Vec<String> =
        hub.events(&id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "failover"), "{kinds:?} {r:?}");
    assert_eq!(hub.session_summary(&session)["harness"], "fake-pool");
    // The pool profile is the same fake agent, so it reports the limit too:
    // no second failover, the turn fails once and stays on the pool.
    assert!(r.is_err(), "{r:?}");
    assert_eq!(kinds.iter().filter(|k| *k == "failover").count(), 1);
    let ok = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "after"}]}),
        )
        .await
        .unwrap();
    assert_eq!(ok["stopReason"], "end_turn");
    assert_eq!(hub.session_summary(&session)["preview"], "echo: after");
}

#[tokio::test]
async fn process_death_quotes_the_last_stderr_line() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "die"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let r = c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "die: Not logged in · Please run /login"}]})).await;
    let err = r.unwrap_err();
    assert!(err.contains("agent process closed (fake): Not logged in"), "{err}");
    let session = hub.resolve(&id).unwrap();
    let last =
        hub.events(&id, 0, 1000).unwrap().into_iter().rfind(|e| e.kind == "turn_result").unwrap();
    assert_eq!(last.msg["status"], "failed");
    assert!(last.msg["error"].as_str().unwrap().contains("Not logged in"));
    assert_eq!(hub.session_summary(&session)["status"], "disconnected");
}

#[tokio::test]
async fn family_defaults_presets_and_the_target_grammar() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
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
    let mut pool = HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    // A declared model the harness does not report, in provider/model form.
    // `-m fake/m3` resolves to this profile through the family's prefer list.
    pool.models = vec![acpmux::config::DeclaredModel::Id("fake/m3".into())];
    agents.insert("fake-pool".to_owned(), pool);
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.defaults.insert(
        "fake".into(),
        acpmux::config::SessionDefaults {
            model: Some("m2".into()),
            effort: None,
            policy: Some(PermissionPolicy::ApproveAll),
            prefer: vec!["fake-pool".into()],
            env: BTreeMap::new(),
        },
    );
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    // -m fake: the family's prefer list picks the pool; defaults apply.
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "name": "fam"}}})).await.unwrap();
    let sum = &s["_meta"]["acpmux"];
    assert_eq!(sum["harness"], "fake-pool", "{sum}");
    assert_eq!(sum["family"], "fake");
    assert_eq!(sum["policy"], "approve-all");
    assert_eq!(sum["model"], "m2");
    // -m fake-pool/m1 --policy ask: explicit values win.
    let s2 = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake-pool", "name": "fam2", "model": "m1", "policy": "ask"}}})).await.unwrap();
    assert_eq!(s2["_meta"]["acpmux"]["model"], "m1");
    assert_eq!(s2["_meta"]["acpmux"]["policy"], "ask");
    // -m fake/m3 where the catalog lists `fake/m3`, not `m3`: the full id is used.
    let s3 = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "name": "fam3", "model": "m3"}}})).await.unwrap();
    assert_eq!(s3["_meta"]["acpmux"]["model"], "fake/m3");
    // A bare model id is refused with the spelling to use.
    let err = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": "m2"}}}),
        )
        .await
        .unwrap_err();
    assert!(
        err.contains("unknown harness \"m2\"") && err.contains("is a model id: write fake-pool/m2"),
        "{err}"
    );
    let err = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": "gpt"}}}),
        )
        .await
        .unwrap_err();
    assert!(err.contains("families: fake") && !err.contains("is a model id"), "{err}");
    // Harness view lists families, defaults and presets; declared models show first.
    let a = c.request(method::MUX_HARNESSES, json!({})).await.unwrap();
    assert_eq!(a["harnesses"]["fake-pool"]["family"], "fake");
    assert_eq!(a["families"]["fake"], json!(["fake", "fake-pool"]));
    let models = c.request("_acpmux/models", json!({})).await.unwrap();
    let fake_models: Vec<&str> = models["harnesses"]
        .as_array()
        .unwrap()
        .iter()
        .find(|h| h["harness"] == "fake-pool")
        .unwrap()["models"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap())
        .collect();
    assert_eq!(fake_models[0], "fake/m3", "{fake_models:?}");
    assert!(fake_models.contains(&"m1"));
    // Presets: one harness, bundled model/effort/policy/env; -m still wins.
    let p = c.request(method::MUX_PRESETS, json!({"name": "fast", "set": {"harness": "fake-pool", "model": "m1", "policy": "deny-all", "env": {"FAKE_MODEL": "${model}"}}})).await.unwrap();
    assert_eq!(p["profile"], "fake-pool");
    let err = c
        .request(method::MUX_PRESETS, json!({"name": "bad", "set": {"harness": "nope"}}))
        .await
        .unwrap_err();
    assert!(err.contains("unknown harness"), "{err}");
    let s4 = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"preset": "fast", "name": "pre"}}})).await.unwrap();
    assert_eq!(s4["_meta"]["acpmux"]["harness"], "fake-pool");
    assert_eq!(s4["_meta"]["acpmux"]["model"], "m1");
    assert_eq!(s4["_meta"]["acpmux"]["policy"], "deny-all");
    // ${model} in the preset env: the model is a spawn parameter the process sees.
    let id4 = s4["sessionId"].as_str().unwrap().to_owned();
    c.request(method::MUX_SET_POLICY, json!({"sessionId": id4, "policy": "approve-all"}))
        .await
        .unwrap();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id4, "prompt": [{"type": "text", "text": "env: FAKE_MODEL"}]}),
    )
    .await
    .unwrap();
    assert_eq!(hub.session_summary(&hub.resolve(&id4).unwrap())["preview"], "FAKE_MODEL=m1");
    let s5 = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"preset": "fast", "harness": "fake", "model": "m2", "name": "pre2"}}})).await.unwrap();
    // `fake` is the family: its prefer list still decides the profile.
    assert_eq!(s5["_meta"]["acpmux"]["harness"], "fake-pool");
    assert_eq!(s5["_meta"]["acpmux"]["model"], "m2");
    assert_eq!(s5["_meta"]["acpmux"]["policy"], "deny-all");
    let err = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"preset": "nope"}}}),
        )
        .await
        .unwrap_err();
    assert!(err.contains("unknown preset"), "{err}");
    let list = c.request(method::MUX_PRESETS, json!({})).await.unwrap();
    assert_eq!(list["presets"][0]["name"], "fast");
}

#[tokio::test]
async fn client_fs_writes_go_through_the_permission_policy() {
    let dir = std::env::temp_dir().join(format!("acpmux-fs-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let dir_s = dir.to_string_lossy().into_owned();
    // approve-edits: the write happens without a prompt.
    let (hub, mut c) = setup(PermissionPolicy::ApproveEdits).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": dir_s, "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "fswrite: a.txt"}]}),
    )
    .await
    .unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "wrote");
    assert_eq!(std::fs::read_to_string(dir.join("a.txt")).unwrap(), "ok\n");
    let kinds: Vec<String> =
        hub.events(&id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "permission_auto"), "{kinds:?}");
    // Reads pass, with line/limit windows.
    std::fs::write(dir.join("r.txt"), "one\ntwo\nthree\n").unwrap();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "fsread: r.txt"}]}),
    )
    .await
    .unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "read: one two three");
    // ask: the write shows up as a pending permission with kind edit; a rejection reaches the harness.
    c.request(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": "ask"})).await.unwrap();
    c.next += 1;
    let prompt_id = c.next;
    c.tx.send(
        Message::request(
            prompt_id,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "fswrite: b.txt"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    assert_eq!(pending["request"]["toolCall"]["kind"], "edit");
    assert_eq!(pending["request"]["toolCall"]["title"], "Write b.txt");
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "reject_once"}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert!(
        hub.session_summary(&session)["preview"].as_str().unwrap().starts_with("rejected:"),
        "{}",
        hub.session_summary(&session)["preview"]
    );
    assert!(!dir.join("b.txt").exists());
    // deny-all refuses reads too.
    c.request(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": "deny-all"}))
        .await
        .unwrap();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "fsread: r.txt"}]}),
    )
    .await
    .unwrap();
    assert!(hub.session_summary(&session)["preview"].as_str().unwrap().starts_with("rejected:"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn directory_browser_resolves_relative_paths_and_lists_folders_only() {
    let root = std::env::temp_dir().join(format!("acpmux-directory-rpc-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("My Project")).unwrap();
    std::fs::write(root.join("file.txt"), "not a directory").unwrap();
    let (_, mut c) = setup(PermissionPolicy::Ask).await;
    let result = c
        .request("_acpmux/directories", json!({"cwd":root, "path":"My Project/.."}))
        .await
        .unwrap();
    let canonical = std::fs::canonicalize(&root).unwrap();
    assert_eq!(result["path"], canonical.to_string_lossy().as_ref());
    assert_eq!(result["directories"], json!([canonical.join("My Project")]));
    assert!(c.request("_acpmux/directories", json!({"cwd":root,"path":"file.txt"})).await.is_err());
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn catalog_reload_preserves_pending_turn_and_rejects_invalid_config() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let dir = std::env::temp_dir().join(format!("acpmux-reload-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    hub.config.write().await.path = Some(path.clone());
    let original = hub.config.read().await.clone();
    let profile = original.harnesses["fake"].clone();
    let s = c.request(method::SESSION_NEW, json!({"cwd":cwd(),"mcpServers":[]})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    let agent_sid = session.meta().agent_session_id;
    c.next += 1;
    c.tx.send(Message::request(c.next, method::SESSION_PROMPT, json!({"sessionId":id,"prompt":[{"type":"text","text":"ask: keep this pending across reload"}]})).to_line()).await.unwrap();
    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;

    let mut next = original.clone();
    // Override all ambient discovery with test fixtures: no real provider is launched.
    for name in acpmux::config::discover_harnesses().keys() {
        next.harnesses.insert(name.clone(), profile.clone());
    }
    next.harnesses.remove("fake");
    next.harnesses.insert("deepseek".into(), profile.clone());
    next.default_harness = Some("deepseek".into());
    next.permission_policy = PermissionPolicy::ApproveAll;
    next.websocket =
        Some(acpmux::config::WebSocketConfig { listen: "127.0.0.1:1".into(), token: None });
    next.defaults.insert(
        "deepseek".into(),
        acpmux::config::SessionDefaults { model: Some("m2".into()), ..Default::default() },
    );
    next.presets.insert(
        "flash".into(),
        acpmux::config::Preset {
            harness: "deepseek".into(),
            model: None,
            effort: None,
            policy: None,
            env: BTreeMap::new(),
            description: None,
        },
    );
    std::fs::write(&path, serde_json::to_vec(&next).unwrap()).unwrap();
    let reload = c.request(method::MUX_RELOAD_CONFIG, json!({})).await.unwrap();
    assert_eq!(reload["reloaded"], true);
    assert_eq!(reload["retainedProfiles"], json!(["fake"]));
    assert_eq!(session.meta().agent_session_id, agent_sid);
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
    assert_eq!(session.pending_permissions()[0].0, pending["permissionId"]);
    {
        let cfg = hub.config.read().await;
        assert!(cfg.harnesses.contains_key("deepseek"));
        assert_eq!(cfg.permission_policy, PermissionPolicy::Ask);
        assert_eq!(cfg.websocket, original.websocket);
        assert_eq!(cfg.defaults["deepseek"].model.as_deref(), Some("m2"));
        assert_eq!(cfg.presets["flash"].harness, "deepseek");
    }
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId":id,"permissionId":pending["permissionId"],"optionId":"yes"}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(hub.session_summary(&session)["preview"], "chose yes");
    let events = hub.events(&id, 0, 1000).unwrap();
    assert_eq!(events.iter().filter(|e| e.dir == "out" && e.kind == "initialize").count(), 1);
    let new = c
        .request(
            method::SESSION_NEW,
            json!({"cwd":cwd(),"mcpServers":[],"_meta":{"acpmux":{"preset":"flash"}}}),
        )
        .await
        .unwrap();
    assert_eq!(new["configOptions"][0]["currentValue"], "m2");

    std::fs::write(&path, "{invalid").unwrap();
    assert!(
        c.request(method::MUX_RELOAD_CONFIG, json!({}))
            .await
            .unwrap_err()
            .contains("reload config")
    );
    assert!(hub.config.read().await.harnesses.contains_key("deepseek"));
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId":id,"prompt":[{"type":"text","text":"still here"}]}),
    )
    .await
    .unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "echo: still here");
    hub.shutdown_all().await;
    std::fs::remove_dir_all(dir).unwrap();
}
