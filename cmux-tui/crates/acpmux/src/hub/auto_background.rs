//! Part of `Hub`; see `hub/mod.rs`. A Claude Code shell still running in the foreground after
//! [`AUTO_BACKGROUND_AFTER`] goes to the background on its own, through Ctrl-B's
//! `background_tasks` (`processes.rs`), so the turn goes on while it runs. Leo, 2026-11-02, on
//! a session that sat about 80 minutes in one turn of about 40 foreground shell calls (worktree
//! setup, loops of GitHub reads, long remote calls): "but why not in cmux". The plugin's
//! PreToolUse hook (`bg_hook.rs`) turns away the commands known to be slow before they start;
//! this catches every other one, a person's own script included, which no list can know.
//!
//! One timer per foreground Bash call of the chat's own turn (a subagent's calls are not the
//! turn's, `on_update`), armed when its command arrives. It ends when the call is no longer
//! in flight (it finished, or the turn ended), when Claude Code moved it, or when Claude Code
//! refused the request; while the call still waits (a permission card, say) and nothing moved,
//! it asks again one interval later. Weak references only, so it never keeps a chat or the hub
//! alive. What moved is listed like any shell Claude Code moved itself, origin
//! `auto_backgrounded`.
//!
//! Codex needs none of this: its unified exec hands a long command back to the agent as a
//! running process after a short wait (`codex_app_server/background.rs`), so a turn never
//! blocks on one.
//!
//! `ACPMUX_AUTO_BACKGROUND_SECS` in the daemon's environment sets the wait; `0` turns it off.

use super::*;

/// How long a foreground shell runs before it goes to the background.
pub(super) const AUTO_BACKGROUND_AFTER: std::time::Duration = std::time::Duration::from_secs(60);

/// The daemon's env knob for [`AUTO_BACKGROUND_AFTER`] (seconds; `0` turns it off).
pub const AUTO_BACKGROUND_ENV: &str = "ACPMUX_AUTO_BACKGROUND_SECS";

/// The wait the daemon starts with: the env's, else [`AUTO_BACKGROUND_AFTER`].
pub(super) fn auto_background_from_env() -> Option<std::time::Duration> {
    after_of(std::env::var(AUTO_BACKGROUND_ENV).ok().as_deref())
}

fn after_of(value: Option<&str>) -> Option<std::time::Duration> {
    match value.map(str::trim).filter(|v| !v.is_empty()) {
        None => Some(AUTO_BACKGROUND_AFTER),
        Some(v) => match v.parse::<u64>() {
            Ok(0) => None,
            Ok(secs) => Some(std::time::Duration::from_secs(secs)),
            Err(_) => Some(AUTO_BACKGROUND_AFTER),
        },
    }
}

/// The foreground shell a `session/update`'s `update` names, if it names one: a call of kind
/// `execute` with a command and without `run_in_background: true`, still running. Its command
/// comes with the `tool_call`, or with the `tool_call_update` that follows a call Claude Code
/// named as its block started (`claude_stdio/early_calls.rs`).
pub(super) fn foreground_shell(update: &Value) -> Option<&str> {
    if !matches!(
        update.get("sessionUpdate").and_then(Value::as_str),
        Some("tool_call" | "tool_call_update")
    ) || update.get("kind").and_then(Value::as_str) != Some("execute")
        || matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"))
    {
        return None;
    }
    let input = update.get("rawInput")?;
    if input.get("run_in_background") == Some(&Value::Bool(true)) {
        return None;
    }
    input.get("command")?.as_str()?;
    update.get("toolCallId")?.as_str()
}

impl Hub {
    /// How long a foreground shell runs before it goes to the background; None turns it off
    /// (tests shorten it).
    pub fn set_auto_background_after(&self, after: Option<std::time::Duration>) {
        *self.auto_background_after.lock().unwrap_or_else(|e| e.into_inner()) = after;
    }

    /// Arms the timer for the foreground shell `params`' update starts, in a Claude Code chat's
    /// own running turn (module docs). History a load replays starts nothing.
    pub(super) fn arm_auto_background(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Option<&Value>,
        replayed: bool,
    ) {
        if replayed || !session.backgrounds_work.load(Ordering::SeqCst) {
            return;
        }
        let Some(after) = *self.auto_background_after.lock().unwrap_or_else(|e| e.into_inner())
        else {
            return;
        };
        let Some(params) = params else { return };
        let Some(tool) = params.get("update").and_then(foreground_shell) else { return };
        let sid = params.get("sessionId").and_then(Value::as_str);
        if sid.is_some_and(|sid| {
            session.subagents.lock().unwrap_or_else(|e| e.into_inner()).owns(sid)
        }) {
            return;
        }
        // One timer a call: its command may come twice (the call, then an update).
        let key = format!("{}/{tool}", session.id);
        if !self.auto_background_armed.lock().unwrap_or_else(|e| e.into_inner()).insert(key.clone())
        {
            return;
        }
        let tool = tool.to_owned();
        let (hub, chat) = (Arc::downgrade(self), Arc::downgrade(session));
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(after).await;
                let Some(hub) = hub.upgrade() else { return };
                let disarm = || {
                    hub.auto_background_armed
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .remove(&key);
                };
                let Some(chat) = chat.upgrade() else { return disarm() };
                let in_flight = chat
                    .turn
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .as_ref()
                    .is_some_and(|t| t.doing.open_tools.contains(&tool));
                if !in_flight {
                    return disarm();
                }
                match hub.background_session(&chat, Some(&tool), true).await {
                    Ok(answer) if answer.get("backgrounded") == Some(&Value::Bool(false)) => {}
                    Ok(_) => return disarm(),
                    Err(e) => {
                        tracing::debug!(tool, error = %e.message, "auto-background refused");
                        return disarm();
                    }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_json::JsonSet as _;

    #[test]
    fn the_wait_comes_from_the_env_and_zero_turns_it_off() {
        assert_eq!(after_of(None), Some(AUTO_BACKGROUND_AFTER));
        assert_eq!(after_of(Some("")), Some(AUTO_BACKGROUND_AFTER));
        assert_eq!(after_of(Some("90")), Some(std::time::Duration::from_secs(90)));
        assert_eq!(after_of(Some("0")), None);
        assert_eq!(after_of(Some("soon")), Some(AUTO_BACKGROUND_AFTER));
    }

    #[test]
    fn only_a_new_foreground_shell_arms_it() {
        let call = |input: Value| {
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute",
                "status": "in_progress", "rawInput": input})
        };
        assert_eq!(foreground_shell(&call(json!({"command": "make"}))), Some("t1"));
        assert_eq!(
            foreground_shell(&call(json!({"command": "make", "run_in_background": false}))),
            Some("t1")
        );
        assert_eq!(
            foreground_shell(&call(json!({"command": "npm run dev", "run_in_background": true}))),
            None
        );
        // Announced before its input streamed: no command yet, nothing to time.
        assert_eq!(foreground_shell(&call(json!({}))), None);
        let mut read = call(json!({"command": "x"}));
        read.set("kind", json!("read"));
        assert_eq!(foreground_shell(&read), None);
        // A call named early gets its command in the update that follows.
        let mut update = call(json!({"command": "make"}));
        update.set("sessionUpdate", json!("tool_call_update"));
        assert_eq!(foreground_shell(&update), Some("t1"));
        update.set("status", json!("completed"));
        assert_eq!(foreground_shell(&update), None);
    }
}
