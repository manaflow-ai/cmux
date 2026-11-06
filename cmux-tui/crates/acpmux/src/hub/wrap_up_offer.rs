//! A completed turn's wrap-up answer as the chat's suggested next prompt, on harnesses that make
//! none of their own (`crate::wrap_up_suggestion`). Claude Code predicts the next prompt itself
//! (`claude_stdio/prompt_suggestions.rs`), so its chats are left to that.

use super::*;

impl Hub {
    /// Offers `answer` as the chat's next-prompt suggestion through the acceptance gate
    /// (`suggestion_gate.rs`), written after the turn's end as the harness's own would be.
    pub(super) fn offer_wrap_up_suggestion(&self, session: &Session, answer: &str) {
        let meta = session.meta();
        let claude = match self.config.try_read() {
            Ok(cfg) => {
                super::resolve::session_profile(&cfg, &meta.harness, &meta.cwd, meta.remote_origin)
                    .is_ok_and(|p| p.kind == crate::config::HarnessKind::ClaudeStdio)
            }
            // Unknown: leave the chat as it was.
            Err(_) => true,
        };
        if claude {
            return;
        }
        let mut update = crate::wrap_up_suggestion::update(answer);
        crate::suggestion_gate::filter_update(&session.id, &meta.harness, &mut update);
        let msg = json!({
            "jsonrpc": "2.0",
            "method": crate::rpc::method::SESSION_UPDATE,
            "params": {"sessionId": meta.agent_session_id.clone().unwrap_or_else(|| session.id.clone()), "update": update},
        });
        self.append(session, "in", "prompt_suggestion", msg);
    }
}
