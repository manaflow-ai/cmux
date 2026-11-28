//! A read through the hub, end to end in one process: machine A's [`read`] posts to a stand-in
//! hub that leases the message straight to machine B's relay (`deliver`, with the `sameUser`
//! control entry `host join` writes), and A reads B's reply from the receipt. No ssh peer, no
//! peer link.

use super::*;
use crate::config::Config;
use crate::mesh::{HubError, InMessage, MeshHub, Receipt};
use crate::mesh_http::MeshControlFrom;
use futures::future::BoxFuture;
use std::sync::Mutex;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn machine_b() -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

/// A local client of machine B, to make its session and run a turn.
async fn call(hub: &Arc<Hub>, m: &str, params: Value) -> Value {
    call_as(hub, Origin::Local, m, params).await
}

/// [`call`] from `origin`: the app's pane is `Origin::LocalApp`.
async fn call_as(hub: &Arc<Hub>, origin: Origin, m: &str, params: Value) -> Value {
    let (tx, in_rx) = mpsc::channel(16);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(crate::server::serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    tx.send(crate::rpc::Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await.unwrap().unwrap();
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("id") == Some(&json!(1)) {
            assert!(value.get("error").is_none(), "{value}");
            return value["result"].clone();
        }
    }
}

/// The hub as both machines see it: a send is leased to B at once, under the person the hub
/// stamps (`user`), and B's ack is the receipt A reads.
struct Loopback {
    b: Arc<Hub>,
    hook: super::super::MeshControlHook,
    user: &'static str,
    receipts: Mutex<std::collections::HashMap<String, Receipt>>,
    unknown: bool,
    /// The reads sent: each is one round trip through the hub and the receiver's inbox.
    asks: std::sync::atomic::AtomicUsize,
    /// Optional event gate used by the concurrent-read regression test.
    send_release: Option<tokio::sync::Notify>,
}

impl Loopback {
    fn new(b: &Arc<Hub>, dir: &std::path::Path, user: &'static str) -> Self {
        let hook = super::super::MeshControlHook::new(
            vec![MeshControlFrom::same_user()],
            Some(dir.join("mesh-controls.json")),
        )
        .with_own_user(Arc::new(|| Some("person-1".to_owned())));
        Self {
            b: b.clone(),
            hook,
            user,
            receipts: Mutex::default(),
            unknown: false,
            asks: Default::default(),
            send_release: None,
        }
    }
}

impl MeshHub for Loopback {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async { Ok(Vec::new()) })
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Ok(()) })
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        Box::pin(async { Err(HubError::unavailable("unused")) })
    }

    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            m.validate().map_err(HubError::refused)?;
            // As the hub does (cmux-platform `Core.ts`): a read names one session.
            if m.op.as_deref() == Some("read") && m.to.session_id.is_none() && m.to.name.is_none() {
                let mut e = HubError::refused("a read names one session by sessionId or name");
                e.code = Some("mesh.invalid".into());
                return Err(e);
            }
            self.asks.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if let Some(release) = &self.send_release {
                release.notified().await;
            }
            if self.unknown {
                let mut e = HubError::refused("no such recipient");
                e.code = Some("mesh.unknown_recipient".into());
                return Err(e);
            }
            let id = format!("msg_{}", uuid::Uuid::now_v7().simple());
            let message = InMessage {
                message_id: id.clone(),
                kind: m.kind,
                op: m.op.clone(),
                mode: m.mode,
                // The hub resolved the host: the inbox names only the session.
                to: Target {
                    session_id: m.to.session_id.clone(),
                    name: m.to.name.clone(),
                    ..Target::default()
                },
                from: Sender {
                    daemon_id: Some("inst_a".into()),
                    user: Some(self.user.into()),
                    ..m.from.clone()
                },
                body: m.body.clone(),
                attempt: 1,
                start_work: None,
                state: Some("queued".into()),
                subject: None,
            };
            let ack = super::super::deliver(&self.b, &message, &self.hook, Some("inst_b"))
                .await
                .expect("a read is always answered");
            // The hub keeps an answer of at most one message body, as the real hub does.
            let answered = ack.result.as_ref().map_or(0, String::len);
            assert!(answered <= MAX_READ_RESULT_BYTES, "an answer of {answered} bytes");
            let mut receipt: Receipt = serde_json::from_value(json!({
                "messageId": id, "state": serde_json::to_value(ack.state).unwrap(), "createdAt": 1
            }))
            .unwrap();
            (receipt.detail, receipt.result) = (ack.detail, ack.result);
            // The first receipt is still queued; the answer comes in the sender's wait.
            self.receipts.lock().unwrap().insert(id.clone(), receipt.clone());
            receipt.state = "queued".into();
            (receipt.detail, receipt.result) = (None, None);
            Ok(receipt)
        })
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            self.receipts.lock().unwrap().get(id).cloned().ok_or_else(|| HubError::refused("none"))
        })
    }
}

#[test]
fn a_key_names_a_session_id_or_a_name_on_its_host() {
    let id = "019a5d1e-8f00-7000-8000-000000000001";
    let by_id = recipient("machine-b", id);
    assert_eq!((by_id.session_id.as_deref(), by_id.name), (Some(id), None));
    let by_name = recipient("machine-b", "own-e2e");
    assert_eq!(
        (by_name.name.as_deref(), by_name.host.as_deref()),
        (Some("own-e2e"), Some("machine-b"))
    );
    // Only the params a read takes go across, never a session or host the asker names.
    let sent: Value = serde_json::from_str(&body(
        method::MUX_EVENTS,
        &json!({"sessionId": "x", "host": "y", "limit": 5, "maxBytes": 9, "kinds": ["transcript"]}),
    ))
    .unwrap();
    assert_eq!(sent["params"], json!({"limit": 5, "maxBytes": 9, "kinds": ["transcript"]}));
    assert_eq!(
        serde_json::from_str::<Value>(&body(method::MUX_INFO, &json!({"x": 1}))).unwrap()["params"],
        json!({})
    );
    let search: Value = serde_json::from_str(&body(
        method::MUX_SESSION_SEARCH,
        &json!({
            "sessionId": "x",
            "host": "y",
            "query": "ship the build",
            "withTurnTime": true,
            "role": "assistant",
            "sinceMs": 123,
            "limit": 4,
        }),
    ))
    .unwrap();
    assert_eq!(
        search["params"],
        json!({"query": "ship the build", "role": "assistant", "sinceMs": 123, "limit": 4, "withTurnTime": true})
    );
}

#[tokio::test]
async fn the_same_persons_machine_reads_a_reply_through_the_hub_and_no_one_else_does() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "own-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    call(
        &b,
        method::SESSION_PROMPT,
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "pong from b"}]}),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");

    // `acpmux last machine-b/own-e2e`: info names the session, then its events page.
    let info = read(&hub, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap();
    assert_eq!(
        (info["sessionId"].as_str(), info["peer"].as_str()),
        (Some(session.as_str()), Some("machine-b"))
    );
    assert_eq!(info["via"], "hub");
    let page =
        json!({"limit": 5000, "kinds": ["transcript"], "maxBytes": 4 << 20, "beforeSeq": u64::MAX});
    let events = read(&hub, "machine-b", &session, method::MUX_EVENTS, &page).await.unwrap();
    let mut transcript = crate::transcript::Transcript::default();
    for event in events["events"].as_array().unwrap() {
        transcript.apply_event(event);
    }
    let replies: Vec<_> = transcript
        .items
        .iter()
        .filter_map(|item| match item {
            crate::transcript::Item::Assistant { text } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(replies, ["echo: pong from b"]);

    // The app's open of the chat: a hidden attach there, answered with its detail and newest page.
    let attach =
        json!({"sessionId": format!("machine-b/{session}"), "limit": 200, "maxBytes": 1 << 20});
    let opened = read(&hub, "machine-b", &session, method::MUX_ATTACH, &attach).await.unwrap();
    assert_eq!(opened["session"]["sessionId"].as_str(), Some(session.as_str()), "{opened}");
    assert!(opened["events"].as_array().is_some_and(|events| !events.is_empty()), "{opened}");
    assert_eq!(opened["peer"], "machine-b");

    // Another person is refused by B itself, whatever the hub let through.
    let other = Loopback::new(&b, dir.path(), "person-2");
    let refused =
        read(&other, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert!(refused.message.contains("mesh.control_not_allowed"), "{refused:?}");
    // A session B does not have, or one the hub does not know, is `no session`.
    let missing =
        read(&hub, "machine-b", "nobody", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert_eq!(missing.code, RpcError::not_found("").code, "{missing:?}");
    let unknown = Loopback { unknown: true, ..Loopback::new(&b, dir.path(), "person-1") };
    let unknown =
        read(&unknown, "machine-c", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert_eq!(unknown.code, RpcError::not_found("").code, "{unknown:?}");
}

/// Concurrent callers of one hub-routed read share the single network round trip while it is
/// held in flight. The gate is event-driven, so a caller that arrives after release would make a
/// second send and fail the count below.
#[tokio::test]
async fn single_flight_concurrent_hub_reads_share_one_send() {
    const CALLERS: usize = 8;
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "shared-read"}});
    let _made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let mut loopback = Loopback::new(&b, dir.path(), "person-1");
    loopback.send_release = Some(tokio::sync::Notify::new());
    let loopback = Arc::new(loopback);
    let params = json!({});
    let mut callers = Vec::new();
    for _ in 0..CALLERS {
        let mut caller = Box::pin(read_shared(
            &b,
            loopback.clone(),
            "machine-b",
            "shared-read",
            method::MUX_INFO,
            &params,
        ));
        assert!(futures::poll!(&mut caller).is_pending());
        callers.push(caller);
    }
    assert_eq!(loopback.asks.load(std::sync::atomic::Ordering::SeqCst), 1);
    loopback.send_release.as_ref().unwrap().notify_waiters();
    for caller in callers {
        assert_eq!(caller.await.unwrap()["peer"], "machine-b");
    }
    assert_eq!(loopback.asks.load(std::sync::atomic::Ordering::SeqCst), 1);
}

/// A chat with one record over the hub's 64 KiB opens through the hub, and its older pages read
/// back to that record: a page always holds at least one record, so no smaller page fits it.
#[tokio::test]
async fn a_chat_page_with_a_record_over_64_kib_opens_through_the_hub() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "big-record"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    let big = "a 65 KiB line ".repeat(65 * 1024 / 14 + 1);
    assert!(big.len() > 65 * 1024);
    call(
        &b,
        method::SESSION_PROMPT,
        json!({"sessionId": session, "prompt": [{"type": "text", "text": big}]}),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");

    // The app's open of the chat, then its older pages as the pane reads them back.
    let attach =
        json!({"sessionId": format!("machine-b/{session}"), "limit": 200, "maxBytes": 1 << 20});
    let opened = read(&hub, "machine-b", &session, method::MUX_ATTACH, &attach).await.unwrap();
    assert_eq!(opened["session"]["sessionId"].as_str(), Some(session.as_str()));
    assert_eq!((opened["peer"].as_str(), opened["via"].as_str()), (Some("machine-b"), Some("hub")));
    let mut events: Vec<Value> = opened["events"].as_array().cloned().unwrap_or_default();
    let mut more = opened["hasMore"].as_bool() == Some(true);
    for _ in 0..64 {
        if !more {
            break;
        }
        let oldest = events.iter().filter_map(|e| e["seq"].as_u64()).min().unwrap();
        let older = json!({"limit": 200, "maxBytes": 1 << 20, "beforeSeq": oldest});
        let page = read(&hub, "machine-b", &session, method::MUX_EVENTS, &older).await.unwrap();
        more = page["hasMore"].as_bool() == Some(true);
        events.extend(page["events"].as_array().cloned().unwrap_or_default());
    }
    assert!(!more, "the pages never reached the chat's start");
    events.sort_by_key(|e| e["seq"].as_u64());
    let mut transcript = crate::transcript::Transcript::default();
    for event in &events {
        transcript.apply_event(event);
    }
    let replies: Vec<_> = transcript
        .items
        .iter()
        .filter_map(|item| match item {
            crate::transcript::Item::Assistant { text } => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(replies, [format!("echo: {big}")]);
}

/// cmuxterm-hq#15806: claude-sr2-coord's 373 KB detail went through the hub in ten round trips,
/// 52 to 106 s on a busy host, past the 50 s a read waits, and `acpmux last` reads it first.
/// A detail of any size is one round trip now, its largest fields marked omitted.
#[tokio::test]
async fn a_chat_detail_of_any_size_reads_through_the_hub_in_one_round_trip() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "big-detail"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    // About 400 KB of commands, as a coordinator's detail was 373 KB.
    let commands: Vec<Value> = (0..3000)
        .map(|i| json!({"name": format!("command-{i}"), "description": "d".repeat(110)}))
        .collect();
    b.resolve(&session).unwrap().set_available_commands_for_test(json!(commands));
    let whole = call(&b, method::MUX_INFO, json!({"sessionId": session})).await;
    assert!(
        whole.to_string().len() > 350 * 1024,
        "the detail is {} bytes",
        whole.to_string().len()
    );
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");

    let info = read(&hub, "machine-b", "big-detail", method::MUX_INFO, &json!({})).await.unwrap();
    let asks = hub.asks.load(std::sync::atomic::Ordering::SeqCst);
    assert_eq!(asks, 1, "info took {asks} round trips through the hub");
    assert_eq!(info["sessionId"].as_str(), Some(session.as_str()));
    assert_eq!((info["peer"].as_str(), info["via"].as_str()), (Some("machine-b"), Some("hub")));
    let omitted: Vec<&str> =
        info["omitted"]["fields"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
    assert!(omitted.contains(&"availableCommands"), "{omitted:?}");
    // `acpmux last`'s id: what it reads from the detail is whole.
    assert_eq!(crate::cli::resolve::routed_id(&info).unwrap(), format!("machine-b/{session}"));
}

/// The queue an `_acpmux/info` through the hub carries is its next [`HUB_QUEUE_KEEP`] prompts
/// and their count, whatever its length: 368 queued prompts were 229 KB of one detail.
#[test]
fn a_detail_through_the_hub_carries_the_queue_head_and_its_count() {
    let queued: Vec<Value> = (0..400)
        .map(|i| json!({"promptId": format!("p-{i}"), "prompt": "q".repeat(600)}))
        .collect();
    let mut detail = json!({
        "sessionId": "s", "status": "running", "queue": queued,
        "timeBreakdown": {"rows": "t".repeat(80 * 1024)},
    });
    fit_info(&mut detail);
    assert!(detail.to_string().len() <= HUB_INFO_BYTES, "{} bytes", detail.to_string().len());
    let queue = detail["queue"].as_array().unwrap();
    assert_eq!(queue.len(), HUB_QUEUE_KEEP);
    assert_eq!(queue[0]["promptId"], "p-0");
    assert_eq!(
        (detail["queueCount"].as_u64(), detail["queueTruncated"].as_bool()),
        (Some(400), Some(true))
    );
    assert_eq!(detail["sessionId"], "s");
    // A short queue goes whole, with no count.
    let mut short = json!({"sessionId": "s", "queue": [{"promptId": "p-0"}]});
    fit_info(&mut short);
    assert_eq!(short, json!({"sessionId": "s", "queue": [{"promptId": "p-0"}]}));
}

#[tokio::test]
async fn a_read_runs_only_a_read_method() {
    let b = machine_b();
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");
    let refused =
        read(&hub, "machine-b", "own-e2e", method::SESSION_PROMPT, &json!({})).await.unwrap_err();
    assert!(refused.message.contains("mesh.read_unsupported"), "{refused:?}");
}

/// The app's prompt to a chat the hub lists for another machine of the same person goes through
/// the hub and runs there as a turn; nothing here refuses it as no session (#36710 review).
#[tokio::test]
async fn a_prompt_to_a_listed_hub_chat_runs_there_through_the_hub() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "own-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    let dir = tempfile::tempdir().unwrap();
    let a = machine_b();
    let mesh: Arc<dyn MeshHub> = Arc::new(Loopback::new(&b, dir.path(), "person-1"));
    let _ = a.mesh.set(mesh);
    let hosts = std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]);
    let row = crate::mesh::BookSession {
        name: "own-e2e".into(),
        session_id: session.clone(),
        host: "machine-b".into(),
        daemon_id: "inst_b".into(),
        harness: "fake".into(),
        state: "idle".into(),
        stuck_reason: None,
        last_seen_at: 1,
        ..Default::default()
    };
    a.set_mesh_book(hosts, vec![row]);

    // As the pane sends it, over the app's own connection: the listed row's bare id.
    let sent = call_as(
        &a,
        Origin::LocalApp,
        method::SESSION_PROMPT,
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello from a"}]}),
    )
    .await;
    assert_eq!(sent["via"], "mesh", "{sent}");
    // B runs it as a turn: its reply shows there within the bound.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let info = call(&b, method::MUX_INFO, json!({"sessionId": session})).await;
        if info.to_string().contains("echo: hello from a") {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "no reply on B: {info}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    // A name the hub does not list here stays this daemon's refusal.
    assert!(prompt_target_is_listed(&a, "machine-c/own-e2e").is_none());
}

/// The target [`prompt`] would send `key` to, without sending.
fn prompt_target_is_listed(hub: &Arc<Hub>, key: &str) -> Option<()> {
    let (host, _) = key.split_once('/')?;
    hub.mesh_book_has_host(host).then_some(())
}

/// A child with no peer link can report through its journal even if its own tools
/// cannot open sockets. The starter owns both paging and delivery.
#[tokio::test]
async fn a_hub_only_sandbox_refusal_reaches_the_starters_chat() {
    let b = machine_b();
    let child = call(
        &b,
        method::SESSION_NEW,
        json!({
            "cwd": std::env::temp_dir(), "mcpServers": [],
            "_meta": {"acpmux": {"harness": "fake", "name": "blocked-child"}}
        }),
    )
    .await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let a = machine_b();
    let parent = call(
        &a,
        method::SESSION_NEW,
        json!({
            "cwd": std::env::temp_dir(), "mcpServers": [],
            "_meta": {"acpmux": {"harness": "fake", "name": "starter"}}
        }),
    )
    .await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let dir = tempfile::tempdir().unwrap();
    a.mesh.set(Arc::new(Loopback::new(&b, dir.path(), "person-1")));
    let key = format!("machine-b/{child}");
    a.set_mesh_book(
        std::collections::BTreeMap::from([("machine-b".into(), 1)]),
        vec![crate::mesh::BookSession {
            name: "blocked-child".into(),
            session_id: child.clone(),
            host: "machine-b".into(),
            daemon_id: "inst_b".into(),
            harness: "fake".into(),
            state: "idle".into(),
            ..Default::default()
        }],
    );
    assert_eq!(crate::hub::watches::resolve(&a, &key).unwrap(), key);
    let mut events = a.subscribe();
    a.watches
        .add(crate::hub::watches::Watch {
            id: "hub-failure-report".into(),
            to: parent.clone(),
            sessions: vec![key.clone()],
            until: vec!["blocked".into()],
            match_text: None,
            once: true,
            caller: None,
            active: true,
            cursors: [(key, Default::default())].into_iter().collect(),
            offline: Default::default(),
            ..Default::default()
        })
        .unwrap();
    let remote = b.resolve(&child).unwrap();
    b.append(
        &remote,
        "mux",
        "harness_sandbox_failed",
        json!({
            "error": "cannot create .git/index.lock: Permission denied", "remote": true
        }),
    );
    a.start_watches();
    let report = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.session_id == parent
                && event.record.kind == "user_message"
                && let Some(text) = event.record.msg["text"].as_str()
                && text.contains("index.lock")
            {
                break text.to_owned();
            }
        }
    })
    .await
    .expect("hub-only refusal never reached the starter");
    assert!(report.contains("blocked") && report.contains("Full access"), "{report}");
    a.shutdown_all().await;
    b.shutdown_all().await;
}

/// `acpmux history HOST/NAME` for a session only the hub reaches reads its turns there, as
/// `acpmux last` reads its page; a session read the hub does not carry says so and is never
/// answered `no session` (2026-11-19: `acpmux history cosmic-gray/claude-desktop-…` answered
/// no_session while `acpmux last` of it worked).
#[tokio::test]
async fn history_reads_through_the_hub_and_other_session_reads_never_answer_no_session() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "own-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    call(
        &b,
        method::SESSION_PROMPT,
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "turn on b"}]}),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let a = machine_b();
    let mesh: Arc<dyn MeshHub> = Arc::new(Loopback::new(&b, dir.path(), "person-1"));
    let _ = a.mesh.set(mesh);

    let history =
        call(&a, method::MUX_HISTORY, json!({"sessionId": "machine-b/own-e2e", "limit": 5})).await;
    assert_eq!(history["sessionId"].as_str(), Some(session.as_str()), "{history}");
    assert_eq!(history["turns"].as_array().map(Vec::len), Some(1), "{history}");
    assert_eq!(
        (history["peer"].as_str(), history["via"].as_str()),
        (Some("machine-b"), Some("hub"))
    );

    let found = call(
        &a,
        method::MUX_SESSION_SEARCH,
        json!({"sessionId": "machine-b/own-e2e", "query": "turn on b", "role": "user"}),
    )
    .await;
    assert_eq!(found["hits"][0]["snippet"], "turn on b");
    assert_eq!(found["peer"], "machine-b");

    for m in [method::MUX_QUEUE_TEXT, method::MUX_ATTACHMENT, method::MUX_WAIT] {
        let refused = call_error(&a, m, json!({"sessionId": "machine-b/own-e2e"})).await;
        assert_eq!(
            refused.pointer("/data/reason"),
            Some(&json!("mesh.read_unsupported")),
            "{m}: {refused}"
        );
        let said = refused["message"].as_str().unwrap_or_default();
        assert!(!said.contains("no session"), "{m}: {refused}");
    }
}

/// `acpmux rename HOST/ID NAME [--handle]` for a session only the hub reaches renames it there,
/// as `acpmux info HOST/ID` reads it. Leo, 2026-11-23: "the renaming paradigm still hasn't hit
/// yet" (every such rename from a lane VM answered no_session). A sender granted `read` alone
/// renames nothing, and a session verb the hub does not carry says so, never `no session`.
#[tokio::test]
async fn rename_reaches_a_session_only_the_hub_reaches_and_no_verb_answers_no_session() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "own-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    let dir = tempfile::tempdir().unwrap();
    let a = machine_b();
    let mesh: Arc<dyn MeshHub> = Arc::new(Loopback::new(&b, dir.path(), "person-1"));
    let _ = a.mesh.set(mesh);
    let hosts = std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]);
    let row = crate::mesh::BookSession {
        name: "own-e2e".into(),
        session_id: session.clone(),
        host: "machine-b".into(),
        daemon_id: "inst_b".into(),
        harness: "fake".into(),
        state: "idle".into(),
        last_seen_at: 1,
        ..Default::default()
    };
    a.set_mesh_book(hosts, vec![row]);
    let on_b = |key: &str| call(&b, method::MUX_INFO, json!({"sessionId": key}));

    // By name, as `acpmux rename machine-b/own-e2e renamed-e2e` sends it.
    let renamed = call(
        &a,
        method::MUX_RENAME,
        json!({"sessionId": "machine-b/own-e2e", "newName": "renamed-e2e"}),
    )
    .await;
    assert_eq!(renamed["name"], "renamed-e2e", "{renamed}");
    assert_eq!(
        (renamed["peer"].as_str(), renamed["via"].as_str()),
        (Some("machine-b"), Some("hub"))
    );
    assert_eq!(on_b(&session).await["name"], "renamed-e2e");
    // By id, as the CLI sends it once it resolved `HOST/NAME` (`resolve_id`, `control_id`), and
    // its spoken handle (`--handle`).
    let by_id = format!("machine-b/{session}");
    let handle =
        call(&a, method::MUX_RENAME, json!({"sessionId": by_id, "newHandle": "Mango"})).await;
    assert_eq!(handle["handle"], "Mango", "{handle}");
    assert_eq!(on_b(&session).await["handle"], "Mango");
    // The same rename again (the hub may lease a message twice) leaves it as once.
    let again =
        call(&a, method::MUX_RENAME, json!({"sessionId": by_id, "newHandle": "Mango"})).await;
    assert_eq!(again["handle"], "Mango", "{again}");

    // A sender B trusts only to read renames nothing.
    let read_only = Loopback {
        hook: super::super::MeshControlHook::new(
            vec![MeshControlFrom {
                same_user: true,
                ops: vec!["read".into()],
                ..Default::default()
            }],
            Some(dir.path().join("mesh-controls-read.json")),
        )
        .with_own_user(Arc::new(|| Some("person-1".to_owned()))),
        ..Loopback::new(&b, dir.path(), "person-1")
    };
    let info = read(&read_only, "machine-b", &session, method::MUX_INFO, &json!({})).await;
    assert!(info.is_ok(), "a read-only sender still reads: {info:?}");
    let refused = read(
        &read_only,
        "machine-b",
        &session,
        method::MUX_RENAME,
        &json!({"newName": "taken-over"}),
    )
    .await
    .unwrap_err();
    assert!(refused.message.contains("mesh.control_not_allowed"), "{refused:?}");
    assert_eq!(on_b(&session).await["name"], "renamed-e2e");

    // A retry goes through too (`acpmux retry machine-b/renamed-e2e`): B runs it on its own
    // session and answers, here that its last turn did not fail, never that the hub does not
    // carry it (2026-11-24: lanes the SR2 pool's 503 cut could not be retried from here).
    let retry =
        call_error(&a, method::MUX_RETRY, json!({"sessionId": "machine-b/renamed-e2e"})).await;
    let said = retry["message"].as_str().unwrap_or_default();
    assert!(said.contains("retry.nothing_failed"), "{retry}");
    assert!(!said.contains("does not carry") && !said.contains("no session"), "{retry}");
    // A sender B trusts only to read retries nothing.
    let refused =
        read(&read_only, "machine-b", &session, method::MUX_RETRY, &json!({})).await.unwrap_err();
    assert!(refused.message.contains("mesh.control_not_allowed"), "{refused:?}");

    // Every other session verb the hub does not carry says so, by name or by id.
    for (m, key) in [
        (method::MUX_PAUSE, "machine-b/renamed-e2e"),
        (method::MUX_KILL, by_id.as_str()),
        (method::MUX_WAKE, by_id.as_str()),
        (method::MUX_SET_POLICY, by_id.as_str()),
    ] {
        let refused = call_error(&a, m, json!({"sessionId": key, "policy": "ask"})).await;
        assert_eq!(
            refused.pointer("/data/reason"),
            Some(&json!("mesh.read_unsupported")),
            "{m}: {refused}"
        );
        let said = refused["message"].as_str().unwrap_or_default();
        assert!(!said.contains("no session"), "{m}: {refused}");
        if m == method::MUX_KILL {
            assert!(said.contains("--mesh"), "{m} names the route that stops it: {refused}");
        }
    }
    // A host the hub does not list is still no session.
    let typo = call_error(&a, method::MUX_PAUSE, json!({"sessionId": "machine-z/own-e2e"})).await;
    assert_ne!(typo.pointer("/data/reason"), Some(&json!("mesh.read_unsupported")), "{typo}");
}

/// `acpmux session hold|release HOST/ID` and `acpmux session tag HOST/ID` for a session only the
/// hub reaches run there, as a rename does. 2026-11-26: a fleet pause's wake of a held lane only
/// the hub reaches from the waking machine refused at `session release` ("the mesh hub does not
/// carry _acpmux/session_hold"), pass after pass, while its `send` went through. A sender granted
/// `read` alone holds and tags nothing.
#[tokio::test]
async fn hold_release_and_tag_reach_a_session_only_the_hub_reaches() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "held-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    let dir = tempfile::tempdir().unwrap();
    let a = machine_b();
    let mesh: Arc<dyn MeshHub> = Arc::new(Loopback::new(&b, dir.path(), "person-1"));
    let _ = a.mesh.set(mesh);
    let hosts = std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]);
    let row = crate::mesh::BookSession {
        name: "held-e2e".into(),
        session_id: session.clone(),
        host: "machine-b".into(),
        daemon_id: "inst_b".into(),
        harness: "fake".into(),
        state: "idle".into(),
        last_seen_at: 1,
        ..Default::default()
    };
    a.set_mesh_book(hosts, vec![row]);
    let tag_on_b =
        |key: &str| b.resolve(&session).unwrap().meta().tags.get(key).map(|t| t.value.clone());
    let by_id = format!("machine-b/{session}");
    let hold_tag = crate::hub::session_hold::TAG;

    // `acpmux session hold machine-b/ID`, twice (the hub may lease a message again): held once.
    for _ in 0..2 {
        let held =
            call(&a, method::MUX_SESSION_HOLD, json!({"sessionId": by_id, "held": true})).await;
        assert_eq!(held["held"], true, "{held}");
        assert_eq!((held["peer"].as_str(), held["via"].as_str()), (Some("machine-b"), Some("hub")));
    }
    assert_eq!(tag_on_b(hold_tag).as_deref(), Some("on"));
    assert!(b.session_held(&b.resolve(&session).unwrap()));
    // `acpmux session release machine-b/held-e2e`, by name.
    let released = call(
        &a,
        method::MUX_SESSION_HOLD,
        json!({"sessionId": "machine-b/held-e2e", "held": false}),
    )
    .await;
    assert_eq!(
        (released["held"].as_bool(), released["was"].as_bool()),
        (Some(false), Some(true)),
        "{released}"
    );
    assert!(!b.session_held(&b.resolve(&session).unwrap()));

    // `acpmux session tag machine-b/ID k=v`, then `--remove k`.
    let tagged =
        call(&a, method::MUX_TAG, json!({"sessionId": by_id, "set": {"fleet-pause.held": "x"}}))
            .await;
    assert_eq!(tagged["via"], "hub", "{tagged}");
    assert_eq!(tag_on_b("fleet-pause.held").as_deref(), Some("x"));
    call(&a, method::MUX_TAG, json!({"sessionId": by_id, "remove": ["fleet-pause.held"]})).await;
    assert_eq!(tag_on_b("fleet-pause.held"), None);
    // The receiver keeps its own rules: the tag only `acpmux register` sets is refused there.
    let reserved = call_error(
        &a,
        method::MUX_TAG,
        json!({"sessionId": by_id, "set": {crate::hub::register::REGISTERED_TAG: "1"}}),
    )
    .await;
    assert!(
        reserved["message"].as_str().unwrap_or_default().contains("acpmux register"),
        "{reserved}"
    );

    // A sender B trusts only to read holds and tags nothing.
    let read_only = Loopback {
        hook: super::super::MeshControlHook::new(
            vec![MeshControlFrom {
                same_user: true,
                ops: vec!["read".into()],
                ..Default::default()
            }],
            Some(dir.path().join("mesh-controls-read.json")),
        )
        .with_own_user(Arc::new(|| Some("person-1".to_owned()))),
        ..Loopback::new(&b, dir.path(), "person-1")
    };
    for (m, params) in [
        (method::MUX_SESSION_HOLD, json!({"held": true})),
        (method::MUX_TAG, json!({"set": {"taken": "over"}})),
    ] {
        let refused = read(&read_only, "machine-b", &session, m, &params).await.unwrap_err();
        assert!(refused.message.contains("mesh.control_not_allowed"), "{m}: {refused:?}");
    }
    assert!(!b.session_held(&b.resolve(&session).unwrap()));
    assert_eq!(tag_on_b("taken"), None);
}

/// `acpmux session hold|release HOST/ID` for a chat only the hub reaches holds and releases it
/// there, with its `held` (a release that dropped it would hold the chat instead). Leo,
/// 2026-11-26: "we can gradually lift the pause, efficiently"; the lift left 47 of 145 held lanes
/// asleep because the hub did not carry `_acpmux/session_hold`. A sender granted `read` alone
/// holds nothing.
#[tokio::test]
async fn a_hold_and_its_release_reach_a_session_only_the_hub_reaches() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "held-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    let dir = tempfile::tempdir().unwrap();
    let a = machine_b();
    let mesh: Arc<dyn MeshHub> = Arc::new(Loopback::new(&b, dir.path(), "person-1"));
    let _ = a.mesh.set(mesh);
    let hosts = std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]);
    let row = crate::mesh::BookSession {
        name: "held-e2e".into(),
        session_id: session.clone(),
        host: "machine-b".into(),
        daemon_id: "inst_b".into(),
        harness: "fake".into(),
        state: "idle".into(),
        last_seen_at: 1,
        ..Default::default()
    };
    a.set_mesh_book(hosts, vec![row]);
    let held_on_b = || b.session_held(&b.resolve(&session).unwrap());
    let by_id = format!("machine-b/{session}");

    let held = call(&a, method::MUX_SESSION_HOLD, json!({"sessionId": by_id, "held": true})).await;
    assert_eq!((held["held"].as_bool(), held["via"].as_str()), (Some(true), Some("hub")), "{held}");
    assert!(held_on_b());
    // The release fleet_pause sends, by id; twice (the hub may lease it again) is once.
    for _ in 0..2 {
        let released =
            call(&a, method::MUX_SESSION_HOLD, json!({"sessionId": by_id, "held": false})).await;
        assert_eq!(released["held"], false, "{released}");
        assert!(!held_on_b(), "released on B: {released}");
    }
    // By name too, as `acpmux session release machine-b/held-e2e` sends it before resolving.
    call(&a, method::MUX_SESSION_HOLD, json!({"sessionId": "machine-b/held-e2e", "held": true}))
        .await;
    assert!(held_on_b());
    call(&a, method::MUX_SESSION_HOLD, json!({"sessionId": "machine-b/held-e2e", "held": false}))
        .await;
    assert!(!held_on_b());

    // A sender B trusts only to read holds nothing.
    let read_only = Loopback {
        hook: super::super::MeshControlHook::new(
            vec![MeshControlFrom {
                same_user: true,
                ops: vec!["read".into()],
                ..Default::default()
            }],
            Some(dir.path().join("mesh-controls-read.json")),
        )
        .with_own_user(Arc::new(|| Some("person-1".to_owned()))),
        ..Loopback::new(&b, dir.path(), "person-1")
    };
    let refused =
        read(&read_only, "machine-b", &session, method::MUX_SESSION_HOLD, &json!({"held": true}))
            .await
            .unwrap_err();
    assert!(refused.message.contains("mesh.control_not_allowed"), "{refused:?}");
    assert!(!held_on_b());
}

/// [`call`]'s error, for a request that must fail.
async fn call_error(hub: &Arc<Hub>, m: &str, params: Value) -> Value {
    let (tx, in_rx) = mpsc::channel(16);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(crate::server::serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    tx.send(crate::rpc::Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await.unwrap().unwrap();
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("id") == Some(&json!(1)) {
            return value.get("error").cloned().unwrap_or_else(|| panic!("no error: {value}"));
        }
    }
}

// A browser is its own enrolled device on the mesh hub (RFD 0005). A web connection reads and
// prompts a chat the hub lists only with the device credential it presented on that connection
// (`_acpmux/device_hello`), never with this daemon's own hub identity (`may_read` holds).

/// The daemon's own hub identity, which no web connection may use: every call is counted and
/// refused.
#[derive(Default)]
struct DaemonIdentity {
    calls: std::sync::atomic::AtomicUsize,
}

impl DaemonIdentity {
    fn used(&self) -> usize {
        self.calls.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn call<T>(&self) -> Result<T, HubError> {
        self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Err(HubError::unavailable("the daemon's own identity was used"))
    }
}

impl MeshHub for DaemonIdentity {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async { Ok(Vec::new()) })
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Ok(()) })
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        Box::pin(async { Err(HubError::unavailable("unused")) })
    }

    fn send<'a>(&'a self, _: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { self.call() })
    }

    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { self.call() })
    }

    fn answer<'a>(&'a self, _: &'a str, _: Duration) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { self.call() })
    }
}

/// One request the fake HTTP hub saw: its request line, its bearer and its JSON body.
#[derive(Debug, Clone)]
struct Seen {
    line: String,
    bearer: String,
    body: Value,
}

type Respond = Box<dyn Fn(usize, &Seen) -> (u16, Value) + Send + Sync>;

/// The mesh hub over HTTP on a loopback port: it records every request and answers each with
/// `respond(index, request)`. Its URL goes in the daemon's `meshRelay`.
async fn http_hub(respond: Respond) -> (String, Arc<Mutex<Vec<Seen>>>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::<Seen>::new()));
    let log = Arc::clone(&seen);
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut bytes = Vec::new();
            let (head_len, body_len) = loop {
                let mut chunk = [0; 4096];
                let n = stream.read(&mut chunk).await.unwrap_or(0);
                if n == 0 {
                    break (0, 0);
                }
                bytes.extend_from_slice(&chunk[..n]);
                if let Some(end) = bytes.windows(4).position(|s| s == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&bytes[..end]);
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            let (key, value) = line.split_once(':')?;
                            key.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().unwrap_or(0))
                        })
                        .unwrap_or(0);
                    break (end + 4, length);
                }
            };
            if head_len == 0 {
                continue;
            }
            while bytes.len() < head_len + body_len {
                let mut chunk = [0; 4096];
                let n = stream.read(&mut chunk).await.unwrap_or(0);
                if n == 0 {
                    break;
                }
                bytes.extend_from_slice(&chunk[..n]);
            }
            let head = String::from_utf8_lossy(&bytes[..head_len]).into_owned();
            let bearer = head
                .lines()
                .find_map(|line| {
                    let (key, value) = line.split_once(':')?;
                    key.eq_ignore_ascii_case("authorization").then(|| value.trim().to_owned())
                })
                .unwrap_or_default();
            let body = bytes
                .get(head_len..head_len + body_len)
                .and_then(|b| serde_json::from_slice(b).ok())
                .unwrap_or(Value::Null);
            let request = Seen { line: head.lines().next().unwrap_or("").to_owned(), bearer, body };
            let index = {
                let mut log = log.lock().unwrap();
                log.push(request.clone());
                log.len() - 1
            };
            let (status, answer) = respond(index, &request);
            let answer = answer.to_string();
            let reply = format!(
                "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{answer}",
                answer.len(),
            );
            let _ = stream.write_all(reply.as_bytes()).await;
        }
    });
    (url, seen)
}

/// The hub's answer to a mesh message, as cmux-platform gives it: a send (a read's `control` or
/// a prompt) is queued; the read's answer comes on the sender's wait for its receipt
/// (`GET /v1/mesh/messages/:id?waitSeconds=N`), with `info` as its result.
fn mesh_answer(seen: &Seen, info: &Value) -> (u16, Value) {
    if let Some(rest) = seen.line.strip_prefix("GET /v1/mesh/messages/") {
        let id = rest.split(['?', ' ']).next().unwrap_or_default();
        let result = info.to_string();
        return (
            200,
            json!({"messageId": id, "state": "delivered", "createdAt": 1, "result": result}),
        );
    }
    let id = format!("msg_{}", uuid::Uuid::now_v7().simple());
    (200, json!({"messageId": id, "state": "queued", "createdAt": 1}))
}

const LISTED: &str = "019a5d1e-8f00-7000-8000-0000000000b1";
const DEVICE: &str = "cmm_web_device_credential_for_tests";

/// Daemon A, on the hub at `url`, its own identity `own`, and machine-b's chat `LISTED` in the
/// address book its own heartbeat read.
fn daemon_a(url: &str, own: Arc<DaemonIdentity>) -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "meshRelay": {"url": url, "tokenCommand": ["/nonexistent/must-not-run"]}
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let a = Hub::new(config, store);
    let _ = a.mesh.set(own);
    let hosts = std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]);
    let row = crate::mesh::BookSession {
        name: "own-e2e".into(),
        session_id: LISTED.into(),
        host: "machine-b".into(),
        daemon_id: "inst_b".into(),
        harness: "fake".into(),
        state: "idle".into(),
        last_seen_at: 1,
        ..Default::default()
    };
    a.set_mesh_book(hosts, vec![row]);
    a
}

/// One connection to a daemon, as a browser on its web listener holds it (`Origin::Web`, the
/// listener token proven at the upgrade), or as `origin` says.
struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    fn connect(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, in_rx) = mpsc::channel(16);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(crate::server::serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self { tx, rx, next: 1 }
    }

    /// The reply's result, or its error object.
    async fn request(&mut self, m: &str, params: Value) -> Result<Value, Value> {
        let id = self.next;
        self.next += 1;
        self.tx.send(crate::rpc::Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.rx.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return match value.get("error") {
                    Some(error) => Err(error.clone()),
                    None => Ok(value["result"].clone()),
                };
            }
        }
    }

    async fn read(&mut self) -> Result<Value, Value> {
        self.request(method::MUX_INFO, json!({"sessionId": format!("machine-b/{LISTED}")})).await
    }

    async fn prompt(&mut self) -> Result<Value, Value> {
        let prompt = json!([{"type": "text", "text": "hello from a browser"}]);
        self.request(method::SESSION_PROMPT, json!({"sessionId": LISTED, "prompt": prompt})).await
    }
}

fn reason(error: &Value) -> &str {
    error.pointer("/data/reason").and_then(Value::as_str).unwrap_or_default()
}

/// The invariant `may_read` keeps: a browser with no device of its own reads and prompts nothing
/// through the hub, and nothing it asks is sent with this daemon's identity.
#[tokio::test]
async fn a_web_connection_without_a_device_never_uses_the_daemons_identity() {
    let (url, seen) =
        http_hub(Box::new(|_, s| mesh_answer(s, &json!({"sessionId": LISTED})))).await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));
    let mut web = Client::connect(&a, Origin::Web);
    assert!(web.read().await.is_err(), "a web read with no device was answered");
    assert!(web.prompt().await.is_err(), "a web prompt with no device was sent");
    assert_eq!(own.used(), 0, "a web connection used the daemon's hub identity");
    assert!(seen.lock().unwrap().is_empty(), "the hub was reached with no device credential");
}

/// A browser's own device credential reads and prompts machine-b's chat; the hub sees only that
/// credential, never the daemon's, and the credential is never echoed back.
#[tokio::test]
async fn a_web_device_reads_and_prompts_with_its_own_credential() {
    let info = json!({"sessionId": LISTED, "name": "own-e2e"});
    let (url, seen) = http_hub(Box::new(move |_, s| mesh_answer(s, &info))).await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));

    // Only a web connection presents a device: the app's pane and the unix socket keep the
    // daemon's identity and need none.
    for origin in [Origin::LocalApp, Origin::Local] {
        let mut other = Client::connect(&a, origin);
        let refused = other.request("_acpmux/device_hello", json!({"credential": DEVICE})).await;
        assert!(refused.is_err(), "{origin:?} presented a web device: {refused:?}");
    }

    let mut web = Client::connect(&a, Origin::Web);
    let hello = web.request("_acpmux/device_hello", json!({"credential": DEVICE})).await.unwrap();
    assert!(!hello.to_string().contains(DEVICE), "the credential was echoed: {hello}");
    assert_eq!(hello["auth"], "webDevice", "{hello}");
    // Once per connection: a second device never replaces the first.
    let again =
        web.request("_acpmux/device_hello", json!({"credential": "cmm_another_device"})).await;
    assert!(again.is_err(), "a second device_hello was taken: {again:?}");

    let read = web.read().await.unwrap();
    assert_eq!((read["sessionId"].as_str(), read["via"].as_str()), (Some(LISTED), Some("hub")));
    assert_eq!(read["peer"], "machine-b");
    let sent = web.prompt().await.unwrap();
    assert_eq!(sent["via"], "mesh", "{sent}");

    let seen = seen.lock().unwrap().clone();
    assert!(seen.len() >= 2, "{seen:?}");
    for request in &seen {
        assert_eq!(request.bearer, format!("Bearer {DEVICE}"), "{}", request.line);
    }
    assert!(seen.iter().any(|s| s.body["kind"] == "prompt"), "{seen:?}");
    // The read went as cmux-platform takes it: a `read` control, then the sender's wait on its
    // receipt. Nothing registered the device (no heartbeat, no inbox).
    assert!(seen.iter().any(|s| s.body["op"] == "read"), "{seen:?}");
    assert!(seen.iter().any(|s| s.line.contains("waitSeconds=")), "{seen:?}");
    assert!(
        !seen.iter().any(|s| s.line.contains("/heartbeat") || s.line.contains("/inbox")),
        "{seen:?}"
    );
    assert_eq!(own.used(), 0, "the daemon's own identity was used");

    // Another browser on the same daemon has no device of its own: nothing is shared.
    let mut stranger = Client::connect(&a, Origin::Web);
    assert!(stranger.read().await.is_err());
    assert_eq!(own.used(), 0);
}

/// The hub revokes the device: its next call is answered `device.revoked`, the connection drops
/// the device, and no later call on it reaches the hub or falls back to the daemon's identity.
#[tokio::test]
async fn a_revoked_device_is_dropped() {
    let info = json!({"sessionId": LISTED});
    let (url, seen) = http_hub(Box::new(move |index, s| {
        // The first read's send and its receipt wait; then the hub revokes the device.
        if index < 2 {
            mesh_answer(s, &info)
        } else {
            (401, json!({"code": "machine.revoked", "message": "revoked"}))
        }
    }))
    .await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));
    let mut web = Client::connect(&a, Origin::Web);
    web.request("_acpmux/device_hello", json!({"credential": DEVICE})).await.unwrap();
    web.read().await.unwrap();

    let revoked = web.read().await.unwrap_err();
    assert_eq!(reason(&revoked), "device.revoked", "{revoked}");
    let reached = seen.lock().unwrap().len();
    for _ in 0..2 {
        let again = web.read().await.unwrap_err();
        assert_eq!(reason(&again), "device.revoked", "{again}");
        let prompt = web.prompt().await.unwrap_err();
        assert_eq!(reason(&prompt), "device.revoked", "{prompt}");
    }
    assert_eq!(seen.lock().unwrap().len(), reached, "a revoked device reached the hub again");
    // Nor may the connection present another device after the revoke.
    let after = web.request("_acpmux/device_hello", json!({"credential": "cmm_next"})).await;
    assert!(after.is_err(), "{after:?}");
    assert_eq!(own.used(), 0, "the daemon's own identity was used after the revoke");
}

/// A credential the hub does not know is refused by the hub (cmux-platform: a junk bearer is 401
/// `mesh.unauthorized`, an unknown `cmm_` one 401 `machine.revoked`); the browser learns
/// `device.unauthorized` or `device.revoked`, the device is dropped after one call, and nothing
/// falls back to the daemon's identity.
#[tokio::test]
async fn a_strangers_credential_is_refused() {
    for (code, expected, stranger) in [
        ("mesh.unauthorized", "device.unauthorized", "a-junk-bearer-for-tests"),
        ("machine.revoked", "device.revoked", "cmm_a_strangers_credential"),
    ] {
        let (url, seen) =
            http_hub(Box::new(move |_, _| (401, json!({"code": code, "message": "no"})))).await;
        let own = Arc::new(DaemonIdentity::default());
        let a = daemon_a(&url, Arc::clone(&own));
        let mut web = Client::connect(&a, Origin::Web);
        web.request("_acpmux/device_hello", json!({"credential": stranger})).await.unwrap();
        for refused in [web.read().await.unwrap_err(), web.prompt().await.unwrap_err()] {
            assert_eq!(reason(&refused), expected, "{refused}");
            assert!(!refused.to_string().contains(stranger), "{refused}");
        }
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "the hub was asked again after it refused: {seen:?}");
        assert!(seen.iter().all(|s| s.bearer == format!("Bearer {stranger}")), "{seen:?}");
        assert_eq!(own.used(), 0, "the daemon's own identity was used as a fallback");
    }
}

/// A browser's device client registers nothing at the hub: no heartbeat (so no session rows) and
/// no inbox or ack, refused before any request (cmux-platform answers each 403 for a web caller).
#[tokio::test]
async fn a_web_devices_hub_client_never_registers() {
    let (url, seen) = http_hub(Box::new(|_, _| (200, json!({})))).await;
    let hub =
        crate::mesh_http::HttpHub::with_credential(url, zeroize::Zeroizing::new(DEVICE.into()))
            .unwrap();
    let inbox = hub.inbox(Duration::from_secs(1), 1).await.unwrap_err();
    assert_eq!(inbox.code.as_deref(), Some("mesh.forbidden"), "{inbox:?}");
    let ack = hub.ack("msg_1", &Ack::refused("x")).await.unwrap_err();
    assert_eq!(ack.code.as_deref(), Some("mesh.forbidden"), "{ack:?}");
    assert!(seen.lock().unwrap().is_empty(), "a device client called the hub");
}

/// `_acpmux/device_enroll` mints a join token with the person's access token and redeems it as a
/// `web` machine with the browser's public key, as a new machine joins; it returns the device
/// credential to that connection alone and writes no join record.
#[tokio::test]
async fn a_web_device_enrolls_through_the_join_path() {
    let key = base64::engine::general_purpose::STANDARD.encode([7u8; 32]);
    let (url, seen) = http_hub(Box::new(|_, s| {
        if s.line.contains("/v1/machines/join-tokens/redeem") {
            // cmux-platform's web redeem answer: the hub mints the device's credential.
            (
                200,
                json!({"credential": "cmm_minted_by_the_hub", "machineId": "mch_web_1",
                       "joinTokenId": "join_1", "teamId": "team_1",
                       "wgPublicKey": s.body["wgPublicKey"],
                       "expiresAt": "2027-11-17T12:00:00.000Z", "userId": "user_1"}),
            )
        } else if s.line.contains("/v1/machines/join-tokens") {
            (
                200,
                json!({"joinTokenId": "join_1", "token": "cmj_minted_for_web", "teamId": "team_1",
                       "expiresAt": "2026-11-17T12:10:00.000Z"}),
            )
        } else {
            (404, json!({}))
        }
    }))
    .await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));
    let mut web = Client::connect(&a, Origin::Web);
    let access = "person-access-token-for-tests";
    let enrolled = web
        .request("_acpmux/device_enroll", json!({"accessToken": access, "publicKey": key}))
        .await
        .unwrap();
    assert_eq!(enrolled["credential"], "cmm_minted_by_the_hub", "{enrolled}");
    assert_eq!(
        (enrolled["machineId"].as_str(), enrolled["userId"].as_str()),
        (Some("mch_web_1"), Some("user_1"))
    );
    assert!(!enrolled.to_string().contains(access), "{enrolled}");
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 2, "{seen:?}");
    assert_eq!(seen[0].bearer, format!("Bearer {access}"));
    let redeem = &seen[1].body;
    assert_eq!(redeem["platform"], "web", "{redeem}");
    assert_eq!(redeem["wgPublicKey"], key.as_str(), "{redeem}");
    assert_eq!(redeem["token"], "cmj_minted_for_web", "{redeem}");
    assert!(redeem["hostname"].as_str().is_some_and(|h| !h.is_empty()), "{redeem}");
    // The hub mints the credential; no client proposal and no name go with a web redeem.
    assert!(redeem.get("proposedCredential").is_none() && redeem.get("name").is_none(), "{redeem}");
    assert_eq!(own.used(), 0);
    // A malformed key is refused before the hub is asked.
    let bad = web
        .request("_acpmux/device_enroll", json!({"accessToken": access, "publicKey": "nope"}))
        .await;
    assert!(bad.is_err(), "{bad:?}");
}

/// The fake hub's half of a bound device (RFD 0083; cmux-platform verifies the real ECDSA P-256
/// signature): a challenge issues a fresh nonce, a session spends it and answers only the
/// signature `GOOD_PROOF` over a nonce it issued and never spent; then only the session credential
/// reads. The raw device credential is refused everywhere else, as the hub refuses a bound one.
const GOOD_PROOF: &str = "the-browser-keys-signature-for-tests";
const SESSION: &str = "cmm_session_credential_for_tests";

fn bound_hub() -> Respond {
    let issued = Arc::new(Mutex::new(Vec::<String>::new()));
    let info = json!({"sessionId": LISTED, "name": "own-e2e"});
    Box::new(move |index, s| {
        let refused = (401, json!({"code": "device.proof_refused", "message": "no"}));
        if s.line.starts_with("POST /v1/machines/credentials/self/challenge ") {
            if s.bearer != format!("Bearer {DEVICE}") {
                return (401, json!({"code": "machine.revoked", "message": "no"}));
            }
            let nonce = format!("nonce-{index}");
            issued.lock().unwrap().push(nonce.clone());
            return (200, json!({"machineId": "mch_web_1", "nonce": nonce, "expiresAt": "x"}));
        }
        if s.line.starts_with("POST /v1/machines/credentials/self/session ") {
            let nonce = s.body["nonce"].as_str().unwrap_or_default().to_owned();
            let mut issued = issued.lock().unwrap();
            let Some(at) = issued.iter().position(|n| *n == nonce) else { return refused };
            issued.remove(at); // spent, signature valid or not
            let binding = s.body["binding"].as_str().unwrap_or_default();
            if s.body["signature"] != GOOD_PROOF || !binding.starts_with("acpmux:") {
                return refused;
            }
            return (
                200,
                json!({"credential": SESSION, "machineId": "mch_web_1", "binding": binding,
                       "expiresAt": "x"}),
            );
        }
        if s.bearer != format!("Bearer {SESSION}") {
            return (401, json!({"code": "machine.revoked", "message": "bound credential"}));
        }
        mesh_answer(s, &info)
    })
}

/// A bound device proves its key on the connection: the challenge names this connection's binding,
/// the valid signature is traded for a session credential, and every read and prompt goes with that
/// credential alone, never the raw one.
#[tokio::test]
async fn a_bound_device_with_a_valid_proof_is_admitted() {
    let (url, seen) = http_hub(bound_hub()).await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));
    let mut web = Client::connect(&a, Origin::Web);
    let challenge =
        web.request("_acpmux/device_challenge", json!({"credential": DEVICE})).await.unwrap();
    assert_eq!(challenge["machineId"], "mch_web_1", "{challenge}");
    let binding = challenge["binding"].as_str().unwrap().to_owned();
    assert!(binding.starts_with("acpmux:"), "{challenge}");
    let hello = web
        .request(
            "_acpmux/device_hello",
            json!({"credential": DEVICE, "nonce": challenge["nonce"], "signature": GOOD_PROOF}),
        )
        .await
        .unwrap();
    assert_eq!(hello["auth"], "webDevice", "{hello}");
    assert!(!hello.to_string().contains(SESSION), "the session credential was echoed: {hello}");
    web.read().await.unwrap();
    assert_eq!(web.prompt().await.unwrap()["via"], "mesh");

    let seen = seen.lock().unwrap().clone();
    let session = seen.iter().find(|s| s.line.contains("/self/session")).unwrap();
    assert_eq!(session.body["binding"], binding.as_str(), "{session:?}");
    let mesh: Vec<_> = seen.iter().filter(|s| s.line.contains("/v1/mesh/")).collect();
    assert!(mesh.len() >= 2, "{seen:?}");
    assert!(mesh.iter().all(|s| s.bearer == format!("Bearer {SESSION}")), "{mesh:?}");
    assert_eq!(own.used(), 0);

    // Another connection's binding differs: a proof is good for the connection it names.
    let mut other = Client::connect(&a, Origin::Web);
    let theirs = other.request("_acpmux/device_challenge", json!({"credential": DEVICE})).await;
    assert_ne!(theirs.unwrap()["binding"], binding.as_str());
}

/// A stolen credential without the key: the thief gets a nonce, but no signature it can make buys
/// a session, the connection holds no device, and the raw credential reads nothing.
#[tokio::test]
async fn a_stolen_bound_credential_without_the_key_is_refused() {
    let (url, seen) = http_hub(bound_hub()).await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));
    let mut thief = Client::connect(&a, Origin::Web);
    let challenge =
        thief.request("_acpmux/device_challenge", json!({"credential": DEVICE})).await.unwrap();
    let forged = json!({"credential": DEVICE, "nonce": challenge["nonce"], "signature": "forged"});
    let refused = thief.request("_acpmux/device_hello", forged).await.unwrap_err();
    assert_eq!(reason(&refused), "device.proof_refused", "{refused}");
    assert!(!refused.to_string().contains(DEVICE), "{refused}");
    assert!(thief.read().await.is_err(), "a refused proof left a device on the connection");
    assert!(thief.prompt().await.is_err());

    // The bearer hello (no proof) holds the raw credential, which the hub refuses for a bound
    // device: the first call says so and the device is dropped.
    let mut bearer = Client::connect(&a, Origin::Web);
    bearer.request("_acpmux/device_hello", json!({"credential": DEVICE})).await.unwrap();
    assert_eq!(reason(&bearer.read().await.unwrap_err()), "device.revoked");
    assert!(
        !seen.lock().unwrap().iter().any(|s| s.bearer == format!("Bearer {SESSION}")),
        "a session was issued without the key"
    );
    assert_eq!(own.used(), 0);
}

/// A replayed proof (the same nonce and signature, on a new connection) is refused: the hub spent
/// the nonce on its first use.
#[tokio::test]
async fn a_replayed_device_proof_is_refused() {
    let (url, _seen) = http_hub(bound_hub()).await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));
    let mut web = Client::connect(&a, Origin::Web);
    let challenge =
        web.request("_acpmux/device_challenge", json!({"credential": DEVICE})).await.unwrap();
    let proof = json!({"credential": DEVICE, "nonce": challenge["nonce"], "signature": GOOD_PROOF});
    web.request("_acpmux/device_hello", proof.clone()).await.unwrap();

    let mut replay = Client::connect(&a, Origin::Web);
    let refused = replay.request("_acpmux/device_hello", proof).await.unwrap_err();
    assert_eq!(reason(&refused), "device.proof_refused", "{refused}");
    assert!(replay.read().await.is_err());
    // A challenge or a proof is the web listener's alone.
    let mut local = Client::connect(&a, Origin::LocalApp);
    let asked = local.request("_acpmux/device_challenge", json!({"credential": DEVICE})).await;
    assert!(asked.is_err(), "{asked:?}");
}

/// Enrollment with a device key sends it to the hub's redeem as `deviceKey`; a key that is not a
/// raw P-256 point is refused before the hub is asked.
#[tokio::test]
async fn a_web_device_enrolls_with_its_device_key() {
    let key = base64::engine::general_purpose::STANDARD.encode([7u8; 32]);
    let mut point = [9u8; 65];
    point[0] = 4;
    let device_key = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(point);
    let (url, seen) = http_hub(Box::new(|_, s| {
        if s.line.contains("/v1/machines/join-tokens/redeem") {
            (
                200,
                json!({"credential": "cmm_minted_by_the_hub", "machineId": "mch_web_1",
                       "joinTokenId": "join_1", "teamId": "team_1",
                       "wgPublicKey": s.body["wgPublicKey"],
                       "expiresAt": "2027-11-17T12:00:00.000Z", "userId": "user_1"}),
            )
        } else {
            (
                200,
                json!({"joinTokenId": "join_1", "token": "cmj_minted_for_web", "teamId": "team_1",
                       "expiresAt": "2026-11-17T12:10:00.000Z"}),
            )
        }
    }))
    .await;
    let a = daemon_a(&url, Arc::new(DaemonIdentity::default()));
    let mut web = Client::connect(&a, Origin::Web);
    let access = "person-access-token-for-tests";
    for bad in ["nope", &base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([4u8; 33])] {
        let refused = web
            .request(
                "_acpmux/device_enroll",
                json!({"accessToken": access, "publicKey": key, "deviceKey": bad}),
            )
            .await;
        assert!(refused.is_err(), "{bad}: {refused:?}");
    }
    assert!(seen.lock().unwrap().is_empty(), "a bad device key reached the hub");
    web.request(
        "_acpmux/device_enroll",
        json!({"accessToken": access, "publicKey": key, "deviceKey": device_key}),
    )
    .await
    .unwrap();
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen[1].body["deviceKey"], device_key.as_str(), "{:?}", seen[1]);
}

/// A prompt's `mesh:` delivery id goes back to the browser, and the browser may ask its status.
/// That status read goes with the device's credential alone: never with this daemon's identity,
/// neither after the hub revoked the device nor for a web connection that has no device.
#[tokio::test]
async fn a_web_devices_send_status_uses_its_own_credential_and_ends_with_the_revoke() {
    let info = json!({"sessionId": LISTED});
    let (url, seen) = http_hub(Box::new(move |index, s| {
        // The prompt and one status read go through; then the hub revokes the device.
        if index < 2 {
            mesh_answer(s, &info)
        } else {
            (401, json!({"code": "machine.revoked", "message": "revoked"}))
        }
    }))
    .await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));
    let mut web = Client::connect(&a, Origin::Web);
    web.request("_acpmux/device_hello", json!({"credential": DEVICE})).await.unwrap();
    let sent = web.prompt().await.unwrap();
    let id = sent["deliveryId"].as_str().unwrap().to_owned();
    assert!(id.starts_with("mesh:"), "{sent}");
    let status = json!({"deliveryId": id});

    web.request(method::MUX_SEND_STATUS, status.clone()).await.unwrap();
    assert_eq!(own.used(), 0, "a web device's status read used the daemon's identity");
    assert!(
        seen.lock().unwrap().iter().all(|s| s.bearer == format!("Bearer {DEVICE}")),
        "{:?}",
        seen.lock().unwrap()
    );

    let revoked = web.request(method::MUX_SEND_STATUS, status.clone()).await.unwrap_err();
    assert_eq!(reason(&revoked), "device.revoked", "{revoked}");
    let reached = seen.lock().unwrap().len();
    let again = web.request(method::MUX_SEND_STATUS, status.clone()).await.unwrap_err();
    assert_eq!(reason(&again), "device.revoked", "{again}");
    assert_eq!(seen.lock().unwrap().len(), reached, "a revoked device reached the hub again");
    assert_eq!(own.used(), 0, "the daemon's identity answered a revoked device's status read");

    // A web connection with no device asks the same id: nothing goes with the daemon's identity.
    let mut stranger = Client::connect(&a, Origin::Web);
    assert!(stranger.request(method::MUX_SEND_STATUS, status).await.is_err());
    assert_eq!(own.used(), 0, "a web connection with no device used the daemon's identity");
}

/// Which hub call a [`Flaky`] failure stands in for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Call {
    Send,
    Answer,
}

/// The hub as gcp-codex-swarm-07 saw it on 2026-11-19..20: the failures queued here come first,
/// one per call of their kind, then [`Loopback`] answers. `calls` counts every call that reached it.
struct Flaky {
    inner: Loopback,
    failures: Mutex<std::collections::VecDeque<(Call, HubError)>>,
    calls: Mutex<Vec<Call>>,
}

impl Flaky {
    fn new(inner: Loopback, failures: Vec<(Call, HubError)>) -> Self {
        Self { inner, failures: Mutex::new(failures.into()), calls: Mutex::default() }
    }

    fn fail(&self, call: Call) -> Option<HubError> {
        self.calls.lock().unwrap().push(call);
        let mut failures = self.failures.lock().unwrap();
        if failures.front().is_some_and(|(c, _)| *c == call) {
            return failures.pop_front().map(|(_, e)| e);
        }
        None
    }
}

/// A hub answer with `status` and `code`, as `mesh_http::answer` makes it.
fn hub_status(status: u16, code: &str) -> HubError {
    let mut e = HubError::refused(format!("the hub answered {status} {code}"));
    e.refused = !(status == 408 || status == 429 || status >= 500);
    e.status = Some(status);
    e.code = Some(code.into());
    e
}

impl MeshHub for Flaky {
    fn inbox(&self, wait: Duration, max: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        self.inner.inbox(wait, max)
    }

    fn ack<'a>(&'a self, id: &'a str, ack: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        self.inner.ack(id, ack)
    }

    fn heartbeat<'a>(
        &'a self,
        beat: &'a crate::mesh::Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        self.inner.heartbeat(beat)
    }

    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        match self.fail(Call::Send) {
            Some(e) => Box::pin(async move { Err(e) }),
            None => self.inner.send(m),
        }
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.inner.receipt(id)
    }

    fn answer<'a>(
        &'a self,
        id: &'a str,
        wait: Duration,
    ) -> BoxFuture<'a, Result<Receipt, HubError>> {
        match self.fail(Call::Answer) {
            Some(e) => Box::pin(async move { Err(e) }),
            None => self.inner.answer(id, wait),
        }
    }
}

/// `acpmux last HOST/NAME` through a hub that drops a connection, answers 503 and lets go of the
/// read's receipt (404 `mesh.not_found`) still reads the session: each blip is tried again, and
/// the read whose receipt is gone is sent afresh.
#[tokio::test]
async fn a_read_through_a_hub_that_blips_still_answers() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "own-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    let dir = tempfile::tempdir().unwrap();
    let hub = Flaky::new(
        Loopback::new(&b, dir.path(), "person-1"),
        vec![
            (Call::Send, HubError::unavailable("the hub: error sending request")),
            (Call::Answer, hub_status(503, "mesh.unavailable")),
            (Call::Answer, hub_status(404, "mesh.not_found")),
        ],
    );
    let info = read(&hub, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap();
    assert_eq!(info["sessionId"].as_str(), Some(session.as_str()), "{info}");
    assert_eq!(info["via"], "hub");
    // Send (dropped), send, answer (503), answer (404: gone), send again, answer.
    assert_eq!(
        *hub.calls.lock().unwrap(),
        [Call::Send, Call::Send, Call::Answer, Call::Answer, Call::Send, Call::Answer]
    );
}

/// A hub that stays down is tried a bounded number of times, and the error names the only route
/// this machine has to the host and the one that does not need the hub. A refusal is not retried.
#[tokio::test]
async fn a_hub_that_stays_down_fails_bounded_and_names_the_direct_route() {
    let b = machine_b();
    let dir = tempfile::tempdir().unwrap();
    let down: Vec<_> = (0..crate::mesh_retry::ATTEMPTS)
        .map(|_| (Call::Send, hub_status(503, "mesh.unavailable")))
        .collect();
    let hub = Flaky::new(Loopback::new(&b, dir.path(), "person-1"), down);
    let e = read(&hub, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert_eq!(hub.calls.lock().unwrap().len(), crate::mesh_retry::ATTEMPTS);
    assert!(e.message.contains("the hub answered 503 mesh.unavailable"), "{e:?}");
    assert!(e.message.contains("only through the mesh hub"), "{e:?}");
    assert!(e.message.contains("`acpmux machine add machine-b`"), "{e:?}");
    let data = e.data.unwrap();
    assert_eq!((&data["reason"], &data["route"]), (&json!("mesh.unavailable"), &json!("hub")));

    let refused = Flaky::new(
        Loopback::new(&b, dir.path(), "person-1"),
        vec![(Call::Send, hub_status(403, "mesh.forbidden"))],
    );
    let e = read(&refused, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert_eq!(refused.calls.lock().unwrap().len(), 1);
    assert_eq!(e.data.unwrap()["retryable"], json!(false));
}

/// How long the HTTP client waits on one hub call before it gives up (`mesh_http`'s `CALL_WAIT`).
const CLIENT_WAIT: Duration = Duration::from_secs(30);

/// A receipt the hub has taken and not yet delivered.
fn queued() -> Receipt {
    serde_json::from_value(json!({"messageId": "msg_silent", "state": "queued"})).unwrap()
}

/// A hub that takes a connection and never answers it: each call hangs for the client's whole
/// wait, then fails as no answer. With `takes_send`, the send is taken at once and only the
/// receipt's long-poll hangs.
struct Silent {
    takes_send: bool,
    calls: Mutex<Vec<Call>>,
}

fn timed_out() -> HubError {
    HubError::unavailable("the hub: error sending request: operation timed out")
}

impl MeshHub for Silent {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        panic!("a read never leases")
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        panic!("a read never acks")
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        panic!("a read never heartbeats")
    }

    fn send<'a>(&'a self, _: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.calls.lock().unwrap().push(Call::Send);
        let takes = self.takes_send;
        Box::pin(async move {
            if takes {
                return Ok(queued());
            }
            tokio::time::sleep(CLIENT_WAIT).await;
            Err(timed_out())
        })
    }

    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        panic!("a read waits on its answer, not the receipt")
    }

    fn answer<'a>(&'a self, _: &'a str, _: Duration) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.calls.lock().unwrap().push(Call::Answer);
        Box::pin(async {
            tokio::time::sleep(CLIENT_WAIT).await;
            Err(timed_out())
        })
    }
}

/// A read through a hub that never answers ends within `READ_WAIT`, whether the send or the
/// answer is what hangs: no try outlives the read's wait, and none starts after it. Before,
/// three tries of a 30 s call each, plus the resend, took a read past four minutes.
#[tokio::test(start_paused = true)]
async fn a_hub_that_never_answers_ends_the_read_within_its_wait() {
    for takes_send in [false, true] {
        let hub = Silent { takes_send, calls: Mutex::default() };
        let started = tokio::time::Instant::now();
        let e = read(&hub, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
        let took = started.elapsed();
        let calls = hub.calls.lock().unwrap().clone();
        assert!(
            took <= READ_WAIT + Duration::from_secs(1),
            "takes_send {takes_send}: the read took {took:?} ({calls:?})"
        );
        assert_eq!(e.data.unwrap()["reason"], json!("mesh.read_unanswered"), "{calls:?}");
    }
}

/// A hub that lets go of the read's receipt (404 `mesh.not_found`) only as the read's wait runs
/// out.
struct GoneLate {
    started: tokio::time::Instant,
    calls: Mutex<Vec<Call>>,
}

impl MeshHub for GoneLate {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        panic!("a read never leases")
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        panic!("a read never acks")
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        panic!("a read never heartbeats")
    }

    fn send<'a>(&'a self, _: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.calls.lock().unwrap().push(Call::Send);
        Box::pin(async { Ok(queued()) })
    }

    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        panic!("a read waits on its answer, not the receipt")
    }

    fn answer<'a>(&'a self, _: &'a str, _: Duration) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.calls.lock().unwrap().push(Call::Answer);
        let gone = self.started + READ_WAIT;
        Box::pin(async move {
            tokio::time::sleep_until(gone).await;
            Err(hub_status(404, "mesh.not_found"))
        })
    }
}

/// A receipt the hub lets go of once the read's wait has run out is not sent again: the read
/// fails as unanswered with the one send it made, never a second read no one waits for.
#[tokio::test(start_paused = true)]
async fn a_receipt_gone_after_the_wait_is_not_sent_again() {
    let hub = GoneLate { started: tokio::time::Instant::now(), calls: Mutex::default() };
    let e = read(&hub, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert_eq!(*hub.calls.lock().unwrap(), [Call::Send, Call::Answer]);
    assert_eq!(e.data.unwrap()["reason"], json!("mesh.read_unanswered"));
}

/// A machine only the hub reaches answers a health read of itself, as a direct peer's link
/// reads it (`peer_health.rs`), bounded to one small message. The hub takes a read only when it
/// names a session, so the read goes through one the hub lists there; the machine answers its
/// health before it looks that session up. A read of the machine alone is the hub's
/// `mesh.invalid` (every machine only the hub reaches read "resources unknown", 2026-11-25).
#[tokio::test]
async fn a_machine_answers_its_health_through_the_hub_via_any_of_its_sessions() {
    let b = machine_b();
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");
    let health = host_health(&hub, "machine-b", Some("any-session-of-b")).await.unwrap();
    assert!(health.is_object(), "{health}");
    assert!(health.get("unsupported").is_none(), "{health}");
    assert!(health.to_string().len() <= HEALTH_BYTES);
    // The machine alone: refused by the hub, never sent on.
    let alone = host_health(&hub, "machine-b", None).await.unwrap_err();
    assert!(alone.message.contains("names one session"), "{alone:?}");
    // Another person is refused by B itself.
    let other = Loopback::new(&b, dir.path(), "person-2");
    assert!(host_health(&other, "machine-b", Some("any-session-of-b")).await.is_err());
}

/// Old against new: a build before the health read refuses it as it refuses any method it does
/// not read (`mesh.read_unsupported`), which the asker keeps as unsupported, never an error.
#[tokio::test]
async fn an_old_machine_refuses_the_health_read_and_reads_as_unsupported() {
    let b = machine_b();
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");
    // What a build without `_acpmux/host_health` answers: the refusal of a method it lacks.
    let old = read(&hub, "machine-b", "own-e2e", "_acpmux/host_health_unknown", &json!({})).await;
    let refused = old.unwrap_err();
    assert!(refused.message.starts_with("mesh.read_unsupported"), "{refused:?}");
    assert_eq!(health_of(Err(refused)).unwrap(), json!({"unsupported": true}));
    // A new machine's answer, an answer with no reading, and one over the bound.
    assert_eq!(health_of(Ok(r#"{"health":{"cpus":4}}"#.into())).unwrap(), json!({"cpus": 4}));
    assert!(health_of(Ok(r#"{"other":1}"#.into())).is_err());
    assert!(health_of(Ok("not json".into())).is_err());
    let big = json!({"health": {"x": "y".repeat(HEALTH_BYTES)}}).to_string();
    assert!(health_of(Ok(big)).is_err());
    // Any other failure stays a failure.
    assert!(health_of(Err(RpcError::internal("down"))).is_err());
    // The body is version 1, so an old build reaches its method check.
    let body: Value = serde_json::from_str(&health_body()).unwrap();
    assert_eq!(body["version"], 1);
    assert_eq!(body["method"], HOST_HEALTH);
}

/// A receiver that took the read and is slow but working: it renews its lease every 20 s, each
/// long-poll on the receipt answers with the renewed lease, and the answer comes after 2 min.
/// With `works: false` it took the read and then nothing moves.
struct SlowWorker {
    started: tokio::time::Instant,
    works: bool,
}

impl MeshHub for SlowWorker {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        panic!("a read never leases")
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        panic!("a read never acks")
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        panic!("a read never heartbeats")
    }

    fn send<'a>(&'a self, _: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { Ok(queued()) })
    }

    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        panic!("a read waits on its answer, not the receipt")
    }

    fn answer<'a>(
        &'a self,
        _: &'a str,
        wait: Duration,
    ) -> BoxFuture<'a, Result<Receipt, HubError>> {
        let started = self.started;
        let works = self.works;
        Box::pin(async move {
            const RENEW: Duration = Duration::from_secs(20);
            const DONE: Duration = Duration::from_secs(120);
            let now = tokio::time::Instant::now();
            let at = now.saturating_duration_since(started);
            if !works {
                // Leased once, then silent: every long-poll runs out on the same lease.
                tokio::time::sleep(wait).await;
                return Ok(serde_json::from_value(json!({
                    "messageId": "msg_silent", "state": "leased", "leasedUntil": 1
                }))
                .unwrap());
            }
            if at >= DONE {
                return Ok(serde_json::from_value(json!({
                    "messageId": "msg_silent", "state": "delivered", "createdAt": 1,
                    "result": json!({"ok": true}).to_string()
                }))
                .unwrap());
            }
            // The next renewal, or the long-poll's own end, whichever is first.
            let renewals = at.as_secs() / RENEW.as_secs() + 1;
            let next = started + RENEW * renewals as u32;
            if next <= now + wait {
                tokio::time::sleep_until(next).await;
                return Ok(serde_json::from_value(json!({
                    "messageId": "msg_silent", "state": "leased", "leasedUntil": renewals
                }))
                .unwrap());
            }
            tokio::time::sleep(wait).await;
            Ok(queued())
        })
    }
}

/// Leo, 2026-11-24: "if it's making good progress, it shiukd be allowed to keep going?" A read
/// whose receiver keeps renewing its lease gets its answer after 2 min; before, the read gave
/// up at 50 s from its start as unanswered.
#[tokio::test(start_paused = true)]
async fn a_read_whose_receiver_keeps_working_is_not_cut_off() {
    let hub = SlowWorker { started: tokio::time::Instant::now(), works: true };
    let started = tokio::time::Instant::now();
    let reply = read(&hub, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await;
    let reply = reply.expect("the answer after 2 min of steady progress");
    assert_eq!(reply["ok"], json!(true));
    assert!(started.elapsed() >= Duration::from_secs(120), "{:?}", started.elapsed());
}

/// A receiver that took the read and then goes silent is still let go at `READ_WAIT` of silence.
#[tokio::test(start_paused = true)]
async fn a_read_whose_receiver_goes_silent_ends_at_the_silence_bound() {
    let hub = SlowWorker { started: tokio::time::Instant::now(), works: false };
    let started = tokio::time::Instant::now();
    let e = read(&hub, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
    let took = started.elapsed();
    assert_eq!(e.data.unwrap()["reason"], json!("mesh.read_unanswered"));
    // The lease it took (at the first long-poll's end) was the last progress.
    assert!(took <= ANSWER_WAIT + READ_WAIT + Duration::from_secs(1), "{took:?}");
}

fn rss_kib() -> u64 {
    let s = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    s.lines()
        .find_map(|l| l.strip_prefix("VmRSS:"))
        .and_then(|v| v.split_whitespace().next()?.parse().ok())
        .unwrap_or(0)
}

/// Where a hub-only daemon's memory goes per mesh read (acpmux-memory-growth): RSS after N of
/// each step of a health read.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "diagnostic"]
async fn diagnose_per_read_memory() {
    const N: usize = 1500;
    let b = machine_b();
    let mut report = vec![];
    let base = rss_kib();
    for _ in 0..N {
        let _ = health_answer(&b).await;
    }
    report.push(("health_answer", rss_kib() - base));
    let base = rss_kib();
    for _ in 0..N {
        let _ = crate::server::peer_status::host_health_with(&b, Origin::Peer, None).await;
    }
    report.push(("host_health_with", rss_kib() - base));
    let base = rss_kib();
    for _ in 0..N {
        let (tx, mut rx) = super::super::relay_connection(&b);
        let init = json!({"protocolVersion": 1, "clientCapabilities": {}});
        super::super::rpc_call(&tx, &mut rx, 1, method::INITIALIZE, init).await.ok();
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    report.push(("relay_conn_initialize", rss_kib() - base));
    report.push(("live_after_init", super::super::queue_gauge::live().len() as u64));
    let base = rss_kib();
    for _ in 0..N {
        let (tx, mut rx) = super::super::relay_connection(&b);
        let init = json!({"protocolVersion": 1, "clientCapabilities": {}});
        super::super::rpc_call(&tx, &mut rx, 1, method::INITIALIZE, init).await.ok();
        let _ = super::super::rpc_call(&tx, &mut rx, 2, "_acpmux/status", json!({})).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    report.push(("relay_conn_status", rss_kib() - base));
    report.push(("live_after_status", super::super::queue_gauge::live().len() as u64));
    let meta = json!({"acpmux": {"harness": "fake", "name": "own-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    call(
        &b,
        method::SESSION_PROMPT,
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "pong"}]}),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");
    let attach =
        json!({"sessionId": format!("machine-b/{session}"), "limit": 200, "maxBytes": 1 << 20});
    let page =
        json!({"limit": 5000, "kinds": ["transcript"], "maxBytes": 4 << 20, "beforeSeq": u64::MAX});
    for (label, m, params) in [
        ("sess_info", method::MUX_INFO, json!({})),
        ("sess_attach", method::MUX_ATTACH, attach),
        ("sess_events", method::MUX_EVENTS, page),
    ] {
        let base = rss_kib();
        for _ in 0..300 {
            read(&hub, "machine-b", &session, m, &params).await.unwrap();
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
        report.push((label, rss_kib() - base));
        report.push(("live", super::super::queue_gauge::live().len() as u64));
    }
    eprintln!("RSS_GROWTH_KIB over {N}: {report:?}");
}

/// cmuxterm-hq#15806: `acpmux last HOST/NAME` read the turn back page by page, each page at most
/// 40 KiB through the hub and its own round trip, so a coordinator's long turn ran past the 50 s
/// a read waits. `_acpmux/last` builds the replies where the log is: one round trip, the same
/// reply as the pages give.
#[tokio::test]
async fn last_reads_a_long_turns_reply_through_the_hub_in_one_round_trip() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "long-turn"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    // One reply of 3000 chunks: the pages read back to its start to know it is whole.
    call(
        &b,
        method::SESSION_PROMPT,
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "chunks: 3000"}]}),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let a = machine_b();
    let loopback = Arc::new(Loopback::new(&b, dir.path(), "person-1"));
    let mesh: Arc<dyn MeshHub> = loopback.clone();
    let _ = a.mesh.set(mesh);
    let asks = || loopback.asks.load(std::sync::atomic::Ordering::SeqCst);
    let key = format!("machine-b/{session}");

    // Before: the pages `acpmux last` read from a daemon without `_acpmux/last`.
    let mut pages = crate::cli::last_reply::Pages::new(1);
    while let Some(query) = pages.next_query(&key) {
        pages.take(&call(&a, method::MUX_EVENTS, query).await);
    }
    let paged = pages.replies();
    let paged_asks = asks();
    assert_eq!(paged.len(), 1);
    assert!(paged[0].starts_with("w0 "), "{:?}", paged[0].get(..40));
    assert!(paged[0].trim_end().ends_with("w2999"), "the paged reply is whole");

    // After: one `_acpmux/last`.
    let last = call(&a, method::MUX_LAST, json!({"sessionId": key, "count": 1})).await;
    let last_asks = asks() - paged_asks;
    eprintln!("hub round trips for last: paged {paged_asks}, _acpmux/last {last_asks}");
    assert_eq!(last_asks, 1, "_acpmux/last took {last_asks} round trips");
    assert!(paged_asks > 3, "the long turn paged in {paged_asks} round trips");
    assert_eq!(last["replies"], json!(paged), "{last}");
    assert_eq!(last["truncated"], json!(false));
    assert_eq!((last["peer"].as_str(), last["via"].as_str()), (Some("machine-b"), Some("hub")));
}

/// An `_acpmux/last` answer fits one hub message whatever its replies hold: the newest reply
/// keeps the most, each older one at least its start.
#[test]
fn last_replies_fit_one_hub_message() {
    use crate::server::requests::last_fit_for_test as fit;
    let replies = vec!["a".repeat(30_000), "b".repeat(30_000), "c".repeat(60_000)];
    let (kept, truncated) = fit(replies, 48 * 1024);
    assert!(truncated);
    let total: usize = kept.iter().map(String::len).sum();
    assert!(total <= 48 * 1024 + 2 * 3, "{total}");
    assert!(kept[0].len() >= 1022 && kept[1].len() >= 1022, "older replies keep their start");
    assert!(kept[2].starts_with("ccc") && kept[2].ends_with('…'));
    let (whole, cut) = fit(vec!["short".into(), "reply".into()], 48 * 1024);
    assert_eq!((whole, cut), (vec!["short".to_owned(), "reply".to_owned()], false));
}

#[test]
fn last_replies_fit_escaped_text_and_fifty_previews() {
    use crate::server::requests::last_fit_for_test as fit;
    let controls: String = (0..32).filter_map(char::from_u32).collect();
    for text in [controls, "\"\\\n\ré🦀".into(), "a".into()] {
        for count in [1, 3, 50] {
            let (kept, truncated) = fit(vec![text.repeat(60_000); count], 48 * 1024);
            assert!(truncated);
            assert_eq!(kept.len(), count);
            assert!(kept.iter().all(|reply| reply.ends_with('…')));
            let bytes = serde_json::to_vec(&kept).unwrap().len();
            assert!(bytes <= 48 * 1024, "{count} replies serialized to {bytes} bytes");
        }
    }
}

/// The issue's duress shape: 50,000 transcript records and a 400 KB detail. An escaped
/// answer used to grow beyond the text-only cap and take seven additional hub asks.
#[tokio::test]
async fn last_and_info_stay_two_asks_with_fifty_thousand_records() {
    let b = machine_b();
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [],
            "_meta": {"acpmux": {"harness": "fake", "name": "last-duress"}}}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap();
    let remote = b.resolve(session).unwrap();
    for i in 0..50_000 {
        b.append(&remote, "mux", "user_message", json!({"text": format!("old prompt {i}")}));
    }
    let commands: Vec<Value> = (0..3000)
        .map(|i| json!({"name": format!("command-{i}"), "description": "d".repeat(110)}))
        .collect();
    remote.set_available_commands_for_test(json!(commands));
    let escaped = "\u{0}".repeat(48 * 1024);
    b.append(
        &remote,
        "in",
        "session_update",
        json!({"method": "session/update", "params": {"sessionId": session,
            "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": escaped}}}}),
    );
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");
    let info = read(&hub, "machine-b", session, method::MUX_INFO, &json!({})).await.unwrap();
    let last =
        read(&hub, "machine-b", session, method::MUX_LAST, &json!({"count": 1})).await.unwrap();
    assert_eq!(info["sessionId"], session);
    assert_eq!(last["truncated"], true);
    let reply = last["replies"][0].as_str().unwrap();
    assert!(reply.starts_with('\u{0}') && reply.ends_with('…'));
    assert!(serde_json::to_vec(&last).unwrap().len() <= MAX_READ_RESULT_BYTES);
    let asks = hub.asks.load(std::sync::atomic::Ordering::SeqCst);
    eprintln!("last/info duress: 50000 transcript records, 400 KB detail, {asks} hub asks");
    assert_eq!(asks, 2);
}
