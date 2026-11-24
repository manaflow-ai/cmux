//! A `session/new` that can be sent again: its creator's key (`_meta.acpmux.createKey`).
//!
//! An automatic restart (a self-update, `machine update`, a crash-restart under systemd) closes
//! every connection, and a `session/new` in flight then ends with no reply (`daemon_closed`):
//! the create may have happened or not, and its caller cannot tell. On a Linux lane VM
//! (2026-11-21 09:58:45Z) `acpmux machine self-update` restarted the daemon under a packing
//! benchmark's `acpmux new -d --json`, and the benchmark died on it.
//!
//! The CLI sends a fresh key with each create and the same key again after it reconnects. The
//! key is kept in the session's meta (`SessionMeta::create_key`), on disk, before its agent
//! starts, so the next daemon finds it: a create sent again answers with the session the first
//! one made, or makes it when the first never did. Exactly one session either way.
//!
//! Only the local socket's keys are honored: a key is no proof of who sent it, and a remote
//! client must never get another caller's session by naming its key.

use super::*;

/// The `_meta.acpmux` field.
pub(crate) const FIELD: &str = "createKey";

/// Listed at initialize: this daemon keeps create keys, so a create sent again with one never
/// makes a second session. A CLI resends an unnamed create only to a daemon that lists it, and
/// only when the daemon it first sent it to listed it too.
pub(crate) const FEATURE: &str = "createKey";

/// Set (true) on the reply to a create its key found made already: the caller's session, not a
/// new one.
pub(crate) const REPLAYED: &str = "createReplayed";

/// The longest key kept: a UUID is 36 bytes.
const MAX_LEN: usize = 128;

/// The key a create's `_meta.acpmux` names, checked: None when it names none.
pub(crate) fn requested(meta: Option<&Value>) -> Result<Option<String>, RpcError> {
    let Some(value) = meta.and_then(|m| m.get(FIELD)) else { return Ok(None) };
    match value {
        Value::Null => Ok(None),
        Value::String(key)
            if !key.is_empty()
                && key.len() <= MAX_LEN
                && key.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_') =>
        {
            Ok(Some(key.clone()))
        }
        _ => Err(RpcError::invalid_params(format!(
            "{FIELD} must be at most {MAX_LEN} letters, digits, '-' or '_'"
        ))),
    }
}

/// The session made under `key` among `sessions`.
pub(super) fn made_in(sessions: &HashMap<String, Arc<Session>>, key: &str) -> Option<Arc<Session>> {
    sessions.values().find(|s| s.read_meta(|m| m.create_key.as_deref() == Some(key))).cloned()
}

impl Hub {
    /// The session a create with `key` made, on this daemon or an earlier one: waits for the
    /// store's index first, since the earlier daemon's session is in it.
    pub(crate) async fn created_with_key(&self, key: &str) -> Option<Arc<Session>> {
        self.wait_store().await;
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        made_in(&sessions, key).filter(|s| !s.purged.load(Ordering::SeqCst))
    }
}

#[cfg(test)]
#[path = "create_key_tests.rs"]
mod tests;
