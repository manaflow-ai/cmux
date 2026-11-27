//! A peer's session/load replays `_acpmux/message` records. ACP's session/resume replays no
//! history (`server/requests/session_open.rs`), messages included.
//! The receiving peer must preserve both journal copies and redact sender hosts.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{
    Origin, WsAuth, bind_ws, peer_auth::PeerAuth, serve_connection_with, serve_ws_with,
};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub(root: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        // A peer's load or resume is held to the Web's rules on the owning daemon
        // (`remote_guard.rs`): the chat must ask, in a mode the asking table lists.
        "permissionPolicy": "ask",
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, root).unwrap();
    Hub::new(cfg, store)
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, input) = mpsc::channel(64);
        let (output, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), input, output, Origin::Local));
        Self { tx, rx, next: 0 }
    }

    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut client = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        client
            .ok(
                "initialize",
                json!({"protocolVersion": 1, "_meta": {"acpmux": {
                    "callerSession": {"sessionId": id, "token": token}
                }}}),
            )
            .await;
        client
    }

    async fn call(&mut self, method: &str, params: Value) -> (Value, Vec<Value>) {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, method, params).to_line()).await.unwrap();
        let mut notes = Vec::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.rx.recv())
                .await
                .expect("request timed out")
                .expect("connection closed");
            let msg: Value = serde_json::from_str(&line).unwrap();
            if msg.get("id") == Some(&json!(id)) {
                return (msg, notes);
            }
            notes.push(msg);
        }
    }

    async fn ok(&mut self, method: &str, params: Value) -> Value {
        let (reply, _) = self.call(method, params).await;
        assert!(reply["error"].is_null(), "{method}: {reply}");
        reply["result"].clone()
    }

    async fn new_session(&mut self, name: &str) -> String {
        self.ok(
            "session/new",
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await["sessionId"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    async fn prompt(&mut self, session: &str, text: &str) {
        self.ok(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    }

    async fn replay_messages(&mut self, method: &str, session: &str) -> Vec<Value> {
        let (reply, mut notes) = self.call(method, json!({"sessionId": session})).await;
        assert!(reply["error"].is_null(), "{reply}");
        // The peer notice worker may publish the replayed event just after the
        // forwarded request's response. Drain notifications until the first
        // message arrives, with a bounded event-driven wait.
        if !notes.iter().any(|note| note["method"] == "_acpmux/message") {
            let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
            while let Ok(Some(line)) = tokio::time::timeout_at(deadline, self.rx.recv()).await {
                let note: Value = serde_json::from_str(&line).unwrap();
                let is_message = note["method"] == "_acpmux/message";
                notes.push(note);
                if is_message {
                    break;
                }
            }
        }
        let id = session.split_once('/').map_or(session, |(_, id)| id);
        let matches =
            |note: &Value| note["method"] == "_acpmux/message" && note["params"]["sessionId"] == id;
        let mut messages: Vec<_> =
            notes.iter().filter(|note| matches(note)).map(|note| note["params"].clone()).collect();
        if messages.is_empty() {
            // The peer event consumer and forwarded RPC response are independent tasks.
            // Wait on notifications rather than assuming the event wins that race.
            let message = tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    let line = self.rx.recv().await.expect("connection closed");
                    let note: Value = serde_json::from_str(&line).unwrap();
                    if matches(&note) {
                        break note["params"].clone();
                    }
                }
            })
            .await
            .expect("peer replay did not deliver its message event");
            messages.push(message);
        }
        messages
    }
}

#[tokio::test]
async fn peer_reopen_replays_incoming_and_outgoing_messages_without_sender_host() {
    reopen_replays_messages(true).await;
}

/// A peer added with the dashboard token alone (served as Web, `peer.rs` withholds the peer token
/// on a plain non-loopback link) replays them too: its link takes the event envelopes its hub reads.
#[tokio::test]
async fn a_dashboard_token_peer_reopen_replays_its_messages() {
    reopen_replays_messages(false).await;
}

async fn reopen_replays_messages(with_peer_token: bool) {
    let root = std::env::temp_dir().join(format!("peer-message-replay-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let local = hub(&root);
    let remote = hub(&root);
    let auth_dir = root.join("remote-auth");
    let auth = PeerAuth::create(&auth_dir).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_dir)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(
        remote.clone(),
        listener,
        "test-token".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    local
        .add_peer(
            "remote",
            &format!("ws://127.0.0.1:{port}"),
            Some("test-token".into()),
            with_peer_token.then_some(peer_token),
            true,
        )
        .await
        .unwrap();

    // Both copies come from a real fake harness prompt, rather than synthetic journal writes.
    let mut person = Client::new(&remote);
    let sender = person.new_session("sender").await;
    let receiver = person.new_session("receiver").await;
    let mut sender_agent = Client::as_session(&remote, &sender).await;
    sender_agent.prompt(&receiver, "message across the peer").await;

    let mut client = Client::new(&local);
    let incoming = client.replay_messages("session/load", &format!("remote/{receiver}")).await;
    assert_eq!(incoming.len(), 1, "{incoming:#?}");
    assert_eq!(incoming[0]["sessionId"], receiver);
    // Routed like the `_acpmux/event` beside it: the chat id is the peer's.
    assert_eq!(incoming[0]["peer"], "remote", "{incoming:#?}");
    assert_eq!(incoming[0]["sender"]["sessionId"], sender);
    assert_eq!(incoming[0]["text"], "message across the peer");
    if with_peer_token {
        assert!(incoming[0]["sender"].get("host").is_none(), "sender host leaked: {incoming:#?}");
    }

    let outgoing = client.replay_messages("session/load", &format!("remote/{sender}")).await;
    assert_eq!(outgoing.len(), 1, "{outgoing:#?}");
    assert_eq!(outgoing[0]["sessionId"], sender);
    assert_eq!(outgoing[0]["peer"], "remote", "{outgoing:#?}");
    assert_eq!(outgoing[0]["sender"]["sessionId"], sender);
    assert_eq!(outgoing[0]["text"], "message across the peer");
    if with_peer_token {
        assert!(outgoing[0]["sender"].get("host").is_none(), "sender host leaked: {outgoing:#?}");
    }

    // Reopening each mirrored chat replays the same projections.
    assert_eq!(
        client.replay_messages("session/load", &format!("remote/{receiver}")).await,
        incoming
    );
    assert_eq!(client.replay_messages("session/load", &format!("remote/{sender}")).await, outgoing);
    // Another viewer's reopen replays over the link both share: a viewer that heard the
    // message hears it no more. A later message is the marker: anything repeated would come
    // before it.
    let mut other = Client::new(&local);
    let heard = other.replay_messages("session/load", &format!("remote/{receiver}")).await;
    assert_eq!(heard, incoming);
    assert_eq!(
        client.replay_messages("session/load", &format!("remote/{receiver}")).await,
        incoming
    );
    sender_agent.prompt(&receiver, "the marker").await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let line = tokio::time::timeout_at(deadline, other.rx.recv())
            .await
            .expect("the marker reached the other viewer")
            .expect("connection closed");
        let note: Value = serde_json::from_str(&line).unwrap();
        if note["method"] == "_acpmux/message" && note["params"]["sessionId"] == receiver {
            assert_eq!(note["params"]["text"], "the marker", "a repeated notice: {note}");
            break;
        }
    }

    std::fs::remove_dir_all(root).unwrap();
}
