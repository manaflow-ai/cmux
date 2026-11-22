//! Persist explicit handle changes under the existing session rename authority.
use super::*;

impl Hub {
    pub(crate) fn rename_spoken_handle(
        &self,
        session: &Session,
        handle: &str,
    ) -> Result<(), RpcError> {
        if !crate::session_handle::valid(handle) {
            return Err(RpcError::invalid_params(
                "a handle is 2–24 ASCII letters, digits or hyphens, starting with a letter and ending with a letter or digit",
            ));
        }
        let _renaming = self.spoken_handle_renames.lock().unwrap_or_else(|e| e.into_inner());
        // Serialize the local check and save. Disconnected peers may independently choose
        // the same handle. Routing refuses a tie when their rows become visible together.
        if self.spoken_handle_taken(handle, &session.id) {
            return Err(RpcError::invalid_params(format!("session handle {handle:?} is taken"))
                .with_data(json!({"reason": "handle.taken"})));
        }
        let moving = session.moving.lock().unwrap_or_else(|e| e.into_inner());
        if moving.is_some() {
            return Err(queue::moving_error(session));
        }
        let previous = session
            .meta
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .handle
            .replace(handle.to_owned());
        if let Err(error) = self.save_meta_answered(session) {
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).handle = previous;
            self.save_meta(session);
            return Err(error);
        }
        self.events.row_changed(session);
        Ok(())
    }

    fn spoken_handle_taken(&self, handle: &str, id: &str) -> bool {
        let conflicts = |name: &str, current: Option<&str>, key: &str| {
            name.eq_ignore_ascii_case(handle)
                || crate::session_handle::matches(current, key, handle)
        };
        let local = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().any(|s| {
            s.id != id && s.read_meta(|meta| conflicts(&meta.name, meta.handle.as_deref(), &s.id))
        });
        local
            || self.remote_sessions.read().values().any(|r| {
                let key = &r.receipt.mux_session_id;
                let name = r.summary.name().unwrap_or_default();
                let bare = name
                    .strip_prefix(r.peer.as_str())
                    .and_then(|n| n.strip_prefix('/'))
                    .unwrap_or(name);
                key != id && conflicts(bare, r.summary.handle(), key)
            })
    }
}
