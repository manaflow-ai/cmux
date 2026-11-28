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
//! Harness magic `continue` (RFD 0158 §15, opt-in) lifts that one-a-turn rule while the work
//! moves: later stops go to the check again, up to [`SOFT_BUDGET`] continuations, until a stop
//! finds no file or commit changed since the previous one ([`Continuation`]).
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

/// Harness magic `continue` (RFD 0158 §15): with it on, a stop condition's chat is sent on
/// while its work moves, instead of at most once a turn ([`repeat_stop`]). Every later stop of a
/// turn the check already sent back goes to the check again (`{}`) until one of three things ends
/// it with `continue: false`:
/// - the soft budget: [`SOFT_BUDGET`] continuations in the turn (Claude Code's own default cap on
///   consecutive blocks is 8, and `/goal` lives under it);
/// - the spin guard: no file and no commit changed since the previous stop
///   ([`worktree_fingerprint`]: HEAD, `git status`, and the size and mtime of each path it lists),
///   so a chat that only reports back to the check ends there, as the §2 spin rule says;
/// - no fingerprint (not a git folder, or git past [`FINGERPRINT_LIMIT`]): it fails open to the
///   rule without the feature, one continuation a turn.
///
/// A reply with no tool call still ends at Claude Code's block cap of one ([`BLOCK_CAP`]).
/// Off by default (Leo, 2026-11-26: "identify all the weird opinionated fleet things we shipped
/// into the app and remove them"): on with `agents.harnessMagic.continue.enabled: true`;
/// `ACPMUX_HM_CONTINUE=0` turns it off whatever the file says (`1` on). Counted per turn on
/// `turn_result.harnessMagic.continue` (`continued`, `spinStopped`, `budgetStopped`,
/// `unreadStopped`).
pub(crate) const CONTINUE_FEATURE: &str = "continue";
/// The setting that turns it on (off unless `true`).
pub(crate) const CONTINUE_SETTING: &str = "agents.harnessMagic.continue.enabled";
/// The most continuations one turn gets with the feature on.
pub(crate) const SOFT_BUDGET: u32 = 8;
/// The longest a stop waits on the fingerprint; Claude Code waits 5 s on the callback.
pub(crate) const FINGERPRINT_LIMIT: std::time::Duration = std::time::Duration::from_secs(2);

#[cfg(test)]
thread_local! {
    /// Turns `continue` on for this test thread, whatever the settings file says.
    pub(crate) static CONTINUE_FOR_TEST: std::cell::Cell<bool> =
        const { std::cell::Cell::new(false) };
}

/// Whether `continue` is on, given the kill switch's value and the settings document.
pub(crate) fn continue_enabled_in(env: Option<&str>, doc: Option<&Value>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, CONTINUE_SETTING)).and_then(|v| v.as_bool())
        == Some(true)
}

/// Whether `continue` is on now.
pub(crate) fn continue_enabled() -> bool {
    #[cfg(test)]
    if CONTINUE_FOR_TEST.with(std::cell::Cell::get) {
        return true;
    }
    let env = std::env::var(crate::hub::harness_magic::env_key(CONTINUE_FEATURE)).ok();
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    continue_enabled_in(env.as_deref(), doc.as_ref())
}

/// What the folder's work looks like now, as one number: HEAD, the `git status` lines, and the
/// size and mtime of each path they name (a file edited twice keeps its ` M` line). `None` outside
/// a repository or when git fails.
pub(crate) fn worktree_fingerprint(cwd: &std::path::Path) -> Option<u64> {
    use std::hash::{Hash, Hasher};
    let head = crate::git_state::GitState::read(cwd).head?;
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let mut h = std::collections::hash_map::DefaultHasher::new();
    head.hash(&mut h);
    out.stdout.hash(&mut h);
    for record in out.stdout.split(|b| *b == 0).filter(|r| r.len() > 3) {
        let path = cwd.join(String::from_utf8_lossy(&record[3..]).as_ref());
        match std::fs::symlink_metadata(&path) {
            Ok(m) => {
                m.len().hash(&mut h);
                m.modified().ok().hash(&mut h);
            }
            Err(_) => 0u8.hash(&mut h),
        }
    }
    Some(h.finish())
}

/// A turn's `continue` counts.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ContinueCounters {
    /// Later stops handed to the check again, the work having moved.
    pub continued: u64,
    /// Turns ended because nothing changed since the previous stop.
    pub spin_stopped: u64,
    /// Turns ended at [`SOFT_BUDGET`].
    pub budget_stopped: u64,
    /// Turns ended with no fingerprint to compare (the rule without the feature).
    pub unread_stopped: u64,
}

impl ContinueCounters {
    pub(crate) fn to_json(self) -> Value {
        json!({
            "continued": self.continued,
            "spinStopped": self.spin_stopped,
            "budgetStopped": self.budget_stopped,
            "unreadStopped": self.unread_stopped,
        })
    }
}

/// One chat's `continue` state for its current turn.
#[derive(Debug, Default)]
pub(crate) struct Continuation {
    /// Continuations so far this turn (stops the check sent back).
    sent: u32,
    /// The fingerprint at the previous stop.
    last: Option<u64>,
    counters: ContinueCounters,
}

impl Continuation {
    /// The answer to a Stop callback whose input is `input`, with the folder's `fingerprint` now.
    pub(crate) fn on_stop(&mut self, input: &Value, fingerprint: Option<u64>) -> Value {
        let active = input.get("stop_hook_active").and_then(Value::as_bool) == Some(true);
        let last = std::mem::replace(&mut self.last, fingerprint);
        if !active {
            // The turn's first stop: the check decides it.
            self.sent = 0;
            return json!({});
        }
        self.sent = self.sent.saturating_add(1);
        let c = &mut self.counters;
        let reason = if self.sent >= SOFT_BUDGET {
            c.budget_stopped += 1;
            "The stop condition sent this turn on at its continuation budget"
        } else {
            match (last, fingerprint) {
                (Some(a), Some(b)) if a != b => {
                    c.continued += 1;
                    return json!({});
                }
                (Some(_), Some(_)) => {
                    c.spin_stopped += 1;
                    "No file or commit changed since the stop condition last sent this turn on"
                }
                _ => {
                    c.unread_stopped += 1;
                    "The stop condition was checked once this turn"
                }
            }
        };
        json!({"continue": false, "suppressOutput": true, "stopReason": reason})
    }

    /// The turn's counts, and a fresh state for the next turn.
    pub(crate) fn turn_ended(&mut self) -> ContinueCounters {
        std::mem::take(self).counters
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
