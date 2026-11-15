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
        // A snapshot that does not restore: the start replays from zero (a
        // version bump migrates instead).
        registry
            .put_journal_reducer_state(AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, 0, "")
            .unwrap();
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

/// A replay from zero (a snapshot that does not restore) that the start's
/// budget does not finish goes on in the roster's owner after the daemon serves: the
/// start returns at once, and the roster ends complete, with the same entries
/// as a start that replayed it all.
#[test]
fn a_replay_the_start_budget_leaves_finishes_in_the_background() {
    use crate::mux::agent_roster_restore::STARTUP_BUDGET_FOR_TEST;
    let store = sealed_roster_store("roster-replay-background");
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    registry
        .put_journal_reducer_state(
            crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
            crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
            0,
            "",
        )
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

/// router-review on #39096 at b9e8947 (F2): a background replay slice whose
/// read failed left the replay running with no pass scheduled, so the roster
/// stayed behind (and `expect_agent` sends refused) until an unrelated
/// request or tick woke the owner. It is now retried after a backoff, as the
/// rebuild's reads are.
#[test]
fn a_replay_read_failure_is_retried_without_another_request() {
    use crate::mux::agent_roster_fold::rebuild_faults;
    use crate::mux::agent_roster_restore::STARTUP_BUDGET_FOR_TEST;
    let session = "roster-replay-retry";
    let store = sealed_roster_store(session);
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    registry
        .put_journal_reducer_state(
            crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
            crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
            0,
            "",
        )
        .unwrap();
    drop(registry);
    rebuild_faults::fail_replay_reads(session, 1);
    STARTUP_BUDGET_FOR_TEST.with(|budget| budget.set(Some(Duration::ZERO)));
    let reopened = open_persistent_test_mux(store.session, &store.root);
    STARTUP_BUDGET_FOR_TEST.with(|budget| budget.set(None));
    reopened.stop_journal_maintenance();
    let deadline = Instant::now() + Duration::from_secs(10);
    while reopened.agent_roster_settling() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let settled = !reopened.agent_roster_settling();
    rebuild_faults::fail_replay_reads(session, 0);
    assert!(settled, "the replay stopped at its failed read");
    for terminal_id in &store.terminals {
        assert_eq!(roster_agent_state(&reopened, terminal_id).as_deref(), Some("idle"));
    }
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&store.root);
}

/// A kind map an older build left partly filled, as app-wedge-recover's
/// premigration repro has it (#39503): the sealed segments' agent kinds are
/// gone from `journal_segment_kinds`, each segment names only
/// `personal.session.put`, and the backfill marker is an older build's `0`.
/// Drops the roster snapshot (an unreadable one at the current version), so
/// the next restore folds from zero through the kind read.
fn hide_agent_kinds_from_the_kind_map(store: &SealedRosterStore) {
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    registry
        .put_journal_reducer_state(
            crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
            crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
            0,
            "",
        )
        .unwrap();
    let database = registry.session_journal_database_path().unwrap();
    drop(registry);
    rusqlite::Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DELETE FROM journal_segment_kinds WHERE kind LIKE 'agent.%' OR kind LIKE 'plugin.%';
             INSERT OR IGNORE INTO journal_segment_kinds(segment_id, kind)
               SELECT segment_id, 'personal.session.put' FROM journal_segments;
             DELETE FROM meta WHERE key LIKE 'journal_segment_kinds_backfill%';
             INSERT INTO meta(key, value) VALUES
               ('journal_segment_kinds_backfill', '0'),
               ('journal_segment_kinds_backfill_through', '0');",
        )
        .unwrap();
}

/// The owner-side mirror of #39503's
/// `a_partial_kind_map_does_not_hide_an_agent_event_from_the_premigration`,
/// on the start's writable connection: with a backfill slice of one segment
/// a call, the restore's kind reads meet segments the backfill has not
/// rescanned, whose maps it must not trust.
#[test]
fn a_partial_kind_map_does_not_hide_an_agent_event_from_the_start_fold() {
    use crate::workspace_registry::session_journal::BACKFILL_SLICE_FOR_TEST;
    let store = sealed_roster_store("roster-partial-kind-map");
    hide_agent_kinds_from_the_kind_map(&store);
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(Some(Duration::ZERO)));
    let restored = crate::mux::agent_roster_restore::restore_agent_roster(&registry);
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(None));
    let restored = restored.unwrap();
    assert!(restored.replay.is_none());
    for (step, terminal_id) in store.terminals.iter().enumerate() {
        assert_eq!(
            restored
                .host
                .roster
                .entries
                .get(terminal_id.as_str())
                .map(|entry| entry.state.as_str()),
            Some("idle"),
            "roster entry of step {step}"
        );
    }
    drop(registry);
    let _ = std::fs::remove_dir_all(&store.root);
}

/// The same through the roster owner's read-only reader, where the backfill
/// cannot run at all: the start leaves the whole fold to the background
/// replay (a zero budget).
#[test]
fn a_partial_kind_map_does_not_hide_an_agent_event_from_the_background_replay() {
    use crate::mux::agent_roster_restore::STARTUP_BUDGET_FOR_TEST;
    let store = sealed_roster_store("roster-partial-kind-map-replay");
    hide_agent_kinds_from_the_kind_map(&store);
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
            .put_journal_reducer_state(
                crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
                crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
                0,
                "",
            )
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

/// #39096 review (salvage bound): the replay's salvaging read (the fallback when the
/// kind-scoped read fails) reads the journal as it is now, past the start's
/// head. Its records apply no deltas, so one committed after the start (a
/// plugin's exit) must be left for the live fold, which applies its delta:
/// the replay applies and moves its cursor through `through` only.
#[test]
fn the_replays_salvaging_read_stops_at_the_starts_head() {
    use crate::mux::agent_roster_restore::{
        AgentRosterReplay, ReplayProgress, RosterFoldLimits, RosterJournal, RosterSave,
    };
    use crate::workspace_registry::SessionJournalRecord;
    use crate::workspace_registry::session_journal::salvage::{
        SalvagedJournalPage, SkippedJournalRange,
    };
    use crate::workspace_registry::session_journal::{
        JournalClass, JournalProducer, JournalReplayPolicy, JournalSensitivity, SessionJournalPage,
    };
    /// A journal whose kind-scoped read always fails and whose salvaging
    /// read returns the whole journal as one page.
    struct Salvaging(Vec<SessionJournalRecord>, bool);
    impl RosterJournal for Salvaging {
        fn kinds_after(
            &self,
            _: u64,
            _: u64,
            _: usize,
        ) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
            anyhow::bail!("the kind-scoped read fails")
        }
        fn after_salvaging(&self, cursor: u64, _: usize) -> anyhow::Result<SalvagedJournalPage> {
            if self.1 {
                return Ok(SalvagedJournalPage::Skipped(SkippedJournalRange {
                    start_sequence: cursor + 1,
                    end_sequence: self.0.last().map_or(0, |record| record.sequence),
                    segment_id: None,
                    reason: "test",
                }));
            }
            Ok(SalvagedJournalPage::Page(SessionJournalPage {
                head_sequence: self.0.last().map_or(0, |record| record.sequence),
                records: self.0.iter().filter(|r| r.sequence > cursor).cloned().collect(),
            }))
        }
        fn subject_ids_in_range(&self, _: &str, _: u64, _: u64) -> anyhow::Result<Vec<String>> {
            Ok(Vec::new())
        }
        fn save(&self, _: RosterSave, _: u64, _: &str) -> anyhow::Result<()> {
            Ok(())
        }
    }
    let records = (1..=10)
        .map(|sequence| SessionJournalRecord {
            sequence,
            event_id: format!("event_{sequence}"),
            schema_version: 1,
            kind: "workspace.focus".into(),
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            occurred_at_ms: sequence,
            committed_at_ms: sequence,
            producer: JournalProducer { kind: "test".into(), id: "test".into() },
            authority: None,
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: Vec::new(),
            sensitivity: JournalSensitivity::Metadata,
            payload: serde_json::json!({}),
            resource_revision: None,
            previous_resource_revision: None,
            terminal_output: None,
        })
        .collect::<Vec<_>>();
    let limits = RosterFoldLimits { page: 512, save_every_pages: 64, stop_after_pages: None };
    // A page that decodes, then a range that does not: both end at the
    // start's head.
    for skipped in [false, true] {
        let mut replay = AgentRosterReplay::for_test(6, limits);
        let mut host = AgentRosterHost::default();
        let journal = Salvaging(records.clone(), skipped);
        let done = replay.fold(&journal, &mut &mut host, None).unwrap();
        assert!(matches!(done, ReplayProgress::Done { .. }));
        assert_eq!(host.cursor, 6, "skipped {skipped}: the replay stops at the start's head");
    }
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

/// Waits until `mux`'s roster rebuild is over, at most 10 s, with no
/// request that would give the roster's owner another pass.
fn rebuild_ends_on_its_own(mux: &Mux) -> bool {
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.agent_roster_rebuilding() {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    true
}

/// A rebuild whose read fails tries again on its own, after a backoff: a
/// read error used to end the slice with nothing scheduled, so the roster
/// stayed stale (and its projections unreconciled) until an agent event
/// woke the owner.
#[test]
fn a_rebuild_read_failure_is_retried_without_another_request() {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    use crate::mux::agent_roster_fold::rebuild_faults;
    let session = "roster-rebuild-retry";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-rebuild-retry-{}", crate::workspace_registry::new_uuid_v4()));
    let (terminal, _) = store_with_a_previous_version_snapshot(
        session,
        &root,
        AGENT_ROSTER_REDUCER_VERSION - 1,
        |snapshot, terminal| {
            snapshot["entries"][terminal.as_str()]["state"] = serde_json::json!("idle");
        },
    );
    rebuild_faults::fail_reads(session, 2);
    let mux = open_persistent_test_mux(session, &root);
    mux.stop_journal_maintenance();
    assert!(rebuild_ends_on_its_own(&mux), "the rebuild stopped at its failed read");
    assert_eq!(roster_agent_state(&mux, &terminal).as_deref(), Some("working"));
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID)
            .unwrap(),
        None,
        "the retried rebuild finished"
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// The retries are bounded: a read that keeps failing ends the rebuild for
/// this run, with the stale mark kept, so the next start rebuilds again.
#[test]
fn a_rebuild_whose_reads_keep_failing_gives_up_and_keeps_the_stale_mark() {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    use crate::mux::agent_roster_fold::rebuild_faults;
    let session = "roster-rebuild-give-up";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-rebuild-give-up-{}", crate::workspace_registry::new_uuid_v4()));
    store_with_a_previous_version_snapshot(
        session,
        &root,
        AGENT_ROSTER_REDUCER_VERSION - 1,
        |_, _| {},
    );
    rebuild_faults::fail_reads(session, u32::MAX);
    let mux = open_persistent_test_mux(session, &root);
    mux.stop_journal_maintenance();
    assert!(rebuild_ends_on_its_own(&mux), "the rebuild retries without a bound");
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID)
            .unwrap(),
        Some(AGENT_ROSTER_REDUCER_VERSION - 1),
        "a rebuild that gave up must leave the roster marked stale"
    );
    rebuild_faults::fail_reads(session, 0);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// The stale mark and the migrated snapshot are written together: when the
/// mark cannot be written, the migrated snapshot is not saved at the
/// current version either. Otherwise a stop before the rebuild finished
/// left a migrated snapshot passing for the current reducer's fold, with no
/// mark, and every later start trusted it.
#[test]
fn a_migrated_snapshot_is_not_saved_without_its_stale_mark() {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    let session = "roster-bump-mark";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-bump-mark-{}", crate::workspace_registry::new_uuid_v4()));
    let previous = AGENT_ROSTER_REDUCER_VERSION - 1;
    store_with_a_previous_version_snapshot(session, &root, previous, |_, _| {});
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let database = registry.session_journal_database_path().unwrap();
    // The mark's write fails (a full disk, an I/O error).
    rusqlite::Connection::open(&database)
        .unwrap()
        .execute_batch(&format!(
            "CREATE TRIGGER refuse_rebuild_mark BEFORE INSERT ON meta
             WHEN NEW.key = 'journal_reducer_rebuild.{AGENT_ROSTER_REDUCER_ID}'
             BEGIN SELECT RAISE(ABORT, 'the mark is refused'); END;"
        ))
        .unwrap();
    let restored = crate::mux::agent_roster_restore::restore_agent_roster(&registry).unwrap();
    assert!(restored.rebuild);
    assert_eq!(registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap(), None);
    let (version, _, _) = registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap().unwrap();
    assert_eq!(version, previous, "the migrated snapshot was saved without its stale mark");
    rusqlite::Connection::open(&database)
        .unwrap()
        .execute_batch("DROP TRIGGER refuse_rebuild_mark;")
        .unwrap();

    // The next start migrates again, and this time marks it.
    let restored = crate::mux::agent_roster_restore::restore_agent_roster(&registry).unwrap();
    assert!(restored.rebuild);
    assert_eq!(
        registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap(),
        Some(previous)
    );
    let (version, _, _) = registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap().unwrap();
    assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION);
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// A terminal the live roster retired while the rebuild ran stays retired
/// when the rebuilt roster replaces the live one. The rebuild folds only the
/// journal, and a close is not a journal event the roster folds, so the
/// rebuilt roster used to bring the closed terminal's entry back.
#[test]
fn a_terminal_retired_during_the_rebuild_stays_retired() {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    use crate::mux::agent_roster_fold::rebuild_faults;
    let session = "roster-rebuild-retire";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-rebuild-retire-{}", crate::workspace_registry::new_uuid_v4()));
    let (terminal, _) = store_with_a_previous_version_snapshot(
        session,
        &root,
        AGENT_ROSTER_REDUCER_VERSION - 1,
        |_, _| {},
    );
    rebuild_faults::hold(session, true);
    let mux = open_persistent_test_mux(session, &root);
    assert!(mux.agent_roster_rebuilding());
    assert_eq!(roster_agent_state(&mux, &terminal).as_deref(), Some("working"));
    mux.retire_roster_terminal(&terminal);
    assert_eq!(roster_agent_state(&mux, &terminal), None, "the live pass retired it");
    assert!(mux.agent_roster_rebuilding());

    rebuild_faults::hold(session, false);
    mux.continue_agent_roster_rebuild_later();
    assert!(rebuild_ends_on_its_own(&mux));
    assert_eq!(roster_agent_state(&mux, &terminal), None, "the rebuild brought it back");
    let (_, _, snapshot) = mux
        .workspace_registry
        .lock()
        .unwrap()
        .journal_reducer_state(AGENT_ROSTER_REDUCER_ID)
        .unwrap()
        .unwrap();
    let saved = crate::journal_reducers::AgentRoster::restore(&snapshot).unwrap();
    assert!(!saved.entries.contains_key(terminal.as_str()), "the saved roster has it again");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A rebuild that gave up leaves the roster stale for the rest of the run,
/// not only marked stale for the next start: projections (terminal adoption,
/// respawn, the open's reconcile) are not reconciled from it.
#[test]
fn a_rebuild_that_gave_up_keeps_the_roster_stale() {
    use crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION;
    use crate::mux::agent_roster_fold::rebuild_faults;
    let session = "roster-rebuild-gave-up-stale";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-gave-up-stale-{}", crate::workspace_registry::new_uuid_v4()));
    store_with_a_previous_version_snapshot(
        session,
        &root,
        AGENT_ROSTER_REDUCER_VERSION - 1,
        |_, _| {},
    );
    rebuild_faults::fail_reads(session, u32::MAX);
    let mux = open_persistent_test_mux(session, &root);
    mux.stop_journal_maintenance();
    assert!(rebuild_ends_on_its_own(&mux));
    assert!(mux.agent_roster_stale(), "a roster whose rebuild gave up is reconciled from");
    rebuild_faults::fail_reads(session, 0);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// When the start could not write the stale mark, a live pass does not save
/// the migrated roster at the current version either: a stop before the
/// rebuild finished would leave a snapshot every later start trusts. It
/// saves at the version the roster was migrated from, so the next start
/// migrates and marks it again.
#[test]
fn a_live_pass_does_not_save_an_unmarked_migrated_roster_at_the_current_version() {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    use crate::mux::agent_roster_fold::rebuild_faults;
    let session = "roster-unmarked-live-save";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-unmarked-save-{}", crate::workspace_registry::new_uuid_v4()));
    let previous = AGENT_ROSTER_REDUCER_VERSION - 1;
    let (terminal, _) = store_with_a_previous_version_snapshot(session, &root, previous, |_, _| {});
    let database =
        WorkspaceRegistry::open(&root, session).unwrap().session_journal_database_path().unwrap();
    rusqlite::Connection::open(&database)
        .unwrap()
        .execute_batch(&format!(
            "CREATE TRIGGER refuse_rebuild_mark BEFORE INSERT ON meta
             WHEN NEW.key = 'journal_reducer_rebuild.{AGENT_ROSTER_REDUCER_ID}'
             BEGIN SELECT RAISE(ABORT, 'the mark is refused'); END;"
        ))
        .unwrap();
    // The rebuild does not finish in this run (the daemon stops first).
    rebuild_faults::hold(session, true);
    let mux = open_persistent_test_mux(session, &root);
    append_journal_hook(&mux, &terminal, "Stop", Some("bump"));
    assert_eq!(roster_agent_state(&mux, &terminal).as_deref(), Some("idle"));
    let (version, _, _) = mux
        .workspace_registry
        .lock()
        .unwrap()
        .journal_reducer_state(AGENT_ROSTER_REDUCER_ID)
        .unwrap()
        .unwrap();
    assert_eq!(version, previous, "a live pass saved the unmarked migrated roster as current");
    rebuild_faults::hold(session, false);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
