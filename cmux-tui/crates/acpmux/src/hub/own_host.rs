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
        if let Some((host, _)) = key.split_once('/')
            && self.peer(host).is_some()
        {
            return Err(RpcError::not_found(format!("no local session with the id {key:?}")));
        }
        let found = self.resolve_here(key);
        if found.as_ref().is_err_and(|e| e.code == RpcError::not_found("").code)
            && let Some((host, rest)) = key.split_once('/')
            && !rest.is_empty()
            && is_own_machine_name(host)
            && self.peer(host).is_none()
        {
            return self.resolve_exact(rest).unwrap_or(found);
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
fn is_own_machine_name(host: &str) -> bool {
    static NAME: std::sync::LazyLock<String> =
        std::sync::LazyLock::new(crate::pairing::machine_name);
    NAME.as_str() != "host" && host.eq_ignore_ascii_case(&NAME)
}

#[cfg(test)]
mod segment_tests {
    use super::*;
    use crate::session_identity::SessionReceipt;
    use serde_json::json;

    fn hub_with(names: &[(&str, &str)]) -> Arc<Hub> {
        let cfg: crate::config::Config =
            serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        for (id, name) in names {
            let meta: crate::store::SessionMeta = serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": id, "name": name,
                "harness": "claude", "cwd": "/w", "status": "idle",
                "createdAt": 1, "updatedAt": 1,
            }))
            .unwrap();
            let session = hub.make_session(meta);
            hub.sessions.lock().unwrap().insert((*id).into(), session);
        }
        hub
    }

    fn peer_row(hub: &Hub, peer: &str, id: &str, name: &str) {
        let row = RemoteSession {
            peer: peer.into(),
            summary: json!({"sessionId": id, "name": name, "peer": peer}),
            receipt: SessionReceipt {
                host_id: peer.into(),
                mux_session_id: id.into(),
                agent_session_id: None,
                generation: 1,
            },
        };
        hub.remote_sessions.lock().unwrap().insert(format!("{peer}/{id}"), row);
    }

    fn id(r: Result<Arc<Session>, RpcError>) -> String {
        r.map(|s| s.id.clone()).unwrap_or_else(|e| panic!("{}", e.message))
    }

    fn err(r: Result<Arc<Session>, RpcError>) -> RpcError {
        r.err().expect("refused")
    }

    /// `acpmux send mac-ci-3` was no_session when the lane is the coordinator's sub-session
    /// `claude-sr2/mac-ci-3`: its last name segments name it, on a `/` boundary only.
    #[test]
    fn a_sub_session_is_found_by_its_short_name() {
        let hub = hub_with(&[("m1", "claude-sr2/mac-ci-3"), ("m2", "claude-sr2"), ("m3", "x")]);
        assert_eq!(id(hub.resolve("mac-ci-3")), "m1");
        assert_eq!(id(hub.resolve("claude-sr2/mac-ci-3")), "m1");
        assert_eq!(id(hub.resolve("claude-sr2")), "m2", "a whole name beats a prefix");
        let e = err(hub.resolve("ci-3"));
        assert!(e.message.starts_with("no session matches \"ci-3\""), "{}", e.message);
        assert!(e.data.is_none(), "a probe's miss lists nothing: {e:?}");
    }

    /// A whole name is meant over a segment: here, and on a peer.
    #[test]
    fn a_whole_name_beats_a_short_name_here_or_on_a_peer() {
        let hub = hub_with(&[("m1", "claude-sr2/lane"), ("m2", "lane")]);
        assert_eq!(id(hub.resolve("lane")), "m2");
        let hub = hub_with(&[("m1", "claude-sr2/lane")]);
        peer_row(&hub, "hb", "r1", "hb/lane");
        assert!(hub.resolve("lane").is_err(), "the peer's `lane` is the one meant");
        assert_eq!(hub.resolve_remote("lane").map(|(_, id, _)| id), None, "no peer is connected");
        assert_eq!(hub.remote_matches("lane"), 1);
    }

    /// Two sub-sessions with the short name are refused with their names, so the caller picks;
    /// a third session the key is a prefix of does not settle it.
    #[test]
    fn two_sub_sessions_with_the_short_name_are_refused_with_both() {
        let hub = hub_with(&[("m1", "a/lane"), ("m2", "b/lane"), ("m3", "lane-2")]);
        let e = err(hub.resolve("lane"));
        assert!(e.message.contains("matches 3 sessions"), "{}", e.message);
        assert!(e.message.contains("a/lane (m1), b/lane (m2), lane-2 (m3)"), "{}", e.message);
        assert_eq!(e.data.unwrap()["reason"], "ambiguous_session");
    }

    /// A peer's sub-session is found by its short name, with or without the peer's name.
    #[test]
    fn a_peers_sub_session_is_found_by_its_short_name() {
        let hub = hub_with(&[]);
        peer_row(&hub, "cg", "r1", "cg/claude-sr2/mac-ci-3");
        assert_eq!(hub.remote_matches("mac-ci-3"), 1);
        assert_eq!(hub.remote_matches("cg/mac-ci-3"), 1);
        assert_eq!(hub.remote_matches("ci-3"), 0);
        assert_eq!(hub.remote_strict_matches("mac-ci-3"), 0);
    }

    /// The refusal a caller reads names the close matches, here and on peers.
    #[test]
    fn an_unknown_name_is_told_with_the_close_matches() {
        let hub = hub_with(&[("m1", "claude-sr2/mac-ci-3"), ("m2", "unrelated")]);
        peer_row(&hub, "hb", "r1", "hb/mac-ci-30");
        let e = err(hub.resolve_told("mac-ci", true));
        assert!(e.message.starts_with("no session matches \"mac-ci\""), "{}", e.message);
        let close = e.data.unwrap()["candidates"].clone();
        assert_eq!(close, json!(["claude-sr2/mac-ci-3", "hb/mac-ci-30"]));
        let untold = err(hub.resolve_told("mac-ci", false));
        assert!(untold.data.is_none(), "{untold:?}");
    }
}
