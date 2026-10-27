//! Resource identity reads that mux planners make on a registry connection
//! they already hold, and the SQLite error class a hook retry reads. SQL
//! stays in the registry: mux/ calls these instead of naming rusqlite
//! (p02-threads MQ-14), and the connection it passes was taken through the
//! registry's checked chokepoint (`RegistryConnection::get`).

use rusqlite::{Connection, OptionalExtension};

use super::AgentHookRetryClass;

/// Whether `public_id` names a live or deleted resource: a client-minted id
/// is never reused (`split-client-keys-v1`).
pub(crate) fn resource_public_id_known(
    connection: &Connection,
    public_id: &str,
) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// Whether `tab` names a tab the registry retired (closed): the only ids a
/// reopen may give back.
pub(crate) fn is_retired_tab(connection: &Connection, tab: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM resource_tabs WHERE public_id = ?1 AND deleted_revision IS NOT NULL",
            [tab],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

impl AgentHookRetryClass {
    /// Whether `error` failed because another connection held the registry
    /// (SQLite busy or locked): a retry can succeed.
    pub(crate) fn registry_busy(error: &anyhow::Error) -> bool {
        error.chain().any(|cause| {
            matches!(
                cause.downcast_ref::<rusqlite::Error>(),
                Some(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error {
                        code: rusqlite::ErrorCode::DatabaseBusy
                            | rusqlite::ErrorCode::DatabaseLocked,
                        ..
                    },
                    _
                ))
            )
        })
    }
}
