//! What the mesh relay (`server/mesh_relay.rs`) reads of this daemon's sessions: the rows it
//! heartbeats to the hub, and the session a relayed message names. Both are this daemon's own
//! sessions only, never a peer's: the hub reaches each daemon for its own sessions, and a message
//! from the hub is never forwarded to a peer.

use super::*;
use crate::mesh::{MAX_HEARTBEAT_SESSIONS, SessionRow, Target};

impl Hub {
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
        rows.into_iter().take(MAX_HEARTBEAT_SESSIONS).map(|(_, _, row)| row).collect()
    }

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
