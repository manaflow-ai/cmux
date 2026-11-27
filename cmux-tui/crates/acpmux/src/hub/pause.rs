//! Pause and resume an agent session on request: `acpmux session pause NAME` (`_acpmux/pause`)
//! and `acpmux session wake NAME` (`_acpmux/wake`).
//!
//! Leo (2026-11-03): "i think acpmux ought to be like ultra conducive to pause/resume. we can
//! absolutely own the fuck out of that layer". A pause is the idle pass's hibernation
//! (`idle.rs`), now instead of after 2 idle minutes: the harness and its MCP servers exit, the
//! chat stays open, and its record, transcript and agent session id stay, so the next start
//! resumes the same conversation (`session/load`, `claude --resume`). It wakes on its next
//! prompt, a person typing into it or opening it, as any hibernated chat does, or on
//! `session wake`, which starts its agent now and says how long that took.
//!
//! A pause is refused unless the session is idle, checked under the leases a turn, an agent start
//! and a mode change take, as `session stop --if-idle` does (`stop_if_idle.rs`): the refusal is
//! the same JSON-RPC error ([`NOT_IDLE_CODE`], data `reason` `busy` and `busyWith`), and the CLI
//! exits 6. It is also refused while anything but the harness's own MCP servers runs under it
//! (`idle_census.rs`, `busyWith` `process`): its exit would end that too.

use super::stop_if_idle::{BUSY, NOT_IDLE_CODE};
use super::*;

/// Listed in `initialize`'s `_meta.acpmux.features`: this daemon serves `_acpmux/pause` and
/// `_acpmux/wake`.
pub(crate) const FEATURE: &str = "sessionPause";

/// The refusal of a pause: the session is not idle (`what` holds it).
fn not_idle(session: &Session, what: &str) -> RpcError {
    RpcError::new(NOT_IDLE_CODE, format!("session is not idle ({what}): not paused"))
        .with_data(json!({"reason": BUSY, "busyWith": what, "sessionId": session.id,
            "revision": Hub::revision(session), "retryable": true}))
}

impl Hub {
    /// Hibernates `session` now (module docs): `{sessionId, paused, exitMs}`, or `paused: false`
    /// with `reason` `stopped` (closed: no agent runs) or `paused` (already hibernated).
    pub(crate) async fn pause(&self, session: &Arc<Session>) -> Result<Value, RpcError> {
        let not_paused =
            |reason: &str| json!({"sessionId": session.id, "paused": false, "reason": reason});
        if self.stopping.load(Ordering::SeqCst) {
            return Err(not_idle(session, "stopping"));
        }
        // A prompt that took the turn lock was admitted, even before its turn shows.
        let Ok(_turn) = session.turn_lock.try_lock() else { return Err(not_idle(session, "turn")) };
        // A start, a mode change, a fork or the idle pass under way.
        let Ok(_using) = session.harness_use.try_write() else {
            return Err(not_idle(session, "starting"));
        };
        let Ok(_spawning) = session.spawn_lock.try_lock() else {
            return Err(not_idle(session, "starting"));
        };
        let Some(child) = session.child.lock().await.clone() else {
            return Ok(if self.waking(session) {
                not_paused("paused")
            } else {
                not_paused("stopped")
            });
        };
        // What the agent sent that the reader already queued counts, as in the idle pass.
        Self::drain_inbound(session).await;
        if let Some(what) = self.busy_with(session) {
            return Err(not_idle(session, what));
        }
        // Nothing it did not report may end with it (`idle_census.rs`).
        let sidecars = self.sidecars(session, &child).await;
        let census = self.idle_census(child.pid, sidecars).await;
        if !matches!(census, super::idle_census::Census::Clear) {
            self.note_refusal(session, &census);
            return Err(not_idle(session, "process"));
        }
        // The folder's work leaves this machine before the agent does (`wip_ref.rs`).
        session.save_wip().await;
        let began = std::time::Instant::now();
        let link_lost = child.host_record().is_some() && !child.is_alive().await;
        drop(child);
        if !self.hibernate_held(session, link_lost, None).await {
            return Ok(not_paused("stopped"));
        }
        let exit_ms = u64::try_from(began.elapsed().as_millis()).unwrap_or(u64::MAX);
        tracing::info!(
            session = %session.id,
            cause = "pause",
            exit_ms,
            "hibernated: paused on request; the harness and its MCP servers exited and the \
             session resumes its conversation on its next prompt or `session wake`"
        );
        Ok(json!({"sessionId": session.id, "paused": true, "exitMs": exit_ms}))
    }

    /// Starts a hibernated (paused or idle) `session`'s agent now, on its conversation:
    /// `{sessionId, woke, tookMs}`, or `woke: false` with `reason` `running` (its agent is up) or
    /// `stopped` (closed: its next prompt starts it). A failed start is the request's error, and
    /// the session stays hibernated.
    pub(crate) async fn wake(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value, RpcError> {
        if !self.waking(session) || session.status() == SessionStatus::Closed {
            let running = session.child.lock().await.is_some();
            let reason = if running { "running" } else { "stopped" };
            return Ok(json!({"sessionId": session.id, "woke": false, "reason": reason}));
        }
        if session.meta().watching.is_some() {
            return Err(RpcError::invalid_params(
                "this chat is watched: it starts no agent until Take Over",
            ));
        }
        let stops = session.stops.load(Ordering::SeqCst);
        let began = std::time::Instant::now();
        self.wake_cause(session, "resume");
        self.child_for_since(session, stops).await?;
        let took_ms = u64::try_from(began.elapsed().as_millis()).unwrap_or(u64::MAX);
        Ok(json!({"sessionId": session.id, "woke": true, "tookMs": took_ms}))
    }
}
