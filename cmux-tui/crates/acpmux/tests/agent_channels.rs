//! Agent byte channels (`server/channels.rs`) across a real peer link: two hubs in this process,
//! B serving WebSocket and A mirroring B as peer `b`, as `cancel_peer_link.rs` sets them up.
//!
//! - A client on B listens on `echo`; a client on A opens `b`/`echo` with its first bytes on the
//!   open itself. B's listener hears `opened` carrying them, answers on the channel, and A's
//!   opener hears `data`; A closes and B hears `closed` once.
//! - Old against new, both ways: a peer that never listed `agent-channels-v1` (an older build) is
//!   refused at A with `peer_unsupported` before anything goes on the link; an older client
//!   never sends a channel method, and a stranger's `send` on a channel it does not hold is told
//!   `unknown_channel` while the channel's parties hear nothing.
//! - A link that drops closes its channels on both sides (`link_lost` on A, `peer_gone` on B).
//! - Loopback (no peer): a channel on one daemon, both ends local.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

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
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const WAIT: Duration = Duration::from_secs(30);
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn hub() -> Arc<Hub> {
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
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A local client connection: answers by id, and the channel notifications it heard, in order.
struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    answers: Vec<Value>,
    heard: Vec<(String, Value)>,
    next_id: i64,
}

impl Client {
    async fn connect(h: Arc<Hub>) -> Self {
        let _ = h.person.install_spawn_key(PERSON_KEY);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c =
            Self { tx: in_tx, rx: out_rx, answers: Vec::new(), heard: Vec::new(), next_id: 10 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
        let init = c.call(method::INITIALIZE, hello).await;
        let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let proved = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(proved.get("error").is_none(), "{proved}");
        c
    }

    async fn read(&mut self, within: Duration) -> bool {
        let Ok(Some(line)) = tokio::time::timeout(within, self.rx.recv()).await else {
            return false;
        };
        let v: Value = serde_json::from_str(&line).unwrap();
        match (v.get("id").is_some(), v["method"].as_str()) {
            (true, None) => self.answers.push(v),
            (false, Some(m)) if m.starts_with("_acpmux/channel/") => {
                self.heard.push((m.to_owned(), v["params"].clone()))
            }
            _ => {}
        }
        true
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        let deadline = tokio::time::Instant::now() + WAIT;
        loop {
            if let Some(at) = self.answers.iter().position(|v| v["id"] == json!(id)) {
                return self.answers.remove(at);
            }
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            assert!(self.read(left).await, "no answer to {m}");
        }
    }

    async fn notify(&self, m: &str, params: Value) {
        self.tx.send(Message::notification(m, params).to_line()).await.unwrap();
    }

    /// The first channel notification `m` heard (waiting for it), removed from `heard`.
    async fn hear(&mut self, m: &str) -> Value {
        let deadline = tokio::time::Instant::now() + WAIT;
        loop {
            if let Some(at) = self.heard.iter().position(|(got, _)| got == m) {
                return self.heard.remove(at).1;
            }
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            assert!(self.read(left).await, "never heard {m}; heard {:#?}", self.heard);
        }
    }

    /// Everything heard until nothing more comes for `quiet`.
    async fn drain(&mut self, quiet: Duration) -> Vec<(String, Value)> {
        while self.read(quiet).await {}
        std::mem::take(&mut self.heard)
    }
}

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Pair {
    a: Arc<Hub>,
    b: Arc<Hub>,
    _scratch: Scratch,
}

/// B serves WebSocket with a peer token; A mirrors B as peer `b`, connected.
async fn pair(tag: &str) -> Pair {
    let _ = HERMETIC;
    let scratch =
        Scratch(std::env::temp_dir().join(format!("amx-channels-{tag}-{}", uuid::Uuid::new_v4())));
    let home = scratch.0.join("home");
    let b = hub();
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let a = hub();
    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let peer = a.peer_by_name("b").expect("peer b");
    let mut settled = peer.settled();
    let connected = async {
        while a.peers().into_iter().next().expect("one peer")["state"] != "connected" {
            settled.changed().await.expect("peer gone");
        }
    };
    tokio::time::timeout(Duration::from_secs(60), connected).await.expect("peer b never connected");
    Pair { a, b, _scratch: scratch }
}

fn reason(err: &Value) -> &str {
    err["error"]["data"]["reason"].as_str().unwrap_or_default()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_channel_opens_carries_bytes_both_ways_and_closes_across_a_peer() {
    let p = pair("roundtrip").await;
    let mut listener = Client::connect(p.b.clone()).await;
    let listening = listener.call(method::MUX_CHANNEL_LISTEN, json!({"service": "echo"})).await;
    assert!(listening.get("error").is_none(), "{listening}");
    // The service is held: a second listener on B is told so.
    let mut other = Client::connect(p.b.clone()).await;
    let taken = other.call(method::MUX_CHANNEL_LISTEN, json!({"service": "echo"})).await;
    assert_eq!(reason(&taken), "channel.service_taken", "{taken}");

    let mut opener = Client::connect(p.a.clone()).await;
    let started = Instant::now();
    let open = opener
        .call(method::MUX_CHANNEL_OPEN, json!({"peer": "b", "service": "echo", "text": "hi"}))
        .await;
    let id = open["result"]["channelId"].as_str().expect("a channel id").to_owned();
    assert_eq!(open["result"]["peer"], "b", "{open}");

    // The first bytes rode the open: B's listener hears them with `opened`, no round trip first.
    let opened = listener.hear(method::MUX_CHANNEL_OPENED).await;
    assert_eq!(opened["text"], "hi", "{opened}");
    assert_eq!(opened["service"], "echo", "{opened}");
    let far = opened["channelId"].as_str().unwrap().to_owned();
    assert_eq!(far, id, "one channel id on both daemons");
    listener
        .notify(method::MUX_CHANNEL_SEND, json!({"channelId": far, "text": "hello back"}))
        .await;
    let data = opener.hear(method::MUX_CHANNEL_DATA).await;
    assert_eq!(data["text"], "hello back", "{data}");
    eprintln!("open to first answer over the link: {:?}", started.elapsed());

    // Raw bytes go as base64 `data`, in order after text.
    opener.notify(method::MUX_CHANNEL_SEND, json!({"channelId": id, "data": "AAEC/w=="})).await;
    opener.notify(method::MUX_CHANNEL_SEND, json!({"channelId": id, "text": "two"})).await;
    let one = listener.hear(method::MUX_CHANNEL_DATA).await;
    let two = listener.hear(method::MUX_CHANNEL_DATA).await;
    assert_eq!(one["data"], "AAEC/w==", "first {one}, then {two}");
    assert_eq!(two["text"], "two", "{two}");

    // A stranger on A cannot write on it: it is told `unknown_channel`, the parties hear nothing.
    let stranger = Client::connect(p.a.clone()).await;
    stranger.notify(method::MUX_CHANNEL_SEND, json!({"channelId": id, "text": "x"})).await;

    opener.notify(method::MUX_CHANNEL_CLOSE, json!({"channelId": id})).await;
    let closed = listener.hear(method::MUX_CHANNEL_CLOSED).await;
    assert_eq!(closed["channelId"], json!(id), "{closed}");
    let rest = listener.drain(Duration::from_millis(300)).await;
    assert!(rest.is_empty(), "B's listener heard more after close: {rest:#?}");
    let rest = opener.drain(Duration::from_millis(300)).await;
    assert!(rest.is_empty(), "A's opener heard more after its close: {rest:#?}");
    assert_eq!(p.a.channel_counts_for_tests().0, 0, "A still holds the channel");
    assert_eq!(p.b.channel_counts_for_tests().0, 0, "B still holds the channel");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_peer_is_refused_before_anything_goes_on_the_link() {
    let p = pair("older").await;
    let mut listener = Client::connect(p.b.clone()).await;
    listener.call(method::MUX_CHANNEL_LISTEN, json!({"service": "echo"})).await;
    // New against old: A's link to B as if B were a build from before `agent-channels-v1`.
    p.a.peer_by_name("b").unwrap().forget_agent_channels_for_tests();
    let mut opener = Client::connect(p.a.clone()).await;
    let open = opener
        .call(method::MUX_CHANNEL_OPEN, json!({"peer": "b", "service": "echo", "text": "hi"}))
        .await;
    assert_eq!(reason(&open), "channel.peer_unsupported", "{open}");
    let heard = listener.drain(Duration::from_millis(300)).await;
    assert!(heard.is_empty(), "B heard an open A refused: {heard:#?}");
    // Old against new: a client from before channels never sends one, and the daemon's other
    // methods are untouched; a peer that is not one is refused by name.
    let unknown =
        opener.call(method::MUX_CHANNEL_OPEN, json!({"peer": "nope", "service": "echo"})).await;
    assert_eq!(reason(&unknown), "channel.peer_unknown", "{unknown}");
    let none = opener.call(method::MUX_CHANNEL_OPEN, json!({"service": "echo"})).await;
    assert_eq!(reason(&none), "channel.no_listener", "{none}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dropped_link_closes_the_channel_on_both_sides() {
    let p = pair("drop").await;
    let mut listener = Client::connect(p.b.clone()).await;
    listener.call(method::MUX_CHANNEL_LISTEN, json!({"service": "echo"})).await;
    let mut opener = Client::connect(p.a.clone()).await;
    let open = opener.call(method::MUX_CHANNEL_OPEN, json!({"peer": "b", "service": "echo"})).await;
    let id = open["result"]["channelId"].as_str().expect("a channel id").to_owned();
    listener.hear(method::MUX_CHANNEL_OPENED).await;
    p.a.remove_peer("b").await.unwrap();
    let mine = opener.hear(method::MUX_CHANNEL_CLOSED).await;
    assert_eq!(mine["channelId"], json!(id), "{mine}");
    assert_eq!(mine["reason"], "link_lost", "{mine}");
    let theirs = listener.hear(method::MUX_CHANNEL_CLOSED).await;
    assert_eq!(theirs["reason"], "peer_gone", "{theirs}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_loopback_channel_and_a_listener_that_leaves() {
    let _ = HERMETIC;
    let h = hub();
    let mut listener = Client::connect(h.clone()).await;
    listener.call(method::MUX_CHANNEL_LISTEN, json!({"service": "svc/one"})).await;
    let mut opener = Client::connect(h.clone()).await;
    let open =
        opener.call(method::MUX_CHANNEL_OPEN, json!({"service": "svc/one", "text": "a"})).await;
    let id = open["result"]["channelId"].as_str().expect("a channel id").to_owned();
    let opened = listener.hear(method::MUX_CHANNEL_OPENED).await;
    assert_eq!(opened["text"], "a");
    listener.notify(method::MUX_CHANNEL_SEND, json!({"channelId": id, "text": "b"})).await;
    assert_eq!(opener.hear(method::MUX_CHANNEL_DATA).await["text"], "b");
    // Frames keep their order, raw bytes and text alike.
    for i in 0..20 {
        let frame = if i % 2 == 0 {
            json!({"channelId": id, "data": "AAEC/w=="})
        } else {
            json!({"channelId": id, "text": format!("{i}")})
        };
        opener.notify(method::MUX_CHANNEL_SEND, frame).await;
    }
    for i in 0..20 {
        let got = listener.hear(method::MUX_CHANNEL_DATA).await;
        if i % 2 == 0 {
            assert_eq!(got["data"], "AAEC/w==", "frame {i}: {got}");
        } else {
            assert_eq!(got["text"], format!("{i}"), "frame {i}: {got}");
        }
    }
    // Both text and data at once is refused, and closes the channel.
    let bad = opener
        .call(method::MUX_CHANNEL_OPEN, json!({"service": "svc/one", "text": "a", "data": "YQ=="}))
        .await;
    assert!(bad.get("error").is_some(), "{bad}");
    // The listener's connection ends: the opener hears `peer_gone`, the service is free again.
    drop(listener);
    let closed = opener.hear(method::MUX_CHANNEL_CLOSED).await;
    assert_eq!(closed["reason"], "peer_gone", "{closed}");
    let again = opener.call(method::MUX_CHANNEL_OPEN, json!({"service": "svc/one"})).await;
    assert_eq!(reason(&again), "channel.no_listener", "{again}");
    assert_eq!(h.channel_counts_for_tests(), (0, 0));
}
