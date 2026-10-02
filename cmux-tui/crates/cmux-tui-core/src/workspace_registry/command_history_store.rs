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

use super::{WorkspaceRegistry, meta_value};
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
                let mut insert = tx.prepare_cached(
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
        let mut statement = self.connection.prepare_cached(
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
            registry_id: self.registry_id.clone(),
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
                let mut statement =
                    tx.prepare_cached("DELETE FROM terminal_commands WHERE id = ?1")?;
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
        if self.database_path.is_none() {
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
mod tests {
    use super::*;

    const NOW: u64 = 100 * DAY_MS;

    fn temp_root(label: &str) -> std::path::PathBuf {
        std::env::temp_dir()
            .join(format!("cmux-command-history-{label}-{}", super::super::new_uuid_v4()))
    }

    fn command(text: &str, started_at_ms: u64) -> FinishedCommand {
        FinishedCommand {
            command: Some(text.into()),
            cwd: Some("/repo".into()),
            exit_code: Some(0),
            started_at_ms,
            duration_ms: 5,
        }
    }

    fn terminal() -> String {
        "term_00000000000000000000000000000001".into()
    }

    fn texts(page: &CommandHistoryPage) -> Vec<String> {
        page.commands.iter().map(|row| row.command.clone().unwrap_or_default()).collect()
    }

    #[test]
    fn command_history_lists_the_newest_rows_after_a_cursor_in_order() {
        let mut registry = WorkspaceRegistry::in_memory("command-history-list").unwrap();
        let rows: Vec<_> =
            (0..5).map(|step| (terminal(), command(&format!("c{step}"), NOW + step))).collect();
        registry.append_terminal_commands(&rows, NOW).unwrap();

        let page = registry.list_terminal_commands(None, 10, NOW).unwrap();
        assert_eq!(texts(&page), ["c0", "c1", "c2", "c3", "c4"]);
        assert_eq!(page.retention_days, DEFAULT_COMMAND_RETENTION_DAYS);
        assert_eq!(page.deletions, 0);
        let first = &page.commands[0];
        assert_eq!(first.terminal_id, terminal());
        assert_eq!(first.cwd.as_deref(), Some("/repo"));
        assert_eq!(first.exit_code, Some(0));
        assert_eq!(first.started_at_ms, NOW);
        assert_eq!(first.duration_ms, 5);

        assert!(!page.truncated);
        assert_eq!(page.registry_id, registry.registry_id());

        let newest = registry.list_terminal_commands(None, 2, NOW).unwrap();
        assert_eq!(texts(&newest), ["c3", "c4"], "a limit keeps the newest rows");
        assert!(newest.truncated, "older rows were left out");
        let after = registry.list_terminal_commands(Some(page.commands[2].id), 10, NOW).unwrap();
        assert_eq!(texts(&after), ["c3", "c4"]);
        assert!(!after.truncated);
        let gap = registry.list_terminal_commands(Some(page.commands[0].id), 2, NOW).unwrap();
        assert_eq!(texts(&gap), ["c3", "c4"]);
        assert!(gap.truncated, "a reader after c0 missed c1 and c2");
    }

    #[test]
    fn command_history_deletes_by_id_by_start_time_and_all() {
        let mut registry = WorkspaceRegistry::in_memory("command-history-delete").unwrap();
        let rows: Vec<_> =
            (0..4).map(|step| (terminal(), command(&format!("c{step}"), NOW + step))).collect();
        registry.append_terminal_commands(&rows, NOW).unwrap();
        let ids: Vec<u64> = registry
            .list_terminal_commands(None, 10, NOW)
            .unwrap()
            .commands
            .iter()
            .map(|r| r.id)
            .collect();

        assert_eq!(
            registry.delete_terminal_commands(&CommandDeletion::Ids(vec![ids[1]])).unwrap(),
            1
        );
        let page = registry.list_terminal_commands(None, 10, NOW).unwrap();
        assert_eq!(texts(&page), ["c0", "c2", "c3"]);
        assert_eq!(page.deletions, 1);

        assert_eq!(
            registry.delete_terminal_commands(&CommandDeletion::StartedSince(NOW + 2)).unwrap(),
            2
        );
        assert_eq!(texts(&registry.list_terminal_commands(None, 10, NOW).unwrap()), ["c0"]);

        // A delete that removes nothing does not count.
        assert_eq!(
            registry.delete_terminal_commands(&CommandDeletion::Ids(vec![ids[1]])).unwrap(),
            0
        );
        assert_eq!(registry.list_terminal_commands(None, 10, NOW).unwrap().deletions, 2);

        assert_eq!(registry.delete_terminal_commands(&CommandDeletion::All).unwrap(), 1);
        let empty = registry.list_terminal_commands(None, 10, NOW).unwrap();
        assert!(empty.commands.is_empty());
        assert_eq!(empty.deletions, 3);

        // Ids are never reused after a delete.
        registry.append_terminal_commands(&[(terminal(), command("next", NOW))], NOW).unwrap();
        let next = registry.list_terminal_commands(None, 10, NOW).unwrap();
        assert!(next.commands[0].id > ids[3]);
    }

    #[test]
    fn command_history_expires_rows_after_the_retention_period() {
        let mut registry = WorkspaceRegistry::in_memory("command-history-expiry").unwrap();
        let old = NOW - 31 * DAY_MS;
        let recent = NOW - 29 * DAY_MS;
        let stored = registry
            .append_terminal_commands(
                &[(terminal(), command("old", old)), (terminal(), command("recent", recent))],
                NOW,
            )
            .unwrap();
        // The append deleted the expired row and reports the next expiry.
        let next = recent + 30 * DAY_MS;
        assert_eq!(stored, CommandExpiry { deleted: 1, next_ms: Some(next) });
        let page = registry.list_terminal_commands(None, 10, NOW).unwrap();
        assert_eq!(texts(&page), ["recent"]);
        assert_eq!(page.deletions, 0, "expiry is not a client delete");

        // At the next expiry time the row goes, and nothing is left to wait for.
        assert_eq!(
            registry.expire_terminal_commands(next - 1).unwrap(),
            CommandExpiry { deleted: 0, next_ms: Some(next) }
        );
        assert_eq!(
            registry.expire_terminal_commands(next).unwrap(),
            CommandExpiry { deleted: 1, next_ms: None }
        );
        assert!(registry.list_terminal_commands(None, 10, NOW).unwrap().commands.is_empty());
    }

    #[test]
    fn command_history_list_never_returns_an_expired_row() {
        let mut registry = WorkspaceRegistry::in_memory("command-history-list-expiry").unwrap();
        registry.append_terminal_commands(&[(terminal(), command("a", NOW))], NOW).unwrap();
        let later = NOW + 30 * DAY_MS;
        assert!(registry.list_terminal_commands(None, 10, later).unwrap().commands.is_empty());
        assert_eq!(registry.list_terminal_commands(None, 10, later - 1).unwrap().commands.len(), 1);
    }

    #[test]
    fn command_history_retention_is_validated_persisted_and_applied_at_once() {
        let root = temp_root("retention");
        {
            let mut registry = WorkspaceRegistry::open(&root, "retention").unwrap();
            assert_eq!(registry.terminal_command_retention_days().unwrap(), 30);
            registry
                .append_terminal_commands(
                    &[
                        (terminal(), command("ten days", NOW - 10 * DAY_MS)),
                        (terminal(), command("two days", NOW - 2 * DAY_MS)),
                    ],
                    NOW,
                )
                .unwrap();
            assert!(registry.set_terminal_command_retention_days(0).is_err());
            assert!(
                registry
                    .set_terminal_command_retention_days(MAX_COMMAND_RETENTION_DAYS + 1)
                    .is_err()
            );
            registry.set_terminal_command_retention_days(7).unwrap();
            // Hidden from lists at once, deleted on the next pass.
            assert_eq!(
                texts(&registry.list_terminal_commands(None, 10, NOW).unwrap()),
                ["two days"]
            );
            assert_eq!(
                registry.expire_terminal_commands(NOW).unwrap(),
                CommandExpiry { deleted: 1, next_ms: Some(NOW - 2 * DAY_MS + 7 * DAY_MS) }
            );
        }
        let registry = WorkspaceRegistry::open(&root, "retention").unwrap();
        assert_eq!(registry.terminal_command_retention_days().unwrap(), 7);
        drop(registry);
        let _ = std::fs::remove_dir_all(root);
    }

    /// A deleted command line must not stay readable in the database file.
    #[test]
    fn command_history_delete_zeroes_the_deleted_text_on_disk() {
        let root = temp_root("secure-delete");
        let secret = "export TOKEN=cmux-secret-4f1c9e";
        let path = {
            let mut registry = WorkspaceRegistry::open(&root, "secure-delete").unwrap();
            registry.append_terminal_commands(&[(terminal(), command(secret, NOW))], NOW).unwrap();
            assert_eq!(registry.delete_terminal_commands(&CommandDeletion::All).unwrap(), 1);
            assert!(registry.checkpoint_terminal_command_deletes().unwrap());
            registry.database_path.clone().unwrap()
        };
        let mut bytes = std::fs::read(&path).unwrap();
        if let Ok(wal) = std::fs::read(path.with_extension("sqlite3-wal")) {
            bytes.extend(wal);
        }
        let needle = b"cmux-secret-4f1c9e";
        assert!(
            !bytes.windows(needle.len()).any(|window| window == needle),
            "deleted command text is still in the database file"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn command_history_rejects_oversized_requests() {
        let mut registry = WorkspaceRegistry::in_memory("command-history-limits").unwrap();
        assert!(registry.list_terminal_commands(None, 0, NOW).is_err());
        assert!(registry.list_terminal_commands(None, MAX_COMMAND_LIST_LIMIT + 1, NOW).is_err());
        let ids = (1..=MAX_COMMAND_DELETE_IDS as u64 + 1).collect();
        assert!(registry.delete_terminal_commands(&CommandDeletion::Ids(ids)).is_err());
        assert!(registry.delete_terminal_commands(&CommandDeletion::Ids(Vec::new())).is_err());
    }
}
