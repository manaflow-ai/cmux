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
        seals.push(seal_journal(&mux, &format!("roster_bad_segment_{step}")));
    }
    // Segments written by this build (actor-era records) decode on the
    // strict path: only the corruption below makes the restore skip.
    let strict = mux.session_journal_after(0, 1024).unwrap();
    assert!(strict.records.iter().any(|record| record.kind.starts_with("agent.")));
    mux.shutdown();
    drop(mux);
    SealedRosterStore { root, session, terminals, seals }
}

/// Checkpoint and seal the whole journal; returns the new segment ids.
fn seal_journal(mux: &Mux, key: &str) -> Vec<String> {
    let checkpoint =
        mux.create_journal_checkpoint("client_test", &format!("{key}_checkpoint")).unwrap();
    let sealed = mux
        .seal_journal_segments(
            checkpoint.checkpoint.source_sequence,
            "client_test",
            &format!("{key}_seal"),
        )
        .unwrap();
    assert!(!sealed.segments.is_empty());
    sealed.segments.into_iter().map(|segment| segment.segment_id).collect()
}

/// Overwrite the content of every segment of one seal with bytes that are
/// not gzip, and drop the roster snapshot so the reopen replays from zero.
/// With `inflate_end`, the seal's last segment also claims to end at the
/// first active row, past every later segment.
fn corrupt_seal_and_drop_roster_snapshot(
    store: &SealedRosterStore,
    seal: usize,
    inflate_end: bool,
) {
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
    if inflate_end {
        let changed = connection
            .execute(
                "UPDATE journal_segments
                 SET end_sequence = (SELECT MIN(sequence) FROM session_journal)
                 WHERE segment_id = ?1",
                rusqlite::params![store.seals[seal].last().unwrap()],
            )
            .unwrap();
        assert_eq!(changed, 1);
    }
}

fn reopen_and_check_roster(store: &SealedRosterStore, corrupt_seal: usize, inflate_end: bool) {
    corrupt_seal_and_drop_roster_snapshot(store, corrupt_seal, inflate_end);
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
    reopen_and_check_roster(&store, 1, false);
    std::fs::remove_dir_all(&store.root).unwrap();
}

#[test]
fn open_skips_a_corrupt_first_segment_and_keeps_every_decodable_roster_record() {
    let store = sealed_roster_store("roster-bad-first-segment");
    reopen_and_check_roster(&store, 0, false);
    std::fs::remove_dir_all(&store.root).unwrap();
}

#[test]
fn a_corrupt_segment_end_cannot_hide_the_records_after_it() {
    let store = sealed_roster_store("roster-bad-segment-end");
    reopen_and_check_roster(&store, 1, true);
    std::fs::remove_dir_all(&store.root).unwrap();
}

/// An agent whose later events sit in a skipped range keeps its last decoded
/// state only when that state is not a live claim: "working" from before the
/// range could be stale (the range may hold its stop), so it becomes
/// "unknown" until the agent reports again.
#[test]
fn an_agent_with_events_in_a_skipped_range_is_not_reported_working() {
    let session = "roster-stale-live";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-stale-live-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let quiet = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    let live = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    append_journal_hook(&mux, &quiet, "SessionStart", Some("quiet"));
    append_journal_hook(&mux, &quiet, "UserPromptSubmit", Some("quiet"));
    append_journal_hook(&mux, &live, "SessionStart", Some("live"));
    append_journal_hook(&mux, &live, "UserPromptSubmit", Some("live"));
    assert_eq!(roster_agent_state(&mux, &live).as_deref(), Some("working"));
    let first = seal_journal(&mux, "roster_stale_live_0");
    append_journal_hook(&mux, &live, "Stop", Some("live"));
    assert_eq!(roster_agent_state(&mux, &live).as_deref(), Some("idle"));
    let second = seal_journal(&mux, "roster_stale_live_1");
    mux.shutdown();
    drop(mux);

    let store = SealedRosterStore {
        root: root.clone(),
        session,
        terminals: vec![quiet.clone(), live.clone()],
        seals: vec![first, second],
    };
    corrupt_seal_and_drop_roster_snapshot(&store, 1, false);
    let reopened = open_persistent_test_mux(session, &root);
    // No event of `quiet` is in the skipped range: its decoded state stands.
    assert_eq!(roster_agent_state(&reopened, &quiet).as_deref(), Some("working"));
    assert_eq!(roster_agent_state(&reopened, &live).as_deref(), Some("unknown"));
    // The next real report corrects it.
    append_journal_hook(&reopened, &live, "UserPromptSubmit", Some("live"));
    assert_eq!(roster_agent_state(&reopened, &live).as_deref(), Some("working"));
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}
