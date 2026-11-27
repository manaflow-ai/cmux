use super::*;

impl Hub {
    /// How many sessions the peers list that `key` names, as [`Hub::resolve_remote`] matches
    /// them: 0 none, 1 the one it resolves, more when it is ambiguous.
    pub fn remote_matches(&self, key: &str) -> usize {
        let map = self.remote_sessions.read();
        if map.get(key).is_some() {
            return 1;
        }
        // Whole names and prefixes, else short names (closed ones only when no live one has
        // it, as `resolve_remote` matches them). Only the rows the indexes say `key` can name
        // are read (`remote_rows.rs`), never every peer's.
        let strict = map.named(key).into_iter().filter(|(id, r)| names_remote(id, r, key)).count();
        if strict > 0 {
            return strict;
        }
        let (mut live, mut closed) = (0, 0);
        for (_, r) in map.short_named(key) {
            if remote_segment(r, key) {
                if remote_closed(r) { closed += 1 } else { live += 1 }
            }
        }
        if live == 0 { closed } else { live }
    }

    /// [`Self::remote_matches`] without short names: how many peer sessions `key` names by id,
    /// id prefix, whole name or `PEER/NAME`. A local short name gives way to any of them
    /// (`Hub::resolve_here`).
    pub(in crate::hub) fn remote_strict_matches(&self, key: &str) -> usize {
        let map = self.remote_sessions.read();
        if map.get(key).is_some() {
            return 1;
        }
        map.named(key).into_iter().filter(|(id, r)| names_remote(id, r, key)).count()
    }

    /// The names (with their ids) of the peer sessions whose short name is `key`
    /// ([`remote_segment`]), each with whether it is closed, for `Hub::resolve_here`'s tie.
    pub(in crate::hub) fn remote_segment_names(&self, key: &str) -> Vec<(String, bool)> {
        let map = self.remote_sessions.read();
        map.short_named(key)
            .into_iter()
            .map(|(_, r)| r)
            .filter(|r| remote_segment(r, key))
            .map(|r| {
                let name = r.summary.name().unwrap_or("");
                (format!("{name} ({}/{})", r.peer, r.receipt.mux_session_id), remote_closed(r))
            })
            .collect()
    }

    /// Look a key up among peer sessions: exact id, `peer/name`, or a unique name or id prefix;
    /// failing those, the one peer session whose short name `key` is ([`remote_segment`]):
    /// `mac-ci-3` for `claude-sr2/mac-ci-3` when `key` names no session here in any way
    /// (`Hub::local_match_counts`), or `PEER/mac-ci-3` on that peer only.
    pub fn resolve_remote(&self, key: &str) -> Option<(Arc<crate::peer::Peer>, String, Value)> {
        let map = self.remote_sessions.read();
        let (row, name) = remote_match(&map, key)?;
        let row = Arc::clone(row);
        drop(map);
        if !name.available(self, key) {
            return None;
        }
        Some((self.peer(&row.peer)?, row.receipt.mux_session_id.clone(), row.summary.value()))
    }

    /// The names of the peer sessions whose name contains `lower` (any case), for a refusal's
    /// list (`Hub::unknown_session`).
    pub(in crate::hub) fn remote_names_containing(&self, lower: &str) -> Vec<String> {
        let map = self.remote_sessions.read();
        map.values()
            .filter_map(|r| r.summary.name())
            .filter(|n| crate::session_name::contains_ignore_case(n, lower))
            .map(str::to_owned)
            .collect()
    }
}

/// Local names can shadow a peer's bare short name or former name; check them at use time.
#[derive(Clone, Copy)]
pub(in crate::hub) enum RemoteName {
    Direct,
    Short { closed: bool },
    Former,
}

impl RemoteName {
    pub(in crate::hub) fn available(self, hub: &Hub, key: &str) -> bool {
        match self {
            Self::Direct => true,
            Self::Short { closed } => {
                let [other, live_here, closed_here] = hub.local_match_counts(key);
                other == 0 && live_here == 0 && (!closed || closed_here == 0)
            }
            Self::Former => {
                hub.local_match_counts(key) == [0, 0, 0] && hub.resolve_former_here(key).is_none()
            }
        }
    }
}

/// The candidate in one peer-row snapshot, shared by prompt routing and the idle-link index.
pub(in crate::hub) fn remote_match<'a>(
    map: &'a crate::hub::remote_rows::RemoteRows,
    key: &str,
) -> Option<(&'a Arc<RemoteSession>, RemoteName)> {
    let (hit, by_short_name) = if let Some(r) = map.get(key) {
        (Some(r), false)
    } else {
        // Whole names and prefixes first; the short-name candidates count only when none
        // matched. Only the rows the indexes say `key` can name are read (`remote_rows.rs`),
        // never every peer's, and the predicates still decide which of them it names. Only
        // the one row picked is cloned.
        let strict: Vec<&Arc<RemoteSession>> = map
            .named(key)
            .into_iter()
            .filter(|(id, r)| names_remote(id, r, key))
            .map(|(_, r)| r)
            .collect();
        let shorts: Vec<&Arc<RemoteSession>> = if strict.is_empty() {
            map.short_named(key)
                .into_iter()
                .filter(|(_, r)| remote_segment(r, key))
                .map(|(_, r)| r)
                .collect()
        } else {
            Vec::new()
        };
        let short = strict.is_empty();
        let mut matches: Vec<&Arc<RemoteSession>> = if short {
            // Closed ones count only when no live one has the short name (`hub/key_route.rs`).
            let live = shorts.iter().any(|r| !remote_closed(r));
            shorts.into_iter().filter(|r| !live || !remote_closed(r)).collect()
        } else {
            strict
        };
        (if matches.len() == 1 { matches.pop() } else { None }, short)
    };
    if let Some(row) = hit {
        let name = if by_short_name && !key.contains('/') {
            RemoteName::Short { closed: remote_closed(row) }
        } else {
            RemoteName::Direct
        };
        return Some((row, name));
    }
    let route = map.former_route(key)?.ok()?;
    Some((map.get(&route)?, RemoteName::Former))
}

/// Whether peer session `r` is closed (its row's `status`).
pub(in crate::hub) fn remote_closed(r: &RemoteSession) -> bool {
    r.summary.closed()
}

/// Whether `key` is peer session `r`'s short name, its name's last segment: a bare
/// `mac-ci-3` for `PEER/claude-sr2/mac-ci-3` on any peer, or `PEER/mac-ci-3` on that peer only.
pub(in crate::hub) fn remote_segment(r: &RemoteSession, key: &str) -> bool {
    let name = r.summary.name().unwrap_or("");
    if !key.contains('/') {
        return crate::session_name::ends_with_segments(name, key);
    }
    let peer = format!("{}/", r.peer);
    key.strip_prefix(&peer).is_some_and(|rest| {
        !rest.contains('/')
            && crate::session_name::ends_with_segments(
                name.strip_prefix(&peer).unwrap_or(name),
                rest,
            )
    })
}

/// Whether `key` names the peer's session `r` (listed under `id`): its name, a prefix of its id,
/// or `PEER/NAME`.
pub(in crate::hub) fn names_remote(id: &str, r: &RemoteSession, key: &str) -> bool {
    let name = r.summary.name().unwrap_or("");
    let alias = r.summary.alias();
    name == key
        || alias == Some(key)
        || r.receipt.mux_session_id.starts_with(key)
        || id.starts_with(key)
        || name.strip_prefix(&format!("{}/", r.peer)) == Some(key)
}
