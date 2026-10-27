//! Per-app local KV storage (`app.storage.*`): SQLite, one table per app.
//! The supervisor owns it (plan section 7); uninstall drops the table in the
//! same commit that clears the install record.
//!
//! Every entry point is the connection's checked scope (Chrome's
//! `ScopedBlockingCall`): it notes `sqlite` at its caller, so a thread that
//! disallows blocking records (or, in `CMUX_DAEMON_BLOCKING=panic`, panics
//! at) the code that asked for the storage. The supervisor's lock in front
//! of the connection is timed and named (`Supervisor::storage`).

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};

use crate::request_path::{BlockingKind, note};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

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
    /// Opens (or creates) the database; `None` opens an in-memory one. An
    /// unreadable file is set aside and the storage starts empty
    /// (`sqlite_policy`).
    #[track_caller]
    pub fn open(path: Option<&Path>) -> Result<Self, StorageError> {
        Self::open_with_faults(path, &crate::sqlite_policy::LoggedFaults)
    }

    /// `open`, reporting an unreadable file set aside to `faults`.
    #[track_caller]
    pub(crate) fn open_with_faults(
        path: Option<&Path>,
        faults: &dyn crate::sqlite_policy::SqliteFaults,
    ) -> Result<Self, StorageError> {
        note(BlockingKind::Sqlite);
        let db = match path {
            Some(path) => {
                crate::sqlite_policy::open_own_store("apps_storage", path, faults, |path| {
                    Ok(Self::prepare(Connection::open(path)?)?)
                })
            }
            None => {
                Connection::open_in_memory().and_then(Self::prepare).map_err(anyhow::Error::from)
            }
        }
        .map_err(|error| failed(format!("{error:#}")))?;
        Ok(Self { db })
    }

    fn prepare(db: Connection) -> rusqlite::Result<Connection> {
        db.busy_timeout(crate::sqlite_policy::BUSY_TIMEOUT)?;
        crate::sqlite_policy::probe(&db)?;
        db.pragma_update(None, "journal_mode", "WAL").ok();
        Ok(db)
    }

    fn ensure(&self, app: &str) -> Result<String, StorageError> {
        let table = table(app);
        self.db
            .execute_batch(&format!("CREATE TABLE IF NOT EXISTS {table} (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"))
            .map_err(failed)?;
        Ok(table)
    }

    /// Runs one `app.storage.*` op and returns its value.
    #[track_caller]
    pub fn call(&self, app: &str, op: &str, params: &Value) -> Result<Value, StorageError> {
        note(BlockingKind::Sqlite);
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
    #[track_caller]
    pub fn clear(&self, app: &str) -> Result<(), StorageError> {
        note(BlockingKind::Sqlite);
        self.db.execute_batch(&format!("DROP TABLE IF EXISTS {}", table(app))).map_err(failed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_get_keys_delete_and_clear_are_per_app() {
        let s = Storage::open(None).unwrap();
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

    /// A storage op on a thread that disallows blocking is recorded at the
    /// op's caller; the same op on an ordinary thread records nothing.
    #[test]
    fn a_disallowed_storage_op_records_one_sqlite_site_at_its_caller() {
        use cmux_threads::blocking::{
            BlockingKind as ThreadsKind, BlockingMode, disallow_blocking, set_mode, snapshot,
        };
        set_mode(BlockingMode::Record);
        let s = Storage::open(None).unwrap();
        let (disallowed, allowed) = std::thread::spawn(move || {
            let allowed = line!() + 1;
            s.call("cmux/a", "app.storage.keys", &json!({})).unwrap();
            disallow_blocking();
            let disallowed = line!() + 1;
            s.call("cmux/a", "app.storage.keys", &json!({})).unwrap();
            (disallowed, allowed)
        })
        .join()
        .unwrap();
        let snapshot = snapshot();
        let site = snapshot.site(file!(), disallowed).expect("the op's caller is recorded");
        assert_eq!(site.count, 1);
        assert!(site.kinds.contains(ThreadsKind::Sqlite));
        assert_eq!(snapshot.site(file!(), allowed), None);
    }

    #[test]
    fn a_garbage_file_opens_as_empty_storage_with_one_fault() {
        let dir = crate::sqlite_policy::TestDir::new();
        let path = dir.path().join("apps-storage.sqlite");
        std::fs::write(&path, vec![0xa5_u8; 8192]).unwrap();
        let faults = crate::sqlite_policy::RecordedFaults::default();

        let s = Storage::open_with_faults(Some(&path), &faults).unwrap();

        s.call("cmux/a", "app.storage.set", &json!({ "key": "k", "value": 1 })).unwrap();
        assert_eq!(s.call("cmux/a", "app.storage.get", &json!({ "key": "k" })).unwrap(), json!(1));
        let events = faults.taken();
        assert_eq!(events.len(), 1, "{events:?}");
        assert_eq!(events[0].store, "apps_storage");
        assert_eq!(std::fs::read(&events[0].aside).unwrap(), vec![0xa5_u8; 8192]);
        drop(s);
        // The new file is a good store: the next open reports nothing.
        drop(Storage::open_with_faults(Some(&path), &faults).unwrap());
        assert!(faults.taken().is_empty());
    }

    #[test]
    fn limits_are_enforced() {
        let s = Storage::open(None).unwrap();
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
}
