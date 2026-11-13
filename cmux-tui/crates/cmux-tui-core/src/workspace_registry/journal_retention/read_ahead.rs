//! What the retention pass reads of the registry file BEFORE a hold of the
//! registry lock, on a connection of its own.
//!
//! A row hold deletes each row of its records through each index of its
//! table: a seek into each B-tree for each row, and each page that the
//! registry connection does not have is a read of the file inside the hold.
//! On a generated registry of a long-lived session a hold read about 10,500
//! pages that way (2026-11-13: 85 % of a hold at 2 GB and 93 % at 13 GB was
//! that seek; a rename waited up to 21 s behind one). The count of the
//! records at or below the floor is a row of each sealed segment, and was
//! 22 s under the lock at 13 GB.
//!
//! A page cache of SQLite is of one connection, so this connection cannot
//! give its pages to the registry connection. It reads the same pages of
//! the same file, with no lock held: the hold then gets them from the file
//! cache of the system, and waits for no disk while a request waits for the
//! lock. What the hold writes is not less.
//!
//! The reads change no answer: the hold asks for its rows again under the
//! lock ([`hold_through`]).
//!
//! Each read is one statement with no transaction around it, so its read
//! transaction ends with the statement. A read that stayed open would keep
//! the WAL syncer's checkpoint from each frame after it, and the WAL from
//! its reset. [`RetentionReadAhead::ended`] refuses to go on in that state.

use std::path::Path;
use std::time::Duration;

use anyhow::Context as _;
use rusqlite::Connection;

use super::{PrunedSegment, hold_through};
use crate::workspace_registry::open_registry_database_read_only;
use crate::workspace_registry::output_cleanup::{
    journal_in_place_room_on, journal_rebuild_owed_on,
};

/// For each table of `PRUNED_ROW_TABLES`, in its order: the read of the
/// rows at or below a record (`?1`), through the table and EACH of its
/// indexes, as the delete of those rows goes. A column that can be long is
/// read to its end (its overflow pages). A partial index has an entry only
/// for a row with a value there; a row with none makes no seek, as in the
/// delete. A test compares these plans with the indexes of the schema, so
/// a new index of one of the tables fails until it is read here.
pub(super) const HOLD_ROW_READS: [(&str, &str); 4] = [
    (
        "journal_segment_reducer_records",
        "SELECT COALESCE(SUM(LENGTH(hold.record_json)), 0)
         FROM journal_segment_reducer_records AS hold
         WHERE hold.sequence <= ?1",
    ),
    (
        "journal_subject_index",
        "SELECT COALESCE(SUM(EXISTS(
           SELECT 1 FROM journal_subject_index AS entry
             INDEXED BY journal_subject_index_by_subject_sequence
           WHERE entry.kind = hold.kind AND entry.id = hold.id
             AND entry.sequence = hold.sequence)), 0)
         FROM journal_subject_index AS hold
         WHERE hold.sequence <= ?1",
    ),
    (
        "journal_event_index",
        "SELECT COALESCE(SUM(
           EXISTS(SELECT 1 FROM journal_event_index AS entry
                  WHERE entry.event_id = hold.event_id)
           + EXISTS(SELECT 1 FROM journal_event_index AS entry
                      INDEXED BY journal_event_index_by_causal_hook
                    WHERE entry.causal_hook_id = hold.causal_hook_id
                      AND entry.sequence = hold.sequence)
           + EXISTS(SELECT 1 FROM journal_event_index AS entry
                      INDEXED BY journal_event_index_by_resource_revision
                    WHERE entry.resource_revision = hold.resource_revision)), 0)
         FROM journal_event_index AS hold
         WHERE hold.sequence <= ?1",
    ),
    (
        "journal_ingress_receipts",
        "SELECT COALESCE(SUM(
           LENGTH(hold.result_json)
           + EXISTS(SELECT 1 FROM journal_ingress_receipts AS entry
                    WHERE entry.producer_id = hold.producer_id
                      AND entry.origin = hold.origin
                      AND entry.idempotency_key = hold.idempotency_key)
           + EXISTS(SELECT 1 FROM journal_ingress_receipts AS entry
                    WHERE entry.event_id = hold.event_id)), 0)
         FROM journal_ingress_receipts AS hold
         WHERE hold.journal_sequence <= ?1",
    ),
];

/// A read-only connection to the registry file for one retention pass, on
/// the maintenance thread. It shares nothing with the registry connection
/// or its mutex.
///
/// Its three reads are never inlined: a sample of the daemon's stacks then
/// names a read apart from the hold after it
/// (`scripts/measure/registry-migration-proof.py`, the in-place-stacks arm).
pub(crate) struct RetentionReadAhead {
    connection: Connection,
}

impl RetentionReadAhead {
    pub(crate) fn open(database_path: &Path) -> anyhow::Result<Self> {
        let connection = open_registry_database_read_only(database_path)
            .with_context(|| format!("open the retention reader of {}", database_path.display()))?;
        connection.busy_timeout(Duration::from_secs(5))?;
        Ok(Self { connection })
    }

    /// Reads the rows of the next row hold of `segment`
    /// (`WorkspaceRegistry::delete_pruned_segment_rows`) as that hold will:
    /// the hold's last record, then each row at or below it through each
    /// index of its table. The caller holds no lock.
    #[inline(never)]
    pub(crate) fn read_hold_rows(&self, segment: &PrunedSegment) -> anyhow::Result<()> {
        let through = hold_through(&self.connection, i64::try_from(segment.end)?)?;
        for (_, read) in HOLD_ROW_READS {
            self.connection.prepare_cached(read)?.query_row([through], |_| Ok(()))?;
        }
        self.ended()?;
        #[cfg(test)]
        super::retention_step_for_test(super::RetentionStep::ReadBeforeHold { through });
        Ok(())
    }

    /// `WorkspaceRegistry::journal_rebuild_owed`, read here: a row of each
    /// sealed segment at or below `floor`. The caller holds no lock.
    #[inline(never)]
    pub(crate) fn rebuild_owed(&self, floor: u64) -> anyhow::Result<bool> {
        let owed = journal_rebuild_owed_on(&self.connection, floor)?;
        self.ended()?;
        Ok(owed)
    }

    /// `WorkspaceRegistry::journal_in_place_room`, read here, as
    /// [`Self::rebuild_owed`].
    #[inline(never)]
    pub(crate) fn in_place_room(&self, floor: u64, deleted: u64) -> anyhow::Result<Option<u64>> {
        let room = journal_in_place_room_on(&self.connection, floor, deleted)?;
        self.ended()?;
        Ok(room)
    }

    /// Fails when a read of this connection is still open: no statement of
    /// it is in a step, and it is in no transaction. The pass takes no hold
    /// after a read that did not end (see the module doc).
    fn ended(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.connection.is_autocommit() && !self.connection.is_busy(),
            "a read of the retention reader did not end: it would keep the WAL from its reset"
        );
        Ok(())
    }
}
