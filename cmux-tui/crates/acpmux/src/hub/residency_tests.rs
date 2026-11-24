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

#[test]
fn a_restored_rhythm_keeps_its_gaps_and_the_gap_under_way() {
    let saved: Vec<u64> = (1..=25).map(|m| m * 60_000).collect();
    let mut r = Rhythm::restored(&saved, Some(3 * 60_000), 7 * MIN);
    assert_eq!(r.gaps(), saved[5..].to_vec(), "the last 20");
    r.began(9 * MIN);
    assert_eq!(r.gaps().last(), Some(&(5 * 60_000)), "3 min before the restart and 2 after");
    r.ended(10 * MIN);
    r.began(11 * MIN);
    assert_eq!(r.gaps().last(), Some(&60_000), "nothing carried past the first gap");
    let mut fresh = Rhythm::restored(&[], None, 7 * MIN);
    fresh.began(8 * MIN);
    assert!(fresh.gaps().is_empty(), "no last turn: no gap");
}

#[tokio::test]
async fn a_chats_gaps_reach_its_meta_and_come_back_after_a_restart() {
    let (hub, session) = chat().await;
    {
        let mut r = session.idle_rhythm.lock().unwrap();
        for i in 0..4 {
            r.ended(i * 10 * MIN + 1);
            r.began(i * 10 * MIN + 3 * MIN);
        }
    }
    hub.rhythm_turn_ended(&session);
    let mut meta = session.meta();
    assert_eq!(meta.idle_gaps_ms.len(), 4);
    // Saved and loaded as a daemon restart does.
    let wire = serde_json::to_value(&meta).unwrap();
    meta = serde_json::from_value(wire).unwrap();
    assert_eq!(meta.idle_gaps_ms.len(), 4);
    meta.last_turn = Some(json!({"endedAt": crate::store::now_ms() - 60_000}));
    let r = hub.restored_rhythm(&meta);
    assert_eq!(r.median(), Some(Duration::from_millis(179_999)), "{:?}", r.gaps());
    // An older meta without the field loads with no gaps.
    let mut old = serde_json::to_value(&meta).unwrap();
    old.as_object_mut().unwrap().retain(|k, _| !k.to_ascii_lowercase().contains("gaps"));
    let old: crate::store::SessionMeta = serde_json::from_value(old).unwrap();
    assert!(old.idle_gaps_ms.is_empty());
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_filler_chat_counts_for_no_cap_and_goes_first() {
    use crate::store::Tag;
    let tag = |v: &str, exp: Option<u64>| {
        std::collections::BTreeMap::from([(
            FILLER_TAG.to_owned(),
            Tag { value: v.into(), expires_at: exp },
        )])
    };
    assert!(tags_say_filler(&tag("true", None), 10));
    assert!(tags_say_filler(&tag(" TRUE", Some(11)), 10));
    assert!(!tags_say_filler(&tag("true", Some(10)), 10), "expired");
    assert!(!tags_say_filler(&tag("false", None), 10));
    assert!(!tags_say_filler(&Default::default(), 10));
    let (hub, session) = chat().await;
    let idle = Duration::from_secs(120);
    hub.set_idle_policy(IdlePolicyKind::AdaptiveV1);
    {
        let mut r = session.idle_rhythm.lock().unwrap();
        r.ended(1);
        r.began(MIN);
    }
    assert_eq!(hub.idle_period_for(&session, idle), LONG);
    assert!(!hub.residency_of(&session, SessionStatus::Ready).filler);
    session.meta.lock().unwrap().tags = tag("true", None);
    let r = hub.residency_of(&session, SessionStatus::Ready);
    assert!(r.resident && r.filler && !r.counts_for_cap());
    assert!(!costs_for_cap(&session, true));
    assert_eq!(hub.idle_period_for(&session, idle), SHORT, "filler hibernates first");
    hub.shutdown_all().await;
}
