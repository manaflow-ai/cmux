//! The person's Stop of a chat on a peer holds the other agents' messages queued behind its turn
//! there, as it does for a chat on this machine (`hub/cancel.rs` `person_stop`). The peer daemon's
//! link is never the person on the peer, so the peer used to take the Stop as a plain cancel: the
//! stopped turn ended and the next agent message started a turn at once (Leo, 2026-10-29: "i
//! literally can't stop you i clicked the stop button and it didnt do anything"). This daemon now
//! says the Stop is the person's (`personStop`) to a peer that lists the feature
//! (`server/person_stop.rs`); an older peer gets the plain cancel as before.
//!
//! Two hubs: B serves WebSocket; A mirrors B as peer `b`. And a fake peer that records what A
//! forwards, with and without the feature.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    // A chat the peer link starts is a remote one: its folder must be under a web root.
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "webRoots": [std::env::temp_dir()],
        "webAskingModes": {"fake": ["normal"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    // The Stop holds the agent messages queued behind the turn: a plain send queues as before
    // the inbox (`hub/inbox.rs`), as the other queue tests pin it.
    cfg.agent_inbox = Some(false);
    cfg
}

fn hub() -> Arc<Hub> {
    let _ = HERMETIC;
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
    async fn send(&mut self, m: &str, p: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, p).to_line()).await.unwrap();
        self.next
    }

    async fn notify(&mut self, m: &str, p: Value) {
        self.tx.send(Message::notification(m, p).to_line()).await.unwrap();
    }

    async fn call(&mut self, m: &str, p: Value) -> Value {
        let id = self.send(m, p).await;
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                assert!(error.is_none(), "{m} failed: {error:?}");
                return result.unwrap_or(Value::Null);
            }
        }
    }

    async fn wait_for(&mut self, m: &str, pred: impl Fn(&Value) -> bool) {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .unwrap_or_else(|_| panic!("no {m} came"))
                .expect("closed");
            if let Message::Notification { method, params } = Message::parse(&line).unwrap()
                && method == m
                && pred(&params.unwrap_or(Value::Null))
            {
                return;
            }
        }
    }
}

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// A client of `h`; the person when `person`, else a client that never proved the key.
async fn client(h: Arc<Hub>, person: bool) -> C {
    let _ = h.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let init = c.call(method::INITIALIZE, hello).await;
    if person {
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        c.call("_acpmux/person_prove", json!({"proof": proof})).await;
    }
    c
}

async fn until_connected(a: &Hub, name: &str) {
    let peer = a.peer_by_name(name).expect("the peer");
    let mut settled = peer.settled();
    let wait = async {
        while a.peers().into_iter().find(|p| p["name"] == name).expect("listed")["state"]
            != "connected"
        {
            settled.changed().await.expect("peer gone");
        }
    };
    tokio::time::timeout(Duration::from_secs(60), wait).await.expect("the peer never connected");
}

/// The first `kind` record of B's session `id` whose payload `pred` takes, waited for (bounded).
async fn record_until(hub: &Hub, id: &str, kind: &str, pred: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let events = hub.events(id, 0, 10_000).unwrap();
        if let Some(e) = events.iter().find(|e| e.kind == kind && pred(&e.msg)) {
            return e.msg.clone();
        }
        assert!(tokio::time::Instant::now() < deadline, "no {kind} record came");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// How the person's client here sends its Stop.
#[derive(Clone, Copy)]
enum Form {
    Notification,
    Request,
}

/// Who started B's chat `lane`.
#[derive(Clone, Copy)]
enum Started {
    /// A, as the app starts a chat on a peer: a remote chat on B.
    FromA,
    /// B itself, as `acpmux` or `lane-place` start a lane there: B stops it from a peer link
    /// only for its owner's own daemon (`remote_guard/cancel_owner.rs`).
    OnB,
}

/// B's session `lane` runs an "until-cancel" turn with another agent's message queued behind it;
/// A's person presses Stop on `b/lane`. B's log must show the agent message held by the Stop,
/// and the message must still be queued after the stopped turn ended.
async fn a_peers_person_stop_holds(form: Form, started: Started, tag: &str) {
    let b = hub();
    let home = std::env::temp_dir().join(format!("acpmux-pps-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let a = hub();
    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    until_connected(&a, "b").await;
    let mut ca = client(a.clone(), true).await;
    let mut cb = client(b.clone(), true).await;
    let id = match started {
        Started::FromA => {
            let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                "_meta": {"acpmux": {"name": "lane", "peer": "b"}}});
            ca.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned()
        }
        Started::OnB => {
            let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                "_meta": {"acpmux": {"name": "lane"}}});
            let id =
                cb.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();
            assert!(!b.resolve(&id).unwrap().meta().remote_origin, "B's own chat");
            until_mirrored(&a, "b/lane").await;
            id
        }
    };
    let turn = json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}],
        "_meta": {"acpmux": {"promptId": "p-turn"}}});
    cb.send(method::SESSION_PROMPT, turn).await;
    cb.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let from_agent = json!({"sessionId": id, "prompt": [{"type": "text", "text": "from a lane"}],
        "_meta": {"acpmux": {"promptId": "p-agent", "fromAgent": "lane-a"}}});
    cb.send(method::SESSION_PROMPT, from_agent).await;
    cb.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-agent" && p["queued"] == true)
        .await;

    let stop = json!({"sessionId": "b/lane"});
    match form {
        Form::Notification => ca.notify(method::SESSION_CANCEL, stop).await,
        Form::Request => {
            ca.call(method::SESSION_CANCEL, stop).await;
        }
    }

    let ended = record_until(&b, &id, "turn_result", |m| m["promptId"] == "p-turn").await;
    assert_eq!(ended["stopReason"], "cancelled", "{ended}");
    let events = b.events(&id, 0, 10_000).unwrap();
    let held = events.iter().find(|e| e.kind == "queue_paused" && e.msg["reason"] == "stop");
    assert!(
        held.is_some_and(|e| e.msg["held"] == json!(["p-agent"])),
        "the peer took the person's Stop as a plain cancel: no hold of the agent message"
    );
    // Held, it starts no turn of its own once the stopped one ended.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let session = b.resolve(&id).unwrap();
    assert!(session.turn().is_none(), "the held agent message started a turn");
    assert_eq!(session.queued(), 1, "the agent message left the queue");
    b.shutdown_all().await;
    a.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&home);
}

/// Waits until `a` mirrors the peer's chat `key`.
async fn until_mirrored(a: &Hub, key: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while a.resolve_remote(key).is_none() {
        assert!(tokio::time::Instant::now() < deadline, "{key} was never mirrored");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_person_stop_notification_for_a_peers_chat_holds_the_agent_messages_there() {
    a_peers_person_stop_holds(Form::Notification, Started::FromA, "note").await;
}

#[tokio::test]
async fn a_person_stop_request_for_a_peers_chat_holds_the_agent_messages_there() {
    a_peers_person_stop_holds(Form::Request, Started::FromA, "req").await;
}

/// Leo's case: a lane the peer started itself, stopped from his Mac.
#[tokio::test]
async fn a_person_stop_of_a_lane_the_peer_started_holds_the_agent_messages_there() {
    a_peers_person_stop_holds(Form::Notification, Started::OnB, "b-note").await;
    a_peers_person_stop_holds(Form::Request, Started::OnB, "b-req").await;
}

/// A fake peer serving one session `lane`: its `initialize` lists `features`, and every
/// `session/cancel` it gets, request or notification, is sent on as its params.
async fn fake_peer(features: Value) -> (u16, mpsc::UnboundedReceiver<Value>) {
    use tokio_tungstenite::tungstenite::Message as Ws;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (cancels, received) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let (cancels, features) = (cancels.clone(), features.clone());
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let (request_id, m, params) = match Message::parse(&text) {
                        Ok(Message::Request { id, method, params }) => (Some(id), method, params),
                        Ok(Message::Notification { method, params }) => (None, method, params),
                        _ => continue,
                    };
                    if m == method::SESSION_CANCEL {
                        let _ = cancels.send(params.unwrap_or(Value::Null));
                    }
                    let Some(request_id) = request_id else { continue };
                    let session = json!({"sessionId": "remote-lane", "name": "lane", "harness": "fake", "status": "running"});
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "version": "0", "build": "fake", "origin": "peer", "features": features}}}),
                        method::MUX_WATCH => json!({"sessions": [session]}),
                        _ => json!({}),
                    };
                    let line = Message::ok(request_id, result).to_line();
                    if ws.send(Ws::Text(line.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    (port, received)
}

async fn next_cancel(cancels: &mut mpsc::UnboundedReceiver<Value>) -> Value {
    tokio::time::timeout(Duration::from_secs(20), cancels.recv())
        .await
        .expect("the Stop never reached the peer")
        .expect("the fake peer ended")
}

fn says_person(cancel: &Value) -> bool {
    cancel.pointer("/_meta/acpmux/personStop") == Some(&Value::Bool(true))
}

/// The person's Stop says so only to a peer that lists `personStop`; an older peer gets the plain
/// cancel it always took, and a client that is not the person never says it, whatever it sends.
#[tokio::test]
async fn a_forwarded_stop_says_it_is_the_persons_only_to_a_peer_that_takes_it() {
    let (new_port, mut new_cancels) = fake_peer(json!(["personStop"])).await;
    let (old_port, mut old_cancels) = fake_peer(json!([])).await;
    let a = hub();
    for (name, port) in [("new", new_port), ("old", old_port)] {
        let url = format!("ws://127.0.0.1:{port}");
        a.add_peer(name, &url, Some("tok".into()), None, true).await.unwrap();
        until_connected(&a, name).await;
    }
    let mut person = client(a.clone(), true).await;
    let mut agent = client(a.clone(), false).await;

    person.notify(method::SESSION_CANCEL, json!({"sessionId": "new/lane"})).await;
    let cancel = next_cancel(&mut new_cancels).await;
    assert!(says_person(&cancel), "the person's Stop to a peer that takes it: {cancel}");
    assert_eq!(cancel["sessionId"], "remote-lane", "{cancel}");
    person.call(method::SESSION_CANCEL, json!({"sessionId": "new/lane"})).await;
    let cancel = next_cancel(&mut new_cancels).await;
    assert!(says_person(&cancel), "the person's Stop as a request: {cancel}");

    person.notify(method::SESSION_CANCEL, json!({"sessionId": "old/lane"})).await;
    let cancel = next_cancel(&mut old_cancels).await;
    assert!(!says_person(&cancel), "an older peer got the new field: {cancel}");
    person.call(method::SESSION_CANCEL, json!({"sessionId": "old/lane"})).await;
    let cancel = next_cancel(&mut old_cancels).await;
    assert!(!says_person(&cancel), "an older peer got the new field: {cancel}");

    // An agent's Stop, even one that writes the field itself, is a plain cancel on the peer.
    let forged = json!({"sessionId": "new/lane", "_meta": {"acpmux": {"personStop": true}}});
    agent.notify(method::SESSION_CANCEL, forged.clone()).await;
    let cancel = next_cancel(&mut new_cancels).await;
    assert!(!says_person(&cancel), "an agent's Stop went on as the person's: {cancel}");
    agent.call(method::SESSION_CANCEL, forged).await;
    let cancel = next_cancel(&mut new_cancels).await;
    assert!(!says_person(&cancel), "an agent's Stop went on as the person's: {cancel}");
    a.shutdown_all().await;
}
