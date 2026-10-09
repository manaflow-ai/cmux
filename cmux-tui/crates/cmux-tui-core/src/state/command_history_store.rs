//! Terminal command history records (`terminal-command-history-v1`,
//! plans/cmux-next/history.md section 6).
//!
//! Owner: this table, written only through the methods below and only by
//! the daemon's command history worker (mux/command_history.rs), which
//! stores new rows, runs client deletes in queue order (a command queued
//! before a delete never comes back after it) and expires old rows. Request
//! threads read rows and write only the retention value. A command line can
//! hold secrets, so these rows are deletable state, not session journal
//! records: the journal is append-only and archived in sealed segments, so a
//! record there can never be removed.
//!
//! Rows expire `retention_days` after the command started (default 30,
//! persisted in `meta`). A list never returns an expired row; the worker
//! deletes them when it starts (daemon start), on every store and retention
//! change, and at the oldest row's expiry time (one deadline, no polling).
//! The registry connection runs with `secure_delete` on, so freed cells are
//! zeroed, and the worker checkpoints the WAL after deletes. Ids are never
//! reused, so a client cursor stays valid across deletes.

use std::time::Duration;

use rusqlite::{OptionalExtension, Transaction, params};

use crate::workspace_registry::{WorkspaceRegistry, meta_value};
use crate::shell_history::FinishedCommand;

/// Days a command record is kept when no client set a retention.
pub(crate) const DEFAULT_COMMAND_RETENTION_DAYS: u32 = 30;
/// Longest accepted retention (10 years).
pub(crate) const MAX_COMMAND_RETENTION_DAYS: u32 = 3650;
/// Most rows one list returns.
pub(crate) const MAX_COMMAND_LIST_LIMIT: usize = 1000;
/// Most ids one delete names.
pub(crate) const MAX_COMMAND_DELETE_IDS: usize = 1000;

const DAY_MS: u64 = 24 * 60 * 60 * 1000;
const RETENTION_KEY: &str = "terminal_command_retention_days";
const DELETIONS_KEY: &str = "terminal_command_deletions";
/// The registry connection's normal busy timeout (`initialize`).
const REGISTRY_BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// One stored command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CommandHistoryRow {
    pub(crate) id: u64,
    pub(crate) terminal_id: String,
    pub(crate) command: Option<String>,
    pub(crate) cwd: Option<String>,
    pub(crate) exit_code: Option<i32>,
    pub(crate) started_at_ms: u64,
    pub(crate) duration_ms: u64,
}

/// What a client delete removes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CommandDeletion {
    Ids(Vec<u64>),
    /// Commands that started at or after this time.
    StartedSince(u64),
    All,
}

/// One list response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CommandHistoryPage {
    /// Ascending by id: the newest `limit` unexpired rows after the cursor.
    pub(crate) commands: Vec<CommandHistoryRow>,
    /// Older unexpired rows after the cursor were left out (more than
    /// `limit`). A client reading after a cursor then has a gap.
    pub(crate) truncated: bool,
    /// Counts client deletes that removed rows (not expiry: a client drops
    /// rows older than `retention_days` itself). A client that saw another
    /// value reads again from the start.
    pub(crate) deletions: u64,
    /// This registry; ids and `deletions` start over in another one.
    pub(crate) registry_id: String,
    pub(crate) retention_days: u32,
}

/// What a store or expiry pass did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CommandExpiry {
    /// Rows the pass deleted.
    pub(crate) deleted: u64,
    /// When the oldest remaining row expires; `None` when no row is left.
    pub(crate) next_ms: Option<u64>,
}

/// Runs on every registry open. Also turns on `secure_delete` for the
/// registry connection, so deleted rows here (and in every other table) are
/// zeroed instead of staying readable in free space.
pub(super) fn create_command_history_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "PRAGMA secure_delete=ON;
         CREATE TABLE IF NOT EXISTS terminal_commands (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           terminal_id TEXT NOT NULL,
           command TEXT,
           cwd TEXT,
           exit_code INTEGER,
           started_at_ms INTEGER NOT NULL CHECK(started_at_ms >= 0),
           duration_ms INTEGER NOT NULL CHECK(duration_ms >= 0)
         );
         CREATE INDEX IF NOT EXISTS terminal_commands_by_start
           ON terminal_commands(started_at_ms);",
    )?;
    Ok(())
}

fn to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn to_u64(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

impl WorkspaceRegistry {
    /// The retention in days ([`DEFAULT_COMMAND_RETENTION_DAYS`] until set).
    pub(crate) fn terminal_command_retention_days(&self) -> anyhow::Result<u32> {
        Ok(meta_value(&self.connection, RETENTION_KEY)?
            .and_then(|value| value.parse::<u32>().ok())
            .filter(|days| (1..=MAX_COMMAND_RETENTION_DAYS).contains(days))
            .unwrap_or(DEFAULT_COMMAND_RETENTION_DAYS))
    }

    /// Stores the retention. Lists hide what it expires at once; the worker
    /// deletes those rows on its next pass.
    pub(crate) fn set_terminal_command_retention_days(&mut self, days: u32) -> anyhow::Result<()> {
        anyhow::ensure!(
            (1..=MAX_COMMAND_RETENTION_DAYS).contains(&days),
            "bad request: retention_days must be 1...{MAX_COMMAND_RETENTION_DAYS}"
        );
        self.connection.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![RETENTION_KEY, days.to_string()],
        )?;
        Ok(())
    }

    /// Stores finished commands of terminals (public id, command) in one
    /// transaction, then expires old rows.
    pub(crate) fn append_terminal_commands(
        &mut self,
        commands: &[(String, FinishedCommand)],
        now_ms: u64,
    ) -> anyhow::Result<CommandExpiry> {
        if !commands.is_empty() {
            let tx = self.connection.transaction()?;
            {
                let mut insert = tx.prepare(
                    "INSERT INTO terminal_commands(
                       terminal_id, command, cwd, exit_code, started_at_ms, duration_ms
                     ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                )?;
                for (terminal_id, command) in commands {
                    insert.execute(params![
                        terminal_id,
                        command.command,
                        command.cwd,
                        command.exit_code,
                        to_i64(command.started_at_ms),
                        to_i64(command.duration_ms),
                    ])?;
                }
            }
            tx.commit()?;
        }
        self.expire_terminal_commands(now_ms)
    }

    /// The newest `limit` unexpired rows with an id above `after_id`,
    /// oldest first. Reads only.
    pub(crate) fn list_terminal_commands(
        &self,
        after_id: Option<u64>,
        limit: usize,
        now_ms: u64,
    ) -> anyhow::Result<CommandHistoryPage> {
        anyhow::ensure!(
            (1..=MAX_COMMAND_LIST_LIMIT).contains(&limit),
            "bad request: limit must be 1...{MAX_COMMAND_LIST_LIMIT}"
        );
        let retention_days = self.terminal_command_retention_days()?;
        let cutoff = expiry_cutoff(retention_days, now_ms);
        let after = to_i64(after_id.unwrap_or(0));
        let mut statement = self.connection.prepare(
            "SELECT id, terminal_id, command, cwd, exit_code, started_at_ms, duration_ms
             FROM (
               SELECT * FROM terminal_commands
               WHERE id > ?1 AND (?3 IS NULL OR started_at_ms > ?3)
               ORDER BY id DESC LIMIT ?2
             )
             ORDER BY id ASC",
        )?;
        // One more than asked, to tell whether older rows were left out.
        let mut commands = statement
            .query_map(params![after, to_i64(limit as u64 + 1), cutoff.map(to_i64)], |row| {
                Ok(CommandHistoryRow {
                    id: to_u64(row.get(0)?),
                    terminal_id: row.get(1)?,
                    command: row.get(2)?,
                    cwd: row.get(3)?,
                    exit_code: row.get(4)?,
                    started_at_ms: to_u64(row.get(5)?),
                    duration_ms: to_u64(row.get(6)?),
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let truncated = commands.len() > limit;
        if truncated {
            commands.remove(0);
        }
        Ok(CommandHistoryPage {
            commands,
            truncated,
            deletions: meta_value(&self.connection, DELETIONS_KEY)?
                .and_then(|value| value.parse().ok())
                .unwrap_or(0),
            registry_id: self.registry_id().to_owned(),
            retention_days,
        })
    }

    /// Runs a client delete; returns how many rows went.
    pub(crate) fn delete_terminal_commands(
        &mut self,
        deletion: &CommandDeletion,
    ) -> anyhow::Result<u64> {
        if let CommandDeletion::Ids(ids) = deletion {
            anyhow::ensure!(
                (1..=MAX_COMMAND_DELETE_IDS).contains(&ids.len()),
                "bad request: ids must name 1...{MAX_COMMAND_DELETE_IDS} commands"
            );
        }
        let tx = self.connection.transaction()?;
        let deleted = match deletion {
            CommandDeletion::Ids(ids) => {
                let mut statement = tx.prepare("DELETE FROM terminal_commands WHERE id = ?1")?;
                let mut deleted = 0;
                for id in ids {
                    deleted += statement.execute([to_i64(*id)])?;
                }
                deleted
            }
            CommandDeletion::StartedSince(since_ms) => tx.execute(
                "DELETE FROM terminal_commands WHERE started_at_ms >= ?1",
                [to_i64(*since_ms)],
            )?,
            CommandDeletion::All => tx.execute("DELETE FROM terminal_commands", [])?,
        };
        if deleted > 0 {
            tx.execute(
                "INSERT INTO meta(key, value) VALUES(?1, '1')
                 ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1",
                [DELETIONS_KEY],
            )?;
        }
        tx.commit()?;
        Ok(deleted as u64)
    }

    /// Deletes rows older than the retention. Reads first, so a pass with
    /// nothing expired writes nothing.
    pub(crate) fn expire_terminal_commands(
        &mut self,
        now_ms: u64,
    ) -> anyhow::Result<CommandExpiry> {
        let retention_days = self.terminal_command_retention_days()?;
        let retention_ms = u64::from(retention_days) * DAY_MS;
        let oldest = |registry: &Self| -> anyhow::Result<Option<u64>> {
            let oldest: Option<i64> = registry
                .connection
                .query_row("SELECT MIN(started_at_ms) FROM terminal_commands", [], |row| row.get(0))
                .optional()?
                .flatten();
            Ok(oldest.map(to_u64))
        };
        let mut deleted = 0;
        if let (Some(cutoff), Some(oldest)) = (expiry_cutoff(retention_days, now_ms), oldest(self)?)
            && oldest <= cutoff
        {
            deleted = self.connection.execute(
                "DELETE FROM terminal_commands WHERE started_at_ms <= ?1",
                [to_i64(cutoff)],
            )? as u64;
        }
        let next_ms = oldest(self)?.map(|oldest| oldest.saturating_add(retention_ms));
        Ok(CommandExpiry { deleted, next_ms })
    }

    /// Moves deleted pages into the database file and resets the WAL, which
    /// still holds the text of deleted rows. Never waits for readers: returns
    /// false when one blocked it, and the caller tries again later.
    pub(crate) fn checkpoint_terminal_command_deletes(&mut self) -> anyhow::Result<bool> {
        if self.session_journal_database_path().is_none() {
            return Ok(true);
        }
        self.connection.busy_timeout(Duration::ZERO)?;
        let result = self
            .connection
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get::<_, i64>(0));
        self.connection.busy_timeout(REGISTRY_BUSY_TIMEOUT)?;
        match result {
            Ok(busy) => Ok(busy == 0),
            Err(rusqlite::Error::SqliteFailure(error, _))
                if error.code == rusqlite::ErrorCode::DatabaseBusy =>
            {
                Ok(false)
            }
            Err(error) => Err(error.into()),
        }
    }
}

/// A row that started at or before this time has expired; `None` before any
/// row can have.
fn expiry_cutoff(retention_days: u32, now_ms: u64) -> Option<u64> {
    now_ms.checked_sub(u64::from(retention_days) * DAY_MS)
}

#[cfg(test)]
mod tests;
