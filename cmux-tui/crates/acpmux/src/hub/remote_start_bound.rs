//! Part of `Hub`; see `hub/mod.rs`. A sandboxed Claude Code that never starts.
//!
//! A remote chain runs Claude Code under the remote-chain sandbox (`remote_sandbox.rs`). On
//! air-blue (2026-11-28) its launcher (`sr`) hung before its main as the sandbox denied a
//! mach-lookup: the child wrote nothing on stdout, acpmux answered `initialize` itself (the
//! translator does), and the chat read `running` for good with no error anywhere.
//!
//! Claude Code answers the `initialize` control request it is sent at its start within seconds.
//! So a remote-origin Claude child that has written no line on stdout [`REMOTE_START_BOUND`]
//! after acpmux spawned it is stopped here (acpmux started it): the chat logs a
//! `remote_start_bound` event naming the sandbox, and a running turn fails with the same text
//! and a next step instead of hanging. The next prompt starts the agent again. Any line from
//! the child (`tap.rs` marks `Session::raw_line_tap`) or a newer agent ends the watch.

use super::*;

/// How long a remote-origin Claude child may write nothing on stdout after its spawn.
pub(super) const REMOTE_START_BOUND: std::time::Duration = std::time::Duration::from_secs(60);

/// How long the stopped child gets to exit after its SIGTERM.
const STOP_GRACE: std::time::Duration = std::time::Duration::from_secs(2);

/// The error text of a remote chain whose agent never started, for a bound of `ms`.
fn start_bound_text(ms: u64) -> String {
    format!(
        "the sandboxed agent wrote nothing in {}s; its launcher may be blocked by the \
         remote-chain sandbox (remote-chain.sb). acpmux stopped it; next: run the chat's \
         launcher as Claude Code itself (not a wrapper that needs more than the sandbox \
         allows), or read the chat's remote_start_bound and stderr events, then send again",
        ms / 1000
    )
}

impl Hub {
    /// Watches `child`, just spawned for `session` behind tap number `tap`: no line from it on
    /// stdout within `bound` ([`REMOTE_START_BOUND`]; tests shorten it) stops it and fails its turn ([`Hub::remote_start_bound_error`]).
    pub(super) fn watch_remote_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        tap: u64,
        bound: std::time::Duration,
    ) {
        let hub = Arc::downgrade(self);
        let session = session.clone();
        let child = Arc::downgrade(child);
        self.scope.spawn_named("remote-start-bound", async move {
            tokio::time::sleep(bound).await;
            let (Some(hub), Some(child)) = (hub.upgrade(), child.upgrade()) else { return };
            // It wrote a line, or another agent took the chat since.
            let current =
                session.child.lock().await.as_ref().is_some_and(|c| Arc::ptr_eq(c, &child));
            if !current
                || session.raw_line_tap.load(Ordering::SeqCst) >= tap
                || session.taps.load(Ordering::SeqCst) != tap
            {
                return;
            }
            let ms = bound.as_millis() as u64;
            let text = start_bound_text(ms);
            tracing::warn!(session = %session.id, pid = ?child.pid, "{text}");
            hub.append(
                &session,
                "mux",
                "remote_start_bound",
                json!({"startBoundMs": ms, "pid": child.pid, "error": text}),
            );
            if let Some(turn) = session.turn() {
                let answer = json!({"stopReason": "cancelled",
                                    "_meta": {"acpmux": {"remoteStartBoundMs": ms}}});
                session.steer_end.send_replace(Some((turn.turn_id, answer)));
            }
            child.terminate(STOP_GRACE).await;
        });
    }

    /// The error a turn whose sandboxed agent never started fails with (`finish_turn`), from
    /// its forced answer.
    pub(super) fn remote_start_bound_error(answer: &Value) -> Option<RpcError> {
        let ms = answer.pointer("/_meta/acpmux/remoteStartBoundMs").and_then(Value::as_u64)?;
        Some(
            RpcError::new(-32000, start_bound_text(ms))
                .with_data(json!({"reason": "remote.start_bound", "startBoundMs": ms})),
        )
    }
}

#[cfg(test)]
#[path = "remote_start_bound_tests.rs"]
mod tests;
