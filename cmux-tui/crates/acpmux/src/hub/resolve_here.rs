//! Part of `Hub`; see `hub/mod.rs`. A session key (id, short id or name) resolved against this
//! daemon's own sessions, and the error an unknown one gets.

use super::*;

impl Hub {
    /// This daemon's own session `key` names: its id, its whole name, then a unique prefix of
    /// either. Only when none of those finds a session here and no peer lists one `key` names
    /// (by id, id prefix, whole name or `PEER/NAME`, `Hub::remote_strict_matches`), a bare key
    /// (no `/`) that is a sub-session's last name segment (`mac-ci-3` for `claude-sr2/mac-ci-3`,
    /// `session_name::ends_with_segments`) names it: so no key that found a session before
    /// short names, or was refused, finds another now. A short name only a peer's session has
    /// is the peer route's (`Hub::resolve_remote`); one several sessions share, here or on
    /// peers, is refused with their names. A miss is the plain `no session matches`
    /// (`Hub::unknown_session` adds the close names where a caller is told). A key with a `/`
    /// never matches by short name here: `HOST/NAME` stays a host's (`own_host.rs`).
    pub(crate) fn resolve_here(&self, key: &str) -> Result<Arc<Session>, RpcError> {
        // The chats `key` may name that left memory come back first (`evict.rs`).
        self.rehydrate_named(key);
        let sessions = self.sessions.lock().unwrap();
        // A qualified id is authoritative for new routing. The old bare id,
        // name and prefix forms below remain compatible.
        if let Some((host, mux_id)) = SessionReceipt::split_qualified_id(key)
            && host == LOCAL_HOST_ID
            && let Some(s) = sessions.get(mux_id)
        {
            return Ok(s.clone());
        }
        if let Some(s) = sessions.get(key) {
            return Ok(s.clone());
        }
        // Names are read under each session's meta lock, never cloned: a
        // clone of every meta took ~45 ms with 2,500 sessions, on each Stop
        // (`acpmux session cancel NAME`) and every other call by name. One
        // pass sorts them into the tiers below.
        let bare = !key.contains('/');
        let (mut by_name, mut by_segment, mut by_prefix) = (Vec::new(), Vec::new(), Vec::new());
        for s in sessions.values() {
            let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let alias = meta.tags.get("session.alias").map(|tag| tag.value.as_str());
            if meta.name == key || alias == Some(key) {
                by_name.push(s.clone());
            }
            if bare && crate::session_name::ends_with_segments(&meta.name, key) {
                by_segment.push((s.clone(), meta.status == SessionStatus::Closed));
            }
            if s.id.starts_with(key)
                || meta.name.starts_with(key)
                || alias.is_some_and(|alias| alias.starts_with(key))
            {
                by_prefix.push(s.clone());
            }
        }
        drop(sessions);
        if by_name.len() == 1 {
            return Ok(by_name.remove(0));
        }
        // A given name (`session_handle.rs`, "Mango") reaches its session as `key_route` tier 0
        // does, ahead of former names and prefixes (Leo, 2026-11-23: "the renaming paradigm
        // still hasn't hit yet").
        if by_name.is_empty()
            && let Some(found) = self.resolve_handle_here(key)
        {
            return found;
        }
        // No session has it as its name now: one that had it before a rename
        // (`former_names.rs`), ahead of short names and prefixes. A peer's session that has it
        // as its name now wins (`resolve_remote`).
        if by_name.is_empty()
            && let Some(found) = self.resolve_former_here(key)
            && self.remote_strict_matches(key) == 0
        {
            return found;
        }
        let named = |matched: &[Arc<Session>]| -> Vec<String> {
            matched
                .iter()
                .map(|s| {
                    format!("{} ({})", s.meta.lock().unwrap_or_else(|e| e.into_inner()).name, s.id)
                })
                .collect()
        };
        let tied = |mut names: Vec<String>| {
            names.sort();
            names.dedup();
            crate::session_name::ambiguous(key, &names)
        };
        // A short name here, only where the rules above find nothing here and no peer lists a
        // session `key` names: then this answers as it did before short names matched. The
        // peers' rows are read only with a local candidate in hand (a plain miss, as for every
        // request a peer's session serves, reads none), with this daemon's sessions unlocked.
        // A short name only a peer's session has is `resolve_remote`'s.
        if by_name.is_empty()
            && by_prefix.is_empty()
            && !by_segment.is_empty()
            && self.remote_strict_matches(key) == 0
        {
            // Closed ones count only when no live one, here or on a peer, has the short name
            // (`hub/key_route.rs`), so this agrees with the route the unix socket takes.
            let remote = self.remote_segment_names(key);
            let live = by_segment.iter().any(|(_, closed)| !closed)
                || remote.iter().any(|(_, closed)| !closed);
            let here: Vec<Arc<Session>> = by_segment
                .into_iter()
                .filter(|(_, closed)| !live || !closed)
                .map(|(s, _)| s)
                .collect();
            let there: Vec<String> =
                remote.into_iter().filter(|(_, closed)| !live || !closed).map(|(n, _)| n).collect();
            match (here.as_slice(), there.len()) {
                ([one], 0) => return Ok(one.clone()),
                // The one a peer has is `resolve_remote`'s.
                ([], 1) => return Err(crate::session_name::not_found(key, &[])),
                // Several, here or on peers: a tie, refused with every name.
                _ => {
                    let mut names = named(&here);
                    names.extend(there);
                    return Err(tied(names));
                }
            }
        }
        match by_prefix.len() {
            1 => Ok(by_prefix.remove(0)),
            0 => Err(crate::session_name::not_found(key, &[])),
            _ => Err(tied(named(&by_prefix))),
        }
    }

    /// This daemon's own sessions `key` names: [by id, name or a prefix of either; by short name
    /// and live; by short name and closed]. A peer's short name gives way to the first two, and
    /// to the third only when it is closed too (`Hub::resolve_remote`).
    pub(crate) fn local_match_counts(&self, key: &str) -> [usize; 3] {
        self.rehydrate_named(key);
        let bare = !key.contains('/');
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut counts = [0_usize; 3];
        for s in sessions.values() {
            let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let alias = meta.tags.get("session.alias").map(|tag| tag.value.as_str());
            if s.id.starts_with(key)
                || meta.name.starts_with(key)
                || alias.is_some_and(|alias| alias.starts_with(key))
            {
                counts[0] = counts[0].saturating_add(1);
            } else if bare && crate::session_name::ends_with_segments(&meta.name, key) {
                let slot = if meta.status == SessionStatus::Closed { 2 } else { 1 };
                if let Some(count) = counts.get_mut(slot) {
                    *count = count.saturating_add(1);
                }
            }
        }
        counts
    }

    /// The one session here whose last name segment is the bare `key` (`HOST/SHORT` with this
    /// machine as `HOST`, `own_host.rs`): None when none is; refused when several are. Closed
    /// sessions count only when none is live, as in `key_route` and `resolve_here`.
    pub(crate) fn resolve_short_here(&self, key: &str) -> Option<Result<Arc<Session>, RpcError>> {
        if key.contains('/') {
            return None;
        }
        self.rehydrate_named(key);
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let (live, closed): (Vec<_>, Vec<_>) = sessions
            .values()
            .filter_map(|s| {
                let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                crate::session_name::ends_with_segments(&meta.name, key)
                    .then(|| (s.clone(), meta.name.clone(), meta.status == SessionStatus::Closed))
            })
            .partition(|(_, _, closed)| !closed);
        drop(sessions);
        let found = if live.is_empty() { closed } else { live };
        match found.as_slice() {
            [] => None,
            [(s, _, _)] => Some(Ok(s.clone())),
            many => Some(Err(crate::session_name::ambiguous(
                key,
                &many.iter().map(|(s, n, _)| format!("{n} ({})", s.id)).collect::<Vec<_>>(),
            ))),
        }
    }

    /// The refusal for a key no session here or on a peer names, with the names it nearly
    /// matched (`session_name::candidates`), so the caller can pick one instead of running
    /// `acpmux ls`. Reads every name: only where the refusal goes back to a caller.
    pub fn unknown_session(&self, key: &str) -> RpcError {
        let lower = key.to_ascii_lowercase();
        let mut names: Vec<String> = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .filter_map(|s| {
                let name = s.meta.lock().unwrap_or_else(|e| e.into_inner()).name.clone();
                name.to_ascii_lowercase().contains(&lower).then_some(name)
            })
            .collect();
        names.extend(
            self.evicted.names().into_iter().filter(|n| n.to_ascii_lowercase().contains(&lower)),
        );
        names.extend(self.remote_names_containing(&lower));
        let close = crate::session_name::candidates(names.iter().map(String::as_str), key);
        crate::session_name::not_found(key, &close)
    }
}
