//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/ask`: a side question about a
//! chat (Claude Code's `/btw`). It is asked in a throwaway fork of the chat
//! that holds its finished turns, answered once, and gone again: the chat's
//! own thread, turn count and agent conversation never see it.
//!
//! A Claude chat forks through its latest finished turn, so a question can
//! come while a turn runs (`fork_at.rs`); the copy of Claude's transcript is
//! deleted with the fork. Any other agent forks at the chat's end, so its
//! chat must be between turns. The fork runs under `deny-all`: whatever its
//! agent asks permission for is refused.

use super::*;

const CONFLICT: i64 = -32000;

impl Hub {
    /// Ask `question` about `session` without adding it to the chat.
    /// Returns `{sessionId, text, stopReason}`, `text` the agent's answer.
    /// `opts` carries the asking connection's rules (control, trust gate).
    pub async fn ask_aside(
        self: &Arc<Self>,
        session: &Arc<Session>,
        question: &str,
        client: &str,
        opts: PromptOptions,
    ) -> Result<Value, RpcError> {
        if question.trim().is_empty() {
            return Err(RpcError::invalid_params("text is required"));
        }
        let meta = session.meta();
        let (is_claude, env) = self.harness_env(&meta).await;
        let through = if is_claude {
            let latest = self.latest_turn_result(&session.id)?.ok_or_else(|| {
                RpcError::invalid_params("the chat has no finished turn to ask about")
            })?;
            Some(latest)
        } else if matches!(meta.status, SessionStatus::Running | SessionStatus::Waiting) {
            return Err(RpcError::new(CONFLICT, "the chat is working; ask when the turn ends"));
        } else {
            None
        };
        let name = self.unique_name(&format!("{}-aside", meta.name));
        let aside =
            self.fork(session, Some(name), None, Default::default(), None, through, false).await?;
        let mut tag = serde_json::Map::new();
        tag.insert(ASIDE_TAG.into(), json!(session.id));
        self.set_tags(&aside, Some(&tag), &[], None);
        self.set_policy(&aside, PermissionPolicy::DenyAll).await;
        let before = aside.seq.load(std::sync::atomic::Ordering::SeqCst);
        let blocks = vec![json!({"type": "text", "text": question})];
        let reply = self.prompt_with(&aside, blocks, client, false, opts).await;
        let text: String = self
            .store
            .events(&aside.id, before, 500_000)
            .unwrap_or_default()
            .iter()
            .filter(|e| e.kind == "agent_message_chunk")
            .filter(|e| !e.msg.get("params").is_some_and(crate::subagents::is_subagents))
            .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
            .collect();
        let agent_sid = aside.meta().agent_session_id;
        if let Err(e) = self.kill(&aside, true).await {
            tracing::warn!(session = %aside.id, "side question cleanup: {e}");
        }
        // Claude keeps the fork's conversation in its own store, where chat
        // lists would find it.
        if is_claude
            && let Some(sid) = agent_sid.filter(|s| crate::adopt::is_bare_id(s))
            && let Some(file) =
                crate::adopt::find_claude(&self.harness_homes().with_env(&[&env]).claude, &sid)
            && let Err(e) = std::fs::remove_file(&file)
        {
            tracing::warn!(session = %aside.id, "side question transcript: {e}");
        }
        let reply = reply?;
        Ok(json!({"sessionId": session.id, "text": text, "stopReason": reply.get("stopReason")}))
    }
}

/// Marks a side question's fork (its value the chat's id) while it lives,
/// so chat lists leave it out.
const ASIDE_TAG: &str = "aside";
