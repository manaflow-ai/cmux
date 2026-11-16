//! Per-app KV storage (`app.storage.*`): SQLite, one table per app.
//! The supervisor owns it (plan section 7); uninstall drops the table in the
//! same commit that clears the install record.
//!
//! An app granted `storage:synced` keeps the same four ops, served from a
//! second table per app: the device's replica of the person's `appkv:<user>`
//! cloud stream (cmuxterm-hq#12221). Each row has its value, the cloud's
//! `revision` and a `dirty` flag; writes apply here at once, mark the row
//! dirty and queue one op per key in `appkv_outbox`, which `synced.rs` sends
//! with its idempotency key until the cloud answers. A stream row applies
//! unless a local write of that key is still pending (it is kept as the
//! row's `seen_*` and applied after the ack when the cloud ordered it after
//! ours) or the replica already holds a newer revision. An app with only
//! `storage:local` never touches these tables.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::cloud_conversations::{AppKvRow, AppKvWrite};

pub const MAX_KEY_BYTES: usize = 256;
pub const MAX_VALUE_BYTES: usize = 64 * 1024;
pub const MAX_APP_BYTES: i64 = 4 * 1024 * 1024;

/// The grant that routes `app.storage.*` to the synced replica.
pub const SYNCED_SCOPE: &str = "storage:synced";

/// Keys changed per app, for `app.storage.changed {keys}`.
pub type Changed = BTreeMap<String, BTreeSet<String>>;

pub struct Storage {
    db: Connection,
}

/// An error answered to the app (`{code, message}`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageError {
    pub code: &'static str,
    pub message: String,
}

/// One queued cloud write: the newest local write of one key.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingOp {
    pub app: String,
    pub key: String,
    /// `None` deletes.
    pub value: Option<Value>,
    pub idempotency_key: String,
}

fn failed(error: impl std::fmt::Display) -> StorageError {
    StorageError { code: "operation.failed", message: error.to_string() }
}

fn invalid(message: &str) -> StorageError {
    StorageError { code: "validation.invalid", message: message.to_string() }
}

/// `<prefix>_<first 16 hex of sha256(app id)>`: app ids never reach SQL text.
fn hashed(prefix: &str, app: &str) -> String {
    let digest = Sha256::digest(app.as_bytes());
    format!("{prefix}_{}", digest.iter().take(8).map(|b| format!("{b:02x}")).collect::<String>())
}

fn table(app: &str) -> String {
    hashed("kv", app)
}

/// The synced replica's table.
fn replica(app: &str) -> String {
    hashed("kvs", app)
}

/// The owner's row key of `(app, key)`: base64url(sha256(app NUL key)),
/// unpadded; a row that comes without one (an `appkv.list` page) gets it here.
pub fn row_key(app: &str, key: &str) -> String {
    use base64::Engine as _;
    let digest = Sha256::digest(format!("{app}\0{key}").as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

fn mint_key() -> String {
    let mut bytes = [0u8; 12];
    let _ = getrandom::fill(&mut bytes);
    format!("appkv-{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>())
}

fn mark(changed: &mut Changed, app: &str, key: &str) {
    changed.entry(app.to_string()).or_default().insert(key.to_string());
}

/// One replica row as stored.
struct Local {
    value: Option<String>,
    revision: i64,
    dirty: bool,
    seen_revision: Option<i64>,
    seen_value: Option<String>,
    seen_deleted: bool,
}

impl Storage {
    /// Opens (or creates) the database; `None` opens an in-memory one.
    pub fn open(path: Option<&Path>) -> Result<Self, StorageError> {
        let db = match path {
            Some(path) => Connection::open(path),
            None => Connection::open_in_memory(),
        }
        .map_err(failed)?;
        db.pragma_update(None, "journal_mode", "WAL").ok();
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS appkv_outbox (app TEXT NOT NULL, key TEXT NOT NULL, value TEXT, idem TEXT NOT NULL, PRIMARY KEY (app, key));
             CREATE TABLE IF NOT EXISTS appkv_rows (row_key TEXT PRIMARY KEY NOT NULL, app TEXT NOT NULL, key TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS appkv_apps (app TEXT PRIMARY KEY NOT NULL);
             CREATE TABLE IF NOT EXISTS appkv_meta (k TEXT PRIMARY KEY NOT NULL, v TEXT NOT NULL);",
        )
        .map_err(failed)?;
        Ok(Self { db })
    }

    fn ensure(&self, app: &str) -> Result<String, StorageError> {
        let table = table(app);
        self.db
            .execute_batch(&format!("CREATE TABLE IF NOT EXISTS {table} (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"))
            .map_err(failed)?;
        Ok(table)
    }

    /// The app's replica table, created (and registered) on first use. A
    /// `value` of NULL is a delete still pending.
    fn ensure_replica(&self, app: &str) -> Result<String, StorageError> {
        let table = replica(app);
        self.db
            .execute_batch(&format!("CREATE TABLE IF NOT EXISTS {table} (key TEXT PRIMARY KEY NOT NULL, value TEXT, revision INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 0, seen_revision INTEGER, seen_value TEXT, seen_deleted INTEGER NOT NULL DEFAULT 0)"))
            .map_err(failed)?;
        self.db
            .execute("INSERT OR IGNORE INTO appkv_apps (app) VALUES (?1)", params![app])
            .map_err(failed)?;
        Ok(table)
    }

    /// Whether the app has a replica here (it synced on this device before).
    pub fn has_replica(&self, app: &str) -> bool {
        self.db
            .query_row("SELECT 1 FROM appkv_apps WHERE app = ?1", params![app], |_| Ok(()))
            .optional()
            .ok()
            .flatten()
            .is_some()
    }

    /// Runs one `app.storage.*` op and returns its value; `synced` serves it
    /// from the app's replica (`storage:synced`).
    pub fn call(
        &self,
        app: &str,
        op: &str,
        params: &Value,
        synced: bool,
    ) -> Result<Value, StorageError> {
        let key = || -> Result<&str, StorageError> {
            let key = params
                .get("key")
                .and_then(Value::as_str)
                .ok_or_else(|| invalid("key must be a string"))?;
            if key.is_empty() || key.len() > MAX_KEY_BYTES {
                return Err(invalid("key must be 1 to 256 bytes"));
            }
            Ok(key)
        };
        let (table, live) = if synced {
            (self.ensure_replica(app)?, "value IS NOT NULL")
        } else {
            (self.ensure(app)?, "1")
        };
        match op {
            "app.storage.get" => {
                let raw: Option<String> = self
                    .db
                    .query_row(
                        &format!("SELECT value FROM {table} WHERE key = ?1 AND {live}"),
                        params![key()?],
                        |row| row.get(0),
                    )
                    .optional()
                    .map_err(failed)?;
                Ok(raw.and_then(|r| serde_json::from_str(&r).ok()).unwrap_or(Value::Null))
            }
            "app.storage.set" => {
                let key = key()?;
                let value = serde_json::to_string(params.get("value").unwrap_or(&Value::Null))
                    .map_err(failed)?;
                if value.len() > MAX_VALUE_BYTES {
                    return Err(StorageError {
                        code: "app.limit",
                        message: "value is larger than 64 KiB".into(),
                    });
                }
                let used: i64 = self
                    .db
                    .query_row(&format!("SELECT COALESCE(SUM(LENGTH(CAST(key AS BLOB)) + LENGTH(CAST(value AS BLOB))), 0) FROM {table} WHERE key != ?1 AND value IS NOT NULL"), params![key], |row| row.get(0))
                    .map_err(failed)?;
                if used + (key.len() + value.len()) as i64 > MAX_APP_BYTES {
                    return Err(StorageError {
                        code: "app.limit",
                        message: "the app's storage is full (4 MiB)".into(),
                    });
                }
                if synced {
                    self.write_local(app, &table, key, Some(&value))?;
                } else {
                    self.db
                        .execute(&format!("INSERT INTO {table} (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value"), params![key, value])
                        .map_err(failed)?;
                }
                Ok(Value::Null)
            }
            "app.storage.delete" => {
                let key = key()?;
                if synced {
                    self.write_local(app, &table, key, None)?;
                } else {
                    self.db
                        .execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![key])
                        .map_err(failed)?;
                }
                Ok(Value::Null)
            }
            "app.storage.keys" => {
                let mut statement = self
                    .db
                    .prepare(&format!("SELECT key FROM {table} WHERE {live} ORDER BY key"))
                    .map_err(failed)?;
                let keys = statement
                    .query_map([], |row| row.get::<_, String>(0))
                    .map_err(failed)?
                    .filter_map(Result::ok)
                    .collect::<Vec<_>>();
                Ok(json!(keys))
            }
            _ => Err(StorageError {
                code: "operation.unsupported",
                message: format!("{op} is not a storage op"),
            }),
        }
    }

    /// A local synced write: the row is dirty at once and the key's queued op
    /// is replaced (the cloud keeps the last write per key, so only the
    /// newest one needs to go). A delete keeps a NULL row until the ack, so
    /// a stream row cannot bring the key back meanwhile.
    fn write_local(
        &self,
        app: &str,
        table: &str,
        key: &str,
        value: Option<&str>,
    ) -> Result<(), StorageError> {
        let tx = self.db.unchecked_transaction().map_err(failed)?;
        tx.execute(&format!("INSERT INTO {table} (key, value, dirty) VALUES (?1, ?2, 1) ON CONFLICT(key) DO UPDATE SET value = excluded.value, dirty = 1"), params![key, value])
            .map_err(failed)?;
        tx.execute(
            "INSERT OR REPLACE INTO appkv_outbox (app, key, value, idem) VALUES (?1, ?2, ?3, ?4)",
            params![app, key, value, mint_key()],
        )
        .map_err(failed)?;
        tx.commit().map_err(failed)
    }

    /// Queued cloud writes, oldest first, at most `limit`.
    pub fn pending(&self, limit: usize) -> Vec<PendingOp> {
        let Ok(mut statement) = self
            .db
            .prepare("SELECT app, key, value, idem FROM appkv_outbox ORDER BY rowid LIMIT ?1")
        else {
            return Vec::new();
        };
        statement
            .query_map(params![limit as i64], |row| {
                let value: Option<String> = row.get(2)?;
                Ok(PendingOp {
                    app: row.get(0)?,
                    key: row.get(1)?,
                    value: value.and_then(|v| serde_json::from_str(&v).ok()),
                    idempotency_key: row.get(3)?,
                })
            })
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }

    fn local(&self, table: &str, key: &str) -> Option<Local> {
        self.db
            .query_row(
                &format!("SELECT value, revision, dirty, seen_revision, seen_value, seen_deleted FROM {table} WHERE key = ?1"),
                params![key],
                |row| {
                    Ok(Local {
                        value: row.get(0)?,
                        revision: row.get(1)?,
                        dirty: row.get::<_, i64>(2)? != 0,
                        seen_revision: row.get(3)?,
                        seen_value: row.get(4)?,
                        seen_deleted: row.get::<_, i64>(5)? != 0,
                    })
                },
            )
            .optional()
            .ok()
            .flatten()
    }

    /// The cloud took `op` (at `revision`, when its answer named one). A
    /// newer local write of the key keeps the row dirty. A stream row the
    /// cloud ordered after ours, seen while ours was pending, applies now.
    pub fn acked(&self, op: &PendingOp, revision: Option<u64>) -> Changed {
        let mut changed = Changed::new();
        let still: Option<String> = self
            .db
            .query_row(
                "SELECT idem FROM appkv_outbox WHERE app = ?1 AND key = ?2",
                params![op.app, op.key],
                |row| row.get(0),
            )
            .optional()
            .ok()
            .flatten();
        if still.as_deref() != Some(op.idempotency_key.as_str()) {
            return changed;
        }
        let _ = self.db.execute(
            "DELETE FROM appkv_outbox WHERE app = ?1 AND key = ?2",
            params![op.app, op.key],
        );
        let table = replica(&op.app);
        let Some(local) = self.local(&table, &op.key) else { return changed };
        let ours = revision.map_or(0, |r| r as i64);
        // A stream write the cloud ordered after ours: a row of a higher
        // revision, or a delete heard after our own write's echo.
        let later = revision.is_some()
            && local
                .seen_revision
                .is_some_and(|seen| if local.seen_deleted { seen >= ours } else { seen > ours });
        if later {
            if local.seen_deleted {
                let _ = self
                    .db
                    .execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![op.key]);
            } else {
                let _ = self.db.execute(
                    &format!("UPDATE {table} SET value = ?2, revision = ?3, dirty = 0, seen_revision = NULL, seen_value = NULL, seen_deleted = 0 WHERE key = ?1"),
                    params![op.key, local.seen_value, local.seen_revision],
                );
            }
            if local.seen_value != local.value || local.seen_deleted != local.value.is_none() {
                mark(&mut changed, &op.app, &op.key);
            }
        } else if local.value.is_none() {
            let _ =
                self.db.execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![op.key]);
        } else {
            let _ = self.db.execute(
                &format!("UPDATE {table} SET revision = ?2, dirty = 0, seen_revision = NULL, seen_value = NULL, seen_deleted = 0 WHERE key = ?1"),
                params![op.key, ours],
            );
        }
        changed
    }

    /// The cloud refused `op` for good (`app.limit`, a bad request): it is
    /// dropped and the key goes back to what the cloud last said, or stays as
    /// it is until the next snapshot when the replica heard nothing.
    pub fn refused(&self, op: &PendingOp) -> Changed {
        let mut changed = Changed::new();
        let removed = self
            .db
            .execute(
                "DELETE FROM appkv_outbox WHERE app = ?1 AND key = ?2 AND idem = ?3",
                params![op.app, op.key, op.idempotency_key],
            )
            .unwrap_or(0);
        if removed == 0 {
            return changed;
        }
        let table = replica(&op.app);
        let Some(local) = self.local(&table, &op.key) else { return changed };
        if local.seen_revision.is_some() && local.seen_deleted {
            let _ =
                self.db.execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![op.key]);
            mark(&mut changed, &op.app, &op.key);
        } else if local.seen_revision.is_some() {
            let _ = self.db.execute(
                &format!("UPDATE {table} SET value = ?2, revision = ?3, dirty = 0, seen_revision = NULL, seen_value = NULL WHERE key = ?1"),
                params![op.key, local.seen_value, local.seen_revision],
            );
            mark(&mut changed, &op.app, &op.key);
        } else if local.value.is_none() {
            let _ =
                self.db.execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![op.key]);
        } else {
            let _ = self.db.execute(
                &format!("UPDATE {table} SET dirty = 0, revision = 0 WHERE key = ?1"),
                params![op.key],
            );
        }
        changed
    }

    /// One stream row for an app that syncs here.
    fn apply_row(&self, row: &AppKvRow, changed: &mut Changed) -> Result<(), StorageError> {
        let table = self.ensure_replica(&row.app)?;
        let row_key =
            if row.row_key.is_empty() { row_key(&row.app, &row.key) } else { row.row_key.clone() };
        self.db
            .execute(
                "INSERT OR REPLACE INTO appkv_rows (row_key, app, key) VALUES (?1, ?2, ?3)",
                params![row_key, row.app, row.key],
            )
            .map_err(failed)?;
        let value = serde_json::to_string(&row.value).map_err(failed)?;
        let revision = row.revision as i64;
        match self.local(&table, &row.key) {
            // A local write is pending: it wins for now; the row is kept in
            // case the cloud ordered it after ours.
            Some(local) if local.dirty => {
                if local.seen_revision.is_none_or(|seen| revision >= seen) {
                    self.db
                        .execute(
                            &format!("UPDATE {table} SET seen_revision = ?2, seen_value = ?3, seen_deleted = 0 WHERE key = ?1"),
                            params![row.key, revision, value],
                        )
                        .map_err(failed)?;
                }
            }
            // A stale row never undoes a newer one (our own acked write).
            Some(local) if local.revision > revision => {}
            Some(local) if local.value.as_deref() == Some(value.as_str()) => {
                self.db
                    .execute(
                        &format!("UPDATE {table} SET revision = ?2 WHERE key = ?1"),
                        params![row.key, revision],
                    )
                    .map_err(failed)?;
            }
            _ => {
                self.db
                    .execute(&format!("INSERT INTO {table} (key, value, revision, dirty) VALUES (?1, ?2, ?3, 0) ON CONFLICT(key) DO UPDATE SET value = excluded.value, revision = excluded.revision, dirty = 0"), params![row.key, value, revision])
                    .map_err(failed)?;
                mark(changed, &row.app, &row.key);
            }
        }
        Ok(())
    }

    /// The stream removed `(app, key)`.
    fn remove_row(&self, app: &str, key: &str, changed: &mut Changed) -> Result<(), StorageError> {
        let table = self.ensure_replica(app)?;
        match self.local(&table, key) {
            Some(local) if local.dirty => {
                // Ordered after the last row the stream showed for the key.
                let seen = local.seen_revision.unwrap_or(local.revision);
                self.db
                    .execute(
                        &format!("UPDATE {table} SET seen_revision = ?2, seen_value = NULL, seen_deleted = 1 WHERE key = ?1"),
                        params![key, seen],
                    )
                    .map_err(failed)?;
            }
            Some(_) => {
                self.db
                    .execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![key])
                    .map_err(failed)?;
                mark(changed, app, key);
            }
            None => {}
        }
        Ok(())
    }

    /// Applies one stream event's writes, in order, for the apps `synced`
    /// says sync here; returns the keys that changed per app.
    pub fn apply_writes(
        &self,
        writes: &[AppKvWrite],
        synced: impl Fn(&str) -> bool,
    ) -> Result<Changed, StorageError> {
        let mut changed = Changed::new();
        for write in writes {
            match write {
                AppKvWrite::Upsert(row) if synced(&row.app) => self.apply_row(row, &mut changed)?,
                AppKvWrite::Upsert(_) => {}
                AppKvWrite::Delete { row_key } => {
                    let named: Option<(String, String)> = self
                        .db
                        .query_row(
                            "SELECT app, key FROM appkv_rows WHERE row_key = ?1",
                            params![row_key],
                            |row| Ok((row.get(0)?, row.get(1)?)),
                        )
                        .optional()
                        .map_err(failed)?;
                    let Some((app, key)) = named else { continue };
                    let _ = self
                        .db
                        .execute("DELETE FROM appkv_rows WHERE row_key = ?1", params![row_key]);
                    if synced(&app) {
                        self.remove_row(&app, &key, &mut changed)?;
                    }
                }
            }
        }
        Ok(changed)
    }

    /// A snapshot (or a full `appkv.list`) read at head revision `upto`: every
    /// row of the person's synced storage then. A clean row it does not hold
    /// and no later event wrote is gone; a dirty one waits for its ack.
    pub fn apply_snapshot(
        &self,
        rows: &[AppKvRow],
        upto: u64,
        synced: impl Fn(&str) -> bool,
    ) -> Result<Changed, StorageError> {
        let mut changed = Changed::new();
        let mut apps: BTreeSet<String> = self.replica_apps().into_iter().collect();
        apps.extend(rows.iter().map(|row| row.app.clone()));
        for app in apps.iter().filter(|app| synced(app)) {
            let table = self.ensure_replica(app)?;
            let held: BTreeSet<&str> =
                rows.iter().filter(|row| &row.app == app).map(|row| row.key.as_str()).collect();
            let clean: Vec<String> = {
                let mut statement = self
                    .db
                    .prepare(&format!("SELECT key FROM {table} WHERE dirty = 0 AND revision <= ?1"))
                    .map_err(failed)?;
                statement
                    .query_map(params![upto as i64], |row| row.get::<_, String>(0))
                    .map_err(failed)?
                    .filter_map(Result::ok)
                    .collect()
            };
            for key in clean.iter().filter(|key| !held.contains(key.as_str())) {
                self.db
                    .execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![key])
                    .map_err(failed)?;
                mark(&mut changed, app, key);
            }
            for row in rows.iter().filter(|row| &row.app == app) {
                self.apply_row(row, &mut changed)?;
            }
        }
        Ok(changed)
    }

    fn replica_apps(&self) -> Vec<String> {
        let Ok(mut statement) = self.db.prepare("SELECT app FROM appkv_apps ORDER BY app") else {
            return Vec::new();
        };
        statement
            .query_map([], |row| row.get::<_, String>(0))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }

    /// The cloud account the replicas belong to (`None`: never signed in;
    /// writes made signed out go to the first account that signs in).
    pub fn account(&self) -> Option<String> {
        self.db
            .query_row("SELECT v FROM appkv_meta WHERE k = 'account'", [], |row| row.get(0))
            .optional()
            .ok()
            .flatten()
    }

    pub fn set_account(&self, account: &str) -> Result<(), StorageError> {
        self.db
            .execute(
                "INSERT OR REPLACE INTO appkv_meta (k, v) VALUES ('account', ?1)",
                params![account],
            )
            .map(|_| ())
            .map_err(failed)
    }

    /// Another account signed in: every replica and queued write belonged
    /// to the previous one and is dropped (never sent to the new account).
    /// Returns the keys that were visible, per app.
    pub fn reset_synced(&self) -> Changed {
        let mut changed = Changed::new();
        for app in self.replica_apps() {
            if let Ok(Value::Array(keys)) = self.call(&app, "app.storage.keys", &json!({}), true) {
                for key in keys.iter().filter_map(Value::as_str) {
                    mark(&mut changed, &app, key);
                }
            }
            let _ = self.db.execute_batch(&format!("DROP TABLE IF EXISTS {}", replica(&app)));
        }
        let _ = self.db.execute_batch(
            "DELETE FROM appkv_apps; DELETE FROM appkv_outbox; DELETE FROM appkv_rows;",
        );
        changed
    }

    /// Deletes everything the app stored on this device: its local table,
    /// its replica and its queued cloud writes. The cloud rows stay: the
    /// person's other devices may still have the app.
    pub fn clear(&self, app: &str) -> Result<(), StorageError> {
        self.db
            .execute_batch(&format!(
                "DROP TABLE IF EXISTS {}; DROP TABLE IF EXISTS {};",
                table(app),
                replica(app)
            ))
            .map_err(failed)?;
        for statement in [
            "DELETE FROM appkv_outbox WHERE app = ?1",
            "DELETE FROM appkv_rows WHERE app = ?1",
            "DELETE FROM appkv_apps WHERE app = ?1",
        ] {
            self.db.execute(statement, params![app]).map_err(failed)?;
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "storage_tests.rs"]
mod tests;
