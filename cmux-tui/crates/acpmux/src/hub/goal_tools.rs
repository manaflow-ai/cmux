//! A chat's goal on any harness (`generic_goal.rs`): set, reported on and read by its own agent
//! through the `acpmux` MCP server (`goal_set`, `goal_update`, `goal_get`), and kept going at each
//! completed turn's end. The goal is the session's `goal`, saved with its meta and sent to clients
//! as a `session_info_update` `_meta.goal`, as Codex's and Claude's loops are (`loop_goal.rs`), so
//! the pane's goal strip draws it. Codex has its own goal (`/goal`), which this refuses to shadow;
//! a Claude Code chat may set one, but its continuation is Claude's own `/loop`, not this.

use super::*;
use crate::generic_goal::{self, GoalRequest, Reported, Step};

/// The continuation's sender, as a background task's notice is.
const SENDER: &str = "acpmux";

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl Hub {
    /// Sets `session`'s goal (a new one replaces any goal set this way).
    pub(crate) fn goal_set(&self, session: &Session, request: &GoalRequest) -> Result<Value, RpcError> {
        let codex = {
            let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.family.as_deref().map(crate::goal::GoalProvider::from_name)
                == Some(crate::goal::GoalProvider::Codex)
        };
        if codex {
            return Err(RpcError::invalid_params(
                "this is a Codex chat: use Codex's own /goal, which Codex keeps and continues itself",
            ));
        }
        let goal = generic_goal::new_goal(request, now_ms());
        let value = goal.to_value();
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).goal = Some(goal);
        self.publish_goal(session);
        Ok(value)
    }

    /// The agent reports on `session`'s goal: running, blocked or complete, with an optional note.
    pub(crate) fn goal_update(
        &self,
        session: &Session,
        status: Reported,
        note: Option<&str>,
    ) -> Result<Value, RpcError> {
        let value = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let Some(goal) = m.goal.as_mut().filter(|g| generic_goal::is_generic(g)) else {
                return Err(RpcError::invalid_params("this chat has no goal set with goal_set"));
            };
            generic_goal::apply_report(goal, status, note, now_ms());
            goal.to_value()
        };
        self.publish_goal(session);
        Ok(value)
    }

    /// `session`'s goal, whatever set it, or null.
    pub(crate) fn goal_get(&self, session: &Session) -> Value {
        let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        m.goal.as_ref().map(crate::goal::GoalState::to_value).unwrap_or(Value::Null)
    }

    /// Saves the goal and sends it to clients, as `end_loop_goal` sends its clear.
    fn publish_goal(&self, session: &Session) {
        let (sid, goal) = {
            let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let goal = m.goal.as_ref().map(crate::goal::GoalState::to_value).unwrap_or(Value::Null);
            (m.agent_session_id.clone().unwrap_or_else(|| session.id.clone()), goal)
        };
        self.save_meta(session);
        let update = json!({"sessionUpdate": "session_info_update", "_meta": {"goal": goal}});
        let msg = json!({"jsonrpc": "2.0", "method": "session/update",
                         "params": {"sessionId": sid, "update": update}});
        self.append(session, "in", "session_info_update", msg);
    }

    /// At a completed turn's end: keeps a running goal going with acpmux's own prompt, or stops it
    /// at a budget or the cap (`generic_goal::next_step`). `turn_tokens` is what the turn spent,
    /// when its harness says. A Claude Code chat continues through its own `/loop` instead.
    pub(super) fn continue_goal(self: &Arc<Self>, session: &Arc<Session>, turn_tokens: Option<u64>) {
        let running = session
            .meta
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .goal
            .as_ref()
            .is_some_and(|g| generic_goal::is_generic(g) && g.lifecycle() == "running");
        if !running || self.claude_stdio(session) {
            return;
        }
        let step = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            match m.goal.as_mut() {
                Some(goal) => generic_goal::next_step(goal, turn_tokens, now_ms()),
                None => Step::None,
            }
        };
        let text = match step {
            Step::None => return,
            Step::Stop(reason) => {
                tracing::info!(session = %session.id, reason, "a goal stopped");
                self.publish_goal(session);
                return;
            }
            Step::Continue(text) => text,
        };
        self.publish_goal(session);
        let notice = json!({"sender": SENDER, "severity": "info", "title": "Keep going toward the goal"});
        let text = crate::prompt_provenance::notice_text(&notice, &text);
        let provenance = crate::prompt_provenance::notice(&notice, &session.id);
        let opts = PromptOptions {
            provenance: Some(provenance),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Fyi),
            ..PromptOptions::default()
        };
        let (hub, session) = (Arc::clone(self), Arc::clone(session));
        tokio::spawn(async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            // Never steered: it waits behind anything the person queued.
            if let Err(e) = hub.prompt_with(&session, blocks, SENDER, false, opts).await
                && e.data.as_ref().is_none_or(|d| d["held"] != true)
            {
                tracing::warn!(session = %session.id, "a goal's continuation: {}", e.message);
            }
        });
    }

    /// Whether `session` runs Claude Code over its stream (`claude_stdio`), as `wrap_up_offer.rs`
    /// tells it. Unknown counts as yes: nothing is sent then.
    fn claude_stdio(&self, session: &Session) -> bool {
        let meta = session.meta();
        match self.config.try_read() {
            Ok(cfg) => {
                super::resolve::session_profile(&cfg, &meta.harness, &meta.cwd, meta.remote_origin)
                    .is_ok_and(|p| p.kind == crate::config::HarnessKind::ClaudeStdio)
            }
            Err(_) => true,
        }
    }
}
