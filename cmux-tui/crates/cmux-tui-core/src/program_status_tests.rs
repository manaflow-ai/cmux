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
