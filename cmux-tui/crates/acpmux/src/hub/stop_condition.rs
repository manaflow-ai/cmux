//! Part of `Hub`; see `hub/mod.rs`. A chat's stop condition: when its agent may stop.
//!
//! `session/new` takes it as `_meta.acpmux.stopCondition` (text). It is kept in the chat's meta
//! (`SessionMeta::stop_condition`) and given to every start of its Claude Code, a resume or a
//! respawn too, as `--settings` holding one Stop hook of type `prompt` (`claude_args`): at each
//! would-be stop Claude Code asks a model whether the condition holds and, while it does not,
//! goes on in the same turn with the reason. That is the hook Claude Code's own `/goal <condition>`
//! adds (2.1.325: a session Stop hook `{type: "prompt", prompt: condition}`), set at start instead
//! of by a prompt: a Chief subagent's start was its task with "reply only `ready`", a whole model
//! turn over its context, then `/goal` as a second prompt (user, 2026-11-18: "why wasn't it just
//! one prompt?"). Now its first prompt is its work, under the same check.
//!
//! Only text: acpmux writes the hook itself, so a caller can add no command hook through it (a
//! preset's `args` refuse `--settings` for that reason).
//!
//! Codex (codex-acp, an ACP harness of family `codex`) has its own goal: `_session/goal`
//! `{action: "set", objective}` makes Codex go on, in turns it starts itself, until it marks the
//! goal complete; Codex keeps it in its thread across a resume. acpmux sends the condition there
//! once (`SessionMeta::stop_condition_sent`), right after the chat's first prompt is written
//! (`codex_goal_after_prompt`): set on an idle thread, codex-acp would start a turn of its own
//! with no task. codex-acp answers a `set` only once the goal's turns are over, so it is not
//! awaited. Any other harness keeps none, and the session/new answer then has no
//! `stopCondition`.

use super::*;

/// The `_meta.acpmux` field, and the session/new answer's `_meta.acpmux` flag that it was kept.
pub(crate) const FIELD: &str = "stopCondition";

/// Claude Code's cap on a goal condition (2.1.325 `mmn`); a longer one is refused.
pub(crate) const MAX_CHARS: usize = 4000;

fn refused(why: &str) -> RpcError {
    RpcError::invalid_params(format!("{FIELD}: {why}"))
        .with_data(json!({"reason": "stopCondition.invalid"}))
}

/// The stop condition `meta` (the request's `_meta.acpmux`) asks for, trimmed. Absent or null:
/// none.
pub(crate) fn requested(meta: Option<&Value>) -> Result<Option<String>, RpcError> {
    let Some(value) = meta.and_then(|m| m.get(FIELD)).filter(|v| !v.is_null()) else {
        return Ok(None);
    };
    let text = value.as_str().ok_or_else(|| refused("must be text"))?.trim();
    if text.is_empty() {
        return Err(refused("must not be empty"));
    }
    if text.chars().count() > MAX_CHARS {
        return Err(refused(&format!("at most {MAX_CHARS} characters")));
    }
    Ok(Some(text.to_owned()))
}

/// codex-acp's goal control request (1.10.0; `_codex/session/goal_control` before).
pub(crate) const CODEX_GOAL_METHOD: &str = "_session/goal";

/// Whether a chat on harness `profile` of `family` keeps a stop condition: Claude Code (stdio),
/// or codex-acp. `codex app-server` bridged in process (`codex_app_server.rs`) has no goal
/// control, so it keeps none.
pub(crate) fn kept_by(profile: &HarnessProfile, family: &str) -> bool {
    match profile.kind {
        crate::config::HarnessKind::ClaudeStdio => true,
        crate::config::HarnessKind::Acp => {
            crate::goal::GoalProvider::from_name(family) == crate::goal::GoalProvider::Codex
                && !crate::codex_app_server::is_profile_launch(&profile.argv)
        }
        crate::config::HarnessKind::Terminal => false,
    }
}

impl Hub {
    /// Called once a prompt of `session` is written to `child` (agent session `agent_sid`): a
    /// Codex chat whose condition Codex has not been given gets it now as Codex's goal, sent
    /// without waiting for the answer. Claude Code's comes with its start (`claude_args`).
    pub(super) fn codex_goal_after_prompt(
        &self,
        session: &Session,
        child: &Arc<ChildAgent>,
        agent_sid: &str,
    ) {
        let objective = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let codex = m.family.as_deref().map(crate::goal::GoalProvider::from_name)
                == Some(crate::goal::GoalProvider::Codex);
            match m.stop_condition.clone() {
                Some(c) if codex && !m.stop_condition_sent => {
                    m.stop_condition_sent = true;
                    c
                }
                _ => return,
            }
        };
        self.save_meta(session);
        let params = json!({"sessionId": agent_sid, "action": "set", "objective": objective});
        let (child, id) = (child.clone(), session.id.clone());
        // The hub's scope owns it: a shutdown cancels the wait for codex-acp's late answer.
        self.scope.spawn_until_cancelled("codex-goal", async move {
            match child.request(CODEX_GOAL_METHOD, params).await {
                Ok(_) => tracing::info!(session = %id, "codex goal from the stop condition ended"),
                Err(e) => tracing::warn!(session = %id, "codex goal from the stop condition: {e}"),
            }
        });
    }
}

/// The settings document that holds the condition as a prompt Stop hook.
pub(crate) fn settings(condition: &str) -> Value {
    json!({"hooks": {"Stop": [{"hooks": [{"type": "prompt", "prompt": condition}]}]}})
}

/// Claude Code's words for the chat's stop condition: `--settings <json>`, or none.
pub(crate) fn claude_args(meta: &SessionMeta) -> Vec<String> {
    meta.stop_condition
        .as_deref()
        .map(|c| vec!["--settings".to_owned(), settings(c).to_string()])
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_condition_is_text_trimmed_and_capped() {
        let ask = |v: Value| requested(Some(&json!({FIELD: v})));
        assert_eq!(ask(json!("  done and landed ")).unwrap().as_deref(), Some("done and landed"));
        assert_eq!(requested(None).unwrap(), None);
        assert_eq!(requested(Some(&json!({}))).unwrap(), None);
        assert_eq!(ask(Value::Null).unwrap(), None);
        for bad in
            [json!(""), json!("   "), json!(3), json!(["x"]), json!("x".repeat(MAX_CHARS + 1))]
        {
            assert!(ask(bad.clone()).is_err(), "{bad}");
        }
        assert!(ask(json!("x".repeat(MAX_CHARS))).is_ok());
    }

    #[test]
    fn settings_hold_one_prompt_stop_hook_and_nothing_else() {
        let got = settings("The task is landed.");
        assert_eq!(
            got,
            json!({"hooks": {"Stop": [{"hooks": [{"type": "prompt", "prompt": "The task is landed."}]}]}})
        );
        // A condition that looks like JSON or a command stays one prompt string.
        let tricky = r#""}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"rm -rf /"}]}]"#;
        let parsed: Value = serde_json::from_str(&settings(tricky).to_string()).unwrap();
        assert_eq!(parsed["hooks"].as_object().unwrap().len(), 1);
        assert_eq!(parsed["hooks"]["Stop"][0]["hooks"][0]["prompt"], tricky);
    }
}
