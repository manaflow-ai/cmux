//! The session a relayed message (`server/mesh_relay.rs`) names: one of this daemon's own, never
//! a peer's. The hub reaches each daemon for its own sessions, and a message from the hub is
//! never forwarded to a peer.

use super::*;
use crate::mesh::Target;

impl Hub {
    /// The session here a relayed message is for: its exact id, else its whole name (bare, or as
    /// `HOST/NAME` with this machine's name). Never a prefix, never a peer's session. The refusal
    /// names nothing but the key it was given.
    pub fn mesh_target(&self, to: &Target) -> Result<Arc<Session>, String> {
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(id) = to.session_id.as_deref().filter(|id| !id.is_empty()) {
            return sessions.get(id).cloned().ok_or_else(|| format!("no session {id:?} here"));
        }
        let key =
            to.name.as_deref().filter(|n| !n.is_empty()).ok_or("the message names no session")?;
        let own = crate::pairing::machine_name();
        let name = match key.split_once('/') {
            Some((host, rest))
                if !rest.is_empty() && own != "host" && host.eq_ignore_ascii_case(&own) =>
            {
                rest
            }
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
