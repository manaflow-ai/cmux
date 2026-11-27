//! The session supervisor's decision: what to do about a session that ended, from its exit
//! record (RFD 0177 §4, build 6, in cmuxterm-hq `docs/rfd/0177-kernel-proc-lifecycle.md`).
//!
//! Leo, 2026-11-24: "also try to fix up whateve occured that closed the lanes when they weren't
//! finished? we need to be more persistent somehow when agents die but they have important work".
//!
//! OTP's supervisor taken wholesale, adapted where an agent differs from a process:
//!
//! - **Restart type from owned work** ([`restart_type`]). A session whose exit owns an open PR,
//!   a goal or a role is `permanent`; one that crashed, was killed or dropped is `transient`
//!   (restarted only after an abnormal exit, so a drop is left down); one whose closer said
//!   `done` is `temporary` (never restarted).
//! - **Intensity in restarts and tokens** ([`Intensity`]). At most `max_restarts` restarts and
//!   `max_tokens` tokens in `window_ms`; past either, the failure escalates to the parent
//!   instead of looping (today's `auto_resume_exhausted` escalates to nobody).
//! - **Restart means resume**: the decision names the transcript to resume from; a caller that
//!   finds the transcript itself is the poison falls back to a fresh session handed a summary.
//!
//! The policy: at most 3 restarts in a 6 h window; a session that owns open work is restarted
//! first; past the limit its owner is handed it. Pure: no hub, no clock.
//! `hub/exit_notify.rs` logs the decision next to the exit record when `ACPMUX_SUPERVISOR=1`
//! (default off); nothing acts on it yet.

use crate::exit_record::{ExitClass, ExitRecord};
use serde::Serialize;

/// The event kind the decision is logged as, in the ended session's chat.
pub const KIND: &str = "supervisor_decision";

/// Whether decisions are logged (`ACPMUX_SUPERVISOR=1` turns it on; off by default).
pub fn enabled() -> bool {
    std::env::var("ACPMUX_SUPERVISOR").is_ok_and(|v| v.trim() == "1")
}

/// OTP's child restart types.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RestartType {
    /// Always restarted: it owns work someone waits on.
    Permanent,
    /// Restarted only after an abnormal exit (crashed or killed).
    Transient,
    /// Never restarted: its work is done.
    Temporary,
}

/// The restart type of the session `rec` records (module docs).
pub fn restart_type(rec: &ExitRecord) -> RestartType {
    match rec.class {
        ExitClass::Done => RestartType::Temporary,
        _ if rec.owned.any() => RestartType::Permanent,
        ExitClass::Crashed | ExitClass::Killed | ExitClass::Dropped => RestartType::Transient,
    }
}

/// Whether the exit was abnormal: the session's work was cut, not finished or let go.
fn abnormal(class: ExitClass) -> bool {
    matches!(class, ExitClass::Crashed | ExitClass::Killed)
}

/// The intensity limit: OTP's `MaxR` restarts in `MaxT`, plus a token budget in the same window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Intensity {
    pub max_restarts: u32,
    pub window_ms: u64,
    pub max_tokens: u64,
}

impl Default for Intensity {
    /// 3 restarts in 6 h, and a token budget a crash loop would pass.
    fn default() -> Self {
        Self { max_restarts: 3, window_ms: 6 * 3600 * 1000, max_tokens: 2_000_000 }
    }
}

/// One earlier restart of the same session: when, and the tokens its run used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Restart {
    pub at_ms: u64,
    pub tokens: u64,
}

/// What the supervisor does about one exit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Decision {
    /// Resume the session from its transcript.
    Restart { transcript: Option<String> },
    /// Leave it down: nothing waits on it.
    Leave { why: &'static str },
    /// Past the intensity limit: hand the failure to the parent (none named: to nobody, said).
    Escalate { to: Option<String>, why: String },
}

/// The decision for `rec`, ended at `now_ms` with its last run having used `tokens`, given its
/// earlier `restarts` and the `parent` it escalates to.
pub fn decide(
    rec: &ExitRecord,
    now_ms: u64,
    tokens: u64,
    restarts: &[Restart],
    limit: Intensity,
    parent: Option<&str>,
) -> Decision {
    let kind = restart_type(rec);
    match kind {
        RestartType::Temporary => return Decision::Leave { why: "done" },
        RestartType::Transient if !abnormal(rec.class) => {
            return Decision::Leave { why: "normal exit" };
        }
        _ => {}
    }
    let since = now_ms.saturating_sub(limit.window_ms);
    let recent = restarts.iter().filter(|r| r.at_ms >= since);
    let (count, spent) =
        recent.fold((0u32, tokens), |(n, t), r| (n + 1, t.saturating_add(r.tokens)));
    let window_min = limit.window_ms / 60_000;
    let why = if count >= limit.max_restarts {
        Some(format!("{count} restarts in {window_min} min (max {})", limit.max_restarts))
    } else if spent > limit.max_tokens {
        Some(format!("{spent} tokens in {window_min} min (max {})", limit.max_tokens))
    } else {
        None
    };
    match why {
        Some(why) => Decision::Escalate { to: parent.map(str::to_owned), why },
        None => Decision::Restart { transcript: rec.transcript.clone() },
    }
}

#[cfg(test)]
#[path = "supervisor_tests.rs"]
mod tests;
