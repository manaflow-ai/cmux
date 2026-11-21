//! Part of `Hub`; see `hub/mod.rs`. The sessions' half of the chats' activity view
//! (`chats/activity.rs`): what a chat's live acpmux session needs from the person and its latest
//! reply, read from the session, and the hub's cache of the closed sessions' part. Moved from
//! `chats/activity.rs`: it reads sessions and the hub, which `chats` (a lower module) does not
//! reach.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cmux_chat_index::{AdapterKind, ChatKey};
use serde_json::{Value, json};

use super::{Hub, Session};
use crate::chats::activity::Newest;
use crate::chats::{ChatActivity, SeqChange, key_text};
use crate::store::SessionStatus;
use cmux_json::JsonSet as _;

#[cfg(test)]
#[path = "chat_activity_tests.rs"]
mod tests;

// Every scale test reads Linux process counters (cfg target_os = "linux").
#[cfg(all(test, target_os = "linux"))]
#[path = "chat_activity_scale_tests.rs"]
mod scale_tests;

/// The longest preview sent, in characters: one sidebar line and some.
const PREVIEW_CHARS: usize = 160;

/// The indexed chat a session continues: the store of its profile's family
/// and the agent's session id. Only adoptable families have one.
pub fn session_chat_key(session: &Session) -> Option<ChatKey> {
    session.read_meta(|meta| {
        let harness = match meta.family.as_deref()? {
            "claude" => AdapterKind::ClaudeCode,
            "codex" => AdapterKind::Codex,
            _ => return None,
        };
        Some(ChatKey { harness, session_id: meta.agent_session_id.clone()? })
    })
}

/// What the session needs from the person, most urgent first; None while
/// it needs nothing (idle, working, or closed).
pub fn attention(session: &Session) -> Option<&'static str> {
    let (status, failed, unread) = session.read_meta(|meta| {
        (
            meta.status,
            meta.last_turn.as_ref().and_then(|t| t.get("status")).and_then(Value::as_str)
                == Some("failed"),
            meta.unread,
        )
    });
    match status {
        SessionStatus::Closed => return None,
        SessionStatus::Waiting => return Some("needsInput"),
        _ if session.has_pending_permissions() => return Some("needsInput"),
        // An open sub-session below it asks: the run stalls there (`hub/asks_below.rs`).
        _ if session.waits_below() => return Some("needsInput"),
        SessionStatus::Running => return None,
        _ => {}
    }
    if failed {
        Some("failed")
    } else if unread {
        Some("unread")
    } else {
        None
    }
}

/// The `attention` and `preview` fields of a session's chat.
pub fn activity_fields(session: &Session) -> Value {
    let preview = session.read_meta(|meta| {
        meta.preview.as_deref().filter(|p| !p.trim().is_empty()).map(|p| {
            let line = p.split_whitespace().collect::<Vec<_>>().join(" ");
            line.chars().take(PREVIEW_CHARS).collect::<String>()
        })
    });
    json!({"attention": attention(session), "preview": preview})
}

/// The `_acpmux/chat_changed` params of a session's chat activity, when the
/// session continues an indexable chat.
pub fn activity_change(hub: &Hub, session: &Session) -> Option<Value> {
    let key = session_chat_key(session)?;
    let mut change = hub.chat_activity_fields(session);
    change.set("kind", json!("activity"));
    change.set("key", json!(key_text(&key)));
    Some(change)
}

/// The closed sessions' chat activity, shared by every reader (each chats watcher on each change
/// batch, each window refresh, each page): with thousands of closed sessions, rebuilding it per
/// reader took every session's locks once per watcher per batch. A closed session's fields
/// change only with an activity record of its own, a `tags` or `purged` record (a parent's tags
/// decide whether it is listed), the session map changing, or a tag expiring; each of those makes
/// the next read build it again.
#[derive(Default)]
pub struct ActivityCache {
    /// Moves on with each change above.
    epoch: AtomicU64,
    /// Moves on with every activity record: a batch's activity is shared while it stays.
    records: AtomicU64,
    built: Mutex<Option<Arc<Built>>>,
    /// One build at a time: the others wait for it instead of repeating it.
    building: Mutex<()>,
    /// The last change batch's activity, for the next watcher of the same batch.
    batch: Mutex<Option<SharedBatch>>,
    #[cfg(test)]
    builds: AtomicU64,
    #[cfg(test)]
    build_pause: Mutex<Option<BuildPause>>,
}

/// A change batch, the counts its activity was read at, and that activity.
type SharedBatch = (Arc<Vec<SeqChange>>, (u64, u64, usize), Option<u64>, Arc<ChatActivity>);

#[cfg(test)]
struct BuildPause {
    entered: std::sync::mpsc::Sender<()>,
    release: std::sync::mpsc::Receiver<()>,
}

struct Built {
    /// The epoch and session count it was built at, and when its first tag expires.
    epoch: u64,
    sessions: usize,
    expires_at: Option<u64>,
    closed: Arc<HashMap<String, Newest>>,
    closed_ids: HashSet<String>,
    /// The sessions that were not closed: read again on every build of a `ChatActivity`.
    live: Vec<Arc<Session>>,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl ActivityCache {
    #[cfg(test)]
    pub(crate) fn test_builds(&self) -> u64 {
        self.builds.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(crate) fn test_reset_builds(&self) {
        self.builds.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(crate) fn test_pause_next_build(
        &self,
        entered: std::sync::mpsc::Sender<()>,
        release: std::sync::mpsc::Receiver<()>,
    ) {
        *lock(&self.build_pause) = Some(BuildPause { entered, release });
    }

    #[cfg(test)]
    pub(crate) fn test_cached_closed(&self, id: &str) -> bool {
        lock(&self.built).as_ref().is_some_and(|built| built.closed_ids.contains(id))
    }

    /// A mux record of `kind` was appended to session `id` (`closed`: the session is closed now).
    pub(crate) fn note(&self, id: &str, kind: &str, closed: bool) {
        self.records.fetch_add(1, Ordering::SeqCst);
        let stale = closed
            || matches!(kind, "tags" | "purged")
            || lock(&self.built).as_ref().is_some_and(|built| built.closed_ids.contains(id));
        if stale {
            self.invalidate();
        }
    }

    /// The session map lost or replaced a session.
    pub(crate) fn invalidate(&self) {
        self.epoch.fetch_add(1, Ordering::SeqCst);
    }
}

impl Hub {
    /// A chat's `attention` and `preview`, and `parent`: the chat of the session that started
    /// this one (`Hub::spawned_by`; its chat key, else its session id), so lists fold it under
    /// that chat instead of listing it on its own (Leo 2026-10-13). Null for a chat nobody started.
    pub fn chat_activity_fields(&self, session: &Session) -> Value {
        let mut fields = activity_fields(session);
        let parent = self.spawned_by_session(session).map(|parent| match self.resolve(&parent) {
            Ok(parent_session) => {
                session_chat_key(&parent_session).map_or(parent, |key| key_text(&key))
            }
            Err(_) => parent,
        });
        fields.set("parent", json!(parent));
        fields
    }

    /// Every session's chat activity; the newest session wins a chat two sessions continue.
    /// The closed sessions' part comes from `ActivityCache`; only the live sessions are read.
    pub fn chat_activity(&self) -> Arc<ChatActivity> {
        self.chat_activity_with_expiry().0
    }

    fn chat_activity_with_expiry(&self) -> (Arc<ChatActivity>, Option<u64>) {
        let built = self.closed_chat_activity();
        (
            Arc::new(ChatActivity::new(
                built.closed.clone(),
                self.newest(&built.live),
                built.expires_at,
            )),
            built.expires_at,
        )
    }

    /// `chat_activity` for one index change batch: every chats watcher of the batch shares one,
    /// unless an activity record or a session came or went meanwhile.
    pub fn chat_activity_for_batch(&self, batch: &Arc<Vec<SeqChange>>) -> Arc<ChatActivity> {
        let cache = &self.chat_activity_cache;
        // One bounded computation: a mutation during it makes this value uncached, and its own
        // follow-up notification drives the next watcher to compute the newer value.
        let seen = self.activity_version();
        {
            let shared = lock(&cache.batch);
            if let Some((same_batch, at, expires_at, activity)) = shared.as_ref()
                && Arc::ptr_eq(same_batch, batch)
                && *at == seen
                && expires_at.is_none_or(|at| at > crate::store::now_ms())
            {
                return activity.clone();
            }
        }
        let (activity, expires_at) = self.chat_activity_with_expiry();
        let now = self.activity_version();
        if now == seen {
            let mut shared = lock(&cache.batch);
            // Do not overwrite a result published by a newer reader that raced this call.
            let newer = shared.as_ref().is_some_and(|(_, at, _, _)| *at > seen);
            if !newer {
                *shared = Some((batch.clone(), seen, expires_at, activity.clone()));
            }
        }
        activity
    }

    fn activity_version(&self) -> (u64, u64, usize) {
        (
            self.chat_activity_cache.records.load(Ordering::SeqCst),
            self.chat_activity_cache.epoch.load(Ordering::SeqCst),
            self.session_count(),
        )
    }

    fn closed_chat_activity(&self) -> Arc<Built> {
        let cache = &self.chat_activity_cache;
        let current = || {
            let built = lock(&cache.built).clone()?;
            let fresh = built.epoch == cache.epoch.load(Ordering::SeqCst)
                && built.sessions == self.session_count()
                && built.expires_at.is_none_or(|at| at > crate::store::now_ms());
            fresh.then_some(built)
        };
        if let Some(built) = current() {
            return built;
        }
        let _one = lock(&cache.building);
        if let Some(built) = current() {
            return built;
        }
        // Read before the sessions: a change during the build makes the next read build again.
        #[cfg(test)]
        cache.builds.fetch_add(1, Ordering::SeqCst);
        let epoch = cache.epoch.load(Ordering::SeqCst);
        let sessions = self.session_handles();
        let now = crate::store::now_ms();
        let (mut closed, mut live, mut closed_ids, mut expires_at) =
            (Vec::new(), Vec::new(), HashSet::new(), None::<u64>);
        for session in &sessions {
            let (is_closed, expires) = session.read_meta(|meta| {
                let expires = meta.tags.values().filter_map(|tag| tag.expires_at);
                (meta.status == SessionStatus::Closed, expires.filter(|at| *at > now).min())
            });
            expires_at = match (expires_at, expires) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
            if is_closed {
                closed_ids.insert(session.id.clone());
                closed.push(session.clone());
            } else {
                live.push(session.clone());
            }
        }
        let built = Arc::new(Built {
            epoch,
            sessions: sessions.len(),
            expires_at,
            closed: Arc::new(self.newest(&closed)),
            closed_ids,
            live,
        });
        #[cfg(test)]
        if let Some(pause) = lock(&cache.build_pause).take() {
            let _ = pause.entered.send(());
            // The hold's own park: it ends when the test sends, or drops its sender on an unwind.
            let _ = pause.release.recv();
        }
        // A closed-session activity record or a map change while the index was being built
        // invalidates this result. Return it to this reader, but do not publish it; the mutation's
        // own notification makes the next reader build again.
        if built.epoch == cache.epoch.load(Ordering::SeqCst)
            && built.sessions == self.session_count()
        {
            *lock(&cache.built) = Some(built.clone());
        }
        built
    }

    /// The newest of `sessions` for each chat key, with its fields: only the winners' fields are
    /// built.
    fn newest(&self, sessions: &[Arc<Session>]) -> HashMap<String, Newest> {
        let mut winners: HashMap<String, (u64, &Arc<Session>)> = HashMap::new();
        for session in sessions {
            let Some(key) = session_chat_key(session) else { continue };
            let updated = session.read_meta(|meta| meta.updated_at);
            let key = key_text(&key);
            let beats = |(at, s): &(u64, &Arc<Session>)| (updated, &session.id) >= (*at, &s.id);
            if winners.get(&key).is_none_or(beats) {
                winners.insert(key, (updated, session));
            }
        }
        winners
            .into_iter()
            .map(|(key, (at, s))| (key, (at, s.id.clone(), self.chat_activity_fields(s))))
            .collect()
    }
}
