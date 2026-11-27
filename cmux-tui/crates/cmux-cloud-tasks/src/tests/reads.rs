//! The two answer readers, a Run's card, the saved list's format and a hand-off's words.

use serde_json::json;

use crate::follower::{Effect, Event, Kind, step};
use crate::handoff;
use crate::model::{self, Notice, Outcome, State};
use crate::read::{self, Read};

fn run(body: &str) -> &'static str {
    match read::run(body) {
        Read::Going { .. } => "running",
        Read::Unreadable => "unreadable",
        Read::Ended(Outcome::Succeeded) => "succeeded",
        Read::Ended(Outcome::Failed) => "failed",
        Read::Ended(Outcome::TimedOut) => "timedOut",
        Read::Ended(Outcome::Cancelled) => "cancelled",
        Read::Ended(Outcome::NeedsYou) => "needsYou",
        // A Run's read never closes (only a hand-off does).
        Read::Closed(_) => "closed",
    }
}

#[test]
fn a_body_that_is_no_run_snapshot_is_never_an_end() {
    assert_eq!(run(r#"{"run":{}}"#), "unreadable");
    assert_eq!(run(r#"{"run":{"status":"weird"}}"#), "unreadable");
    assert_eq!(run("[]"), "unreadable");
    assert_eq!(run("not json"), "unreadable");
    assert_eq!(run(r#"{"run":{"status":"failed"},"receipt":{}}"#), "unreadable");
    assert_eq!(run(r#"{"run":{"status":"failed"},"receipt":"done"}"#), "unreadable");
    // A terminal status before its receipt is written: the Run's end is the receipt.
    assert_eq!(run(r#"{"run":{"status":"failed"},"receipt":null}"#), "running");
    assert_eq!(run(r#"{"run":{"id":"r1","status":"running"}}"#), "running");
    assert_eq!(
        run(r#"{"run":{"status":"succeeded"},"receipt":{"status":"succeeded","exitCode":0}}"#),
        "succeeded"
    );
    assert_eq!(
        run(r#"{"run":{"status":"cancelled"},"receipt":{"status":"cancelled"}}"#),
        "cancelled"
    );
    assert_eq!(
        run(r#"{"run":{"status":"failed"},"receipt":{"status":"failed","timedOut":true}}"#),
        "timedOut"
    );
    assert_eq!(
        run(r#"{"run":{"status":"failed"},"receipt":{"status":"failed","timedOut":false}}"#),
        "failed"
    );
}

#[test]
fn a_hand_off_body_of_another_shape_is_unreadable() {
    for body in [
        "{}",
        r#"{"handoff":{"status":"done"}}"#,
        r#"{"handoff":{"status":"paused","version":2}}"#,
        "nope",
        r#"{"handoff":{"status":"done","version":2,"state":"archived"}}"#,
        r#"{"run":{"status":"succeeded"},"receipt":{"status":"succeeded"}}"#,
    ] {
        assert_eq!(read::handoff(body), Read::Unreadable, "read {body} as an answer");
    }
    let starting =
        read::handoff(r#"{"handoff":{"status":"starting","version":7,"turn":1,"state":"open"}}"#);
    assert_eq!(
        starting,
        Read::Going { cursor: Some(7), notice: None, running: true },
        "starting is progress of a turn that runs"
    );
    let done =
        read::handoff(r#"{"handoff":{"status":"done","version":8,"turn":2,"state":"open"}}"#);
    let notice = Notice { key: "2:done".into(), outcome: Outcome::Succeeded };
    assert_eq!(
        done,
        Read::Going { cursor: Some(8), notice: Some(notice), running: false },
        "a turn's done goes on"
    );
    // A store from before turns closes at the first end, and counts it turn 1.
    let before = read::handoff(r#"{"handoff":{"status":"failed","version":3}}"#);
    assert_eq!(
        before,
        Read::Closed(Some(Notice { key: "1:failed".into(), outcome: Outcome::Failed }))
    );
    assert_eq!(
        read::handoff(r#"{"handoff":{"status":"cancelled","version":3,"state":"closed"}}"#),
        Read::Closed(None)
    );
}

#[test]
fn a_hand_offs_words() {
    assert_eq!(
        handoff::notice("needs-you", Some(3)),
        Some(Notice { key: "3:needs-you".into(), outcome: Outcome::NeedsYou })
    );
    for quiet in ["cancelled", "starting", "running"] {
        assert_eq!(handoff::notice(quiet, Some(1)), None);
    }
    assert!(handoff::is_open("done", Some("open")) && !handoff::is_open("running", Some("closed")));
    assert!(handoff::is_open("running", None) && !handoff::is_open("done", None));
    assert!(
        handoff::is_running("starting")
            && handoff::is_running("running")
            && !handoff::is_running("needs-you")
    );
}

#[test]
fn the_lists_times_are_read_as_the_store_sends_them() {
    let created = handoff::iso_millis("2026-10-20T10:00:00.000Z").expect("an ISO time");
    assert!((created - 1_792_490_400_000.0).abs() < 1.0);
    let updated = handoff::iso_millis("2026-10-28T09:30:00.250Z").expect("an ISO time");
    assert!((updated - 1_793_179_800_250.0).abs() < 1.0);
    assert_eq!(handoff::iso_millis("2026-10-20T10:00:00Z"), Some(1_792_490_400_000.0));
    assert_eq!(handoff::iso_millis("2026-10-20T12:00:00+02:00"), Some(1_792_490_400_000.0));
    assert_eq!(handoff::iso_millis("2024-02-29T00:00:00Z"), Some(1_709_164_800_000.0));
    assert_eq!(handoff::millis(&json!(1_792_490_400_000u64)), Some(1_792_490_400_000.0));
    assert_eq!(handoff::millis(&json!("2026-10-20T10:00:00Z")), Some(1_792_490_400_000.0));
    assert_eq!(handoff::millis(&json!(null)), None);
    for wrong in [
        "yesterday",
        "2026-10-20",
        "2026-02-30T00:00:00Z",
        "2026-10-20T10:00:00",
        "2026-10-20T25:00:00Z",
    ] {
        assert_eq!(handoff::iso_millis(wrong), None, "{wrong}");
    }
}

#[test]
fn a_card_keeps_the_receipt_alone() {
    let card = read::card(r#"{"run":{"status":"succeeded"},"receipt":{"status":"succeeded"}}"#);
    let expected = serde_json::to_string(&json!({"receipt": {"status": "succeeded"}})).unwrap();
    assert_eq!(card, Some(read::base64(expected.as_bytes())));
    assert_eq!(read::card(r#"{"run":{"status":"running"}}"#), None);
    assert_eq!(read::card(r#"{"handoff":{"status":"done"}}"#), None);
    assert_eq!(read::base64(b""), "");
    assert_eq!(read::base64(b"f"), "Zg==");
    assert_eq!(read::base64(b"fo"), "Zm8=");
    assert_eq!(read::base64(b"foobar"), "Zm9vYmFy");
}

/// A list the app saved before the move to Rust (Swift's JSONEncoder: dates as seconds since
/// 2001, the card as base64, absent optionals left out) reads, and is written back the same way.
#[test]
fn the_saved_list_keeps_the_apps_format() {
    let saved = r#"{"following":[{"id":"r2","task":"b","key":"k2","user":"u1","started":815000100.5,"cursor":3,"running":true},
        {"id":"r1","task":"a","key":"k1","user":"u1","team":"t1","started":815000000.25},
        {"id":"r1","task":"copy","key":"k1","user":"u1","started":1}],
        "ended":[{"record":{"id":"r0","task":"x","key":"k0","user":"u1","started":814999000},"outcome":"timedOut",
        "card":"eyJyZWNlaXB0Ijp7fX0=","at":815000000,"told":false}],
        "cancelled":["r9"],"incognito":["ho_1"],"incognitoOwners":{"ho_1":"u1"}}"#;
    let state = model::load(Some(saved));
    let ids: Vec<&str> = state.records.iter().map(|record| record.id.as_str()).collect();
    assert_eq!(ids, ["r1", "r2"], "oldest first, a record saved twice keeps its first copy");
    assert_eq!(state.records[0].task, "a");
    assert_eq!(state.ended[0].card.as_deref(), Some("eyJyZWNlaXB0Ijp7fX0="));
    assert_eq!(
        (state.cancelled.clone(), state.incognito.clone()),
        (vec!["r9".to_string()], vec!["ho_1".to_string()])
    );
    let written: serde_json::Value = serde_json::from_str(&model::saved(&state)).unwrap();
    assert_eq!(
        written["following"][0],
        json!({"id":"r1","task":"a","key":"k1","user":"u1","team":"t1","started":815000000.25})
    );
    assert_eq!(written["ended"][0]["outcome"], "timedOut");
    assert_eq!(written["ended"][0]["at"], json!(815000000.0));
    assert_eq!(written["incognitoOwners"], json!({"ho_1": "u1"}));
    assert!(written.get("user").is_none() && written.get("records").is_none());
    // A list from before the cancels and incognito ids were kept still reads.
    let old = model::load(Some(r#"{"following":[],"ended":[]}"#));
    assert_eq!(old, State::default());
    // One that does not read starts empty.
    assert_eq!(model::load(Some(r#"{"following":[{"id":"r1"}],"ended":[]}"#)), State::default());
    assert_eq!(model::load(None), State::default());
}

/// An end saves before it tells, so a crash inside the banner leaves it to the next launch.
#[test]
fn an_end_saves_answers_then_tells() {
    let record = super::sim::run_record("r1", "u1");
    let followed = step(Kind::Runs, State::default(), Event::Follow { record }, super::sim::NOW);
    let body = r#"{"run":{"status":"succeeded"},"receipt":{"status":"succeeded"}}"#;
    let event = Event::Answer {
        id: "r1".into(),
        body: Some(body.into()),
        status: None,
        failed: false,
        cancelled: false,
    };
    let ended = step(Kind::Runs, followed.state, event, super::sim::NOW);
    let order: Vec<&str> = ended
        .effects
        .iter()
        .map(|effect| match effect {
            Effect::Save => "save",
            Effect::ClearPoll { .. } => "clearPoll",
            Effect::Answer { .. } => "answer",
            Effect::Tell { mark_told: true, .. } => "tell+mark",
            _ => "other",
        })
        .collect();
    assert_eq!(order, ["save", "clearPoll", "answer", "tell+mark"]);
    assert_eq!(ended.state.ended_run("r1").map(|ended| ended.told), Some(false));
}
