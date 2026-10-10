//! Per-app local KV storage (`app.storage.*`): SQLite, one table per app.
//! The supervisor owns it (plan section 7); uninstall drops the table in the
//! same commit that clears the install record.

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
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
    /// Opens (or creates) the database; `None` opens an in-memory one.
    pub fn open(path: Option<&Path>) -> Result<Self, StorageError> {
        let db = match path {
            Some(path) => Connection::open(path),
            None => Connection::open_in_memory(),
        }
        .map_err(failed)?;
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
