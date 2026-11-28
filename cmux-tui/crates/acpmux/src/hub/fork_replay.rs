//! Part of `Hub`; see `hub/mod.rs`. What the parent's agent sends for the session its own
//! `session/fork` makes is not the parent's.
//!
//! OpenCode answers `session/fork` only after it replayed the whole forked conversation as
//! `session/update`s under the NEW agent session's id (its `forkSession` runs `replayMessages`),
//! from the parent's process. Logged in the parent's transcript, the chat showed a second copy of
//! its own conversation, as a background turn that never ended (fork-hammer, 2026-11-22). The
//! fork never needs them: it loads its agent session in its own process (`fork.rs`), whose
//! `session/load` replays the same history into the fork's log, marked `.replay`.
//!
//! So while a `session/fork` the hub sent waits for its answer, an update under a session id the
//! chat does not know (not its agent session, not an earlier one, not one of its subagents) is the
//! fork's, and is dropped. Once the answer names the new session, any update under that id is
//! dropped too, whenever it comes. A native subagent's updates carry its own id on purpose
//! (`crate::subagents`): it is known by its spawn, which comes under the chat's own id, so it is
//! never dropped.

use super::*;
use std::sync::atomic::AtomicUsize;

/// The forked agent session ids remembered per chat: a chat forked more often than this forgets
/// its oldest ones, whose agent sessions the parent's process no longer reports on by then.
const MADE_KEPT: usize = 32;

/// A chat's agent `session/fork` requests (`Session::fork_replay`).
#[derive(Debug, Default)]
pub(crate) struct ForkReplay {
    /// The `session/fork` requests sent to its agent that wait for their answer.
    asking: AtomicUsize,
    /// The agent session ids those requests made, newest last.
    made: StdMutex<std::collections::VecDeque<String>>,
}

/// Held while one `session/fork` waits for its answer.
pub(crate) struct Asking<'a>(&'a ForkReplay);

impl Drop for Asking<'_> {
    fn drop(&mut self) {
        self.0.asking.fetch_sub(1, Ordering::SeqCst);
    }
}

impl ForkReplay {
    /// A `session/fork` goes to the agent now; the guard ends its wait.
    pub(crate) fn asking(&self) -> Asking<'_> {
        self.asking.fetch_add(1, Ordering::SeqCst);
        Asking(self)
    }

    /// The agent answered with `sid`: its updates are never the chat's.
    pub(crate) fn made(&self, sid: &str) {
        let mut made = self.made.lock().unwrap_or_else(|e| e.into_inner());
        if made.iter().any(|s| s == sid) {
            return;
        }
        if made.len() == MADE_KEPT {
            made.pop_front();
        }
        made.push_back(sid.to_owned());
    }

    fn is_made(&self, sid: &str) -> bool {
        self.made.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|s| s == sid)
    }
}

/// Whether `msg`, from the chat's agent, is a `session/update` of a session the chat's own
/// `session/fork` made (see the module's note).
pub(super) fn of_the_fork(session: &Session, msg: &Message) -> bool {
    let Message::Notification { method, params: Some(p) } = msg else { return false };
    method == crate::rpc::method::SESSION_UPDATE && update_of_the_fork(session, p)
}

/// [`of_the_fork`] for a `session/update`'s params, as the inbound loop applies them.
pub(super) fn update_of_the_fork(session: &Session, p: &Value) -> bool {
    let Some(sid) = p.get("sessionId").and_then(Value::as_str) else { return false };
    if session.fork_replay.is_made(sid) {
        return true;
    }
    if session.fork_replay.asking.load(Ordering::SeqCst) == 0 {
        return false;
    }
    {
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        // Not knowing its own id, the chat cannot tell another session's update from its own.
        let Some(own) = meta.agent_session_id.as_deref() else { return false };
        if own == sid || meta.retired_agent_session_ids.iter().any(|r| r == sid) {
            return false;
        }
    }
    !session.subagents.lock().unwrap_or_else(|e| e.into_inner()).knows(sid)
}

#[cfg(test)]
#[path = "fork_replay_tests.rs"]
mod tests;
