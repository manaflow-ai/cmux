//! Part of `Hub`; see `hub/mod.rs`. An OpenCode chat is forked by the fork's own process.
//!
//! OpenCode keeps its sessions in one store every `opencode acp` process reads (its server's
//! database), and its `session/fork` copies the session from there. Asked of the chat's own
//! process, it answered only once the chat's running model step or tool call ended, and a stopped
//! chat's agent was started again (initialize, then `session/load` of its whole history) only to be
//! asked; the fork's own process then started and loaded the fork again. Measured 2026-11-22,
//! OpenCode 1.19.0 on a Mac: an idle chat forked in 6-14 s, a working one in 24-58 s, a stopped
//! one in 44.5 s.
//!
//! So the fork's own agent forks the chat's agent session at its first start: spawn, initialize,
//! then `session/fork {sessionId: <the chat's agent session>}` in place of `session/load`, its
//! answer the fork's agent session. The chat's process is never asked, so a working chat goes on
//! undisturbed and a stopped one stays stopped; OpenCode replays the forked conversation in the
//! fork's process, under the fork's hold (`ReplayHold`), as a load would.
//!
//! What the fork's agent holds is what OpenCode had stored when the fork's request reached it:
//! every finished message and part. A running turn's prompt, its finished reasoning and text and
//! its tool calls (one still running stays so in the copy); a reply still streaming is stored only
//! when its part ends, so the fork's agent does not have the words of it the fork's transcript
//! shows cut off (as a Claude or Codex copy of a working chat today).
//!
//! The fork's transcript is cut as the fork is made; its agent reads the store a moment later, as
//! its process starts. A prompt the person sends the chat in between would be in the fork's agent
//! and not in its transcript, so the chat's input stays held (`Session::input_handoff`, as for a
//! `session/fork` to the chat's own agent) until the fork's request is written, at most
//! [`HOLD_MAX`]; past that the chat takes its input again, and a prompt sent after it may be in
//! the fork's agent too.

use super::lifecycle::ReplayHold;
use super::*;
use cmux_json::JsonSet as _;
use std::sync::atomic::Ordering;
use std::time::Duration;

/// The longest the chat's input waits for its fork's agent to ask for the fork: past it, the
/// chat's prompts go on (a fork's agent that hangs at its start never holds its parent).
pub(super) const HOLD_MAX: Duration = Duration::from_secs(15);

/// A fork whose own agent forks its parent's agent session at its first start.
pub(crate) struct AgentFork {
    /// The parent's agent session (OpenCode's session id).
    pub(super) parent: String,
    /// The parent's input, held until the fork's `session/fork` is written ([`HOLD_MAX`]).
    hold: Option<tokio::sync::OwnedMutexGuard<()>>,
}

impl std::fmt::Debug for AgentFork {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AgentFork")
            .field("parent", &self.parent)
            .field("holding", &self.hold.is_some())
            .finish()
    }
}

/// Whether a fork of a chat on `harness` is made by the fork's own agent: OpenCode, which offers
/// `session/fork` and forks from the store every one of its processes reads, into the chat's own
/// folder (its store keeps a session under its folder's project).
pub(super) fn applies(opencode: bool, offers_fork: bool, same_folder: bool) -> bool {
    opencode && offers_fork && same_folder
}

impl Session {
    /// The parent's agent session this fork's own agent forks at its start, while it has not yet.
    pub(super) fn agent_fork_parent(&self) -> Option<String> {
        self.agent_fork.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|f| f.parent.clone())
    }

    /// Lets go of the parent's input this fork held, if it still does.
    pub(super) fn release_agent_fork_hold(&self) {
        let hold = self
            .agent_fork
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_mut()
            .and_then(|f| f.hold.take());
        drop(hold);
    }
}

impl Hub {
    /// Marks `fork` as forked by its own agent from `parent` (the chat's agent session), holding
    /// the chat's input `hold` until its request is written, at most [`HOLD_MAX`].
    pub(super) fn arm_agent_fork(
        &self,
        fork: &Arc<Session>,
        parent: String,
        hold: tokio::sync::OwnedMutexGuard<()>,
    ) {
        *fork.agent_fork.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(AgentFork { parent, hold: Some(hold) });
        let weak = Arc::downgrade(fork);
        // Cancelled with the hub: the hold then goes with the hub itself.
        self.scope.spawn_until_cancelled("agent-fork-hold", async move {
            tokio::time::sleep(HOLD_MAX).await;
            if let Some(fork) = weak.upgrade() {
                fork.release_agent_fork_hold();
            }
        });
    }

    /// At the first start of a fork its own agent makes ([`AgentFork`]): `session/fork` of the
    /// parent's agent session in this process, in place of a load. `None`: no such fork.
    /// The chat's input is let go once the request is written, or when this ends.
    pub(super) async fn fork_in_own_process(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        mut params: Value,
    ) -> Option<Result<Value, RpcError>> {
        let parent = session.agent_fork_parent()?;
        params.set("sessionId", json!(parent));
        let hold = ReplayHold::start(session, child);
        session.loading.store(true, Ordering::SeqCst);
        let res = child
            .request_with_hook(method::SESSION_FORK, params, None, || {
                session.release_agent_fork_hold()
            })
            .await;
        session.release_agent_fork_hold();
        session.loading.store(false, Ordering::SeqCst);
        hold.end().await;
        // Made or failed, this fork does not ask again: a failed one starts from its transcript.
        session.agent_fork.lock().unwrap_or_else(|e| e.into_inner()).take();
        Some(res.and_then(|v| {
            if v.get("sessionId").and_then(Value::as_str).is_some() {
                Ok(v)
            } else {
                Err(RpcError::internal("session/fork returned no sessionId"))
            }
        }))
    }
}

#[cfg(test)]
#[path = "fork_own_process_tests.rs"]
mod tests;
