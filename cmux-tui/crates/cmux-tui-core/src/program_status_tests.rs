use super::*;

fn report(id: &str, state: ProgramStatusState) -> ProgramStatusEvent {
    ProgramStatusEvent::Report(ProgramStatusReport {
        state,
        kind: None,
        progress: None,
        id: id.into(),
        app: String::new(),
        title: String::new(),
        message: String::new(),
    })
}

#[test]
fn the_record_updated_longest_ago_goes_first_at_the_limit() {
    let mut records = ProgramStatusRecords::default();
    for index in 0..MAX_RECORDS {
        records.apply(report(&format!("r{index}"), ProgramStatusState::Working), 0);
    }
    // Refresh r0 so r1 is now the oldest.
    records.apply(report("r0", ProgramStatusState::Working), 0);
    records.apply(report("new", ProgramStatusState::Working), 0);
    assert_eq!(records.len(), MAX_RECORDS);
    assert!(records.get("r0").is_some());
    assert!(records.get("r1").is_none());
    assert!(records.get("new").is_some());
    // Replacing an existing record at the limit evicts nothing.
    records.apply(report("r2", ProgramStatusState::Done), 0);
    assert_eq!(records.len(), MAX_RECORDS);
}

#[test]
fn dialog_wait_reaches_the_roster_as_a_blocked_then_idle_pair() {
    let mut records = ProgramStatusRecords::default();
    records.apply(report("", ProgramStatusState::Working), 1);
    assert_eq!(records.take_blocker_change(true), None, "work alone hands nothing");
    records.apply(report("", ProgramStatusState::Blocked), 2);
    assert_eq!(records.take_blocker_change(true), Some(ProgramStatusState::Blocked));
    records.apply(report("", ProgramStatusState::Blocked), 3);
    assert_eq!(records.take_blocker_change(true), None, "a refresh of the wait hands nothing");
    records.apply(report("", ProgramStatusState::Idle), 4);
    assert_eq!(records.take_blocker_change(true), Some(ProgramStatusState::Idle));
    records.apply(report("", ProgramStatusState::Working), 5);
    assert_eq!(records.take_blocker_change(true), None, "no wait to end");
}

#[test]
fn dialog_wait_that_ends_with_its_program_hands_no_stop() {
    let mut records = ProgramStatusRecords::default();
    records.apply(report("", ProgramStatusState::Blocked), 1);
    assert_eq!(records.take_blocker_change(true), Some(ProgramStatusState::Blocked));
    records.apply(ProgramStatusEvent::PromptStart, 2);
    assert_eq!(records.take_blocker_change(true), None, "the program left: no idle to report");
    // A later program's idle is not the end of the earlier wait.
    records.apply(report("", ProgramStatusState::Idle), 3);
    assert_eq!(records.take_blocker_change(true), None);
}

#[test]
fn dialog_wait_restored_by_a_new_daemon_is_handed_again() {
    let mut host = ProgramStatusRecords::default();
    host.apply(report("", ProgramStatusState::Blocked), 1);
    let mut adopted = ProgramStatusRecords::default();
    adopted.restore(host.snapshot());
    assert_eq!(adopted.take_blocker_change(true), Some(ProgramStatusState::Blocked));
    assert_eq!(adopted.take_blocker_change(false), None, "an exited program ends nothing");
}
