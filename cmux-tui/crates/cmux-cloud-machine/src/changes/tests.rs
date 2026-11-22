//! The pending overlay's rules (moved from the app's CloudMachineChangeStateTests and
//! CloudMachineChangesPollingTests; the app keeps the ones that drive a session).

use super::*;

const VM: &str = "vm_a";

fn record(status: Status) -> Machine {
    Machine::new(VM, status)
}

fn failing(code: &str) -> Machine {
    let mut machine = record(Status::Running);
    machine.last_change_failure =
        Some(ChangeFailure::new(code.into(), "provider refused".into(), None));
    machine
}

/// Sends and acknowledges mutation `id`.
fn accepted(changes: &mut Changes, change: Status, id: &str, baseline: &Machine) {
    changes.begin(VM, change, id, Some(baseline));
    changes.returned(VM, id);
}

#[test]
fn a_sent_change_shows_at_once_and_a_refused_one_goes() {
    let mut changes = Changes::default();
    let shown = changes.begin(VM, Status::Pausing, "m1", Some(&record(Status::Running)));
    assert_eq!(
        shown,
        Shown { pending_change: Some(Status::Pausing), pending_mutation_id: Some("m1".into()) }
    );
    assert!(changes.rolled_back(VM, "m1"));
    assert_eq!(changes.shown(VM), Shown::default());
    assert!(changes.mutations.is_empty());
    assert!(!changes.rolled_back(VM, "m1"), "a second rollback finds nothing");
}

#[test]
fn a_failed_kill_preserves_the_older_mutation() {
    for change in [Status::Pausing, Status::Starting] {
        let mut changes = Changes::default();
        let baseline =
            record(if change == Status::Starting { Status::Paused } else { Status::Running });
        changes.begin(VM, change, "older", Some(&baseline));
        changes.begin(VM, Status::Deleting, "kill", Some(&baseline));
        assert!(changes.rolled_back(VM, "kill"));
        assert_eq!(changes.shown(VM).pending_change, Some(change));
        changes.returned(VM, "older");
        assert_eq!(changes.apply(&baseline, None).pending_change, Some(change));
        assert_eq!(
            changes.unsettled(std::slice::from_ref(&baseline), &[]),
            [VM],
            "the older transition still needs reads"
        );
        let terminal =
            record(if change == Status::Starting { Status::Running } else { Status::Paused });
        assert_eq!(changes.apply(&terminal, None).pending_change, None);
        assert!(changes.unsettled(&[terminal], &[]).is_empty());
    }
}

#[test]
fn an_older_failure_cannot_erase_a_newer_mutation_of_the_same_kind() {
    let mut changes = Changes::default();
    changes.begin(VM, Status::Deleting, "older", None);
    changes.begin(VM, Status::Deleting, "newer", None);
    changes.returned(VM, "newer");
    assert!(changes.rolled_back(VM, "older"));
    assert_eq!(changes.shown(VM).pending_mutation_id.as_deref(), Some("newer"));
    assert_eq!(
        changes.apply(&record(Status::Running), None).pending_change,
        Some(Status::Deleting)
    );
}

#[test]
fn a_stale_provider_failure_cannot_retire_a_newer_mutation() {
    let mut changes = Changes::default();
    changes.read_issued(1);
    accepted(&mut changes, Status::Pausing, "m1", &record(Status::Running));
    let failure = failing("pause_failed");
    let stale = changes.apply(&failure, Some(1));
    assert_eq!(
        (stale.pending_mutation_id.as_deref(), stale.failed_mutation_id.as_deref()),
        (Some("m1"), None)
    );
    let confirmed = changes.apply(&failure, Some(2));
    assert_eq!(
        (confirmed.pending_mutation_id, confirmed.failed_mutation_id.as_deref()),
        (None, Some("m1"))
    );
}

#[test]
fn a_provider_kill_failure_does_not_retire_an_older_pause() {
    let mut changes = Changes::default();
    accepted(&mut changes, Status::Pausing, "pause", &record(Status::Running));
    accepted(&mut changes, Status::Deleting, "kill", &record(Status::Running));
    let failure = failing("delete_failed");
    let restored = changes.apply(&failure, None);
    assert_eq!(restored.pending_mutation_id.as_deref(), Some("pause"));
    assert_eq!(restored.failed_mutation_id.as_deref(), Some("kill"));
    assert_eq!(restored.shown_status(), Status::Pausing);
    // Inspecting the same provider error twice cannot retire the older pause.
    let again = changes.apply(&failure, None);
    assert_eq!(
        (again.pending_mutation_id.as_deref(), again.failed_mutation_id),
        (Some("pause"), None)
    );
    assert_eq!(changes.apply(&record(Status::Paused), None).pending_change, None);
}

#[test]
fn a_failure_already_on_the_baseline_is_not_this_mutations() {
    let mut changes = Changes::default();
    let failed = failing("old");
    accepted(&mut changes, Status::Pausing, "m1", &failed);
    let shown = changes.apply(&failed, None);
    assert_eq!((shown.pending_change, shown.failed_mutation_id), (Some(Status::Pausing), None));
}

#[test]
fn an_accepted_mutation_survives_a_stale_list_until_its_terminal_record() {
    let mut changes = Changes::default();
    accepted(&mut changes, Status::Pausing, "m1", &record(Status::Running));
    assert_eq!(changes.apply(&record(Status::Running), None).pending_change, Some(Status::Pausing));
    assert_eq!(changes.apply(&record(Status::Paused), None).pending_change, None);
}

#[test]
fn a_mutation_not_yet_acknowledged_is_never_settled() {
    let mut changes = Changes::default();
    changes.begin(VM, Status::Pausing, "m1", Some(&record(Status::Running)));
    assert_eq!(
        changes.apply(&record(Status::Paused), Some(5)).pending_change,
        Some(Status::Pausing)
    );
}

#[test]
fn a_later_running_revision_retires_a_pause_superseded_elsewhere() {
    let mut changes = Changes::default();
    // Read 1 was issued before this app's pause was accepted: a stale running answer.
    changes.read_issued(1);
    accepted(&mut changes, Status::Pausing, "m1", &record(Status::Running));
    assert_eq!(
        changes.apply(&record(Status::Running), Some(1)).pending_change,
        Some(Status::Pausing)
    );
    // Read 2 is a later revision: another client paused then resumed the machine.
    let mut superseding = record(Status::Running);
    superseding.updated_at = Some(2_000.0);
    assert_eq!(changes.apply(&superseding, Some(2)).pending_change, None);
    assert_eq!(changes.apply(&record(Status::Running), None).pending_change, None);
}

#[test]
fn app_server_revisions_retire_superseded_changes_after_acknowledgement() {
    for change in [Status::Pausing, Status::Starting] {
        let status = if change == Status::Pausing { Status::Running } else { Status::Paused };
        let mut baseline = record(status);
        baseline.server_revision = Some("99999999999999999999".into());
        let mut newer = record(status);
        newer.server_revision = Some("100000000000000000000".into());
        let mut changes = Changes::default();
        changes.read_issued(1);
        accepted(&mut changes, change, "m1", &baseline);
        assert_eq!(
            changes.apply(&newer, Some(1)).pending_change,
            Some(change),
            "a read from before the acceptance"
        );
        assert_eq!(
            changes.apply(&baseline, Some(2)).pending_change,
            Some(change),
            "no newer revision"
        );
        assert_eq!(changes.apply(&newer, Some(3)).pending_change, None);
    }
}

#[test]
fn terminal_records_without_a_revision_respect_read_ordering() {
    for change in [Status::Pausing, Status::Starting] {
        let terminal =
            record(if change == Status::Pausing { Status::Paused } else { Status::Running });
        let mut changes = Changes::default();
        changes.read_issued(1);
        accepted(&mut changes, change, "m1", &record(Status::Running));
        assert_eq!(
            changes.apply(&terminal, Some(1)).pending_change,
            Some(change),
            "pre-acknowledgement reads cannot settle"
        );
        assert_eq!(changes.unsettled(&[record(Status::Running)], &[]), [VM]);
        assert_eq!(
            changes.apply(&terminal, Some(2)).pending_change,
            None,
            "a fresh terminal state needs no timestamp"
        );
        assert!(changes.unsettled(&[terminal], &[]).is_empty());
    }
}

#[test]
fn a_destroyed_record_or_a_list_without_the_machine_drops_its_mutations() {
    let mut changes = Changes::default();
    accepted(&mut changes, Status::Deleting, "m1", &record(Status::Running));
    assert_eq!(changes.apply(&record(Status::Destroyed), None).pending_change, None);
    accepted(&mut changes, Status::Pausing, "m2", &record(Status::Running));
    changes.removed(VM);
    assert!(changes.mutations.is_empty());
}

#[test]
fn only_changing_or_tracked_machines_that_are_not_pushed_stay_unsettled() {
    let mut changes = Changes::default();
    changes.begin("vm_tracked", Status::Pausing, "m1", None);
    let list = [
        Machine::new("vm_pausing", Status::Pausing),
        Machine::new("vm_running", Status::Running),
        Machine::new("vm_pushed", Status::Deleting),
    ];
    assert_eq!(changes.unsettled(&list, &["vm_pushed".into()]), ["vm_pausing", "vm_tracked"]);
    assert_eq!(
        changes.unsettled(&list, &["vm_pushed".into(), "vm_tracked".into(), "vm_pausing".into()]),
        Vec::<String>::new()
    );
}

#[test]
fn revisions_compare_as_unsigned_decimals() {
    assert!(newer_revision(Some("10"), Some("9")));
    assert!(newer_revision(Some("100000000000000000000"), Some("99999999999999999999")));
    assert!(!newer_revision(Some("9"), Some("10")));
    assert!(!newer_revision(Some("5"), Some("5")));
    assert!(!newer_revision(Some("0005"), Some("5")));
    assert!(newer_revision(Some("006"), Some("5")));
    assert!(newer_revision(Some("1"), Some("000")));
    for (current, previous) in [
        (None, Some("1")),
        (Some("2"), None),
        (Some(""), Some("1")),
        (Some("2a"), Some("1")),
        (Some("-2"), Some("1")),
    ] {
        assert!(!newer_revision(current, previous), "{current:?} {previous:?}");
    }
}

#[test]
fn failed_reads_back_off_to_thirty_seconds_and_a_list_resets_the_wait() {
    assert_eq!(next_delay(SETTLE_DELAY_MS, false), 6_000);
    assert_eq!(next_delay(24_000, false), MAX_DELAY_MS);
    assert_eq!(next_delay(MAX_DELAY_MS, false), MAX_DELAY_MS);
    assert_eq!(next_delay(24_000, true), SETTLE_DELAY_MS);
}

#[test]
fn the_state_round_trips_as_the_apps_json() {
    let mut changes = Changes::default();
    changes.read_issued(4);
    accepted(&mut changes, Status::Pausing, "m1", &failing("x"));
    let text = serde_json::to_value(&changes).unwrap();
    assert_eq!(text["latestIssuedRead"], 4);
    assert_eq!(text["mutations"][VM][0]["requestReturnedRead"], 4);
    assert_eq!(serde_json::from_value::<Changes>(text).unwrap(), changes);
}
