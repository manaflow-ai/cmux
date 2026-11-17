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
}

impl Loopback {
    fn new(b: &Arc<Hub>, dir: &std::path::Path, user: &'static str) -> Self {
        let hook = super::super::MeshControlHook::new(
            vec![MeshControlFrom::same_user()],
            Some(dir.join("mesh-controls.json")),
        )
        .with_own_user(Arc::new(|| Some("person-1".to_owned())));
        Self { b: b.clone(), hook, user, receipts: Mutex::default(), unknown: false }
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

/// The hub's answer to a mesh message: a read is answered at once with `info`; a prompt is
/// queued.
fn mesh_answer(seen: &Seen, info: &Value) -> (u16, Value) {
    let id = format!("msg_{}", uuid::Uuid::now_v7().simple());
    if seen.body.get("kind").and_then(Value::as_str) == Some("control") {
        let result = info.to_string();
        (200, json!({"messageId": id, "state": "delivered", "createdAt": 1, "result": result}))
    } else {
        (200, json!({"messageId": id, "state": "queued", "createdAt": 1}))
    }
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
        if index == 0 {
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

/// A credential the hub does not know (a stranger's, or made up) is refused by the hub; the
/// browser learns `device.revoked` or `device.unauthorized`, and nothing falls back to the
/// daemon's identity.
#[tokio::test]
async fn a_strangers_credential_is_refused() {
    let (url, seen) =
        http_hub(Box::new(|_, _| (401, json!({"code": "mesh.unauthorized", "message": "no"}))))
            .await;
    let own = Arc::new(DaemonIdentity::default());
    let a = daemon_a(&url, Arc::clone(&own));
    let mut web = Client::connect(&a, Origin::Web);
    let stranger = "cmm_a_strangers_credential";
    web.request("_acpmux/device_hello", json!({"credential": stranger})).await.unwrap();
    for refused in [web.read().await.unwrap_err(), web.prompt().await.unwrap_err()] {
        assert!(matches!(reason(&refused), "device.revoked" | "device.unauthorized"), "{refused}");
        assert!(!refused.to_string().contains(stranger), "{refused}");
    }
    let seen = seen.lock().unwrap().clone();
    assert!(!seen.is_empty(), "the hub never checked the credential");
    assert!(seen.iter().all(|s| s.bearer == format!("Bearer {stranger}")), "{seen:?}");
    assert_eq!(own.used(), 0, "the daemon's own identity was used as a fallback");
}

/// `_acpmux/device_enroll` mints a join token with the person's access token and redeems it as a
/// `web` machine with the browser's public key, as a new machine joins; it returns the device
/// credential to that connection alone and writes no join record.
#[tokio::test]
async fn a_web_device_enrolls_through_the_join_path() {
    let key = base64::engine::general_purpose::STANDARD.encode([7u8; 32]);
    let (url, seen) = http_hub(Box::new(|_, s| {
        if s.line.contains("/v1/machines/join-tokens/redeem") {
            let credential = s.body["proposedCredential"].clone();
            (
                200,
                json!({"machineId": "mch_web_1", "joinTokenId": "join_1", "teamId": "team_1",
                       "userId": "user_1", "wgPublicKey": s.body["wgPublicKey"],
                       "credential": credential}),
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
    let credential = enrolled["credential"].as_str().unwrap_or_default().to_owned();
    assert!(credential.starts_with("cmm_"), "{enrolled}");
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
    assert_eq!(own.used(), 0);
    // A malformed key is refused before the hub is asked.
    let bad = web
        .request("_acpmux/device_enroll", json!({"accessToken": access, "publicKey": "nope"}))
        .await;
    assert!(bad.is_err(), "{bad:?}");
}
