//! The stored resource creation receipt row, read by every creation path.

use super::*;

pub(super) struct StoredCreation {
    pub(super) operation: String,
    pub(super) fingerprint: String,
    pub(super) idempotency_key: String,
    pub(super) intent_json: String,
    pub(super) execution_kind: String,
    pub(super) attempt: u64,
    pub(super) state: String,
    pub(super) execution_generation: Option<String>,
    pub(super) created_path_json: Option<String>,
    pub(super) generation: Option<String>,
    pub(super) committed_revision: Option<i64>,
}

pub(super) fn read_creation_record(
    connection: &Connection,
    correlation_key: &str,
) -> anyhow::Result<Option<StoredCreation>> {
    connection
        .query_row(
            "SELECT operation, fingerprint, idempotency_key, intent_json, execution_kind,
                    attempt, state, execution_generation, created_path_json, generation,
                    committed_revision
             FROM resource_creation_receipts
             WHERE correlation_key = ?1",
            [correlation_key],
            |row| {
                Ok(StoredCreation {
                    operation: row.get(0)?,
                    fingerprint: row.get(1)?,
                    idempotency_key: row.get(2)?,
                    intent_json: row.get(3)?,
                    execution_kind: row.get(4)?,
                    attempt: u64::try_from(row.get::<_, i64>(5)?)
                        .map_err(|_| rusqlite::Error::IntegralValueOutOfRange(5, i64::MAX))?,
                    state: row.get(6)?,
                    execution_generation: row.get(7)?,
                    created_path_json: row.get(8)?,
                    generation: row.get(9)?,
                    committed_revision: row.get(10)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
}
