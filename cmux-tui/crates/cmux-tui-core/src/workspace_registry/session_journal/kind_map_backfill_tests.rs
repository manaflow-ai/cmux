//! Kind maps of segments sealed before kind maps, filled while the owner
//! serves, so that a later reducer version bump reads sealed history from
//! the maps and the kept reducer records instead of decoding every segment.
//!
//! On a persistent registry the agent roster's replays read on a read-only
//! connection, which never runs the legacy kind backfill, and nothing else
//! wrote those maps: a registry sealed before them (Leo's, 12.2M records)
//! decoded every legacy segment at every bump, about 17.5 s at 3M records
//! against 0.4 s with the maps (2026-11-09).

use super::kind_read_tests::{
    SEALED_AGENT_RECORDS, destroy_sealed_segments, kept_reducer_records,
    run_reducer_record_backfill, sealed_history, sealed_terminal_output,
};
use super::*;

/// A registry whose sealed segments look sealed before kind maps and kept
/// reducer records: agent records among session puts and some terminal
/// output, sealed, then the seal-time indexes and backfill markers removed.
/// Returns its root, the registry and the kind maps its seal wrote.
fn legacy_registry(name: &str) -> (PathBuf, WorkspaceRegistry, Vec<(String, String)>) {
    let root = std::env::temp_dir().join(format!("cmux-{name}-{}", new_uuid_v4().replace('-', "")));
    let mut registry = WorkspaceRegistry::open(&root, name).unwrap();
    let mut records = Vec::new();
    for (index, record) in sealed_history(6_000).into_iter().enumerate() {
        records.push(record);
        if index % 16 == 0 {
            records.push(sealed_terminal_output(index));
        }
    }
    registry.append_journal_records_for_test(&records);
    registry.seal_journal_for_test(name);
    let sealed_maps = kind_maps(&registry);
    assert!(sealed_maps.iter().any(|(_, kind)| kind == "terminal.output"));
    {
        let db = registry.connection.get();
        db.execute_batch(
            "DELETE FROM journal_segment_kinds;
             DELETE FROM journal_segment_reducer_records;
             DELETE FROM meta WHERE key IN (
               'journal_segment_kinds_backfill', 'journal_segment_kinds_backfill_through',
               'journal_segment_kinds_backfill_end', 'journal_segment_reducer_records_backfill'
             );",
        )
        .unwrap();
    }
    assert!(registry.journal_segments().unwrap().len() > 2, "several segments");
    assert_eq!(unmapped_segments(&registry), registry.journal_segments().unwrap().len() as i64);
    (root, registry, sealed_maps)
}

fn kind_maps(registry: &WorkspaceRegistry) -> Vec<(String, String)> {
    let db = registry.connection.get();
    let mut statement =
        db.prepare("SELECT segment_id, kind FROM journal_segment_kinds ORDER BY 1, 2").unwrap();
    statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

fn unmapped_segments(registry: &WorkspaceRegistry) -> i64 {
    registry
        .connection
        .get()
        .query_row(
            "SELECT COUNT(*) FROM journal_segments AS segment WHERE NOT EXISTS (
               SELECT 1 FROM journal_segment_kinds AS kinds
               WHERE kinds.segment_id = segment.segment_id)",
            [],
            |row| row.get(0),
        )
        .unwrap()
}

/// The roster's records from the first one, read as its rebuild after a
/// reducer version bump reads them: on a read-only connection of its own.
fn rebuild_read(registry: &WorkspaceRegistry) -> anyhow::Result<Vec<SessionJournalRecord>> {
    let reader = SessionJournalReader::open(&registry.session_journal_database_path().unwrap())?;
    let head = registry.session_journal_head()?;
    let (mut cursor, mut records) = (0, Vec::new());
    while cursor < head {
        let (page, reached) = reader.kinds_after(
            cursor,
            head,
            crate::journal_reducers::AgentRoster::folds_kind,
            512,
        )?;
        anyhow::ensure!(reached > cursor, "a page made no progress");
        records.extend(page);
        cursor = reached;
    }
    Ok(records)
}

/// A legacy registry: the rebuild's read decodes every legacy segment and
/// writes nothing, so it would at every later bump too. The reducer record
/// backfill writes each legacy segment's whole kind map (the one its seal
/// would have written, terminal output included) with its kept records,
/// and the next rebuild's read decodes no segment: it succeeds after every
/// segment's content is destroyed.
#[test]
fn the_backfill_maps_legacy_segments_so_a_later_bump_decodes_none() {
    let (root, registry, sealed_maps) = legacy_registry("kind-map-backfill");
    let segments = unmapped_segments(&registry);
    assert_eq!(rebuild_read(&registry).unwrap().len(), SEALED_AGENT_RECORDS);
    assert_eq!(unmapped_segments(&registry), segments, "a read-only read maps nothing");

    let decoded = run_reducer_record_backfill(&registry, usize::MAX);
    assert_eq!(decoded as i64, segments, "each legacy segment decodes once");
    assert_eq!(unmapped_segments(&registry), 0);
    assert_eq!(kind_maps(&registry), sealed_maps, "the maps are the ones sealing writes");
    assert_eq!(kept_reducer_records(&registry), SEALED_AGENT_RECORDS as i64);
    assert_eq!(unproven_kind_maps(&registry.connection.get()).unwrap(), None);
    assert_eq!(run_reducer_record_backfill(&registry, usize::MAX), 0, "a done backfill stays done");

    destroy_sealed_segments(&registry);
    assert_eq!(
        rebuild_read(&registry).unwrap().len(),
        SEALED_AGENT_RECORDS,
        "the read after the backfill decoded a segment"
    );
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// A registry whose reducer record backfill finished under the earlier
/// cursor rule kept the agent records of its legacy segments but mapped
/// none of them, so the read still decoded them all. Its cursor starts the
/// backfill over, which maps them.
#[test]
fn a_backfill_finished_before_it_wrote_kind_maps_starts_over() {
    let (root, registry, sealed_maps) = legacy_registry("kind-map-backfill-rule");
    run_reducer_record_backfill(&registry, usize::MAX);
    {
        let db = registry.connection.get();
        db.execute("DELETE FROM journal_segment_kinds", []).unwrap();
        db.execute(
            "UPDATE meta SET value = json_set(value, '$.kind_map', 1)
             WHERE key = 'journal_segment_reducer_records_backfill'",
            [],
        )
        .unwrap();
    }
    assert!(run_reducer_record_backfill(&registry, usize::MAX) > 0, "the older cursor starts over");
    assert_eq!(kind_maps(&registry), sealed_maps);
    destroy_sealed_segments(&registry);
    assert_eq!(rebuild_read(&registry).unwrap().len(), SEALED_AGENT_RECORDS);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// A legacy kind backfill that a read on the writer's connection started
/// and did not finish (it maps a slice per read) leaves every kind map in
/// its range unproven, so each read decodes those segments. The owner's
/// slices finish it, a slice per call, and it never starts one itself.
#[test]
fn the_owner_finishes_an_unfinished_legacy_kind_backfill() {
    let (root, registry, sealed_maps) = legacy_registry("kind-map-backfill-legacy");
    assert!(!registry.continue_legacy_kind_backfill().unwrap(), "no backfill to finish");
    assert_eq!(unmapped_segments(&registry) as usize, registry.journal_segments().unwrap().len());

    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(Some(std::time::Duration::ZERO)));
    let head = registry.session_journal_head().unwrap();
    registry
        .session_journal_kinds_after(0, head, crate::journal_reducers::AgentRoster::folds_kind, 1)
        .unwrap();
    assert!(unproven_kind_maps(&registry.connection.get()).unwrap().is_some(), "it started");
    let mut slices = 0;
    while registry.continue_legacy_kind_backfill().unwrap() {
        slices += 1;
        assert!(slices < 1_000, "the backfill never finished");
    }
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(None));
    assert!(slices > 0, "one slice per call");
    assert_eq!(unproven_kind_maps(&registry.connection.get()).unwrap(), None);
    assert_eq!(kind_maps(&registry), sealed_maps);

    run_reducer_record_backfill(&registry, usize::MAX);
    destroy_sealed_segments(&registry);
    assert_eq!(rebuild_read(&registry).unwrap().len(), SEALED_AGENT_RECORDS);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
