//! The topology state the packed journal states so far, for the journal
//! compaction (`journal_compact.rs`): one hash per live `(resource, id)`.

use std::collections::HashMap;

use rusqlite::{Connection, params};
use serde_json::Value;
use sha2::{Digest, Sha256};

/// A `(resource, id)` of a resource change.
pub(super) type StatedKey = (String, String);
/// The hash of a stated value ([`value_hash`]).
pub(super) type StatedHash = [u8; 32];
/// What a run of records changes in the fold, not yet committed: `None`
/// removes the key (a `delete`).
pub(super) type FoldDelta = HashMap<StatedKey, Option<StatedHash>>;

/// The fold's table in the staging file. A row is one live resource; the
/// pack commits its changes in the transaction of the segment that holds
/// the records, so a resumed pack reads the fold of exactly the packed
/// journal.
pub(super) const STATED_FOLD_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS output_cleanup_stated (
       resource TEXT NOT NULL,
       id TEXT NOT NULL,
       hash BLOB NOT NULL,
       PRIMARY KEY(resource, id)
     ) WITHOUT ROWID;";

/// The value each tracked `(resource, id)` has after the records packed so
/// far, as the journal checkpoint reducer and the public fold apply them
/// (`upsert` sets, `delete` removes). It holds a SHA-256 of each value, not
/// the value: a session of 826 workspaces states 5,713 resources, and one
/// value can be kilobytes.
pub(super) struct StatedFold {
    values: HashMap<StatedKey, StatedHash>,
}

impl StatedFold {
    /// The fold `staging` holds: the state after its last packed segment.
    pub(super) fn load(staging: &Connection) -> anyhow::Result<Self> {
        staging.execute_batch(STATED_FOLD_SCHEMA)?;
        let mut statement =
            staging.prepare("SELECT resource, id, hash FROM main.output_cleanup_stated")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, Vec<u8>>(2)?))
        })?;
        let mut values = HashMap::new();
        for row in rows {
            let (resource, id, hash) = row?;
            let hash = StatedHash::try_from(hash.as_slice()).map_err(|_| {
                anyhow::anyhow!("a stated value hash of {resource} {id} is invalid")
            })?;
            values.insert((resource, id), hash);
        }
        Ok(Self { values })
    }

    /// The hash of the value stated for `key`, with `pending` (the records
    /// of the open segment) applied over the committed fold.
    pub(super) fn stated(&self, pending: &FoldDelta, key: &StatedKey) -> Option<StatedHash> {
        match pending.get(key) {
            Some(pending) => *pending,
            None => self.values.get(key).copied(),
        }
    }

    /// Applies `delta` and writes it through `transaction` (the staging
    /// transaction of the segment whose records made it).
    pub(super) fn commit(
        &mut self,
        transaction: &Connection,
        delta: FoldDelta,
    ) -> anyhow::Result<()> {
        let mut upsert = transaction.prepare_cached(
            "INSERT INTO main.output_cleanup_stated(resource, id, hash) VALUES(?1, ?2, ?3)
             ON CONFLICT(resource, id) DO UPDATE SET hash = excluded.hash",
        )?;
        let mut delete = transaction.prepare_cached(
            "DELETE FROM main.output_cleanup_stated WHERE resource = ?1 AND id = ?2",
        )?;
        for (key, hash) in delta {
            match hash {
                Some(hash) => {
                    upsert.execute(params![key.0, key.1, hash.as_slice()])?;
                    self.values.insert(key, hash);
                }
                None => {
                    delete.execute(params![key.0, key.1])?;
                    self.values.remove(&key);
                }
            }
        }
        Ok(())
    }
}

/// A SHA-256 of `value` that is equal exactly when two values are equal as
/// the journal's readers compare them (`serde_json::Value` equality: object
/// keys in any order), except numbers, which are equal here only when they
/// are written the same (`1` and `1.0` differ). A differing hash only keeps
/// an upsert the journal could have dropped.
pub(super) fn value_hash(value: &Value) -> StatedHash {
    let mut hasher = Sha256::new();
    hash_into(&mut hasher, value);
    hasher.finalize().into()
}

fn hash_bytes(hasher: &mut Sha256, tag: u8, bytes: &[u8]) {
    hasher.update([tag]);
    hasher.update((bytes.len() as u64).to_le_bytes());
    hasher.update(bytes);
}

fn hash_into(hasher: &mut Sha256, value: &Value) {
    match value {
        Value::Null => hasher.update([b'n']),
        Value::Bool(true) => hasher.update([b't']),
        Value::Bool(false) => hasher.update([b'f']),
        Value::Number(number) => hash_bytes(hasher, b'd', number.to_string().as_bytes()),
        Value::String(text) => hash_bytes(hasher, b's', text.as_bytes()),
        Value::Array(items) => {
            hasher.update([b'a']);
            hasher.update((items.len() as u64).to_le_bytes());
            for item in items {
                hash_into(hasher, item);
            }
        }
        Value::Object(fields) => {
            hasher.update([b'o']);
            hasher.update((fields.len() as u64).to_le_bytes());
            let mut fields = fields.iter().collect::<Vec<_>>();
            fields.sort_unstable_by(|a, b| a.0.cmp(b.0));
            for (name, field) in fields {
                hash_bytes(hasher, b'k', name.as_bytes());
                hash_into(hasher, field);
            }
        }
    }
}
