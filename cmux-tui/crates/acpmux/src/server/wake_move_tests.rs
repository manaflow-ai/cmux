//! A wake's move (`wake_move.rs`, RFD 0181 B6 step 2).

use super::*;
use crate::hub::wake_place::{Action, Decision, Facts, act, agent_wake_cause, decide};

fn verdict() -> Value {
    json!({"pick": "roomy", "hosts": [
        {"name": "here", "local": true, "room": 0.0},
        {"name": "roomy", "room": 4.0},
    ]})
}

fn registry() -> Value {
    json!({"machines": {
        "here": {"lanes": {"max_lanes": 6}},
        "roomy": {"lanes": {"max_lanes": 12}},
    }})
}

fn facts(live: usize) -> Facts {
    Facts { live, max: Some(6), ..Facts::default() }
}

#[test]
fn a_wake_moves_only_with_a_target_and_the_switch_on() {
    let d = decide(&facts(6), &verdict(), Some(&registry()), "here");
    assert_eq!(act(&d, true), Action::Move("roomy".into()));
    assert_eq!(act(&d, false), Action::Here("lane_overflow.rebalance is off for this host"));
    let under = decide(&facts(2), &Value::Null, Some(&registry()), "here");
    assert_eq!(act(&under, true), Action::Here("fits here"));
    let pinned = decide(&Facts { pinned: true, ..facts(9) }, &verdict(), Some(&registry()), "here");
    assert_eq!(act(&pinned, true), Action::Here("pinned to this machine"));
}

#[test]
fn the_switch_is_off_unless_the_registry_turns_it_on_for_this_host() {
    let conf = |r: Value| crate::rebalance::conf(Some(&r)).on_for("here");
    assert!(!conf(registry()), "absent: off");
    assert!(conf(json!({"lane_overflow": {"rebalance": {"enabled": true}}})));
    assert!(!conf(json!({"lane_overflow": {"rebalance": {"enabled": true, "hosts": ["other"]}}})));
}

#[test]
fn only_a_prompt_that_names_an_agent_or_the_daemon_moves() {
    assert_eq!(agent_wake_cause(None), None, "no provenance: may be a person's");
    assert_eq!(agent_wake_cause(Some(&json!({"kind": "odd"}))), None);
    let msg = json!({"kind": "agent_message"});
    assert_eq!(agent_wake_cause(Some(&msg)), Some("agent-msg"));
    assert_eq!(agent_wake_cause(Some(&json!({"bgTaskId": "b1"}))), Some("bg-notice"));
}

#[test]
fn a_plan_is_fenced_by_the_epoch_it_was_decided_at() {
    assert!(fresh(3, 3));
    assert!(!fresh(3, 4), "the chat moved meanwhile: the plan moves nothing");
}

#[test]
fn where_the_move_left_the_chat_decides_who_starts_it() {
    assert_eq!(landed(true, false), Landed::Moved, "committed: the prompt follows it");
    assert_eq!(landed(true, true), Landed::Moved);
    assert_eq!(landed(false, true), Landed::Moving, "frozen: neither side starts it");
    assert_eq!(landed(false, false), Landed::Here, "failed or timed out: it wakes here");
}

#[test]
fn the_move_has_its_own_bound() {
    assert_eq!(LIMIT, Duration::from_secs(120));
    assert!(LIMIT < Duration::from_secs(1800), "shorter than a pick's move: a prompt waits on it");
}

#[tokio::test]
async fn one_wake_moves_a_chat_at_a_time() {
    let a = gate("chat-1");
    let held = a.lock().await;
    let b = gate("chat-1");
    assert!(b.try_lock().is_err(), "a second prompt waits for the first's move");
    assert!(gate("chat-2").try_lock().is_ok(), "another chat does not");
    drop(held);
    assert!(b.try_lock().is_ok());
}

/// The RFD's measurement, on step 1's fleet (32 hosts, one wake each, 25 past their cap and 1
/// more held): wakes that start on a past-cap or held host. Step 1 moved none (26). With the
/// switch on and every move committed, none starts there (0). With the switch on and every move
/// failing or past its bound, each wakes where it slept (26): the fallback.
#[test]
fn wakes_that_start_on_past_cap_or_held_hosts_before_and_after() {
    let starts_misplaced = |on: bool, commits: bool| {
        (0..32)
            .filter(|&i| {
                let f = Facts {
                    live: if i < 25 { 6 + i % 4 } else { 3 },
                    held: (i == 30).then(|| "held".into()),
                    ..facts(0)
                };
                let d: Decision = decide(&f, &verdict(), Some(&registry()), "here");
                let moved = matches!(act(&d, on), Action::Move(_))
                    && landed(commits, false) == Landed::Moved;
                (d.past_cap || d.held) && !moved
            })
            .count()
    };
    assert_eq!(starts_misplaced(false, true), 26, "switch off: step 1's count");
    assert_eq!(starts_misplaced(true, true), 0, "switch on, moves commit");
    assert_eq!(starts_misplaced(true, false), 26, "switch on, moves fail: they wake here");
}
