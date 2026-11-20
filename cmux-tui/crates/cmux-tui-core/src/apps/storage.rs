//! Per-app local KV storage (`app.storage.*`): SQLite, one table per app.
//! The supervisor owns it (plan section 7); uninstall drops the table in the
//! same commit that clears the install record.

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::workspace_registry::wal_durability::{self, OwnerRelease};

pub const MAX_KEY_BYTES: usize = 256;
pub const MAX_VALUE_BYTES: usize = 64 * 1024;
pub const MAX_APP_BYTES: i64 = 4 * 1024 * 1024;

pub struct Storage {
    db: Connection,
}

/// An error answered to the app (`{code, message}`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageError {
    pub code: &'static str,
    pub message: String,
}

fn failed(error: impl std::fmt::Display) -> StorageError {
    StorageError { code: "operation.failed", message: error.to_string() }
}

fn invalid(message: &str) -> StorageError {
    StorageError { code: "validation.invalid", message: message.to_string() }
}

/// `kv_<first 16 hex of sha256(app id)>`: app ids never reach SQL text.
fn table(app: &str) -> String {
    let digest = Sha256::digest(app.as_bytes());
    format!("kv_{}", digest.iter().take(8).map(|b| format!("{b:02x}")).collect::<String>())
}

impl Storage {
    /// Opens (or creates) the database; `None` opens an in-memory one.
    ///
    /// A database on disk is a store of the session folder, so it opens the
    /// one way such a store opens: after the release of the session's owner
    /// (`released`) each commit of it is refused.
    pub(crate) fn open(path: Option<&Path>, released: &OwnerRelease) -> Result<Self, StorageError> {
        let db = match path {
            Some(path) => wal_durability::open_store(path, "apps storage", released)
                .map_err(|error| failed(format!("{error:#}")))?,
            None => Connection::open_in_memory().map_err(failed)?,
        };
        db.pragma_update(None, "journal_mode", "WAL").ok();
        Ok(Self { db })
    }

    fn ensure(&self, app: &str) -> Result<String, StorageError> {
        let table = table(app);
        self.db
            .execute_batch(&format!("CREATE TABLE IF NOT EXISTS {table} (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"))
            .map_err(failed)?;
        Ok(table)
    }

    /// Runs one `app.storage.*` op and returns its value.
    pub fn call(&self, app: &str, op: &str, params: &Value) -> Result<Value, StorageError> {
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
        let table = self.ensure(app)?;
        match op {
            "app.storage.get" => {
                let raw: Option<String> = self
                    .db
                    .query_row(
                        &format!("SELECT value FROM {table} WHERE key = ?1"),
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
                    .query_row(&format!("SELECT COALESCE(SUM(LENGTH(CAST(key AS BLOB)) + LENGTH(CAST(value AS BLOB))), 0) FROM {table} WHERE key != ?1"), params![key], |row| row.get(0))
                    .map_err(failed)?;
                if used + (key.len() + value.len()) as i64 > MAX_APP_BYTES {
                    return Err(StorageError {
                        code: "app.limit",
                        message: "the app's storage is full (4 MiB)".into(),
                    });
                }
                self.db
                    .execute(&format!("INSERT INTO {table} (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value"), params![key, value])
                    .map_err(failed)?;
                Ok(Value::Null)
            }
            "app.storage.delete" => {
                self.db
                    .execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![key()?])
                    .map_err(failed)?;
                Ok(Value::Null)
            }
            "app.storage.keys" => {
                let mut statement = self
                    .db
                    .prepare(&format!("SELECT key FROM {table} ORDER BY key"))
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

    /// Deletes everything the app stored.
    pub fn clear(&self, app: &str) -> Result<(), StorageError> {
        self.db.execute_batch(&format!("DROP TABLE IF EXISTS {}", table(app))).map_err(failed)
    }
}

impl super::supervisor::Supervisor {
    /// The storage database, opened on first use. Lock order: `inner`, then
    /// `storage`.
    pub(super) fn storage(&self) -> std::sync::MutexGuard<'_, Option<Storage>> {
        let mut guard = self.storage.lock().unwrap();
        if guard.is_none() {
            let path = self.config.state_dir.as_ref().map(|d| d.join("apps-storage.sqlite"));
            *guard = Storage::open(path.as_deref(), &self.config.owner_release).ok();
        }
        guard
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_get_keys_delete_and_clear_are_per_app() {
        let s = Storage::open(None, &OwnerRelease::default()).unwrap();
        s.call("cmux/a", "app.storage.set", &json!({ "key": "k", "value": { "n": 1 } })).unwrap();
        s.call("cmux/b", "app.storage.set", &json!({ "key": "k", "value": 2 })).unwrap();
        assert_eq!(
            s.call("cmux/a", "app.storage.get", &json!({ "key": "k" })).unwrap(),
            json!({ "n": 1 })
        );
        assert_eq!(s.call("cmux/a", "app.storage.keys", &json!({})).unwrap(), json!(["k"]));
        s.clear("cmux/a").unwrap();
        assert_eq!(
            s.call("cmux/a", "app.storage.get", &json!({ "key": "k" })).unwrap(),
            Value::Null
        );
        assert_eq!(s.call("cmux/b", "app.storage.get", &json!({ "key": "k" })).unwrap(), json!(2));
        s.call("cmux/b", "app.storage.delete", &json!({ "key": "k" })).unwrap();
        assert_eq!(s.call("cmux/b", "app.storage.keys", &json!({})).unwrap(), json!([]));
    }

    #[test]
    fn limits_are_enforced() {
        let s = Storage::open(None, &OwnerRelease::default()).unwrap();
        let big = "x".repeat(MAX_VALUE_BYTES);
        assert_eq!(
            s.call("a", "app.storage.set", &json!({ "key": "k", "value": big })).unwrap_err().code,
            "app.limit"
        );
        assert_eq!(
            s.call("a", "app.storage.get", &json!({ "key": "" })).unwrap_err().code,
            "validation.invalid"
        );
    }

    /// An owner that released its session writes no store of it. The apps'
    /// storage is a database of the session
    /// folder: after the release the next owner has it, so a `set` of the
    /// owner before is refused and the database keeps its keys.
    ///
    /// The row takes the owner's own supervisor and makes the two last calls
    /// of an app's write path (`calls.rs`): the supervisor's storage, then
    /// the op. An app's whole request needs an installed app with a host
    /// process: that is not in the row.
    #[test]
    fn a_set_after_the_session_release_of_its_owner_is_refused() {
        const APP: &str = "cmux/a";
        let root = std::env::temp_dir().join(format!(
            "cmux-apps-storage-release-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let session = "apps-storage-release";
        let options = crate::SurfaceOptions {
            terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(
                &root, session,
            )),
            ..crate::SurfaceOptions::default()
        };
        let mux = crate::Mux::open_persistent(session, options, &root).unwrap();
        let folder = mux.session_state_directory().expect("a session on disk has its folder");
        let supervisor = mux.control_clients.apps().get_or_init(&mux);
        let set = |key: &str| {
            let params = json!({ "key": key, "value": 1 });
            supervisor
                .storage()
                .as_ref()
                .map(|storage| storage.call(APP, "app.storage.set", &params))
        };
        let before = set("before");
        let on_disk = folder.join("apps-storage.sqlite").exists();
        mux.shutdown();
        let release = format!("{:?}", mux.release_ownership(&root.join("control.sock")));
        let after = set("after");
        let keys = supervisor
            .storage()
            .as_ref()
            .map(|storage| storage.call(APP, "app.storage.keys", &json!({})));
        drop(supervisor);
        drop(mux);
        crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(
            before,
            Some(Ok(Value::Null)),
            "setup: the owner's `set` before its stop did not store the key"
        );
        assert!(on_disk, "setup: the apps' storage is not a file of the session folder");
        assert_eq!(
            release, "Released",
            "setup: an owner whose threads all ended did not give its session up"
        );
        assert_eq!(
            after.map(|said| said.map_err(|error| error.code)),
            Some(Err("operation.failed")),
            "after its release returned, a `set` of the owner was not refused: the apps' \
             storage is a database of the session, which the next owner has from then on"
        );
        assert_eq!(
            keys,
            Some(Ok(json!(["before"]))),
            "the apps' storage does not have the keys that it had when the release returned"
        );
    }
}
