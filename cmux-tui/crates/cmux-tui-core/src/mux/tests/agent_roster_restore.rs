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

/// A replay from zero takes minutes on a large registry, and a daemon can be
/// stopped partway (a 30-minute restore.snapshot was killed and restarted).
/// The restore saves the roster and its cursor every few pages, so the next
/// start resumes there and ends with the same roster as one whole replay.
#[test]
fn a_stopped_roster_replay_resumes_from_its_last_save() {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    use crate::mux::agent_roster_restore::{
        RosterFoldLimits, restore_agent_roster, restore_agent_roster_with,
    };
    let store = sealed_roster_store("roster-replay-resume");
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    let head = registry.session_journal_head().unwrap();
    let drop_snapshot = || {
        registry.put_journal_reducer_state(AGENT_ROSTER_REDUCER_ID, 0, 0, "").unwrap();
    };

    drop_snapshot();
    let whole = restore_agent_roster(&registry).unwrap();
    assert!(whole.diagnostic.is_none(), "{:?}", whole.diagnostic);
    assert_eq!(whole.host.cursor, head);
    let whole_snapshot = whole.host.roster.snapshot().to_string();

    drop_snapshot();
    let limits = RosterFoldLimits { page: 1, save_every_pages: 2, stop_after_pages: Some(3) };
    let stopped = restore_agent_roster_with(&registry, limits).unwrap();
    let (version, saved, _) =
        registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap().unwrap();
    assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION, "the stopped replay saved its progress");
    assert!(saved > 0 && saved < head, "saved cursor {saved} of head {head}");
    assert!(saved <= stopped.host.cursor);

    let resumed = restore_agent_roster(&registry).unwrap();
    assert_eq!(resumed.host.cursor, head);
    assert_eq!(resumed.host.roster.snapshot().to_string(), whole_snapshot);
    drop(registry);
    let _ = std::fs::remove_dir_all(&store.root);
}

/// A replay from zero (a reducer version bump) that the start's budget does
/// not finish goes on in the roster's owner after the daemon serves: the
/// start returns at once, and the roster ends complete, with the same entries
/// as a start that replayed it all.
#[test]
fn a_replay_the_start_budget_leaves_finishes_in_the_background() {
    use crate::mux::agent_roster_restore::STARTUP_BUDGET_FOR_TEST;
    let store = sealed_roster_store("roster-replay-background");
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    registry
        .put_journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID, 0, 0, "")
        .unwrap();
    drop(registry);
    STARTUP_BUDGET_FOR_TEST.with(|budget| budget.set(Some(Duration::ZERO)));
    let reopened = open_persistent_test_mux(store.session, &store.root);
    STARTUP_BUDGET_FOR_TEST.with(|budget| budget.set(None));
    for _ in 0..100 {
        if !reopened.agent_roster_replaying() {
            break;
        }
        assert!(reopened.settle_agent_roster_for_test());
    }
    assert!(!reopened.agent_roster_replaying(), "the background replay did not finish");
    for (step, terminal_id) in store.terminals.iter().enumerate() {
        assert_eq!(
            roster_agent_state(&reopened, terminal_id).as_deref(),
            Some("idle"),
            "roster entry of step {step} after the background replay"
        );
    }
    let registry_head = reopened.session_journal_head().unwrap();
    let (version, saved, _) = reopened
        .workspace_registry
        .lock()
        .unwrap()
        .journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID)
        .unwrap()
        .unwrap();
    assert_eq!(version, crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION);
    assert!(saved <= registry_head && saved > 0, "saved {saved} of head {registry_head}");
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&store.root);
}

/// The start's roster cost stays flat as the journal grows: a replay from
/// zero over 6 and over 60 output-heavy sealed segments (10x the output and
/// the records). Prints the time with no budget (the whole replay on the
/// start, as before) and with the start's budget; the numbers in the PR come
/// from this test.
#[test]
fn the_start_roster_cost_stays_flat_as_the_journal_grows() {
    use crate::mux::agent_roster_restore::{
        RosterFoldLimits, STARTUP_BUDGET, restore_agent_roster_within,
    };
    use crate::workspace_registry::session_journal::tests::output_heavy_sealed_registry;
    let limits = RosterFoldLimits { page: 512, save_every_pages: 64, stop_after_pages: None };
    for segments in [6_u64, 60] {
        let (registry, _) = output_heavy_sealed_registry(segments, 4096);
        let started = Instant::now();
        let whole = restore_agent_roster_within(&registry, limits, None).unwrap();
        let unbudgeted = started.elapsed();
        assert!(whole.replay.is_none());
        let head = registry.session_journal_head().unwrap();
        assert_eq!(whole.host.cursor, head);
        registry
            .put_journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID, 0, 0, "")
            .unwrap();
        let started = Instant::now();
        let mut start =
            restore_agent_roster_within(&registry, limits, Some(STARTUP_BUDGET)).unwrap();
        let with_budget = started.elapsed();
        eprintln!(
            "roster start bench: {segments} segments, head {head}: whole replay {} ms, \
             with the start budget {} ms (cursor {})",
            unbudgeted.as_millis(),
            with_budget.as_millis(),
            start.host.cursor
        );
        // One page past the budget at most.
        assert!(with_budget < STARTUP_BUDGET + Duration::from_secs(2), "{with_budget:?}");
        if let Some(replay) = start.replay.as_mut() {
            let mut host = &mut start.host;
            let done = replay.fold(&registry, &mut host, None).unwrap();
            assert!(matches!(done, crate::mux::agent_roster_restore::ReplayProgress::Done { .. }));
        }
        assert_eq!(start.host.cursor, head);
        assert_eq!(
            start.host.roster.snapshot().to_string(),
            whole.host.roster.snapshot().to_string()
        );
    }
}
