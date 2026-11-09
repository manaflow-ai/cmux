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
fn the_sealed_estimate_reads_the_kind_map_and_counts_every_record() {
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
    let all = sealed_records(&connection, 0).unwrap();
    assert_eq!((all.kept_at_least, all.kept_at_most, all.total), (30, 45, 145));
    let tail = sealed_records(&connection, 130).unwrap();
    assert_eq!((tail.kept_at_least, tail.kept_at_most, tail.total), (0, 15, 15));
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

/// Base-compatible checks of the three review follow-ups on #39175 (the
/// estimate's denominator, the staged size at completion, the tail sealed
/// after Phase A).
mod followups {
    use super::*;

    fn control() -> StageControl<'static> {
        StageControl {
            on_pending: &|| {},
            next_segment: &|| true,
            stopped: std::sync::Arc::new(|| false),
        }
    }

    #[test]
    fn a_mixed_segment_counts_toward_the_journal_so_a_mostly_output_registry_is_staged() {
        // One sealed segment of mostly output (it lists another kind too),
        // then ten live rows of another kind: output is most of the journal.
        // The segment has no content, so staging it fails: the cleanup got
        // past its estimate.
        let dir = temp_dir("mixed-denominator");
        let db_path = registry(&dir, 0, 0);
        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute_batch(
                "INSERT INTO journal_segments VALUES ('mixed', 1, 1000, 1000);
                 INSERT INTO journal_segment_kinds VALUES
                   ('mixed', 'terminal.output'), ('mixed', 'terminal.title');
                 WITH RECURSIVE n(i) AS (SELECT 1001 UNION ALL SELECT i + 1 FROM n WHERE i < 1010)
                 INSERT INTO session_journal SELECT i, 'personal.session.put' FROM n;",
            )
            .unwrap();
        drop(connection);
        let outcome = stage_registry(&db_path, &control());
        assert!(
            !matches!(outcome, Ok(StageOutcome::Skipped(_))),
            "a journal of 999 output records in 1010 was skipped: {outcome:?}"
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn phase_a_does_not_complete_with_a_staging_file_over_its_size_bound() {
        // Fewer segments than one periodic check: only the check at the end
        // sees the file. A sparse tail past the bound stands in for staged
        // records (SQLite reads the size in the file's header).
        let dir = temp_dir("staged-bytes");
        let db_path = registry(&dir, 100, 1);
        drop(open_staging(&db_path, "registry-guard").unwrap());
        fs::OpenOptions::new()
            .write(true)
            .open(staging_path(&db_path))
            .unwrap()
            .set_len((2 << 30) + 4096)
            .unwrap();
        // SAFETY: nextest runs each test in its own process. Under a shared
        // process the value only lowers the cleanup's free-space margin.
        unsafe { std::env::set_var("CMUX_TUI_TEST_OUTPUT_CLEANUP_MARGIN_BYTES", "0") };
        let outcome = stage_registry(&db_path, &control()).unwrap();
        assert!(!matches!(outcome, StageOutcome::Complete { .. }), "completed: {outcome:?}");
        assert!(!staging_path(&db_path).exists(), "the staging file stays: {outcome:?}");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_open_abandons_a_cleanup_whose_tail_sealed_after_staging_would_copy_too_much() {
        // Phase A staged nothing; two million records were sealed after it.
        let dir = temp_dir("sealed-tail");
        let db_path = registry(&dir, 1, 10);
        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute_batch(
                "INSERT INTO journal_segments VALUES ('tail', 100, 2000099, 2000000);
                 INSERT INTO journal_segment_kinds VALUES ('tail', 'personal.session.put');",
            )
            .unwrap();
        drop(connection);
        let staging = open_staging(&db_path, "registry-guard").unwrap();
        staging
            .execute("UPDATE output_cleanup_state SET value = '1' WHERE key = 'complete'", [])
            .unwrap();
        drop(staging);
        let before = fs::read(&db_path).unwrap();

        assert!(!swap_at_open(&db_path, &|_| Ok(())), "the registry was swapped");
        assert!(!failed_path(&db_path).exists(), "the open staged the tail and failed");
        assert!(!staging_path(&db_path).exists(), "the staging file stays");
        assert_eq!(fs::read(&db_path).unwrap(), before, "the registry changed");
        fs::remove_dir_all(&dir).unwrap();
    }
}
