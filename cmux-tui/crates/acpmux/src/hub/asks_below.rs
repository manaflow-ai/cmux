//! Part of `Hub`; see `hub/mod.rs`. Open sub-sessions below a session that wait on the person
//! (cmuxterm-hq#7794 #7: a subagent's ask reached only the Chief, and every other run stalled
//! where nobody looked). A child that asks for a permission or a question is `Waiting`; its
//! parent's summary counts it (`subsessionsWaiting`, since `subsessionsWaitingSince`), so the
//! parent's dot and lane read `input`, not `working` (`views.rs` `status_indicator`), and the
//! parent chat's page draws the child's ask in place (webviews `subagents/childAsks.ts`).
//!
//! The count covers every open descendant, not only children: a grandchild's ask stalls its
//! grandparent's run as much. Each change is a mux `subsessions_waiting` record
//! (`{count, since}`, since null at zero), which watchers hear as `_acpmux/session_changed`;
//! then the parent's is re-decided, as `work_below.rs` does for work.
//!
//! It reads only the children's statuses and their own counts, never a child's permission
//! state: a child appends its `permission_request` under that state's lock, and its
//! `set_status` (which calls in here) can run under it.

use super::*;

/// The mux record of a change in how many sub-sessions below a session wait on the person.
pub const RECORD_KIND: &str = "subsessions_waiting";

impl Hub {
    /// How many open sub-sessions below `session` wait on the person, and since when; None while
    /// none does.
    pub(super) fn subsessions_waiting(&self, session: &Session) -> Option<(u32, u64)> {
        let mark = *session.asks_below.lock().unwrap_or_else(|e| e.into_inner());
        (mark.0 > 0).then_some(mark)
    }

    /// Re-decides how many sub-sessions below `session` wait on the person. When that changed,
    /// it is recorded and the parent's is re-decided. As in `refresh_work_below`, the session's
    /// mark is held while deciding and let go before the parent's is taken, so marks are always
    /// taken parent before child.
    pub(super) fn refresh_asks_below(&self, session: &Session) {
        {
            let mut mark = session.asks_below.lock().unwrap_or_else(|e| e.into_inner());
            let count = self.waiting_below(session);
            if count == mark.0 {
                return;
            }
            // The first ask below dates the wait; another one joining it does not move it.
            let since = match (count, mark.0) {
                (0, _) => 0,
                (_, 0) => now_ms().max(1),
                _ => mark.1,
            };
            *mark = (count, since);
            let since = (since != 0).then_some(since);
            self.append(session, "mux", RECORD_KIND, json!({"count": count, "since": since}));
        }
        if let Some(parent) = self.subsession_parent(session) {
            self.refresh_asks_below(&parent);
        }
    }

    /// Re-decides the asks below `session`'s parent, if it is a sub-session.
    pub(super) fn refresh_parent_asks_below(&self, session: &Session) {
        if let Some(parent) = self.subsession_parent(session) {
            self.refresh_asks_below(&parent);
        }
    }

    /// The open sub-session below `session`, at any depth, where `permission_id` is pending, when
    /// it is not pending in `session` itself. A person's answer sent to the parent for its child's
    /// ask, drawn on the parent's page (`server/requests.rs` `route_ask_below`), goes there.
    pub(crate) fn asking_below(&self, session: &Session, permission_id: &str) -> Option<String> {
        let pending = |s: &Session| {
            s.permissions
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .pending
                .contains_key(permission_id)
        };
        if pending(session) {
            return None;
        }
        let mut queue: std::collections::VecDeque<String> =
            self.subsessions.open_children(&session.id).into();
        let mut seen = std::collections::HashSet::from([session.id.clone()]);
        while let Some(id) = queue.pop_front() {
            if !seen.insert(id.clone()) {
                continue;
            }
            let child = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned();
            let Some(child) = child else { continue };
            if pending(&child) {
                return Some(id);
            }
            queue.extend(self.subsessions.open_children(&id));
        }
        None
    }

    /// Open children waiting on the person, plus those waiting below each of them.
    fn waiting_below(&self, session: &Session) -> u32 {
        let children: Vec<Arc<Session>> = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            self.subsessions
                .open_children(&session.id)
                .iter()
                .filter_map(|id| sessions.get(id).cloned())
                .collect()
        };
        children
            .iter()
            .map(|child| {
                u32::from(child.status() == SessionStatus::Waiting)
                    + self.subsessions_waiting(child).map_or(0, |(count, _)| count)
            })
            .sum()
    }
}

#[cfg(test)]
#[path = "asks_below_tests.rs"]
mod asks_below_tests;
