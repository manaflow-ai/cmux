//! A session's record rules (moved from the app's CloudMachineRecordEdgeTests and
//! CloudMachineDefaultNameTests).

use serde_json::json;

use super::*;
use crate::record::PauseReason;

fn machine(status: Status) -> Machine {
    Machine::new("vm_a", status)
}

#[test]
fn a_record_edge_suspends_connects_or_retries() {
    let (paused, running) = (machine(Status::Paused), machine(Status::Running));
    assert_eq!(edge(&paused, Status::Running, false, true), Some(Edge::Suspend));
    assert_eq!(edge(&running, Status::Paused, false, false), Some(Edge::Connect));
    // A resume's overlay cleared over a record that already read running: a second live edge.
    assert_eq!(edge(&running, Status::Running, true, false), Some(Edge::Connect));
    assert_eq!(edge(&running, Status::Running, true, true), None);
    // A machine that ran after provisioning or starting answers only now.
    assert_eq!(edge(&running, Status::Provisioning, false, false), Some(Edge::Retry));
    assert_eq!(edge(&running, Status::Starting, false, false), Some(Edge::Retry));
    assert_eq!(edge(&running, Status::Starting, false, true), None);
    assert_eq!(edge(&running, Status::Running, false, false), None);
    assert_eq!(edge(&paused, Status::Paused, false, false), None);
    // Still resuming (the overlay stands): not a second edge.
    let mut resuming = machine(Status::Running);
    resuming.pending_change = Some(Status::Starting);
    assert_eq!(edge(&resuming, Status::Running, true, false), None);
}

#[test]
fn only_a_persons_app_link_connect_runs_through_starting() {
    let starting = machine(Status::Starting);
    assert!(
        !holds_connect(&starting, Origin::User, true),
        "a person's retry during a passive wake"
    );
    assert!(holds_connect(&starting, Origin::Script, true));
    assert!(holds_connect(&starting, Origin::User, false), "a legacy link keeps the strict hold");
    for status in [Status::Pausing, Status::Deleting] {
        assert!(holds_connect(&machine(status), Origin::User, true));
    }
    let mut resuming = machine(Status::Paused);
    resuming.pending_change = Some(Status::Starting);
    assert!(!holds_connect(&resuming, Origin::User, true));
    assert!(!holds_connect(&machine(Status::Running), Origin::Script, true));
}

#[test]
fn a_connect_since_the_read_keeps_the_live_status() {
    let mut current = machine(Status::Starting);
    current.running_since = Some(5.0);
    let mut record = machine(Status::Paused);
    record.pause_reason = Some(PauseReason::Idle);
    record.display_name = Some("renamed".into());
    let kept = listed(&record, &current, true);
    assert_eq!(
        (kept.status, kept.pause_reason, kept.running_since),
        (Status::Starting, None, Some(5.0))
    );
    assert_eq!(kept.display_name.as_deref(), Some("renamed"));
    assert_eq!(listed(&record, &current, false), record);
    assert_eq!(listed(&machine(Status::Running), &current, true).status, Status::Running);
}

#[test]
fn a_pin_keeps_only_unlisted_machines_that_are_not_failed_or_going() {
    let mut killing = Machine::new("vm_k", Status::Running);
    killing.pending_change = Some(Status::Deleting);
    let machines = [
        Machine::new("vm_listed", Status::Running),
        Machine::new("vm_new", Status::Provisioning),
        Machine::new("vm_failed", Status::Failed),
        Machine::new("vm_gone", Status::Destroyed),
        killing,
    ];
    assert_eq!(kept_for_pin(&machines, &["vm_listed".into()]), ["vm_new"]);
}

#[test]
fn a_plan_entry_carries_what_is_known() {
    let mut paused = Machine::new("vm_p", Status::Paused);
    paused.slug = Some("calm-sky".into());
    paused.pause_reason = Some(PauseReason::Idle);
    paused.pending_change = Some(Status::Starting);
    assert_eq!(
        Value::Object(start_chat_plan_entry(&paused, false, None)),
        json!({"id": "vm_p", "title": "calm-sky", "status": "starting", "connected": false, "slug": "calm-sky", "pause_reason": "idle"})
    );
    let mut mine = Machine::new("vm_m", Status::Running);
    mine.created_by = Some("user-a".into());
    assert_eq!(
        Value::Object(start_chat_plan_entry(&mine, true, Some(2))),
        json!({"id": "vm_m", "title": "vm_m", "status": "running", "connected": true, "created_by": "user-a", "chats": 2})
    );
}

fn pick(taken: &[&str]) -> String {
    let taken: Vec<String> = taken.iter().map(|title| (*title).to_owned()).collect();
    let candidates: Vec<String> = std::iter::once("Cloud Machine".to_owned())
        .chain((2..=taken.len() + 2).map(|number| format!("Cloud Machine {number}")))
        .collect();
    default_name(&taken, &candidates).unwrap()
}

#[test]
fn the_first_machine_is_cloud_machine() {
    assert_eq!(pick(&[]), "Cloud Machine");
    assert_eq!(pick(&["vm_8f2c1a", "build-box"]), "Cloud Machine");
}

#[test]
fn a_taken_name_counts_on_from_two() {
    assert_eq!(pick(&["Cloud Machine"]), "Cloud Machine 2");
    assert_eq!(pick(&["Cloud Machine", "Cloud Machine 2"]), "Cloud Machine 3");
    assert_eq!(
        pick(&["Cloud Machine", "Cloud Machine 3"]),
        "Cloud Machine 2",
        "the first free number"
    );
    assert_eq!(pick(&["Cloud Machine", "Cloud Machine 2", "Cloud Machine 3"]), "Cloud Machine 4");
}

#[test]
fn titles_compare_trimmed_and_case_insensitively() {
    assert_eq!(pick(&[" cloud machine "]), "Cloud Machine 2");
}
