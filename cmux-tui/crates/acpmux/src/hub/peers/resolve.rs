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
        // Only the one row picked is parsed.
        let row = |r: &RemoteSession| {
            (r.peer.clone(), r.receipt.mux_session_id.clone(), r.summary.value())
        };
        let (hit, by_short_name) = if let Some(r) = map.get(key) {
            (Some(row(r)), false)
        } else {
            // Whole names and prefixes first; the short-name candidates count only when none
            // matched. Only the rows the indexes say `key` can name are read (`remote_rows.rs`),
            // never every peer's, and the predicates still decide which of them it names. Only
            // the one row picked is cloned.
            let strict: Vec<&RemoteSession> = map
                .named(key)
                .into_iter()
                .filter(|(id, r)| names_remote(id, r, key))
                .map(|(_, r)| &**r)
                .collect();
            let shorts: Vec<&RemoteSession> = if strict.is_empty() {
                map.short_named(key)
                    .into_iter()
                    .filter(|(_, r)| remote_segment(r, key))
                    .map(|(_, r)| &**r)
                    .collect()
            } else {
                Vec::new()
            };
            let short = strict.is_empty();
            let mut matches: Vec<&RemoteSession> = if short {
                // Closed ones count only when no live one has the short name (`hub/key_route.rs`).
                let live = shorts.iter().any(|r| !remote_closed(r));
                shorts.into_iter().filter(|r| !live || !remote_closed(r)).collect()
            } else {
                strict
            };
            (if matches.len() == 1 { matches.pop().map(row) } else { None }, short)
        };
        drop(map);
        // No peer's session has it as its name: one that had it before a rename
        // (`former_names.rs`), only when no session here has or had it either.
        let hit = match hit {
            Some(hit) => Some(hit),
            None => {
                let route = self.former_remote_route(key)?.ok()?;
                if self.local_match_counts(key) != [0, 0, 0]
                    || self.resolve_former_here(key).is_some()
                {
                    return None;
                }
                let map = self.remote_sessions.read();
                map.get(&route).map(|r| row(r))
            }
        };
        let (peer_name, id, summary) = hit?;
        // A bare short name gives way to any session here `key` names by id, name or prefix, to
        // a live one here with the short name, and, when this one is closed, to a closed one
        // here too (`Hub::resolve_here` refuses those ties). Read only now, with the peers' rows
        // unlocked and a candidate in hand, so no other lookup scans this daemon's sessions a
        // second time.
        if by_short_name && !key.contains('/') {
            let [other, live_here, closed_here] = self.local_match_counts(key);
            let closed = summary.get("status").and_then(Value::as_str) == Some("closed");
            if other > 0 || live_here > 0 || (closed && closed_here > 0) {
                return None;
            }
        }
        let peer = self.peer(&peer_name)?;
        Some((peer, id, summary))
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
