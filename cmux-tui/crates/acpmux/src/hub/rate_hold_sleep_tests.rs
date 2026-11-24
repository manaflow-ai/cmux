//! A held chat sleeps (`rate_hold.rs`, "A held chat sleeps"): a hold further away than the idle
//! period lets the chat hibernate despite its queue and its continuation, and its reset wakes
//! it for one turn. A Codex chat on a lane VM was held 6 days with its harness up.

use super::*;
use crate::clock::ManualClock;
use crate::config::{Config, StoreMode};
use crate::protocol::session::RetryReason;
use std::path::Path;
use std::time::Duration;

const LIMIT: &str =
    "API Error: Request rejected (429) · This request would exceed your account's rate limit";

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn kinds(hub: &Hub, id: &str, kind: &str) -> Vec<EventRecord> {
    hub.events(id, 0, 10_000).unwrap().into_iter().filter(|e| e.kind == kind).collect()
}

async fn until(what: &str, done: impl Fn() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(std::time::Instant::now() < deadline, "{what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Held 10 minutes away, with a message queued and its continuation waiting on the hold: it
/// may hibernate (the default idle period is 2 minutes). Parked, too.
#[tokio::test]
async fn a_chat_held_past_its_idle_period_is_eligible_with_its_queue_and_continuation() {
    let (hub, session) = chat().await;
    hub.hold_for_rate_limit(&session, "t-cut", now_ms() + 600_000, true);
    hub.set_waiting_for_test(&session, "t-cut", RetryReason::RateLimit);
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert!(hub.continuation_pending(&session));
    assert!(hub.idle_eligible(&session), "held 10 minutes away");
    hub.park_at_stop(&session, true);
    assert!(hub.idle_eligible(&session), "parked");
    // Hibernation off: nothing sleeps.
    hub.set_idle_child(None);
    assert!(!hub.idle_eligible(&session), "hibernation is off");
    session.queued.fetch_sub(1, Ordering::SeqCst);
    hub.shutdown_all().await;
}

/// A hold due within the idle period keeps the chat awake, as before: its reset comes first.
#[tokio::test]
async fn a_chat_whose_hold_is_due_within_its_idle_period_stays_awake() {
    let (hub, session) = chat().await;
    hub.hold_for_rate_limit(&session, "t-cut", now_ms() + 30_000, true);
    hub.set_waiting_for_test(&session, "t-cut", RetryReason::RateLimit);
    assert!(!hub.idle_eligible(&session), "due in 30 s, idle period 2 minutes");
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert!(!hub.idle_eligible(&session), "due in 30 s, with a message queued");
    session.queued.fetch_sub(1, Ordering::SeqCst);
    hub.shutdown_all().await;
}

/// No hold: a pending continuation, or a queued prompt, keeps the chat awake as before. A held
/// chat whose continuation waits for anything but the hold does too.
#[tokio::test]
async fn a_pending_continuation_without_a_hold_still_keeps_the_chat_awake() {
    let (hub, session) = chat().await;
    assert!(hub.idle_eligible(&session));
    for reason in [RetryReason::Capacity, RetryReason::RateLimit] {
        hub.set_waiting_for_test(&session, "t-cut", reason);
        assert!(!hub.idle_eligible(&session), "a {reason:?} continuation, no hold");
    }
    hub.set_ending_for_test(&session, None);
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert!(!hub.idle_eligible(&session), "a queued prompt, no hold");
    session.queued.fetch_sub(1, Ordering::SeqCst);
    hub.hold_for_rate_limit(&session, "t-cut", now_ms() + 600_000, true);
    hub.set_waiting_for_test(&session, "t-cut", RetryReason::Capacity);
    assert!(!hub.idle_eligible(&session), "held, its continuation waiting for capacity");
    hub.set_ending_for_test(&session, Some("t-cut"));
    assert!(!hub.idle_eligible(&session), "held, its continuation being decided");
    hub.shutdown_all().await;
}

/// The whole path: a turn fails on the 429 with a reset 6 s away, another agent's message
/// queues, the idle period (1 s here) passes and the harness exits. At the reset the hold's
/// timer wakes the chat: one turn starts, carrying the message and the continuation's words.
#[tokio::test]
async fn a_hibernated_held_chat_wakes_at_its_reset_for_one_turn_with_what_queued() {
    let (hub, session) = chat().await;
    let clock = ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(1)));
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = session.id.clone();
    let text = format!("recover-once: {LIMIT}; Retry-After: 6");
    let opts = PromptOptions { prompt_id: Some("p-cut".into()), ..PromptOptions::default() };
    let cut =
        hub.prompt_with(&session, vec![json!({"type": "text", "text": text})], "test", false, opts);
    assert!(cut.await.is_err(), "the 429 fails the turn");
    until("no continuation waits on the hold", || {
        Hub::rate_held(&session)
            && hub.continuation_pending(&session)
            && hub.continuation_waits_on_hold(&session)
    })
    .await;
    let reset = kinds(&hub, &id, "rate_limit_held").last().unwrap().msg["until"].as_u64().unwrap();
    let sent = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            let opts = PromptOptions {
                prompt_id: Some("m-late".into()),
                agent: Some("lane".into()),
                ..PromptOptions::default()
            };
            let blocks = vec![json!({"type": "text", "text": "late report"})];
            hub.prompt_with(&session, blocks, "test", false, opts).await
        })
    };
    until("the message never queued", || session.queue().len() == 1).await;
    assert!(now_ms() + 1_000 < reset, "the test reached the reset before it hibernated");

    // Past the idle period: the harness exits, queue and continuation kept.
    clock.advance(Duration::from_secs(2));
    until("the held chat never hibernated", || {
        session.hibernated_at.load(Ordering::SeqCst) != 0
            && session.child.try_lock().is_ok_and(|c| c.is_none())
    })
    .await;
    assert!(now_ms() < reset, "the reset came before the hibernation was seen");
    assert_eq!(session.queue().len(), 1, "the queue survives the hibernation");
    assert!(hub.continuation_pending(&session), "the continuation survives the hibernation");
    assert_eq!(kinds(&hub, &id, "turn_started").len(), 1);

    // The reset: the message's turn runs, which starts the agent again.
    let done = tokio::time::timeout(Duration::from_secs(30), sent).await;
    done.expect("the queued message never ran").unwrap().expect("its turn failed");
    let started = kinds(&hub, &id, "turn_started");
    assert_eq!(started.len(), 2, "exactly one turn after the reset");
    assert!(started[1].at >= reset, "it started before the reset: {} < {reset}", started[1].at);
    let folded = kinds(&hub, &id, "auto_resume_skipped");
    assert_eq!(folded.len(), 1, "{folded:?}");
    assert_eq!(folded[0].msg["skipped"], "folded", "{folded:?}");
    let last = kinds(&hub, &id, "user_message").pop().unwrap().msg.to_string();
    assert!(last.contains("late report"), "the queued message is lost: {last}");
    assert!(last.contains("rate limit"), "the turn carries the continuation's words: {last}");
    assert!(session.child.try_lock().is_ok_and(|c| c.is_some()), "the agent is up again");
    assert_eq!(session.hibernated_at.load(Ordering::SeqCst), 0, "the wake cleared it");
    hub.shutdown_all().await;
}
