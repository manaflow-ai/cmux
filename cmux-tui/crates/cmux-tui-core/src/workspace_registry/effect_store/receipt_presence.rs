//! Whether a resource request was already received: a stored effect or
//! creation receipt for its idempotency key, or a creation receipt for its
//! correlation key. A gate that refuses new work before the receipt lookup
//! (resource_router/browser_engine.rs) lets such a retry through to its
//! replay.

use super::*;

impl WorkspaceRegistry {
    #[track_caller]
    pub fn has_resource_receipt(
        &self,
        idempotency_key: &str,
        correlation_key: Option<&str>,
    ) -> anyhow::Result<bool> {
        let connection = self.connection.get();
        let found: i64 = connection.query_row(
            "SELECT EXISTS (SELECT 1 FROM resource_effect_receipts WHERE idempotency_key = ?1)
                 OR EXISTS (SELECT 1 FROM resource_creation_receipts
                            WHERE idempotency_key = ?1 OR correlation_key = ?2)",
            rusqlite::params![idempotency_key, correlation_key.unwrap_or(idempotency_key)],
            |row| row.get(0),
        )?;
        Ok(found != 0)
    }
}
