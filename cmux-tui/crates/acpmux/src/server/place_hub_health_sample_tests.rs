//! RFD 0181 B3's measure: what one placement waits on, and that what it does not wait on still
//! lands for the next one.
use super::*;
use crate::hub::hub_health::IN_FLIGHT;
use crate::mesh::{Ack, Heartbeat, HeartbeatReply, HubError, InMessage, OutMessage, Receipt};
use futures::future::BoxFuture;
use std::collections::BTreeMap;

fn hosts(n: usize) -> BTreeSet<String> {
    (0..n).map(|i| format!("lane-{i}")).collect()
}

#[test]
fn a_placement_waits_on_the_same_few_machines_at_40_as_at_139() {
    for seed in [1, 7, 0xdead_beef, u64::MAX] {
        let at_40 = wait_on(&hosts(40), seed);
        let at_139 = wait_on(&hosts(139), seed);
        assert_eq!((at_40.len(), at_139.len()), (SAMPLE, SAMPLE), "seed {seed}");
        assert!(at_139.is_subset(&hosts(139)));
    }
}

#[test]
fn a_few_machines_with_no_reading_are_all_waited_on() {
    assert_eq!(wait_on(&hosts(3), 9), hosts(3));
    assert!(wait_on(&BTreeSet::new(), 9).is_empty());
}

#[test]
fn draws_spread_over_every_machine() {
    let all = hosts(139);
    let mut seen = BTreeSet::new();
    let mut x = 0x9e37_79b9_7f4a_7c15u64;
    for _ in 0..2_000 {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        seen.extend(wait_on(&all, x));
    }
    assert_eq!(seen.len(), 139, "no machine is never drawn");
}

/// A hub whose machines answer a health read after their own delay (`None`: never). An answer
/// is a build without the method (`{"unsupported": true}`): a reading all the same.
struct Fleet {
    after: BTreeMap<String, Option<Duration>>,
}

impl MeshHub for Fleet {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(futures::future::pending())
    }
    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Ok(()) })
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        Box::pin(async { Ok(HeartbeatReply { daemon_id: "d".into(), ttl_seconds: 90 }) })
    }
    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        let after = m.to.host.as_ref().and_then(|h| self.after.get(h).copied().flatten());
        Box::pin(async move {
            let Some(after) = after else { return futures::future::pending().await };
            tokio::time::sleep(after).await;
            let mut r: Receipt = serde_json::from_value(serde_json::json!({
                "messageId": "m", "state": "refused", "createdAt": 1000,
                "detail": "mesh.read_unsupported: an older build"
            }))
            .unwrap();
            r.to = m.to.clone();
            Ok(r)
        })
    }
    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(futures::future::pending())
    }
}

const MACHINES: usize = 139;
const SEED: u64 = 0x5eed;
const SAMPLED_ANSWER: Duration = Duration::from_secs(1);
const REST_ANSWER: Duration = Duration::from_secs(3);

/// The machines one placement over [`MACHINES`] asks (the first [`IN_FLIGHT`] due) and, of
/// them, the ones it waits on.
fn asked_and_sampled() -> (Vec<String>, BTreeSet<String>) {
    let asked: Vec<String> = (0..IN_FLIGHT).map(|i| format!("lane-{i}")).collect();
    let sampled = wait_on(&asked.iter().cloned().collect(), SEED);
    (asked, sampled)
}

/// One placement through `fleet`: how long it waited, and the cache it filled.
async fn place_once(
    scope: &cmux_scope::Scope,
    fleet: Fleet,
) -> (Duration, Arc<StdMutex<HubHealth>>) {
    let cache: Arc<StdMutex<HubHealth>> = Arc::default();
    let hosts: Vec<String> = (0..MACHINES).map(|i| format!("lane-{i}")).collect();
    let via: Via = Arc::new(|host| Some(format!("{host}-session")));
    let began = tokio::time::Instant::now();
    refresh_drawn(scope, Arc::new(fleet), cache.clone(), hosts, via, FIRST_WAIT, SEED).await;
    (began.elapsed(), cache)
}

#[tokio::test(start_paused = true)]
async fn a_stalled_machine_not_drawn_never_holds_a_placement_and_the_rest_land_after() {
    let (asked, sampled) = asked_and_sampled();
    let rest: Vec<&String> = asked.iter().filter(|h| !sampled.contains(*h)).collect();
    let stalled = rest[0].clone();
    let after = asked
        .iter()
        .map(|h| {
            let d = if *h == stalled {
                None
            } else if sampled.contains(h) {
                Some(SAMPLED_ANSWER)
            } else {
                Some(REST_ANSWER)
            };
            (h.clone(), d)
        })
        .collect();
    let scope = cmux_scope::Scope::new("hub health sample test");
    let (waited, cache) = place_once(&scope, Fleet { after }).await;
    // Before (every machine with no reading waited on): FIRST_WAIT, held by the stalled one.
    assert_eq!(waited, SAMPLED_ANSWER, "the slowest of the {SAMPLE} drawn, not of {IN_FLIGHT}");
    let read = |h: &str| cache.lock().unwrap().reading(h).is_some();
    assert!(sampled.iter().all(|h| read(h)), "the drawn ones are weighed now");
    assert!(rest.iter().all(|h| !read(h)), "the rest are still out when the placement goes on");

    tokio::time::sleep(REST_ANSWER).await;
    let landed: Vec<&&String> = rest.iter().filter(|h| read(h)).collect();
    assert_eq!(landed.len(), rest.len() - 1, "every one but the stalled one lands for the next");
    assert!(!read(&stalled));
}

#[tokio::test(start_paused = true)]
async fn a_stalled_drawn_machine_holds_a_placement_no_longer_than_the_first_wait() {
    let (asked, sampled) = asked_and_sampled();
    let stalled = sampled.iter().next().unwrap().clone();
    let after =
        asked.iter().map(|h| (h.clone(), (*h != stalled).then_some(SAMPLED_ANSWER))).collect();
    let scope = cmux_scope::Scope::new("hub health sample test");
    let (waited, _) = place_once(&scope, Fleet { after }).await;
    assert_eq!(waited, FIRST_WAIT);
}
