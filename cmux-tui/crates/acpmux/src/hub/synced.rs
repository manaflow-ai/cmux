//! Chat state through the sync engine (RFD 0140 build step 3): each chat's title, read mark, pin
//! and unsent draft, as a person sets them here (`_acpmux/rename`, `_acpmux/markRead`,
//! `_acpmux/markUnread`, `_acpmux/pin`, `_acpmux/draft_set`, a sent draft cleared), is also an
//! edit in this daemon's `cmux_sync` replica (an LWW map, keys `title/`, `read/`, `pin/`,
//! `draft/` + chat id), stamped with its hybrid clock. Another replica (the phone, the Mac, a VM)
//! pulls what it lacks with its version vector (`_acpmux/sync/pull`) and pushes its own offline
//! edits (`_acpmux/sync/push`); every pair converges in any order, and a value that wins here is
//! applied to the chat.
//!
//! A winner for a chat this daemon does not hold yet is kept in the replica and its chat id noted
//! as pending (`synced-pending.json`); when the chat comes (read at start, made, forked or moved
//! here) its four keys are applied then, never skipped. A daemon pulls from each peer daemon as
//! the link comes up and pushes what that peer lacks, so edits made while either side was offline
//! cross on reconnect (`exchange`), and a later local edit goes straight to every peer it has
//! exchanged with.
//!
//! Leo, 2026-11-24: "we absolutely need to rfd and stripmine those types of things and other
//! actually incredible feats of engineering and sync-up".
//!
//! The replica is persisted whole beside the store (`synced-state.json`), so offline edits and the
//! replica's actor id survive a restart; a store with no folder (tests, memory) keeps it in memory.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_sync::{Actor, Delta, Replica, Snapshot, Vv};
use serde_json::Value;

use std::sync::Arc;

use super::{Hub, Session};
use crate::protocol::sync::{SyncPullParams, SyncPullResult, SyncPushDone, SyncPushParams};
use crate::rpc::RpcError;

pub type Map = Replica<String, Value>;

const FILE: &str = "synced-state.json";
const PENDING_FILE: &str = "synced-pending.json";
/// Entries one push may carry: a client cannot hand the daemon an unbounded merge.
const MAX_PUSH_ENTRIES: usize = 10_000;

/// A key's meaning, for applying a winning remote edit to the chat it names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Field {
    Title(String),
    Read(String),
    Pin(String),
    Draft(String),
}

impl Field {
    pub fn chat(&self) -> &str {
        match self {
            Field::Title(id) | Field::Read(id) | Field::Pin(id) | Field::Draft(id) => id,
        }
    }
}

pub fn title_key(session: &str) -> String {
    format!("title/{session}")
}

pub fn read_key(session: &str) -> String {
    format!("read/{session}")
}

pub fn pin_key(session: &str) -> String {
    format!("pin/{session}")
}

pub fn draft_key(session: &str) -> String {
    format!("draft/{session}")
}

/// Every key one chat may have, in the order a pending chat applies them.
pub fn chat_keys(session: &str) -> [String; 4] {
    [title_key(session), read_key(session), pin_key(session), draft_key(session)]
}

pub fn field(key: &str) -> Option<Field> {
    let (kind, id) = key.split_once('/')?;
    if id.is_empty() {
        return None;
    }
    let id = id.to_owned();
    match kind {
        "title" => Some(Field::Title(id)),
        "read" => Some(Field::Read(id)),
        "pin" => Some(Field::Pin(id)),
        "draft" => Some(Field::Draft(id)),
        _ => None,
    }
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
    /// Chats a winner came for while this daemon did not hold them: applied when each comes.
    pending: StdMutex<BTreeSet<String>>,
    /// Each peer daemon's vector as of the last exchange with it: a later local edit is pushed
    /// to it from there (`Hub::synced_tell_peers`).
    peers: StdMutex<HashMap<String, Vv>>,
}

impl Synced {
    /// Load the replica at `path`, or start a fresh one (a missing or unreadable file).
    pub fn open(path: Option<PathBuf>) -> Self {
        let map = path
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice::<Snapshot<String, Value>>(&bytes).ok())
            .map_or_else(|| Map::new(new_actor()), Map::restore);
        let pending = path
            .as_deref()
            .and_then(|p| std::fs::read(p.with_file_name(PENDING_FILE)).ok())
            .and_then(|bytes| serde_json::from_slice::<BTreeSet<String>>(&bytes).ok())
            .unwrap_or_default();
        Self {
            map: StdMutex::new(map),
            path,
            save: StdMutex::new(()),
            pending: StdMutex::new(pending),
            peers: StdMutex::new(HashMap::new()),
        }
    }

    fn pending(&self) -> std::sync::MutexGuard<'_, BTreeSet<String>> {
        self.pending.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Note chats `ids` as holding winners this daemon could not apply yet: one save for all.
    pub fn hold(&self, ids: impl IntoIterator<Item = String>) {
        let mut added = false;
        {
            let mut pending = self.pending();
            for id in ids {
                added |= pending.insert(id);
            }
        }
        if added {
            self.persist_pending();
        }
    }

    pub fn held(&self, id: &str) -> bool {
        self.pending().contains(id)
    }

    pub fn held_ids(&self) -> Vec<String> {
        self.pending().iter().cloned().collect()
    }

    /// Chat `id`'s winners were applied: no longer pending.
    pub fn release(&self, id: &str) {
        if self.pending().remove(id) {
            self.persist_pending();
        }
    }

    fn persist_pending(&self) {
        let Some(path) = self.path.as_deref() else { return };
        let _one = self.save.lock().unwrap_or_else(|e| e.into_inner());
        let ids = self.pending().clone();
        let Ok(bytes) = serde_json::to_vec(&ids) else { return };
        let path = path.with_file_name(PENDING_FILE);
        if let Err(e) = write_whole(&path, &bytes) {
            tracing::warn!(error = %e, path = %path.display(), "synced pending chats not saved");
        }
    }

    pub fn vv(&self) -> Vv {
        self.lock().vv().clone()
    }

    /// The delta peer `name` lacks as of its last known vector, if one is known.
    pub fn delta_for_peer(&self, name: &str) -> Option<Delta<String, Value>> {
        let theirs = self.peers.lock().unwrap_or_else(|e| e.into_inner()).get(name).cloned()?;
        let delta = self.lock().delta_since(&theirs);
        Some(delta)
    }

    /// Peer `name` holds at least `vv` now.
    pub fn note_peer(&self, name: &str, vv: Vv) {
        self.peers.lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_owned(), vv);
    }

    pub fn known_peers(&self) -> Vec<String> {
        self.peers.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Map> {
        self.map.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Record a local edit. Writing the value already there is no edit, so applying a remote
    /// winner through the ordinary path does not echo back as a new local one.
    pub fn record(&self, key: String, value: Value) -> bool {
        let wrote = {
            let mut map = self.lock();
            // A cleared value is a delete (a tombstone): on the wire an entry's value is an
            // `Option`, so a JSON null would arrive as a delete anyway.
            if value.is_null() {
                if map.get(&key).is_none() {
                    false
                } else {
                    map.delete(key, wall_ms());
                    true
                }
            } else if map.get(&key) == Some(&value) {
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

    /// The key's last write: `Some(None)` for a delete, `None` when never written.
    pub fn written(&self, key: &str) -> Option<Option<Value>> {
        self.lock().entry(&key.to_owned()).map(|e| e.value.clone())
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

    /// A person renamed, marked, pinned or drafted in a chat here: one edit in the replica, sent
    /// on to every peer daemon this one has exchanged with.
    pub(crate) fn synced_record(&self, key: String, value: Value) {
        if self.synced().record(key, value) {
            self.synced_tell_peers();
        }
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

    /// `_acpmux/sync/push`: merge, then apply each winner to the chat it names on this daemon (a
    /// chat it does not hold yet gets it when it comes, `synced_chat_came`).
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
        let (changed, gap, vv) = self.synced_merge(&delta).await;
        Ok(SyncPushDone { changed, gap, vv: serde_json::to_value(vv).unwrap_or_default() })
    }

    async fn synced_merge(&self, delta: &Delta<String, Value>) -> (Vec<String>, bool, Vv) {
        let (changed, gap, vv) = self.synced().push(delta);
        let mut absent = BTreeSet::new();
        for (key, value) in &changed {
            let Some(field) = field(key) else { continue };
            // A winner for a chat not here yet is kept for it until it comes.
            match self.session_get(field.chat()) {
                Some(session) => self.apply_field(&session, field, value.as_ref()).await,
                None => {
                    absent.insert(field.chat().to_owned());
                }
            }
        }
        self.synced().hold(absent);
        (changed.into_iter().map(|(k, _)| k).collect(), gap, vv)
    }

    async fn apply_field(&self, session: &Arc<Session>, field: Field, value: Option<&Value>) {
        let key = match &field {
            Field::Title(_) => "title",
            Field::Read(_) => "read",
            Field::Pin(_) => "pin",
            Field::Draft(_) => "draft",
        };
        let applied = match (field, value) {
            (Field::Title(_), Some(Value::String(name))) => {
                if session.meta().name == *name || crate::session_name::validate(name).is_err() {
                    return;
                }
                self.rename(session, name.clone()).await
            }
            (Field::Read(_), Some(Value::Bool(true))) => self.mark_read_answered(session),
            (Field::Read(_), Some(Value::Bool(false))) => self.mark_unread_answered(session),
            (Field::Pin(_), Some(Value::Bool(pinned))) => self.set_pinned(session, *pinned),
            (Field::Draft(_), Some(Value::String(text))) => {
                if session.meta().composer_draft.as_deref() == Some(text.as_str()) {
                    return;
                }
                self.set_composer_draft(session, text).map(drop)
            }
            (Field::Draft(_), None | Some(Value::Null)) => {
                if session.meta().composer_draft.is_none() {
                    return;
                }
                self.set_composer_draft(session, "").map(drop)
            }
            _ => return,
        };
        if let Err(e) = applied {
            tracing::debug!(session = %session.id, key, error = ?e, "synced edit not applied to the chat");
        }
    }

    /// `_acpmux/pin`, and a pin that won on another replica: kept in the chat's record and,
    /// when a person set it here, one synced `pin/<id>` edit.
    pub fn set_pinned(&self, session: &Session, pinned: bool) -> Result<(), RpcError> {
        let was = {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            std::mem::replace(&mut meta.pinned, pinned)
        };
        if was != pinned {
            self.events.row_changed(session);
            self.save_meta_answered(session)?;
        }
        self.synced_record(pin_key(&session.id), Value::Bool(pinned));
        Ok(())
    }

    /// Every winner kept for chat `session`, applied now it is here.
    async fn apply_held_chat(&self, session: &Arc<Session>) {
        let synced = self.synced();
        for key in chat_keys(&session.id) {
            // A delete kept for the chat (a cleared draft) is applied too.
            let Some(value) = synced.written(&key) else { continue };
            let Some(field) = field(&key) else { continue };
            self.apply_field(session, field, value.as_ref()).await;
        }
        synced.release(&session.id);
    }

    /// Every pending chat this daemon holds now gets its winners (a start, once its chat logs are
    /// read; a test calls it directly).
    pub async fn synced_apply_pending(&self) {
        for id in self.synced().held_ids() {
            if let Some(session) = self.session_get(&id) {
                self.apply_held_chat(&session).await;
            }
        }
    }

    /// A chat came here (made, forked, moved): winners kept for it are applied.
    pub(super) fn synced_chat_came(&self, id: &str) {
        if self.synced.get().is_none_or(|s| !s.held(id)) {
            return;
        }
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
        let id = id.to_owned();
        rt.spawn(async move {
            if let Some(session) = hub.session_get(&id) {
                hub.apply_held_chat(&session).await;
            }
        });
    }

    /// At start: the chats read from the store get the winners kept for them, once their logs
    /// are read.
    pub(super) fn synced_after_start(self: &Arc<Self>) {
        let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
        let weak = Arc::downgrade(self);
        rt.spawn(async move {
            let Some(hub) = weak.upgrade() else { return };
            if hub.synced().held_ids().is_empty() {
                return;
            }
            hub.wait_logs().await;
            hub.synced_apply_pending().await;
        });
    }

    /// Pull what peer `name` holds that this replica lacks, apply it, then push what it lacks:
    /// edits made on either side while the link was down cross now. `call` sends one request to
    /// the peer (its link, or another hub in a test).
    pub async fn synced_exchange<F, Fut>(&self, name: &str, call: F) -> Result<(), RpcError>
    where
        F: Fn(&'static str, Value) -> Fut,
        Fut: std::future::Future<Output = Result<Value, RpcError>>,
    {
        use crate::rpc::method;
        let ours = self.synced().vv();
        let pulled = call(method::MUX_SYNC_PULL, serde_json::json!({"vv": ours})).await?;
        let pulled: SyncPullResult =
            serde_json::from_value(pulled).map_err(|e| bad("sync/pull answer", e))?;
        let delta: Delta<String, Value> =
            serde_json::from_value(pulled.delta).map_err(|e| bad("delta", e))?;
        let mut theirs: Vv = serde_json::from_value(pulled.vv).map_err(|e| bad("vv", e))?;
        if !delta.entries.is_empty() {
            self.synced_merge(&delta).await;
        }
        let (_, lacking, _) = self.synced().pull(&theirs);
        if !lacking.entries.is_empty() {
            if lacking.entries.len() > MAX_PUSH_ENTRIES {
                tracing::warn!(
                    peer = name,
                    entries = lacking.entries.len(),
                    "synced push too large"
                );
            } else {
                theirs = self.synced_send(&call, &lacking).await?;
            }
        }
        self.synced().note_peer(name, theirs);
        Ok(())
    }

    async fn synced_send<F, Fut>(
        &self,
        call: &F,
        delta: &Delta<String, Value>,
    ) -> Result<Vv, RpcError>
    where
        F: Fn(&'static str, Value) -> Fut,
        Fut: std::future::Future<Output = Result<Value, RpcError>>,
    {
        let done =
            call(crate::rpc::method::MUX_SYNC_PUSH, serde_json::json!({"delta": delta})).await?;
        let done: SyncPushDone =
            serde_json::from_value(done).map_err(|e| bad("sync/push answer", e))?;
        serde_json::from_value(done.vv).map_err(|e| bad("vv", e))
    }

    /// Peer `peer`'s link came up: exchange with it in the background.
    pub(super) fn synced_on_connect(&self, peer: &str, generation: u64) {
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        let Some(link) = self.peer(peer).filter(|p| p.generation == generation) else { return };
        let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
        let name = peer.to_owned();
        rt.spawn(async move {
            let call = |m: &'static str, params: Value| {
                let link = link.clone();
                async move { link.request(m, params).await }
            };
            match hub.synced_exchange(&name, call).await {
                Ok(()) => tracing::debug!(peer = %name, "synced state exchanged"),
                Err(e) => tracing::debug!(peer = %name, error = ?e, "synced state not exchanged"),
            }
        });
    }

    /// A local edit goes on to each peer daemon this one has exchanged with, from the vector it
    /// last knew there.
    fn synced_tell_peers(&self) {
        let synced = self.synced();
        let names = synced.known_peers();
        if names.is_empty() {
            return;
        }
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
        for name in names {
            let Some(link) = self.peer(&name) else { continue };
            let Some(delta) = synced.delta_for_peer(&name) else { continue };
            if delta.entries.is_empty() || delta.entries.len() > MAX_PUSH_ENTRIES {
                continue;
            }
            let hub = hub.clone();
            rt.spawn(async move {
                let call = |m: &'static str, params: Value| {
                    let link = link.clone();
                    async move { link.request(m, params).await }
                };
                match hub.synced_send(&call, &delta).await {
                    Ok(vv) => hub.synced().note_peer(&name, vv),
                    Err(e) => tracing::debug!(peer = %name, error = ?e, "synced edit not sent"),
                }
            });
        }
    }
}

#[cfg(test)]
#[path = "synced_tests.rs"]
mod tests;
