//! A prompt to a chat on a peer whose link is down, or drops before the peer accepted it, waits in
//! the outbox and runs exactly once when the link is back (`server/prompt_outbox.rs`). Two hubs:
//! B owns the chat and serves WebSocket; A reaches B through a TCP relay the test cuts and
//! restores, and every prompt is driven through A.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
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
    let mut cfg = Config {
        harnesses: BTreeMap::from([("fake".to_owned(), profile)]),
        default_harness: Some("fake".into()),
        ..Default::default()
    };
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
    /// The person's own connection to `h` (`hub/person.rs`), as the app's.
    async fn person(h: Arc<Hub>) -> C {
        let _ = h.person.install_spawn_key(PERSON_KEY);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        let init = c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        c.call("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
        c
    }

    async fn send(&mut self, m: &str, p: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, p).to_line()).await.unwrap();
        self.next
    }

    async fn line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
            .await
            .expect("no line within 60 s")
            .expect("connection closed");
        serde_json::from_str(&line).unwrap()
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, Value> {
        let id = self.send(m, p).await;
        loop {
            let v = self.line().await;
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }

    /// The next notification `m` whose params satisfy `pred`, keeping the response to request
    /// `id` if it comes first.
    async fn notice(&mut self, m: &str, id: i64, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let v = self.line().await;
            assert_ne!(v.get("id"), Some(&json!(id)), "answered before {m}: {v}");
            if v["method"] == m && pred(&v["params"]) {
                return v["params"].clone();
            }
        }
    }

    /// The response to request `id`, with every `_acpmux/prompt_accepted` before it.
    async fn answer(&mut self, id: i64) -> (Value, Vec<Value>) {
        let mut accepts = Vec::new();
        loop {
            let v = self.line().await;
            if v["method"] == method::MUX_PROMPT_ACCEPTED {
                accepts.push(v["params"].clone());
            }
            if v.get("id") == Some(&json!(id)) {
                return (v, accepts);
            }
        }
    }
}

/// A TCP relay from A to B's listener the test cuts (every connection closed, new ones refused)
/// and restores, and whose B-to-A direction it can blackhole.
struct Relay {
    port: u16,
    down: Arc<AtomicBool>,
    deaf: Arc<AtomicBool>,
    open: Arc<Mutex<Vec<tokio::task::AbortHandle>>>,
}

impl Relay {
    async fn to(port: u16) -> Relay {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay = Relay {
            port: listener.local_addr().unwrap().port(),
            down: Arc::default(),
            deaf: Arc::default(),
            open: Arc::default(),
        };
        let (down, deaf, open) = (relay.down.clone(), relay.deaf.clone(), relay.open.clone());
        tokio::spawn(async move {
            while let Ok((client, _)) = listener.accept().await {
                if down.load(SeqCst) {
                    continue;
                }
                let Ok(server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await else {
                    continue;
                };
                let (mut cr, mut cw) = client.into_split();
                let (mut sr, mut sw) = server.into_split();
                let up = tokio::spawn(async move {
                    let _ = tokio::io::copy(&mut cr, &mut sw).await;
                });
                let deaf = deaf.clone();
                let back = tokio::spawn(async move {
                    let mut buf = vec![0u8; 64 * 1024];
                    while let Ok(n) = sr.read(&mut buf).await {
                        if n == 0 {
                            break;
                        }
                        if !deaf.load(SeqCst) && cw.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                    }
                });
                open.lock().unwrap().extend([up.abort_handle(), back.abort_handle()]);
            }
        });
        relay
    }

    /// Every connection closes and new ones are refused.
    fn cut(&self) {
        self.down.store(true, SeqCst);
        for task in self.open.lock().unwrap().drain(..) {
            task.abort();
        }
    }

    fn restore(&self) {
        self.deaf.store(false, SeqCst);
        self.down.store(false, SeqCst);
    }
}

/// B with a chat `lane`, and A linked to B through a relay: (A, B, the chat's id on B, relay).
async fn linked(tag: &str) -> (Arc<Hub>, Arc<Hub>, String, Relay) {
    let b = hub();
    let home = std::env::temp_dir().join(format!("prompt-outbox-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let ws = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), listener, "tok".into(), ws));
    let mut cb = C::person(b.clone()).await;
    let made = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                   "_meta": {"acpmux": {"name": "lane"}}}),
        )
        .await
        .unwrap();
    let relay = Relay::to(port).await;
    let a = hub();
    a.add_peer(
        "b",
        &format!("ws://127.0.0.1:{}", relay.port),
        Some("tok".into()),
        Some(token),
        true,
    )
    .await
    .unwrap();
    (a, b, made["sessionId"].as_str().unwrap().to_owned(), relay)
}

/// Waits until A says its link to B is `up`.
async fn link_is(a: &Hub, up: bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while a.peers()[0]["connected"] != json!(up) {
        assert!(tokio::time::Instant::now() < deadline, "link never {up}: {:?}", a.peers());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// How many times B's chat recorded prompt `prompt_id` as a user message: each is one run.
async fn runs(b: &Arc<Hub>, session: &str, prompt_id: &str) -> usize {
    let mut cb = C::person(b.clone()).await;
    let page = cb
        .call(
            method::MUX_EVENTS,
            json!({"sessionId": session, "afterSeq": 0, "limit": 1000, "kinds": ["user_message"]}),
        )
        .await
        .unwrap();
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e.pointer("/msg/promptId").and_then(Value::as_str) == Some(prompt_id))
        .count()
}

fn prompt(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
           "_meta": {"acpmux": {"promptId": prompt_id}}})
}

/// The link is down when the person sends: the prompt waits (`state: "outbox"`, no error), runs
/// once the link is back, and the request answers with its turn.
#[tokio::test]
async fn prompt_outbox_a_prompt_sent_while_the_link_is_down_waits_and_runs_once() {
    let (a, b, session, relay) = linked("down").await;
    let mut ca = C::person(a.clone()).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/lane", "limit": 0})).await.unwrap();
    relay.cut();
    link_is(&a, false).await;

    let id = ca.send(method::SESSION_PROMPT, prompt("b/lane", "while away", "p-down")).await;
    let waiting = ca.notice(method::MUX_PROMPT_ACCEPTED, id, |p| p["promptId"] == "p-down").await;
    assert_eq!(waiting["state"], "outbox", "{waiting}");
    assert_eq!(waiting["peer"], "b");
    assert!(waiting["deliveryId"].is_string(), "{waiting}");
    assert!(waiting["turnId"].is_null());
    assert_eq!(runs(&b, &session, "p-down").await, 0, "ran while the link was down");

    relay.restore();
    let (answer, accepts) = ca.answer(id).await;
    assert!(answer.get("error").is_none(), "{answer}");
    assert_eq!(answer["result"]["stopReason"], "end_turn", "{answer}");
    // The peer's own acceptance followed the outbox's, naming the turn that ran it.
    assert!(
        accepts.iter().any(|p| p["promptId"] == "p-down" && p["turnId"].is_string()),
        "{accepts:?}"
    );
    assert_eq!(runs(&b, &session, "p-down").await, 1);
    // The outbox's record says so too (`acpmux send --status`).
    let status = ca
        .call(method::MUX_SEND_STATUS, json!({"deliveryId": waiting["deliveryId"]}))
        .await
        .unwrap();
    assert_eq!(status["status"], "delivered", "{status}");
    assert_eq!(status["waitsFor"], "b", "{status}");
}

/// The prompt's frame reaches B, then the link drops before B's acceptance comes back: the
/// prompt is not kept in the outbox (`peer.rs` keeps the caller and asks B for the outcome on
/// the next link, unchanged), and it runs exactly once.
#[tokio::test]
async fn prompt_outbox_a_prompt_that_reached_the_peer_before_a_drop_is_rebound_not_resent() {
    let (a, b, session, relay) = linked("dropped").await;
    let mut ca = C::person(a.clone()).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/lane", "limit": 0})).await.unwrap();
    // B's answers no longer reach A: B takes the prompt, A never hears it did.
    relay.deaf.store(true, SeqCst);
    let id = ca.send(method::SESSION_PROMPT, prompt("b/lane", "ticking:6:500", "p-raced")).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while runs(&b, &session, "p-raced").await == 0 {
        assert!(tokio::time::Instant::now() < deadline, "B never took the prompt");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    relay.cut();
    link_is(&a, false).await;
    relay.restore();
    let (answer, accepts) = ca.answer(id).await;
    assert!(answer.get("error").is_none(), "{answer}");
    assert_eq!(answer["result"]["stopReason"], "end_turn", "{answer}");
    assert!(accepts.iter().all(|p| p["state"] != "outbox"), "kept in the outbox: {accepts:?}");
    assert_eq!(runs(&b, &session, "p-raced").await, 1, "the drop ran it again");
}

/// A prompt kept while the link is down, and the same prompt id sent again directly the moment
/// the link is back (the pane's Retry), race the outbox's own resend: B's ledger runs it once
/// and every sender hears that run.
#[tokio::test]
async fn prompt_outbox_a_resend_racing_the_outbox_on_reconnect_runs_exactly_once() {
    let (a, b, session, relay) = linked("race").await;
    let mut ca = C::person(a.clone()).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/lane", "limit": 0})).await.unwrap();
    relay.cut();
    link_is(&a, false).await;
    let id = ca.send(method::SESSION_PROMPT, prompt("b/lane", "ticking:6:500", "p-race")).await;
    let waiting = ca.notice(method::MUX_PROMPT_ACCEPTED, id, |p| p["promptId"] == "p-race").await;
    assert_eq!(waiting["state"], "outbox", "{waiting}");

    relay.restore();
    link_is(&a, true).await;
    let mut cc = C::person(a.clone()).await;
    let direct = cc.call(method::SESSION_PROMPT, prompt("b/lane", "ticking:6:500", "p-race")).await;
    assert_eq!(direct.unwrap()["stopReason"], "end_turn");
    let (answer, _) = ca.answer(id).await;
    assert!(answer.get("error").is_none(), "{answer}");
    assert_eq!(answer["result"]["stopReason"], "end_turn", "{answer}");
    assert_eq!(runs(&b, &session, "p-race").await, 1, "the race ran it twice");
}
