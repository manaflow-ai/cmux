//! A stop writes the subject rows of the journal's tail.
//!
//! The subject rows of the newest journal rows are written by a later commit
//! (see `workspace_registry/session_journal/tests/late_subject_rows.rs` for
//! the rule and for the file of a crash). A stop is the last point of a run:
//! after it no journal row is after the mark, the subject table has each row
//! that a write at record time gives, and the store's schema number is 15, so
//! a build that does not know the rule opens the store.
//!
//! The tests run a real `Mux` on an on-disk registry. Each prints a
//! `late_subject_rows` line with the time of the stop: a measurement for a
//! reader, no test asserts on it.

use std::time::Instant;

use super::*;
use crate::workspace_registry::new_uuid_v4;
use crate::workspace_registry::session_journal::tests::late_subject_rows::{
    DUE_NUMBER, PERIOD, fixture_subjects, lose_rows, ms, records, stopped_file_problem,
};

/// The journal rows before the tail, and the tail: one row less than a
/// period (99 journal rows for a period of 100).
const ROWS_BEFORE: u64 = 500;
const TAIL: u64 = PERIOD - 1;

/// Stops a `Mux` whose store has `tail` journal rows with no subject rows
/// yet, and returns what is wrong with the store's file after the stop.
fn stop_with_a_tail(label: &str, tail: u64) -> Option<String> {
    let root =
        std::env::temp_dir().join(format!("cmux-late-subject-rows-{label}-{}", new_uuid_v4()));
    let mux = open_persistent_test_mux(label, &root);
    mux.stop_journal_maintenance();
    let (database, head, sealed) = {
        let registry = mux.workspace_registry.lock().unwrap();
        if tail > 0 {
            let rows = (0..ROWS_BEFORE + tail).map(fixture_subjects).collect::<Vec<_>>();
            for batch in rows.chunks(100) {
                registry.append_journal_records_for_test(&records(batch));
            }
        }
        (
            registry.session_journal_database_path().unwrap(),
            registry.session_journal_head().unwrap(),
            registry.journal_segments_end().unwrap(),
        )
    };
    // With no tail the test does not touch the file: the control.
    let due =
        if tail > 0 { head - lose_rows(&database, head, sealed, tail, DUE_NUMBER) } else { 0 };
    let started = Instant::now();
    mux.shutdown();
    let stop = started.elapsed();
    println!(
        "late_subject_rows: a stop of a store of {head} journal rows, the subject rows of {due} \
         of them made due by the test: {:.3} ms",
        ms(stop)
    );
    let problem = stopped_file_problem(&database);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    problem
}

#[test]
fn a_stop_writes_the_subject_rows_of_the_journals_tail_and_puts_the_15_back() {
    let problem = stop_with_a_tail("stop-tail", TAIL);
    assert!(problem.is_none(), "a stop with a tail of {TAIL} journal rows: {problem:?}");
}

#[test]
fn a_store_that_is_opened_and_stopped_with_no_new_journal_row_ends_at_15() {
    let problem = stop_with_a_tail("stop-plain", 0);
    assert!(problem.is_none(), "a stop with no journal row from the test: {problem:?}");
}
