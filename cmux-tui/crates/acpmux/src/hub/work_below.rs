//! Part of `Hub`; see `hub/mod.rs`. Work a session started that runs on past its own turn
//! (manaflow-ai/cmux#25230): a background subagent of its harness (`crate::subagents`), or an
//! open sub-session (`subsessions.rs`) that runs a turn, waits on the person, or has such work
//! of its own. A task is not done while its subagents run, so the session's status dot and lane
//! stay `working` until all of it ends (`views.rs` `status_indicator`, the summary's
//! `subagentsWorkingSince`).
//!
//! Each change is a mux `subagents_working` record (`{since}`, null when it ended), which
//! watchers hear as `_acpmux/session_changed`, and then re-decides the parent's.

use super::*;

/// The mux record of a change in a session's work below its turn.
pub const RECORD_KIND: &str = "subagents_working";

impl Hub {
    /// Since when work `session` started still runs past its own turn; None while none does.
    pub(super) fn work_below_since(&self, session: &Session) -> Option<u64> {
        let since = *session.work_below_since.lock().unwrap_or_else(|e| e.into_inner());
        (since != 0).then_some(since)
    }

    /// Re-decides whether work `session` started runs past its own turn. When that changed, it
    /// is recorded and the parent's is re-decided. Holds the session's mark while deciding, so
    /// two concurrent decisions never leave an older answer behind; a parent's mark is only
    /// taken after the child's is let go, so the order is always parent before child (sub-session
    /// links form a tree).
    pub(super) fn refresh_work_below(&self, session: &Session) {
        {
            let mut mark = session.work_below_since.lock().unwrap_or_else(|e| e.into_inner());
            let works = self.works_below(session);
            if works == (*mark != 0) {
                return;
            }
            *mark = if works { now_ms().max(1) } else { 0 };
            // Recorded under the mark, so the records keep the order of the changes.
            let since = (*mark != 0).then_some(*mark);
            self.append(session, "mux", RECORD_KIND, json!({"since": since}));
        }
        if let Some(parent) = self.subsession_parent(session) {
            self.refresh_work_below(&parent);
        }
    }

    /// Re-decides the work below the turn of `session`'s parent, if it is a sub-session.
    pub(super) fn refresh_parent_work_below(&self, session: &Session) {
        if let Some(parent) = self.subsession_parent(session) {
            self.refresh_work_below(&parent);
        }
    }

    /// The harness is gone and its background subagents with it.
    pub(super) fn end_background_subagents(&self, session: &Session) {
        session.subagents.lock().unwrap_or_else(|e| e.into_inner()).end_background();
        self.refresh_work_below(session);
    }

    /// Whether a background subagent of `session` runs, or one of its open sub-sessions works.
    fn works_below(&self, session: &Session) -> bool {
        if session.subagents.lock().unwrap_or_else(|e| e.into_inner()).background_running() > 0 {
            return true;
        }
        let children: Vec<Arc<Session>> = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            self.subsessions
                .open_children(&session.id)
                .iter()
                .filter_map(|id| sessions.get(id).cloned())
                .collect()
        };
        children.iter().any(|child| {
            matches!(child.status(), SessionStatus::Running | SessionStatus::Waiting)
                || self.work_below_since(child).is_some()
        })
    }

    /// The session that started `session` as its sub-session, if it is one and is here.
    fn subsession_parent(&self, session: &Session) -> Option<Arc<Session>> {
        let parent = session.meta.lock().unwrap_or_else(|e| e.into_inner()).subsession.clone()?;
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        sessions.get(&parent.started_by).filter(|p| p.id != session.id).cloned()
    }
}
