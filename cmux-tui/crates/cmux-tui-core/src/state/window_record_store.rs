//! Window records: personal state with a single writer per record
//! (plans/cmux-next/OWNERSHIP-PRINCIPLES.md "Single writer per entity").
//!
//! One record per app window, keyed `(install_id, window_id)`, owned by the
//! install that hosts the window (`owner = install_id`). Every write is a
//! compare-and-swap on the record's own revision, so two windows (or two
//! Macs) saving at once never overwrite each other and never contend on one
//! shared document.
//!
//! Migration: the app's `windows` frontend projection (frontend `cmux-next`,
//! scope `personal`) is copied once, at the first open of a registry that
//! has these tables, into records owned by [`PLACEHOLDER_INSTALL_ID`]. The
//! app adopts one on its first `window_record.put` of the same `window_id`:
//! the placeholder row moves to the putting install, its revision continues,
//! and the change batch deletes the placeholder record and upserts the
//! adopted one. `window_record.delete` drops a placeholder record the app
//! does not adopt. The projection itself stays readable and writable for
//! older apps; after the migration the two are not kept in sync.
//!
//! Gap: the owner is not authenticated yet. The daemon trusts the
//! `install_id` a request names (client-enforced single writer) until
//! connections carry an authenticated install identity.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

/// The resource kind of window records on `session.events`.
pub(crate) const RESOURCE: &str = "window_record";
/// Owner of the records migrated from the `windows` projection until an app
/// adopts them. Reserved: no request may put under it.
pub(crate) const PLACEHOLDER_INSTALL_ID: &str = "install_unadopted";
/// The largest record body, in canonical JSON bytes.
pub(crate) const MAX_RECORD_BYTES: usize = 64 * 1024;
const MIGRATED_META_KEY: &str = "window_records_v1";
const PROJECTION_FRONTEND: &str = "cmux-next";
const PROJECTION_SCOPE: &str = "personal";
const PROJECTION_SUBJECT: &str = "windows";

pub(crate) fn create_window_record_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS window_records (
           install_id TEXT NOT NULL,
           window_id TEXT NOT NULL,
           owner TEXT NOT NULL,
           revision INTEGER NOT NULL CHECK(revision >= 1),
           record_json TEXT NOT NULL,
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           PRIMARY KEY(install_id, window_id)
         );",
    )?;
    Ok(())
}

/// Validate an install or window id: 1 to 128 bytes of ASCII letters,
/// digits, `-`, `_`, `.` or `:` (no `/`, which joins the record id).
pub(crate) fn validate_key(field: &str, value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_.:".contains(&byte)),
        "bad request: {field} must be 1 to 128 ASCII letters, digits, '-', '_', '.' or ':'"
    );
    Ok(())
}

/// The public id of one record on `session.events`.
pub(crate) fn record_id(install_id: &str, window_id: &str) -> String {
    format!("{install_id}/{window_id}")
}

pub(crate) struct StoredRecord {
    pub(crate) revision: u64,
    pub(crate) snapshot: Value,
}

fn snapshot_value(
    install_id: &str,
    window_id: &str,
    owner: &str,
    revision: u64,
    record_json: &str,
    updated_at_ms: u64,
) -> anyhow::Result<Value> {
    Ok(json!({
        "id": record_id(install_id, window_id),
        "install_id": install_id,
        "window_id": window_id,
        "owner": owner,
        "revision": revision.to_string(),
        "record": serde_json::from_str::<Value>(record_json)?,
        "updated_at_ms": updated_at_ms.to_string(),
    }))
}

type Row = (String, String, String, i64, String, i64);

fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Row> {
    Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?))
}

fn stored(row: Row) -> anyhow::Result<StoredRecord> {
    let (install_id, window_id, owner, revision, record_json, updated_at_ms) = row;
    let revision = u64::try_from(revision)?;
    Ok(StoredRecord {
        revision,
        snapshot: snapshot_value(
            &install_id,
            &window_id,
            &owner,
            revision,
            &record_json,
            u64::try_from(updated_at_ms)?,
        )?,
    })
}

const COLUMNS: &str = "install_id, window_id, owner, revision, record_json, updated_at_ms";

/// One record, if stored.
pub(crate) fn record(
    connection: &Connection,
    install_id: &str,
    window_id: &str,
) -> anyhow::Result<Option<StoredRecord>> {
    connection
        .query_row(
            &format!(
                "SELECT {COLUMNS} FROM window_records WHERE install_id = ?1 AND window_id = ?2"
            ),
            params![install_id, window_id],
            row,
        )
        .optional()?
        .map(stored)
        .transpose()
}

/// Every record of every install, ordered by install then window.
pub(crate) fn record_snapshots(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    let mut statement = connection
        .prepare(&format!("SELECT {COLUMNS} FROM window_records ORDER BY install_id, window_id"))?;
    let rows = statement.query_map([], row)?.collect::<Result<Vec<_>, _>>()?;
    rows.into_iter().map(|row| stored(row).map(|record| record.snapshot)).collect()
}

/// Write one record at `revision` (insert or replace) and return its
/// snapshot.
pub(crate) fn write_record(
    transaction: &Transaction<'_>,
    install_id: &str,
    window_id: &str,
    revision: u64,
    record_json: &str,
    updated_at_ms: u64,
) -> anyhow::Result<Value> {
    transaction.execute(
        "INSERT INTO window_records(
           install_id, window_id, owner, revision, record_json, updated_at_ms
         ) VALUES(?1, ?2, ?1, ?3, ?4, ?5)
         ON CONFLICT(install_id, window_id) DO UPDATE SET
           owner = excluded.owner,
           revision = excluded.revision,
           record_json = excluded.record_json,
           updated_at_ms = excluded.updated_at_ms",
        params![
            install_id,
            window_id,
            i64::try_from(revision)?,
            record_json,
            i64::try_from(updated_at_ms)?
        ],
    )?;
    snapshot_value(install_id, window_id, install_id, revision, record_json, updated_at_ms)
}

/// Remove one record. Returns whether it existed.
pub(crate) fn delete_record(
    transaction: &Transaction<'_>,
    install_id: &str,
    window_id: &str,
) -> anyhow::Result<bool> {
    Ok(transaction.execute(
        "DELETE FROM window_records WHERE install_id = ?1 AND window_id = ?2",
        params![install_id, window_id],
    )? > 0)
}

/// One-time copy of the `windows` frontend projection into placeholder
/// records. Idempotent: a `meta` flag records it. Windows without a string
/// `id` are skipped; the projection row is left in place.
pub(crate) fn migrate_window_projection(connection: &Connection) -> anyhow::Result<()> {
    let tx = connection.unchecked_transaction()?;
    let migrated = tx
        .query_row("SELECT 1 FROM meta WHERE key = ?1", [MIGRATED_META_KEY], |_| Ok(()))
        .optional()?
        .is_some();
    if !migrated {
        let payload = tx
            .query_row(
                "SELECT payload FROM frontend_projections
                 WHERE frontend = ?1 AND scope = ?2 AND subject_key = ?3",
                params![PROJECTION_FRONTEND, PROJECTION_SCOPE, PROJECTION_SUBJECT],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let windows = payload
            .and_then(|payload| serde_json::from_str::<Value>(&payload).ok())
            .and_then(|document| document.get("windows").and_then(Value::as_array).cloned())
            .unwrap_or_default();
        let now = crate::mux::now_ms();
        for window in windows {
            let Some(window_id) = window.get("id").and_then(Value::as_str) else { continue };
            if validate_key("window_id", window_id).is_err() || !window.is_object() {
                continue;
            }
            let record_json = serde_json::to_string(&window)?;
            if record_json.len() > MAX_RECORD_BYTES {
                continue;
            }
            tx.execute(
                "INSERT OR IGNORE INTO window_records(
                   install_id, window_id, owner, revision, record_json, updated_at_ms
                 ) VALUES(?1, ?2, ?1, 1, ?3, ?4)",
                params![PLACEHOLDER_INSTALL_ID, window_id, record_json, i64::try_from(now)?],
            )?;
        }
        tx.execute("INSERT INTO meta(key, value) VALUES(?1, '1')", [MIGRATED_META_KEY])?;
    }
    tx.commit()?;
    Ok(())
}
