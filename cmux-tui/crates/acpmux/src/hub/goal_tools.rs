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
/// A continuation's refusal when its goal changed while it waited (`check_goal_mark`).
const MOVED_ON: &str = "goal.moved_on";

/// For a prompt sent as a goal's continuation (`PromptOptions::goal_mark`), once it holds the
/// turn lock: its goal must still be running and unchanged since it was sent, so one that waited
/// behind the person's prompt never runs after that turn completed or replaced the goal.
pub(super) fn check_goal_mark(session: &Session, mark: Option<&str>) -> Result<(), RpcError> {
    let Some(mark) = mark else { return Ok(()) };
    let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
    let current = m.goal.as_ref().is_some_and(|g| {
        generic_goal::is_generic(g) && g.lifecycle() == "running" && generic_goal::mark(g) == mark
    });
    if current {
        Ok(())
    } else {
        Err(RpcError::invalid_params("the goal changed before its continuation ran")
            .with_data(json!({"reason": MOVED_ON})))
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl Hub {
    /// Sets `session`'s goal (a new one replaces any goal set this way).
    pub(crate) fn goal_set(
        &self,
        session: &Session,
        request: &GoalRequest,
    ) -> Result<Value, RpcError> {
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
        self.publish_goal(session, true)?;
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
        self.publish_goal(session, true)?;
        Ok(value)
    }

    /// `session`'s goal, whatever set it, or null.
    pub(crate) fn goal_get(&self, session: &Session) -> Value {
        let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        m.goal.as_ref().map(crate::goal::GoalState::to_value).unwrap_or(Value::Null)
    }

    /// Saves the goal and sends it to clients, as `end_loop_goal` sends its clear. `answered`: a
    /// request reports the change (`goal_set`, `goal_update`), so it returns once the goal is on
    /// disk, and a failed save fails the request (`meta_save.rs`), as the goal outlives a restart.
    fn publish_goal(&self, session: &Session, answered: bool) -> Result<(), RpcError> {
        let (sid, goal) = {
            let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let goal = m.goal.as_ref().map(crate::goal::GoalState::to_value).unwrap_or(Value::Null);
            (m.agent_session_id.clone().unwrap_or_else(|| session.id.clone()), goal)
        };
        let saved = if answered {
            self.save_meta_answered(session)
        } else {
            self.save_meta(session);
            Ok(())
        };
        let update = json!({"sessionUpdate": "session_info_update", "_meta": {"goal": goal}});
        let msg = json!({"jsonrpc": "2.0", "method": "session/update",
                         "params": {"sessionId": sid, "update": update}});
        self.append(session, "in", "session_info_update", msg);
        saved
    }

    /// At a completed turn's end: keeps a running goal going with acpmux's own prompt, or stops it
    /// at a budget or the cap (`generic_goal::next_step`). `turn_tokens` is what the turn spent,
    /// when its harness says. A Claude Code chat continues through its own `/loop` instead.
    pub(super) fn continue_goal(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn_tokens: Option<u64>,
    ) {
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
        let (step, mark) = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            match m.goal.as_mut() {
                Some(goal) => {
                    let step = generic_goal::next_step(goal, turn_tokens, now_ms());
                    (step, generic_goal::mark(goal))
                }
                None => (Step::None, String::new()),
            }
        };
        let text = match step {
            Step::None => return,
            Step::Stop(reason) => {
                tracing::info!(session = %session.id, reason, "a goal stopped");
                let _ = self.publish_goal(session, false);
                return;
            }
            Step::Continue(text) => text,
        };
        let _ = self.publish_goal(session, false);
        let notice =
            json!({"sender": SENDER, "severity": "info", "title": "Keep going toward the goal"});
        let text = crate::prompt_provenance::notice_text(&notice, &text);
        let provenance = crate::prompt_provenance::notice(&notice, &session.id);
        let opts = PromptOptions {
            provenance: Some(provenance),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Fyi),
            // Refused if the goal moved on before it ran: reported complete or blocked, replaced,
            // or stepped again by a later turn (`check_goal_mark`).
            goal_mark: Some(mark),
            ..PromptOptions::default()
        };
        let (hub, session) = (Arc::clone(self), Arc::clone(session));
        tokio::spawn(async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            // Never steered: it waits behind anything the person queued.
            if let Err(e) = hub.prompt_with(&session, blocks, SENDER, false, opts).await
                && e.data.as_ref().is_none_or(|d| d["held"] != true && d["reason"] != MOVED_ON)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn hub() -> Arc<Hub> {
        let mut config = Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        Hub::new(config, store)
    }

    fn chat(hub: &Hub) -> Arc<Session> {
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "g", "name": "pi chat", "harness": "pi",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        hub.make_session(meta)
    }

    fn request(objective: &str) -> GoalRequest {
        GoalRequest {
            objective: objective.into(),
            done_when: "cargo test passes".into(),
            token_budget: None,
            time_budget_minutes: None,
        }
    }

    /// The mark a continuation is sent with, as `continue_goal` takes it after its step.
    fn step(session: &Session) -> String {
        let mut m = session.meta.lock().unwrap();
        let goal = m.goal.as_mut().unwrap();
        assert!(matches!(generic_goal::next_step(goal, None, now_ms()), Step::Continue(_)));
        generic_goal::mark(goal)
    }

    fn moved_on(result: Result<(), RpcError>) -> bool {
        result.is_err_and(|e| e.data.is_some_and(|d| d["reason"] == MOVED_ON))
    }

    /// A continuation that waited behind the person's prompt runs only while its goal is the
    /// one it was sent for, still running. Codex review of #36413, finding F1.
    #[test]
    fn a_continuation_is_refused_once_its_goal_moved_on() {
        let hub = hub();
        let session = chat(&hub);
        hub.goal_set(&session, &request("Make the suite pass")).unwrap();
        let mark = step(&session);
        assert!(check_goal_mark(&session, Some(&mark)).is_ok());
        assert!(check_goal_mark(&session, None).is_ok());

        // That turn's agent reported it complete.
        hub.goal_update(&session, Reported::Complete, None).unwrap();
        assert!(moved_on(check_goal_mark(&session, Some(&mark))));

        // Running again resets its count: the older continuation is still not this goal's.
        hub.goal_update(&session, Reported::Running, None).unwrap();
        assert!(moved_on(check_goal_mark(&session, Some(&mark))));

        // A new goal replaced it.
        let mark = step(&session);
        hub.goal_set(&session, &request("Ship the docs")).unwrap();
        assert!(moved_on(check_goal_mark(&session, Some(&mark))));

        // A later turn's step sent a newer continuation.
        let older = step(&session);
        let newer = step(&session);
        assert!(moved_on(check_goal_mark(&session, Some(&older))));
        assert!(check_goal_mark(&session, Some(&newer)).is_ok());
    }
}
