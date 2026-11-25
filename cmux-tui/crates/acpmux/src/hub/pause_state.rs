//! Paused or stranded: what a session row says of a turn that did not finish.
//!
//! Leo, 2026-11-24: "i wonder what will happen with claudes on vms... do they get stranded!? what
//! do we do ab stops and wakeups... is our pausing good". A chat whose turn an outage cut off is
//! **paused** while acpmux holds a continuation for it: the row's `retry` (its reason and when
//! it fires, `hub/auto_resume.rs`), the account's rate-limit hold (`rateLimitedUntil`,
//! `hub/rate_hold.rs`), or a retry still being decided (`retryDeciding`). It is **stranded** when
//! its last turn failed and nothing holds a continuation: no one will wake it but a prompt or
//! `acpmux retry`. Before, both read "failed turn", so 122 chats on one machine looked the same
//! whether they would come back by themselves or never (2026-11-24 22:16Z).
//!
//! The one reading of a row that `acpmux ls`, the lane report to a parent and the board share.

use serde_json::Value;

/// A row's paused or stranded state, or none (it runs, it is idle after a turn that ended, or it
/// waits on a person).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PauseState {
    /// acpmux continues it by itself: `reason` (`capacity`, `rate_limit`, `transport`,
    /// `agent_exited`, `context`), at `resumes_at` (epoch ms) when known.
    Paused { reason: String, resumes_at: Option<u64> },
    /// Its last turn failed and nothing will continue it: `cause` is the failure's class
    /// ([`cause`]), `error` its text.
    Stranded { cause: &'static str, error: String },
}

/// The class of a failed turn's error, for a stranded row: one of `resume_cause`'s
/// (`capacity`, `rate_limit`, `transport`, `agent_exited`, `context`), `disk` (no space left),
/// `auth` (a sign-in failure), `refused` (a bad or refused request), else `error`.
pub(crate) fn cause(error: &str) -> &'static str {
    let lower = error.to_lowercase();
    if lower.contains("no space left on device") || lower.contains("os error 28") {
        return "disk";
    }
    if let Some(cause) = crate::turn_errors::resume_cause(error, error) {
        return cause;
    }
    if crate::recovery::auth_kind(error).is_some() {
        return "auth";
    }
    if crate::turn_errors::is_refused_request(error) {
        return "refused";
    }
    "error"
}

/// Whether a stranded row's cause is an outage acpmux means to ride out (overload, the
/// connection, a dead agent): such a strand is acpmux's own gap, not the chat's.
pub(crate) fn is_outage(cause: &str) -> bool {
    matches!(cause, "capacity" | "rate_limit" | "transport" | "agent_exited")
}

/// The row's paused or stranded state ([module docs](self)).
pub(crate) fn of_row(row: &Value) -> Option<PauseState> {
    let retry = &row["retry"];
    if let Some(reason) = retry.get("reason").and_then(Value::as_str) {
        let resumes_at = retry.get("nextAt").and_then(Value::as_u64);
        return Some(PauseState::Paused { reason: reason.to_owned(), resumes_at });
    }
    if let Some(until) = row.get("rateLimitedUntil").and_then(Value::as_u64) {
        return Some(PauseState::Paused { reason: "rate_limit".into(), resumes_at: Some(until) });
    }
    if row.get("retryDeciding").and_then(Value::as_bool) == Some(true) {
        let last = &row["lastTurn"];
        let error = last.get("errorText").and_then(Value::as_str).unwrap_or_default();
        let reason = crate::turn_errors::resume_cause(error, error).unwrap_or("error");
        return Some(PauseState::Paused { reason: reason.into(), resumes_at: None });
    }
    // A turn that runs, or one queued to, is no strand: it is going on now.
    let running = row.get("turn").is_some_and(|t| !t.is_null())
        || row.get("status").and_then(Value::as_str) == Some("running")
        || row.get("queued").and_then(Value::as_u64).unwrap_or(0) > 0;
    let last = &row["lastTurn"];
    if running || last.get("status").and_then(Value::as_str) != Some("failed") {
        return None;
    }
    let error = last.get("errorText").and_then(Value::as_str).unwrap_or("the turn failed");
    Some(PauseState::Stranded { cause: cause(error), error: error.to_owned() })
}

/// When a pause resumes, as `HH:MMZ`, or `soon` when not known yet.
pub(crate) fn resumes_line(resumes_at: Option<u64>) -> String {
    resumes_at
        .and_then(|at| i64::try_from(at).ok())
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map_or_else(|| "soon".to_owned(), |at| at.format("%H:%MZ").to_string())
}

/// The short line `acpmux ls` shows: `paused: capacity, resumes 22:41Z` or
/// `stranded: capacity`.
pub(crate) fn short_line(state: &PauseState) -> String {
    match state {
        PauseState::Paused { reason, resumes_at } => {
            format!("paused: {}, resumes {}", reason.replace('_', " "), resumes_line(*resumes_at))
        }
        PauseState::Stranded { cause, .. } => format!("stranded: {}", cause.replace('_', " ")),
    }
}

#[cfg(test)]
#[path = "pause_state_tests.rs"]
mod tests;
