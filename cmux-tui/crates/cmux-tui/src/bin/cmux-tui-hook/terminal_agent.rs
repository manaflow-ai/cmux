//! Which Claude in a terminal is the terminal's agent.
//!
//! A Claude that the terminal's agent starts (from a hook, an MCP server or
//! a teammate) gets the terminal's environment but does not source the
//! agent's `CLAUDE_ENV_FILE`, so it has no claim (plugin_copy.rs). Before a
//! Claude hook hands over messages, the startup banner or the session
//! context, it checks whether the terminal already has another agent:
//!
//! - A Claude whose `CLAUDE_PID` is the one this terminal's agent recorded
//!   at its `SessionStart` is that agent (after `/clear` or `/resume`).
//! - Without a `CLAUDE_PID`, a `SessionStart` with source `clear` is the
//!   terminal's agent: only a running Claude starts a session that way.
//! - Else one `agent.list` read of the terminal: a live hook session other
//!   than this one means this Claude is another agent's. A read that fails or
//!   times out means it is the terminal's agent, so the agent is never
//!   silenced by a daemon that does not answer in time. At `SessionStart`
//!   the read ends inside the hook's time budget; with no time left it is
//!   not made, with the same result as a failed read. Only a read that
//!   shows this session as the terminal's (or no live session) records this
//!   process, at its start or at a later prompt.
//!
//! Limits (docs/agent-hooks.md): a Claude that ended without `SessionEnd`
//! (a crash, `kill -9`) leaves a live row, and the next Claude started by
//! hand in that terminal counts as another agent's until the screen detector
//! replaces the row. Such starts are counted in the hook-spool directory
//! ([`STALE_AGENT_ROWS`]). A nested Claude whose start reaches the daemon
//! first takes the row the same way.

use cmux_tui_core::diagnostics::{
    existing_hook_spool_dir, hook_spool_dir, open_spool_file, queue_prefix, spool_name_part,
};

use super::*;

/// How long `agent.list` may take before the hook reports as the agent.
const DEADLINE: Duration = Duration::from_millis(1500);
/// A recorded process id is a few digits; a larger file is not read.
const MAX_PID_BYTES: u64 = 32;
/// A row without a hook event for this long may be left by a Claude that
/// ended without `SessionEnd` (cmux-tui-core `STALE_HOOK_MS`).
const STALE_ROW_MS: u64 = 30_000;
/// The count of `startup` sessions that met such a row, in the hook-spool
/// directory.
pub(super) const STALE_AGENT_ROWS: &str = "claude-stale-agent-rows";

/// One Claude hook run in a terminal.
pub(super) struct Run<'a> {
    pub(super) socket: &'a Path,
    pub(super) terminal: Option<&'a str>,
    pub(super) session: Option<&'a str>,
    /// The `SessionStart` payload's `source`; `None` for other events.
    pub(super) start_source: Option<&'a str>,
    /// `CLAUDE_PID`, digits only.
    pub(super) pid: Option<&'a str>,
    /// When the hook's time budget ends (a `SessionStart`): the read ends by
    /// then, and none is made with no time left. `None`: the read's own bound.
    pub(super) budget_end: Option<Instant>,
}

impl Run<'_> {
    /// Whether this Claude is not the terminal's agent but one it started.
    /// A read that shows this session as the terminal's records this process.
    pub(super) fn is_nested(&self) -> bool {
        self.check(false, || self.read_roster())
    }

    /// [`Self::is_nested`] for the journal hook's `SessionStart`: a read that
    /// shows no other live session records this process too, and a start
    /// beside a row that a crash may have left is counted. The
    /// session-context hook runs beside it through [`Self::is_nested`], so
    /// it does neither.
    pub(super) fn start_is_nested(&self) -> bool {
        self.check(true, || self.read_roster())
    }

    fn check(&self, at_start: bool, read: impl FnOnce() -> anyhow::Result<Value>) -> bool {
        let recorded = self.terminal.and_then(|terminal| recorded_pid(self.socket, terminal));
        let nested = nested_in(self, recorded.as_deref(), read, now_ms());
        if nested == Nested::Own || (at_start && nested == Nested::Free) {
            self.record_agent();
        }
        if at_start && nested == Nested::StaleRow {
            // Claude Code keeps a hook's stderr in its debug log.
            eprintln!(
                "cmux-tui-hook: {} startup beside a quiet agent row of another process; counted in {STALE_AGENT_ROWS}",
                self.terminal.unwrap_or_default()
            );
            let _ = count_stale_row(self.socket);
        }
        nested.is_nested()
    }

    fn read_roster(&self) -> anyhow::Result<Value> {
        let params = json!({"terminal_id": self.terminal.unwrap_or_default()});
        let now = Instant::now();
        let budget_end = self.budget_end.unwrap_or(now + DEADLINE);
        let deadline = read_deadline(budget_end, now).context("no time left to read")?;
        inbox::request(self.socket, "agent.list", params, false, deadline)
    }

    /// Records this Claude as the terminal's agent.
    fn record_agent(&self) {
        let (Some(terminal), Some(pid)) = (self.terminal, self.pid) else { return };
        let Ok(path) = pid_file(self.socket, terminal) else { return };
        let temporary = path.with_extension(format!("claude-pid.{}", std::process::id()));
        let written = open_spool_file(&temporary)
            .and_then(|mut file| file.set_len(0).and_then(|()| file.write_all(pid.as_bytes())));
        if written.and_then(|()| std::fs::rename(&temporary, &path)).is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
    }
}

/// When the `agent.list` read made at `now` must end: its own bound, cut to
/// the end of the hook's time budget (`budget_end`). `None` when no time is
/// left, and the hook then makes no read.
fn read_deadline(budget_end: Instant, now: Instant) -> Option<Instant> {
    let deadline = (now + DEADLINE).min(budget_end);
    (deadline > now).then_some(deadline)
}

/// The verdict of [`nested_in`].
#[derive(Debug, PartialEq, Eq)]
enum Nested {
    /// The terminal's agent: its recorded process, or a clear without one.
    No,
    /// The roster shows this session as the terminal's live one.
    Own,
    /// The roster shows no live session of another Claude.
    Free,
    /// Reported as the agent because the roster read failed; not recorded.
    Unread,
    Yes,
    /// Nested, and the other session's row looks left over: a `startup`
    /// session of another process, with no hook event on that row for
    /// [`STALE_ROW_MS`].
    StaleRow,
}

impl Nested {
    fn is_nested(&self) -> bool {
        matches!(self, Self::Yes | Self::StaleRow)
    }
}

/// [`Run::is_nested`] over `recorded` (the agent's recorded process id) and
/// one `agent.list` read, at `now` (ms since the epoch).
fn nested_in(
    run: &Run<'_>,
    recorded: Option<&str>,
    read: impl FnOnce() -> anyhow::Result<Value>,
    now: u64,
) -> Nested {
    let (Some(terminal), Some(session)) = (run.terminal, run.session) else { return Nested::No };
    if run.pid.is_some() && run.pid == recorded {
        return Nested::No;
    }
    // A known process of another Claude may `/clear` too: it is checked.
    if run.pid.is_none() && run.start_source == Some("clear") {
        return Nested::No;
    }
    let Ok(rows) = read() else { return Nested::Unread };
    let text = |row: &Value, key: &str| row.get(key).and_then(Value::as_str).map(str::to_owned);
    let other = rows.as_array().into_iter().flatten().find(|row| {
        let live = row.get("extra").and_then(|extra| text(extra, "agent_session_id"));
        text(row, "terminal_id").as_deref() == Some(terminal)
            && text(row, "source").as_deref() == Some("hook")
            && text(row, "state").as_deref() != Some("done")
            && live.is_some_and(|live| live != session)
    });
    let Some(other) = other else {
        let own = rows.as_array().into_iter().flatten().any(|row| {
            let live = row.get("extra").and_then(|extra| text(extra, "agent_session_id"));
            text(row, "terminal_id").as_deref() == Some(terminal)
                && text(row, "source").as_deref() == Some("hook")
                && text(row, "state").as_deref() != Some("done")
                && live.as_deref() == Some(session)
        });
        return if own { Nested::Own } else { Nested::Free };
    };
    let updated = other.get("updated_at_ms");
    let quiet = updated
        .and_then(Value::as_u64)
        .or_else(|| updated.and_then(Value::as_str).and_then(|at| at.parse().ok()))
        .is_some_and(|at| now.saturating_sub(at) > STALE_ROW_MS);
    if run.start_source == Some("startup") && recorded.is_some() && quiet {
        return Nested::StaleRow;
    }
    Nested::Yes
}

/// The file that names the process id of `terminal`'s agent, in the hook
/// queue directory beside `socket`.
fn pid_file(socket: &Path, terminal: &str) -> io::Result<PathBuf> {
    let name = format!("{}.{}.claude-pid", queue_prefix(socket), spool_name_part(terminal));
    Ok(hook_spool_dir(socket)?.join(name))
}

/// The recorded process id of `terminal`'s agent. Makes no directory, and
/// opens no link.
fn recorded_pid(socket: &Path, terminal: &str) -> Option<String> {
    let name = format!("{}.{}.claude-pid", queue_prefix(socket), spool_name_part(terminal));
    let path = existing_hook_spool_dir(socket).ok()??.join(name);
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::custom_flags(&mut options, libc::O_NOFOLLOW);
    let mut text = String::new();
    options.open(path).ok()?.take(MAX_PID_BYTES).read_to_string(&mut text).ok()?;
    let pid = text.trim();
    (!pid.is_empty() && pid.bytes().all(|byte| byte.is_ascii_digit())).then(|| pid.to_owned())
}

fn count_stale_row(socket: &Path) -> io::Result<()> {
    let mut file = open_spool_file(&hook_spool_dir(socket)?.join(STALE_AGENT_ROWS))?;
    file.lock()?;
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    let total = text.trim().parse::<u64>().unwrap_or(0).saturating_add(1);
    file.set_len(0)?;
    io::Seek::seek(&mut file, io::SeekFrom::Start(0))?;
    writeln!(file, "{total}")
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run<'a>(session: &'a str, start: Option<&'a str>, pid: Option<&'a str>) -> Run<'a> {
        Run {
            socket: Path::new("/nonexistent/s.sock"),
            terminal: Some("term_a"),
            session: Some(session),
            start_source: start,
            pid,
            budget_end: None,
        }
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

    fn rows(rows: Value) -> impl FnOnce() -> anyhow::Result<Value> {
        move || Ok(rows)
    }

    fn outer(updated_at_ms: u64) -> Value {
        json!([{"terminal_id": "term_a", "source": "hook", "state": "idle",
            "updated_at_ms": updated_at_ms.to_string(),
            "extra": {"agent_session_id": "outer-1"}}])
    }

    const NOW: u64 = 1_000_000;

    #[test]
    fn any_launcher_w5n3_only_another_live_hook_session_is_foreign() {
        // A Claude the terminal's agent started: another live session.
        let nested = run("nested-2", None, Some("51"));
        assert_eq!(nested_in(&nested, Some("42"), rows(outer(NOW)), NOW), Nested::Yes);
        // The agent itself, and an agent row of another terminal.
        let agent = run("outer-1", None, Some("42"));
        assert_eq!(nested_in(&agent, None, rows(outer(NOW)), NOW), Nested::Own);
        // Compaction keeps the session: the row tells the agent from a nested one.
        let compacted = run("outer-1", Some("compact"), Some("42"));
        assert_eq!(nested_in(&compacted, None, rows(outer(NOW)), NOW), Nested::Own);
        let nested_compacted = run("nested-2", Some("compact"), Some("51"));
        assert_eq!(nested_in(&nested_compacted, Some("42"), rows(outer(NOW)), NOW), Nested::Yes);
        let elsewhere = json!([{"terminal_id": "term_b", "source": "hook", "state": "idle",
            "extra": {"agent_session_id": "outer-1"}}]);
        assert_eq!(nested_in(&nested, Some("42"), rows(elsewhere), NOW), Nested::Free);
        // No agent yet, an ended one, or one that no hook reports.
        assert_eq!(nested_in(&nested, None, rows(json!([])), NOW), Nested::Free);
        let ended = json!([{"terminal_id": "term_a", "source": "hook", "state": "done",
            "extra": {"agent_session_id": "outer-1"}}]);
        assert_eq!(nested_in(&nested, None, rows(ended), NOW), Nested::Free);
        let screen = json!([{"terminal_id": "term_a", "source": "detected", "state": "idle"}]);
        assert_eq!(nested_in(&nested, None, rows(screen), NOW), Nested::Free);
        // A read that fails or times out keeps the hook reporting.
        let failed = || Err(anyhow::anyhow!("timed out"));
        let unread = nested_in(&nested, Some("42"), failed, NOW);
        assert!(unread == Nested::Unread && !unread.is_nested());
    }

    #[test]
    fn any_launcher_w5n3_the_agent_after_clear_or_resume_is_never_foreign() {
        // The roster may still show the session before `/clear` or an
        // in-process `/resume`: the start source or the recorded process
        // says this is the agent, with no read.
        let unread = || -> anyhow::Result<Value> { panic!("no roster read") };
        let clear = run("outer-2", Some("clear"), Some("42"));
        assert_eq!(nested_in(&clear, Some("42"), unread, NOW), Nested::No);
        let clear_without_pid = run("outer-2", Some("clear"), None);
        assert_eq!(nested_in(&clear_without_pid, None, unread, NOW), Nested::No);
        // Another process that clears is checked like any other start.
        let nested_clear = run("nested-3", Some("clear"), Some("51"));
        assert_eq!(nested_in(&nested_clear, Some("42"), rows(outer(NOW)), NOW), Nested::Yes);
        let resumed = run("older-0", Some("resume"), Some("42"));
        assert_eq!(nested_in(&resumed, Some("42"), unread, NOW), Nested::No);
        let prompt = run("older-0", None, Some("42"));
        assert_eq!(nested_in(&prompt, Some("42"), unread, NOW), Nested::No);
        // A `--resume` of another process is checked like any other start.
        let other = run("older-0", Some("resume"), Some("51"));
        assert_eq!(nested_in(&other, Some("42"), rows(outer(NOW)), NOW), Nested::Yes);
    }

    #[test]
    fn any_launcher_w5n3_limit_a_start_beside_a_crashed_agents_row_stays_nested_and_is_counted() {
        // Documented limit: the row may be left by a Claude that crashed.
        // The start stays nested (a teammate must not get the messages), and
        // is counted.
        let started = run("next-3", Some("startup"), Some("51"));
        let quiet = NOW - STALE_ROW_MS - 1;
        assert_eq!(nested_in(&started, Some("42"), rows(outer(quiet)), NOW), Nested::StaleRow);
        assert_eq!(nested_in(&started, Some("42"), rows(outer(NOW - 10)), NOW), Nested::Yes);
        assert_eq!(nested_in(&started, None, rows(outer(quiet)), NOW), Nested::Yes);
        let prompt = run("next-3", None, Some("51"));
        assert_eq!(nested_in(&prompt, Some("42"), rows(outer(quiet)), NOW), Nested::Yes);
    }

    #[cfg(unix)]
    #[test]
    fn any_launcher_w5n3_the_agent_pid_is_recorded_per_terminal() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = dir.path().join("s.sock");
        fn at<'a>(
            socket: &'a Path,
            session: &'a str,
            start: Option<&'a str>,
            pid: &'a str,
        ) -> Run<'a> {
            Run {
                socket,
                terminal: Some("term_a"),
                session: Some(session),
                start_source: start,
                pid: Some(pid),
                budget_end: None,
            }
        }
        let failed = || Err(anyhow::anyhow!("timed out"));
        let unread = || -> anyhow::Result<Value> { panic!("no roster read") };
        // The daemon does not answer: the start reports but records nothing.
        assert!(!at(&socket, "outer-1", Some("startup"), "42").check(true, failed));
        assert_eq!(recorded_pid(&socket, "term_a"), None);
        // A nested Claude's prompt is never recorded.
        assert!(at(&socket, "nested-2", None, "51").check(false, rows(outer(NOW))));
        assert_eq!(recorded_pid(&socket, "term_a"), None);
        // A later prompt whose read shows its own session records it.
        assert!(!at(&socket, "outer-1", None, "42").check(false, rows(outer(NOW))));
        assert_eq!(recorded_pid(&socket, "term_a").as_deref(), Some("42"));
        assert_eq!(recorded_pid(&socket, "term_b"), None);
        // Then an in-process `/resume` (the old session still live) needs no read.
        assert!(!at(&socket, "older-0", Some("resume"), "42").check(true, unread));
        count_stale_row(&socket).unwrap();
        count_stale_row(&socket).unwrap();
        let counted =
            std::fs::read_to_string(hook_spool_dir(&socket).unwrap().join(STALE_AGENT_ROWS));
        assert_eq!(counted.unwrap().trim(), "2");
    }
}
