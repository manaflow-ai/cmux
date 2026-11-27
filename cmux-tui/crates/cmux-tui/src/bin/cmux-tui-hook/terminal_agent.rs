//! Which Claude in a terminal is the terminal's agent.
//!
//! A Claude that the terminal's agent starts from a hook, an MCP server or a
//! teammate gets the terminal's environment but does not source the agent's
//! `CLAUDE_ENV_FILE`, so it has no claim (plugin_copy.rs). Before a Claude
//! hook writes a claim or gives the session context, it checks whether the
//! terminal already has another agent:
//!
//! - A `SessionStart` with source `clear` or `resume` is the terminal's
//!   agent: a running Claude ends its session (`SessionEnd`) and starts the
//!   next one, and the roster may not show the end yet. A Claude that a hook
//!   started can clear or resume too; it then gets only the session context.
//! - Else one `agent.list` read of the terminal: a live hook session other
//!   than this one means this Claude is another agent's. A read that fails or
//!   times out means it is the terminal's agent, so the agent is never
//!   silenced by a daemon that does not answer in time. The read ends inside
//!   the hook's time budget; with no time left it is not made, with the same
//!   result as a failed read.
//!
//! Limits (docs/agent-hooks.md): a Claude that ended without `SessionEnd`
//! (a crash, `kill -9`) leaves a live row, and the next Claude started by
//! hand in that terminal counts as another agent's until the screen detector
//! replaces the row. A nested Claude whose start reaches the daemon first
//! takes the row the same way.

use super::*;

/// How long `agent.list` may take before the hook acts as the agent.
pub(super) const DEADLINE: Duration = Duration::from_millis(1500);

/// One Claude hook run in a terminal.
pub(super) struct Run<'a> {
    pub(super) socket: &'a Path,
    pub(super) terminal: Option<&'a str>,
    pub(super) session: Option<&'a str>,
    /// The `SessionStart` payload's `source`; `None` for other events.
    pub(super) start_source: Option<&'a str>,
    /// When the hook's time budget ends. The read ends by then, and no read
    /// is made when no time is left.
    pub(super) budget_end: Instant,
}

impl Run<'_> {
    /// Whether this Claude is not the terminal's agent but one it started.
    pub(super) fn is_nested(&self) -> bool {
        let read = || {
            let params = json!({"terminal_id": self.terminal.unwrap_or_default()});
            let deadline = read_deadline(self.budget_end, Instant::now())?;
            session_context::request(self.socket, "agent.list", params, deadline)
        };
        nested_in(self, read)
    }
}

/// When the `agent.list` read made at `now` must end: its own bound, cut to
/// the end of the hook's time budget (`budget_end`). `None` when no time is
/// left, and the hook then makes no read.
fn read_deadline(budget_end: Instant, now: Instant) -> Option<Instant> {
    let deadline = (now + DEADLINE).min(budget_end);
    (deadline > now).then_some(deadline)
}

/// [`Run::is_nested`] over one `agent.list` read (`None` when it failed).
fn nested_in(run: &Run<'_>, read: impl FnOnce() -> Option<Value>) -> bool {
    let (Some(terminal), Some(session)) = (run.terminal, run.session) else { return false };
    if matches!(run.start_source, Some("clear" | "resume")) {
        return false;
    }
    let Some(rows) = read() else { return false };
    let text = |row: &Value, key: &str| row.get(key).and_then(Value::as_str).map(str::to_owned);
    rows.as_array().into_iter().flatten().any(|row| {
        let live = row.get("extra").and_then(|extra| text(extra, "agent_session_id"));
        text(row, "terminal_id").as_deref() == Some(terminal)
            && text(row, "source").as_deref() == Some("hook")
            && text(row, "state").as_deref() != Some("done")
            && live.is_some_and(|live| live != session)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run<'a>(session: &'a str, start: Option<&'a str>) -> Run<'a> {
        Run {
            socket: Path::new("/nonexistent/s.sock"),
            terminal: Some("term_a"),
            session: Some(session),
            start_source: start,
            budget_end: Instant::now() + DEADLINE,
        }
    }

    fn rows(rows: Value) -> impl FnOnce() -> Option<Value> {
        move || Some(rows)
    }

    fn outer() -> Value {
        json!([{"terminal_id": "term_a", "source": "hook", "state": "idle",
            "extra": {"agent_session_id": "outer-1"}}])
    }

    #[test]
    fn any_launcher_w5n3_only_another_live_hook_session_is_foreign() {
        // A Claude the terminal's agent started: another live session.
        assert!(nested_in(&run("nested-2", None), rows(outer())));
        assert!(nested_in(&run("nested-2", Some("startup")), rows(outer())));
        // Compaction keeps the session: the row tells the agent from a nested one.
        assert!(!nested_in(&run("outer-1", Some("compact")), rows(outer())));
        assert!(nested_in(&run("nested-2", Some("compact")), rows(outer())));
        // The agent itself, and an agent row of another terminal.
        assert!(!nested_in(&run("outer-1", None), rows(outer())));
        let elsewhere = json!([{"terminal_id": "term_b", "source": "hook", "state": "idle",
            "extra": {"agent_session_id": "outer-1"}}]);
        assert!(!nested_in(&run("nested-2", None), rows(elsewhere)));
        // No agent yet, an ended one, or one that no hook reports.
        assert!(!nested_in(&run("nested-2", None), rows(json!([]))));
        let ended = json!([{"terminal_id": "term_a", "source": "hook", "state": "done",
            "extra": {"agent_session_id": "outer-1"}}]);
        assert!(!nested_in(&run("nested-2", None), rows(ended)));
        let screen = json!([{"terminal_id": "term_a", "source": "detected", "state": "idle"}]);
        assert!(!nested_in(&run("nested-2", None), rows(screen)));
        // A read that fails or times out keeps the hook acting as the agent.
        assert!(!nested_in(&run("nested-2", None), || None));
    }

    #[test]
    fn any_launcher_w5n3_claim_read_ends_inside_the_hook_budget() {
        let now = Instant::now();
        // Much budget left: the read has its own bound.
        assert_eq!(read_deadline(now + Duration::from_secs(4), now), Some(now + DEADLINE));
        // Less left than that bound (a slow send): the read ends with the budget.
        let end = now + Duration::from_millis(300);
        assert_eq!(read_deadline(end, now), Some(end));
        // No time left: no read.
        assert_eq!(read_deadline(now, now), None);
        assert_eq!(read_deadline(now, now + Duration::from_millis(5)), None);
    }

    #[test]
    fn any_launcher_w5n3_the_agent_after_clear_or_resume_is_never_foreign() {
        // `/clear` and an in-process `/resume` end the session first; the
        // roster may still show it live. No read is made.
        let unread = || -> Option<Value> { panic!("no roster read") };
        assert!(!nested_in(&run("outer-2", Some("clear")), unread));
        assert!(!nested_in(&run("older-0", Some("resume")), unread));
    }
}
