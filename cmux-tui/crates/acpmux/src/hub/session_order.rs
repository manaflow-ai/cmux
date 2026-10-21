//! Part of `Hub`; see `hub/mod.rs`. The order session lists use.

use super::*;

/// `sessions` newest first. Each session's `updated_at` is read once: other
/// tasks move it at any time (every logged event), and a key that is read
/// again on each comparison is not a total order, which makes Rust's sort
/// panic (the Chief daemon, 2026-10-14). Ties keep the session id order, so
/// the list is the same for the same values.
pub(super) fn newest_first(sessions: Vec<Arc<Session>>) -> Vec<Arc<Session>> {
    let mut keyed: Vec<_> = sessions
        .into_iter()
        .map(|s| {
            let at = s.meta.lock().unwrap_or_else(|e| e.into_inner()).updated_at;
            (at, s)
        })
        .collect();
    keyed.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
    keyed.into_iter().map(|(_, s)| s).collect()
}
