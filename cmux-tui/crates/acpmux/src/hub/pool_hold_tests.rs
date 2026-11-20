//! The one hold every turn's end goes through (`rate_hold.rs` `Hub::limit_failure`) and the
//! pool's hold (`pool_hold.rs`).
use super::*;
use crate::hub::rate_hold::{MIN_HOLD_MS, PARK_AFTER, hold_until};

const LIMIT: &str =
    "API Error: Request rejected (429) · This request would exceed your account's rate limit";
const POOL: &str = "API Error: 503 no non-exhausted claude accounts available, next account frees \
                    up in 1h6m (retry after 3930s). This is a server-side issue, usually temporary.";

fn hub_with(ids: &[(&str, &str)], delays: Option<Vec<u64>>) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    cfg.auto_resume_delays_ms = delays;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    for (id, harness) in ids {
        let meta = json!({"schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": harness, "cwd": "/tmp", "status": "idle", "turnCount": 3,
            "createdAt": 1, "updatedAt": 2});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    }
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    hub
}

fn notice() -> Value {
    json!({"kind": "notice", "fromName": "acpmux"})
}

fn held_for(session: &Session) -> u64 {
    session.rate_hold.until().expect("held").saturating_sub(now_ms())
}

/// glass-chrome-polish, 2026-11-20: a notice's turn failed on the 429 six times, 61 s apart,
/// with continuations off. Every failure of a turn no continuation follows holds for the
/// backoff of the chat's strikes now: 1, 2, 4 minutes (and a fifth more at most), never a flat
/// minute.
#[tokio::test]
async fn a_notices_429_holds_for_the_strikes_backoff_not_a_flat_minute() {
    let hub = hub_with(&[("gcp", "claude")], Some(Vec::new()));
    let session = hub.resolve("gcp").unwrap();
    let mut held = Vec::new();
    for n in 1..=3u64 {
        hub.limit_failure(&session, &format!("t{n}"), LIMIT, None, false);
        assert!(hub.rate_holds(&session, Some(&notice())), "a notice waits for the hold");
        assert!(session.rate_hold.probing(), "the next turn is a probe: nothing steers in");
        held.push(held_for(&session));
        hub.lift_rate_hold(&session, "reset");
    }
    for (n, ms) in held.iter().enumerate() {
        let least = MIN_HOLD_MS << n;
        assert!(*ms + 50 >= least && *ms <= least + least / 5 + 50, "strike {}: {held:?}", n + 1);
    }
    assert_eq!(session.rate_hold.retries_last_hour(), 3);
    let row = hub.session_summary(&session);
    assert_eq!(row["rateLimitRetries1h"], 3, "{row}");
}

/// A reset the error names holds until then, however few the strikes.
#[tokio::test]
async fn a_named_reset_holds_until_it() {
    let hub = hub_with(&[("gcp", "claude")], Some(vec![25, 25]));
    let session = hub.resolve("gcp").unwrap();
    hub.limit_failure(&session, "t1", &format!("{LIMIT}; Retry-After: 900"), None, false);
    let ms = held_for(&session);
    assert!((899_000..=900_100).contains(&ms), "{ms}");
}

/// A turn its continuation follows is held by that continuation (`schedule_auto_resume`), not
/// twice: one strike per failure.
#[tokio::test]
async fn a_continued_turn_is_not_struck_twice() {
    let hub = hub_with(&[("gcp", "claude")], Some(vec![25, 25]));
    let session = hub.resolve("gcp").unwrap();
    hub.limit_failure(&session, "t1", LIMIT, None, true);
    assert_eq!(session.rate_hold.strikes(), 0);
    assert!(!Hub::rate_held(&session));
}

/// The pool's 503 holds every chat of its harness at once, until the gateway's reset; a Codex
/// chat on the same daemon goes on.
#[tokio::test]
async fn the_pools_503_holds_every_chat_of_the_pool_until_its_reset() {
    let hub = hub_with(&[("a", "claude"), ("b", "claude"), ("c", "codex")], Some(Vec::new()));
    let (a, b, c) =
        (hub.resolve("a").unwrap(), hub.resolve("b").unwrap(), hub.resolve("c").unwrap());
    hub.limit_failure(&a, "t1", POOL, None, false);
    for s in [&a, &b] {
        assert!(hub.rate_holds(s, Some(&notice())), "{} waits", s.id);
        let until = hub.session_summary(s)["rateLimitedUntil"].as_u64().unwrap();
        let ms = until.saturating_sub(now_ms());
        assert!((3_929_000..=3_930_100).contains(&ms), "{}: {ms}", s.id);
    }
    assert!(!hub.rate_holds(&c, Some(&notice())), "another harness's chat goes on");
    assert_eq!(a.rate_hold.strikes(), 0, "the pool's limit is no strike of the chat");
    // A later failure with a sooner reset never moves the deadline earlier.
    let before = hub.pool_until(&b).unwrap();
    hub.limit_failure(
        &b,
        "t2",
        "API Error: 503 no non-exhausted claude accounts (retry after 5s)",
        None,
        false,
    );
    assert!(hub.pool_until(&a).unwrap() >= before);
}

/// At the reset one chat probes; the others still wait. Its turn that ends otherwise than on
/// the pool's limit lifts the hold for all; one that fails on it again holds them all, longer.
#[tokio::test]
async fn one_probe_decides_for_the_whole_pool() {
    let hub = hub_with(&[("a", "claude"), ("b", "claude")], Some(vec![25, 25]));
    let (a, b) = (hub.resolve("a").unwrap(), hub.resolve("b").unwrap());
    hub.limit_failure(&a, "t1", POOL, None, false);
    let first = hub.pool_until(&a).unwrap();
    hub.pool_hold.lock().probe = Some((b.id.clone(), now_ms()));
    assert!(!hub.pool_holds(&b), "the probe goes");
    assert!(hub.pool_holds(&a), "the others wait for it");
    // The probe failed on the pool again: everyone held, the probe too, no sooner than before.
    hub.limit_failure(&b, "t2", POOL, None, false);
    hub.pool_turn_ended(&b, Some(POOL));
    assert!(hub.pool_holds(&b) && hub.pool_holds(&a));
    assert!(hub.pool_until(&a).unwrap() >= first);
    assert_eq!(hub.pool_hold.lock().strikes, 2);
    // The next probe's turn went well: the hold ends for every chat.
    hub.pool_hold.lock().probe = Some((b.id.clone(), now_ms()));
    hub.pool_turn_ended(&a, None);
    assert!(hub.pool_holds(&a), "a turn of another chat decides nothing");
    hub.pool_turn_ended(&b, None);
    assert!(!hub.pool_holds(&a) && !hub.pool_holds(&b));
    assert_eq!(hub.pool_hold.lock().strikes, 0);
    let lifted = hub.events(&b.id, 0, 1_000).unwrap();
    assert!(lifted.iter().any(|e| e.kind == "rate_limit_pool_lifted"), "the probe says it");
}

/// With no chat holding work at the reset nothing would be sent: the hold ends, no probe.
#[tokio::test]
async fn a_reset_with_no_work_waiting_ends_the_hold() {
    let hub = hub_with(&[("a", "claude")], Some(vec![25, 25]));
    let a = hub.resolve("a").unwrap();
    hub.limit_failure(&a, "t1", "API Error: 503 no non-exhausted claude accounts", None, false);
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while hub.pool_holds(&a) {
        assert!(tokio::time::Instant::now() < deadline, "still held");
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(hub.pool_hold.lock().probe.is_none());
}

/// Continuations off (`autoResumeDelaysMs: []`) still bring a limited chat back by itself.
#[test]
fn a_limits_continuation_is_on_with_continuations_off() {
    assert_eq!(crate::hub::auto_resume::rate_limit_waits(Vec::new(), MIN_HOLD_MS), [MIN_HOLD_MS]);
    assert_eq!(crate::hub::auto_resume::rate_limit_waits(vec![5, 6], MIN_HOLD_MS), [5, 6]);
}

/// The before/after count of turns the limit refuses, from one replay: one chat under a 429
/// that names no reset, a notice always waiting (glass-chrome-polish), and a pool of 37 chats
/// under the gateway's 503 with a `retry after 3930s`, each with a notice every 5 minutes,
/// for an hour. Before: every failure held a flat minute and the pool's 503 held nothing.
#[test]
fn replay_refired_turns_per_hour() {
    const HOUR: u64 = 3_600_000;
    // One chat: a turn at each hold's end, parked at PARK_AFTER strikes.
    let chat = |hold: &dyn Fn(u64, u32) -> u64| {
        let (mut t, mut turns) = (0u64, 0u32);
        while t < HOUR && turns < PARK_AFTER {
            turns += 1;
            t = hold(t, turns);
        }
        (turns, t)
    };
    let (before, before_span) = chat(&|t, _| t + MIN_HOLD_MS);
    let (after, after_span) = chat(&|t, n| hold_until(t, n, MIN_HOLD_MS, None, "gcp"));
    eprintln!(
        "one chat, 429: before {before} turns in {} s; after {after} in {} s",
        before_span / 1000,
        after_span / 1000
    );
    assert!(after_span >= 25 * before_span / 4, "{after_span} vs {before_span}");
    // The pool: before, each notice of each chat is a turn into the 503; after, the chats that
    // ran when it came fail once, then one probe per reset.
    let (chats, every) = (37u64, 5 * 60_000u64);
    let pool_before = chats * (HOUR / every);
    let reset = 3_930_000u64;
    let step = hold_until(0, 1, MIN_HOLD_MS, Some(reset), "pool");
    // At worst every chat had a turn running when the first 503 came: each fails once.
    let first_hour = chats + HOUR.div_ceil(step);
    let steady = HOUR.div_ceil(step);
    eprintln!(
        "pool of {chats}, 503: before {pool_before} turns/h; after {first_hour} in the first hour, \
         {steady}/h after"
    );
    assert!(first_hour * 10 < pool_before && steady == 1);
}
