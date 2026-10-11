//! Durable per-terminal idle-close policies (`terminal-idle-close-v1`).
//!
//! A policy is keyed by the process-stable terminal host id, so it survives
//! owner restarts together with the terminal host it describes. The table is
//! additive and carries no foreign key: an older binary that opens the same
//! registry ignores it, and a policy row whose terminal is gone or tombstoned
//! is inert and pruned by the owner's reaper.

use rusqlite::{OptionalExtension, Transaction, params};

use super::{TerminalLifecycle, WorkspaceRegistry, read_terminal, validate_terminal_identity};

/// Largest accepted idle-close duration: ten years. The bound keeps every
/// deadline representable as an `Instant` offset on all supported platforms.
pub(crate) const MAX_TERMINAL_IDLE_CLOSE_SECONDS: u64 = 10 * 365 * 24 * 60 * 60;

/// One live terminal with an idle-close policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalIdlePolicy {
    pub terminal_id: String,
    pub incarnation: Option<String>,
    pub idle_close_seconds: u64,
}

pub(super) fn create_terminal_idle_policy_schema(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_idle_policies (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           idle_close_seconds INTEGER NOT NULL CHECK(idle_close_seconds > 0)
         );",
    )?;
    Ok(())
}

fn validate_terminal_idle_close_seconds(seconds: Option<u64>) -> anyhow::Result<()> {
    if let Some(seconds) = seconds {
        anyhow::ensure!(
            (1..=MAX_TERMINAL_IDLE_CLOSE_SECONDS).contains(&seconds),
            "bad request: idle_close_seconds must be between 1 and {MAX_TERMINAL_IDLE_CLOSE_SECONDS}, or null"
        );
    }
    Ok(())
}

impl WorkspaceRegistry {
    /// Store (`Some`) or clear (`None`, never close) the idle-close policy of a
    /// live terminal. Tombstoned or unknown terminals are rejected so a stale
    /// request cannot leave an orphan policy behind.
    pub fn set_terminal_idle_policy(
        &mut self,
        terminal_id: &str,
        idle_close_seconds: Option<u64>,
    ) -> anyhow::Result<()> {
        validate_terminal_identity("terminal id", terminal_id)?;
        validate_terminal_idle_close_seconds(idle_close_seconds)?;
        let tx = self.connection.transaction()?;
        let terminal = read_terminal(&tx, terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal_not_found"))?;
        anyhow::ensure!(terminal.lifecycle != TerminalLifecycle::Tombstoned, "terminal_not_found");
        match idle_close_seconds {
            Some(seconds) => {
                let seconds = i64::try_from(seconds)?;
                tx.execute(
                    "INSERT INTO terminal_idle_policies(terminal_id, idle_close_seconds)
                     VALUES(?1, ?2)
                     ON CONFLICT(terminal_id) DO UPDATE
                       SET idle_close_seconds = excluded.idle_close_seconds",
                    params![terminal_id, seconds],
                )?;
            }
            None => {
                const DELETE_POLICY: &str =
                    "DELETE FROM terminal_idle_policies WHERE terminal_id = ?1";
                tx.execute(DELETE_POLICY, [terminal_id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// The stored policy of one terminal, if any.
    pub fn terminal_idle_policy(&self, terminal_id: &str) -> anyhow::Result<Option<u64>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        let seconds = self
            .connection
            .query_row(
                "SELECT idle_close_seconds FROM terminal_idle_policies WHERE terminal_id = ?1",
                [terminal_id],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        Ok(seconds.map(u64::try_from).transpose()?)
    }

    /// Every non-tombstoned terminal that carries an idle-close policy.
    pub fn live_terminal_idle_policies(&self) -> anyhow::Result<Vec<TerminalIdlePolicy>> {
        let mut statement = self.connection.prepare(
            "SELECT policy.terminal_id, host.incarnation, policy.idle_close_seconds
             FROM terminal_idle_policies AS policy
             JOIN terminal_hosts AS host ON host.terminal_id = policy.terminal_id
             WHERE host.lifecycle != 'tombstoned'
             ORDER BY policy.terminal_id",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?, row.get::<_, i64>(2)?))
        })?;
        let mut policies = Vec::new();
        for row in rows {
            let (terminal_id, incarnation, seconds) = row?;
            policies.push(TerminalIdlePolicy {
                terminal_id,
                incarnation,
                idle_close_seconds: u64::try_from(seconds)?,
            });
        }
        Ok(policies)
    }

    /// Delete policies whose terminal is tombstoned or no longer registered.
    /// Returns the number of rows removed.
    pub fn prune_terminal_idle_policies(&mut self) -> anyhow::Result<usize> {
        Ok(self.connection.execute(
            "DELETE FROM terminal_idle_policies
             WHERE terminal_id NOT IN (
               SELECT terminal_id FROM terminal_hosts WHERE lifecycle != 'tombstoned'
             )",
            [],
        )?)
    }
}
