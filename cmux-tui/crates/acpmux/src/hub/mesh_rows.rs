//! The session a relayed message (`server/mesh_relay.rs`) names: one of this daemon's own, never
//! a peer's. The hub reaches each daemon for its own sessions, and a message from the hub is
//! never forwarded to a peer.

use super::*;
use crate::mesh::Target;

impl Hub {
    /// The daemon is stopping (`_acpmux/shutdown`, a signal): the relay ends with it.
    pub fn is_stopping(&self) -> bool {
        self.stopping.load(std::sync::atomic::Ordering::SeqCst)
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
