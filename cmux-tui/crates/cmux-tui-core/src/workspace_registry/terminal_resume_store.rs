//! Durable per-terminal resume commands (`resume-command`).
//!
//! A resume command is the line a person chose for one terminal: when the
//! daemon respawns that terminal (after an owner restart, an update or a
//! reboot) it types the line on the new prompt without a newline, so the
//! person decides whether it runs (`mux::terminal_respawn::prefill`). One row
//! in `terminal_resume_command` per terminal; no row means none is set.
//!
//! The table is additive and has no foreign key, like `terminal_keep`, so the
//! schema version does not change and an older binary still opens this
//! registry (it ignores the table). Rows of tombstoned terminals are inert
//! and removed by [`WorkspaceRegistry::prune_terminal_resume_commands`].

use rusqlite::{OptionalExtension, Transaction, params};

use super::{TerminalLifecycle, WorkspaceRegistry, read_terminal, validate_terminal_identity};

/// The longest resume command stored, in bytes.
pub const RESUME_COMMAND_CAP: usize = 4096;

pub(super) fn create_terminal_resume_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_resume_command (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           command TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// `command` trimmed, when it is one line of 1 to [`RESUME_COMMAND_CAP`]
/// bytes without control characters (a newline or carriage return would
/// run part of it on its own when it is typed).
pub fn validated_resume_command(command: &str) -> anyhow::Result<String> {
    let command = command.trim();
    anyhow::ensure!(!command.is_empty(), "bad request: resume command is empty");
    anyhow::ensure!(
        command.len() <= RESUME_COMMAND_CAP,
        "bad request: resume command is longer than {RESUME_COMMAND_CAP} bytes"
    );
    anyhow::ensure!(
        !command.chars().any(char::is_control),
        "bad request: resume command must be one line without control characters"
    );
    Ok(command.to_string())
}

impl WorkspaceRegistry {
    /// Set (`Some`) or clear (`None`) the resume command of a live terminal
    /// and return the stored command. Tombstoned or unknown terminals are
    /// rejected so a stale request cannot leave an orphan row behind.
    pub fn set_terminal_resume_command(
        &mut self,
        terminal_id: &str,
        command: Option<&str>,
    ) -> anyhow::Result<Option<String>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        let command = command.map(validated_resume_command).transpose()?;
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let terminal = read_terminal(&tx, terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal_not_found"))?;
        anyhow::ensure!(terminal.lifecycle != TerminalLifecycle::Tombstoned, "terminal_not_found");
        match command.as_deref() {
            Some(command) => tx.execute(
                "INSERT INTO terminal_resume_command(terminal_id, command) VALUES(?1, ?2)
                 ON CONFLICT(terminal_id) DO UPDATE SET command = excluded.command",
                params![terminal_id, command],
            )?,
            None => tx.execute(
                "DELETE FROM terminal_resume_command WHERE terminal_id = ?1",
                [terminal_id],
            )?,
        };
        tx.commit()?;
        Ok(command)
    }

    /// The resume command of one terminal, if one is set.
    pub fn terminal_resume_command(&self, terminal_id: &str) -> anyhow::Result<Option<String>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        Ok(self
            .connection
            .get()
            .query_row(
                "SELECT command FROM terminal_resume_command WHERE terminal_id = ?1",
                [terminal_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    }

    /// Delete resume commands whose terminal is tombstoned or no longer
    /// registered. Returns the number of rows removed.
    pub fn prune_terminal_resume_commands(&mut self) -> anyhow::Result<usize> {
        Ok(self.connection.get().execute(
            "DELETE FROM terminal_resume_command
             WHERE terminal_id NOT IN (
               SELECT terminal_id FROM terminal_hosts WHERE lifecycle != 'tombstoned'
             )",
            [],
        )?)
    }
}
