//! The delete of one segment in more than one transaction, at the registry.
//!
//! Each test has a real registry file with an old segment of
//! [`OLD_RECORDS`] agent records (more than two holds of
//! [`RETENTION_RECORDS_PER_HOLD`]) and a newer segment, each reducer at the
//! head, and calls the three parts of the delete as the maintenance worker's
//! pass does. No test times anything.

use rusqlite::{Connection, params};

use super::part_deleted_tests::{NEW_RECORDS, Sealed, sealed_with};
use super::*;
use crate::workspace_registry::session_journal::reducer_records::ReducerRecordBackfillStep;

/// Agent records of the old segment: two full holds and a part of a third.
const OLD_RECORDS: usize = 600;

/// The delete triggers a build before the delete in parts made.
const OLD_DELETE_TRIGGERS: &str = "
    CREATE TRIGGER IF NOT EXISTS journal_segments_reject_delete
      BEFORE DELETE ON journal_segments
    BEGIN
      SELECT RAISE(ABORT, 'journal segments are immutable');
    END;
    CREATE TRIGGER IF NOT EXISTS journal_subject_index_reject_delete
      BEFORE DELETE ON journal_subject_index
    BEGIN
      SELECT RAISE(ABORT, 'journal subject index is append-only');
    END;";

/// The registry of the module doc: each reducer saved at the head, so each
/// can have a base at the end of the old segment.
fn registry(label: &str) -> Sealed {
    let sealed = sealed_with(label, OLD_RECORDS);
    let head = sealed.registry.session_journal_head().unwrap();
    for (reducer, version) in base::FLOOR_REDUCERS {
        sealed
            .registry
            .connection
            .finish_journal_reducer_rebuild(reducer, version, head, "{}")
            .unwrap();
    }
    sealed
}

/// Records with a row in one of the four row tables, in `(after, through]`.
fn records_with_rows(db: &Connection, after: u64, through: u64) -> u64 {
    let (after, through) = (i64::try_from(after).unwrap(), i64::try_from(through).unwrap());
    let count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM (
               SELECT sequence FROM journal_segment_reducer_records
               WHERE sequence > ?1 AND sequence <= ?2
               UNION SELECT sequence FROM journal_subject_index
               WHERE sequence > ?1 AND sequence <= ?2
               UNION SELECT sequence FROM journal_event_index
               WHERE sequence > ?1 AND sequence <= ?2
               UNION SELECT journal_sequence FROM journal_ingress_receipts
               WHERE journal_sequence > ?1 AND journal_sequence <= ?2)",
            params![after, through],
            |row| row.get(0),
        )
        .unwrap();
    u64::try_from(count).unwrap()
}

/// The rows of the four row tables at or below the record `through`.
fn rows_at_or_below(db: &Connection, through: u64) -> u64 {
    let count: i64 = db
        .query_row(
            "SELECT (SELECT COUNT(*) FROM journal_segment_reducer_records WHERE sequence <= ?1)
                  + (SELECT COUNT(*) FROM journal_subject_index WHERE sequence <= ?1)
                  + (SELECT COUNT(*) FROM journal_event_index WHERE sequence <= ?1)
                  + (SELECT COUNT(*) FROM journal_ingress_receipts WHERE journal_sequence <= ?1)",
            [i64::try_from(through).unwrap()],
            |row| row.get(0),
        )
        .unwrap();
    u64::try_from(count).unwrap()
}

fn segment_rows(db: &Connection, end: u64) -> i64 {
    db.query_row(
        "SELECT COUNT(*) FROM journal_segments WHERE end_sequence = ?1",
        [i64::try_from(end).unwrap()],
        |row| row.get(0),
    )
    .unwrap()
}

/// The delete triggers of the two tables, by name.
fn delete_triggers(db: &Connection) -> Vec<String> {
    let mut statement = db
        .prepare(
            "SELECT name FROM sqlite_master
             WHERE type = 'trigger' AND tbl_name IN ('journal_segments', 'journal_subject_index')
               AND sql LIKE '%BEFORE DELETE%'
             ORDER BY name",
        )
        .unwrap();
    statement.query_map([], |row| row.get(0)).unwrap().map(Result::unwrap).collect()
}

/// What a delete of the segment that ends at `end`, and of the subject rows
/// of the record `sequence`, gives: the two error texts (`None`: deleted).
/// Each runs in a transaction that is rolled back.
fn try_deletes(db: &Connection, end: u64, sequence: u64) -> (Option<String>, Option<String>) {
    let attempt = |before: Option<&str>, sql: &str, value: u64| -> Option<String> {
        let value = i64::try_from(value).unwrap();
        let tx = db.unchecked_transaction().unwrap();
        if let Some(before) = before {
            tx.execute(before, [value]).unwrap();
        }
        let outcome = tx.execute(sql, [value]);
        if let Ok(rows) = outcome {
            assert!(rows > 0, "the setup: the delete names a row: {sql} {value}");
        }
        // Dropped: rolled back.
        outcome.err().map(|error| error.to_string())
    };
    (
        attempt(
            // The kind map names the segment by a foreign key: it goes first.
            Some(
                "DELETE FROM journal_segment_kinds WHERE segment_id IN
                   (SELECT segment_id FROM journal_segments WHERE end_sequence = ?1)",
            ),
            "DELETE FROM journal_segments WHERE end_sequence = ?1",
            end,
        ),
        attempt(None, "DELETE FROM journal_subject_index WHERE sequence = ?1", sequence),
    )
}

/// The end of the newer segment (the one that holds the record `sequence`).
fn segment_end_of(sealed: &Sealed, sequence: u64) -> u64 {
    sealed
        .registry
        .journal_segments()
        .unwrap()
        .iter()
        .find(|segment| segment.start_sequence <= sequence && sequence <= segment.end_sequence)
        .expect("the setup: a segment holds the record")
        .end_sequence
}

/// A hold of the registry lock deletes the rows of at most
/// [`RETENTION_RECORDS_PER_HOLD`] records, the lowest first; the floor moves
/// first and deletes nothing; the segment's row with its content goes last.
#[test]
fn one_hold_deletes_the_rows_of_at_most_256_records_and_the_content_goes_last() {
    let mut sealed = registry("holds");
    let (old_end, head) = (sealed.old_end, sealed.registry.session_journal_head().unwrap());
    let count = |sealed: &Sealed| records_with_rows(&sealed.registry.connection.get(), 0, old_end);
    let later =
        |sealed: &Sealed| records_with_rows(&sealed.registry.connection.get(), old_end, head);
    let (whole, later_before) = (count(&sealed), later(&sealed));
    assert!(
        whole > 2 * RETENTION_RECORDS_PER_HOLD,
        "the setup: the old segment has rows of more records than two holds take: {whole}"
    );

    let segment = sealed
        .registry
        .begin_journal_segment_prune(old_end)
        .unwrap()
        .expect("the first hold selects the old segment");
    assert_eq!(sealed.registry.journal_pruned_through().unwrap(), old_end, "the floor moved");
    assert_eq!(count(&sealed), whole, "the first hold deletes no row");

    let mut holds = 0;
    loop {
        let before = count(&sealed);
        let more = sealed.registry.delete_pruned_segment_rows(&segment).unwrap();
        let after = count(&sealed);
        holds += 1;
        assert!(
            before - after <= RETENTION_RECORDS_PER_HOLD,
            "hold {holds} deleted the rows of {} records",
            before - after
        );
        assert_eq!(
            segment_rows(&sealed.registry.connection.get(), old_end),
            1,
            "the segment row with its content is there after hold {holds}"
        );
        if !more {
            break;
        }
        assert_eq!(
            before - after,
            RETENTION_RECORDS_PER_HOLD,
            "a hold that is not the last is full"
        );
        // The lowest records go first: the last agent record has its rows.
        let last = sealed.old[OLD_RECORDS - 1];
        assert_eq!(
            records_with_rows(&sealed.registry.connection.get(), last - 1, last),
            1,
            "the rows of the last agent record are there after hold {holds}"
        );
    }
    assert!(holds >= 3, "the rows went in {holds} holds");
    assert_eq!(count(&sealed), 0, "no row of the old segment's records is left");

    assert!(sealed.registry.finish_journal_segment_prune(&segment).unwrap());
    assert_eq!(segment_rows(&sealed.registry.connection.get(), old_end), 0, "the segment is gone");
    assert_eq!(later(&sealed), later_before, "each row above the old segment stays");
    assert_eq!(sealed.new.len(), NEW_RECORDS);
    sealed.close();
}

/// A hold of the registry lock deletes at most [`RETENTION_ROWS_PER_HOLD`]
/// rows, whatever the rows of a record are: a record of a long-lived
/// session has about 15 subject rows, and a hold of 256 records read about
/// 10,500 pages of the file under the lock. A hold that is not the last is
/// full; the segment's row with its content goes last; nothing above the
/// segment changes. It counts rows and times nothing.
#[test]
fn one_hold_deletes_at_most_the_bound_of_rows_and_the_content_goes_last() {
    let mut sealed = registry("row-bound");
    let (old_end, head) = (sealed.old_end, sealed.registry.session_journal_head().unwrap());
    let rows = |sealed: &Sealed| rows_at_or_below(&sealed.registry.connection.get(), old_end);
    let later =
        |sealed: &Sealed| records_with_rows(&sealed.registry.connection.get(), old_end, head);
    let (whole, later_before) = (rows(&sealed), later(&sealed));
    assert!(
        whole > 2 * RETENTION_ROWS_PER_HOLD,
        "the setup: the old segment has more rows than two holds take: {whole}"
    );

    let segment = sealed
        .registry
        .begin_journal_segment_prune(old_end)
        .unwrap()
        .expect("the first hold selects the old segment");
    assert_eq!(rows(&sealed), whole, "the first hold deletes no row");

    let mut holds: u64 = 0;
    loop {
        let before = rows(&sealed);
        let more = sealed.registry.delete_pruned_segment_rows(&segment).unwrap();
        let deleted = before - rows(&sealed);
        holds += 1;
        assert!(
            deleted <= RETENTION_ROWS_PER_HOLD,
            "hold {holds} deleted {deleted} rows of {whole}; a hold deletes at most \
             {RETENTION_ROWS_PER_HOLD}"
        );
        assert_eq!(
            segment_rows(&sealed.registry.connection.get(), old_end),
            1,
            "the segment row with its content is there after hold {holds}"
        );
        if !more {
            break;
        }
        assert_eq!(deleted, RETENTION_ROWS_PER_HOLD, "hold {holds} is not the last and is full");
    }
    assert!(
        holds >= whole.div_ceil(RETENTION_ROWS_PER_HOLD),
        "the {whole} rows went in {holds} holds"
    );
    assert_eq!(rows(&sealed), 0, "no row of the old segment's records is left");

    assert!(sealed.registry.finish_journal_segment_prune(&segment).unwrap());
    assert_eq!(segment_rows(&sealed.registry.connection.get(), old_end), 0, "the segment is gone");
    assert_eq!(later(&sealed), later_before, "each row above the old segment stays");
    assert_eq!(sealed.new.len(), NEW_RECORDS);
    sealed.close();
}

/// The two tables refuse a delete above the floor and permit one at or
/// below it. The trigger reads the floor from `meta`: no schema change.
#[test]
fn a_delete_above_the_floor_is_refused_in_each_of_the_two_tables() {
    let mut sealed = registry("refused");
    let (old_end, new_end) = (sealed.old_end, segment_end_of(&sealed, sealed.new[0]));
    let deletes = |sealed: &Sealed, end: u64, sequence: u64| {
        try_deletes(&sealed.registry.connection.get(), end, sequence)
    };

    // No floor yet: each row is above it.
    let (segment, subject) = deletes(&sealed, old_end, sealed.old[0]);
    assert!(
        segment.as_deref().is_some_and(|error| error.contains("immutable")),
        "a segment above the floor: {segment:?}"
    );
    assert!(
        subject.as_deref().is_some_and(|error| error.contains("append-only")),
        "a subject row above the floor: {subject:?}"
    );

    let begun = sealed.registry.begin_journal_segment_prune(old_end).unwrap();
    assert!(begun.is_some(), "the setup: the floor moves to the end of the old segment");
    let schema_version = |sealed: &Sealed| -> i64 {
        sealed
            .registry
            .connection
            .get()
            .query_row("PRAGMA schema_version", [], |row| row.get(0))
            .unwrap()
    };
    let schema_before = schema_version(&sealed);

    assert_eq!(
        deletes(&sealed, old_end, sealed.old[0]),
        (None, None),
        "at or below the floor both deletes are permitted"
    );
    let (segment, subject) = deletes(&sealed, new_end, sealed.new[0]);
    assert!(
        segment.as_deref().is_some_and(|error| error.contains("immutable")),
        "a segment above the floor {old_end}: {segment:?}"
    );
    assert!(
        subject.as_deref().is_some_and(|error| error.contains("append-only")),
        "a subject row above the floor {old_end}: {subject:?}"
    );

    assert!(
        sealed.registry.prune_oldest_journal_segment(old_end).unwrap(),
        "the delete to its end"
    );
    assert_eq!(schema_version(&sealed), schema_before, "the delete of a segment changes no schema");
    sealed.close();
}

/// A build before the delete in parts opened the file last: its two
/// triggers refuse each delete. In one arm it made them beside the new
/// ones, in the other the file never had the new ones. The open replaces
/// them before a retention pass can run, and the pass deletes.
#[test]
fn a_file_with_the_old_delete_triggers_opens_and_retention_deletes() {
    for (arm, drop_new) in [("old-only", true), ("old-beside-new", false)] {
        let sealed = registry(arm);
        let (old_end, new_end, new_first) =
            (sealed.old_end, segment_end_of(&sealed, sealed.new[0]), sealed.new[0]);
        let Sealed { root, registry, .. } = sealed;
        let path = registry.session_journal_database_path().unwrap();
        drop(registry);
        {
            let db = Connection::open(&path).unwrap();
            if drop_new {
                db.execute_batch(
                    "DROP TRIGGER journal_segments_keep_above_floor;
                     DROP TRIGGER journal_subject_index_keep_above_floor;",
                )
                .unwrap();
            }
            db.execute_batch(OLD_DELETE_TRIGGERS).unwrap();
            let refused = db
                .execute(
                    "DELETE FROM journal_subject_index WHERE sequence <= ?1",
                    [i64::try_from(old_end).unwrap()],
                )
                .expect_err("the setup: the old trigger refuses each delete");
            assert!(refused.to_string().contains("append-only"), "{arm}: {refused}");
        }

        let mut registry = WorkspaceRegistry::open(&root, arm).unwrap();
        assert_eq!(
            delete_triggers(&registry.connection.get()),
            ["journal_segments_keep_above_floor", "journal_subject_index_keep_above_floor"],
            "{arm}: the open leaves the two triggers of this build and no older one"
        );
        assert!(
            registry.prune_oldest_journal_segment(old_end).unwrap(),
            "{arm}: the pass deletes the old segment"
        );
        let db = registry.connection.get();
        assert_eq!(segment_rows(&db, old_end), 0, "{arm}: the old segment is gone");
        assert_eq!(records_with_rows(&db, 0, old_end), 0, "{arm}: and each row of its records");
        let (segment, subject) = try_deletes(&db, new_end, new_first);
        assert!(
            segment.is_some() && subject.is_some(),
            "{arm}: a row above the floor is refused: {segment:?} {subject:?}"
        );
        drop(db);
        drop(registry);
        std::fs::remove_dir_all(root).unwrap();
    }
}

/// A close between two transactions of the delete: the floor is at the end
/// of the segment and rows of a part of its records are there. The next
/// start's pass selects the same segment and ends the delete; nothing above
/// the segment changes. The registry is closed here (a drop), so this is
/// not a kill: a process killed between two holds (no close, the WAL not
/// checkpointed) is the arm `kill-hold` of the proof tool.
#[test]
fn a_start_after_a_close_between_two_holds_ends_the_delete() {
    let mut sealed = registry("kill");
    let (old_end, head) = (sealed.old_end, sealed.registry.session_journal_head().unwrap());
    let later_before = records_with_rows(&sealed.registry.connection.get(), old_end, head);
    let segment = sealed.registry.begin_journal_segment_prune(old_end).unwrap().unwrap();
    assert!(sealed.registry.delete_pruned_segment_rows(&segment).unwrap(), "the setup: rows left");
    let left = records_with_rows(&sealed.registry.connection.get(), 0, old_end);
    assert!(left > 0, "the setup: the close is between two holds");
    let Sealed { root, registry, .. } = sealed;
    // The close: no later hold ran.
    drop(registry);

    let mut registry = WorkspaceRegistry::open(&root, "kill").unwrap();
    assert_eq!(registry.journal_pruned_through().unwrap(), old_end, "the floor is stored");
    {
        let db = registry.connection.get();
        assert_eq!(segment_rows(&db, old_end), 1, "the part-deleted segment is there");
        assert_eq!(records_with_rows(&db, 0, old_end), left);
    }
    assert!(
        registry.prune_oldest_journal_segment(old_end).unwrap(),
        "the next pass takes it again"
    );
    let db = registry.connection.get();
    assert_eq!(segment_rows(&db, old_end), 0, "the segment is gone after the next pass");
    assert_eq!(records_with_rows(&db, 0, old_end), 0, "no row of its records is left");
    assert_eq!(records_with_rows(&db, old_end, head), later_before, "the rest is as it was");
    drop(db);
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// The backfill of kept reducer records fills a segment that has none. A
/// part-deleted segment whose kept rows are gone is such a segment: after a
/// kill before the last hold, a backfill that starts again from the first
/// segment writes its rows again. The last hold then refuses to delete the
/// content while a row is left, so a kept row never outlives its segment.
#[test]
fn the_backfill_fills_a_part_deleted_segment_again_and_no_row_outlives_the_segment() {
    let mut sealed = registry("backfill");
    let old_end = sealed.old_end;
    let segment = sealed.registry.begin_journal_segment_prune(old_end).unwrap().unwrap();
    while sealed.registry.delete_pruned_segment_rows(&segment).unwrap() {}
    assert_eq!(records_with_rows(&sealed.registry.connection.get(), 0, old_end), 0, "the setup");

    // The backfill starts again from the first segment, as after a cleanup
    // or a build with one more reducer kind.
    sealed
        .registry
        .connection
        .get()
        .execute("DELETE FROM meta WHERE key = 'journal_segment_reducer_records_backfill'", [])
        .unwrap();
    let reader = sealed.reader();
    let ReducerRecordBackfillStep::Decode(plan) =
        sealed.registry.plan_reducer_record_backfill(8).unwrap()
    else {
        panic!("the setup: the backfill decodes the part-deleted segment");
    };
    assert!(
        sealed.registry.commit_reducer_record_backfill(plan.prepare(&reader).unwrap()).unwrap()
    );
    drop(reader);
    let refilled = records_with_rows(&sealed.registry.connection.get(), 0, old_end);
    assert!(refilled > 0, "the setup: the backfill wrote kept rows of the segment again");

    assert!(
        !sealed.registry.finish_journal_segment_prune(&segment).unwrap(),
        "the last hold deletes no content while {refilled} records have a row"
    );
    assert_eq!(segment_rows(&sealed.registry.connection.get(), old_end), 1);

    assert!(sealed.registry.prune_oldest_journal_segment(old_end).unwrap(), "the pass goes on");
    let db = sealed.registry.connection.get();
    assert_eq!(segment_rows(&db, old_end), 0, "the segment is gone");
    assert_eq!(records_with_rows(&db, 0, old_end), 0, "and no kept row outlives it");
    drop(db);
    sealed.close();
}
