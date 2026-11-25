//! What a chat shows while it waits for capacity (RFD model-overload-smoothing §3.8).
//!
//! Leo, 2026-11-24: "fix 529s properly with better designs", "send a fella to do the deep work +
//! design and stuff to smooth over these siuations better pleaseeeeeee". A turn cut by an
//! overloaded model, an exhausted account pool or the account's rate limit is held by acpmux and
//! continued by itself (`auto_resume.rs`, `rate_hold.rs`). Its row carries one reading of that
//! wait, decided here, so every client draws the same calm state ("Waiting for capacity, about
//! 40 s"; "Paused for capacity, resumes ~22:41") and never the raw "API Error: 503 …" or
//! "Repeated 529" in the chat body. The raw error rides along for a details disclosure.
//!
//! A turn nothing will continue (retries used up, auto-resume off, a parked rate limit) has no
//! wait: it stays a failed turn, which is the one state a client draws in red.

use crate::protocol::session::{CapacityWait, RetryReason, RetrySummary};
use serde_json::Value;

/// Longest raw error kept for the disclosure, in characters.
const MAX_ERROR_CHARS: usize = 600;

/// Whether `reason` is a capacity cause: the model or the gateway was full, or the account's
/// limit was spent. Connection drops, a dead agent and a full context are not.
pub(crate) fn is_capacity(reason: RetryReason) -> bool {
    matches!(reason, RetryReason::Capacity | RetryReason::RateLimit)
}

/// The chat's capacity wait, or none. `last`: the row's raw `lastTurn` (its `errorText`,
/// `turnId`, `endedAt`); `retry`: the continuation that waits; `deciding`: a continuation is being
/// decided or runs; `rate_until`: the account's rate-limit hold.
pub(crate) fn of(
    last: Option<&Value>,
    retry: Option<&RetrySummary>,
    deciding: bool,
    rate_until: Option<u64>,
) -> Option<CapacityWait> {
    let failed = last.filter(|l| l.get("status").and_then(Value::as_str) == Some("failed"));
    let error = failed.and_then(|l| l.get("errorText")).and_then(Value::as_str).unwrap_or_default();
    let cut_by = (!error.is_empty())
        .then(|| super::turn_errors::resume_cause(error, error).and_then(RetryReason::from_cause))
        .flatten();
    let (reason, resumes_at, turn_id) = if let Some(r) = retry.filter(|r| is_capacity(r.reason)) {
        (r.reason, Some(r.next_at), Some(r.turn_id.clone()))
    } else if let Some(until) = rate_until {
        (RetryReason::RateLimit, Some(until), None)
    } else if deciding && cut_by.is_some_and(is_capacity) {
        (cut_by?, None, None)
    } else {
        return None;
    };
    let turn_id = turn_id.or_else(|| {
        failed.and_then(|l| l.get("turnId")).and_then(Value::as_str).map(str::to_owned)
    });
    let since = failed.and_then(|l| l.get("endedAt")).and_then(Value::as_u64);
    let error = (!error.is_empty()).then(|| error.chars().take(MAX_ERROR_CHARS).collect());
    Some(CapacityWait { reason, resumes_at, turn_id, since, error })
}

/// A list row's line for the row's serialized `capacityWait`: "paused for capacity, resumes
/// ~22:41Z", or "paused for capacity" while its time is not known. None without a wait.
pub(crate) fn paused_line(wait: &Value) -> Option<String> {
    wait.get("reason").and_then(Value::as_str)?;
    let at = wait
        .get("resumesAt")
        .and_then(Value::as_u64)
        .and_then(|at| i64::try_from(at).ok())
        .and_then(chrono::DateTime::from_timestamp_millis);
    Some(match at {
        Some(at) => format!("paused for capacity, resumes ~{}", at.format("%H:%MZ")),
        None => "paused for capacity".to_owned(),
    })
}

#[cfg(test)]
#[path = "capacity_wait_tests.rs"]
mod tests;
