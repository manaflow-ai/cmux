//! The size watch on outgoing messages (`wire_size.rs`).

use std::time::{Duration, Instant};

use serde_json::json;

use super::*;
use crate::rpc::{MAX_MESSAGE_BYTES, Message};

/// `p` percent of the per-message cap.
fn pct(p: usize) -> usize {
    MAX_MESSAGE_BYTES / 100 * p
}

#[test]
fn a_message_under_three_quarters_of_the_cap_is_not_counted() {
    let watch = SizeWatch::new();
    assert!(!watch.observe(What::Method("session/update"), pct(70)));
    assert!(!watch.observe(What::Reply, NEAR_CAP_BYTES - 1));
    let s = watch.status();
    assert_eq!(s["nearCap"], 0);
    assert_eq!(s["tooLarge"], 0);
    assert!(s["lastMethod"].is_null(), "{s}");
}

/// One at 80% of the cap is counted every time, and warned of once per method a minute.
#[test]
fn a_message_at_80_percent_counts_near_cap_and_warns_once_per_method() {
    let watch = SizeWatch::new();
    assert!(watch.observe(What::Method("_acpmux/session_changed"), pct(80)));
    assert!(
        !watch.observe(What::Method("_acpmux/session_changed"), pct(81)),
        "a second warning for the same method within the minute"
    );
    assert!(
        watch.observe(What::ReplyTo("_acpmux/sessions"), pct(80)),
        "another method warns on its own"
    );
    let s = watch.status();
    assert_eq!(s["nearCap"], 3);
    assert_eq!(s["tooLarge"], 0);
    assert_eq!(s["lastMethod"], "reply to _acpmux/sessions");
    assert_eq!(s["lastBytes"], pct(80));
    assert_eq!(s["lastTooLarge"], false);
    assert!(s["lastAt"].as_u64().is_some_and(|t| t > 0), "{s}");
    assert_eq!(s["nearCapBytes"], NEAR_CAP_BYTES);
    assert_eq!(s["limit"], MAX_MESSAGE_BYTES);
}

/// One at exactly the cap still goes out: near the cap. One byte more is refused: too large,
/// warned of apart from the near-cap warning for the same method.
#[test]
fn a_message_over_the_cap_counts_too_large() {
    let watch = SizeWatch::new();
    assert!(watch.observe(What::Method("session/update"), MAX_MESSAGE_BYTES));
    assert!(watch.observe(What::Method("session/update"), MAX_MESSAGE_BYTES + 1));
    assert!(!watch.observe(What::Method("session/update"), MAX_MESSAGE_BYTES + 2));
    let s = watch.status();
    assert_eq!(s["nearCap"], 1);
    assert_eq!(s["tooLarge"], 2);
    assert_eq!(s["lastMethod"], "session/update");
    assert_eq!(s["lastBytes"], MAX_MESSAGE_BYTES + 2);
    assert_eq!(s["lastTooLarge"], true);
}

#[test]
fn a_method_warns_again_after_a_quiet_minute() {
    let watch = SizeWatch::new();
    let t0 = Instant::now();
    assert!(watch.observe_at(What::Method("session/update"), pct(90), t0));
    assert!(!watch.observe_at(What::Method("session/update"), pct(90), t0 + WARN_EVERY / 2));
    assert!(watch.observe_at(
        What::Method("session/update"),
        pct(90),
        t0 + WARN_EVERY + Duration::from_secs(1)
    ));
    assert_eq!(watch.status()["nearCap"], 3);
}

/// Methods are few, but a label is made from what a peer sent: the warned set stays bounded,
/// and a full set never cuts a method's quiet minute short; a new method waits for room.
#[test]
fn the_methods_remembered_for_the_quiet_minute_are_bounded() {
    let watch = SizeWatch::new();
    let t0 = Instant::now();
    for n in 0..WARN_KEYS {
        let method = format!("_x/{n}");
        assert!(watch.observe_at(What::Method(&method), pct(80), t0));
    }
    let later = t0 + WARN_EVERY / 2;
    for n in WARN_KEYS..(WARN_KEYS * 3) {
        let method = format!("_x/{n}");
        assert!(!watch.observe_at(What::Method(&method), pct(80), later), "no room for {method}");
    }
    assert!(!watch.observe_at(What::Method("_x/0"), pct(80), later), "_x/0 is still quiet");
    assert_eq!(watch.warned_len(), WARN_KEYS);
    assert_eq!(watch.status()["nearCap"], WARN_KEYS * 3 + 1, "every one is counted");
    // A minute on, the expired make room.
    let after = t0 + WARN_EVERY + Duration::from_secs(1);
    assert!(watch.observe_at(What::Method("_y/new"), pct(80), after));
    assert!(watch.observe_at(What::Method("_x/0"), pct(80), after));
    assert!(watch.warned_len() <= WARN_KEYS);
}

#[test]
fn a_reply_names_the_request_it_answers_when_that_is_known() {
    let reply = Message::ok(json!(1), json!({}));
    assert_eq!(What::of(&reply, Some("_acpmux/sessions")).label(), "reply to _acpmux/sessions");
    assert_eq!(What::of(&reply, None).label(), "reply");
    let note = Message::notification("session/update", json!({}));
    assert_eq!(What::of(&note, Some("ignored")).label(), "session/update");
    let request = Message::request(2, "_acpmux/github_action", json!({}));
    assert_eq!(What::of(&request, None).label(), "_acpmux/github_action");
}

/// `bounded_line` is where every capped send measures its line: it counts what it refuses in
/// the daemon-wide watch, and what it sends near the cap.
#[test]
fn bounded_line_counts_in_the_daemon_wide_watch() {
    let count = |key: &str| global().status()[key].as_u64().unwrap_or(0);
    let (near, over) = (count("nearCap"), count("tooLarge"));
    let big = json!({"text": "x".repeat(MAX_MESSAGE_BYTES)});
    assert!(Message::notification("_acpmux/size_watch_test", big.clone()).bounded_line().is_err());
    let reply = Message::ok(json!(3), big).bounded_line_replying(Some("_acpmux/sessions")).unwrap();
    assert!(reply.contains("message.too_large"), "{reply}");
    assert!(count("tooLarge") >= over + 2);
    let near_line = json!({"text": "x".repeat(pct(80))});
    assert!(Message::notification("_acpmux/size_watch_test", near_line).bounded_line().is_ok());
    assert!(count("nearCap") > near);
}

/// `_acpmux/status` reports the counts as `largeMessages`.
#[tokio::test]
async fn daemon_status_reports_large_messages() {
    global().observe(What::Method("_acpmux/size_watch_status_test"), pct(90));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let status = hub.status().await;
    let large = &status["largeMessages"];
    assert!(large["nearCap"].as_u64().is_some_and(|n| n >= 1), "{large}");
    assert!(large["tooLarge"].as_u64().is_some(), "{large}");
    assert_eq!(large["limit"], MAX_MESSAGE_BYTES);
    assert!(large["lastBytes"].as_u64().is_some_and(|b| b >= pct(75) as u64), "{large}");
}
