//! The session a relayed message (`server/mesh_relay.rs`) names: one of this daemon's own, never
//! a peer's. The hub reaches each daemon for its own sessions, and a message from the hub is
//! never forwarded to a peer.

use super::*;
use crate::mesh::Target;

impl Hub {
    /// The session here a relayed message is for: its exact id, else its whole name (bare, or as
    /// `HOST/NAME` with this machine's name). Never a prefix, never a peer's session. A message
    /// that names another host, or any daemon (this one cannot prove an id is its own), is refused
    /// rather than given to a session here that shares the name. The refusal names nothing but
    /// the key it was given.
    pub fn mesh_target(&self, to: &Target) -> Result<Arc<Session>, String> {
        let own = crate::pairing::machine_name();
        let ours = |host: &str| own != "host" && host.eq_ignore_ascii_case(&own);
        if let Some(host) = to.host.as_deref().filter(|h| !h.is_empty())
            && !ours(host)
        {
            return Err(format!("the message is for host {host:?}, not this one"));
        }
        if to.daemon_id.as_deref().is_some_and(|d| !d.is_empty()) {
            return Err("the message names a daemon, and this one takes only its sessions".into());
        }
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(id) = to.session_id.as_deref().filter(|id| !id.is_empty()) {
            return sessions.get(id).cloned().ok_or_else(|| format!("no session {id:?} here"));
        }
        let key =
            to.name.as_deref().filter(|n| !n.is_empty()).ok_or("the message names no session")?;
        let name = match key.split_once('/') {
            Some((host, rest)) if !rest.is_empty() && ours(host) => rest,
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
