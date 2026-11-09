//! The cleanup copies every kept record, Phase B inside the open, so it runs
//! only where output is most of the journal. A registry whose journal is
//! mostly other records is not staged, and a staged cleanup that would copy
//! too much is abandoned at open before anything is copied.

use std::fs;

use super::stage::{StageControl, StageOutcome, open_staging, sealed_records, stage_registry};
use super::*;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("cmux-output-cleanup-guard-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A registry with the journal tables the cleanup reads: `output` live
/// output rows and `other` live rows of another kind.
fn registry(dir: &Path, output: i64, other: i64) -> PathBuf {
    let db_path = dir.join("workspace-registry.sqlite3");
    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO meta VALUES('registry_id', 'registry-guard');
             CREATE TABLE session_journal(sequence INTEGER PRIMARY KEY, kind TEXT NOT NULL);
             CREATE INDEX session_journal_by_kind_sequence ON session_journal(kind, sequence);
             CREATE TABLE journal_segments(
               segment_id TEXT PRIMARY KEY, start_sequence INTEGER, end_sequence INTEGER,
               record_count INTEGER);
             CREATE TABLE journal_segment_kinds(
               segment_id TEXT, kind TEXT, PRIMARY KEY(segment_id, kind)) WITHOUT ROWID;",
        )
        .unwrap();
    connection
        .execute(
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?1 + ?2)
             INSERT INTO session_journal
             SELECT i, CASE WHEN i <= ?1 THEN 'terminal.output' ELSE 'personal.session.put' END
             FROM n",
            [output, other],
        )
        .unwrap();
    db_path
}

#[test]
fn a_registry_mostly_of_other_records_is_not_staged_and_its_staging_file_goes() {
    let dir = temp_dir("stage");
    let db_path = registry(&dir, 1, 100);
    // A staging file an earlier build left for this registry.
    drop(open_staging(&db_path, "registry-guard").unwrap());
    assert!(staging_path(&db_path).is_file());

    let outcome = stage_registry(
        &db_path,
        &StageControl {
            on_pending: &|| {},
            next_segment: &|| true,
            stopped: std::sync::Arc::new(|| false),
        },
    )
    .unwrap();
    assert!(!matches!(outcome, StageOutcome::Complete { .. }), "staged: {outcome:?}");
    assert!(!staging_path(&db_path).exists(), "the staging file stays: {outcome:?}");
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn an_open_abandons_a_staged_cleanup_that_would_copy_too_much() {
    let dir = temp_dir("swap");
    let db_path = registry(&dir, 1, 10);
    // A complete staging file whose segments keep two million records: the
    // open would copy every one of them.
    let staging = open_staging(&db_path, "registry-guard").unwrap();
    staging
        .execute_batch(
            "INSERT INTO output_cleanup_segments VALUES(1, 2000000, 2000000, 2000000, 0);
             UPDATE output_cleanup_state SET value = '1' WHERE key = 'complete';",
        )
        .unwrap();
    drop(staging);
    let before = fs::read(&db_path).unwrap();

    assert!(!swap_at_open(&db_path, &|_| Ok(())), "the registry was swapped");
    assert!(!staging_path(&db_path).exists(), "the staging file stays");
    assert!(!failed_path(&db_path).exists(), "the swap ran and failed");
    assert_eq!(fs::read(&db_path).unwrap(), before, "the registry changed");
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_sealed_estimate_counts_only_segments_whose_kinds_settle_it() {
    let dir = temp_dir("sealed");
    let db_path = registry(&dir, 0, 0);
    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute_batch(
            "INSERT INTO journal_segments VALUES
               ('output', 1, 100, 100), ('other', 101, 130, 30), ('mixed', 131, 140, 10),
               ('unmapped', 141, 145, 5);
             INSERT INTO journal_segment_kinds VALUES
               ('output', 'terminal.output'), ('other', 'personal.session.put'),
               ('other', 'terminal.title'), ('mixed', 'terminal.output'),
               ('mixed', 'terminal.title');",
        )
        .unwrap();
    assert_eq!(sealed_records(&connection).unwrap(), (30, 130));
    drop(connection);
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_kept_bounds() {
    assert_eq!(kept_refusal(10, 100), None);
    assert_eq!(kept_refusal(50, 100), None);
    assert!(kept_refusal(51, 100).is_some(), "over half");
    assert!(kept_refusal(MAX_KEPT_RECORDS + 1, u64::MAX).is_some(), "over the bound");
}
