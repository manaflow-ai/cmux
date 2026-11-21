//! Part of `Hub`; see `hub/mod.rs`. A chat whose agent host is below this build's level moves onto
//! the installed build at its next idle point.
//!
//! An update swaps the daemon at once, while every agent host it adopts keeps the binary it
//! started from until its chat hibernates (`views/host_build.rs`), and a chat at work never
//! reaches the 2-minute idle period: its turns follow each other within it. So a fix that lives in
//! the host, as Claude Code's translator does, never reached the chats that needed it most: after
//! the next-prompt suggestions moved behind a person's own turn
//! (`claude_stdio/prompt_suggestions.rs`), 35 of 41 live hosts on one Mac and the busy lanes still
//! ran the build before it, and the team gateway still saw about 1,100 suggestions an hour (sr2
//! audit, 2026-11-21).
//!
//! A host whose record says a lower [`crate::agent_host::HOST_LEVEL`] (an older build's says none:
//! 0) and another build than the daemon's moves once its chat is idle for [`MOVE_AFTER`]: the
//! idle pass hibernates it as at the end of an idle period, under every gate of that pass (no
//! turn running or queued, no question, nothing at work below it, its process census clear), so
//! nothing is lost, and the next prompt resumes the chat (`claude --resume`) on a host of the
//! installed build. A census that finds a process the harness did not report keeps it up, and
//! the chat then waits for the normal idle period as before: such a process (a dev server) would
//! keep it up at every try. Each chat moves at most once per daemon run, so a wake that starts a
//! host below the level again (a launcher of an older binary) never makes it move at every idle
//! point. Nothing moves while idle hibernation is off (`ACPMUX_IDLE_CHILD_SECS=0`): an agent the
//! daemon is told to keep, it keeps.

use crate::hub::*;

/// How long a chat whose host must move waits idle first: long enough that what follows its turn
/// (a queued notice, a script's next prompt) comes first, short against the idle period.
pub(super) const MOVE_AFTER: std::time::Duration = std::time::Duration::from_secs(10);

impl Hub {
    /// Whether `session`'s live host moves at its next idle point (module docs). False while a
    /// start or stop holds the child's slot.
    pub(super) fn host_moves(&self, session: &Session) -> bool {
        let below = session.child.try_lock().ok().is_some_and(|child| {
            child.as_ref().is_some_and(|c| c.host_below(crate::agent_host::HOST_LEVEL))
        });
        below
            && !self
                .host_moved
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .contains(&session.id)
    }

    /// The idle period of `session`: [`MOVE_AFTER`] when its host moves, else `idle`.
    pub(super) fn idle_period(
        &self,
        session: &Session,
        idle: std::time::Duration,
    ) -> std::time::Duration {
        if self.host_moves(session) { MOVE_AFTER.min(idle) } else { idle }
    }

    /// `session`'s move is done or given up: it waits for the normal idle period from now on.
    pub(super) fn host_move_settled(&self, session: &Session) {
        self.host_moved
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(session.id.clone());
    }
}
