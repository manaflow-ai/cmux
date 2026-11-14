//! `HOST/NAME` with this machine's own name as `HOST`: the form other machines list a session
//! under (`peers.rs` `resolve_remote`), which coordinators use for every lane. On the lane's own
//! machine that name was `no_session`.

use super::*;

impl Hub {
    /// Resolve by id, exact name, or unique prefix of either. A key that finds nothing and reads
    /// `HOST/NAME` with this machine's own peer name as `HOST` finds the session here whose id or
    /// whole name is `NAME`. Never a prefix of `NAME`, and never when a peer of this daemon has
    /// that name (its session is the one meant), so it can only reach a session the bare `NAME`
    /// names exactly.
    pub fn resolve(&self, key: &str) -> Result<Arc<Session>, RpcError> {
        // A configured peer owns its namespace even when its mirrored row disappeared
        // after lookup. A local display name must never intercept the resolved route.
        // The refusal reads as for a name that is no peer: a peer's connection gets this
        // answer and must not learn this host's peers from it.
        if let Some((host, _)) = key.split_once('/')
            && self.peer(host).is_some()
        {
            return Err(RpcError::not_found(format!("no session matches {key:?}")));
        }
        let found = self.resolve_here(key);
        if found.as_ref().is_err_and(|e| e.code == RpcError::not_found("").code)
            && let Some((host, rest)) = key.split_once('/')
            && !rest.is_empty()
            && is_own_machine_name(host)
            && self.peer(host).is_none()
        {
            // Its whole name first, then its short name (`Hub::resolve_short_here`).
            return self
                .resolve_exact(rest)
                .or_else(|| self.resolve_short_here(rest))
                .unwrap_or(found);
        }
        found
    }

    /// [`Self::resolve`] for a caller that is told why it failed: a key no session here or on a
    /// peer names comes back with the names it nearly matched (`Hub::unknown_session`) when
    /// `tell` (a connection that may read every name: the local socket).
    pub fn resolve_told(&self, key: &str, tell: bool) -> Result<Arc<Session>, RpcError> {
        self.resolve(key).map_err(|e| {
            let plain = e.code == RpcError::not_found("").code
                && e.message.starts_with("no session matches");
            if tell && plain { self.unknown_session(key) } else { e }
        })
    }

    /// The session whose id or whole name is `key`: None when none is; an error when several
    /// share the name.
    fn resolve_exact(&self, key: &str) -> Option<Result<Arc<Session>, RpcError>> {
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(s) = sessions.get(key) {
            return Some(Ok(s.clone()));
        }
        let mut named: Vec<_> = sessions
            .values()
            .filter(|s| {
                s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner).name == key
            })
            .cloned()
            .collect();
        match named.len() {
            0 => None,
            1 => Some(Ok(named.remove(0))),
            n => Some(Err(RpcError::invalid_params(format!(
                "{key:?} names {n} sessions; use the id"
            )))),
        }
    }
}

/// Whether `host` is this machine's name as its peers know it (`pairing::machine_name`, the
/// host name's first label; any case, as `Air-Blue` for `air-blue`). The fallback `host` (a host
/// name that is no session name) is no one's name.
pub(super) fn is_own_machine_name(host: &str) -> bool {
    static NAME: std::sync::LazyLock<String> =
        std::sync::LazyLock::new(crate::pairing::machine_name);
    NAME.as_str() != "host" && host.eq_ignore_ascii_case(&NAME)
}

#[cfg(test)]
mod segment_tests;
