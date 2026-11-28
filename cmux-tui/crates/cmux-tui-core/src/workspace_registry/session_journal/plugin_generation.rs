//! Journal plugin generation reservation (moved out of session_journal.rs).

use super::*;

impl WorkspaceRegistry {
    /// Reserve a process generation for the userland journal-plugin
    /// supervisor. The value lives in the session registry so a daemon restart
    /// can never reuse a generation that a persisted roster fence retired.
    pub(crate) fn reserve_journal_plugin_generation(&self) -> anyhow::Result<u64> {
        let db = self.connection.get();
        let transaction =
            Transaction::new_unchecked(&db, rusqlite::TransactionBehavior::Immediate)?;
        let current = transaction
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                [JOURNAL_PLUGIN_GENERATION_META_KEY],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .map(|value| {
                value.parse::<u64>().with_context(|| {
                    format!("journal plugin generation {JOURNAL_PLUGIN_GENERATION_META_KEY} is not an unsigned integer")
                })
            })
            .transpose()?
            .unwrap_or(0);
        let next = current
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("journal plugin generation exhausted"))?;
        transaction.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            rusqlite::params![JOURNAL_PLUGIN_GENERATION_META_KEY, next.to_string()],
        )?;
        transaction.commit()?;
        Ok(next)
    }
}
