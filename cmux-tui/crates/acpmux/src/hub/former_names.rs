//! Part of `Hub`; see `hub/mod.rs`. A renamed session keeps answering to its old names (Leo
//! asked that session names follow their task, 2026-11-20, so names now change more often): a
//! rename keeps the name it replaced in `SessionMeta::former_names`, and every lookup that finds
//! no session by its current name (`resolve_here`, `own_host.rs`, `key_route.rs`, a peer's rows
//! in `resolve_remote`) tries the former names next. A current name always wins over one; a
//! rename may take another session's former name, which that session then gives up; and each
//! rename moves the name it gave up away from any other session that still kept it, so one
//! former name names one session. Two sessions that still share one (a store from before this
//! rule) are refused with both names, never one picked.

use super::*;

/// The most former names a session keeps; the oldest goes first.
pub(crate) const KEPT: usize = 8;

/// `former` after a rename from `old` to `new`: `old` last (newest), `new` out of it, no repeat,
/// at most [`KEPT`].
pub(crate) fn push_former(former: &mut Vec<String>, old: &str, new: &str) {
    former.retain(|n| n != old && n != new);
    if !old.is_empty() && old != new {
        former.push(old.to_owned());
    }
    let over = former.len().saturating_sub(KEPT);
    former.drain(..over);
}

/// The route of the one session a former name names, of `rows`: live ones first; several live
/// (or, none live, several closed) are refused.
fn pick_former<T: Clone>(key: &str, rows: Vec<(T, String, bool)>) -> Option<Result<T, RpcError>> {
    let live = rows.iter().any(|(_, _, closed)| !closed);
    let mut rows: Vec<(T, String, bool)> =
        rows.into_iter().filter(|(_, _, closed)| !live || !closed).collect();
    match rows.len() {
        0 => None,
        1 => rows.pop().map(|(found, _, _)| Ok(found)),
        _ => {
            let mut names: Vec<String> = rows.into_iter().map(|(_, name, _)| name).collect();
            names.sort();
            names.dedup();
            Some(Err(crate::session_name::ambiguous(key, &names)))
        }
    }
}

impl Hub {
    /// The session here that had `key` as a name before a rename, when no session here has it
    /// now: None when none had it; refused when several did.
    pub(super) fn resolve_former_here(&self, key: &str) -> Option<Result<Arc<Session>, RpcError>> {
        if key.is_empty() {
            return None;
        }
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut rows = Vec::new();
        for s in sessions.values() {
            let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if meta.name == key {
                // A current name wins: the caller's own lookup finds it.
                return None;
            }
            if meta.former_names.iter().any(|n| n == key) {
                rows.push((
                    s.clone(),
                    format!("{} ({})", meta.name, s.id),
                    meta.status == SessionStatus::Closed,
                ));
            }
        }
        drop(sessions);
        pick_former(key, rows)
    }

    /// The route (`PEER/ID`) of the one peer session that had `key` (`NAME`, or `PEER/NAME`) as a
    /// name before a rename, read from the rows peers list (`formerNames`). Only for a key no
    /// row names now (`resolve_remote`).
    pub(super) fn former_remote_route(&self, key: &str) -> Option<Result<String, RpcError>> {
        let (host, name) = match key.split_once('/') {
            Some((host, name)) if !name.is_empty() => (Some(host), name),
            _ => (None, key),
        };
        let map = self.remote_sessions.read();
        let rows: Vec<(String, String, bool)> = map
            .iter()
            .filter(|(_, r)| host.is_none_or(|h| r.peer == h))
            .filter(|(_, r)| r.summary.has_former_name(name))
            .map(|(route, r)| {
                let shown = r.summary.name().unwrap_or_default().to_owned();
                (route.clone(), shown, r.summary.closed())
            })
            .collect();
        drop(map);
        pick_former(key, rows)
    }

    /// The local route a former name names, for `key_route`: Some(id) for one session here.
    pub(super) fn former_route_here(&self, key: &str) -> Result<Option<String>, RpcError> {
        match self.resolve_former_here(key) {
            None => Ok(None),
            Some(Ok(s)) => Ok(Some(s.id.clone())),
            Some(Err(e)) => Err(e),
        }
    }

    /// Before `session` takes `name` and gives up `old`: every other session that kept either as
    /// a former name gives it up (`name` is now a current name; `old` is now `session`'s former
    /// name), and is saved.
    pub(super) fn release_former_names(&self, session: &Session, name: &str, old: &str) {
        let others: Vec<Arc<Session>> = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .filter(|s| s.id != session.id)
            .cloned()
            .collect();
        for other in others {
            let changed = {
                let mut m = other.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let before = m.former_names.len();
                m.former_names.retain(|n| n != name && n != old);
                m.former_names.len() != before
            };
            if changed {
                self.save_meta(&other);
            }
        }
    }
}

#[cfg(test)]
#[path = "former_names_tests.rs"]
pub(super) mod tests;
