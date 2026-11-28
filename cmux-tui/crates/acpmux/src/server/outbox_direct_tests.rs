//! RFD 0086: while the team hub is down, a send to a session only the hub routes goes to its
//! machine directly (`mesh_direct.rs`), with `meshRelay.directSend` on, and only after the hub
//! definitely did not take it: no connection made, or its gate kept the post from going. A hub
//! that answered (a 503, a timeout) may hold it, so it waits for the hub as before; a refusal of
//! the hub's own still fails it. A copy that may have gone direct is never posted to the hub, so
//! no later hub drain runs it twice.
//!
//! The far machine is a stand-in (`mesh_direct::stub_far`) that keeps the receiver's rule: a
//! prompt id it ran already is answered as taken and not run again (`Hub::knows_prompt`).

use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt,
};
use crate::mesh_relay_config::MeshRelayConfig;
use futures::future::BoxFuture;
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use super::super::mesh_direct::{self, Direct, FarStub};

/// How the stub hub fails while it is down.
#[derive(Clone, Copy, PartialEq)]
enum Down {
    /// No connection: nothing left this daemon.
    Unconnected,
    /// Answered 503: it may hold the post.
    Answered,
}

struct StubHub {
    down: AtomicBool,
    how: Down,
    /// Every post that reached it (a down hub's included, as a 503 one does).
    posts: Mutex<Vec<OutMessage>>,
    /// The message it holds under each idempotency key: one per key.
    held: Mutex<HashMap<String, String>>,
}

impl StubHub {
    fn new(how: Down) -> Self {
        Self { down: AtomicBool::new(true), how, posts: Mutex::default(), held: Mutex::default() }
    }
}

impl MeshHub for StubHub {
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
        let down = self.down.load(Ordering::SeqCst);
        Box::pin(async move {
            if down && self.how == Down::Unconnected {
                return Err(HubError::unconnected("the hub: error trying to connect"));
            }
            self.posts.lock().unwrap().push(message.clone());
            if down {
                let mut e = HubError::refused("the hub answered 503 mesh.unavailable");
                e.refused = false;
                e.status = Some(503);
                e.code = Some("mesh.unavailable".into());
                return Err(e);
            }
            let mut held = self.held.lock().unwrap();
            let n = held.len() + 1;
            let id = held
                .entry(message.idempotency_key.clone())
                .or_insert_with(|| format!("msg_{n:032}"))
                .clone();
            let mut receipt: Receipt = serde_json::from_value(
                json!({"messageId": id, "state": "queued", "createdAt": 1000}),
            )
            .unwrap();
            receipt.to = message.to.clone();
            Ok(receipt)
        })
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            Ok(serde_json::from_value(
                json!({"messageId": id, "state": "delivered", "createdAt": 1000}),
            )
            .unwrap())
        })
    }
}

/// What the far machine does with one direct copy, by the copy's key and the times it was sent.
type Script = Arc<dyn Fn(&str, u32) -> Far + Send + Sync>;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Far {
    /// Runs it (once per prompt id) and answers.
    Run,
    /// Runs it, and the answer is lost on the way back.
    RunLoseAnswer,
    /// Cannot be reached: the stream never opens, nothing runs.
    Unreachable,
    /// The session there refuses it.
    Refuse,
}

/// The stand-in far daemon: each prompt id it ran, and how many times it ran.
#[derive(Default)]
struct FarDaemon {
    ran: Mutex<HashMap<String, u32>>,
    sends: Mutex<HashMap<String, u32>>,
}

fn far_stub(far: &Arc<FarDaemon>, script: Script) -> FarStub {
    let far = far.clone();
    Arc::new(move |post: &OutMessage, attempt: u32| {
        let far = far.clone();
        let script = script.clone();
        let post = post.clone();
        Box::pin(async move {
            let nth = {
                let mut sends = far.sends.lock().unwrap();
                let n = sends.entry(post.idempotency_key.clone()).or_default();
                *n += 1;
                *n
            };
            let step = script(&post.idempotency_key, nth);
            if step == Far::Unreachable {
                return Direct::NotRun("could not be reached directly".into());
            }
            // The far side's own checks and its one id per post.
            let message = match mesh_direct::in_message("inst_a", &post, attempt) {
                Ok(message) => message,
                Err(e) => return mesh_direct::outcome(&post, "far-host", Err(Some(e))),
            };
            if step == Far::Refuse {
                let ack = Some(Ack::refused("no session lane there"));
                return mesh_direct::outcome(
                    &post,
                    "far-host",
                    mesh_direct::answer(ack).map_err(Some),
                );
            }
            // A prompt id it ran already is answered from its log, not run again.
            far.ran.lock().unwrap().entry(message.message_id.clone()).or_insert(1);
            if step == Far::RunLoseAnswer {
                return mesh_direct::outcome(&post, "far-host", Err(None));
            }
            let ack = Some(Ack::delivered(&message.message_id, None));
            mesh_direct::outcome(&post, "far-host", mesh_direct::answer(ack).map_err(Some))
        })
    })
}

struct Rig {
    hub: Arc<Hub>,
    stub: Arc<StubHub>,
    far: Arc<FarDaemon>,
}

async fn rig(how: Down, switch: bool, script: Script) -> Rig {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let stub = Arc::new(StubHub::new(how));
    hub.mesh.set(stub.clone());
    hub.config.write().await.mesh_relay =
        Some(MeshRelayConfig { direct_send: switch, ..MeshRelayConfig::default() });
    let far = Arc::new(FarDaemon::default());
    mesh_direct::stub_far(&hub, ("inst_b".into(), "far-host".into()), far_stub(&far, script));
    Rig { hub, stub, far }
}

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

/// `send_queue` of one prompt to `far-host/lane`: its delivery id.
async fn send(hub: &Arc<Hub>, prompt_id: &str) -> String {
    let params = json!({"request": {
        "sessionId": "far-host/lane",
        "prompt": [{"type": "text", "text": "from a lane VM"}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    }});
    let queued = call(hub, method::MUX_SEND_QUEUE, params).await.expect("a down hub queues it");
    assert_eq!(queued["status"], "queued", "{queued}");
    queued["deliveryId"].as_str().unwrap().to_owned()
}

/// The delivery once it settles, within `within` of the runtime's clock; None if it did not.
async fn settled(hub: &Arc<Hub>, id: &str, within: Duration) -> Option<Delivery> {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let changed = hub.outbox.changed.notified();
        let d = hub.outbox.get(id).unwrap();
        if d.settled() {
            return Some(d);
        }
        tokio::time::timeout_at(deadline, changed).await.ok()?;
    }
}

fn always(step: Far) -> Script {
    Arc::new(move |_, _| step)
}

#[tokio::test(start_paused = true)]
async fn with_the_switch_off_nothing_goes_direct() {
    let r = rig(Down::Unconnected, false, always(Far::Run)).await;
    let id = send(&r.hub, "prompt-switch-off").await;
    assert!(settled(&r.hub, &id, Duration::from_secs(900)).await.is_none(), "waits for the hub");
    assert!(r.far.sends.lock().unwrap().is_empty(), "nothing went direct");
    let d = r.hub.outbox.get(&id).unwrap();
    assert!(!d.direct_maybe, "{d:?}");
    // The hub back: it carries it, once.
    r.stub.down.store(false, Ordering::SeqCst);
    let d = settled(&r.hub, &id, Duration::from_secs(900)).await.expect("the hub carries it");
    assert_eq!(d.state, State::Delivered, "{d:?}");
    assert_eq!(d.accepted.as_ref().unwrap()["via"], "mesh", "{d:?}");
    assert_eq!(r.stub.held.lock().unwrap().len(), 1);
}

#[tokio::test(start_paused = true)]
async fn a_hub_that_answered_may_hold_it_so_nothing_goes_direct() {
    let r = rig(Down::Answered, true, always(Far::Run)).await;
    let id = send(&r.hub, "prompt-hub-answered").await;
    assert!(settled(&r.hub, &id, Duration::from_secs(900)).await.is_none(), "waits for the hub");
    assert!(r.far.sends.lock().unwrap().is_empty(), "a 503 may hold it: never direct");
    let d = r.hub.outbox.get(&id).unwrap();
    assert!(!d.relay_unreached && !d.direct_maybe, "{d:?}");
    r.stub.down.store(false, Ordering::SeqCst);
    let d = settled(&r.hub, &id, Duration::from_secs(900)).await.expect("the hub carries it");
    assert_eq!(d.accepted.as_ref().unwrap()["via"], "mesh", "{d:?}");
}

#[tokio::test(start_paused = true)]
async fn a_hub_with_no_connection_sends_it_direct_once() {
    let r = rig(Down::Unconnected, true, always(Far::Run)).await;
    let id = send(&r.hub, "prompt-direct-once").await;
    let d = settled(&r.hub, &id, Duration::from_secs(120)).await.expect("delivered direct");
    assert_eq!(d.state, State::Delivered, "{d:?}");
    let accepted = d.accepted.as_ref().unwrap();
    assert_eq!(accepted["via"], "direct", "{d:?}");
    assert_eq!(accepted["promptId"], "direct:inst_a:prompt-direct-once", "{d:?}");
    assert!(!d.open_on_peer && d.pin.is_none(), "{d:?}");
    assert_eq!(r.far.ran.lock().unwrap().len(), 1);
    r.stub.down.store(false, Ordering::SeqCst);
    tokio::time::sleep(Duration::from_secs(900)).await;
    assert!(r.stub.posts.lock().unwrap().is_empty(), "the hub is never posted it");
}

#[tokio::test(start_paused = true)]
async fn the_far_sessions_refusal_fails_the_send() {
    let r = rig(Down::Unconnected, true, always(Far::Refuse)).await;
    let id = send(&r.hub, "prompt-far-refuses").await;
    let d = settled(&r.hub, &id, Duration::from_secs(120)).await.expect("settled");
    assert_eq!(d.state, State::Failed, "{d:?}");
    assert!(d.error.as_deref().unwrap().contains("far-host refused it"), "{d:?}");
}

#[tokio::test(start_paused = true)]
async fn a_copy_that_may_have_run_never_goes_to_the_hub() {
    // The first copy runs there and its answer is lost; the far machine is then unreachable.
    let script: Script =
        Arc::new(|_, nth| if nth == 1 { Far::RunLoseAnswer } else { Far::Unreachable });
    let r = rig(Down::Unconnected, true, script).await;
    let id = send(&r.hub, "prompt-maybe-ran").await;
    tokio::time::sleep(Duration::from_secs(60)).await;
    assert!(r.hub.outbox.get(&id).unwrap().direct_maybe);
    // The hub back: still direct only, since only the direct id dedups it there.
    r.stub.down.store(false, Ordering::SeqCst);
    assert!(settled(&r.hub, &id, Duration::from_secs(1800)).await.is_none());
    assert!(r.stub.posts.lock().unwrap().is_empty(), "never posted to the hub");
    assert_eq!(r.far.ran.lock().unwrap().len(), 1);
}

/// Duress: the hub down (no connection) while 60 sends queue, the far machine dropping answers,
/// refusing streams and coming and going, then the hub back. Every send is delivered (0 lost),
/// and each runs once on the far machine or is held once by the hub, never both (0 doubled).
#[tokio::test(start_paused = true)]
async fn hub_down_n_sends_none_lost_none_doubled() {
    const N: u32 = 60;
    let index = |key: &str| key.rsplit('-').next().and_then(|n| n.parse::<u32>().ok()).unwrap();
    let flips = Arc::new(AtomicU32::new(0));
    let flips_in = flips.clone();
    let script: Script = Arc::new(move |key, nth| {
        let i = index(key);
        flips_in.fetch_add(1, Ordering::SeqCst);
        match i % 5 {
            // Never reachable direct: the hub carries these once it is back.
            0 => Far::Unreachable,
            // Runs, answer lost, again: the second copy is the same prompt there.
            1 if nth == 1 => Far::RunLoseAnswer,
            // Not reachable at first, then taken.
            2 if nth <= 2 => Far::Unreachable,
            // Its answer lost twice.
            3 if nth <= 2 => Far::RunLoseAnswer,
            _ => Far::Run,
        }
    });
    let r = rig(Down::Unconnected, true, script).await;
    let mut ids = Vec::new();
    for i in 0..N {
        ids.push(send(&r.hub, &format!("prompt-duress-{i:03}")).await);
    }
    // Down for ten minutes, then back.
    tokio::time::sleep(Duration::from_secs(600)).await;
    r.stub.down.store(false, Ordering::SeqCst);
    let mut lost = Vec::new();
    let mut via_direct = 0;
    let mut via_hub = 0;
    for id in &ids {
        match settled(&r.hub, id, Duration::from_secs(3600)).await {
            Some(d) if d.state == State::Delivered => {
                match d.accepted.as_ref().unwrap()["via"].as_str() {
                    Some("direct") => via_direct += 1,
                    Some("mesh") => via_hub += 1,
                    other => panic!("{other:?}: {d:?}"),
                }
            }
            other => lost.push(format!("{id}: {other:?}")),
        }
    }
    assert!(lost.is_empty(), "lost {} of {N}: {lost:?}", lost.len());
    let ran = r.far.ran.lock().unwrap().clone();
    let held = r.stub.held.lock().unwrap().clone();
    let mut doubled = Vec::new();
    for i in 0..N {
        let key = format!("prompt-duress-{i:03}");
        let far = u32::from(ran.contains_key(&mesh_direct::prompt_id("inst_a", &key)));
        let hub = u32::from(held.contains_key(&key));
        if far + hub != 1 {
            doubled.push(format!("{key}: far {far}, hub {hub}"));
        }
    }
    assert!(doubled.is_empty(), "doubled or missing: {doubled:?}");
    assert_eq!(via_direct + via_hub, N);
    assert_eq!(via_hub, N / 5, "only the unreachable fifth waited for the hub");
    assert!(flips.load(Ordering::SeqCst) > N, "the far machine was tried more than once each");
    eprintln!(
        "duress: {N} sends, 0 lost, 0 doubled; {via_direct} direct, {via_hub} via the hub, {} direct copies",
        flips.load(Ordering::SeqCst)
    );
}
