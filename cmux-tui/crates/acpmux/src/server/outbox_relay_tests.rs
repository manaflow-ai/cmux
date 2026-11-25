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
    /// Until when every send is answered 529 with the hub's `retryAfterSeconds`, as an
    /// overloaded hub does.
    busy_until: Mutex<Option<(tokio::time::Instant, Duration)>>,
    /// When the hub took each post, and its key.
    taken: Mutex<Vec<(tokio::time::Instant, String)>>,
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
            let busy = *self.busy_until.lock().unwrap();
            if let Some((until, retry_after)) = busy
                && tokio::time::Instant::now() < until
            {
                let mut e = HubError::unavailable("overloaded");
                e.status = Some(529);
                e.retry_after = Some(retry_after);
                return Err(e);
            }
            let lose = &self.lose;
            if lose.fetch_update(SeqCst, SeqCst, |n| n.checked_sub(1)).is_ok() {
                return Err(HubError::unavailable("the connection reset"));
            }
            let key = message.idempotency_key.clone();
            self.taken.lock().unwrap().push((tokio::time::Instant::now(), key));
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
    hub.mesh.set(fake.clone());
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
    let saved = hub
        .outbox
        .add(Delivery {
            id: "d-reached".into(),
            target: "huge-blue/lane".into(),
            request: request("huge-blue/lane", "prompt-reached")["request"].clone(),
            caller: None,
            unproven_caller: None,
            not_terminal: false,
            state: State::Queued,
            attempts: 1,
            never_sent: false,
            resends: 0,
            resent_at: 0,
            relay_post: None,
            open_on_peer: false,
            pin: None,
            proof: None,
            error: Some("peer disconnected".into()),
            accepted: None,
            created_at: now,
            updated_at: now,
        })
        .unwrap();
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
        unproven_caller: None,
        not_terminal: false,
        state: State::Queued,
        attempts: 0,
        never_sent: true,
        resends: 0,
        resent_at: 0,
        relay_post: None,
        open_on_peer: false,
        pin: None,
        proof: None,
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

/// A delivery to a session of a peer that is down, which the relay cannot carry (an
/// attachment), after its first attempt: the pin it keeps.
async fn the_pin_of_an_attempt_that_reached_nothing(rules: u8) -> Option<crate::hub::outbox::Pin> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    hub.replay_rules(rules);
    let row = json!({"sessionId": LANE, "name": "lane", "status": "idle", "turnCount": 1,
                     "updatedAt": 5, "createdAt": 5});
    hub.seed_down_peer("huge-blue", vec![row]);
    assert!(hub.mesh.set(Arc::new(FakeHub::default())).is_none(), "no client before");
    let shot = crate::attach::block("shot.png", b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR");
    let mut attached = request("huge-blue/lane", "prompt-pin");
    attached["request"]["prompt"] = json!([{"type": "text", "text": "see this"}, shot]);
    let id = queue(&hub, attached).await;
    let d = after_attempt(&hub, &id, 1).await;
    assert_eq!(d.state, State::Queued, "{d:?}");
    assert!(d.never_sent, "{d:?}");
    d.pin
}

/// Review of #37284 at c4a6f4e7, F3: an attempt that reached nothing (the peer down, the relay
/// unable to carry it) keeps no pin, so the next one reads the session as the peer lists it
/// then: a session the peer made again meanwhile is the one it goes to, never failed as stale.
/// Under c4a6f4e7's rules it kept the generation it read before anything reached the peer.
#[tokio::test]
async fn an_attempt_that_reached_nothing_keeps_no_pin() {
    let old = the_pin_of_an_attempt_that_reached_nothing(crate::hub::journal_restore::AT_C4A6);
    assert_eq!(old.await.map(|p| p.generation), Some(5), "c4a6f4e7 kept it");
    assert_eq!(the_pin_of_an_attempt_that_reached_nothing(0).await, None);
}

/// A send whose record cannot be written is refused, so the sender knows to send it again, and
/// nothing of it is kept: no delivery from memory, no attachments beside the file.
#[tokio::test]
async fn a_send_whose_record_cannot_be_saved_is_refused_and_not_kept() {
    let (hub, fake) = setup(FakeHub::default());
    let dir = std::env::temp_dir().join(format!("outbox-not-saved-{}", uuid::Uuid::now_v7()));
    // Folders where `outbox.json` and its journal should be, made after the open (which sets
    // an unreadable file aside): their writes fail, also for root, while the attachments beside
    // them can still be written.
    let path = dir.join("outbox.json");
    std::fs::create_dir_all(&dir).unwrap();
    hub.outbox.open(&path);
    std::fs::create_dir_all(&path).unwrap();
    std::fs::create_dir_all(crate::hub::outbox::journal_path(&path)).unwrap();
    let shot = crate::attach::block("shot.png", b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR");
    let mut params = request("huge-blue/lane", "prompt-not-saved");
    params["request"]["prompt"] = json!([{"type": "text", "text": "see this"}, shot]);
    let error = call(&hub, method::MUX_SEND_QUEUE, params).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "outbox.not_saved", "{error}");
    assert_eq!(error["data"]["retryable"], true, "{error}");
    assert!(hub.outbox.list(None, 10).0.is_empty(), "kept in memory only");
    let kept: Vec<_> = std::fs::read_dir(dir.join("outbox-attachments"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .collect();
    assert!(kept.is_empty(), "attachments of a refused send are left: {kept:?}");
    assert!(fake.sent.lock().unwrap().is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
}

/// RFD 0124 R6: the sender can distinguish a full disk and retry the same prompt.
#[cfg(unix)]
#[tokio::test]
async fn an_outbox_enospc_answers_busy_disk_full() {
    let (hub, _) = setup(FakeHub::default());
    let dir = tempfile::tempdir().unwrap();
    hub.outbox.open(&dir.path().join("outbox.json"));
    *hub.outbox.next_write_error.lock().unwrap() =
        Some(std::io::Error::from_raw_os_error(libc::ENOSPC));

    let params = request("huge-blue/lane", "retry-after-enospc");
    let error = call(&hub, method::MUX_SEND_QUEUE, params.clone()).await.unwrap_err();
    assert_eq!(error["code"], crate::rpc::BUSY_CODE);
    assert_eq!(error["data"]["reason"], "disk_full");
    assert_eq!(error["data"]["retryable"], true);
    assert!(hub.outbox.list(None, 10).0.is_empty());

    let daemon = crate::client::DaemonError(serde_json::from_value(error).unwrap());
    let envelope = crate::cli::errors::classify(&daemon.into()).envelope();
    assert_eq!(envelope["error"]["code"], "busy");
    assert_eq!(envelope["error"]["detail"], "disk_full");
    assert_eq!(envelope["error"]["retryable"], true);

    let queued = call(&hub, method::MUX_SEND_QUEUE, params).await.unwrap();
    assert!(queued["deliveryId"].is_string(), "{queued}");
}

/// Another peer's link coming back (`peer_ready` is one signal for every peer) does not end the
/// wait of a message whose own peer is still down: the retry sleeps out its delay instead of
/// trying again, and writing its journal, once per other peer's reconnect.
#[tokio::test(start_paused = true)]
async fn another_peers_ready_leaves_a_down_targets_retry_waiting() {
    let (hub, _fake) = setup(FakeHub { unknown: true.into(), ..FakeHub::default() });
    let fired = {
        let hub = hub.clone();
        tokio::spawn(async move {
            loop {
                let changed = hub.outbox.changed.notified();
                let running = hub.outbox.list(None, 10).0;
                if running.iter().any(|d| d.attempts == 1 && d.state == State::Delivering) {
                    for _ in 0..50 {
                        hub.outbox.peer_ready.notify_waiters();
                        tokio::task::yield_now().await;
                    }
                    return tokio::time::Instant::now();
                }
                changed.await;
            }
        })
    };
    let id = queue(&hub, request("huge-blue/lane", "prompt-other-peer-ready")).await;
    let fired = fired.await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        let changed = hub.outbox.changed.notified();
        if hub.outbox.get(&id).unwrap().attempts >= 2 {
            break;
        }
        assert!(tokio::time::timeout_at(deadline, changed).await.is_ok(), "no attempt 2");
    }
    let waited = fired.elapsed();
    assert!(
        waited >= Duration::from_secs(RETRY_DELAYS_SECS[0]) - Duration::from_millis(100),
        "attempt 2 came {waited:?} after 50 other peers' ready signals, its own peer still down"
    );
}

/// Review of #53719, F1: a delivery whose own peer is up (its last attempt failed unsent without
/// an outage) waits its own delay when another peer's link comes back; before, `peer_down_for`
/// answered "not down" and every such delivery went again on each ready anywhere.
#[tokio::test(start_paused = true)]
async fn another_peers_ready_leaves_an_up_targets_retry_waiting() {
    let (hub, _fake, peer) = setup_peer(FakeHub { unknown: true.into(), ..FakeHub::default() });
    let id = queue(&hub, request("huge-blue/lane", "prompt-up-other-peer-ready")).await;
    let d = after_attempt(&hub, &id, 1).await;
    assert_eq!(d.state, State::Queued, "{d:?}");
    // Its own peer is up now, its count unchanged: no ready of its own came.
    peer.connected.store(true, SeqCst);
    let fired = tokio::time::Instant::now();
    for _ in 0..50 {
        hub.outbox.note_peer_ready("elsewhere");
        tokio::task::yield_now().await;
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        let changed = hub.outbox.changed.notified();
        if hub.outbox.get(&id).unwrap().attempts >= 2 {
            break;
        }
        assert!(tokio::time::timeout_at(deadline, changed).await.is_ok(), "no attempt 2");
    }
    let waited = fired.elapsed();
    assert!(
        waited >= Duration::from_secs(RETRY_DELAYS_SECS[0]) - Duration::from_millis(100),
        "attempt 2 came {waited:?} after 50 other peers' ready signals"
    );
}

/// Review of #53719, F1: only a target's own peer's ready is its own. A target naming a peer
/// this daemon does not know waits until that peer's link is ready; one naming no peer never
/// wakes on a ready.
#[test]
fn a_ready_is_only_its_own_peers() {
    let outbox = crate::hub::outbox::Outbox::default();
    let unknown = own_ready_count(&outbox, "ghost/lane");
    assert_eq!(unknown, Some(("ghost".to_owned(), 0)));
    for target in ["lane", "/lane", "ghost/"] {
        assert_eq!(own_ready_count(&outbox, target), None, "{target}");
    }
    assert!(!own_ready_since(&outbox, None));
    outbox.note_peer_ready("elsewhere");
    outbox.peer_ready.notify_waiters();
    assert!(!own_ready_since(&outbox, unknown.as_ref()), "another peer's ready");
    outbox.note_peer_ready("ghost");
    assert!(own_ready_since(&outbox, unknown.as_ref()), "its own peer's ready");
    assert_eq!(outbox.peer_ready_count("ghost"), 1);
}

/// A peer whose link is ready again while an attempt runs (before its failure is saved) ends
/// the wait for the next one: the retry does not sleep out its delay with the peer up.
#[tokio::test(start_paused = true)]
async fn a_peer_ready_during_an_attempt_ends_the_retry_wait() {
    let (hub, _fake, peer) = setup_peer(FakeHub { unknown: true.into(), ..FakeHub::default() });
    // The moment attempt 1 starts, a `peer_ready` fires with this target still down (another
    // peer's link): it alone does not end the wait. Once attempt 1 settles, this target's link
    // comes back as a reconnect does (`peer_runtime_io` marks the link connected, then sends
    // `PeerNotice::Connected`), and that ends it.
    let mid = {
        let hub = hub.clone();
        tokio::spawn(async move {
            loop {
                let changed = hub.outbox.changed.notified();
                let running = hub.outbox.list(None, 10).0;
                if running.iter().any(|d| d.attempts == 1 && d.state == State::Delivering) {
                    hub.outbox.peer_ready.notify_waiters();
                    return;
                }
                changed.await;
            }
        })
    };
    let id = queue(&hub, request("huge-blue/lane", "prompt-ready-mid-attempt")).await;
    mid.await.unwrap();
    let d = after_attempt(&hub, &id, 1).await;
    assert_eq!(d.state, State::Queued, "{d:?}");
    let fired = tokio::time::Instant::now();
    peer.connected.store(true, std::sync::atomic::Ordering::SeqCst);
    hub.outbox.note_peer_ready("huge-blue");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        let changed = hub.outbox.changed.notified();
        if hub.outbox.get(&id).unwrap().attempts >= 2 {
            break;
        }
        assert!(tokio::time::timeout_at(deadline, changed).await.is_ok(), "no attempt 2");
    }
    let waited = fired.elapsed();
    assert!(
        waited < Duration::from_secs(RETRY_DELAYS_SECS[0]),
        "attempt 2 waited {waited:?} with the peer ready"
    );
}

/// Twenty sends queued while the hub answers 529 for one window (its `retryAfterSeconds`): they
/// wait behind its gate, not each on its own back-off, and all go once one probe gets through,
/// within that one window. A send repeated under the same prompt id goes once.
#[tokio::test(start_paused = true)]
async fn twenty_sends_refused_for_one_window_drain_together_when_it_ends() {
    const WINDOW: Duration = Duration::from_secs(30);
    let fake = FakeHub::default();
    let start = tokio::time::Instant::now();
    *fake.busy_until.lock().unwrap() = Some((start + WINDOW, WINDOW));
    let (hub, fake) = setup(fake);
    let mut ids = Vec::new();
    for n in 0..20 {
        let id =
            queue(&hub, request(&format!("huge-blue/drain-{n}"), &format!("p-drain-{n}"))).await;
        ids.push(id);
    }
    // The same prompt again: the delivery already queued, not a second post.
    let again = queue(&hub, request("huge-blue/drain-3", "p-drain-3")).await;
    assert_eq!(again, ids[3]);
    let deadline = start + Duration::from_secs(3_600);
    loop {
        let changed = hub.outbox.changed.notified();
        if ids.iter().all(|id| hub.outbox.get(id).is_some_and(|d| d.state == State::Delivered)) {
            break;
        }
        assert!(tokio::time::timeout_at(deadline, changed).await.is_ok(), "not all delivered");
    }
    let taken = fake.taken.lock().unwrap().clone();
    let last = taken.iter().map(|(at, _)| *at).max().unwrap();
    let drain = last.duration_since(start);
    let first = taken.iter().map(|(at, _)| *at).min().unwrap();
    eprintln!(
        "drain of 20 queued sends after one refused window of {}s: {:.2}s (first taken {:.2}s)",
        WINDOW.as_secs(),
        drain.as_secs_f64(),
        first.duration_since(start).as_secs_f64(),
    );
    let mut keys: Vec<_> = taken.iter().map(|(_, k)| k.clone()).collect();
    keys.sort();
    keys.dedup();
    assert_eq!((taken.len(), keys.len()), (20, 20), "each once: {taken:?}");
    assert!(drain < WINDOW + Duration::from_secs(1), "20 sends took {drain:?}, not one window");
}
