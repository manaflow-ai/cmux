//! What the mesh relay (`server/mesh_relay.rs`) reads of this daemon's sessions: the rows it
//! heartbeats to the hub, and the session a relayed message names. Both are this daemon's own
//! sessions only, never a peer's: the hub reaches each daemon for its own sessions, and a message
//! from the hub is never forwarded to a peer.

use super::*;
use crate::mesh::{MAX_HEARTBEAT_SESSIONS, SessionRow, Target};

impl Hub {
    /// The daemon is stopping (`_acpmux/shutdown`, a signal): the relay ends with it.
    pub fn is_stopping(&self) -> bool {
        self.stopping.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// The sessions here a heartbeat lists: every one but a closed one, at most
    /// [`MAX_HEARTBEAT_SESSIONS`], working ones first, then the most recently changed. Read under
    /// each one's meta lock (no clone of a meta).
    pub fn mesh_rows(&self) -> Vec<SessionRow> {
        let sessions: Vec<Arc<Session>> = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        let rank = |status: SessionStatus| match status {
            SessionStatus::Running | SessionStatus::Waiting => 0,
            SessionStatus::Ready => 1,
            _ => 2,
        };
        let mut rows: Vec<(u8, u64, SessionRow)> = sessions
            .iter()
            .filter_map(|s| {
                let m = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                (m.status != SessionStatus::Closed).then(|| {
                    let row = SessionRow {
                        name: m.name.clone(),
                        session_id: s.id.clone(),
                        harness: m.harness.clone(),
                        state: m.status.to_string(),
                        stuck_reason: None,
                    };
                    (rank(m.status), m.updated_at, row)
                })
            })
            .collect();
        rows.sort_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)));
        // The hub refuses a heartbeat that lists one name twice. Names are unique here
        // (`admission.rs`), so this is a guard: a shared name is listed once, for the session that
        // works most.
        let mut seen = std::collections::HashSet::new();
        rows.into_iter()
            .map(|(_, _, row)| row)
            .filter(|row| seen.insert(row.name.clone()))
            .take(MAX_HEARTBEAT_SESSIONS)
            .collect()
    }

    /// Whether a send to `target` may go to the mesh hub: nothing here or on a peer names it. Not
    /// a session here (one or several), not one or several that a peer lists, not one on a peer
    /// that is down now. An ambiguous name stays this daemon's refusal; the hub is never asked to
    /// pick.
    pub fn mesh_may_route(&self, target: &str) -> bool {
        self.resolve(target).is_err_and(|e| e.code == RpcError::not_found("").code)
            && self.remote_matches(target) == 0
            && self.peer_down_for(target).is_none()
    }

    /// Whether a relayed message is for this daemon: refused when it names another host, or a
    /// daemon id other than `own_daemon` (this daemon's id at the hub, once the hub has told it;
    /// with none known, any daemon id is refused). Every relayed message, control ones included,
    /// passes this before anything here acts on it.
    pub fn mesh_for_here(&self, to: &Target, own_daemon: Option<&str>) -> Result<(), String> {
        if let Some(host) = to.host.as_deref().filter(|h| !h.is_empty())
            && !is_own_host(host)
        {
            return Err(format!("the message is for host {host:?}, not this one"));
        }
        if let Some(daemon) = to.daemon_id.as_deref().filter(|d| !d.is_empty())
            && own_daemon != Some(daemon)
        {
            return Err(format!("the message is for daemon {daemon:?}, not this one"));
        }
        Ok(())
    }

    /// The session here a relayed message is for: its exact id, else its whole name (bare, or as
    /// `HOST/NAME` with this machine's name). Never a prefix, never a peer's session. A message
    /// for another host or daemon ([`Hub::mesh_for_here`]) is refused rather than given to a
    /// session here that shares the name. The refusal names nothing but the key it was given.
    pub fn mesh_target(
        &self,
        to: &Target,
        own_daemon: Option<&str>,
    ) -> Result<Arc<Session>, String> {
        self.mesh_for_here(to, own_daemon)?;
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(id) = to.session_id.as_deref().filter(|id| !id.is_empty()) {
            return sessions.get(id).cloned().ok_or_else(|| format!("no session {id:?} here"));
        }
        let key =
            to.name.as_deref().filter(|n| !n.is_empty()).ok_or("the message names no session")?;
        let name = match key.split_once('/') {
            Some((host, rest)) if !rest.is_empty() && is_own_host(host) => rest,
            _ => key,
        };
        let mut named: Vec<_> = sessions
            .values()
            .filter(|s| {
                s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner).name == name
            })
            .cloned()
            .collect();
        match named.len() {
            1 => Ok(named.remove(0)),
            0 => Err(format!("no session {key:?} here")),
            n => Err(format!("{key:?} names {n} sessions here; send to its session id")),
        }
    }
}

/// Whether `host` is this machine's name (never the "host" stand-in for an unusable one).
fn is_own_host(host: &str) -> bool {
    let own = crate::pairing::machine_name();
    own != "host" && host.eq_ignore_ascii_case(&own)
}

#[cfg(test)]
mod mesh_route_tests {
    use super::*;
    use crate::config::{Config, StoreMode};
    use crate::session_identity::SessionReceipt;
    use serde_json::json;

    fn row(peer: &str, id: &str, name: &str) -> RemoteSession {
        RemoteSession {
            peer: peer.into(),
            summary: json!({"sessionId": id, "name": name}),
            receipt: SessionReceipt {
                host_id: peer.into(),
                mux_session_id: id.into(),
                agent_session_id: None,
                generation: 1,
            },
        }
    }

    /// A name two peers list is ambiguous: it is never sent to the hub to pick one.
    #[tokio::test]
    async fn a_name_one_or_several_peers_list_never_goes_to_the_mesh_hub() {
        let mut config: Config = serde_json::from_value(json!({})).expect("config");
        config.store.mode = StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).expect("store");
        let hub = Hub::new(config, store);
        assert!(hub.mesh_may_route("dep-land"));
        hub.remote_sessions.lock().unwrap().insert("p1/s1".into(), row("p1", "s1", "dep-land"));
        assert!(!hub.mesh_may_route("dep-land"), "one peer lists it");
        hub.remote_sessions.lock().unwrap().insert("p2/s2".into(), row("p2", "s2", "dep-land"));
        assert_eq!(hub.remote_matches("dep-land"), 2);
        assert!(hub.resolve_remote("dep-land").is_none(), "ambiguous");
        assert!(!hub.mesh_may_route("dep-land"), "two peers list it");
        assert!(hub.mesh_may_route("other"));
    }
}
