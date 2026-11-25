//! Detector for a message lost to a dead session (cmuxterm-hq
//! `docs/handbook/lost-message-to-dead-session.md`; Leo, 2026-11-24: "well clearly we need to
//! have better listeners/scheduling to make sure those messages are recievable").
//!
//! Before: a send to `HOST/NAME` on a peer that was down answered "queued", was relayed to the
//! mesh hub later, refused there as unknown four times and failed, and its sender never heard.
//! Now each of the three sends that failed that way reaches a live session or is refused in the
//! sender's own call: a dead name, a renamed name (a session that took it over), and a role
//! address (`goal:SLUG`). One that cannot be checked is queued saying so, and if it fails it is a
//! dead letter.

use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::{
    Ack, AddressBook, BookDaemon, BookSession, Heartbeat, HeartbeatReply, HubError, InMessage,
    MeshHub, OutMessage, Receipt,
};
use futures::future::BoxFuture;
use std::sync::Mutex;

/// A hub whose address book is `book` and which takes every post.
struct BookHub {
    book: AddressBook,
    posts: Mutex<Vec<OutMessage>>,
}

impl MeshHub for BookHub {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async { Ok(Vec::new()) })
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Ok(()) })
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        Box::pin(async { Ok(HeartbeatReply { daemon_id: "inst_a".into(), ttl_seconds: 90 }) })
    }

    fn sessions(&self) -> BoxFuture<'_, Result<AddressBook, HubError>> {
        let book = self.book.clone();
        Box::pin(async move { Ok(book) })
    }

    fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.posts.lock().unwrap().push(message.clone());
        let mut receipt: Receipt = serde_json::from_value(json!({
            "messageId": "msg_00000000000000000000000000000001", "state": "queued",
            "createdAt": 1000
        }))
        .unwrap();
        receipt.to = message.to.clone();
        Box::pin(async move { Ok(receipt) })
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        let receipt: Receipt =
            serde_json::from_value(json!({"messageId": id, "state": "delivered", "createdAt": 1}))
                .unwrap();
        Box::pin(async move { Ok(receipt) })
    }
}

fn session(host: &str, name: &str, former: &[&str]) -> BookSession {
    BookSession {
        name: name.into(),
        session_id: format!("id-{name}"),
        host: host.into(),
        former_names: former.iter().map(|n| (*n).to_owned()).collect(),
        ..BookSession::default()
    }
}

/// A hub with the mesh on, the address book `book`, and peers `down` it has links to that are
/// all down.
fn setup(book: AddressBook, down: &[&str]) -> (Arc<Hub>, Arc<BookHub>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let stub = Arc::new(BookHub { book, posts: Mutex::default() });
    hub.mesh.set(stub.clone());
    for name in down {
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert((*name).to_owned(), peer);
    }
    (hub, stub)
}

fn chat(hub: &Hub, id: &str, name: &str) -> Arc<crate::hub::Session> {
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name, "harness": "pi",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.insert_test_session(meta)
}

fn send(target: &str) -> Value {
    json!({"request": {
        "sessionId": target,
        "prompt": [{"type": "text", "text": "the CI pool is yours"}],
    }})
}

async fn call(hub: &Arc<Hub>, params: Value) -> Result<Value, Value> {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    let lines = [
        Message::request(1, method::INITIALIZE, hello),
        Message::request(2, method::MUX_SEND_QUEUE, params),
    ];
    for line in lines {
        input.send(line.to_line()).await.unwrap();
    }
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), outgoing.recv()).await;
        let reply: Value = serde_json::from_str(&line.unwrap().unwrap()).unwrap();
        if reply.get("id") == Some(&json!(2)) {
            return match reply.get("error") {
                Some(e) => Err(e.clone()),
                None => Ok(reply["result"].clone()),
            };
        }
    }
}

fn live(hosts: &[&str], sessions: Vec<BookSession>) -> AddressBook {
    AddressBook {
        daemons: hosts
            .iter()
            .map(|h| BookDaemon { host: (*h).into(), ..BookDaemon::default() })
            .collect(),
        sessions,
    }
}

#[tokio::test]
async fn a_dead_name_on_a_down_peer_is_refused_in_the_call() {
    // The peer's link here is down, but the hub lists its host live, without the name.
    let (hub, stub) = setup(live(&["far"], vec![session("far", "other", &[])]), &["far"]);
    let e = call(&hub, send("far/goal-ci-a-2")).await.unwrap_err();
    assert!(e["message"].as_str().unwrap().starts_with("no session: far/goal-ci-a-2"), "{e}");
    assert_eq!(e["data"]["reason"], "send.no_session");
    assert!(stub.posts.lock().unwrap().is_empty(), "nothing queued, nothing posted");
    assert!(hub.outbox.list(None, 10).0.is_empty(), "nothing kept");
}

#[tokio::test]
async fn a_renamed_name_reaches_the_session_that_took_it_over() {
    // The session restarted under a new name on another host and recorded the old one.
    let book = live(&["near"], vec![session("near", "goal-ci-240936", &["far/goal-ci-a-2"])]);
    let (hub, stub) = setup(book, &["far"]);
    call(&hub, send("far/goal-ci-a-2")).await.unwrap();
    let posts = stub.posts.lock().unwrap();
    assert_eq!(posts.len(), 1, "posted to the heir through the hub");
    assert_eq!(posts[0].to.name.as_deref(), Some("goal-ci-240936"));
    assert_eq!(posts[0].to.host.as_deref(), Some("near"));
}

#[tokio::test]
async fn a_dead_name_taken_over_here_goes_to_the_session_here() {
    let (hub, _stub) = setup(live(&[], vec![]), &["far"]);
    let heir = chat(&hub, "s-heir", "goal-ci-240936");
    hub.succeed(&heir, &["far/goal-ci-a-2".to_owned()]).unwrap();
    let sent = call(&hub, send("far/goal-ci-a-2")).await.unwrap();
    assert_eq!(sent["target"], "s-heir", "{sent}");
    assert_eq!(sent["redirectedFrom"], "far/goal-ci-a-2");
}

#[tokio::test]
async fn a_role_address_reaches_its_holder() {
    let (hub, _stub) = setup(live(&[], vec![]), &[]);
    let owner = chat(&hub, "s-owner", "goal-ci-240936");
    hub.claim_role(&owner, "goal:ci-linux-on-pool").unwrap();
    let sent = call(&hub, send("goal:ci-linux-on-pool")).await.unwrap();
    assert_eq!(sent["target"], "s-owner", "{sent}");
    assert_eq!(sent["redirectedFrom"], "goal:ci-linux-on-pool");
}

#[tokio::test]
async fn an_unchecked_send_says_so_and_its_failure_is_a_dead_letter() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-dl");
    // The hub lists no daemon for the host: it may come back, so the send is kept, unchecked.
    let (hub, _stub) = setup(live(&[], vec![]), &["far"]);
    hub.outbox.open(&dir.path().join("outbox.json"));
    hub.start_bounces();
    let sent = call(&hub, send("far/asleep")).await.unwrap();
    assert_eq!(sent["recipientChecked"], false, "{sent}");
    assert!(sent["recipientNote"].as_str().unwrap().starts_with("not checked"));
    let id = sent["deliveryId"].as_str().unwrap().to_owned();
    hub.outbox.update(&id, |d| {
        d.state = crate::hub::outbox::State::Failed;
        d.error = Some("failed attempt 4: the hub answered 404 mesh.unknown_recipient".into());
    });
    let path = dir.path().join(crate::hub::dead_letters::FILE);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let text = loop {
        if let Ok(text) = std::fs::read_to_string(&path)
            && !text.is_empty()
        {
            break text;
        }
        assert!(tokio::time::Instant::now() < deadline, "no dead letter");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let line: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    assert_eq!(line["deliveryId"], id);
    assert_eq!(line["target"], "far/asleep");
    assert!(line["reason"].as_str().unwrap().contains("unknown_recipient"));
    assert_eq!(line["text"], "the CI pool is yours");
}
