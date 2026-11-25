//! RFD 0049 R1: a send to a session only the team hub routes (`HOST/NAME` on a machine with no
//! peer link here) is kept in the outbox when the hub does not take it in a way that passes (a
//! 5xx, a 429, no answer, no connection). It answers `queued` with its prompt id and delivery id
//! within `INLINE_WAIT`, and the outbox posts it again under the same key until the hub takes it,
//! once. A refusal of the hub's own still fails. While the hub fails, one post probes it per
//! window (`mesh_gate.rs`), so an overloaded hub is not hammered by every queued send.
//!
//! Before (2026-11-22 21:13Z): "Not sent to HOST/NAME:
//! the mesh hub did not take it: the hub answered 503 mesh.unavailable ... 0 of 2 sent."

use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt, Target,
};
use futures::future::BoxFuture;
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

/// What the stub hub does with one post.
#[derive(Clone)]
enum Answer {
    Take,
    Fail(u16, &'static str),
    /// Accepts the request and never answers.
    Stall,
}

#[derive(Default)]
struct StubHub {
    /// Answers for the next posts, in order; past them every post is taken.
    script: Mutex<VecDeque<Answer>>,
    /// Names the hub does not know: refused, whatever the script says.
    unknown: Vec<&'static str>,
    /// Every post that reached it.
    posts: Mutex<Vec<OutMessage>>,
    /// The message it holds under each idempotency key: one per key, however often it is posted.
    held: Mutex<HashMap<String, String>>,
    /// Until when (the runtime's clock) every post is answered 503, whatever the script says.
    down_until: Mutex<Option<tokio::time::Instant>>,
}

fn hub_status(status: u16, code: &str) -> HubError {
    let mut e = HubError::refused(format!("the hub answered {status} {code}"));
    e.refused = !(status == 408 || status == 429 || status >= 500);
    e.status = Some(status);
    e.code = Some(code.into());
    e
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
        self.posts.lock().unwrap().push(message.clone());
        let name = message.to.name.clone().unwrap_or_default();
        let down = self.down_until.lock().unwrap().is_some_and(|u| tokio::time::Instant::now() < u);
        let answer = if self.unknown.contains(&name.as_str()) {
            Answer::Fail(404, "mesh.unknown_recipient")
        } else if down {
            Answer::Fail(503, "mesh.unavailable")
        } else {
            self.script.lock().unwrap().pop_front().unwrap_or(Answer::Take)
        };
        Box::pin(async move {
            match answer {
                Answer::Take => {
                    let n = self.held.lock().unwrap().len() + 1;
                    let id = self
                        .held
                        .lock()
                        .unwrap()
                        .entry(message.idempotency_key.clone())
                        .or_insert_with(|| format!("msg_{n:032}"))
                        .clone();
                    Ok(receipt(&id, "queued", message.to.clone()))
                }
                Answer::Fail(status, code) => {
                    let mut e = hub_status(status, code);
                    if code == "mesh.unknown_recipient" {
                        e.refused = true;
                    }
                    Err(e)
                }
                Answer::Stall => std::future::pending().await,
            }
        })
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move { Ok(receipt(id, "delivered", Target::default())) })
    }
}

fn receipt(id: &str, state: &str, to: Target) -> Receipt {
    let mut receipt: Receipt = serde_json::from_value(json!({
        "messageId": id, "state": state, "createdAt": 1000
    }))
    .unwrap();
    receipt.to = to;
    receipt
}

fn setup(stub: StubHub) -> (Arc<Hub>, Arc<StubHub>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let stub = Arc::new(stub);
    hub.mesh.set(stub.clone());
    (hub, stub)
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

fn request(target: &str, prompt_id: &str) -> Value {
    json!({"request": {
        "sessionId": target,
        "prompt": [{"type": "text", "text": "from a lane VM"}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    }})
}

/// `send_queue` of `params`, and how long it took on the runtime's clock and on the wall's.
async fn timed_send(hub: &Arc<Hub>, params: Value) -> (Result<Value, Value>, Duration, Duration) {
    let (runtime, wall) = (tokio::time::Instant::now(), std::time::Instant::now());
    let answer = call(hub, method::MUX_SEND_QUEUE, params).await;
    (answer, runtime.elapsed(), wall.elapsed())
}

/// The delivery once it settles, within `within` of the runtime's clock.
async fn settled(hub: &Arc<Hub>, id: &str, within: Duration) -> Delivery {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let changed = hub.outbox.changed.notified();
        let d = hub.outbox.get(id).unwrap();
        if d.settled() {
            return d;
        }
        assert!(tokio::time::timeout_at(deadline, changed).await.is_ok(), "not settled: {d:?}");
    }
}

const BOUND: Duration = Duration::from_millis(500);

#[tokio::test(start_paused = true)]
async fn a_hub_503_queues_the_send_and_the_outbox_delivers_it_once() {
    let script = [Answer::Fail(503, "mesh.unavailable"), Answer::Fail(503, "mesh.unavailable")];
    let (hub, stub) = setup(StubHub { script: Mutex::new(script.into()), ..StubHub::default() });
    let params = request("far-host/lane", "prompt-hub-503");
    let (answer, runtime, wall) = timed_send(&hub, params).await;
    let queued = answer.expect("a 503 never fails the send");
    assert!(runtime < BOUND && wall < BOUND, "took {runtime:?} / {wall:?}");
    assert_eq!(queued["status"], "queued", "{queued}");
    assert_eq!(queued["promptId"], "prompt-hub-503", "{queued}");
    let id = queued["deliveryId"].as_str().unwrap().to_owned();
    assert!(!id.starts_with(super::super::mesh_send::PREFIX), "kept in the outbox: {queued}");
    assert!(queued["error"].as_str().unwrap().contains("hub 503"), "{queued}");

    // `send --status` reads it as queued, with why.
    let status = call(&hub, method::MUX_SEND_STATUS, json!({"deliveryId": id})).await.unwrap();
    assert!(matches!(status["status"].as_str(), Some("queued" | "delivering")), "{status}");
    assert!(status["error"].as_str().unwrap().contains("hub 503"), "{status}");

    let d = settled(&hub, &id, Duration::from_secs(600)).await;
    assert_eq!(d.state, State::Delivered, "{d:?}");
    assert_eq!(d.accepted.as_ref().unwrap()["via"], "mesh", "{d:?}");
    let posts = stub.posts.lock().unwrap();
    assert!(posts.iter().all(|m| m.idempotency_key == "prompt-hub-503"), "one key: {posts:?}");
    assert_eq!(stub.held.lock().unwrap().len(), 1, "the hub holds it once");
    // The two 503s and the post it took: the gate kept the delivery's first attempt (right after
    // the send's own post failed) from asking.
    assert_eq!(posts.len(), 3, "{posts:?}");
    assert!(!hub.mesh.gate().shut(), "the hub's answer opened the gate");
}

#[tokio::test(start_paused = true)]
async fn a_stalled_hub_queues_the_send_within_the_bound_and_the_retry_delivers_it_once() {
    let (hub, stub) =
        setup(StubHub { script: Mutex::new([Answer::Stall].into()), ..StubHub::default() });
    let params = request("far-host/lane", "prompt-stalled");
    let (answer, runtime, wall) = timed_send(&hub, params).await;
    let queued = answer.expect("a hub that does not answer never fails the send");
    assert!(runtime < BOUND && wall < BOUND, "took {runtime:?} / {wall:?}");
    assert_eq!(queued["status"], "queued", "{queued}");
    assert!(queued["error"].as_str().unwrap().contains("did not answer"), "{queued}");
    let id = queued["deliveryId"].as_str().unwrap().to_owned();
    let d = settled(&hub, &id, Duration::from_secs(600)).await;
    assert_eq!(d.state, State::Delivered, "{d:?}");
    // The stalled post may have reached the hub; the retry is the same message under its key.
    assert_eq!(stub.held.lock().unwrap().len(), 1);
    assert!(stub.posts.lock().unwrap().iter().all(|m| m.idempotency_key == "prompt-stalled"));
}

/// A batch to two recipients, one the hub does not know and one while it answers 503: each keeps
/// its own row (`acpmux_mcp_send.rs` sends a batch as one `send_queue` per recipient). The
/// unknown name fails with the hub's reason, the other is queued and delivered.
#[tokio::test(start_paused = true)]
async fn a_batch_with_one_bad_recipient_keeps_its_rows() {
    let (hub, stub) = setup(StubHub {
        script: Mutex::new([Answer::Fail(503, "mesh.unavailable")].into()),
        unknown: vec!["nobody"],
        ..StubHub::default()
    });
    let (good, runtime, _) = timed_send(&hub, request("far-host/lane", "prompt-batch-good")).await;
    assert!(runtime < BOUND);
    let good = good.unwrap();
    assert_eq!(good["status"], "queued", "{good}");
    // The gate is shut by the 503, so the second recipient's send is queued without asking; its
    // refusal comes from the outbox's attempt.
    let (bad, _, _) = timed_send(&hub, request("far-host/nobody", "prompt-batch-bad")).await;
    let bad = bad.unwrap();
    assert_eq!(bad["status"], "queued", "{bad}");
    let good = settled(&hub, good["deliveryId"].as_str().unwrap(), Duration::from_secs(600)).await;
    let bad = settled(&hub, bad["deliveryId"].as_str().unwrap(), Duration::from_secs(1200)).await;
    assert_eq!(good.state, State::Delivered, "{good:?}");
    assert_eq!(bad.state, State::Failed, "{bad:?}");
    // A name the hub never lists fails after its bounded attempts, not on the first 404.
    assert_eq!(bad.attempts, super::UNKNOWN_RECIPIENT_ATTEMPTS, "{bad:?}");
    let error = bad.error.unwrap_or_default();
    assert!(
        error.contains("mesh hub refused it") && error.contains("unknown_recipient"),
        "{error}"
    );
    assert_eq!(stub.held.lock().unwrap().len(), 1);
}

/// A refusal of the hub's own (here a 403) is not retried: the send fails with its reason, and a
/// name the hub does not know is `no session`, as before.
#[tokio::test]
async fn a_refusal_of_the_hubs_own_still_fails_the_send() {
    let (hub, stub) = setup(StubHub {
        script: Mutex::new([Answer::Fail(403, "mesh.forbidden")].into()),
        unknown: vec!["nobody"],
        ..StubHub::default()
    });
    let e = call(&hub, method::MUX_SEND_QUEUE, request("far-host/lane", "prompt-403")).await;
    let e = e.unwrap_err();
    assert!(e["message"].as_str().unwrap().contains("refused it"), "{e}");
    let e = call(&hub, method::MUX_SEND_QUEUE, request("far-host/nobody", "prompt-unknown")).await;
    assert_eq!(e.unwrap_err()["data"]["reason"], "no_session");
    assert!(hub.outbox.list(None, 10).0.is_empty(), "nothing kept");
    assert_eq!(stub.posts.lock().unwrap().len(), 2);
}

/// While the hub answers 503, fifty sends are all queued at once and the hub sees one post per
/// window, not fifty: the gate (`mesh_gate.rs`) keeps an overloaded hub from being hammered.
#[tokio::test(start_paused = true)]
async fn a_failing_hub_is_probed_once_per_window_not_by_every_send() {
    let script = vec![Answer::Fail(503, "mesh.unavailable"); 1000];
    let (hub, stub) = setup(StubHub { script: Mutex::new(script.into()), ..StubHub::default() });
    let mut ids = Vec::new();
    for n in 0..50 {
        let params = request(&format!("far-host/lane-{n}"), &format!("prompt-gate-{n}"));
        let (answer, runtime, _) = timed_send(&hub, params).await;
        assert!(runtime < BOUND);
        let queued = answer.unwrap();
        assert_eq!(queued["status"], "queued", "{queued}");
        ids.push(queued["deliveryId"].as_str().unwrap().to_owned());
    }
    assert_eq!(stub.posts.lock().unwrap().len(), 1, "only the first send asked the hub");
    // Ten minutes of retries by fifty deliveries: windows of 1, 2, 4 ... 60 s, so a dozen or so
    // probes, never one per delivery per retry.
    tokio::time::sleep(Duration::from_secs(600)).await;
    let posts = stub.posts.lock().unwrap().len();
    assert!(posts <= 25, "{posts} posts in ten minutes");
    assert!(ids.iter().all(|id| !hub.outbox.get(id).unwrap().settled()), "all still kept");
}

/// The before/after numbers in the PR (one harness for both: this test needs nothing the fix
/// added, so it runs on the base as it is). `n` sends through `_acpmux/send_queue` while the hub
/// answers 503, then while it stalls (takes the request and never answers), each cut off at
/// [`BENCH_CUTOFF`]. Prints each leg's latency, p50 and p99, on the wall's clock and the
/// runtime's (paused, so a stall costs no wall time), and what the sends came back as. The hub
/// then answers again, and the leg prints how many of the sends it holds, which is `n` exactly
/// when each was delivered once.
#[tokio::test(start_paused = true)]
async fn bench_send_queue_latency_with_the_hub_failing() {
    const N: usize = 200;
    for (leg, answer) in
        [("hub503", Answer::Fail(503, "mesh.unavailable")), ("hubslow", Answer::Stall)]
    {
        let script = vec![answer; 100_000];
        let (hub, stub) =
            setup(StubHub { script: Mutex::new(script.into()), ..StubHub::default() });
        let (mut wall, mut clock) = (Vec::new(), Vec::new());
        let (mut queued, mut failed, mut cut) = (0, 0, 0);
        for n in 0..N {
            let params = request(&format!("far-host/lane-{n}"), &format!("prompt-{leg}-{n}"));
            let (runtime, started) = (tokio::time::Instant::now(), std::time::Instant::now());
            let send = call_within(&hub, method::MUX_SEND_QUEUE, params, BENCH_CUTOFF).await;
            wall.push(started.elapsed());
            clock.push(runtime.elapsed());
            match send {
                Some(Ok(row)) if row["status"] == "queued" => queued += 1,
                Some(Ok(_)) => {}
                Some(Err(_)) => failed += 1,
                None => cut += 1,
            }
        }
        // The hub answers again: what the outbox kept reaches it.
        stub.script.lock().unwrap().clear();
        tokio::time::sleep(Duration::from_secs(900)).await;
        let held = stub.held.lock().unwrap().len();
        let posts = stub.posts.lock().unwrap().len();
        println!(
            "BENCH leg={leg} n={N} wall_p50={:?} wall_p99={:?} clock_p50={:?} clock_p99={:?} \
             queued={queued} failed={failed} cut_at_{}s={cut} hub_holds_after_recovery={held} \
             hub_posts={posts}",
            pct(&mut wall, 50),
            pct(&mut wall, 99),
            pct(&mut clock, 50),
            pct(&mut clock, 99),
            BENCH_CUTOFF.as_secs(),
        );
    }
}

/// How long the bench lets one send take before it counts it as cut off.
const BENCH_CUTOFF: Duration = Duration::from_secs(10);

fn pct(samples: &mut [Duration], p: usize) -> Duration {
    samples.sort();
    samples[(samples.len() * p / 100).min(samples.len() - 1)]
}

/// [`call`], cut off after `within`: None when it did not answer in time.
async fn call_within(
    hub: &Arc<Hub>,
    m: &str,
    params: Value,
    within: Duration,
) -> Option<Result<Value, Value>> {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    for line in [Message::request(1, method::INITIALIZE, hello), Message::request(2, m, params)] {
        input.send(line.to_line()).await.unwrap();
    }
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let line = tokio::time::timeout_at(deadline, outgoing.recv()).await.ok()??;
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply.get("id") == Some(&json!(2)) {
            return Some(match reply.get("error") {
                Some(e) => Err(e.clone()),
                None => Ok(reply["result"].clone()),
            });
        }
    }
}

/// RFD 0086 item 2's duress number: the hub answers 503 for [`OUTAGE`] while [`SENDS`] sends are
/// made, one every [`OUTAGE`] / [`SENDS`]. Every send is answered `queued` within the bound, none
/// is lost (the hub holds each once after it recovers), and the line printed says how long the
/// outbox took to drain from the moment the hub answered again, on the runtime's clock (paused,
/// so the outage costs no wall time) and the wall's.
#[tokio::test(start_paused = true)]
async fn duress_a_30s_hub_503_loses_none_of_100_sends_and_drains_on_recovery() {
    const SENDS: u32 = 100;
    const OUTAGE: Duration = Duration::from_secs(30);
    let (hub, stub) = setup(StubHub::default());
    let start = tokio::time::Instant::now();
    let recovered_at = start + OUTAGE;
    *stub.down_until.lock().unwrap() = Some(recovered_at);
    let mut ids = Vec::new();
    let mut slowest = Duration::ZERO;
    for n in 0..SENDS {
        tokio::time::sleep_until(start + OUTAGE * n / SENDS).await;
        let params = request(&format!("far-host/lane-{n}"), &format!("prompt-duress-{n}"));
        let (answer, runtime, wall) = timed_send(&hub, params).await;
        slowest = slowest.max(runtime).max(wall);
        let queued = answer.expect("a hub 503 never fails the send");
        assert_eq!(queued["status"], "queued", "{queued}");
        ids.push(queued["deliveryId"].as_str().unwrap().to_owned());
    }
    assert!(slowest < BOUND, "a send took {slowest:?}");
    tokio::time::sleep_until(recovered_at).await;
    let wall = std::time::Instant::now();
    let mut lost = 0;
    for id in &ids {
        let d = settled(&hub, id, Duration::from_secs(900)).await;
        if d.state != State::Delivered {
            lost += 1;
        }
    }
    let drain = tokio::time::Instant::now() - recovered_at;
    let drain_wall = wall.elapsed();
    let held = stub.held.lock().unwrap().len();
    let posts = stub.posts.lock().unwrap().len();
    println!(
        "DURESS hub503_for={}s sends={SENDS} lost={lost} hub_holds={held} hub_posts={posts} \
         slowest_send={slowest:?} drain_after_recovery={drain:?} drain_wall={drain_wall:?}",
        OUTAGE.as_secs(),
    );
    assert_eq!(lost, 0, "every send delivered");
    assert_eq!(held, SENDS as usize, "the hub holds each send once");
}

/// RFD 0180 (EAGAIN, not ENOENT): a kept delivery whose target the hub does not list yet (its
/// machine paused, restarting or between heartbeats) waits on the outbox's back-off and is
/// delivered once the hub lists it, under its one key. Before: failed on the first 404 ("the
/// mesh hub refused it: the hub answered 404 mesh.unknown_recipient"), 3 of 69 deliveries on
/// one lane VM, 2026-11-23 to 11-25.
#[tokio::test(start_paused = true)]
async fn a_name_the_hub_lists_late_is_delivered_not_failed() {
    let script = [
        Answer::Fail(503, "mesh.unavailable"),
        Answer::Fail(404, "mesh.unknown_recipient"),
        Answer::Fail(404, "mesh.unknown_recipient"),
        Answer::Fail(404, "mesh.unknown_recipient"),
    ];
    let (hub, stub) = setup(StubHub { script: Mutex::new(script.into()), ..StubHub::default() });
    let (answer, _, _) = timed_send(&hub, request("far-host/waking", "prompt-unlisted")).await;
    let queued = answer.expect("a 503 queues it");
    assert_eq!(queued["status"], "queued", "{queued}");
    let id = queued["deliveryId"].as_str().unwrap().to_owned();
    let d = settled(&hub, &id, Duration::from_secs(1200)).await;
    assert_eq!(d.state, State::Delivered, "{d:?}");
    assert_eq!(stub.held.lock().unwrap().len(), 1, "the hub holds it once");
    let posts = stub.posts.lock().unwrap();
    assert!(posts.iter().all(|m| m.idempotency_key == "prompt-unlisted"), "{posts:?}");
    assert_eq!(posts.len(), 5, "the 503, three 404s and the post it took: {posts:?}");
}

#[test]
fn only_an_unlisted_name_with_attempts_left_waits() {
    let unknown = hub_status(404, "mesh.unknown_recipient");
    assert!(super::unknown_recipient_waits(&unknown, 1));
    assert!(super::unknown_recipient_waits(&unknown, super::UNKNOWN_RECIPIENT_ATTEMPTS - 1));
    assert!(!super::unknown_recipient_waits(&unknown, super::UNKNOWN_RECIPIENT_ATTEMPTS));
    assert!(!super::unknown_recipient_waits(&hub_status(403, "mesh.forbidden"), 1));
}
