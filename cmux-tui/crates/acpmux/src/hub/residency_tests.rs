//! The idle policies (`residency.rs`) and the versioned `residency` record a summary and the
//! daemon status carry.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

const MIN: u64 = 60 * 1_000_000_000;

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

#[test]
fn only_adaptive_names_parse_to_the_adaptive_policy() {
    assert_eq!(IdlePolicyKind::parse(None), IdlePolicyKind::Static);
    assert_eq!(IdlePolicyKind::parse(Some("")), IdlePolicyKind::Static);
    assert_eq!(IdlePolicyKind::parse(Some("static")), IdlePolicyKind::Static);
    assert_eq!(IdlePolicyKind::parse(Some("adaptive-v2")), IdlePolicyKind::Static);
    assert_eq!(IdlePolicyKind::parse(Some(" adaptive-v1\n")), IdlePolicyKind::AdaptiveV1);
    assert_eq!(IdlePolicyKind::parse(Some("adaptive")), IdlePolicyKind::AdaptiveV1);
    assert_eq!(IdlePolicyKind::AdaptiveV1.name(), "adaptive-v1");
}

#[test]
fn a_rhythm_keeps_the_last_gaps_and_takes_their_median() {
    let mut r = Rhythm::default();
    assert_eq!(r.median(), None);
    r.began(5 * MIN);
    assert_eq!(r.median(), None, "a first turn ends no gap");
    let mut t = 10 * MIN;
    for gap in 1..=30u64 {
        r.ended(t);
        t += gap * MIN;
        r.began(t);
        t += MIN;
    }
    // The last 20 of gaps 1..=30 minutes: 11..=30, lower median 20.
    assert_eq!(r.median(), Some(Duration::from_secs(20 * 60)));
    r.began(t + MIN);
    assert_eq!(r.median(), Some(Duration::from_secs(20 * 60)), "a start with no end before it");
}

#[test]
fn adaptive_holds_close_prompts_and_lets_sparse_or_notified_chats_go() {
    let base = Duration::from_secs(120);
    assert_eq!(adaptive_period(None, false, base), base, "no gap seen: the static period");
    assert_eq!(adaptive_period(Some(Duration::from_secs(60)), false, base), LONG);
    assert_eq!(adaptive_period(SPARSE.checked_add(Duration::from_secs(1)), false, base), SHORT);
    assert_eq!(adaptive_period(Some(SPARSE), false, base), LONG);
    assert_eq!(adaptive_period(Some(Duration::from_secs(60)), true, base), SHORT, "a notice comes");
    assert_eq!(adaptive_period(None, true, base), SHORT);
}

#[tokio::test]
async fn the_policy_picks_the_period_and_the_summary_says_which() {
    let (hub, session) = chat().await;
    let idle = Duration::from_secs(120);
    {
        let mut r = session.idle_rhythm.lock().unwrap();
        for i in 0..5 {
            r.ended(i * 10 * MIN + 1);
            r.began(i * 10 * MIN + MIN);
        }
    }
    assert_eq!(hub.idle_policy(), IdlePolicyKind::Static, "static unless asked");
    assert_eq!(hub.idle_period_for(&session, idle), idle);
    let summary = hub.session_summary(&session);
    let r = acpmux_book::index::residency::Residency::of(summary.get("residency")).unwrap();
    assert_eq!(r.v, 1);
    assert_eq!(r.policy.as_ref().unwrap().name, "static");
    if r.resident {
        assert_eq!(r.policy.as_ref().unwrap().idle_secs, Some(120));
    }
    hub.set_idle_policy(IdlePolicyKind::AdaptiveV1);
    assert_eq!(hub.idle_period_for(&session, idle), LONG, "gaps of a minute: it stays up");
    let summary = hub.session_summary(&session);
    let r = acpmux_book::index::residency::Residency::of(summary.get("residency")).unwrap();
    assert_eq!(r.policy.as_ref().unwrap().name, "adaptive-v1");
    if r.resident {
        assert_eq!(r.policy.as_ref().unwrap().idle_secs, Some(LONG.as_secs()));
    }
    let status = hub.residency_status(&hub.indexed_live_sessions());
    assert_eq!(status["v"], 1);
    assert_eq!(status["policy"]["name"], "adaptive-v1");
    assert!(status["resident"].as_u64().unwrap() >= status["busy"].as_u64().unwrap());
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_closed_chat_is_not_resident_and_no_cap_counts_it() {
    let (hub, session) = chat().await;
    let r = hub.residency_of(&session, SessionStatus::Closed);
    assert!(!r.resident && !r.busy && !r.counts_for_cap());
    assert!(!costs_for_cap(&session, true) || session.status() != SessionStatus::Closed);
    let ready = hub.residency_of(&session, SessionStatus::Ready);
    assert!(ready.resident && !ready.busy && ready.counts_for_cap());
    let running = hub.residency_of(&session, SessionStatus::Running);
    assert!(running.resident && running.busy);
    hub.shutdown_all().await;
}
