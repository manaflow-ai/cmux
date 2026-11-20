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

use std::sync::Arc;
use std::sync::mpsc::sync_channel;
use std::time::{Duration, Instant};

use super::*;
use crate::journal_ingress::JournalIngressSender;
use crate::workspace_registry::new_uuid_v4;
use crate::workspace_registry::session_journal::tests::late_subject_rows::{
    DUE_NUMBER, PERIOD, file_state, fixture_subjects, lose_rows, ms, records, stopped_file_problem,
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

/// The stop's write runs when the journal's writer ended. Each other writer
/// of the registry can still append after it: the registry stays open until
/// the session is free. So the last point of a run is the release of the
/// session, not the stop's write: a journal row that comes between the 2
/// gets its subject rows, and the store ends at 15, before the next owner
/// can open it.
#[test]
fn a_journal_row_after_the_stops_write_gets_its_subject_rows_before_the_session_is_free() {
    let label = "stop-late-row";
    let root =
        std::env::temp_dir().join(format!("cmux-late-subject-rows-{label}-{}", new_uuid_v4()));
    let mux = open_persistent_test_mux(label, &root);
    mux.stop_journal_maintenance();
    let database = {
        let registry = mux.workspace_registry.lock().unwrap();
        registry.append_journal_records_for_test(&records(&[fixture_subjects(0)]));
        registry.session_journal_database_path().unwrap()
    };
    mux.shutdown();
    let at_the_stop = stopped_file_problem(&database);
    // 2 journal rows after the stop's write, each in a commit of its own.
    {
        let registry = mux.workspace_registry.lock().unwrap();
        for row in 1..=2 {
            registry.append_journal_records_for_test(&records(&[fixture_subjects(row)]));
        }
    }
    let after_the_late_rows = stopped_file_problem(&database);
    mux.release_ownership(&root.join("no-socket"));
    let at_the_release = stopped_file_problem(&database);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    // The 2 controls: the stop's write left no problem, and the late rows
    // left one (so the row below is not green with no late row).
    assert!(at_the_stop.is_none(), "after the stop and before a late row: {at_the_stop:?}");
    assert!(
        after_the_late_rows.is_some(),
        "2 journal rows after the stop's write left the file as a stop leaves it"
    );
    assert!(
        at_the_release.is_none(),
        "after 2 journal rows that came after the stop's write, and the release of the \
         session: {at_the_release:?}"
    );
}

/// A journal writer that does not end in the stop's time can still append,
/// and it has the registry's connection while it does. The stop writes no
/// subject rows then. The release of the session writes none too, and it
/// does not wait for the connection: the store stays at 16 with its rows
/// due, and a build that does not know that number refuses it until this
/// build opens the session again.
#[test]
fn the_release_of_the_session_writes_nothing_when_the_journals_writer_did_not_end() {
    let label = "stop-writer-did-not-end";
    let root =
        std::env::temp_dir().join(format!("cmux-late-subject-rows-{label}-{}", new_uuid_v4()));
    let mux = open_persistent_test_mux(label, &root);
    mux.stop_journal_maintenance();
    let database = {
        let registry = mux.workspace_registry.lock().unwrap();
        registry.append_journal_records_for_test(&records(&[fixture_subjects(0)]));
        registry.session_journal_database_path().unwrap()
    };
    // The test's writer ends when `writer` is dropped, after the release.
    let writer = mux.journal_ingress.put_a_writer_that_does_not_end_for_test().unwrap();
    mux.shutdown();
    let head = mux.workspace_registry.lock().unwrap().session_journal_head().unwrap();
    let at_the_stop = file_state(&database, head);
    mux.release_ownership(&root.join("no-socket"));
    let at_the_release = file_state(&database, head);
    drop(writer);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    // The control: the stop made no write, so the row below is not green
    // with nothing due.
    assert!(
        at_the_stop.1 > 0 && at_the_stop.2 == DUE_NUMBER,
        "after a stop whose journal writer did not end (the mark, the journal rows after it, \
         the number): {at_the_stop:?}"
    );
    assert_eq!(
        at_the_release, at_the_stop,
        "the release of the session after a stop whose journal writer did not end: (the mark, \
         the journal rows after it, the number) after the release, and before it"
    );
}

/// A stop that runs on the journal writer's own thread cannot wait for that
/// thread: another thread takes the thread's end, and the close comes back
/// at once. The writer has not ended then. For the release of the session it
/// has not ended until its thread ended, so the release writes nothing
/// before that.
#[test]
fn a_journal_writer_that_closes_itself_has_not_ended_until_its_thread_ended() {
    let (ingress, _receivers) = JournalIngressSender::new(true);
    let ingress = Arc::new(ingress);
    let (seen, seen_in_the_writer) = sync_channel(1);
    let (release, released) = sync_channel::<()>(1);
    let writer = ingress.clone();
    ingress
        .spawn_writer("late-subject-rows-writer-closes-itself", move || {
            let closed = writer.close_and_join().is_ok();
            let _ = seen.send((closed, writer.writer_ended()));
            // The thread runs on until the test drops `release`.
            let _ = released.recv();
        })
        .unwrap();
    let in_the_writer = seen_in_the_writer.recv_timeout(Duration::from_secs(10)).unwrap();
    let while_the_thread_runs = ingress.writer_ended();
    drop(release);
    // A second close waits for the result of the thread's end.
    let joined = ingress.close_and_join().is_ok();
    assert_eq!(
        (in_the_writer, while_the_thread_runs, joined, ingress.writer_ended()),
        ((true, false), false, true, true),
        "a journal writer that closes itself: (its own close came back with no error, the \
         writer ended) on the writer's thread; the writer ended while its thread runs on; a \
         second close after the thread's end came back with no error; the writer ended after it"
    );
}
