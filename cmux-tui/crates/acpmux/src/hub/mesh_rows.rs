//! What the mesh relay (`server/mesh_relay.rs`) reads of this daemon's sessions: the rows it
//! heartbeats to the hub, and the session a relayed message names. Both are this daemon's own
//! sessions only, never a peer's: the hub reaches each daemon for its own sessions, and a message
//! from the hub is never forwarded to a peer.

use super::*;
use crate::mesh::{MAX_HEARTBEAT_SESSIONS, SessionRow, Target, heartbeat_meta};

impl Hub {
    /// The daemon is stopping (`_acpmux/shutdown`, a signal): the relay ends with it.
    pub fn is_stopping(&self) -> bool {
        self.stopping.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// The sessions here a heartbeat lists: every one but a closed one, at most
    /// [`MAX_HEARTBEAT_SESSIONS`], working ones first, then the most recently changed. Read under
    /// each one's meta lock (no clone of a meta).
    pub async fn mesh_rows(&self) -> Vec<SessionRow> {
        let team_enabled =
            self.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.team_messaging);
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
                    let stuck_reason = mesh_failure_reason(&m);
                    let title = m.title.as_deref().and_then(heartbeat_meta);
                    let title_source =
                        title.as_ref().and(m.title_source.as_deref()).and_then(heartbeat_meta);
                    let model = super::model_options::current_model(&m);
                    let host_build = super::views::live_host_build(s);
                    let row = SessionRow {
                        name: m.name.clone(),
                        session_id: s.id.clone(),
                        harness: m.harness.clone(),
                        // A watched chat whose app exited (`app_exit.rs`); a harness sandbox
                        // refusal or a BLOCKED reply is `failed` (`mesh_failure_reason`).
                        state: stuck_reason.as_ref().map_or_else(
                            || super::app_exit::row_status(s, m.status),
                            |_| "failed".into(),
                        ),
                        stuck_reason,
                        cwd: crate::mesh::heartbeat_cwd(&m.cwd.to_string_lossy()),
                        title,
                        title_source,
                        name_given: Some(m.name_given),
                        model: model.as_deref().and_then(heartbeat_meta),
                        agent_session_id: m.agent_session_id.as_deref().and_then(heartbeat_meta),
                        host_build: host_build.as_deref().and_then(heartbeat_meta),
                        handle: crate::mesh::heartbeat_handle(m.handle.as_deref(), &s.id),
                        team_address: team_enabled
                            .then(|| {
                                m.tags
                                    .get("teamAddress")
                                    .filter(|tag| {
                                        crate::mesh::valid_team_suffix(&tag.value)
                                            && tag
                                                .expires_at
                                                .map(|at| at > crate::store::now_ms())
                                                .unwrap_or(true)
                                    })
                                    .map(|tag| tag.value.clone())
                            })
                            .flatten(),
                        former_names: crate::mesh::heartbeat_former_names(
                            &m.former_names,
                            &m.succeeds,
                        ),
                        roles: crate::mesh::heartbeat_roles(&m.roles),
                        tags: crate::mesh::heartbeat_tags(&super::session::live_tags(&m)),
                        updated_at: (m.updated_at > 0).then_some(m.updated_at),
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

    /// Whether `target` is `HOST/KEY` on a machine only the mesh hub reaches: neither a peer of
    /// this daemon nor this machine, with nothing here or on a peer naming it
    /// ([`Self::mesh_may_route`]). A chat that moved there over the hub is one: the outbox follows
    /// its move to `HOST/ID` (`server/outbox.rs` `follow_move`), and this daemon's own lookup of
    /// that key can only say "no session HOST/ID on" this machine.
    pub fn mesh_only_host(&self, target: &str) -> bool {
        target.split_once('/').is_some_and(|(host, key)| {
            !host.is_empty()
                && !key.is_empty()
                && self.peer(host).is_none()
                && !is_own_host(host)
                && !super::own_host::is_own_machine_name(host)
        }) && self.mesh_may_route(target)
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
        let key = to
            .name
            .as_deref()
            .filter(|n| !n.is_empty())
            .or_else(|| to.team_address.as_deref().filter(|a| !a.is_empty()))
            .ok_or("the message names no session")?;
        if to.name.is_none() {
            let mut addressed: Vec<_> = sessions
                .values()
                .filter(|s| {
                    s.meta
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .tags
                        .get("teamAddress")
                        .is_some_and(|tag| {
                            tag.expires_at.map(|at| at > crate::store::now_ms()).unwrap_or(true)
                                && tag.value.trim_start_matches('@') == key.trim_start_matches('@')
                        })
                })
                .cloned()
                .collect();
            return match addressed.len() {
                1 => Ok(addressed.remove(0)),
                0 => Err(format!("no session {key:?} here")),
                n => Err(format!("{key:?} names {n} sessions here; send to its session id")),
            };
        }
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

/// Keep the mesh heartbeat's failure projection in step with the local row projection without
/// constructing a full summary for every session. Only the harness's persisted sandbox refusal
/// and an explicit BLOCKED reply are failures; arbitrary prose and ordinary turn errors remain
/// their normal state.
fn mesh_failure_reason(meta: &crate::store::SessionMeta) -> Option<String> {
    let raw = if meta.harness_sandbox.failing {
        meta.harness_sandbox.error.as_deref()
    } else if !matches!(meta.status, SessionStatus::Idle | SessionStatus::Ready) {
        // A previous BLOCKED reply is ordinary preview text while a new turn is running (or
        // waiting for input); do not project that stale reply as a fresh heartbeat failure.
        None
    } else {
        meta.preview.as_deref().and_then(crate::session_liveness::blocked_reply)
    }?;
    let masked = crate::secret_scan::mask(raw);
    Some(masked.chars().take(512).collect())
}

/// Whether `host` is this machine's name on the mesh or its host name (never the "host"
/// stand-in for an unusable one).
pub(super) fn is_own_host(host: &str) -> bool {
    crate::pairing::is_this_machine(host)
}

#[cfg(test)]
#[path = "mesh_rows_mesh_route_tests.rs"]
mod mesh_route_tests;
