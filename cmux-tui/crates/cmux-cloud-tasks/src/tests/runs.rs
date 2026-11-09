//! Sandboxed Runs: each end is told once, never twice, and never for the person's own cancel
//! (ported from the app's SandboxRunNoticeTests).

use super::sim::{Answer, NOW, Sim, body, run_record};
use crate::follower::{Event, Failure, KEPT_ENDED, Kind};
use crate::model::Outcome;
use crate::read;

const RUNNING: &str = r#"{"run":{"id":"r1","status":"running"}}"#;
const SUCCEEDED: &str =
    r#"{"run":{"id":"r1","status":"succeeded"},"receipt":{"status":"succeeded","exitCode":0}}"#;
const CANCELLED: &str =
    r#"{"run":{"id":"r1","status":"cancelled"},"receipt":{"status":"cancelled"}}"#;

fn timed_out(id: &str) -> Failure {
    Failure::TimedOut { path: format!("/api/runs/{id}") }
}

#[test]
fn a_run_that_ends_is_told_once_and_its_send_gets_the_snapshot() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.script("r1", vec![body(RUNNING), body(RUNNING), body(SUCCEEDED)]);
    assert_eq!(sim.follow(run_record("r1", "u1")), Ok(SUCCEEDED.to_string()));
    assert_eq!(sim.outcomes(), [Outcome::Succeeded]);
    assert_eq!(sim.told[0].record.task, "Fix the flaky test\nthen push");
    assert!(!sim.polls.contains("r1"));
    assert!(sim.state.records.is_empty());
    // A late follow of the same Run (a page reload) tells nothing again.
    assert!(sim.follow(run_record("r1", "u1")).is_err());
    assert_eq!(sim.told.len(), 1);
    // Nor does a relaunch: the ended Run is no longer saved as in flight.
    let mut relaunched = sim.relaunch();
    relaunched.account(Some("u1"));
    assert!(relaunched.state.records.is_empty());
    assert!(relaunched.told.is_empty());
    assert_eq!(sim.calls.len(), 3);
}

#[test]
fn two_waiters_share_one_poll_and_one_notice() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.script("r1", vec![body(RUNNING), body(SUCCEEDED)]);
    sim.event(Event::Follow { record: run_record("r1", "u1") });
    // The second follow finds the Run followed: no second poll, the same answer.
    assert_eq!(sim.follow(run_record("r1", "u1")), Ok(SUCCEEDED.to_string()));
    assert_eq!(sim.answers["r1"].len(), 1, "one answer for every waiter");
    assert_eq!(sim.told.len(), 1);
    assert_eq!(sim.calls.len(), 2);
}

#[test]
fn the_persons_own_cancel_tells_nothing_but_a_cancel_elsewhere_does() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.script("r1", vec![body(RUNNING), body(CANCELLED)]);
    sim.script("r2", vec![body(RUNNING), body(CANCELLED)]);
    sim.event(Event::Follow { record: run_record("r1", "u1") });
    assert!(sim.polls.contains("r1"));
    sim.event(Event::NoteCancel { id: "r1".into() });
    sim.settle();
    assert!(sim.told.is_empty());
    assert!(sim.follow(run_record("r2", "u1")).is_ok());
    assert_eq!(sim.outcomes(), [Outcome::Cancelled]);
    assert_eq!(sim.told[0].record.id, "r2");
    // The cancel is spent with its Run.
    assert!(sim.state.cancelled.is_empty());
}

#[test]
fn a_cancel_noted_before_the_follow_starts_still_tells_nothing() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.script("r1", vec![body(CANCELLED)]);
    // `runs.cancel` can win the race with the send's hand-off to the follower.
    sim.event(Event::NoteCancel { id: "r1".into() });
    assert!(sim.follow(run_record("r1", "u1")).is_ok());
    assert!(sim.told.is_empty());
}

#[test]
fn a_cancel_noted_before_a_quit_stays_silent_after_the_relaunch() {
    let mut first = Sim::launch(Kind::Runs, None);
    first.script("r1", vec![body(RUNNING)]);
    first.event(Event::Follow { record: run_record("r1", "u1") });
    first.run(1);
    first.event(Event::NoteCancel { id: "r1".into() });
    first.stop();
    let mut relaunched = first.relaunch();
    relaunched.script("r1", vec![body(CANCELLED)]);
    relaunched.account(Some("u1"));
    relaunched.settle();
    assert!(relaunched.state.records.is_empty());
    assert!(relaunched.told.is_empty());
}

#[test]
fn the_cancels_kept_are_bounded_oldest_out() {
    let mut sim = Sim::launch(Kind::Runs, None);
    for index in 0..300 {
        sim.event(Event::NoteCancel { id: format!("r{index}") });
    }
    sim.event(Event::NoteCancel { id: "r299".into() });
    assert_eq!(sim.state.cancelled.len(), crate::follower::CANCEL_LIMIT);
    assert_eq!(sim.state.cancelled.first().map(String::as_str), Some("r44"));
}

#[test]
fn a_run_of_another_account_is_not_followed() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.script("r1", vec![body(SUCCEEDED)]);
    sim.account(Some("u2"));
    assert_eq!(sim.follow(run_record("r1", "u1")), Err(timed_out("r1")));
    assert!(sim.state.records.is_empty());
    assert!(sim.told.is_empty());
    assert!(sim.calls.is_empty());
}

#[test]
fn an_end_saved_but_not_told_is_told_at_the_next_launch_once() {
    let mut first = Sim::launch(Kind::Runs, None);
    first.script("r1", vec![body(SUCCEEDED)]);
    first.follow(run_record("r1", "u1")).unwrap();
    // The app dies inside the banner's post: its end is saved, not yet told.
    let crashed = first.told[0].saved_then.clone();
    let mut relaunched = Sim::launch(Kind::Runs, crashed);
    relaunched.account(Some("u1"));
    assert_eq!(relaunched.outcomes(), [Outcome::Succeeded]);
    assert_eq!(relaunched.told[0].record.task, "Fix the flaky test\nthen push");
    assert!(relaunched.told[0].replayed);
    // A replayed end stays untold until its listener handled the banner: a quit before that
    // leaves it to the next launch.
    assert_eq!(relaunched.state.ended_run("r1").map(|ended| ended.told), Some(false));
    let mut before_mark = relaunched.relaunch();
    before_mark.account(Some("u1"));
    assert_eq!(before_mark.told.len(), 1);
    before_mark.event(Event::MarkTold { id: "r1".into() });
    // Told: a later launch tells nothing again.
    let mut again = before_mark.relaunch();
    again.account(Some("u1"));
    assert!(again.told.is_empty());
}

#[test]
fn many_runs_in_flight_are_all_followed_and_old_cards_take_their_banners() {
    let mut sim = Sim::launch(Kind::Runs, None);
    for index in 0..40 {
        sim.script(&format!("r{index}"), vec![body(SUCCEEDED)]);
    }
    for index in 0..40 {
        sim.follow(run_record(&format!("r{index}"), "u1")).unwrap();
    }
    assert_eq!(sim.told.len(), 40);
    assert!(sim.state.ended_run("r0").is_some());
    let mut relaunched = sim.relaunch();
    relaunched.now = NOW + KEPT_ENDED + 60.0;
    relaunched.account(Some("u1"));
    assert_eq!(relaunched.forgot.len(), 40);
    assert!(relaunched.state.ended_run("r0").is_none());
}

#[test]
fn an_ended_runs_card_outlives_a_relaunch() {
    let mut first = Sim::launch(Kind::Runs, None);
    first.script("r1", vec![body(SUCCEEDED)]);
    first.follow(run_record("r1", "u1")).unwrap();
    let relaunched = first.relaunch();
    let ended = relaunched.state.ended_run("r1").expect("kept");
    assert_eq!(
        (ended.record.key.as_str(), ended.record.task.as_str()),
        ("key-r1", "Fix the flaky test\nthen push")
    );
    assert!(ended.outcome == Outcome::Succeeded && ended.told);
    assert_eq!(ended.card, read::card(SUCCEEDED));
    let receipt = serde_json::json!({"receipt": {"status": "succeeded", "exitCode": 0}});
    assert_eq!(ended.card, Some(read::base64(serde_json::to_string(&receipt).unwrap().as_bytes())));
}

#[test]
fn a_failed_wait_answers_the_send_but_the_follow_goes_on_to_the_notice() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.script("r1", vec![Answer::Status(0), body(SUCCEEDED)]);
    // The send's own answer is "no receipt in time", as the send's own poll answered it.
    assert_eq!(sim.follow(run_record("r1", "u1")), Err(timed_out("r1")));
    sim.settle();
    assert_eq!(sim.outcomes(), [Outcome::Succeeded]);
}

#[test]
fn a_relaunch_resumes_the_saved_runs_of_the_signed_in_user() {
    let mut first = Sim::launch(Kind::Runs, None);
    first.script("r1", vec![body(RUNNING)]);
    // The send is cut off (its pane closed, the app quit) while the Run still runs.
    first.event(Event::Follow { record: run_record("r1", "u1") });
    first.run(1);
    first.stop();
    assert_eq!(
        first.state.records.iter().map(|record| record.id.as_str()).collect::<Vec<_>>(),
        ["r1"]
    );
    let mut relaunched = first.relaunch();
    relaunched.script("r1", vec![body(SUCCEEDED)]);
    relaunched.account(None); // the session still loading keeps the saved Runs
    assert_eq!(relaunched.state.records.len(), 1);
    assert!(relaunched.polls.is_empty());
    relaunched.account(Some("u1"));
    relaunched.settle();
    assert_eq!(relaunched.outcomes(), [Outcome::Succeeded]);
    assert!(relaunched.state.records.is_empty());
}

#[test]
fn a_sign_out_stops_every_follow_and_another_account_drops_the_others_runs() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.script("r1", vec![body(RUNNING)]);
    sim.script("r2", vec![body(RUNNING)]);
    sim.account(Some("u1"));
    sim.event(Event::Follow { record: run_record("r1", "u1") });
    sim.run(1);
    sim.account(None);
    assert_eq!(sim.answers["r1"], [Err(Failure::NotSignedIn)]);
    assert!(sim.state.records.is_empty());
    assert!(!sim.polls.contains("r1"));
    sim.event(Event::Follow { record: run_record("r2", "u1") });
    sim.run(1);
    sim.account(Some("u2"));
    assert_eq!(sim.answers["r2"], [Err(Failure::NotSignedIn)]);
    assert!(sim.state.records.is_empty());
    assert!(sim.told.is_empty());
}

#[test]
fn a_run_unchanged_past_its_maximum_age_is_given_up() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.script("r1", vec![body(RUNNING)]);
    sim.per_wait = 2.0 * 3_600.0;
    assert_eq!(sim.follow(run_record("r1", "u1")).ok(), None);
    sim.settle();
    // Runs read no turn: six hours since its start, whatever the server answers.
    assert_eq!(sim.calls.len(), 3);
    assert!(!sim.state.knows("r1"));
    assert!(sim.told.is_empty());
}

#[test]
fn a_poll_stopped_while_its_call_was_out_leaves_the_answer_to_the_next_launch() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.event(Event::Follow { record: run_record("r1", "u1") });
    let reply = sim.event(Event::Answer {
        id: "r1".into(),
        body: Some(SUCCEEDED.into()),
        status: None,
        failed: false,
        cancelled: true,
    });
    assert!(reply.effects.is_empty());
    assert!(sim.state.knows("r1") && sim.state.ended.is_empty());
    // A 404 still drops it: the server no longer shows it.
    sim.event(Event::Answer {
        id: "r1".into(),
        body: None,
        status: Some(404),
        failed: true,
        cancelled: true,
    });
    assert!(!sim.state.knows("r1"));
}
