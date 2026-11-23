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
            self.asks.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
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
        last_seen_at: 1,
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
