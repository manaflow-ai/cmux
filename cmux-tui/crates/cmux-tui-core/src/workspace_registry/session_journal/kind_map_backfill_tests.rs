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

/// Before the fix: on a legacy registry the rebuild's read-only read and a
/// finished reducer record backfill leave every segment unmapped, so the
/// next bump's read still decodes every segment (it fails once their
/// content is destroyed).
#[test]
fn before_fix_probe_nothing_maps_legacy_segments() {
    let (root, registry, sealed_maps) = legacy_registry("kind-map-probe");
    let segments = unmapped_segments(&registry);
    assert_eq!(rebuild_read(&registry).unwrap().len(), SEALED_AGENT_RECORDS);
    let decoded = run_reducer_record_backfill(&registry, usize::MAX);
    eprintln!(
        "PROBE segments={segments} sealed_kind_rows={} after_rebuild_read_and_reducer_backfill: \
         decoded={decoded} unmapped={} kind_rows={} kept_rows={} unproven={:?}",
        sealed_maps.len(),
        unmapped_segments(&registry),
        kind_maps(&registry).len(),
        kept_reducer_records(&registry),
        unproven_kind_maps(&registry.connection.get()).unwrap(),
    );
    assert_eq!(unmapped_segments(&registry), segments, "something mapped the legacy segments");
    destroy_sealed_segments(&registry);
    let read = rebuild_read(&registry);
    eprintln!(
        "PROBE second bump read after destroying segment content: {:?}",
        read.as_ref().map(Vec::len).map_err(|e| format!("{e:#}"))
    );
    assert!(read.is_err(), "the read decoded no segment");
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
