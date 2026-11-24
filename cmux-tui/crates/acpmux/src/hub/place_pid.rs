//! The process id of a chat's agent, for `server/place_set.rs`: what a move would leave behind
//! is read off the processes under it.

use super::*;

impl Hub {
    /// The agent's pid, or none while the chat has no agent process (paused, stopped).
    pub(crate) async fn agent_pid(&self, session: &Session) -> Option<u32> {
        session.child.lock().await.as_ref().and_then(|child| child.pid)
    }
}
