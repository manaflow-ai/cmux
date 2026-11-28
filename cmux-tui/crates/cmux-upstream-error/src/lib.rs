//! One reading of an upstream model error, for every layer that waits one out.
//!
//! Before this crate, the same provider refusal was read four ways: acpmux's turn classifier
//! (`turn_errors.rs`), OptChat's compactor (`optchat_host::capacity_wait`, which found a status
//! only after "API Error: " or "HTTP "), and Chief's turn retry
//! (`optchat_chief::turn::capacity_retry_after`, which knew only "api error: 529" and
//! "retry after N"). So "HTTP 529 overloaded_error; retry-after: 30" was waited out by acpmux,
//! waited out by the compactor, and failed by a Chief turn (ask-616b73f6bc, "fix 529s properly
//! with better designs"). Each layer keeps its own policy (how long, how often, what it shows);
//! what an error *says* is decided here once.

use std::time::Duration;

/// Whether `code` (three digits) is in `message` as a number of its own: "HTTP 503", not
/// "2503s".
pub fn has_status(message: &str, code: &str) -> bool {
    let bytes = message.as_bytes();
    message.match_indices(code).any(|(at, _)| {
        let before = at.checked_sub(1).and_then(|i| bytes.get(i).copied());
        let after = at.checked_add(code.len()).and_then(|i| bytes.get(i).copied());
        !before.is_some_and(|b| b.is_ascii_alphanumeric())
            && !after.is_some_and(|b| b.is_ascii_alphanumeric())
    })
}

/// Whether the provider or the gateway had no capacity for the request a moment ago, whichever
/// account asked: HTTP 503 or 529, `overloaded_error`, "at capacity" (Codex), the SR2 gateway's
/// "no non-exhausted ... accounts", the worker gateway's "at its call limit". An account's own
/// usage or rate limit (429) is not: it is [`is_account_limit`], waited on the account's reset,
/// not the provider's.
pub fn is_capacity(message: &str) -> bool {
    let m = message.to_lowercase();
    has_status(&m, "503")
        || has_status(&m, "529")
        || m.contains("overloaded")
        || m.contains("at capacity")
        || m.contains("no non-exhausted")
        // The cmux-platform worker gateway's own ceiling (2026-11-23): "502 the gateway is at
        // its call limit; retry". Capacity, not a dropped connection.
        || m.contains("at its call limit")
}

/// Whether an account's own rate limit refused the request (HTTP 429, "rate limit",
/// "too many requests").
pub fn is_account_limit(message: &str) -> bool {
    let m = message.to_lowercase();
    has_status(&m, "429")
        || m.contains("rate limit")
        || m.contains("rate_limit")
        || m.contains("too many requests")
}

/// The wait an error's text names, in any of the forms our upstreams print: "retry after 3596s"
/// (the subrouter), "retry-after: 30" (a header copied into the message), "retry-after 30",
/// `"retry_after":30` or `"retry-after":"30"` (a JSON body).
pub fn retry_after(message: &str) -> Option<Duration> {
    let lower = message.to_ascii_lowercase();
    [
        "retry after ",
        "retry-after: ",
        "retry-after ",
        "\"retry_after\":",
        "\"retry-after\":",
        "\"retry_after_s\":",
    ]
    .iter()
    .find_map(|lead| {
        let (_, after) = lower.split_once(lead)?;
        let rest = after.trim_start_matches([' ', '"']);
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok().map(Duration::from_secs)
    })
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
