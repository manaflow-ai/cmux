//! Daemon start with an undecodable sealed journal segment (cx-6b12).
//!
//! The agent roster replays the journal from zero when its snapshot is
//! missing or from another reducer version. One corrupt sealed segment must
//! cost only the records it holds: open succeeds, every decodable record
//! still reaches the roster, and the skipped range is reported.

use super::*;
use std::path::PathBuf;

/// One agent session per terminal, each sealed into its own journal segment
/// range, then one more agent in the active journal. Returns the terminal
/// of each step and the segment ids of each seal.
struct SealedRosterStore {
    root: PathBuf,
    session: &'static str,
    terminals: Vec<TerminalPublicId>,
    seals: Vec<Vec<String>>,
}

fn sealed_roster_store(session: &'static str) -> SealedRosterStore {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-bad-segment-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let mut terminals = Vec::new();
    let mut seals = Vec::new();
    for step in 0..4 {
        let surface = mux.new_workspace(None, None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
        append_journal_hook(&mux, &terminal_id, "SessionStart", Some(&format!("agent-{step}")));
        assert_eq!(roster_agent_state(&mux, &terminal_id).as_deref(), Some("idle"));
        terminals.push(terminal_id);
        if step == 3 {
            break;
        }
        let checkpoint = mux
            .create_journal_checkpoint(
                "client_test",
                &format!("roster_bad_segment_checkpoint_{step}"),
            )
            .unwrap();
        let sealed = mux
            .seal_journal_segments(
                checkpoint.checkpoint.source_sequence,
                "client_test",
                &format!("roster_bad_segment_seal_{step}"),
            )
            .unwrap();
        assert!(!sealed.segments.is_empty());
        seals.push(sealed.segments.into_iter().map(|segment| segment.segment_id).collect());
    }
    mux.shutdown();
    drop(mux);
    SealedRosterStore { root, session, terminals, seals }
}

/// Overwrite the content of every segment of one seal with bytes that are
/// not gzip, and drop the roster snapshot so the reopen replays from zero.
fn corrupt_seal_and_drop_roster_snapshot(store: &SealedRosterStore, seal: usize) {
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    let database = registry.session_journal_database_path().unwrap();
    registry
        .put_journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID, 0, 0, "")
        .unwrap();
    drop(registry);
    let connection = rusqlite::Connection::open(&database).unwrap();
    connection.execute_batch("DROP TRIGGER IF EXISTS journal_segments_reject_update;").unwrap();
    for segment_id in &store.seals[seal] {
        let changed = connection
            .execute(
                "UPDATE journal_segments SET content = x'00112233' WHERE segment_id = ?1",
                rusqlite::params![segment_id],
            )
            .unwrap();
        assert_eq!(changed, 1);
    }
}

fn reopen_and_check_roster(store: &SealedRosterStore, corrupt_seal: usize) {
    corrupt_seal_and_drop_roster_snapshot(store, corrupt_seal);
    let reopened = open_persistent_test_mux(store.session, &store.root);
    for (step, terminal_id) in store.terminals.iter().enumerate() {
        let expected = if step == corrupt_seal { None } else { Some("idle") };
        assert_eq!(
            roster_agent_state(&reopened, terminal_id).as_deref(),
            expected,
            "roster entry of step {step} with seal {corrupt_seal} corrupt"
        );
    }
    let diagnostics = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = Arc::clone(&diagnostics);
    assert!(reopened.set_diagnostic_reporter(Arc::new(move |message| {
        sink.lock().unwrap().push(message.to_string());
    })));
    let diagnostics = diagnostics.lock().unwrap().clone();
    assert!(
        diagnostics.iter().any(|message| message.contains("agent roster")
            && store.seals[corrupt_seal].iter().all(|segment| message.contains(segment.as_str()))),
        "expected a skipped-segment diagnostic, got {diagnostics:?}"
    );
    reopened.shutdown();
    drop(reopened);

    // The cursor moved past the bad range, so the next start does not
    // read it again and keeps the same roster.
    let again = open_persistent_test_mux(store.session, &store.root);
    for (step, terminal_id) in store.terminals.iter().enumerate() {
        let expected = if step == corrupt_seal { None } else { Some("idle") };
        assert_eq!(roster_agent_state(&again, terminal_id).as_deref(), expected);
    }
    again.shutdown();
    drop(again);
}

#[test]
fn open_skips_a_corrupt_middle_segment_and_keeps_every_decodable_roster_record() {
    let store = sealed_roster_store("roster-bad-middle-segment");
    reopen_and_check_roster(&store, 1);
    std::fs::remove_dir_all(&store.root).unwrap();
}

#[test]
fn open_skips_a_corrupt_first_segment_and_keeps_every_decodable_roster_record() {
    let store = sealed_roster_store("roster-bad-first-segment");
    reopen_and_check_roster(&store, 0);
    std::fs::remove_dir_all(&store.root).unwrap();
}
