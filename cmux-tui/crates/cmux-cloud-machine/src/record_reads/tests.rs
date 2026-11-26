use std::collections::BTreeSet;

use super::{Listed, Reads, Step};

fn held(ids: &[&str]) -> BTreeSet<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

fn listed(ids: &[&str]) -> Vec<Listed> {
    ids.iter().map(|id| Listed { id: (*id).to_owned(), destroyed: false }).collect()
}

fn apply(id: &str) -> Step {
    Step::Apply { machine: id.to_owned() }
}

fn add(id: &str) -> Step {
    Step::Add { machine: id.to_owned() }
}

fn remove(id: &str, destroyed: bool) -> Step {
    Step::Remove { machine: id.to_owned(), destroyed }
}

#[test]
fn tickets_count_up_and_only_one_record_reads_stay_outstanding() {
    let mut reads = Reads::default();
    assert_eq!(reads.begin(None), 1);
    assert_eq!(reads.begin(Some("a")), 2);
    assert_eq!(reads.begin(None), 3);
    assert_eq!(reads.issued, 3);
    assert_eq!(reads.outstanding.len(), 1);
    assert_eq!(reads.outstanding.get(&2).map(String::as_str), Some("a"));
}

#[test]
fn a_list_ticket_finishing_changes_nothing() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    reads.deferred.insert("a".into(), 1);
    let read = reads.begin(None);
    assert!(reads.finish(read, &mut sessions, false).is_empty());
    // The waiting removal was not processed by a list ticket.
    assert_eq!(reads.deferred.get("a"), Some(&1));
    assert!(sessions.contains("a"));
}

#[test]
fn a_list_adds_new_machines_and_applies_held_ones() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let read = reads.begin(None);
    let steps = reads.reconcile(&listed(&["a", "b"]), read, &mut sessions, false);
    assert_eq!(steps, vec![apply("a"), add("b")]);
    assert_eq!(sessions, held(&["a", "b"]));
    assert_eq!(reads.applied.get("a"), Some(&read));
    assert_eq!(reads.applied.get("b"), Some(&read));
}

#[test]
fn a_list_skips_destroyed_records() {
    let mut reads = Reads::default();
    let mut sessions = held(&[]);
    let read = reads.begin(None);
    let list = vec![Listed { id: "gone".into(), destroyed: true }];
    assert!(reads.reconcile(&list, read, &mut sessions, false).is_empty());
    assert!(sessions.is_empty());
}

#[test]
fn a_destroyed_record_in_a_list_counts_as_left_out() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let read = reads.begin(None);
    let list = vec![Listed { id: "a".into(), destroyed: true }];
    let steps = reads.reconcile(&list, read, &mut sessions, false);
    assert_eq!(steps, vec![remove("a", false)]);
}

#[test]
fn an_older_list_does_not_bring_back_a_machine_a_newer_read_removed() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let old = reads.begin(None);
    let newer = reads.begin(Some("a"));
    assert_eq!(reads.apply("a", true, newer, true, &mut sessions, false), vec![remove("a", true)]);
    assert!(sessions.is_empty());
    assert!(reads.reconcile(&listed(&["a"]), old, &mut sessions, false).is_empty());
    assert!(sessions.is_empty());
}

#[test]
fn an_omission_removes_a_machine_with_no_newer_read() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a", "b"]);
    let read = reads.begin(None);
    let steps = reads.reconcile(&listed(&["a"]), read, &mut sessions, false);
    assert_eq!(steps, vec![apply("a"), remove("b", false)]);
    assert_eq!(sessions, held(&["a"]));
    assert!(reads.deferred.is_empty());
    assert_eq!(reads.applied.get("b"), Some(&read));
}

#[test]
fn an_omission_waits_for_a_newer_status_read_of_that_machine() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let list = reads.begin(None);
    let status = reads.begin(Some("a"));
    assert!(reads.reconcile(&[], list, &mut sessions, false).is_empty());
    assert_eq!(reads.deferred.get("a"), Some(&list));
    assert!(sessions.contains("a"));
    // The status read fails: the removal goes now.
    assert_eq!(reads.finish(status, &mut sessions, false), vec![remove("a", false)]);
    assert!(sessions.is_empty());
}

#[test]
fn a_newer_status_read_that_saw_the_machine_cancels_the_omission() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let list = reads.begin(None);
    let status = reads.begin(Some("a"));
    reads.reconcile(&[], list, &mut sessions, false);
    assert_eq!(reads.apply("a", false, status, true, &mut sessions, false), vec![apply("a")]);
    assert!(reads.deferred.is_empty());
    assert!(sessions.contains("a"));
}

#[test]
fn an_older_status_read_does_not_delay_an_omission() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let status = reads.begin(Some("a"));
    let list = reads.begin(None);
    assert_eq!(reads.reconcile(&[], list, &mut sessions, false), vec![remove("a", false)]);
    // The older read lands after: the machine is gone and stays gone.
    assert!(reads.apply("a", false, status, true, &mut sessions, false).is_empty());
    assert!(reads.outstanding.is_empty());
}

#[test]
fn another_machines_status_read_does_not_delay_an_omission() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a", "b"]);
    let list = reads.begin(None);
    let _status_of_b = reads.begin(Some("b"));
    let steps = reads.reconcile(&listed(&["b"]), list, &mut sessions, false);
    assert_eq!(steps, vec![apply("b"), remove("a", false)]);
}

#[test]
fn a_second_omission_keeps_the_newer_list_ticket() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let first = reads.begin(None);
    let second = reads.begin(None);
    let _status = reads.begin(Some("a"));
    reads.reconcile(&[], second, &mut sessions, false);
    reads.reconcile(&[], first, &mut sessions, false);
    assert_eq!(reads.deferred.get("a"), Some(&second));
}

#[test]
fn an_out_of_order_record_changes_nothing_but_still_ends_its_read() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let old = reads.begin(Some("a"));
    let new = reads.begin(Some("a"));
    assert_eq!(reads.apply("a", false, new, true, &mut sessions, false), vec![apply("a")]);
    assert!(reads.apply("a", false, old, true, &mut sessions, false).is_empty());
    assert!(reads.outstanding.is_empty());
    assert_eq!(reads.applied.get("a"), Some(&new));
}

#[test]
fn a_record_for_a_session_no_longer_current_changes_nothing() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let read = reads.begin(Some("a"));
    assert!(reads.apply("a", false, read, false, &mut sessions, false).is_empty());
    assert_eq!(reads.applied.get("a"), None);
    assert!(reads.outstanding.is_empty());
    let mut none = held(&[]);
    let read = reads.begin(Some("a"));
    assert!(reads.apply("a", false, read, true, &mut none, false).is_empty());
}

#[test]
fn a_destroyed_record_removes_its_machine_and_its_waiting_removal() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let list = reads.begin(None);
    let status = reads.begin(Some("a"));
    reads.reconcile(&[], list, &mut sessions, false);
    assert_eq!(reads.apply("a", true, status, true, &mut sessions, false), vec![remove("a", true)]);
    assert!(reads.deferred.is_empty());
    assert!(sessions.is_empty());
}

#[test]
fn turned_off_nothing_joins_changes_or_goes_and_reads_still_end() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let list = reads.begin(None);
    assert!(reads.reconcile(&listed(&["b"]), list, &mut sessions, true).is_empty());
    assert!(reads.deferred.is_empty());
    let status = reads.begin(Some("a"));
    assert!(reads.apply("a", true, status, true, &mut sessions, true).is_empty());
    assert!(reads.outstanding.is_empty());
    assert_eq!(sessions, held(&["a"]));
    // A removal that waited before Cloud was turned off waits on.
    reads.deferred.insert("a".into(), list);
    let status = reads.begin(Some("a"));
    assert!(reads.finish(status, &mut sessions, true).is_empty());
    assert_eq!(reads.deferred.get("a"), Some(&list));
}

#[test]
fn a_removal_that_goes_mid_list_lets_a_later_listed_machine_join_again() {
    // A list's apply of a held machine ends that read, which lets a waiting removal go; a machine
    // the same list names after it then joins as new, as the app's loop did.
    let mut reads = Reads::default();
    let mut sessions = held(&["a", "b"]);
    reads.deferred.insert("b".into(), 1);
    reads.issued = 1;
    let status_a = reads.begin(Some("a"));
    let steps = reads.apply("a", false, status_a, true, &mut sessions, false);
    assert_eq!(steps, vec![apply("a"), remove("b", false)]);
    let list = reads.begin(None);
    let steps = reads.reconcile(&listed(&["a", "b"]), list, &mut sessions, false);
    assert_eq!(steps, vec![apply("a"), add("b")]);
    assert_eq!(sessions, held(&["a", "b"]));
}

#[test]
fn the_state_round_trips_through_json_with_integer_tickets() {
    let mut reads = Reads::default();
    let mut sessions = held(&["a"]);
    let list = reads.begin(None);
    reads.begin(Some("a"));
    reads.reconcile(&[], list, &mut sessions, false);
    let text = serde_json::to_string(&reads).unwrap();
    let back: Reads = serde_json::from_str(&text).unwrap();
    assert_eq!(back, reads);
    let empty: Reads = serde_json::from_str("{}").unwrap();
    assert_eq!(empty, Reads::default());
}

#[test]
fn steps_serialize_with_their_kind() {
    let text = serde_json::to_value(vec![apply("a"), add("b"), remove("c", true)]).unwrap();
    assert_eq!(
        text,
        serde_json::json!([
            {"do": "apply", "machine": "a"},
            {"do": "add", "machine": "b"},
            {"do": "remove", "machine": "c", "destroyed": true},
        ])
    );
}
