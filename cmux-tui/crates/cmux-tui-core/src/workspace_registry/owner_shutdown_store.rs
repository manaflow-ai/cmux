//! When the owner's session began shutting down (`session-shutdown`).
//!
//! A shell that dies of a signal while its session shuts down (logout,
//! reboot, `SIGTERM` to the daemon) did not end on its own: the session
//! ended around it. The next owner classifies such an exit as a host loss
//! (invariant 3 of plans/cmux-next/OWNERSHIP-PRINCIPLES.md keeps its tab),
//! so it needs the moment the previous owner began shutting down. That
//! moment is one row in the `meta` table, which every schema has: older
//! binaries never read the key, so no migration is needed.

use rusqlite::OptionalExtension;

use super::WorkspaceRegistry;

const OWNER_SHUTDOWN_STARTED_AT_KEY: &str = "owner_shutdown_started_at_ms";

impl WorkspaceRegistry {
    /// Record the start of this owner's shutdown. The earliest start wins,
    /// so a repeated shutdown request never narrows the window.
    pub(crate) fn record_owner_shutdown_start(&mut self, at_ms: u64) -> anyhow::Result<()> {
        self.connection.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO NOTHING",
            [OWNER_SHUTDOWN_STARTED_AT_KEY, &at_ms.to_string()],
        )?;
        Ok(())
    }

    /// The previous owner's shutdown start, if it recorded one.
    pub(crate) fn owner_shutdown_start(&self) -> anyhow::Result<Option<u64>> {
        let value = self
            .connection
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                [OWNER_SHUTDOWN_STARTED_AT_KEY],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        Ok(value.and_then(|value| value.parse().ok()))
    }

    /// Forget the previous owner's shutdown start once this owner's startup
    /// reconciliation classified the exits it left.
    pub(crate) fn clear_owner_shutdown_start(&mut self) -> anyhow::Result<()> {
        self.connection
            .execute("DELETE FROM meta WHERE key = ?1", [OWNER_SHUTDOWN_STARTED_AT_KEY])?;
        Ok(())
    }
}
