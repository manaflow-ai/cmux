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
        let inserted = put_exit_snapshot_in(&tx, terminal_id, generation, blob, None)?;
        tx.commit()?;
        Ok(inserted)
    }

    /// Store the archives of terminals a close is about to stop (ARCHIVE-1)
    /// in one transaction: each one's screen as its exit snapshot and the
    /// program the close stops. Best effort, like the exit snapshot.
    pub(crate) fn put_terminal_archives(
        &mut self,
        archives: &[crate::mux::TerminalArchive],
    ) -> anyhow::Result<()> {
        if archives.is_empty() {
            return Ok(());
        }
        let now = unix_epoch_ms()?;
        let tx = self.connection.transaction()?;
        for archive in archives {
            if let Some((blob, covered)) = archive.screen.as_ref() {
                put_exit_snapshot_in(
                    &tx,
                    &archive.terminal_id,
                    &archive.generation,
                    blob,
                    Some(*covered),
                )?;
            }
            terminal_archive_store::record_stop(
                &tx,
                &archive.terminal_id,
                &archive.generation,
                archive.stopped.as_deref(),
                now,
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// The journaled output offset of terminal `terminal_id`'s incarnation
    /// `generation` (0: none journaled).
    pub(crate) fn terminal_journal_offset(
        &self,
        terminal_id: &str,
        generation: &str,
    ) -> anyhow::Result<u64> {
        journal_offset(&self.connection, terminal_id, generation)
    }
}

fn journal_offset(
    connection: &Connection,
    terminal_id: &str,
    generation: &str,
) -> anyhow::Result<u64> {
    connection
        .query_row(
            "SELECT next_offset FROM journal_terminal_streams
             WHERE terminal_id = ?1 AND generation = ?2",
            params![terminal_id, generation],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .map(u64::try_from)
        .transpose()
        .context("terminal journal offset is negative")
        .map(Option::unwrap_or_default)
}

/// [`WorkspaceRegistry::put_terminal_exit_snapshot`] inside `tx`.
/// `covered` is the output offset read with the capture of a terminal that
/// still runs (archive on close); `None` reads it now (the process ended,
/// so no output follows the capture).
fn put_exit_snapshot_in(
    tx: &Transaction<'_>,
    terminal_id: &str,
    generation: &str,
    blob: &JournalContentBlob,
    covered: Option<u64>,
) -> anyhow::Result<bool> {
    let covered_through = match covered {
        Some(covered) => covered,
        None => journal_offset(tx, terminal_id, generation)?,
    };
    if covered_through == 0 {
        // The generation journaled no output; there is nothing for the
        // snapshot to cover and record reads stay exact without it.
        return Ok(false);
    }
    let now = unix_epoch_ms()?;
    insert_journal_content_blob(tx, blob, now)?;
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
    Ok(inserted > 0)
}
