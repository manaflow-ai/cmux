use super::*;

const SEC: Duration = Duration::from_secs(1);

/// A pathological background loop of any cause, on the breaker's clock: every `every`, each of
/// `harnesses` asks for a start; an admitted one is ready `ready_after` later and ends unused
/// `ends_after` past that. Returns the admitted start times.
fn thrash(
    harnesses: &[&str],
    every: Duration,
    ready_after: Duration,
    ends_after: Duration,
    total: Duration,
) -> (StartBreaker, Vec<Duration>) {
    let mut b = StartBreaker::default();
    let mut admitted = Vec::new();
    // (end time, ready time, harness) of entries alive now.
    let mut alive: Vec<(Duration, Duration, String)> = Vec::new();
    let mut now = Duration::ZERO;
    while now < total {
        alive.retain(|(end, ready, h)| {
            if *end <= now {
                b.note_unused_end(h, *ready, now);
                false
            } else {
                true
            }
        });
        for h in harnesses {
            if b.admit(h, now) {
                admitted.push(now);
                let ready = now + ready_after;
                alive.push((ready + ends_after, ready, (*h).to_owned()));
            }
        }
        now += every;
    }
    (b, admitted)
}

fn most_in_any(window: Duration, times: &[Duration]) -> usize {
    times
        .iter()
        .map(|t| times.iter().filter(|u| **u >= *t && **u < *t + window).count())
        .max()
        .unwrap_or(0)
}

#[test]
fn a_start_evict_loop_stays_bounded_over_two_hours() {
    // The incident's shape: a start every second or so, evicted right after it is ready
    // (about 2,800 starts in two hours unguarded).
    let two_hours = Duration::from_secs(2 * 3600);
    let (b, admitted) = thrash(&["claude"], SEC, 3 * SEC, SEC, two_hours);
    assert!(admitted.len() <= 40, "{} background starts in two hours", admitted.len());
    assert!(most_in_any(Duration::from_secs(60), &admitted) <= HARNESS_PER_MINUTE as usize);
    let v = b.view(two_hours);
    assert_eq!(v["tripped"], true, "{v}");
    assert_eq!(v["harnesses"]["claude"]["open"], true, "{v}");
    // Backed off to the longest cooldown: the last hour holds a handful of starts at most.
    let last_hour = admitted.iter().filter(|t| **t >= Duration::from_secs(3600)).count();
    assert!(last_hour <= 2 * HARNESS_PER_MINUTE as usize, "{last_hour} in the last hour");
}

#[test]
fn a_loop_that_never_churns_is_still_held_to_the_budget() {
    // Entries that live past the churn age but are replaced at once (a cause churn misses).
    let hour = Duration::from_secs(3600);
    let (_, admitted) = thrash(&["codex"], SEC, SEC, CHURN_AGE * 2, hour);
    assert!(admitted.len() <= 40, "{} background starts in an hour", admitted.len());
}

#[test]
fn many_harnesses_together_are_held_to_the_daemon_budget() {
    let names: Vec<String> = (0..20).map(|i| format!("h{i}")).collect();
    let names: Vec<&str> = names.iter().map(String::as_str).collect();
    let hour = Duration::from_secs(3600);
    let (b, admitted) = thrash(&names, SEC, SEC, SEC, hour);
    assert!(most_in_any(Duration::from_secs(60), &admitted) <= GLOBAL_PER_MINUTE as usize);
    assert!(admitted.len() <= 120, "{} background starts in an hour", admitted.len());
    assert!(b.view(hour)["global"]["trips"].as_u64().unwrap() >= 1);
}

#[test]
fn one_trip_counts_once_however_many_starts_it_refuses() {
    let mut b = StartBreaker::default();
    let now = Duration::from_secs(5);
    for _ in 0..HARNESS_PER_MINUTE {
        assert!(b.admit("claude", now));
    }
    for _ in 0..500 {
        assert!(!b.admit("claude", now));
    }
    let v = b.view(now);
    assert_eq!(v["harnesses"]["claude"]["trips"], 1, "{v}");
    assert_eq!(v["harnesses"]["claude"]["reason"], "budget");
    assert_eq!(v["harnesses"]["claude"]["refused"], 500);
    // Another harness has its own budget.
    assert!(b.admit("codex", now));
}

#[test]
fn quick_ends_trip_the_harness_and_a_calm_resets_the_backoff() {
    let mut b = StartBreaker::default();
    let mut now = Duration::from_secs(100);
    for _ in 0..CHURN_TRIPS {
        b.note_unused_end("opencode", now, now + SEC);
        now += 10 * SEC;
    }
    assert!(!b.admit("opencode", now), "churn trips it");
    assert!(b.admit("claude", now), "only that harness");
    assert_eq!(b.view(now)["harnesses"]["opencode"]["reason"], "churn");
    // An entry that lived past the churn age is no churn.
    let mut calm = StartBreaker::default();
    for i in 0..10 {
        let at = Duration::from_secs(1000 + i * 10);
        calm.note_unused_end("opencode", at, at + CHURN_AGE + SEC);
    }
    assert!(calm.admit("opencode", Duration::from_secs(2000)));
    // After the cooldown and a calm, the next trip starts at the base cooldown again.
    let later = now + BASE_COOLDOWN + CALM + SEC;
    assert!(b.admit("opencode", later));
    for _ in 0..CHURN_TRIPS {
        b.note_unused_end("opencode", later, later + SEC);
    }
    let v = b.view(later + SEC);
    assert_eq!(v["harnesses"]["opencode"]["strikes"], 1, "{v}");
    assert!(v["harnesses"]["opencode"]["reopensInMs"].as_u64().unwrap() <= 60_000);
}

#[test]
fn the_status_line_names_a_tripped_scope() {
    let mut b = StartBreaker::default();
    let now = Duration::from_secs(1);
    let status = |b: &StartBreaker| json!({"pool": {"breaker": b.view(now)}});
    assert_eq!(status_line(&status(&b)), None, "never tripped: no line");
    for _ in 0..=HARNESS_PER_MINUTE {
        b.admit("claude", now);
    }
    let line = status_line(&status(&b)).unwrap();
    assert!(line.contains("paused for claude (budget, 60s left)"), "{line}");
}

/// A hub whose breaker is tripped for every harness, with one chat open on the stand-in agent.
async fn tripped_hub() -> std::sync::Arc<crate::hub::Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let now = crate::hub::pool::lock(&hub.clock).now();
    {
        let mut b = crate::hub::pool::lock(&hub.pool.breaker);
        for _ in 0..=GLOBAL_PER_MINUTE {
            b.admit("other", now);
            b.admit("fake", now);
        }
        assert!(!b.admit("fake", now));
    }
    assert_eq!(hub.pool_view_json()["breaker"]["tripped"], true);
    hub
}

#[tokio::test]
async fn a_tripped_breaker_never_blocks_a_persons_start() {
    let hub = tripped_hub().await;
    for _ in 0..3 {
        let req = crate::hub::NewRequest {
            cwd: Some(std::env::temp_dir()),
            ..crate::hub::NewRequest::default()
        };
        let session = hub.new_session(req).await.expect("a person's session/new starts");
        let child = session.child.lock().await.clone().expect("its agent started");
        assert!(child.is_alive().await);
    }
    // A running agent costs no background start: warming its chat still reports it.
    let warmed = hub.warm_sessions(&[], 10, false, true).await;
    assert!(!warmed.is_empty(), "a live chat is warm without a start");
}
