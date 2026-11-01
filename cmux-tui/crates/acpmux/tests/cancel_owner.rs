//! Who may Stop a chat that was started on this machine, from a connection that is not the unix
//! socket (`server/remote_guard/cancel_owner.rs`). The owner's own daemon (a peer link that
//! presented this launch's peer token, asking for itself or for its own person's app) may: Leo
//! pressed Stop on a lane running on a peer and nothing happened (2026-10-29: "i literally can't
//! stop you i clicked the stop button and it didnt do anything"). A Web client, a paired device
//! and a peer forwarding for either may not. A refusal is never silent: the notification form,
//! the one the pane sends, gets `_acpmux/cancel_refused` back, through a forwarding daemon too.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{ConnAuth, Origin, WsAuth, bind_ws, serve_connection_authed, serve_ws_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const REFUSED: &str = "remote.session_cancel_ownership";

fn hub() -> Arc<Hub> {
    let _ = HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "webRoots": [std::env::temp_dir()],
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        Self::reading(hub, origin, auth, 4096)
    }

    /// A client whose outbound queue holds `room` lines: past it the daemon drops notifications.
    fn reading(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth, room: usize) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(room);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0)
    }

    fn local(hub: &Arc<Hub>) -> Self {
        Self::new(hub, Origin::Local, ConnAuth::LocalSocket)
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
        self.2
    }

    async fn notify(&self, m: &str, params: Value) {
        // A connection the daemon ended (an unproven one) takes nothing more.
        let _ = self.0.send(Message::notification(m, params).to_line()).await;
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .expect("no answer")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn wait_for(&mut self, m: &str, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap_or_else(|_| panic!("no {m} came"))
                .expect("closed");
            let Message::Notification { method, params } = Message::parse(&line).unwrap() else {
                continue;
            };
            let params = params.unwrap_or(Value::Null);
            if method == m && pred(&params) {
                return params;
            }
        }
    }

    /// Whether `m` comes within `ms`.
    async fn comes(&mut self, m: &str, ms: u64, pred: impl Fn(&Value) -> bool) -> bool {
        tokio::time::timeout(Duration::from_millis(ms), self.wait_for(m, pred)).await.is_ok()
    }
}

/// A chat this machine started (the unix socket), running an "until-cancel" turn.
async fn local_chat_running(local: &mut Client, name: &str) -> String {
    let r = local
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    local
        .send(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
        )
        .await;
    local
        .wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    id
}

async fn turn_ended(local: &mut Client, id: &str, ms: u64) -> bool {
    let id = id.to_owned();
    local
        .comes(method::MUX_EVENT, ms, move |p| p["kind"] == "turn_end" && p["sessionId"] == id)
        .await
}

/// The cancel `meta` adds to, as `_meta.acpmux`.
fn cancel(id: &str, meta: Value) -> Value {
    if meta.is_null() {
        json!({"sessionId": id})
    } else {
        json!({"sessionId": id, "_meta": {"acpmux": meta}})
    }
}

#[tokio::test]
async fn the_owners_peer_daemon_stops_a_chat_started_on_this_machine() {
    // For itself (the person's CLI there), and for its person's app (`via: app`), in both forms.
    for meta in [Value::Null, json!({"via": "app"}), json!({"via": "app", "personStop": true})] {
        for notification in [true, false] {
            let hub = hub();
            let mut local = Client::local(&hub);
            let id = local_chat_running(&mut local, "lane").await;
            let mut owner = Client::new(&hub, Origin::Peer, ConnAuth::PeerToken);
            if notification {
                owner.notify(method::SESSION_CANCEL, cancel(&id, meta.clone())).await;
                assert!(
                    !owner.comes(method::MUX_CANCEL_REFUSED, 300, |_| true).await,
                    "{meta}: the owner's Stop was refused"
                );
            } else {
                let r = owner.call(method::SESSION_CANCEL, cancel(&id, meta.clone())).await;
                assert_eq!(r["result"], json!({}), "{meta}: {r}");
            }
            assert!(
                turn_ended(&mut local, &id, 20_000).await,
                "{meta}: the owner's Stop ended nothing"
            );
        }
    }
}

/// Every caller that is not the owner, with whatever it claims: refused in both forms, the turn
/// runs on, and the notification form hears why.
#[tokio::test]
async fn guests_other_members_and_forged_owner_claims_cannot_stop_it_and_hear_why() {
    let callers = [
        // A guest: the shared dashboard token (a browser, the Web page).
        ("web", Origin::Web, ConnAuth::ListenerToken, Value::Null),
        // A guest claiming to be the owner's app, or the person's Stop.
        ("web claims app", Origin::Web, ConnAuth::ListenerToken, json!({"via": "app"})),
        ("web claims person", Origin::Web, ConnAuth::ListenerToken, json!({"personStop": true})),
        // Another member's machine paired here (served as Peer, never the owner).
        ("paired device", Origin::Peer, ConnAuth::Device, Value::Null),
        ("paired device claims app", Origin::Peer, ConnAuth::Device, json!({"via": "app"})),
        // The owner's daemon forwarding for someone else: its Web client, a paired machine.
        ("peer for its web", Origin::Peer, ConnAuth::PeerToken, json!({"via": "web"})),
        ("peer for a device", Origin::Peer, ConnAuth::PeerToken, json!({"via": "device"})),
        (
            "peer for a device claims person",
            Origin::Peer,
            ConnAuth::PeerToken,
            json!({"via": "device", "personStop": true}),
        ),
    ];
    let host = acpmux::hand::pair::hostname();
    for (what, origin, auth, meta) in callers {
        let hub = hub();
        let mut local = Client::local(&hub);
        let id = local_chat_running(&mut local, "lane").await;
        let mut other = Client::new(&hub, origin, auth);

        let r = other.call(method::SESSION_CANCEL, cancel(&id, meta.clone())).await;
        assert_eq!(r["error"]["data"]["reason"], REFUSED, "{what}: {r}");
        let message = r["error"]["message"].as_str().unwrap_or_default();
        // It says why, and names nothing about this machine to a caller that is not its owner.
        assert!(message.contains("only its owner"), "{what}: {message}");
        assert!(!message.contains(&host), "{what} learned the host name: {message}");

        other.notify(method::SESSION_CANCEL, cancel(&id, meta.clone())).await;
        let told = other.wait_for(method::MUX_CANCEL_REFUSED, |_| true).await;
        assert_eq!(told["sessionId"], id, "{what}: {told}");
        assert_eq!(told["reason"], REFUSED, "{what}: {told}");
        assert_eq!(told["message"], message, "{what}: {told}");
        // It names the turn it refused to stop, so the pane can tell it from a late answer.
        let turn = hub.resolve(&id).unwrap().turn().expect("a running turn").turn_id;
        assert_eq!(told["turnId"], turn, "{what}: {told}");

        assert!(!turn_ended(&mut local, &id, 300).await, "{what}: a refused Stop ended the turn");
        local.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
        assert!(turn_ended(&mut local, &id, 20_000).await, "{what}: the unix socket's Stop");
    }
}

/// A connection that proved nothing (a replayed or stale token fails the handshake, and what is
/// left is this) stops nothing.
#[tokio::test]
async fn an_unproven_link_cannot_stop_it() {
    let hub = hub();
    let mut local = Client::local(&hub);
    let id = local_chat_running(&mut local, "lane").await;
    let mut unproven = Client::new(&hub, Origin::Peer, ConnAuth::None);
    let r = unproven.call(method::SESSION_CANCEL, cancel(&id, Value::Null)).await;
    assert!(r.get("error").is_some(), "{r}");
    unproven.notify(method::SESSION_CANCEL, cancel(&id, Value::Null)).await;
    assert!(!turn_ended(&mut local, &id, 300).await, "an unproven link ended the turn");
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

/// Two daemons: B serves WebSocket with its peer token and runs a chat it started itself (a lane
/// `acpmux` or `lane-place` started there); A mirrors B as peer `b`.
async fn two_daemons(tag: &str) -> (Arc<Hub>, Arc<Hub>, Client, String, std::path::PathBuf) {
    let b = hub();
    let home = std::env::temp_dir().join(format!("acpmux-co-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(
        b.clone(),
        l,
        "tok".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    let mut cb = Client::local(&b);
    let id = local_chat_running(&mut cb, "lane").await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    until_connected(&a, "b").await;
    (a, b, cb, id, home)
}

/// Leo's Stop: the app (or the CLI) on his Mac stops a lane that runs on a peer and was started
/// there. The pane sends the notification form.
#[tokio::test]
async fn the_owners_stop_of_a_lane_started_on_the_peer_ends_its_turn() {
    for (n, origin, auth) in [
        ("app", Origin::LocalApp, ConnAuth::LocalApp),
        ("cli", Origin::Local, ConnAuth::LocalSocket),
    ] {
        let (a, b, mut cb, id, home) = two_daemons(n).await;
        let mut ca = Client::new(&a, origin, auth);
        ca.notify(method::SESSION_CANCEL, json!({"sessionId": "b/lane"})).await;
        assert!(turn_ended(&mut cb, &id, 20_000).await, "{n}: the owner's Stop ended nothing");
        assert!(!ca.comes(method::MUX_CANCEL_REFUSED, 300, |_| true).await, "{n}: refused");
        b.shutdown_all().await;
        a.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&home);
    }
}

/// A's Web client is no owner of B's chat: B refuses the Stop A forwards for it, and A tells
/// that client, under the name it used, instead of dropping B's answer.
#[tokio::test]
async fn a_peers_refusal_of_a_forwarded_stop_reaches_the_sender() {
    let (a, b, mut cb, id, home) = two_daemons("web").await;
    let turn = b.resolve(&id).unwrap().turn().expect("a running turn").turn_id;
    until_row_turn(&a, "b/lane", &turn).await;
    let mut web = Client::new(&a, Origin::Web, ConnAuth::ListenerToken);
    web.notify(method::SESSION_CANCEL, json!({"sessionId": "b/lane"})).await;
    let told = web.wait_for(method::MUX_CANCEL_REFUSED, |_| true).await;
    assert_eq!(told["sessionId"], "b/lane", "{told}");
    assert_eq!(told["reason"], REFUSED, "{told}");
    assert_eq!(told["peer"], "b", "{told}");
    // The turn A's row showed when the Stop went on, the one B refused to stop.
    assert_eq!(told["turnId"], turn, "{told}");
    assert!(!turn_ended(&mut cb, &id, 300).await, "a guest's forwarded Stop ended the turn");
    b.shutdown_all().await;
    a.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&home);
}

/// Waits until `a`'s row of the peer's chat `key` shows its turn `turn`.
async fn until_row_turn(a: &Hub, key: &str, turn: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if a.resolve_remote(key).is_some_and(|(_, _, row)| row["turn"]["turnId"] == turn) {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "{key} never showed turn {turn}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A client that reads slowly still hears every refused Stop: the daemon drops a notification
/// when the client's queue is full, but not a refusal, or its pane would show Stopping for good.
#[tokio::test]
async fn a_refusal_waits_for_a_slow_reader_and_is_not_dropped() {
    let hub = hub();
    // Room for one notification past the replies' reserve.
    let mut web = Client::reading(&hub, Origin::Web, ConnAuth::ListenerToken, 4);
    let keys: Vec<String> = (1..=5).map(|n| format!("nope-{n}")).collect();
    for key in &keys {
        web.notify(method::SESSION_CANCEL, json!({"sessionId": key})).await;
    }
    // Let the daemon take them all before the client reads.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut heard = Vec::new();
    while heard.len() < keys.len() {
        let line = tokio::time::timeout(Duration::from_secs(5), web.1.recv()).await;
        let Ok(Some(line)) = line else { break };
        if let Ok(Message::Notification { method, params: Some(p) }) = Message::parse(&line)
            && method == method::MUX_CANCEL_REFUSED
        {
            heard.push(p["sessionId"].as_str().unwrap_or_default().to_owned());
        }
    }
    heard.sort();
    assert_eq!(heard, keys, "refusals were dropped for a slow reader");
}

/// How a fake peer answers a forwarded Stop.
#[derive(Clone, Copy)]
enum Answer {
    /// Never: a link that is up but whose daemon is stuck.
    Never,
    /// Its request limit (`connection.busy`), as a daemon answers before it handles anything.
    Busy,
}

/// A fake peer serving one session `lane`: every `session/cancel` it gets, request or
/// notification, is sent on as its params, and answered as `answer` says.
async fn fake_peer(answer: Answer) -> (u16, mpsc::UnboundedReceiver<Value>) {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (cancels, received) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let cancels = cancels.clone();
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let (request_id, m, params) = match Message::parse(&text) {
                        Ok(Message::Request { id, method, params }) => (Some(id), method, params),
                        Ok(Message::Notification { method, params }) => (None, method, params),
                        _ => continue,
                    };
                    let Some(request_id) = request_id else {
                        if m == method::SESSION_CANCEL {
                            let _ = cancels.send(params.unwrap_or(Value::Null));
                        }
                        continue;
                    };
                    let session = json!({"sessionId": "remote-lane", "name": "lane", "harness": "fake", "status": "running"});
                    let reply = match m.as_str() {
                        method::SESSION_CANCEL => {
                            let _ = cancels.send(params.unwrap_or(Value::Null));
                            match answer {
                                Answer::Never => continue,
                                Answer::Busy => Message::err(
                                    request_id,
                                    acpmux::rpc::RpcError::new(
                                        -32000,
                                        "connection request limit reached",
                                    )
                                    .with_data(
                                        json!({"reason": "connection.busy", "retryable": true}),
                                    ),
                                ),
                            }
                        }
                        method::INITIALIZE => Message::ok(
                            request_id,
                            json!({"protocolVersion": 1, "_meta": {"acpmux": {
                                "version": "0", "build": "fake", "origin": "peer"}}}),
                        ),
                        method::MUX_WATCH => {
                            Message::ok(request_id, json!({"sessions": [session]}))
                        }
                        _ => Message::ok(request_id, json!({})),
                    };
                    let line = reply.to_line();
                    if ws.send(Ws::Text(line.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    (port, received)
}

/// A Stop forwarded to a peer that never answers, or answers that it is busy: the sender hears
/// so, and the peer gets the Stop once. A second cancel after a lost answer could stop the turn
/// after the one the person stopped.
#[tokio::test]
async fn a_forwarded_stop_with_no_answer_or_a_busy_peer_is_heard_and_never_sent_twice() {
    for (name, answer, reason) in [
        ("silent", Answer::Never, "peer.cancel_unanswered"),
        ("busy", Answer::Busy, "connection.busy"),
    ] {
        let (port, mut cancels) = fake_peer(answer).await;
        let a = hub();
        let url = format!("ws://127.0.0.1:{port}");
        a.add_peer(name, &url, Some("tok".into()), None, true).await.unwrap();
        until_connected(&a, name).await;
        let mut ca = Client::new(&a, Origin::LocalApp, ConnAuth::LocalApp);
        let key = format!("{name}/lane");
        ca.notify(method::SESSION_CANCEL, json!({"sessionId": key})).await;
        let told = ca.wait_for(method::MUX_CANCEL_REFUSED, |_| true).await;
        assert_eq!(told["sessionId"], key, "{name}: {told}");
        assert_eq!(told["reason"], reason, "{name}: {told}");
        assert_eq!(told["peer"], name, "{name}: {told}");
        let first =
            cancels.try_recv().unwrap_or_else(|e| panic!("{name}: no Stop reached it: {e}"));
        assert_eq!(first["sessionId"], "remote-lane", "{name}: {first}");
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(cancels.try_recv().is_err(), "{name}: the Stop was sent twice");
        a.shutdown_all().await;
    }
}
