//! Agent hook events dropped because their session ended (rule R-L5: a limit
//! that drops user data shows the loss).
//!
//! The hook helper keeps each agent's hook events in a queue on disk,
//! `hook-spool/` beside the session socket, until the daemon answers them
//! (cmux-tui `cmux-tui-hook/hook_spool.rs`). A queue is dropped only when its
//! session ended (its daemon removed the socket): the hook child that drops it
//! adds its events to `hook-spool/ended-session-events`, and `server-stats`
//! reports that count when its request names `hook_queue`.

use std::path::Path;

use serde::Serialize;

/// The directory of hook queues, beside the session socket.
pub const HOOK_SPOOL_DIR: &str = "hook-spool";
/// The count of hook events dropped with their session, in [`HOOK_SPOOL_DIR`].
pub const HOOK_SPOOL_ENDED_EVENTS: &str = "ended-session-events";

/// `server-stats` `hook_queue`.
#[derive(Clone, Debug, Default, Serialize)]
pub struct HookQueueSnapshot {
    /// Hook events of sessions that ended before the daemon answered them,
    /// counted by the hook children that dropped them, for every session
    /// whose socket shares this one's directory.
    pub ended_session_events: u64,
}

impl HookQueueSnapshot {
    /// The count beside `socket` (0 when nothing was ever dropped there).
    pub fn beside(socket: &Path) -> Self {
        let count = socket
            .parent()
            .map(|directory| directory.join(HOOK_SPOOL_DIR).join(HOOK_SPOOL_ENDED_EVENTS))
            .and_then(|path| std::fs::read_to_string(path).ok())
            .and_then(|text| text.trim().parse().ok())
            .unwrap_or(0);
        Self { ended_session_events: count }
    }
}
