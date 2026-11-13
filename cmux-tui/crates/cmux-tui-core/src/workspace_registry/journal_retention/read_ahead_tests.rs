//! The read before a hold ([`RetentionReadAhead`]): it goes through each
//! index that the hold's delete goes through, and it leaves no read open.
//! No test times anything.

use std::path::Path;
use std::time::Duration;

use rusqlite::Connection;

use super::part_deleted_tests::sealed_with;
use super::read_ahead::HOLD_ROW_READS;
use super::*;
use crate::workspace_registry::open_registry_database_read_only;

/// Agent records of the old segment: two full holds and a part of a third.
const OLD_RECORDS: usize = 600;

/// The steps of the query plan of `sql` (its `detail` column).
fn plan(db: &Connection, sql: &str) -> Vec<String> {
    let mut statement = db.prepare(&format!("EXPLAIN QUERY PLAN {sql}")).unwrap();
    statement
        .query_map([1_i64], |row| row.get::<_, String>(3))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

/// The indexes of `table`: name, and origin (`pk`, `u` or `c`).
fn indexes(db: &Connection, table: &str) -> Vec<(String, String)> {
    let mut statement = db.prepare(&format!("PRAGMA index_list({table})")).unwrap();
    statement
        .query_map([], |row| Ok((row.get::<_, String>(1)?, row.get::<_, String>(3)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

/// The delete of a row goes through the table and each index of it. The
/// read before a hold must go the same way, or the hold reads the pages of
/// the index that the read left out from the file, under the lock. The
/// indexes come from the schema of a registry that this build opened, so a
/// new index of one of the four tables fails here until the read has it.
#[test]
fn the_read_before_a_hold_goes_through_each_index_of_each_table_that_the_hold_deletes_from() {
    let sealed = sealed_with("read-ahead-indexes", OLD_RECORDS);
    let db = sealed.registry.connection.get();
    let tables: Vec<&str> = PRUNED_ROW_TABLES.iter().map(|(table, _)| *table).collect();
    let read_tables: Vec<&str> = HOLD_ROW_READS.iter().map(|(table, _)| *table).collect();
    assert_eq!(read_tables, tables, "one read for each table that a hold deletes from");

    let mut problems = Vec::new();
    let mut seen = 0;
    for (table, read) in HOLD_ROW_READS {
        let steps = plan(&db, read);
        // The rows themselves: the scan of the rows at or below the record
        // is not answered from an index alone.
        match steps.iter().find(|step| step.contains(" hold ")) {
            Some(step) if !step.contains("COVERING") => {}
            step => problems.push(format!("{table}: the rows are not read: {step:?} of {steps:?}")),
        }
        for (index, origin) in indexes(&db, table) {
            seen += 1;
            // The primary key of a table with no rowid is the table.
            let is_the_table =
                origin == "pk" && steps.iter().any(|step| step.contains(" hold USING PRIMARY KEY"));
            let named = steps.iter().any(|step| {
                step.split_whitespace()
                    .zip(step.split_whitespace().skip(1))
                    .any(|(word, name)| word == "INDEX" && name == index)
            });
            if !named && !is_the_table {
                problems.push(format!("{table}: no read through the index {index}: {steps:?}"));
            }
        }
    }
    drop(db);
    sealed.close();
    assert!(seen >= 8, "the setup: the four tables have {seen} indexes, 8 or more are known");
    assert!(problems.is_empty(), "{problems:#?}");
}

/// A checkpoint that resets the WAL and cuts its file, with no wait:
/// `true` when no reader stopped it and the file is empty after it.
fn the_wal_resets(checkpointer: &Connection, database: &Path) -> bool {
    let busy = checkpointer
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get::<_, i64>(0))
        .unwrap_or(1);
    let wal = std::fs::metadata(format!("{}-wal", database.display()))
        .map(|file| file.len())
        .unwrap_or(0);
    busy == 0 && wal == 0
}

/// A read of the pass that stayed open would keep the WAL syncer's
/// checkpoint from each frame that a hold writes after it. The control at
/// the end is the same check with a read that IS open: it must not pass.
#[test]
fn the_reads_before_a_hold_end_so_the_wal_resets_while_the_reader_is_open() {
    let mut sealed = sealed_with("read-ahead-wal", OLD_RECORDS);
    let head = sealed.registry.session_journal_head().unwrap();
    for (reducer, version) in base::FLOOR_REDUCERS {
        sealed
            .registry
            .connection
            .finish_journal_reducer_rebuild(reducer, version, head, "{}")
            .unwrap();
    }
    let database = sealed.registry.session_journal_database_path().unwrap();
    let checkpointer = Connection::open(&database).unwrap();
    checkpointer.busy_timeout(Duration::ZERO).unwrap();

    let reader = RetentionReadAhead::open(&database).unwrap();
    let old_end = sealed.old_end;
    reader.rebuild_owed(old_end).unwrap();
    reader.in_place_room(old_end, 0).unwrap();
    let segment = sealed
        .registry
        .begin_journal_segment_prune(old_end)
        .unwrap()
        .expect("the first hold selects the old segment");
    reader.read_hold_rows(&segment).unwrap();
    assert!(
        sealed.registry.delete_pruned_segment_rows(&segment).unwrap(),
        "the setup: the old segment has rows of more records than one hold takes"
    );
    assert!(
        the_wal_resets(&checkpointer, &database),
        "the reader is open after its reads and the WAL did not reset: a read did not end"
    );

    // The control: a read that is open on another connection.
    let open_read = open_registry_database_read_only(&database).unwrap();
    let mut statement = open_read.prepare("SELECT sequence FROM journal_event_index").unwrap();
    let mut rows = statement.query([]).unwrap();
    assert!(rows.next().unwrap().is_some(), "the setup: the open read has a row");
    reader.read_hold_rows(&segment).unwrap();
    sealed.registry.delete_pruned_segment_rows(&segment).unwrap();
    assert!(
        !the_wal_resets(&checkpointer, &database),
        "the control: the WAL reset with a read open, so this test proves nothing"
    );
    drop(rows);
    drop(statement);
    drop(open_read);
    assert!(the_wal_resets(&checkpointer, &database), "the WAL resets when the open read ended");

    drop(reader);
    drop(checkpointer);
    sealed.close();
}
