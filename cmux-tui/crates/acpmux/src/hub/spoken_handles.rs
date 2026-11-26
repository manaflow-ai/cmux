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
        // The handle it gives up stays one of its names (`former_names.rs`): `acpmux send OLD`
        // and a message naming the old handle still reach it, and every surface can say
        // "Mango (fka Honey)". Leo, 2026-11-22: "IDK HOW AGENTS WILL KNOW, MAYBE JUST...
        // FKA/ALIASES?"
        let given = session
            .read_meta(|m| m.handle.clone())
            .filter(|h| crate::session_handle::valid(h) && h != handle);
        if let Some(old) = &given {
            self.release_former_names(session, handle, old);
        }
        let (previous, former) = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let former = m.former_names.clone();
            if let Some(old) = &given {
                super::former_names::push_former(&mut m.former_names, old, handle);
            } else {
                // A first handle that was once a former name is no longer one: no "Mango (fka Mango)".
                m.former_names.retain(|n| n != handle);
            }
            (m.handle.replace(handle.to_owned()), former)
        };
        if let Err(error) = self.save_meta_answered(session) {
            {
                let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                m.handle = previous;
                m.former_names = former;
            }
            self.save_meta(session);
            return Err(error);
        }
        self.events.row_changed(session);
        Ok(())
    }

    /// Set (or, with None, clear) the icon every surface draws for `session`
    /// (`session_icon.rs`). Any client that may rename the chat may set it; nothing else is
    /// asked (Leo, 2026-11-22: "WE'D BETTER NOT HAVE BULLSHIT LOCKS").
    pub(crate) fn set_session_icon(
        &self,
        session: &Session,
        icon: Option<crate::session_icon::SessionIcon>,
    ) -> Result<(), RpcError> {
        let previous = std::mem::replace(
            &mut session.meta.lock().unwrap_or_else(|e| e.into_inner()).icon,
            icon,
        );
        if let Err(error) = self.save_meta_answered(session) {
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).icon = previous;
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
