//! A send to a session on a peer whose link is down fails over to the mesh relay only when the
//! relay can carry it as asked; anything else stays in the durable local outbox (#27590).

use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::{Ack, Heartbeat, HeartbeatReply, HubError, InMessage, Receipt};
use futures::future::BoxFuture;
use std::sync::Mutex;
use std::time::Duration;
use tokio::sync::mpsc;

/// What the fake hub answers a send with.
#[derive(Clone, Copy, PartialEq)]
enum Answer {
    Take,
    Unknown,
    Down,
}

struct FakeHub {
    answer: Answer,
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
        self.sent.lock().unwrap().push(message.clone());
        let answer = self.answer;
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
                Answer::Down => Err(HubError::unavailable("the hub is down")),
            }
        })
    }

    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { Err(HubError::unavailable("unused")) })
    }
}

/// A daemon with the relay on and peer `box` down, whose last list had session `m1`, "lane".
fn setup(answer: Answer) -> (Arc<Hub>, Arc<FakeHub>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "turnCount": 1, "updatedAt": 5});
    hub.seed_down_peer("box", vec![row]);
    let fake = Arc::new(FakeHub { answer, sent: Mutex::new(Vec::new()) });
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
async fn a_text_send_to_a_down_peer_goes_through_the_relay_by_the_sessions_name() {
    let (hub, fake) = setup(Answer::Take);
    let by_name = send_queue(&hub, text("box/lane", "prompt-0001")).await;
    assert!(delivery(&by_name).starts_with("mesh:"), "{by_name}");
    // By id: the relay addresses sessions by name, so the id the cached row knows is turned into
    // that row's name, never sent as one.
    let by_id = send_queue(&hub, text("box/m1", "prompt-0002")).await;
    assert!(delivery(&by_id).starts_with("mesh:"), "{by_id}");
    let to: Vec<_> =
        fake.sent.lock().unwrap().iter().map(|m| (m.to.host.clone(), m.to.name.clone())).collect();
    let lane = (Some("box".to_owned()), Some("lane".to_owned()));
    assert_eq!(to, vec![lane.clone(), lane]);
}

#[tokio::test]
async fn what_the_relay_cannot_carry_stays_in_the_local_outbox() {
    let (hub, fake) = setup(Answer::Take);
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
        let (hub, fake) = setup(answer);
        let reply = send_queue(&hub, text("box/lane", "prompt-0006")).await;
        assert!(!delivery(&reply).starts_with("mesh:"), "{reply}");
        assert_eq!(fake.sent.lock().unwrap().len(), 1, "the relay was tried first");
    }
}
