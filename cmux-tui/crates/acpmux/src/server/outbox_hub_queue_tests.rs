//! The base's copy of the PR's bench (`outbox_hub_queue_tests.rs`), for its before numbers.
#![allow(dead_code)]

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
        let answer = if self.unknown.contains(&name.as_str()) {
            Answer::Fail(404, "mesh.unknown_recipient")
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
