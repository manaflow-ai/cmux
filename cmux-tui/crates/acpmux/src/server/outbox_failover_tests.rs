//! A send to a session on a peer whose link is down fails over to the mesh relay only when the
//! relay can carry it as asked; anything else stays in the durable local outbox (#27590).

use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt,
};
use futures::future::BoxFuture;
use std::sync::Mutex;
use std::time::Duration;
use tokio::sync::mpsc;

/// What the fake hub answers a send with.
#[derive(Clone, Copy, PartialEq)]
enum Answer {
    Take,
    Unknown,
    /// No connection: the request never reached the hub.
    Down,
    /// The answer was lost after the request went out: the hub may have taken it.
    Lost,
}

/// A hub that answers its sends in turn, the last answer again once the list runs out.
struct FakeHub {
    answers: Vec<Answer>,
    sent: Mutex<Vec<OutMessage>>,
}

impl MeshHub for FakeHub {
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
        Box::pin(async { Ok(HeartbeatReply { daemon_id: "inst".into(), ttl_seconds: 90 }) })
    }

    fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        let mut sent = self.sent.lock().unwrap();
        sent.push(message.clone());
        let answer = self.answers[(sent.len() - 1).min(self.answers.len() - 1)];
        drop(sent);
        Box::pin(async move {
            match answer {
                Answer::Take => Ok(serde_json::from_value(json!({
                    "messageId": "msg_00000000000000000000000000000001", "state": "queued",
                    "to": {}, "createdAt": 1000
                }))
                .unwrap()),
                Answer::Unknown => {
                    let mut e = HubError::refused("no such recipient");
                    e.code = Some("mesh.unknown_recipient".into());
                    Err(e)
                }
                Answer::Down => Err(HubError { unsent: true, ..HubError::unavailable("no route") }),
                Answer::Lost => Err(HubError::unavailable("the answer timed out")),
            }
        })
    }

    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { Err(HubError::unavailable("unused")) })
    }
}

/// A daemon with the relay on and peer `box` down, whose last list had session `m1`, "lane".
fn setup(answers: &[Answer]) -> (Arc<Hub>, Arc<FakeHub>) {
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "turnCount": 1, "updatedAt": 5});
    setup_rows(answers, vec![row])
}

fn setup_rows(answers: &[Answer], rows: Vec<Value>) -> (Arc<Hub>, Arc<FakeHub>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    hub.seed_down_peer("box", rows);
    let fake = Arc::new(FakeHub { answers: answers.to_vec(), sent: Mutex::new(Vec::new()) });
    assert!(hub.mesh.set(fake.clone()).is_ok());
    (hub, fake)
}

async fn send_queue(hub: &Arc<Hub>, request: Value) -> Value {
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    input
        .send(Message::request(1, method::MUX_SEND_QUEUE, json!({"request": request})).to_line())
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let response: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if response["id"] == 1 {
                return response;
            }
        }
    })
    .await
    .unwrap()
}

fn text(target: &str, prompt_id: &str) -> Value {
    json!({
        "sessionId": target,
        "prompt": [{"type": "text", "text": "hello"}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    })
}

fn delivery(reply: &Value) -> &str {
    reply.pointer("/result/deliveryId").and_then(Value::as_str).unwrap_or_else(|| panic!("{reply}"))
}

#[tokio::test]
async fn a_text_send_to_a_down_peer_goes_through_the_relay_only_by_the_sessions_name() {
    let (hub, fake) = setup(&[Answer::Take]);
    let by_name = send_queue(&hub, text("box/lane", "prompt-0001")).await;
    assert!(delivery(&by_name).starts_with("mesh:"), "{by_name}");
    // By id: the relay addresses sessions by name, and a name can pass to another session while
    // the link is down, so a send that named one session by its id waits for the link.
    let by_id = send_queue(&hub, text("box/m1", "prompt-0002")).await;
    assert!(!delivery(&by_id).starts_with("mesh:"), "{by_id}");
    let to: Vec<_> =
        fake.sent.lock().unwrap().iter().map(|m| (m.to.host.clone(), m.to.name.clone())).collect();
    assert_eq!(to, vec![(Some("box".to_owned()), Some("lane".to_owned()))]);
}

/// Review of #27590 at f2c910b7: `box/m` names session `m123` by its id prefix as well as by its
/// name `m`. Relayed by name, it could reach another session the name passes to.
#[tokio::test]
async fn a_target_that_names_a_session_by_its_id_prefix_is_never_relayed_by_name() {
    let row = json!({"sessionId": "m123", "name": "m", "status": "idle", "turnCount": 1, "updatedAt": 5});
    let (hub, fake) = setup_rows(&[Answer::Take], vec![row]);
    let reply = send_queue(&hub, text("box/m", "prompt-0001")).await;
    assert!(!delivery(&reply).starts_with("mesh:"), "{reply}");
    assert!(fake.sent.lock().unwrap().is_empty());
}

#[tokio::test]
async fn what_the_relay_cannot_carry_stays_in_the_local_outbox() {
    let (hub, fake) = setup(&[Answer::Take]);
    let mut attached = text("box/lane", "prompt-0003");
    attached["prompt"]
        .as_array_mut()
        .unwrap()
        .push(json!({"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}));
    let mut keyed = text("box/lane", "prompt-0004");
    keyed["_meta"]["acpmux"]["supersede"] = json!("status");
    let mut classed = text("box/lane", "prompt-0005");
    classed["_meta"]["acpmux"]["class"] = json!("block");
    for request in [attached, keyed, classed] {
        let reply = send_queue(&hub, request).await;
        assert!(!delivery(&reply).starts_with("mesh:"), "{reply}");
    }
    assert!(fake.sent.lock().unwrap().is_empty(), "the relay was asked to carry them");
}

#[tokio::test]
async fn a_relay_that_refuses_or_is_down_leaves_the_send_in_the_local_outbox() {
    for answer in [Answer::Unknown, Answer::Down] {
        let (hub, fake) = setup(&[answer]);
        let reply = send_queue(&hub, text("box/lane", "prompt-0006")).await;
        assert!(!delivery(&reply).starts_with("mesh:"), "{reply}");
        assert_eq!(fake.sent.lock().unwrap().len(), 1, "the relay was tried first");
    }
}

#[tokio::test]
async fn a_send_the_hub_may_have_taken_is_asked_again_under_its_key_and_never_kept_here() {
    // The answer was lost, then the hub answers the same key: that one message, no second copy.
    let (hub, fake) = setup(&[Answer::Lost, Answer::Take]);
    let reply = send_queue(&hub, text("box/lane", "prompt-0007")).await;
    assert!(delivery(&reply).starts_with("mesh:"), "{reply}");
    let keys: Vec<_> =
        fake.sent.lock().unwrap().iter().map(|m| m.idempotency_key.clone()).collect();
    assert_eq!(keys, vec!["prompt-0007".to_owned(); 2]);
    // With no prompt id, both asks still carry one key.
    let (hub, fake) = setup(&[Answer::Lost, Answer::Take]);
    let mut unnamed = text("box/lane", "");
    unnamed["_meta"]["acpmux"].as_object_mut().unwrap().remove("promptId");
    let reply = send_queue(&hub, unnamed).await;
    assert!(delivery(&reply).starts_with("mesh:"), "{reply}");
    let keys: Vec<_> =
        fake.sent.lock().unwrap().iter().map(|m| m.idempotency_key.clone()).collect();
    assert!(keys.len() == 2 && keys[0] == keys[1], "{keys:?}");
    // Lost, then refused or unreached: the first ask may still be stored, so it is the caller's
    // error too, never kept here.
    for second in [Answer::Down, Answer::Unknown] {
        let (hub, fake) = setup(&[Answer::Lost, second]);
        let reply = send_queue(&hub, text("box/lane", "prompt-0009")).await;
        assert!(reply.get("result").is_none(), "{reply}");
        assert_eq!(
            reply.pointer("/error/data/reason"),
            Some(&json!("mesh.unknown_outcome")),
            "{reply}"
        );
        assert_eq!(fake.sent.lock().unwrap().len(), 2);
    }
    // Lost twice: an error the caller sees, never a local copy that would run it a second time.
    let (hub, fake) = setup(&[Answer::Lost]);
    let reply = send_queue(&hub, text("box/lane", "prompt-0008")).await;
    assert!(reply.get("result").is_none(), "{reply}");
    assert_eq!(
        reply.pointer("/error/data/reason"),
        Some(&json!("mesh.unknown_outcome")),
        "{reply}"
    );
    assert_eq!(fake.sent.lock().unwrap().len(), 2);
}
