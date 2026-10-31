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
mod segment_tests {
    use super::*;
    use crate::session_identity::SessionReceipt;
    use serde_json::json;

    fn hub_with(names: &[(&str, &str)]) -> Arc<Hub> {
        let names: Vec<(String, String)> =
            names.iter().map(|(i, n)| ((*i).to_owned(), (*n).to_owned())).collect();
        let cfg: crate::config::Config =
            serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        for (id, name) in &names {
            let meta: crate::store::SessionMeta = serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": id, "name": name,
                "harness": "claude", "cwd": "/w", "status": "idle",
                "createdAt": 1, "updatedAt": 1,
            }))
            .unwrap();
            let session = hub.make_session(meta);
            hub.sessions.lock().unwrap().insert(id.clone(), session);
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

    /// A peer that is listed but never runs, so `resolve_remote` can route to it.
    fn add_peer(hub: &Hub, name: &str) {
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.to_owned(), peer);
    }

    fn remote_id(hub: &Hub, key: &str) -> Option<String> {
        hub.resolve_remote(key).map(|(p, id, _)| format!("{}/{id}", p.name))
    }

    /// A whole name is meant over a short name: here, and on a peer.
    #[test]
    fn a_whole_name_beats_a_short_name_here_or_on_a_peer() {
        let hub = hub_with(&[("m1", "claude-sr2/lane"), ("m2", "lane")]);
        assert_eq!(id(hub.resolve("lane")), "m2");
        let hub = hub_with(&[("m1", "claude-sr2/lane")]);
        add_peer(&hub, "hb");
        peer_row(&hub, "hb", "r1", "hb/lane");
        assert!(hub.resolve("lane").is_err(), "the peer's `lane` is the one meant");
        assert_eq!(remote_id(&hub, "lane").as_deref(), Some("hb/r1"));
    }

    /// Two sub-sessions with the short name are refused with their names, so the caller picks.
    #[test]
    fn two_sub_sessions_with_the_short_name_are_refused_with_both() {
        let hub = hub_with(&[("m1", "a/lane"), ("m2", "b/lane")]);
        let e = err(hub.resolve("lane"));
        assert!(e.message.contains("matches 2 sessions"), "{}", e.message);
        assert!(e.message.contains("a/lane (m1), b/lane (m2)"), "{}", e.message);
        assert_eq!(e.data.unwrap()["reason"], "ambiguous_session");
    }

    /// Short names are the last tier: a key that found a session before by a prefix, here or
    /// on a peer, finds the same one now (review of #27791 at 8fb3993).
    #[test]
    fn a_prefix_here_or_on_a_peer_still_wins_over_a_short_name() {
        let hub = hub_with(&[("m1", "a/lane"), ("m2", "lane-2")]);
        assert_eq!(id(hub.resolve("lane")), "m2", "a unique prefix, as before");
        let hub = hub_with(&[("m1", "a/s")]);
        add_peer(&hub, "hb");
        peer_row(&hub, "hb", "s123", "hb/other");
        assert!(hub.resolve("s").is_err(), "the peer's id prefix is meant");
        assert_eq!(remote_id(&hub, "s").as_deref(), Some("hb/s123"));
        // A local prefix keeps a peer's short name from taking the key.
        let hub = hub_with(&[("m1", "sx")]);
        add_peer(&hub, "hb");
        peer_row(&hub, "hb", "r1", "hb/a/s");
        assert_eq!(id(hub.resolve("s")), "m1");
        assert_eq!(remote_id(&hub, "s"), None);
    }

    /// Review of #27791: a short name here and one on a peer are a tie on both routes, never
    /// one picked silently.
    #[test]
    fn a_short_name_here_and_on_a_peer_is_a_tie_on_both_routes() {
        let hub = hub_with(&[("m1", "a/lane")]);
        add_peer(&hub, "hb");
        peer_row(&hub, "hb", "r1", "hb/b/lane");
        let e = err(hub.resolve("lane"));
        assert!(e.message.contains("a/lane (m1), hb/b/lane (hb/r1)"), "{}", e.message);
        assert_eq!(remote_id(&hub, "lane"), None, "the peer route does not take it either");
        // Two here and one on a peer: still a tie, not the peer's.
        let hub = hub_with(&[("m1", "a/lane"), ("m2", "b/lane")]);
        add_peer(&hub, "hb");
        peer_row(&hub, "hb", "r1", "hb/c/lane");
        assert!(err(hub.resolve("lane")).message.contains("matches 3 sessions"));
        assert_eq!(remote_id(&hub, "lane"), None);
        // A peer's alone is the peer route's.
        let hub = hub_with(&[("m1", "other")]);
        add_peer(&hub, "hb");
        peer_row(&hub, "hb", "r1", "hb/claude-sr2/mac-ci-3");
        assert!(hub.resolve("mac-ci-3").is_err());
        assert_eq!(remote_id(&hub, "mac-ci-3").as_deref(), Some("hb/r1"));
        assert_eq!(remote_id(&hub, "hb/mac-ci-3").as_deref(), Some("hb/r1"));
    }

    /// Review of #27791: `PEER/SHORT` reaches that peer only, never another peer's session
    /// whose name happens to end in `PEER/SHORT`.
    #[test]
    fn a_peer_qualified_short_name_stays_on_that_peer() {
        let hub = hub_with(&[]);
        add_peer(&hub, "hb");
        add_peer(&hub, "cg");
        peer_row(&hub, "cg", "r1", "cg/parent/hb/lane");
        assert_eq!(remote_id(&hub, "hb/lane"), None);
        assert_eq!(hub.remote_matches("hb/lane"), 0);
        peer_row(&hub, "hb", "r2", "hb/x/lane");
        assert_eq!(remote_id(&hub, "hb/lane").as_deref(), Some("hb/r2"));
        assert_eq!(remote_id(&hub, "cg/lane").as_deref(), Some("cg/r1"));
        assert_eq!(hub.remote_matches("hb/ane"), 0, "on a `/` boundary only");
    }

    /// Review of #27791: `OWN/NAME` finds the session here named `NAME` exactly before a short
    /// name, and a key with a `/` is never a short name here.
    #[test]
    fn this_machines_qualified_name_keeps_its_exact_match_first() {
        let own = crate::pairing::machine_name();
        if own == "host" {
            return;
        }
        let nested = format!("parent/{own}/lane");
        let hub = hub_with(&[("m1", "lane"), ("m2", nested.as_str()), ("m3", "a/x")]);
        assert_eq!(id(hub.resolve(&format!("{own}/lane"))), "m1");
        assert_eq!(id(hub.resolve(&format!("{own}/x"))), "m3", "its short name, on this host");
        assert!(hub.resolve("parent/x").is_err(), "a key with a `/` is no short name");
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

    /// Review of #27791: a short name skips closed sessions while a live one has it, here and
    /// on peers, as `key_route` does; only closed ones still tie among themselves.
    #[test]
    fn a_short_name_counts_closed_sessions_only_when_none_is_live() {
        let hub = hub_with(&[("m1", "a/lane"), ("m2", "b/lane")]);
        let closed = hub.sessions.lock().unwrap().get("m2").cloned().unwrap();
        hub.set_status(&closed, SessionStatus::Closed);
        assert_eq!(id(hub.resolve("lane")), "m1", "the live one, not a tie with the closed one");
        let live = hub.sessions.lock().unwrap().get("m1").cloned().unwrap();
        hub.set_status(&live, SessionStatus::Closed);
        assert!(err(hub.resolve("lane")).message.contains("matches 2 sessions"), "both closed");

        // `OWN/SHORT` keeps the same rule (review of #27791's base merge).
        let own = crate::pairing::machine_name();
        if own != "host" {
            let hub = hub_with(&[("m1", "a/lane"), ("m2", "b/lane")]);
            let closed = hub.sessions.lock().unwrap().get("m2").cloned().unwrap();
            hub.set_status(&closed, SessionStatus::Closed);
            assert_eq!(id(hub.resolve(&format!("{own}/lane"))), "m1", "the live one here");
            let live = hub.sessions.lock().unwrap().get("m1").cloned().unwrap();
            hub.set_status(&live, SessionStatus::Closed);
            assert!(err(hub.resolve(&format!("{own}/lane"))).message.contains("matches 2"));
        }

        // A closed peer session with the short name gives way to a live one here, and a live
        // peer one is the peer route's while every one here is closed.
        let hub = hub_with(&[("m1", "a/lane")]);
        let row = RemoteSession {
            peer: "hb".into(),
            summary: json!({"sessionId": "r1", "name": "hb/c/lane", "peer": "hb",
                            "status": "closed"}),
            receipt: SessionReceipt {
                host_id: "hb".into(),
                mux_session_id: "r1".into(),
                agent_session_id: None,
                generation: 1,
            },
        };
        hub.remote_sessions.lock().unwrap().insert("hb/r1".into(), row);
        assert_eq!(id(hub.resolve("lane")), "m1");
        assert!(hub.resolve_remote("lane").is_none());
    }

    /// Review of #27791: a peer daemon's or a read-only machine's `_acpmux/resolve` learns no
    /// session names from a miss.
    #[test]
    fn a_resolve_miss_names_close_matches_only_to_a_caller_that_reads_hosts() {
        let hub = hub_with(&[("m1", "coord/lane-3")]);
        let told = hub.locate("lane", false, true).unwrap_err();
        assert_eq!(told.data.unwrap()["candidates"], json!(["coord/lane-3"]));
        let untold = hub.locate("lane", false, false).unwrap_err();
        assert!(untold.data.is_none(), "{untold:?}");
    }
}
