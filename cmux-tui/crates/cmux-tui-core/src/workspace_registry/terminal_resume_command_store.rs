//! Durable per-terminal resume commands (`terminal-resume-command-v1`).
//!
//! A person sets a command on a terminal (Set Resume Command… in
//! cmux-next); the daemon runs it in the terminal's new shell when the
//! terminal restarts: a respawn after its host was lost, or a manual
//! `restart-tab` (`mux/terminal_respawn/prefill.rs`). A row in
//! `terminal_resume_commands` is the command; no row means none.
//!
//! The table is additive and has no foreign key, like `terminal_keep`, so
//! the schema version does not change and an older binary still opens this
//! registry (it ignores the table). Rows of tombstoned or unknown terminals
//! are inert and pruned with the keep rows.

use std::collections::HashMap;

use rusqlite::{Connection, Transaction, params};

use super::{TerminalLifecycle, WorkspaceRegistry, read_terminal, validate_terminal_identity};

/// The longest resume command, in bytes.
pub(crate) const MAX_RESUME_COMMAND_BYTES: usize = 4096;

pub(super) fn create_terminal_resume_command_schema(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_resume_commands (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           command TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// A command to store: trimmed, `None` when empty (a clear). A control
/// character is refused, since a newline would run part of the command.
pub(crate) fn normalized_resume_command(command: Option<&str>) -> anyhow::Result<Option<String>> {
    let Some(command) = command.map(str::trim).filter(|command| !command.is_empty()) else {
        return Ok(None);
    };
    anyhow::ensure!(
        !command.chars().any(char::is_control),
        "bad request: a resume command is one line without control characters"
    );
    anyhow::ensure!(
        command.len() <= MAX_RESUME_COMMAND_BYTES,
        "bad request: a resume command is at most {MAX_RESUME_COMMAND_BYTES} bytes"
    );
    Ok(Some(command.to_string()))
}

/// The resume command of every live terminal, by public terminal id
/// (`term_...`), for the tree's `resume_command` tab field.
pub(crate) fn read_resume_commands(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, String>> {
    let mut statement = connection.prepare(
        "SELECT terminal.public_id, resume.command
         FROM terminal_resume_commands AS resume
         JOIN resource_terminals AS terminal ON terminal.terminal_id = resume.terminal_id
         WHERE terminal.deleted_revision IS NULL",
    )?;
    let rows = statement.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get(1)?)))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

impl WorkspaceRegistry {
    /// Set (`Some`) or clear (`None`) the resume command of a live terminal.
    /// Tombstoned or unknown terminals are rejected so a stale request cannot
    /// leave an orphan row behind. Returns the stored command.
    pub fn set_terminal_resume_command(
        &mut self,
        terminal_id: &str,
        command: Option<&str>,
    ) -> anyhow::Result<Option<String>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        let command = normalized_resume_command(command)?;
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let terminal = read_terminal(&tx, terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal_not_found"))?;
        anyhow::ensure!(terminal.lifecycle != TerminalLifecycle::Tombstoned, "terminal_not_found");
        match &command {
            Some(command) => tx.execute(
                "INSERT INTO terminal_resume_commands(terminal_id, command) VALUES(?1, ?2)
                 ON CONFLICT(terminal_id) DO UPDATE SET command = excluded.command",
                params![terminal_id, command],
            )?,
            None => tx.execute(
                "DELETE FROM terminal_resume_commands WHERE terminal_id = ?1",
                [terminal_id],
            )?,
        };
        tx.commit()?;
        Ok(command)
    }

    /// The resume command of one terminal, if set.
    pub fn terminal_resume_command(&self, terminal_id: &str) -> anyhow::Result<Option<String>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        let db = self.connection.get();
        let mut statement =
            db.prepare("SELECT command FROM terminal_resume_commands WHERE terminal_id = ?1")?;
        let mut rows = statement.query([terminal_id])?;
        Ok(match rows.next()? {
            Some(row) => Some(row.get(0)?),
            None => None,
        })
    }

    /// Delete resume commands whose terminal is tombstoned or no longer
    /// registered. Returns the number of rows removed.
    pub fn prune_terminal_resume_commands(&mut self) -> anyhow::Result<usize> {
        Ok(self.connection.get().execute(
            "DELETE FROM terminal_resume_commands
             WHERE terminal_id NOT IN (
               SELECT terminal_id FROM terminal_hosts WHERE lifecycle != 'tombstoned'
             )",
            [],
        )?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_resume_command_is_one_trimmed_line() {
        assert_eq!(normalized_resume_command(None).unwrap(), None);
        assert_eq!(normalized_resume_command(Some("  ")).unwrap(), None, "empty clears");
        assert_eq!(
            normalized_resume_command(Some(" claude --resume abc ")).unwrap().as_deref(),
            Some("claude --resume abc")
        );
        assert!(normalized_resume_command(Some("echo a\nrm b")).is_err());
        assert!(normalized_resume_command(Some("echo \u{1b}[2J")).is_err());
        let long = "a".repeat(MAX_RESUME_COMMAND_BYTES + 1);
        assert!(normalized_resume_command(Some(&long)).is_err());
    }
}
