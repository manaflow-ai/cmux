//! The mesh relay as a transport under the outbox (`outbox.rs`, `mesh_send.rs` `relay`): a send
//! to a session on a peer whose link is down is kept here and, once an attempt fails as not
//! sent, reaches the hub by that session's id; what the relay cannot carry, a hub that does not
//! take it and a delivery that may have reached the peer stay in the outbox.

use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt, Target,
};
use futures::future::BoxFuture;
use std::sync::Mutex;
use std::sync::atomic::Ordering::SeqCst;

/// The id huge-blue's last list gave its session `lane`.
const LANE: &str = "0190f2a4-7c1e-7d3a-9f00-0123456789ab";

#[derive(Default)]
struct FakeHub {
    sent: Mutex<Vec<OutMessage>>,
    /// Every send is refused as a name the hub does not know.
    unknown: std::sync::atomic::AtomicBool,
    /// How many more sends the hub keeps but whose answer is lost on the way back.
    lose: std::sync::atomic::AtomicUsize,
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
        Box::pin(async { Ok(HeartbeatReply { daemon_id: "inst_a".into(), ttl_seconds: 90 }) })
    }

    fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.sent.lock().unwrap().push(message.clone());
        Box::pin(async move {
            if self.unknown.load(SeqCst) {
                let mut e = HubError::refused("no such recipient");
                e.code = Some("mesh.unknown_recipient".into());
                return Err(e);
            }
            let lose = &self.lose;
            if lose.fetch_update(SeqCst, SeqCst, |n| n.checked_sub(1)).is_ok() {
                return Err(HubError::unavailable("the connection reset"));
            }
            Ok(receipt("queued", message.to.clone()))
        })
    }

    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        let to = self.sent.lock().unwrap().last().map(|m| m.to.clone()).unwrap_or_default();
        Box::pin(async move { Ok(receipt("delivered", to)) })
    }
}

fn receipt(state: &str, to: Target) -> Receipt {
    let mut receipt: Receipt = serde_json::from_value(json!({
        "messageId": "msg_00000000000000000000000000000001", "state": state, "createdAt": 1000
    }))
    .unwrap();
    receipt.to = to;
    receipt
}

/// This daemon with the relay on, and huge-blue a peer that is down after it listed `lane`.
fn setup(fake: FakeHub) -> (Arc<Hub>, Arc<FakeHub>) {
    let (hub, fake, _) = setup_peer(fake);
    (hub, fake)
}

/// [`setup`], and the peer that is down.
fn setup_peer(fake: FakeHub) -> (Arc<Hub>, Arc<FakeHub>, Arc<crate::peer::Peer>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let row = json!({"sessionId": LANE, "name": "lane", "status": "idle", "turnCount": 1,
                     "updatedAt": 5});
    let peer = hub.seed_down_peer("huge-blue", vec![row]);
    let fake = Arc::new(fake);
    assert!(hub.mesh.set(fake.clone()).is_ok());
    (hub, fake, peer)
}

/// `m` with `params` on a new unix-socket connection to `hub`: its result, or its error.
async fn call(hub: &Arc<Hub>, m: &str, params: Value) -> Result<Value, Value> {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    for line in [Message::request(1, method::INITIALIZE, hello), Message::request(2, m, params)] {
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

fn request(target: &str, prompt_id: &str) -> Value {
    json!({"request": {
        "sessionId": target,
        "prompt": [{"type": "text", "text": "from a lane VM"}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    }})
}

/// The delivery once its attempt `n` has settled what it does next.
async fn after_attempt(hub: &Arc<Hub>, id: &str, n: u32) -> Delivery {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let changed = hub.outbox.changed.notified();
        let d = hub.outbox.get(id).unwrap();
        if d.attempts >= n && d.state != State::Delivering {
            return d;
        }
        assert!(tokio::time::timeout_at(deadline, changed).await.is_ok(), "no attempt: {d:?}");
    }
}

/// Whether `d` records no relay post the hub may hold.
fn no_relay_post(d: &Delivery) -> bool {
    d.relay_post.is_none()
}

async fn queue(hub: &Arc<Hub>, params: Value) -> String {
    let queued = call(hub, method::MUX_SEND_QUEUE, params).await.unwrap();
    let id = queued["deliveryId"].as_str().unwrap().to_owned();
    assert!(!id.starts_with(super::super::mesh_send::PREFIX), "kept in the outbox: {queued}");
    id
}

#[tokio::test]
async fn a_send_to_a_down_peers_session_is_kept_here_and_relayed_by_its_session_id() {
    let (hub, fake) = setup(FakeHub::default());
    for (n, target) in ["huge-blue/lane", &format!("huge-blue/{LANE}")].into_iter().enumerate() {
        let id = queue(&hub, request(target, &format!("prompt-relay-{n}"))).await;
        let d = after_attempt(&hub, &id, 1).await;
        assert_eq!(d.state, State::Delivered, "{d:?}");
        assert_eq!(d.accepted.as_ref().unwrap()["via"], "mesh", "{d:?}");
        let to = fake.sent.lock().unwrap().last().unwrap().to.clone();
        assert_eq!(to.session_id.as_deref(), Some(LANE), "{target}: {to:?}");
        // By its id alone: the hub knows the peer's host by its own machine name.
        assert_eq!((to.host.as_deref(), to.name.as_deref()), (None, None), "{to:?}");
        // Its status is the hub's receipt, under the outbox's delivery id.
        let status = call(&hub, method::MUX_SEND_STATUS, json!({"deliveryId": id})).await.unwrap();
        assert_eq!(status["deliveryId"], json!(id), "{status}");
        assert_eq!(status["status"], "delivered", "{status}");
        assert_eq!(status["target"], json!(target), "{status}");
        // What `acpmux send` reads of an acceptance.
        assert_eq!(status["accepted"]["sessionId"], LANE, "{status}");
        assert_eq!(status["accepted"]["steer"], false, "{status}");
    }
    // A key the peer never listed: an id stays an id, a name a name.
    let other = "0190f2a4-7c1e-7d3a-9f00-00000000beef";
    let id = queue(&hub, request(&format!("huge-blue/{other}"), "prompt-relay-unlisted")).await;
    after_attempt(&hub, &id, 1).await;
    let to = fake.sent.lock().unwrap().last().unwrap().to.clone();
    assert_eq!((to.session_id.as_deref(), to.name.as_deref()), (Some(other), None), "{to:?}");
    let id = queue(&hub, request("huge-blue/other", "prompt-relay-named")).await;
    after_attempt(&hub, &id, 1).await;
    let to = fake.sent.lock().unwrap().last().unwrap().to.clone();
    assert_eq!((to.session_id.as_deref(), to.name.as_deref()), (None, Some("other")), "{to:?}");
    assert_eq!(to.host.as_deref(), Some("huge-blue"), "{to:?}");
}

#[tokio::test]
async fn what_the_relay_cannot_carry_or_the_hub_does_not_take_stays_queued_for_the_peer() {
    let (hub, fake) = setup(FakeHub::default());
    let shot = crate::attach::block("shot.png", b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR");
    let mut attached = request("huge-blue/lane", "prompt-keep-attach");
    attached["request"]["prompt"] = json!([{"type": "text", "text": "see this"}, shot]);
    let mut keyed = request("huge-blue/lane", "prompt-keep-supersede");
    keyed["request"]["_meta"]["acpmux"]["supersede"] = json!("status");
    let mut classed = request("huge-blue/lane", "prompt-keep-class");
    classed["request"]["_meta"]["acpmux"]["class"] = json!("block");
    for params in [attached, keyed, classed] {
        let id = queue(&hub, params).await;
        let d = after_attempt(&hub, &id, 1).await;
        assert_eq!(d.state, State::Queued, "tried again later: {d:?}");
        assert!(d.error.as_deref().is_some_and(|e| e.starts_with("peer_unreachable")), "{d:?}");
    }
    assert!(fake.sent.lock().unwrap().is_empty(), "the relay was asked to carry them");

    // A hub that does not take it: kept, and the error says both.
    let (hub, fake) = setup(FakeHub { unknown: true.into(), ..FakeHub::default() });
    let id = queue(&hub, request("huge-blue/lane", "prompt-keep-unknown")).await;
    let d = after_attempt(&hub, &id, 1).await;
    assert_eq!(d.state, State::Queued, "{d:?}");
    assert!(d.never_sent, "{d:?}");
    assert!(d.error.as_deref().is_some_and(|e| e.contains("mesh relay did not take it")), "{d:?}");
    assert_eq!(fake.sent.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_delivery_that_may_have_reached_the_peer_is_never_relayed() {
    let (hub, fake) = setup(FakeHub::default());
    let now = crate::store::now_ms();
    // Saved before `neverSent`, or after an attempt that went out: the peer may have run it.
    let saved = hub.outbox.add(Delivery {
        id: "d-reached".into(),
        target: "huge-blue/lane".into(),
        request: request("huge-blue/lane", "prompt-reached")["request"].clone(),
        caller: None,
        state: State::Queued,
        attempts: 1,
        never_sent: false,
        relay_post: None,
        error: Some("peer disconnected".into()),
        accepted: None,
        created_at: now,
        updated_at: now,
    });
    resume(&hub, vec![saved]);
    let d = after_attempt(&hub, "d-reached", 2).await;
    assert_eq!(d.state, State::Queued, "{d:?}");
    assert!(!d.never_sent, "{d:?}");
    assert!(fake.sent.lock().unwrap().is_empty(), "relayed a delivery the peer may have run");
}

#[tokio::test]
async fn a_relay_post_whose_answer_was_lost_is_tried_again_only_through_the_relay() {
    let fake = FakeHub { lose: 1.into(), ..FakeHub::default() };
    let (hub, fake, peer) = setup_peer(fake);
    let id = queue(&hub, request("huge-blue/lane", "prompt-lost-answer")).await;
    let d = after_attempt(&hub, &id, 1).await;
    assert_eq!(d.state, State::Queued, "{d:?}");
    let posted = d.relay_post.as_ref().and_then(|m| m.to.session_id.as_deref());
    assert_eq!(posted, Some(LANE), "{d:?}");
    // The peer's link comes back: the hub may hold the message, so the link must not run it too.
    peer.connected.store(true, SeqCst);
    let d = after_attempt(&hub, &id, 2).await;
    assert_eq!(d.state, State::Delivered, "{d:?}");
    assert_eq!(d.accepted.as_ref().unwrap()["via"], "mesh", "{d:?}");
    let sent = fake.sent.lock().unwrap().clone();
    assert_eq!(sent.len(), 2, "{sent:?}");
    assert_eq!(sent[0].idempotency_key, sent[1].idempotency_key, "the same message again");
    assert_eq!(sent[1].to, sent[0].to, "{sent:?}");
}

#[tokio::test]
async fn a_hub_that_refuses_the_retry_of_a_lost_post_holds_nothing_and_the_peer_link_takes_it_back()
{
    let fake = FakeHub { lose: 1.into(), ..FakeHub::default() };
    let (hub, fake) = setup(fake);
    let id = queue(&hub, request("huge-blue/lane", "prompt-lost-refused")).await;
    let d = after_attempt(&hub, &id, 1).await;
    assert_eq!(d.state, State::Queued, "{d:?}");
    // The hub checks the key before the recipient: a refusal of the same key means it kept none.
    fake.unknown.store(true, SeqCst);
    let d = after_attempt(&hub, &id, 2).await;
    assert_eq!(d.state, State::Queued, "the peer is tried again: {d:?}");
    assert!(d.never_sent, "{d:?}");
    assert!(no_relay_post(&d), "the peer's link may take it back: {d:?}");
    assert!(d.error.as_deref().is_some_and(|e| e.contains("mesh relay did not take it")), "{d:?}");
}

#[test]
fn an_attempt_on_the_peer_link_is_saved_as_maybe_sent_until_the_link_refuses_it() {
    let now = crate::store::now_ms();
    let mut d = Delivery {
        id: "d-running".into(),
        target: "huge-blue/lane".into(),
        request: request("huge-blue/lane", "prompt-running")["request"].clone(),
        caller: None,
        state: State::Queued,
        attempts: 0,
        never_sent: true,
        relay_post: None,
        error: None,
        accepted: None,
        created_at: now,
        updated_at: now,
    };
    // A restart that finds it Delivering cannot know whether the frame went out: never relayed.
    start_attempt(&mut d, 1);
    assert_eq!(d.state, State::Delivering);
    assert!(!d.never_sent, "a crash mid-attempt could relay what the peer may run: {d:?}");
}
