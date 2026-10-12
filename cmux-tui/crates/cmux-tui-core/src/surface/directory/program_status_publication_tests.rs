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
        after_retry
            .records
            .iter()
            .filter(|record| record.kind == "terminal.program_status")
            .count(),
        2,
        "an extra flush must not duplicate either event"
    );
}

#[cfg(unix)]
#[test]
fn program_status_hook_records_match_snapshot_when_exit_races_publication() {
    use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};
    use crate::workspace_registry::TerminalOnExit;

    let mux = Mux::new_for_test("program-status-exit", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(Some("exit".into()), None, None).unwrap();
    let surface_id = mux
        .seed_running_terminal_with_on_exit_for_test(
            "0000000000004000800000000000004a",
            "1000000000004000800000000000004a",
            &workspace.key,
            TerminalOnExit::Keep,
        )
        .unwrap();
    let surface = mux.surface(surface_id).unwrap();
    let records = surface.as_pty().unwrap().program_status_records();
    for (id, state) in [
        ("working", ProgramStatusState::Working),
        ("blocked", ProgramStatusState::Blocked),
        ("idle", ProgramStatusState::Idle),
        ("done", ProgramStatusState::Done),
        ("error", ProgramStatusState::Error),
    ] {
        let ProgramStatusEvent::Report(mut event) = report(state) else { unreachable!() };
        event.id = id.into();
        records.lock().unwrap().apply(ProgramStatusEvent::Report(event), 0);
    }
    PROGRAM_STATUS_AFTER_CLAIM.with(|slot| {
        let mux = mux.clone();
        let terminal_id = surface.terminal_public_id().unwrap().clone();
        *slot.borrow_mut() = Some(Box::new(move || {
            let exit = TerminalExit::now(TerminalExitOutcome::Exit { code: 1 });
            assert!(mux.persist_terminal_exit_for_test(&terminal_id, &exit).unwrap());
        }));
    });

    surface.publish_pending_progress();
    surface.publish_pending_progress();

    let events: Vec<_> = mux
        .session_journal_after(0, 1024)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| record.kind == "terminal.program_status")
        .collect();
    assert_eq!(events.len(), 1, "exit publication retries must not duplicate the hook");
    let result = &events[0].payload["result"];
    assert_eq!(result["lifecycle"], "exited");
    let current = &result["program_status_change"]["records"];
    assert_eq!(current, &result["extra"]["program_status"]);
    let states: Vec<_> = current.as_array().unwrap().iter().map(|r| r["state"].as_str()).collect();
    assert_eq!(states, [Some("done"), Some("error")]);
    assert_eq!(result["program_status_change"]["record"]["state"], "error");
}
