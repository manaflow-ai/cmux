//! What a reader gets from a segment that retention has deleted a part of.
//!
//! The retention pass moves the floor to the end of a segment first, then
//! deletes the rows of that segment's records in more than one transaction,
//! and deletes the segment row with its content last. Between two of those
//! transactions (and after a kill there) the segment is at or below the
//! floor, its content is whole, and its index rows and kept reducer rows
//! are there for a part of its records only. A reader that takes those rows
//! for the segment gives a part of an answer and no error.
//!
//! Each test here makes that state on a real registry file: an old segment
//! with [`OLD_RECORDS`] agent records of one terminal, a newer segment with
//! [`NEW_RECORDS`] more, the floor at the end of the old segment, and the
//! rows of the first half of the old segment's records deleted.

use std::path::PathBuf;

use rusqlite::params;
use serde_json::json;

use super::*;
use crate::journal_reducers::AgentRoster;
use crate::workspace_registry::session_journal::kind_read_tests::TestJournalRecord;
use crate::workspace_registry::{
    JournalProducer, JournalSubject, SessionJournalReader, SessionJournalRecord, new_uuid_v4,
};

/// Agent records of the old segment, and of the newer one.
const OLD_RECORDS: usize = 8;
pub(super) const NEW_RECORDS: usize = 4;
const TERMINAL: &str = "term_00000000000040008000000000000001";

pub(super) fn subject() -> JournalSubject {
    JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }
}

fn agent_record(turn: usize) -> TestJournalRecord {
    TestJournalRecord {
        kind: "agent.turn.started".into(),
        producer: JournalProducer {
            kind: "agent_adapter".into(),
            id: crate::AGENT_HOOK_PRODUCER_ID.into(),
        },
        subjects: vec![subject()],
        payload: json!({ "turn": turn }),
    }
}

/// The registry of the module doc before the delete, and what it holds.
pub(super) struct Sealed {
    pub(super) root: PathBuf,
    pub(super) registry: WorkspaceRegistry,
    /// The agent records of the old segment, and of the newer one.
    pub(super) old: Vec<u64>,
    pub(super) new: Vec<u64>,
    /// The end of the old segment.
    pub(super) old_end: u64,
}

fn sealed(label: &str) -> Sealed {
    sealed_with(label, OLD_RECORDS)
}

/// [`Sealed`] with `old_records` agent records in the old segment.
pub(super) fn sealed_with(label: &str, old_records: usize) -> Sealed {
    let root = std::env::temp_dir()
        .join(format!("cmux-part-deleted-{label}-{}", new_uuid_v4().replace('-', "")));
    let mut registry = WorkspaceRegistry::open(&root, label).unwrap();
    let old = registry
        .append_journal_records_for_test(&(0..old_records).map(agent_record).collect::<Vec<_>>());
    registry.seal_journal_for_test("old");
    let new = registry.append_journal_records_for_test(
        &(old_records..old_records + NEW_RECORDS).map(agent_record).collect::<Vec<_>>(),
    );
    registry.seal_journal_for_test("new");
    let segments = registry.journal_segments().unwrap();
    let old_segment = segments
        .iter()
        .find(|segment| segment.start_sequence <= old[0] && old[0] <= segment.end_sequence)
        .expect("the setup: a segment holds the first record");
    let old_end = old_segment.end_sequence;
    assert!(
        old[old_records - 1] <= old_end && old_end < new[0],
        "the setup: one segment holds the old records and none of the new ones: \
         {old:?} {new:?} {segments:?}"
    );
    assert!(
        segments.iter().any(|segment| segment.end_sequence >= new[NEW_RECORDS - 1]),
        "the setup: the new records are sealed too: {segments:?}"
    );
    Sealed { root, registry, old, new, old_end }
}

impl Sealed {
    /// The state between two transactions of the retention pass: the floor
    /// is at the end of the old segment, and each row of a record at or
    /// below `through` is gone. The segment row and its content stay.
    fn delete_rows_through(&self, through: u64) {
        let db = self.registry.connection.get();
        let tx = db.unchecked_transaction().unwrap();
        note_journal_pruned_through(&tx, self.old_end).unwrap();
        // A build before the delete in parts refuses each delete of the
        // subject index by trigger; from that build on the floor permits it.
        tx.execute_batch("DROP TRIGGER IF EXISTS journal_subject_index_reject_delete;").unwrap();
        let through = i64::try_from(through).unwrap();
        for table in
            ["journal_segment_reducer_records", "journal_subject_index", "journal_event_index"]
        {
            tx.execute(&format!("DELETE FROM {table} WHERE sequence <= ?1"), [through]).unwrap();
        }
        tx.execute("DELETE FROM journal_ingress_receipts WHERE journal_sequence <= ?1", [through])
            .unwrap();
        tx.commit().unwrap();
        let old_end = i64::try_from(self.old_end).unwrap();
        let later_rows = |table: &str| -> i64 {
            db.query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE sequence > ?1 AND sequence <= ?2"),
                params![through, old_end],
                |row| row.get(0),
            )
            .unwrap()
        };
        assert!(
            later_rows("journal_segment_reducer_records") > 0,
            "the setup: kept reducer rows of the later half are there"
        );
        assert!(
            later_rows("journal_subject_index") > 0,
            "the setup: subject rows of the later half are there"
        );
        let segment_rows: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM journal_segments WHERE end_sequence = ?1",
                [old_end],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(segment_rows, 1, "the setup: the segment row is there");
    }

    pub(super) fn reader(&self) -> SessionJournalReader {
        SessionJournalReader::open(&self.registry.session_journal_database_path().unwrap()).unwrap()
    }

    pub(super) fn close(self) {
        drop(self.registry);
        std::fs::remove_dir_all(self.root).unwrap();
    }
}

/// The agent records a kind-scoped read from the first record gives.
fn agent_sequences(
    read: impl Fn(u64, u64) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)>,
    head: u64,
) -> Vec<u64> {
    let (mut cursor, mut sequences) = (0, Vec::new());
    while cursor < head {
        let (page, reached) = read(cursor, head).expect("the kind read answers");
        assert!(reached > cursor, "each page makes progress");
        sequences.extend(
            page.iter()
                .filter(|record| record.kind == "agent.turn.started")
                .map(|record| record.sequence),
        );
        cursor = reached;
    }
    sequences
}

/// The subject page reads the subject index. Rows of a part of a segment's
/// records gave a page with the later records of the segment and not the
/// earlier ones, with no error and no gap. The page starts above the floor:
/// the records at or below it are gone for this reader, all of them.
#[test]
fn a_subject_page_has_no_record_of_a_segment_that_retention_deleted_a_part_of() {
    let sealed = sealed("subject-page");
    let reader = sealed.reader();
    let page = |after: u64| -> Vec<u64> {
        reader
            .after_subjects(after, 64, &[subject()])
            .expect("the subject page answers")
            .records
            .iter()
            .map(|record| record.sequence)
            .collect()
    };
    let whole = sealed.old.iter().chain(&sealed.new).copied().collect::<Vec<_>>();
    assert_eq!(page(0), whole, "the setup: the page has each record before the delete");

    sealed.delete_rows_through(sealed.old[OLD_RECORDS / 2 - 1]);

    assert_eq!(
        page(0),
        sealed.new,
        "a page from the first record has the records above the floor {} and no record of the \
         segment below it (the old records are {:?})",
        sealed.old_end,
        sealed.old
    );
    assert_eq!(page(sealed.new[0]), sealed.new[1..], "a cursor above the floor reads as before");
    drop(reader);
    sealed.close();
}

/// The kind-scoped read takes a segment's kept reducer rows when each kind
/// it accepts has a row there. Kept rows of a part of the records gave a
/// part of the segment's records. A segment that ends at or below the floor
/// is decoded from its content, which goes last and whole.
#[test]
fn a_kind_read_decodes_a_segment_that_retention_deleted_a_part_of() {
    let sealed = sealed("kind-read");
    let head = sealed.registry.session_journal_head().unwrap();
    let from_registry = |sealed: &Sealed| {
        agent_sequences(
            |after, through| {
                sealed.registry.session_journal_kinds_after(
                    after,
                    through,
                    AgentRoster::folds_kind,
                    512,
                )
            },
            head,
        )
    };
    let whole = sealed.old.iter().chain(&sealed.new).copied().collect::<Vec<_>>();
    assert_eq!(from_registry(&sealed), whole, "the setup: the read has each record");

    sealed.delete_rows_through(sealed.old[OLD_RECORDS / 2 - 1]);

    assert_eq!(
        from_registry(&sealed),
        whole,
        "the registry's read has each agent record of the segment at the floor {}",
        sealed.old_end
    );
    let reader = sealed.reader();
    assert_eq!(
        agent_sequences(
            |after, through| reader.kinds_after(after, through, AgentRoster::folds_kind, 512),
            head,
        ),
        whole,
        "the reader connection's read has each agent record of that segment"
    );
    drop(reader);
    sealed.close();
}
