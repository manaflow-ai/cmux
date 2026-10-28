//! A peer daemon's connection (`Origin::Peer`) never learns this host's other peers: no
//! `_acpmux/peer_state_changed` (live, or the snapshot a watcher that fell behind gets), and no
//! rows in `_acpmux/peers` or `_acpmux/status`. A peer handshake turns `_acpmux/watch` on, so
//! without this every daemon peered with this one would hear its peers' names, states and
//! connection errors. The unix socket still hears and lists them all.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::peer_states::Observed;
use acpmux::protocol::peer_state::PeerLinkState;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Watcher {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Watcher {
    /// A connection of `hub`'s on the unix socket (None) or as `origin`, watching.
    async fn new(hub: Arc<Hub>, origin: Option<Origin>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(16384);
        match origin {
            None => drop(tokio::spawn(serve_connection(hub, in_rx, out_tx))),
            Some(o) => drop(tokio::spawn(serve_connection_with(hub, in_rx, out_tx, o))),
        }
        let mut w = Self { tx, rx, next: 0 };
        w.call(method::INITIALIZE, json!({"protocolVersion": 1})).await;
        w.call(method::MUX_WATCH, json!({"enabled": true})).await;
        w
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let (result, error) = self.answer(m, params).await;
        assert!(error.is_none(), "{m}: {error:?}");
        result
    }

    /// The reply to `m`: its result, and its error's message.
    async fn answer(&mut self, m: &str, params: Value) -> (Value, Option<String>) {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(10), self.rx.recv())
                .await
                .expect("an answer")
                .expect("the connection stays open");
            if let Ok(Message::Response { id: got, result, error }) = Message::parse(&line)
                && got == json!(id)
            {
                return (result.unwrap_or(Value::Null), error.map(|e| e.message));
            }
        }
    }

    /// The `_acpmux/peer_state_changed` notes that arrive within `wait`.
    async fn notes(&mut self, wait: Duration) -> Vec<Value> {
        let end = Instant::now() + wait;
        let mut seen = Vec::new();
        while let Some(left) = end.checked_duration_since(Instant::now()) {
            let Ok(Some(line)) = tokio::time::timeout(left, self.rx.recv()).await else { break };
            if let Ok(Message::Notification { method: m, params }) = Message::parse(&line)
                && m == "_acpmux/peer_state_changed"
            {
                seen.push(params.unwrap_or(Value::Null));
            }
        }
        seen
    }
}

fn seen(state: PeerLinkState, error: Option<&str>) -> Observed {
    Observed { state, last_seen: None, error: error.map(str::to_owned) }
}

fn peer_names(rows: &Value) -> Vec<String> {
    let rows = rows.as_array().cloned().unwrap_or_default();
    rows.iter().filter_map(|r| r["name"].as_str().map(str::to_owned)).collect()
}

#[tokio::test]
async fn a_peer_connection_hears_and_lists_none_of_this_hosts_peers() {
    let a = hub();
    let mut local = Watcher::new(a.clone(), None).await;
    let mut peer = Watcher::new(a.clone(), Some(Origin::Peer)).await;
    let quiet = Duration::from_millis(1500);

    // Live: one change.
    a.peer_states().register("x", 1, seen(PeerLinkState::Connecting, None));
    let heard = local.notes(quiet).await;
    assert!(heard.iter().any(|n| n["peer"] == "x"), "the unix socket hears it: {heard:?}");
    let leaked = peer.notes(Duration::from_millis(200)).await;
    assert!(leaked.is_empty(), "a peer's connection heard this host's peers: {leaked:?}");

    // Fell behind: more changes than the feed holds, sent before either watcher runs (this
    // test's runtime has one thread), so each lags and gets the snapshot instead. `y` changes
    // once, first, so its note is pushed out of the feed: only the snapshot carries it.
    a.peer_states().register("y", 1, seen(PeerLinkState::Connected, None));
    for i in 0..600u32 {
        let state = if i % 2 == 0 { PeerLinkState::Reconnecting } else { PeerLinkState::Connected };
        a.peer_states().changed("x", 1, seen(state, Some("connection refused")));
    }
    let heard = local.notes(quiet).await;
    assert!(heard.iter().any(|n| n["peer"] == "y"), "the unix socket gets the snapshot: {heard:?}");
    let leaked = peer.notes(quiet).await;
    assert!(leaked.is_empty(), "a lagging peer connection got the snapshot: {leaked:?}");

    // Neither list names this host's peers to a peer.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    a.add_peer("gone", &format!("ws://127.0.0.1:{port}"), None, None, false).await.unwrap();
    let mine = local.call("_acpmux/peers", json!({})).await;
    assert_eq!(peer_names(&mine["peers"]), ["gone"], "{mine}");
    let theirs = peer.call("_acpmux/peers", json!({})).await;
    assert_eq!(peer_names(&theirs["peers"]), Vec::<String>::new(), "{theirs}");
    let status = peer.call(method::MUX_STATUS, json!({})).await;
    assert_eq!(peer_names(&status["peers"]), Vec::<String>::new(), "{status}");
    let status = local.call(method::MUX_STATUS, json!({})).await;
    assert_eq!(peer_names(&status["peers"]), ["gone"], "{status}");

    // Nor does the not-found error of `_acpmux/resolve`, which names where it looked.
    let query = json!({"query": "no-such-session"});
    let (_, mine) = local.answer(method::MUX_RESOLVE, query.clone()).await;
    assert!(mine.as_deref().is_some_and(|e| e.contains("gone")), "{mine:?}");
    let (_, theirs) = peer.answer(method::MUX_RESOLVE, query).await;
    let theirs = theirs.expect("not found");
    assert!(!theirs.contains("gone"), "a peer's resolve named this host's peers: {theirs}");
}

/// A request for a session of a peer that is down is refused as `peer_unreachable`, with that
/// peer's name, link state and connection error: one the peer's saved rows list (forwarded, and
/// refused by the link), and one they do not (`Hub::peer_down_for`). A peer's connection gets the
/// first refusal without any of that, and for the second the answer a name that is no peer of this
/// host gets.
#[tokio::test]
async fn a_peer_connection_hears_nothing_of_a_down_peer_in_a_refusal() {
    let dir = std::env::temp_dir().join(format!("acpmux-peer-down-{}", uuid::Uuid::now_v7()));
    // `gone`'s rows, saved while it was up: this host lists `gone/m1` while it is down.
    let row = json!({"sessionId": "m1", "name": "gone/kept", "status": "idle", "updatedAt": 5,
        "sessionReceipt": {"hostId": "gone", "muxSessionId": "m1", "generation": 0}});
    std::fs::create_dir_all(dir.join("peers")).unwrap();
    let saved = json!({"lastSeen": 5, "sessions": [row]});
    std::fs::write(dir.join("peers/gone.json"), saved.to_string()).unwrap();
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let a = Hub::new(cfg, store);
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    a.add_peer("gone", &format!("ws://127.0.0.1:{port}"), None, None, true).await.unwrap();
    let mut local = Watcher::new(a.clone(), None).await;
    let mut peer = Watcher::new(a.clone(), Some(Origin::Peer)).await;
    let info = |id: &str| json!({"sessionId": id});

    for id in ["gone/m1", "gone/lane"] {
        let (_, mine) = local.answer(method::MUX_INFO, info(id)).await;
        let mine = mine.expect("refused");
        assert!(mine.starts_with("peer_unreachable: gone ("), "the unix socket hears why: {mine}");
        assert!(mine.contains("Connection refused"), "{mine}");
    }

    let (_, listed) = peer.answer(method::MUX_INFO, info("gone/m1")).await;
    let listed = listed.expect("refused");
    assert_eq!(
        listed, "peer_unreachable: the request was not sent; retry later",
        "a peer's refusal told it of this host's peer"
    );

    let (_, theirs) = peer.answer(method::MUX_INFO, info("gone/lane")).await;
    let theirs = theirs.expect("refused");
    let (_, nobody) = peer.answer(method::MUX_INFO, info("nosuch/lane")).await;
    let nobody = nobody.expect("refused").replace("nosuch", "gone");
    assert_eq!(theirs, nobody, "a peer's refusal told it of this host's peer");
    assert!(!theirs.contains("unreachable"), "{theirs}");
    drop(a);
    let _ = std::fs::remove_dir_all(&dir);
}
