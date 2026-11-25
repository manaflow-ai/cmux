//! Part of `Hub`; see `hub/mod.rs`. How many things a chat waits on that wake it by themselves
//! (the working shelf, Leo's feature map: "Chats waiting on subagents, checks or watches fold
//! into one row and return when they need you"): its running background tasks that bring their
//! end to it (`notify`, `bg_notify.rs`), the live watches that wake it (`watches.rs` `to`), its
//! running background subagents, and its sub-sessions that work (`work_below.rs`).
//!
//! The summary's `backgroundWaits` reads the count kept here, never the task folder: the task
//! part is read when a notify task starts or ends, the rest when a watch, a subagent or a
//! sub-session changes. Each change is a mux [`RECORD_KIND`] record (`{count}`), which watchers
//! hear as `_acpmux/session_changed`. Memory only: a daemon start finds the tasks again
//! (`bg_notify_resume`) and the watches (`Watches::start`).

use super::*;

/// The mux record of a change in a chat's background waits.
pub const RECORD_KIND: &str = "background_waits";

impl Hub {
    /// The chat's background waits as last counted (the summary's `backgroundWaits`).
    pub(super) fn background_waits(&self, session: &Session) -> u32 {
        *session.background_waits.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads the chat's running notify tasks again (its task folder), then recounts.
    pub(super) fn refresh_background_tasks(&self, session: &Session) {
        let tasks = u32::try_from(self.bg_notifying_count(session)).unwrap_or(u32::MAX);
        session.bg_notifying.store(tasks, Ordering::SeqCst);
        self.refresh_background_waits(session);
    }

    /// [`Self::refresh_background_tasks`] for chat `id`, if it is here.
    pub(super) fn refresh_background_tasks_of(&self, id: &str) {
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        if let Some(session) = session {
            self.refresh_background_tasks(&session);
        }
    }

    /// [`Self::refresh_background_waits`] for chat `id`, if it is here (a watch's `to`).
    pub(super) fn refresh_background_waits_of(&self, id: &str) {
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        if let Some(session) = session {
            self.refresh_background_waits(&session);
        }
    }

    /// Recounts the chat's background waits from what is in memory; a change is recorded. Holds
    /// the count while counting, so two concurrent recounts never leave an older answer behind.
    pub(super) fn refresh_background_waits(&self, session: &Session) {
        let mut count = session.background_waits.lock().unwrap_or_else(|e| e.into_inner());
        let subagents =
            session.subagents.lock().unwrap_or_else(|e| e.into_inner()).background_running();
        let next = session.bg_notifying.load(Ordering::SeqCst) as usize
            + self.watches.waking(&session.id)
            + subagents
            + self.subsessions_working(session);
        let next = u32::try_from(next).unwrap_or(u32::MAX);
        if *count == next {
            return;
        }
        *count = next;
        self.append(session, "mux", RECORD_KIND, json!({"count": next}));
    }
}

#[cfg(test)]
#[path = "background_waits_tests.rs"]
mod background_waits_tests;
