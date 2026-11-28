//! Hub entry points tests outside the hub use to make and edit sessions (moved from `hub/mod.rs`).

use super::*;

impl Hub {
    /// Changes a session's metadata in place, with no record or save (tests outside the hub).
    #[cfg(test)]
    pub(crate) fn edit_test_meta(&self, session: &Session, edit: impl FnOnce(&mut SessionMeta)) {
        edit(&mut session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        // A change no record carries, as any direct metadata write is (`list_order.rs`).
        self.events.row_changed(session);
    }

    #[cfg(any(test, feature = "test-support"))]
    pub(crate) fn insert_test_session(&self, meta: SessionMeta) -> Arc<Session> {
        let id = meta.id.clone();
        let session = self.make_session(meta);
        self.sessions.lock().unwrap().insert(id, session.clone());
        self.update_live_session_index(&session);
        self.session_came(&session);
        session
    }
}
