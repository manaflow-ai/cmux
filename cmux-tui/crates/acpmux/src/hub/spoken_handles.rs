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
        let (previous, former, assigned) = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let former = m.former_names.clone();
            if let Some(old) = &given {
                super::former_names::push_former(&mut m.former_names, old, handle);
            } else {
                // A first handle that was once a former name is no longer one: no "Mango (fka Mango)".
                m.former_names.retain(|n| n != handle);
            }
            let assigned = std::mem::take(&mut m.handle_assigned);
            (m.handle.replace(handle.to_owned()), former, assigned)
        };
        if let Err(error) = self.save_meta_answered(session) {
            {
                let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                m.handle = previous;
                m.former_names = former;
                m.handle_assigned = assigned;
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
        let remote = self.remote_handles(id);
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        handle_taken_in(&sessions, &remote, handle, id)
    }

    /// What every session other peers show (`remote_sessions`) is called, for a handle check:
    /// its bare name, explicit handle and id. Copied out first, so the check that follows can
    /// hold the sessions lock without taking the remote table under it.
    pub(super) fn remote_handles(&self, id: &str) -> Vec<RemoteHandle> {
        self.remote_sessions
            .read()
            .values()
            .filter(|r| r.receipt.mux_session_id != id)
            .map(|r| {
                let name = r.summary.name().unwrap_or_default();
                let bare = name
                    .strip_prefix(r.peer.as_str())
                    .and_then(|n| n.strip_prefix('/'))
                    .unwrap_or(name);
                RemoteHandle {
                    name: bare.to_owned(),
                    handle: r.summary.handle().map(str::to_owned),
                    id: r.receipt.mux_session_id.clone(),
                }
            })
            .collect()
    }

    /// The handle a new chat starts with, picked under the insert lock (`lifecycle.rs`): the
    /// one its start asked for, refused when another session here or on a peer has it, else
    /// the first free cute name (`session_handle::pick_free`), with no hex tail. The second
    /// value is whether the daemon gave it, so the first turn asks the chat to pick its own.
    pub(super) fn assign_handle(
        sessions: &HashMap<String, Arc<Session>>,
        remote: &[RemoteHandle],
        asked: Option<&str>,
        id: &str,
    ) -> Result<(String, bool), RpcError> {
        if let Some(handle) = asked {
            if !crate::session_handle::valid(handle) {
                return Err(RpcError::invalid_params(
                    "a handle is 2–24 ASCII letters, digits or hyphens, starting with a letter and ending with a letter or digit",
                ));
            }
            if handle_taken_in(sessions, remote, handle, id) {
                return Err(RpcError::invalid_params(format!(
                    "session handle {handle:?} is taken; pick another"
                ))
                .with_data(json!({"reason": "handle.taken"})));
            }
            return Ok((handle.to_owned(), false));
        }
        let picked =
            crate::session_handle::pick_free(id, 1, |h| handle_taken_in(sessions, remote, h, id));
        let handle =
            picked.into_iter().next().unwrap_or_else(|| crate::session_handle::default_handle(id));
        Ok((handle, true))
    }

    /// Free names a chat may pick instead of the one it has (`session_handle::first_turn_note`).
    pub(super) fn free_handles(&self, id: &str, count: usize) -> Vec<String> {
        let remote = self.remote_handles(id);
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        crate::session_handle::pick_free(id, count, |h| handle_taken_in(&sessions, &remote, h, id))
    }
}

/// A session another peer shows, as a handle check reads it (`Hub::remote_handles`).
pub(super) struct RemoteHandle {
    name: String,
    handle: Option<String>,
    id: String,
}

/// Whether a session other than `id`, here or on a peer, is already called `handle`: by its
/// name, its explicit handle, or the hex handle its id derives (kept as an alias).
pub(super) fn handle_taken_in(
    sessions: &HashMap<String, Arc<Session>>,
    remote: &[RemoteHandle],
    handle: &str,
    id: &str,
) -> bool {
    let conflicts = |name: &str, current: Option<&str>, key: &str| {
        name.eq_ignore_ascii_case(handle) || crate::session_handle::matches(current, key, handle)
    };
    sessions.values().any(|s| {
        s.id != id && s.read_meta(|meta| conflicts(&meta.name, meta.handle.as_deref(), &s.id))
    }) || remote.iter().any(|r| conflicts(&r.name, r.handle.as_deref(), &r.id))
}

#[cfg(test)]
#[path = "spoken_handles_tests.rs"]
mod tests;
