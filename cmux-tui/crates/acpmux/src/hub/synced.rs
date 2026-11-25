//! Chat state through the sync engine (RFD 0140 build step 3): each chat's title and read mark,
//! as a person sets them here (`_acpmux/rename`, `_acpmux/markRead`, `_acpmux/markUnread`), is
//! also an edit in this daemon's `cmux_sync` replica, stamped with its hybrid clock. Another
//! replica (the phone, the Mac, a VM) pulls what it lacks with its version vector
//! (`_acpmux/sync/pull`) and pushes its own offline edits (`_acpmux/sync/push`); every pair
//! converges in any order, and a title or read mark that wins here is applied to the chat.
//!
//! Leo, 2026-11-24: "we absolutely need to rfd and stripmine those types of things and other
//! actually incredible feats of engineering and sync-up".
//!
//! The replica is persisted whole beside the store (`synced-state.json`), so offline edits and the
//! replica's actor id survive a restart; a store with no folder (tests, memory) keeps it in memory.

use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_sync::{Actor, Delta, Replica, Snapshot, Vv};
use serde_json::Value;

use super::Hub;
use crate::protocol::sync::{SyncPullParams, SyncPullResult, SyncPushDone, SyncPushParams};
use crate::rpc::RpcError;

pub type Map = Replica<String, Value>;

const FILE: &str = "synced-state.json";
/// Entries one push may carry: a client cannot hand the daemon an unbounded merge.
const MAX_PUSH_ENTRIES: usize = 10_000;

/// A key's meaning, for applying a winning remote edit to the chat it names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Field {
    Title(String),
    Read(String),
}

pub fn title_key(session: &str) -> String {
    format!("title/{session}")
}

pub fn read_key(session: &str) -> String {
    format!("read/{session}")
}

pub fn field(key: &str) -> Option<Field> {
    if let Some(id) = key.strip_prefix("title/") {
        return Some(Field::Title(id.to_owned()));
    }
    key.strip_prefix("read/").map(|id| Field::Read(id.to_owned()))
}

fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn new_actor() -> Actor {
    let id = uuid::Uuid::now_v7().simple().to_string();
    Actor::new(format!("daemon-{}-{}", crate::pairing::machine_name(), &id[id.len() - 12..]))
}

/// The replica and where it is kept.
pub struct Synced {
    map: StdMutex<Map>,
    path: Option<PathBuf>,
    /// One save at a time, each of the newest state, so an older snapshot never lands last.
    save: StdMutex<()>,
}

impl Synced {
    /// Load the replica at `path`, or start a fresh one (a missing or unreadable file).
    pub fn open(path: Option<PathBuf>) -> Self {
        let map = path
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice::<Snapshot<String, Value>>(&bytes).ok())
            .map_or_else(|| Map::new(new_actor()), Map::restore);
        Self { map: StdMutex::new(map), path, save: StdMutex::new(()) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Map> {
        self.map.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Record a local edit. Writing the value already there is no edit, so applying a remote
    /// winner through the ordinary path does not echo back as a new local one.
    pub fn record(&self, key: String, value: Value) -> bool {
        let wrote = {
            let mut map = self.lock();
            if map.get(&key) == Some(&value) {
                false
            } else {
                map.set(key, value, wall_ms());
                true
            }
        };
        if wrote {
            self.persist();
        }
        wrote
    }

    pub fn pull(&self, theirs: &Vv) -> (String, Delta<String, Value>, Vv) {
        let map = self.lock();
        (map.actor().0.clone(), map.delta_since(theirs), map.vv().clone())
    }

    /// Merge a delta; returns the changed keys with their winning values (None: deleted), whether
    /// a gap is left to pull, and the vector after.
    pub fn push(&self, delta: &Delta<String, Value>) -> (Vec<(String, Option<Value>)>, bool, Vv) {
        let (changed, gap, vv) = {
            let mut map = self.lock();
            let applied = map.apply(delta, wall_ms());
            let changed = applied
                .changed
                .into_iter()
                .map(|k| {
                    let v = map.get(&k).cloned();
                    (k, v)
                })
                .collect::<Vec<_>>();
            (changed, applied.gap, map.vv().clone())
        };
        if !changed.is_empty() || !gap {
            self.persist();
        }
        (changed, gap, vv)
    }

    pub fn get(&self, key: &str) -> Option<Value> {
        self.lock().get(&key.to_owned()).cloned()
    }

    fn persist(&self) {
        let Some(path) = self.path.as_deref() else { return };
        let _one = self.save.lock().unwrap_or_else(|e| e.into_inner());
        let snapshot = self.lock().snapshot();
        let Ok(bytes) = serde_json::to_vec(&snapshot) else { return };
        if let Err(e) = write_whole(path, &bytes) {
            tracing::warn!(error = %e, path = %path.display(), "synced state not saved");
        }
    }
}

/// Write through a temporary file in the same folder, synced, then renamed into place.
fn write_whole(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let tmp = path.with_extension("json.tmp");
    let mut file = std::fs::File::create(&tmp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&tmp, path)
}

fn bad(what: &str, e: impl std::fmt::Display) -> RpcError {
    RpcError::invalid_params(format!("{what}: {e}"))
}

impl Hub {
    /// The replica, opened on first use beside the store.
    pub fn synced(&self) -> &Synced {
        self.synced.get_or_init(|| {
            // `<home>/sessions/_` -> `<home>`: beside the sessions folder, never inside it.
            let root = self
                .store
                .session_path("_")
                .and_then(|p| p.parent().and_then(Path::parent).map(Path::to_path_buf));
            Synced::open(root.map(|r| r.join(FILE)))
        })
    }

    /// A person renamed a chat or marked it read or unread here: one edit in the replica.
    pub(crate) fn synced_record(&self, key: String, value: Value) {
        self.synced().record(key, value);
    }

    /// `_acpmux/sync/pull`.
    pub fn sync_pull(&self, params: &Value) -> Result<SyncPullResult, RpcError> {
        let p: SyncPullParams =
            serde_json::from_value(params.clone()).map_err(|e| bad("_acpmux/sync/pull", e))?;
        let theirs: Vv = match p.vv {
            None | Some(Value::Null) => Vv::new(),
            Some(v) => serde_json::from_value(v).map_err(|e| bad("vv", e))?,
        };
        let (actor, delta, vv) = self.synced().pull(&theirs);
        Ok(SyncPullResult {
            actor,
            delta: serde_json::to_value(delta).unwrap_or_default(),
            vv: serde_json::to_value(vv).unwrap_or_default(),
        })
    }

    /// `_acpmux/sync/push`: merge, then apply each winning title or read mark to the chat it
    /// names on this daemon (a chat it does not hold is only kept in the replica, for the next
    /// replica that pulls).
    pub async fn sync_push(&self, params: &Value) -> Result<SyncPushDone, RpcError> {
        let p: SyncPushParams =
            serde_json::from_value(params.clone()).map_err(|e| bad("_acpmux/sync/push", e))?;
        let delta: Delta<String, Value> =
            serde_json::from_value(p.delta).map_err(|e| bad("delta", e))?;
        if delta.entries.len() > MAX_PUSH_ENTRIES {
            return Err(RpcError::invalid_params(format!(
                "a push carries at most {MAX_PUSH_ENTRIES} entries"
            ))
            .with_data(serde_json::json!({"reason": "sync.too_large"})));
        }
        let (changed, gap, vv) = self.synced().push(&delta);
        for (key, value) in &changed {
            self.apply_synced(key, value.as_ref()).await;
        }
        Ok(SyncPushDone {
            changed: changed.into_iter().map(|(k, _)| k).collect(),
            gap,
            vv: serde_json::to_value(vv).unwrap_or_default(),
        })
    }

    async fn apply_synced(&self, key: &str, value: Option<&Value>) {
        let Some(field) = field(key) else { return };
        let id = match &field {
            Field::Title(id) | Field::Read(id) => id,
        };
        let Some(session) = self.session_handles().into_iter().find(|s| s.id == *id) else {
            return;
        };
        let applied = match (field, value) {
            (Field::Title(_), Some(Value::String(name))) => {
                if session.meta().name == *name || crate::session_name::validate(name).is_err() {
                    return;
                }
                self.rename(&session, name.clone()).await
            }
            (Field::Read(_), Some(Value::Bool(true))) => self.mark_read_answered(&session),
            (Field::Read(_), Some(Value::Bool(false))) => self.mark_unread_answered(&session),
            _ => return,
        };
        if let Err(e) = applied {
            tracing::debug!(key, error = ?e, "synced edit not applied to the chat");
        }
    }
}

#[cfg(test)]
#[path = "synced_tests.rs"]
mod tests;
