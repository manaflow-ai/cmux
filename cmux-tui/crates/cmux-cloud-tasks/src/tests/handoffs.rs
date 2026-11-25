//! Hand-offs: one lasts the whole session and counts turns; each turn's done, failed and
//! needs-you is told once (per id, turn and status), a cancel and progress never, and the follow
//! stops only when it closes (ported from the app's HandoffNoticeTests).

use serde_json::{Value, json};

use super::sim::{Answer, DAY, NOW, Sim, body};
use crate::follower::{Event, Kind};
use crate::handoff;
use crate::model::{Outcome, Record};

const ID: &str = "ho_0123456789abcdef0123";

/// A `{handoff}` answer; `turn` and `state` none leave them out (the store before turns).
fn answer(
    status: &str,
    version: i64,
    turn: Option<i64>,
    state: Option<&str>,
    summary: Option<&str>,
) -> Answer {
    answer_of(ID, status, version, turn, state, summary)
}

fn answer_of(
    id: &str,
    status: &str,
    version: i64,
    turn: Option<i64>,
    state: Option<&str>,
    summary: Option<&str>,
) -> Answer {
    let mut handoff = json!({"id": id, "sessionId": "s1", "status": status, "version": version, "summary": summary});
    if let Some(turn) = turn {
        handoff["turn"] = json!(turn);
    }
    if let Some(state) = state {
        handoff["state"] = json!(state);
    }
    body(&json!({ "handoff": handoff }).to_string())
}

/// An open turn-1 answer.
fn open(status: &str, version: i64) -> Answer {
    answer(status, version, Some(1), Some("open"), None)
}

/// One entry of the owner's list, as the app reads it.
struct Listed {
    id: String,
    status: &'static str,
    created: f64,
    updated: Option<f64>,
    version: Option<i64>,
    turn: Option<i64>,
}

fn listed(status: &'static str, version: Option<i64>, turn: Option<i64>) -> Listed {
    Listed { id: ID.into(), status, created: NOW, updated: None, version, turn }
}

/// The app's `HandoffNotices.record`: its chat is the record's key; a turn that runs is never
/// given up for age.
fn record_of(entry: &Listed) -> Record {
    Record {
        id: entry.id.clone(),
        task: String::new(),
        key: "s1".into(),
        user: "u1".into(),
        team: None,
        started: entry.created,
        cursor: None,
        told: None,
        changed: None,
        running: handoff::is_running(entry.status).then_some(true),
        host: None,
        incognito: None,
    }
}

/// The app's `HandoffNotices.listed` at `seen`: followed from where the list shows it.
fn listed_record(entry: &Listed, seen: f64) -> Record {
    let mut record = record_of(entry);
    record.cursor = entry.version;
    record.told = handoff::notice(entry.status, entry.turn).map(|notice| vec![notice.key]);
    record.changed = Some(entry.updated.unwrap_or(seen));
    record
}

/// A hand-off this app just made.
fn record(id: &str) -> Record {
    let mut entry = listed("starting", None, None);
    entry.id = id.into();
    record_of(&entry)
}

fn incognito(id: &str) -> Record {
    Record { incognito: Some(true), ..record(id) }
}

/// A follower signed in as `u1`.
fn follower(saved: Option<String>) -> Sim {
    let mut sim = Sim::launch(Kind::Handoffs, saved);
    sim.account(Some("u1"));
    sim
}

fn summary(snapshot: Option<&str>) -> Option<String> {
    let value: Value = serde_json::from_str(snapshot?).ok()?;
    value["handoff"]["summary"].as_str().map(str::to_string)
}

fn cursors(sim: &Sim) -> Vec<Option<i64>> {
    sim.calls.iter().map(|(_, cursor)| *cursor).collect()
}

#[test]
fn each_turns_done_and_needs_you_are_told_once_and_the_follow_outlives_a_turn() {
    let mut sim = follower(None);
    sim.script(
        ID,
        vec![
            open("starting", 1),
            open("running", 2),
            open("needs-you", 3),
            open("needs-you", 3),
            open("running", 4),
            // The same turn stops for the person again: (turn 1, needs-you) was told.
            open("needs-you", 5),
            answer("done", 6, Some(1), Some("open"), Some("Fixed the test")),
            // A follow-up in the same chat: turn 2 on the same id, whose done is told too.
            answer("running", 7, Some(2), Some("open"), None),
            answer("done", 8, Some(2), Some("open"), Some("Pushed")),
            answer("done", 9, Some(2), Some("closed"), Some("Pushed")),
        ],
    );
    sim.watch(record(ID));
    sim.settle();
    assert_eq!(sim.outcomes(), [Outcome::NeedsYou, Outcome::Succeeded, Outcome::Succeeded]);
    let summaries: Vec<Option<String>> =
        sim.told.iter().map(|told| summary(told.snapshot.as_deref())).collect();
    assert_eq!(summaries, [None, Some("Fixed the test".into()), Some("Pushed".into())]);
    // Each wait passes the version the last one saw.
    assert_eq!(
        cursors(&sim),
        [None, Some(1), Some(2), Some(3), Some(3), Some(4), Some(5), Some(6), Some(7), Some(8)]
    );
    // Closed: no more waits, and nothing is told for the close itself.
    assert!(sim.state.records.is_empty());
    assert_eq!(sim.state.ended_run(ID).map(|ended| ended.told), Some(true));
}

#[test]
fn a_cancel_and_progress_are_never_told() {
    let mut sim = follower(None);
    sim.script(
        ID,
        vec![
            open("running", 2),
            open("cancelled", 3),
            answer("running", 4, Some(2), Some("open"), None),
            answer("cancelled", 5, Some(2), Some("closed"), None),
        ],
    );
    sim.watch(record(ID));
    sim.settle();
    assert!(sim.told.is_empty());
    assert_eq!(sim.calls.len(), 4);
}

#[test]
fn a_failed_turn_is_told_once_and_a_closing_turn_end_not_yet_told_is_told() {
    let mut sim = follower(None);
    sim.script(
        ID,
        vec![
            answer("failed", 2, Some(1), Some("open"), Some("The build broke")),
            answer("failed", 3, Some(1), Some("closed"), None),
        ],
    );
    sim.watch(record(ID));
    sim.settle();
    assert_eq!(sim.outcomes(), [Outcome::Failed]);
    let mut closing = follower(None);
    closing.script(ID, vec![answer("done", 2, Some(3), Some("closed"), None)]);
    closing.watch(record(ID));
    closing.settle();
    assert_eq!(closing.outcomes(), [Outcome::Succeeded]);
}

#[test]
fn a_store_before_turns_closes_at_the_first_end() {
    let mut sim = follower(None);
    sim.script(
        ID,
        vec![answer("running", 2, None, None, None), answer("done", 3, None, None, None)],
    );
    sim.watch(record(ID));
    sim.settle();
    assert_eq!(sim.outcomes(), [Outcome::Succeeded]);
    assert_eq!(sim.calls.len(), 2);
}

#[test]
fn a_told_stop_is_not_told_again_after_a_relaunch() {
    let mut first = follower(None);
    first.script(ID, vec![open("needs-you", 3)]);
    first.watch(record(ID));
    first.run(1);
    assert_eq!(first.told.len(), 1);
    first.stop();
    let mut relaunched = Sim::launch(Kind::Handoffs, first.saved.clone());
    assert!(relaunched.state.knows(ID));
    // The relaunch's wait passes the version already seen, and the same stop tells nothing.
    relaunched.script(ID, vec![open("needs-you", 3), Answer::Status(404)]);
    relaunched.account(Some("u1"));
    relaunched.settle();
    assert!(relaunched.told.is_empty());
    assert_eq!(cursors(&relaunched), [Some(3), Some(3)]);
}

/// Issue #31040: an incognito hand-off is never saved, so after a relaunch it comes back from the
/// owner's list. It stays incognito there: its later banners are redacted, and its click opens nothing.
#[test]
fn an_incognito_handoff_found_in_the_list_after_a_relaunch_stays_incognito() {
    let mut first = follower(None);
    first.script(ID, vec![open("running", 2)]);
    first.watch(incognito(ID));
    first.run(1);
    first.stop();
    let mut relaunched = follower(first.saved.clone());
    assert!(!relaunched.state.knows(ID), "an incognito hand-off's record outlived the run");
    relaunched.script(
        ID,
        vec![open("needs-you", 3), answer("done", 4, Some(1), Some("closed"), Some("Pushed"))],
    );
    relaunched.watch(listed_record(&listed("running", Some(2), Some(1)), NOW));
    relaunched.settle();
    assert_eq!(relaunched.outcomes(), [Outcome::NeedsYou, Outcome::Succeeded]);
    let flags: Vec<Option<bool>> =
        relaunched.told.iter().map(|told| told.record.incognito).collect();
    assert_eq!(
        flags,
        [Some(true), Some(true)],
        "a relaunch's banner of an incognito hand-off posted its full text"
    );
    assert_eq!(relaunched.state.ended_run(ID).and_then(|ended| ended.record.incognito), Some(true));
}

/// Review of #31055: the owner's list can answer before the app's own watch of an incognito
/// hand-off; the watch's flag reaches the record already followed, which is then no longer saved.
#[test]
fn an_incognito_watch_after_the_listed_record_makes_it_incognito() {
    let mut sim = follower(None);
    sim.script(ID, vec![open("running", 2)]);
    sim.watch(listed_record(&listed("running", Some(2), Some(1)), NOW));
    sim.watch(incognito(ID));
    assert_eq!(sim.state.records[0].incognito, Some(true));
    sim.stop();
    let relaunched = follower(sim.saved.clone());
    assert!(
        !relaunched.state.records.iter().any(|record| record.id == ID),
        "an incognito hand-off's record was saved"
    );
}

/// Review of #31055: the listed record can even end before the app's own incognito watch; the
/// ended record is then flagged too, and no longer saved.
#[test]
fn an_incognito_watch_after_the_listed_record_ended_makes_it_incognito() {
    let mut sim = follower(None);
    sim.script(ID, vec![answer("done", 3, Some(1), Some("closed"), Some("Pushed"))]);
    sim.watch(listed_record(&listed("running", Some(2), Some(1)), NOW));
    sim.settle();
    sim.watch(incognito(ID));
    assert_eq!(sim.state.ended_run(ID).and_then(|ended| ended.record.incognito), Some(true));
    let relaunched = follower(sim.saved.clone());
    assert!(
        relaunched.state.ended_run(ID).is_none(),
        "an incognito hand-off's ended record was saved"
    );
}

#[test]
fn a_handoff_found_in_the_list_tells_only_what_changes_after() {
    let mut sim = follower(None);
    // The store answers at its deadline with the state the list showed, then turn 3 runs and ends.
    sim.script(
        ID,
        vec![
            answer("done", 5, Some(2), Some("open"), None),
            answer("running", 6, Some(3), Some("open"), None),
            answer("done", 7, Some(3), Some("open"), None),
            answer("done", 8, Some(3), Some("closed"), None),
        ],
    );
    sim.watch(listed_record(&listed("done", Some(5), Some(2)), NOW));
    sim.settle();
    assert_eq!(sim.outcomes(), [Outcome::Succeeded]);
    assert_eq!(sim.calls[0].1, Some(5));
}

#[test]
fn a_handoff_the_store_no_longer_shows_is_dropped_untold() {
    let mut sim = follower(None);
    sim.watch(record(ID));
    sim.settle();
    assert!(sim.told.is_empty());
    assert!(!sim.state.knows(ID));
}

#[test]
fn a_session_made_long_ago_is_followed_from_its_last_change_not_its_creation() {
    // Made four days ago, last changed an hour ago: its next turn is told.
    let mut sim = follower(None);
    sim.script(
        ID,
        vec![
            answer("done", 5, Some(2), Some("open"), None),
            answer("running", 6, Some(3), Some("open"), None),
            answer("done", 7, Some(3), Some("open"), None),
            answer("done", 8, Some(3), Some("closed"), None),
        ],
    );
    let recent = Listed {
        created: NOW - 4.0 * DAY,
        updated: Some(NOW - DAY / 24.0),
        ..listed("done", None, Some(2))
    };
    sim.watch(listed_record(&recent, NOW));
    sim.settle();
    assert_eq!(sim.outcomes(), [Outcome::Succeeded]);
    // A list without its last change: counted from when the app first saw it.
    let mut unknown = follower(None);
    unknown.script(
        ID,
        vec![
            answer("done", 7, Some(3), Some("open"), None),
            answer("done", 8, Some(3), Some("closed"), None),
        ],
    );
    let undated = Listed { created: NOW - 4.0 * DAY, ..listed("running", None, Some(3)) };
    let record = listed_record(&undated, NOW);
    assert_eq!(record.changed, Some(NOW));
    unknown.watch(record);
    unknown.settle();
    assert_eq!(unknown.outcomes(), [Outcome::Succeeded]);
    // One idle for more than three days, its turn not running, is still given up before a wait.
    let mut idle = follower(None);
    idle.script(ID, vec![answer("running", 9, Some(4), Some("open"), None)]);
    let old = Listed {
        created: NOW - 5.0 * DAY,
        updated: Some(NOW - 4.0 * DAY),
        ..listed("done", None, Some(3))
    };
    idle.watch(listed_record(&old, NOW));
    idle.settle();
    assert!(idle.calls.is_empty());
    assert!(idle.told.is_empty());
    assert!(!idle.state.knows(ID));
}

#[test]
fn a_record_saved_long_ago_is_dated_from_the_lists_last_change() {
    // Saved at an earlier launch four days ago, its turn done then; the list shows a turn begun an hour ago.
    let mut sim = follower(None);
    sim.script(
        ID,
        vec![
            answer("running", 6, Some(3), Some("open"), None),
            answer("done", 7, Some(3), Some("open"), None),
            answer("done", 8, Some(3), Some("closed"), None),
        ],
    );
    let saved = Listed {
        created: NOW - 5.0 * DAY,
        updated: Some(NOW - 4.0 * DAY),
        ..listed("done", None, Some(2))
    };
    sim.watch(listed_record(&saved, NOW));
    // Before its poll first looks at its age.
    sim.event(Event::Refresh { id: ID.into(), changed: NOW - DAY / 24.0, running: true });
    assert_eq!(sim.state.records[0].running, Some(true));
    // An older date never moves it back.
    sim.event(Event::Refresh { id: ID.into(), changed: NOW - 4.0 * DAY, running: true });
    assert!(sim.state.records[0].changed.is_some_and(|changed| changed > NOW - 7_200.0));
    sim.settle();
    assert_eq!(sim.outcomes(), [Outcome::Succeeded]);
    assert_eq!(sim.calls.len(), 3);
}

#[test]
fn a_refresh_that_changes_nothing_saves_nothing() {
    let mut sim = follower(None);
    let saved = Listed { updated: Some(NOW - DAY), ..listed("done", None, Some(2)) };
    sim.watch(listed_record(&saved, NOW));
    let reply =
        sim.event(Event::Refresh { id: ID.into(), changed: NOW - 2.0 * DAY, running: false });
    assert!(reply.effects.is_empty());
    // A task not followed is left.
    assert!(
        sim.event(Event::Refresh { id: "ho_other".into(), changed: NOW, running: true })
            .effects
            .is_empty()
    );
}

#[test]
fn a_turn_that_runs_is_never_given_up_for_age() {
    // Each wait takes two days: the turn runs for six days without a change, then ends.
    let mut sim = follower(None);
    sim.per_wait = 2.0 * DAY;
    sim.script(
        ID,
        vec![
            open("running", 2),
            open("running", 2),
            open("running", 2),
            open("running", 2),
            answer("done", 3, Some(1), Some("open"), Some("Fixed")),
            answer("done", 4, Some(1), Some("closed"), Some("Fixed")),
        ],
    );
    // Listed while its turn runs, its last change four days old.
    let running = Listed {
        created: NOW - 4.0 * DAY,
        updated: Some(NOW - 4.0 * DAY),
        ..listed("running", None, Some(1))
    };
    sim.watch(listed_record(&running, NOW));
    sim.settle();
    assert_eq!(sim.outcomes(), [Outcome::Succeeded]);
    assert_eq!(cursors(&sim), [None, Some(2), Some(2), Some(2), Some(2), Some(3)]);
}

#[test]
fn a_turn_that_runs_is_given_up_after_three_days_without_an_answer() {
    // The store answers nothing readable, each try two days apart: given up at the third.
    let mut sim = follower(None);
    sim.per_wait = 2.0 * DAY;
    sim.script(ID, vec![Answer::Status(500)]);
    sim.watch(record(ID));
    sim.settle();
    assert!(!sim.state.knows(ID));
    assert_eq!(sim.calls.len(), 2);
}

/// Issue #31208: an incognito hand-off that closed while the app was stopped is never resumed
/// (its record isn't saved), so nothing removed its id. Once the signed-in list answers, an id of
/// that user neither followed nor open in the list is dropped; one open in the list, one followed
/// by this launch, and another account's stay.
#[test]
fn incognito_ids_neither_followed_nor_listed_are_dropped_once_the_list_answers() {
    let (gone, listed_id, followed) =
        ("ho_0123456789abcdef0124", "ho_0123456789abcdef0125", "ho_0123456789abcdef0126");
    let (closed, other) = ("ho_0123456789abcdef0127", "ho_0123456789abcdef0128");
    let mut first = Sim::launch(Kind::Handoffs, None);
    for id in [gone, listed_id, followed, closed, other] {
        first.script(id, vec![answer_of(id, "running", 2, Some(1), Some("open"), None)]);
    }
    // Another account's open incognito hand-off, made before u1 signed in.
    first.account(Some("u2"));
    first.watch(Record { user: "u2".into(), ..incognito(other) });
    first.account(Some("u1"));
    for id in [gone, listed_id, followed, closed] {
        first.watch(incognito(id));
    }
    first.stop();
    assert!(
        [gone, listed_id, followed, closed, other].iter().all(|id| first.saved_text().contains(id))
    );
    // The relaunch: this app watches `followed` again before the list answers; `gone` and
    // `closed` closed while it was stopped.
    let mut relaunched = follower(first.saved.clone());
    relaunched.watch(incognito(followed));
    // The app's list answer: the open entries it does not know are watched, then the rest pruned.
    let open_entry = Listed { id: listed_id.into(), ..listed("running", Some(2), Some(1)) };
    relaunched.watch(listed_record(&open_entry, NOW));
    relaunched.event(Event::KeepIncognito { listed: vec![listed_id.into()] });
    let saved = relaunched.saved_text();
    assert!(
        !saved.contains(gone),
        "an incognito hand-off that ended while the app was stopped kept its id"
    );
    assert!(!saved.contains(closed), "a closed incognito hand-off in the list kept its id");
    assert!(saved.contains(listed_id) && saved.contains(followed));
    assert!(
        saved.contains(other),
        "another account's list took its incognito hand-off's flag away"
    );
    let mut flagged: Vec<&str> = relaunched
        .state
        .records
        .iter()
        .filter(|record| record.is_incognito())
        .map(|record| record.id.as_str())
        .collect();
    flagged.sort_unstable();
    assert_eq!(flagged, [listed_id, followed]);
}

#[test]
fn a_follower_with_no_user_watches_nothing() {
    let mut sim = Sim::launch(Kind::Handoffs, None);
    sim.script(ID, vec![open("running", 2)]);
    // Not signed in yet (the session still loading).
    sim.watch(record(ID));
    assert!(!sim.state.knows(ID) && sim.polls.is_empty());
    // Signed out.
    sim.account(Some("u1"));
    sim.account(None);
    sim.watch(record(ID));
    assert!(!sim.state.knows(ID) && sim.polls.is_empty());
    // No sign-in at all keeps the list for the next one.
    assert!(sim.event(Event::KeepIncognito { listed: Vec::new() }).effects.is_empty());
    assert!(sim.calls.is_empty());
}
