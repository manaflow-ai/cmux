use super::*;
use ghostty_vt::{ProgramStatusEvent, ProgramStatusReport, ProgramStatusState};

fn report(state: ProgramStatusState) -> ProgramStatusEvent {
    ProgramStatusEvent::Report(ProgramStatusReport {
        state,
        kind: None,
        progress: None,
        id: String::new(),
        app: "make".into(),
        title: String::new(),
        message: String::new(),
    })
}

#[test]
fn program_status_flush_drains_a_final_clear_that_arrives_during_publication() {
    let mux = Mux::new_for_test("program-status-drain", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let records = surface.as_pty().unwrap().program_status_records();
    records.lock().unwrap().apply(report(ProgramStatusState::Working), 0);
    PROGRAM_STATUS_AFTER_CLAIM.with(|slot| {
        let surface = surface.clone();
        *slot.borrow_mut() = Some(Box::new(move || {
            records.lock().unwrap().apply(report(ProgramStatusState::Clear), 1);
            // The output reader loses the claim to the publisher already in
            // flight, then has no further output to trigger another flush.
            surface.publish_pending_progress();
        }));
    });

    surface.publish_pending_progress();

    // Read the journal directly: a public snapshot would retry publication
    // and conceal the missing final event in the one-shot implementation.
    let changes: Vec<_> = mux
        .session_journal_after(0, 1024)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| record.kind == "terminal.program_status")
        .map(|record| record.payload["result"]["program_status_change"].clone())
        .collect();
    assert_eq!(changes.len(), 2, "one report and one clear must reach hooks: {changes:?}");
    assert_eq!(changes[0]["record"]["state"], "working");
    assert_eq!(changes[1]["event"], "clear");
    assert_eq!(changes[1]["id"], "");
    assert_eq!(changes[1]["records"], serde_json::json!([]));

    surface.publish_pending_progress();
    let after_retry = mux.session_journal_after(0, 1024).unwrap();
    assert_eq!(
        after_retry.records.iter().filter(|record| record.kind == "terminal.program_status").count(),
        2,
        "an extra flush must not duplicate either event"
    );
}
