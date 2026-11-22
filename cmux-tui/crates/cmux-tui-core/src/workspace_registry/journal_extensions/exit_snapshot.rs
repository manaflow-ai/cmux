//! The per-terminal exit snapshot store (moved out of journal_extensions.rs).

use super::*;

impl WorkspaceRegistry {
    /// Store the exit snapshot for one terminal generation, best-effort and
    /// idempotent. One row exists per terminal: within a generation the exit
    /// latch is first-writer-wins (a replayed store is a no-op); a later
    /// generation of the same terminal (the next loss after an L2 respawn)
    /// replaces it. Returns whether a snapshot row was written.
    pub(crate) fn put_terminal_exit_snapshot(
        &mut self,
        terminal_id: &str,
        generation: &str,
        blob: &JournalContentBlob,
    ) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let covered_through = tx
            .query_row(
                "SELECT next_offset FROM journal_terminal_streams
                 WHERE terminal_id = ?1 AND generation = ?2",
                params![terminal_id, generation],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map(u64::try_from)
            .transpose()
            .context("terminal journal offset is negative")?
            .unwrap_or(0);
        if covered_through == 0 {
            // The generation journaled no output; there is nothing for the
            // snapshot to cover and record reads stay exact without it.
            return Ok(false);
        }
        let now = unix_epoch_ms()?;
        insert_journal_content_blob(&tx, blob, now)?;
        // Rows are immutable (a trigger rejects UPDATE): a later generation's
        // snapshot (the next loss after an L2 respawn) replaces the earlier
        // generation's row; within one generation the first writer wins.
        tx.execute(
            "DELETE FROM terminal_exit_snapshots WHERE terminal_id = ?1 AND generation != ?2",
            params![terminal_id, generation],
        )?;
        let inserted = tx.execute(
            "INSERT OR IGNORE INTO terminal_exit_snapshots(
               terminal_id, generation, content_id, format, cols, rows,
               covered_through, created_at_ms
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                terminal_id,
                generation,
                blob.reference.content_id,
                blob.reference.format,
                i64::from(blob.reference.cols.max(1)),
                i64::from(blob.reference.rows.max(1)),
                i64::try_from(covered_through)?,
                i64::try_from(now)?,
            ],
        )?;
        tx.commit()?;
        Ok(inserted > 0)
    }
}
