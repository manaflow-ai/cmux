//! A message to another machine's session acks within a second (`hub/outbox.rs`).
//!
//! On 2026-10-21 `acpmux send --no-wait huge-blue/<lane>` from cosmic-gray took 60-120 s and hit
//! `timeout 60` (rc 124) while still delivering. The send waited for `_acpmux/prompt_accepted`,
//! but a peer's acceptance was dropped on the way back (`hub/peers.rs`), and the forwarded
//! `session/prompt` answers only when the target's turn (or a steer's step) ends.
//!
//! Two hubs: B owns the sessions and serves WebSocket; A mirrors B as peer `b`.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{
    Origin, WsAuth, bind_ws, serve_connection, serve_connection_with, serve_ws_with,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// The ack a sender may wait for.
const ACK: Duration = Duration::from_secs(1);
const SEND_QUEUE: &str = "_acpmux/send_queue";
const SEND_STATUS: &str = "_acpmux/send_status";

fn config() -> Config {
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
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

fn hub() -> Arc<Hub> {
    let cfg = config();
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn new(h: Arc<Hub>) -> Self {
        Self::with_origin(h, Origin::Local).await
    }

    async fn with_origin(h: Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(h, in_rx, out_tx, origin));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        c.call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
            .await
            .unwrap();
        c
    }

    /// The connection a session's own tools open: `initialize` with its caller token.
    async fn as_session(h: Arc<Hub>, id: &str) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        let token = acpmux::hub::person::caller_token(id);
        c.call(
            method::INITIALIZE,
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await
        .unwrap();
        c
    }

    async fn send(&mut self, m: &str, p: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, p).to_line()).await.unwrap();
        self.next
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        let id = self.send(m, p).await;
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Ok(Message::Response { id: rid, result, error }) = Message::parse(&line)
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }

    async fn message_events(&mut self, session: &str) -> Vec<Value> {
        let page = self
            .call(method::MUX_EVENTS, json!({"sessionId": session, "limit": 5000}))
            .await
            .unwrap();
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|event| event["kind"] == "_acpmux/message")
            .map(|event| event["msg"].clone())
            .collect()
    }

    /// The notification `m` that `pred` takes, within `within`.
    async fn notified(
        &mut self,
        m: &str,
        within: Duration,
        pred: impl Fn(&Value) -> bool,
    ) -> Option<Value> {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.rx.recv()).await.ok()??;
            if let Ok(Message::Notification { method: got, params }) = Message::parse(&line) {
                let p = params.unwrap_or(Value::Null);
                if got == m && pred(&p) {
                    return Some(p);
                }
            }
        }
    }
}

/// B, with a session `name` whose turn runs until cancelled (a lane at work), and A peered to it.
async fn busy_peer(tag: &str, name: &str) -> (Arc<Hub>, Arc<Hub>, String) {
    let b = hub();
    let home = std::env::temp_dir().join(format!("send-async-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(
        b.clone(),
        l,
        "tok".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    let mut cb = C::new(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    cb.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
    )
    .await;
    cb.notified(method::MUX_EVENT, Duration::from_secs(20), |p| p["kind"] == "turn_started")
        .await
        .expect("B's turn started");
    // Keep B's client: dropping it would not end the turn, but it holds the session attached.
    tokio::spawn(async move {
        let _keep = cb;
        tokio::time::sleep(Duration::from_secs(60)).await;
    });
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    (a, b, id)
}

fn prompt(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({
        "sessionId": session,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    })
}

/// A prompt for a busy peer's session: the sender hears it was taken within a second, not
/// when the target's turn ends.
#[tokio::test]
async fn a_busy_peer_session_acks_a_forwarded_prompt_within_a_second() {
    let (a, _b, _id) = busy_peer("relay", "lane").await;
    let mut ca = C::new(a).await;
    let started = Instant::now();
    ca.send(method::SESSION_PROMPT, prompt("b/lane", "from cosmic-gray", "p-relay")).await;
    let accepted =
        ca.notified(method::MUX_PROMPT_ACCEPTED, ACK, |p| p["promptId"] == "p-relay").await;
    assert!(
        accepted.is_some(),
        "no prompt_accepted within {ACK:?} (waited {:?}): the peer's acceptance never came back",
        started.elapsed()
    );
    assert_eq!(accepted.unwrap()["peer"], "b");
}

/// `send_queue` answers at once with a delivery id; the daemon delivers it, and
/// `send_status` says it was taken by the busy peer session.
#[tokio::test]
async fn send_queue_acks_at_once_and_status_reports_the_delivery() {
    let (a, b, id) = busy_peer("queue", "lane").await;
    let mut person = C::new(a.clone()).await;
    let sender = person
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                   "_meta": {"acpmux": {"name": "sender"}}}),
        )
        .await
        .unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut ca = C::as_session(a, &sender).await;
    let started = Instant::now();
    let queued = ca
        .call(SEND_QUEUE, json!({"request": prompt("b/lane", "hello", "p-queue")}))
        .await
        .unwrap();
    assert!(started.elapsed() < ACK, "send_queue took {:?}", started.elapsed());
    let delivery = queued["deliveryId"].as_str().expect("a delivery id").to_owned();
    assert_eq!(queued["target"], "b/lane");
    let status =
        ca.call(SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 5000})).await.unwrap();
    assert_eq!(status["status"], "delivered", "{status}");
    assert_eq!(status["accepted"]["promptId"], "p-queue", "{status}");
    // The same prompt id again is the same delivery, and B took it once.
    let again = ca
        .call(SEND_QUEUE, json!({"request": prompt("b/lane", "hello", "p-queue")}))
        .await
        .unwrap();
    assert_eq!(again["deliveryId"], delivery);
    let mut cb = C::new(b).await;
    let info = cb.call(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["queued"], 1, "{info}");
    let incoming = cb.message_events(&id).await;
    let outgoing = ca.message_events(&sender).await;
    assert_eq!(incoming.len(), 1, "{incoming:#?}");
    assert_eq!(outgoing.len(), 1, "{outgoing:#?}");
    assert_eq!(incoming[0]["sessionId"], id);
    assert_eq!(outgoing[0]["sessionId"], sender);
    for event in [&incoming[0], &outgoing[0]] {
        assert_eq!(event["sender"]["sessionId"], sender);
        assert_eq!(event["sender"]["name"], "sender");
        assert_eq!(event["text"], "hello");
        assert_eq!(event["messageId"], delivery);
        assert!(event["at"].as_u64().is_some_and(|at| at > 0));
    }
}

/// Sender copies keep distinct target scopes when clients reuse one prompt id.
#[tokio::test]
async fn same_prompt_id_to_two_peer_targets_keeps_both_sender_copies() {
    let (a, b, lane) = busy_peer("scoped-dedupe", "lane").await;
    let mut person = C::new(a.clone()).await;
    let sender = person
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
            "_meta": {"acpmux": {"name": "scoped-sender"}}}),
        )
        .await
        .unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut b_client = C::new(b).await;
    let other = b_client
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
            "_meta": {"acpmux": {"name": "other-target"}}}),
        )
        .await
        .unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut from = C::as_session(a, &sender).await;
    for target in [format!("b/{lane}"), format!("b/{other}")] {
        from.send(method::SESSION_PROMPT, prompt(&target, "same id", "same-prompt")).await;
        from.notified(method::MUX_PROMPT_ACCEPTED, Duration::from_secs(20), |p| {
            p["promptId"] == "same-prompt"
        })
        .await
        .expect("target accepted");
    }
    let copies = person.message_events(&sender).await;
    assert_eq!(copies.len(), 2, "{copies:#?}");
    assert!(copies.iter().all(|event| event["messageId"] == "same-prompt"));
}

/// Two connections retrying one message share a receiver acceptance but each hears it.
/// That fan-out must still leave exactly one outgoing and one incoming journal copy.
#[tokio::test]
async fn concurrent_peer_prompt_retries_record_each_journal_copy_once() {
    let (a, b, target) = busy_peer("message-retry", "lane").await;
    let mut person = C::new(a.clone()).await;
    let sender = person
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                   "_meta": {"acpmux": {"name": "retry-sender"}}}),
        )
        .await
        .unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut first = C::as_session(a.clone(), &sender).await;
    let mut retry = C::as_session(a, &sender).await;
    let request = prompt("b/lane", "one logical message", "p-concurrent-message");
    tokio::join!(
        first.send(method::SESSION_PROMPT, request.clone()),
        retry.send(method::SESSION_PROMPT, request),
    );
    let accepted = |p: &Value| p["promptId"] == "p-concurrent-message";
    let (first_ack, retry_ack) = tokio::join!(
        first.notified(method::MUX_PROMPT_ACCEPTED, Duration::from_secs(20), accepted),
        retry.notified(method::MUX_PROMPT_ACCEPTED, Duration::from_secs(20), accepted),
    );
    assert!(first_ack.is_some() && retry_ack.is_some(), "{first_ack:?}, {retry_ack:?}");
    let outgoing = person.message_events(&sender).await;
    let mut receiver = C::new(b).await;
    let incoming = receiver.message_events(&target).await;
    for events in [&outgoing, &incoming] {
        assert_eq!(events.len(), 1, "{events:#?}");
        assert_eq!(events[0]["messageId"], "p-concurrent-message");
        assert_eq!(events[0]["sender"]["sessionId"], sender);
        assert_eq!(events[0]["text"], "one logical message");
    }
}

/// A browser's metadata stays untrusted when the prompt crosses a daemon link.
#[tokio::test]
async fn web_to_peer_prompt_cannot_forge_message_sender_or_local_journal() {
    let (a, b, id) = busy_peer("web-sender", "lane").await;
    b.config.write().await.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    b.set_policy(&b.resolve(&id).unwrap(), PermissionPolicy::Ask).await;
    let mut local = C::new(b.clone()).await;
    let victim = local
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                   "_meta": {"acpmux": {"name": "not-the-sender"}}}),
        )
        .await
        .unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut web = C::with_origin(a, Origin::Web).await;
    let mut request = prompt("b/lane", "browser message", "p-forged-sender");
    request["_meta"]["acpmux"]["messageSender"] =
        json!({"name": "forged", "sessionId": victim, "host": "forged-host"});
    web.send(method::SESSION_PROMPT, request).await;
    web.notified(method::MUX_PROMPT_ACCEPTED, Duration::from_secs(20), |p| {
        p["promptId"] == "p-forged-sender"
    })
    .await
    .expect("the browser prompt was accepted, so the test reaches message recording");
    assert!(local.message_events(&id).await.is_empty());
    assert!(local.message_events(&victim).await.is_empty());

    // Even a proven peer owns no local sender journal. Its claimed id may collide
    // with one here, but the only copy it can create is in the actual target.
    let mut peer = C::with_origin(b, Origin::Peer).await;
    let mut request = prompt(&id, "peer message", "p-peer-sender");
    request["_meta"]["acpmux"]["messageSender"] =
        json!({"name": "remote-sender", "sessionId": victim, "host": "peer-host"});
    peer.send(method::SESSION_PROMPT, request).await;
    peer.notified(method::MUX_PROMPT_ACCEPTED, Duration::from_secs(20), |p| {
        p["promptId"] == "p-peer-sender"
    })
    .await
    .expect("the peer prompt was accepted");
    let incoming = local.message_events(&id).await;
    assert_eq!(incoming.len(), 1, "{incoming:#?}");
    assert_eq!(incoming[0]["sender"]["name"], "remote-sender");
    assert_eq!(incoming[0]["sender"]["sessionId"], victim);
    assert!(local.message_events(&victim).await.is_empty());
}

/// A peer that is down: the message is queued at once and tried again, never refused.
#[tokio::test]
async fn send_queue_to_a_peer_that_is_down_acks_at_once_and_keeps_trying() {
    let a = hub();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    a.add_peer("gone", &format!("ws://127.0.0.1:{port}"), None, None, true).await.unwrap();
    let mut ca = C::new(a).await;
    let started = Instant::now();
    let queued =
        ca.call(SEND_QUEUE, json!({"request": prompt("gone/lane", "hi", "p-down")})).await.unwrap();
    assert!(started.elapsed() < ACK, "send_queue took {:?}", started.elapsed());
    let delivery = queued["deliveryId"].as_str().unwrap().to_owned();
    let status =
        ca.call(SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 3000})).await.unwrap();
    assert!(matches!(status["status"].as_str(), Some("queued" | "delivering")), "{status}");
    assert!(status["attempts"].as_u64().unwrap_or(0) >= 1, "{status}");
    assert!(status["error"].as_str().is_some_and(|e| e.contains("peer_unreachable")), "{status}");
    // A session nobody has is refused at once.
    let e = ca
        .call(SEND_QUEUE, json!({"request": prompt("nobody", "hi", "p-none")}))
        .await
        .unwrap_err();
    assert!(e.contains("no session"), "{e}");
}

/// A session repeating itself to another is paused (`hub/agent_pairs.rs`): the delivery settles
/// as `held` with the refusal, never retried, so `--no-wait` shows the sender the refusal a
/// direct send gave.
#[tokio::test]
async fn a_paused_agent_pair_holds_the_delivery_and_says_so() {
    let mut cfg = config();
    cfg.harnesses.get_mut("fake").unwrap().family = Some("codex".into());
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let h = Hub::new(cfg, store);
    let mut c = C::new(h.clone()).await;
    let new = || json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let a =
        c.call(method::SESSION_NEW, new()).await.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let b =
        c.call(method::SESSION_NEW, new()).await.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let mut lane = C::as_session(h, &a).await;
    let mut last = Value::Null;
    for (n, text) in [
        "Please check the build, run 1",
        "please  check the BUILD, run 2",
        "Please check the build, run 3",
    ]
    .into_iter()
    .enumerate()
    {
        let queued = lane
            .call(SEND_QUEUE, json!({"request": prompt(&b, text, &format!("p-pair-{n}"))}))
            .await
            .unwrap();
        let delivery = queued["deliveryId"].as_str().unwrap().to_owned();
        last =
            lane.call(SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 5000})).await.unwrap();
        if n < 2 {
            assert_eq!(last["status"], "delivered", "message {n}: {last}");
        }
    }
    assert_eq!(last["status"], "held", "the third near-identical message is held: {last}");
    assert_eq!(last["attempts"], 1, "a held message is not sent again: {last}");
    assert!(last["error"].as_str().is_some_and(|e| !e.is_empty()), "{last}");
}

/// A session whose folder was removed (its worktree deleted while it was idle): on 2026-10-21
/// sends to cmux16's `chief-team` failed with `spawn harness process: No such file or directory`,
/// which named neither the folder nor what was missing. The message stays queued, tried again,
/// says which folder is gone, and is delivered once the folder is back.
#[tokio::test]
async fn a_session_whose_folder_is_gone_keeps_the_message_and_names_the_folder() {
    let h = hub();
    let folder = std::env::temp_dir().join(format!("send-async-gone-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();
    let mut c = C::new(h.clone()).await;
    let s = c
        .call(
            method::SESSION_NEW,
            json!({"cwd": folder, "mcpServers": [], "_meta": {"acpmux": {"name": "gone-lane"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.call(method::SESSION_PROMPT, prompt(&id, "first", "p-gone-0")).await.unwrap();
    let session = h.resolve("gone-lane").unwrap();
    h.detach_child(&session).await;
    std::fs::remove_dir_all(&folder).unwrap();

    let started = Instant::now();
    let queued = c.call(SEND_QUEUE, json!({"request": prompt(&id, "hi", "p-gone")})).await.unwrap();
    assert!(started.elapsed() < ACK, "send_queue took {:?}", started.elapsed());
    let delivery = queued["deliveryId"].as_str().unwrap().to_owned();
    // The first attempt's refusal, once it has run (its error is set).
    let mut status = Value::Null;
    for _ in 0..20 {
        status = c.call(SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 500})).await.unwrap();
        if status["error"].is_string() {
            break;
        }
    }
    assert!(matches!(status["status"].as_str(), Some("queued" | "delivering")), "{status}");
    let error = status["error"].as_str().unwrap_or_default();
    assert!(
        error.contains(&*folder.to_string_lossy()) && error.contains("no longer exists"),
        "the error names the missing folder: {status}"
    );

    std::fs::create_dir_all(&folder).unwrap();
    let mut status = Value::Null;
    for _ in 0..3 {
        status =
            c.call(SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 10_000})).await.unwrap();
        if status["status"] == "delivered" {
            break;
        }
    }
    assert_eq!(status["status"], "delivered", "{status}");
    let _ = std::fs::remove_dir_all(&folder);
}

/// Coordinators name every lane `HOST/NAME`, the form other machines list it under. On the
/// lane's own machine that name was `no_session` (on cosmic-gray, `acpmux info
/// cosmic-gray/deputy-2` while `deputy-2` ran there), so a send from a coordinator on the same
/// machine failed. This machine's own name in front of a local session's name finds it.
#[tokio::test]
async fn this_machines_own_name_in_front_of_a_session_name_finds_the_session() {
    let h = hub();
    let mut c = C::new(h.clone()).await;
    let s = c
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "own-lane"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let qualified = format!("{}/own-lane", acpmux::pairing::machine_name());
    let info = c.call(method::MUX_INFO, json!({"sessionId": qualified})).await.unwrap();
    assert_eq!(info["sessionId"], id, "{info}");
    let queued =
        c.call(SEND_QUEUE, json!({"request": prompt(&qualified, "hi", "p-own")})).await.unwrap();
    let delivery = queued["deliveryId"].as_str().unwrap().to_owned();
    let status =
        c.call(SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 5000})).await.unwrap();
    assert_eq!(status["status"], "delivered", "{status}");
    assert_eq!(status["accepted"]["sessionId"], id, "{status}");
    // Only the whole name: `own-lan` is a prefix of `own-lane`, but HOST/own-lan finds nothing.
    let partial = format!("{}/own-lan", acpmux::pairing::machine_name());
    let e = c.call(method::MUX_INFO, json!({"sessionId": partial})).await.unwrap_err();
    assert!(e.contains("no session"), "{e}");
    // The name in any case: a coordinator writes `Air-Blue` for `air-blue`.
    let upper = format!("{}/own-lane", acpmux::pairing::machine_name().to_uppercase());
    let info = c.call(method::MUX_INFO, json!({"sessionId": upper})).await.unwrap();
    assert_eq!(info["sessionId"], id, "{info}");
    // A peer named like this machine owns that name: its session is meant, never this one.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let host = acpmux::pairing::machine_name();
    h.add_peer(&host, &format!("ws://127.0.0.1:{port}"), None, None, true).await.unwrap();
    let shadowed = c.call(method::MUX_INFO, json!({"sessionId": qualified})).await;
    assert!(shadowed.as_ref().map_or(true, |i| i["sessionId"] != id), "{shadowed:?}");
    // Another machine's name is not this one's: still no session here.
    let other = format!("not-{}/own-lane", acpmux::pairing::machine_name());
    let e = c.call(method::MUX_INFO, json!({"sessionId": other})).await.unwrap_err();
    assert!(e.contains("no session"), "{e}");
}
