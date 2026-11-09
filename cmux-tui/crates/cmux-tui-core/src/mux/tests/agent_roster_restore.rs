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
/// The segments' kept reducer records go too, as for a segment an older
/// build sealed: a replay reads those instead of the content, and would
/// never meet the damage.
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
        connection
            .execute(
                "DELETE FROM journal_segment_reducer_records WHERE segment_id = ?1",
                rusqlite::params![segment_id],
            )
            .unwrap();
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

/// A journal with one agent working, and its roster snapshot saved as
/// `previous_version` after `edit` changed it. Returns the terminal and the
/// snapshot's cursor.
fn store_with_a_previous_version_snapshot(
    session: &str,
    root: &Path,
    previous_version: u32,
    edit: impl FnOnce(&mut Value, &TerminalPublicId),
) -> (TerminalPublicId, u64) {
    use crate::journal_reducers::AGENT_ROSTER_REDUCER_ID;
    let mux = open_persistent_test_mux(session, root);
    let terminal = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    append_journal_hook(&mux, &terminal, "SessionStart", Some("bump"));
    append_journal_hook(&mux, &terminal, "UserPromptSubmit", Some("bump"));
    assert_eq!(roster_agent_state(&mux, &terminal).as_deref(), Some("working"));
    mux.shutdown();
    drop(mux);
    let registry = WorkspaceRegistry::open(root, session).unwrap();
    let (_, cursor, snapshot) =
        registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap().unwrap();
    let mut snapshot: Value = serde_json::from_str(&snapshot).unwrap();
    edit(&mut snapshot, &terminal);
    registry
        .put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            previous_version,
            cursor,
            &snapshot.to_string(),
        )
        .unwrap();
    (terminal, cursor)
}

/// After an agent roster reducer version bump the start serves the old
/// snapshot (migrated) from its own cursor, with no fold of the history, and
/// marks it stale; the roster's owner then folds the whole journal again in
/// the background and replaces it with the current reducer's roster, saved
/// at the current version with the mark cleared. The bumps so far fixed the
/// fold's logic, so the migrated roster can be wrong until then: here it
/// says idle where the journal says working.
#[test]
fn a_version_bump_serves_the_migrated_roster_and_rebuilds_it_in_the_background() {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    let session = "roster-bump-migrate";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-bump-migrate-{}", crate::workspace_registry::new_uuid_v4()));
    let (terminal, cursor) = store_with_a_previous_version_snapshot(
        session,
        &root,
        AGENT_ROSTER_REDUCER_VERSION - 1,
        |snapshot, terminal| {
            snapshot["entries"][terminal.as_str()]["state"] = serde_json::json!("idle");
        },
    );
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let head = registry.session_journal_head().unwrap();
    assert!(cursor > 0 && cursor <= head);
    let restored = crate::mux::agent_roster_restore::restore_agent_roster(&registry).unwrap();
    assert!(restored.rebuild, "a migrated roster is stale");
    // The tail after the old cursor holds no agent record: the migrated
    // state stands until the rebuild.
    assert_eq!(restored.host.cursor, head, "the start folds the tail");
    assert_eq!(restored.host.roster.entries[terminal.as_str()].state, "idle");
    assert_eq!(
        registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap(),
        Some(AGENT_ROSTER_REDUCER_VERSION - 1)
    );
    drop(registry);

    // The saved snapshot is the migrated one, still marked stale: this
    // start rebuilds it.
    let reopened = open_persistent_test_mux(session, &root);
    assert_eq!(roster_agent_state(&reopened, &terminal).as_deref(), Some("working"));
    assert!(!reopened.agent_roster_rebuilding());
    {
        let registry = reopened.workspace_registry.lock().unwrap();
        assert_eq!(
            registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap(),
            None
        );
        let (version, _, snapshot) =
            registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap().unwrap();
        assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION);
        let saved = crate::journal_reducers::AgentRoster::restore(&snapshot).unwrap();
        assert_eq!(saved.entries[terminal.as_str()].state, "working");
    }
    reopened.shutdown();
    drop(reopened);

    // The next start has nothing to rebuild.
    let again = open_persistent_test_mux(session, &root);
    assert!(!again.agent_roster_rebuilding());
    assert_eq!(roster_agent_state(&again, &terminal).as_deref(), Some("working"));
    again.shutdown();
    drop(again);
    std::fs::remove_dir_all(root).unwrap();
}

/// A snapshot whose format no longer restores (a version before the hook
/// session fences) is not folded from zero at start either: the roster is
/// served empty from the journal head, takes live events, and the rebuild
/// fills it.
#[test]
fn a_version_bump_without_a_migratable_snapshot_serves_live_events_and_rebuilds() {
    let session = "roster-bump-empty";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-bump-empty-{}", crate::workspace_registry::new_uuid_v4()));
    let (terminal, _) = store_with_a_previous_version_snapshot(session, &root, 5, |_, _| {});
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let head = registry.session_journal_head().unwrap();
    let restored = crate::mux::agent_roster_restore::restore_agent_roster(&registry).unwrap();
    assert!(restored.rebuild);
    assert_eq!(restored.host.cursor, head, "the start serves from the head");
    assert!(restored.host.roster.entries.is_empty());
    drop(registry);

    let reopened = open_persistent_test_mux(session, &root);
    assert_eq!(roster_agent_state(&reopened, &terminal).as_deref(), Some("working"));
    append_journal_hook(&reopened, &terminal, "Stop", Some("bump"));
    assert_eq!(roster_agent_state(&reopened, &terminal).as_deref(), Some("idle"));
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}
