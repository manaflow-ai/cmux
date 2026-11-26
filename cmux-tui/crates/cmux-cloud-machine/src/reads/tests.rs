//! The read-order rules (the ledger half of the app's CloudIdlePauseTests read-order cases; the
//! app keeps the ones that drive a session).

use super::*;

const VM: &str = "vm_a";

fn vm() -> Vec<String> {
    vec![VM.to_owned()]
}

/// The app's `apply`: admit the record, then retire its ticket.
fn apply(reads: &mut Reads, read: i64) -> (bool, Vec<String>) {
    let admitted = reads.admit(VM, read);
    (admitted, reads.finish(read, false))
}

#[test]
fn tickets_count_up_and_only_one_record_reads_stay_outstanding() {
    let mut reads = Reads::default();
    assert_eq!(reads.begin(None), 1);
    assert!(reads.is_idle(), "a list only orders");
    assert_eq!(reads.begin(Some(VM)), 2);
    assert_eq!(reads.outstanding.get(&2).map(String::as_str), Some(VM));
    assert!(reads.finish(1, false).is_empty(), "a list ticket finishes nothing");
    assert!(reads.finish(2, false).is_empty());
    assert!(reads.is_idle());
}

#[test]
fn an_older_record_landing_after_a_newer_one_changes_nothing() {
    let mut reads = Reads::default();
    let (older_status, older_list, newer) =
        (reads.begin(None), reads.begin(None), reads.begin(None));
    assert!(reads.admit(VM, newer));
    assert!(!reads.admit(VM, older_status), "the newest read's record stays");
    assert!(!reads.admit(VM, older_list));
    let later = reads.begin(None);
    assert!(reads.admit(VM, later), "a read asked after the newest one applies");
}

#[test]
fn an_older_list_without_the_machine_does_not_remove_a_newer_record() {
    let mut reads = Reads::default();
    let older_list = reads.begin(None);
    let status = reads.begin(Some(VM));
    assert_eq!(apply(&mut reads, status), (true, vec![]));
    assert!(reads.omitted(&vm(), older_list, false).is_empty(), "the newer read saw it");
    assert!(reads.deferred.is_empty(), "the omission is superseded, not kept");
    let newer_list = reads.begin(None);
    assert_eq!(reads.omitted(&vm(), newer_list, false), vm(), "a newer list removes it");
    assert_eq!(reads.applied.get(VM), Some(&newer_list));
}

#[test]
fn an_older_list_defers_removal_until_a_newer_record_read_lands() {
    let mut reads = Reads::default();
    let older_list = reads.begin(None);
    let newer_status = reads.begin(Some(VM));
    assert!(reads.omitted(&vm(), older_list, false).is_empty(), "a newer read is outstanding");
    assert_eq!(reads.deferred.get(VM), Some(&older_list));
    assert_eq!(apply(&mut reads, newer_status), (true, vec![]), "the newer record keeps it");
    assert!(reads.deferred.is_empty());
    assert!(reads.is_idle());
}

#[test]
fn a_destroyed_detail_completes_a_deferred_list_removal() {
    let mut reads = Reads::default();
    let list = reads.begin(None);
    let status = reads.begin(Some(VM));
    assert!(reads.omitted(&vm(), list, false).is_empty());
    // The app's destroyed path: admit, remove, then retire the ticket.
    assert!(reads.admit(VM, status));
    reads.removed(VM);
    assert!(reads.finish(status, false).is_empty());
    assert!(reads.is_idle());
    assert!(reads.deferred.is_empty());
    assert!(!reads.admit(VM, list), "the older list cannot bring it back");
}

#[test]
fn a_destroyed_detail_removes_without_waiting_for_a_list() {
    let mut reads = Reads::default();
    let older = reads.begin(Some(VM));
    let detail = reads.begin(Some(VM));
    assert!(reads.admit(VM, detail));
    reads.removed(VM);
    assert!(reads.finish(detail, false).is_empty());
    assert_eq!(apply(&mut reads, older), (false, vec![]), "the stale detail changes nothing");
    assert!(reads.is_idle());
}

#[test]
fn an_older_destroyed_detail_does_not_remove_a_newer_live_record() {
    let mut reads = Reads::default();
    let detail = reads.begin(Some(VM));
    let list = reads.begin(None);
    assert!(reads.admit(VM, list));
    assert_eq!(apply(&mut reads, detail), (false, vec![]));
}

#[test]
fn a_failed_record_read_does_not_keep_an_omitted_machine() {
    let mut reads = Reads::default();
    let list = reads.begin(None);
    let status = reads.begin(Some(VM));
    assert!(reads.finish(status, false).is_empty());
    assert_eq!(reads.omitted(&vm(), list, false), vm());
}

#[test]
fn a_failed_record_read_finishes_an_already_deferred_removal() {
    let mut reads = Reads::default();
    let list = reads.begin(None);
    let status = reads.begin(Some(VM));
    assert!(reads.omitted(&vm(), list, false).is_empty());
    assert_eq!(reads.finish(status, false), vm(), "the failed read released the omission");
    assert!(reads.deferred.is_empty());
    assert_eq!(reads.applied.get(VM), Some(&list));
}

#[test]
fn another_machines_read_does_not_hold_a_removal() {
    let mut reads = Reads::default();
    let list = reads.begin(None);
    let _other = reads.begin(Some("vm_b"));
    assert_eq!(reads.omitted(&vm(), list, false), vm());
}

#[test]
fn an_older_read_of_the_machine_does_not_hold_a_removal() {
    let mut reads = Reads::default();
    let _older = reads.begin(Some(VM));
    let list = reads.begin(None);
    assert_eq!(reads.omitted(&vm(), list, false), vm());
}

#[test]
fn omissions_keep_the_newest_list() {
    let mut reads = Reads::default();
    let first = reads.begin(None);
    let second = reads.begin(None);
    let _status = reads.begin(Some(VM));
    assert!(reads.omitted(&vm(), second, false).is_empty());
    assert!(reads.omitted(&vm(), first, false).is_empty());
    assert_eq!(reads.deferred.get(VM), Some(&second));
}

#[test]
fn cloud_off_releases_nothing_but_still_retires_tickets() {
    let mut reads = Reads::default();
    let list = reads.begin(None);
    let status = reads.begin(Some(VM));
    assert!(reads.omitted(&vm(), list, true).is_empty());
    assert_eq!(reads.deferred.get(VM), Some(&list), "kept for when Cloud is on again");
    assert!(reads.finish(status, true).is_empty());
    assert!(reads.is_idle());
    let next = reads.begin(None);
    assert_eq!(reads.omitted(&[], next, false), vm());
}

#[test]
fn removals_come_in_machine_order() {
    let mut reads = Reads::default();
    let list = reads.begin(None);
    let machines = vec!["vm_c".to_owned(), "vm_a".to_owned(), "vm_b".to_owned()];
    assert_eq!(reads.omitted(&machines, list, false), vec!["vm_a", "vm_b", "vm_c"]);
}

#[test]
fn the_state_round_trips_as_camel_case_json() {
    let mut reads = Reads::default();
    let list = reads.begin(None);
    let _status = reads.begin(Some(VM));
    assert!(reads.omitted(&vm(), list, false).is_empty());
    let json = serde_json::to_value(&reads).expect("encodes");
    assert_eq!(
        json,
        serde_json::json!({"issued": 2, "outstanding": {"2": VM}, "applied": {}, "deferred": {VM: 1}})
    );
    let back: Reads = serde_json::from_value(json).expect("decodes");
    assert_eq!(back, reads);
    let empty: Reads =
        serde_json::from_value(serde_json::json!({})).expect("an empty state decodes");
    assert_eq!(empty, Reads::default());
}

#[test]
fn a_list_adds_new_machines_and_releases_omissions() {
    let mut reads = Reads::default();
    let held = vec!["vm_a".to_owned(), "vm_gone".to_owned()];
    let list = reads.begin(None);
    let listed = vec!["vm_a".to_owned(), "vm_new".to_owned()];
    let answer = reads.listed(&listed, &held, list, false);
    assert_eq!(answer, Listed { add: vec!["vm_new".into()], removals: vec!["vm_gone".into()] });
    assert_eq!(reads.applied.get("vm_new"), Some(&list));
    assert_eq!(reads.applied.get("vm_a"), None, "a held machine is admitted by the app's apply");
}

#[test]
fn an_older_list_does_not_resurrect_a_machine_a_newer_read_removed() {
    let mut reads = Reads::default();
    let older = reads.begin(None);
    let detail = reads.begin(Some(VM));
    assert!(reads.admit(VM, detail));
    reads.removed(VM);
    assert!(reads.finish(detail, false).is_empty());
    assert_eq!(reads.listed(&vm(), &[], older, false), Listed::default());
}
