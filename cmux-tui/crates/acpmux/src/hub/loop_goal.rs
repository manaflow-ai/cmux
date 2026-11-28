//! A Claude Code /loop ends with the agent process that runs it.
//!
//! acpmux's `claude_stdio/loops.rs` sends a loop as the chat's goal (`_meta.goal`, `kind: "loop"`)
//! and clears it when Claude exits. A forced Stop restart (`cancel.rs`) marks that agent stopped,
//! so the inbound loop drops its clear with the rest of what it still sent: the chat would keep a
//! loop that no longer runs. The hub's own exit teardown (`permissions.rs`, `Inbound::Exited`)
//! clears it instead, saved and logged as the same update, so every client sees it end. A goal of
//! any other kind (Codex's, which Codex keeps across its processes) stays.

use super::*;

impl Hub {
    pub(super) fn end_loop_goal(&self, session: &Session) {
        let sid = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let looping = m
                .goal
                .as_ref()
                .and_then(|goal| goal.extra.get("kind"))
                .and_then(Value::as_str)
                .is_some_and(|kind| kind == "loop");
            if !looping {
                return;
            }
            m.goal = None;
            m.agent_session_id.clone().unwrap_or_else(|| session.id.clone())
        };
        self.save_meta(session);
        let update = json!({"sessionUpdate": "session_info_update", "_meta": {"goal": null}});
        let msg = json!({"jsonrpc": "2.0", "method": "session/update",
                         "params": {"sessionId": sid, "update": update}});
        self.append(session, "in", "session_info_update", msg);
    }
}
