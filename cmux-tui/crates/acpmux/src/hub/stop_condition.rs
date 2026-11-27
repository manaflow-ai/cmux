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
//! The same `--settings` caps the blocks at one with no tool call between ([`BLOCK_CAP`]), so a
//! chat that only repeats its report to the check ends its turn after one re-prompt. And a direct
//! acpmux Stop hook beside the check ends the turn at any later stop of a turn the check already
//! sent back (Claude Code's `stop_hook_active`), work or no work between.
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

/// Whether chat `m` runs Codex.
pub(crate) fn is_codex(m: &SessionMeta) -> bool {
    m.family.as_deref().map(crate::goal::GoalProvider::from_name)
        == Some(crate::goal::GoalProvider::Codex)
}

/// Whether Codex chat `m`'s stop condition, its goal, still waits to be met: it has one, and the
/// goal Codex reports (none yet: open) is not done, paused or stalled (`blocked`). Codex only: a
/// Claude Code chat's Stop hook keeps its turn going, and it reports no goal.
pub(crate) fn goal_open(m: &SessionMeta) -> bool {
    is_codex(m)
        && m.stop_condition.is_some()
        && m.goal.as_ref().is_none_or(|g| g.lifecycle() == "running")
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

/// Claude Code's env var for how many times in a row a Stop hook may block the turn from ending
/// with no tool call between (2.1.330: default 8; the count goes back to 0 after a turn step that
/// ran a tool). Past it, Claude Code ends the turn.
pub(crate) const BLOCK_CAP_ENV: &str = "CLAUDE_CODE_STOP_HOOK_BLOCK_CAP";

/// The cap a stop condition's chat gets: one re-prompt with no new work. A chat that only answers a
/// block with text again (a subagent that waits on the person's OK and says "still holding") ends
/// its turn there, instead of 8 more checks and 8 more hold messages (user, 2026-11-23: "it spams
/// too much 'still holding' even though the turn has ended"). A chat that goes back to work runs a
/// tool, which resets the count, so the goal still keeps it going.
pub(crate) const BLOCK_CAP: &str = "1";

/// The response for the native Stop callback after the condition has already sent the turn back.
/// Claude Code's hook input says `stop_hook_active:true` from the first block of a turn on, tool
/// calls or not. The first stop (`false`) gets an empty successful response, so the prompt check
/// decides. A later stop gets `continue:false`, which Claude Code applies before another block.
pub(crate) fn repeat_stop(input: &Value) -> Value {
    if input.get("stop_hook_active").and_then(Value::as_bool) == Some(true) {
        json!({
            "continue": false,
            "suppressOutput": true,
            "stopReason": "The stop condition was checked once this turn"
        })
    } else {
        json!({})
    }
}

/// The settings document that holds the condition as a prompt Stop hook and the block cap
/// ([`BLOCK_CAP`]) in its `env`. The repeat check is registered as Claude's native callback,
/// avoiding a command hook, shell, interpreter, and process spawn on every stop.
pub(crate) fn settings(condition: &str) -> Value {
    json!({
        "env": {BLOCK_CAP_ENV: BLOCK_CAP},
        "hooks": {"Stop": [{"hooks": [
            {"type": "prompt", "prompt": condition},
        ]}]},
    })
}

/// Claude Code's words for the chat's stop condition: `--settings <json>`, or none.
pub(crate) fn claude_args(meta: &SessionMeta) -> Vec<String> {
    meta.stop_condition
        .as_deref()
        .map(|c| vec!["--settings".to_owned(), settings(c).to_string()])
        .unwrap_or_default()
}

#[cfg(test)]
#[path = "stop_condition_tests.rs"]
mod tests;
