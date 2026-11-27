//! What a failed turn's error says about its cause: the account (`is_limit_error`, solved by
//! the fallback profile, `turns.rs`), or a moment's trouble upstream, the provider's or the
//! gateway's capacity, the connection, or the agent's death (`resume_cause`, solved by an
//! automatic continuation in the same session, `auto_resume.rs`).
//!
//! A router capacity error (`is_capacity_error`) is not a single-account limit: the SR2 gateway's 503 "no
//! non-exhausted ... accounts" comes from the pool the fallback profile would move the session
//! onto, and a 529 overloaded is the provider's, whichever account asks. The session waits and
//! goes on where it is (subsession-card, 2026-10-26).

/// Whether `code` (three digits) is in `m` as a number of its own: "HTTP 503", not "2503s"
/// (the shared reading, `cmux_upstream_error::has_status`).
pub(crate) fn has_status(m: &str, code: &str) -> bool {
    cmux_upstream_error::has_status(m, code)
}

/// Does an agent error mean the account cannot serve, not that the prompt
/// was wrong? Sign-in failures are solved by another account; usage and rate
/// limits recover on the same account after their reset.
pub fn is_limit_error(message: &str) -> bool {
    let m = message.to_lowercase();
    m.contains("not logged in")
        || m.contains("/login")
        || m.contains("unauthorized")
        || m.contains("authentication")
        || m.contains("invalid api key")
        || has_status(&m, "401")
        || is_usage_limit_error(message)
}

/// A usage window or rate limit can recover without changing the person's sign-in.
pub(crate) fn is_usage_limit_error(message: &str) -> bool {
    // The pool also answers 429 when every account is exhausted. Its explicit capacity
    // cause takes precedence over the HTTP code: switching or holding one account cannot
    // restore the pool, and helpers must enter the same capacity recovery as their parent.
    if is_capacity_error(message) {
        return false;
    }
    let m = message.to_lowercase();
    (m.contains("reached your") && m.contains("limit"))
        // Claude Code: "You've hit your limit · resets 3pm" (2026-10-20).
        || m.contains("hit your limit")
        || m.contains("hit your usage limit")
        || m.contains("usage limit reached")
        || m.contains("usage limit")
        || m.contains("rate limit")
        || m.contains("rate_limit")
        || m.contains("out of credits")
        || m.contains("insufficient credits")
        || m.contains("quota")
        || has_status(&m, "429")
        // HTTP 429's own words with no code printed, and Gemini's status for it.
        || m.contains("too many requests")
        || m.contains("resource_exhausted")
        || m.contains("weekly limit")
        || m.contains("session limit")
}

/// Does an agent error mean the provider or the gateway had no capacity for the request a
/// moment ago: HTTP 503 or 529, `overloaded_error`, the SR2 gateway's "no non-exhausted ...
/// accounts", Codex's "Selected model is at capacity"? Usage limits and sign-in failures are
/// not (`transient_cause` checks those first).
pub fn is_capacity_error(message: &str) -> bool {
    // One reading for acpmux and OptChat's Chief turn and compactor (ask-616b73f6bc).
    cmux_upstream_error::is_capacity(message)
}

/// An HTTP gateway failure is independent of account credentials.
pub(crate) fn is_gateway_error(message: &str) -> bool {
    let m = message.to_lowercase();
    (500..=599).any(|code| has_status(&m, &code.to_string())) || m.contains("harness_unavailable")
}

/// Does an agent error mean the connection to the model dropped, not that the prompt or the
/// account was at fault? Limit and sign-in errors are excluded from transport classification.
pub fn is_transport_error(message: &str) -> bool {
    !is_limit_error(message) && says_connection_dropped(message)
}

/// Whether an error says the provider had no capacity, a gateway failed (HTTP 502, 504) or
/// the connection dropped ([`is_capacity_error`], [`says_connection_dropped`]), whatever it
/// also says about a sign-in: such an error is never evidence of a sign-in state.
pub fn says_unreachable(message: &str) -> bool {
    let m = message.to_lowercase();
    is_capacity_error(message)
        || has_status(&m, "502")
        || has_status(&m, "504")
        || says_connection_dropped(message)
}

/// Whether an agent error's words say the connection to the model dropped, whatever else it
/// says ([`is_transport_error`] without its limit and sign-in exclusion).
pub fn says_connection_dropped(message: &str) -> bool {
    let m = message.to_lowercase();
    const PHRASES: &[&str] = &[
        "stream disconnected",
        "connection error",
        "connection reset",
        "connection refused",
        "connection closed",
        "connection aborted",
        "econnreset",
        "econnrefused",
        "etimedout",
        "socket hang up",
        "fetch failed",
        "network error",
        "error sending request",
        "broken pipe",
        "bad gateway",
        "service unavailable",
        "gateway timeout",
        "upstream connect error",
        "request timed out",
        // Claude Code: "API Error: Connection lost mid-response." (2026-10-19, a turn cut
        // mid-stream sat idle until a person typed "continue").
        "connection lost",
        "internal server error",
        "premature close",
        "other side closed",
        // The gateway's connection ended mid-answer.
        "unexpected eof",
        "unexpected end of file",
        "early eof",
        // A TLS handshake that did not verify: on Freestyle lanes (2026-11-22) ~30 Claude
        // turns failed with "API Error: Unable to connect to API: SSL certificate verification
        // failed (UNABLE_TO_VERIFY_LEAF_SIGNATURE)" when the restarted daemon's egress proxy
        // signed with a new CA the agent did not trust yet; restarting the agent on the new
        // proxy (`end_stale_proxy_before_retry`) fixes it, so it is a transport error.
        "unable to connect to api",
        "ssl certificate verification failed",
        "unable_to_verify_leaf_signature",
        "self_signed_cert_in_chain",
        "depth_zero_self_signed_cert",
        "unable to get local issuer certificate",
        "certificate verify failed",
        "invalid peer certificate",
    ];
    is_gateway_error(message)
        || PHRASES.iter().any(|p| m.contains(p))
        || (m.contains("websocket")
            && (m.contains("handshake") || m.contains("closed") || m.contains("disconnect")))
}

/// Does an agent error say nobody listened where the model was: the connection was refused
/// (`ECONNREFUSED`), as when the inference gateway is down? A dropped connection
/// ([`says_connection_dropped`]) whose outage ends only when the gateway is back, so its
/// continuation waits it out like a capacity one (`hub/auto_resume.rs` `waits_it_out`) instead
/// of using up a transport error's attempts (2026-11-24: three fresh chats ended their first
/// turn on "API Error: Connection refused (ECONNREFUSED)" and sat failed).
pub fn is_refused_connection(message: &str) -> bool {
    let m = message.to_lowercase();
    m.contains("econnrefused") || m.contains("connection refused")
}

/// Does an agent error say the request itself was refused: a bad request (HTTP 400, 413 or
/// 422, `invalid_request_error`), a refused permission (403, `permission_error`, a rejected
/// tool use) or a missing resource (404)? Sending it again fails the same way, whatever words
/// about a connection or capacity follow ("400 invalid_request_error: unexpected EOF while
/// parsing JSON").
pub fn is_refused_request(message: &str) -> bool {
    let m = message.to_lowercase();
    ["400", "403", "404", "413", "422"].iter().any(|code| has_status(&m, code))
        || m.contains("invalid_request_error")
        || m.contains("permission_error")
        || m.contains("not_found_error")
        || m.contains("request_too_large")
        || m.contains("bad request")
        || m.contains("permission denied")
        || m.contains("tool use was rejected")
}

/// Does an agent error say the chat outgrew its model's context window: Claude Code's "Prompt is
/// too long" (`400 invalid_request_error: prompt is too long: N tokens > M maximum`), "input
/// length and `max_tokens` exceed context limit", OpenAI's `context_length_exceeded` ("maximum
/// context length")? A bad request, but not one that fails the same way again once the chat is
/// compacted (Leo, 2026-11-03, on a Claude chat that sat failed on it: "this should not have
/// happened. this should have just started compacting").
pub fn is_context_overflow(message: &str) -> bool {
    let m = message.to_lowercase();
    m.contains("prompt is too long")
        || (m.contains("exceed context limit") && m.contains("input length"))
        || m.contains("context_length_exceeded")
        || m.contains("maximum context length")
        || m.contains("exceeds the context window")
}

/// Why an agent's error is worth trying again in a moment, if it is: `capacity`
/// ([`is_capacity_error`]) or `transport` ([`is_transport_error`]). A usage limit, a sign-in
/// failure (`recovery::auth_kind`: not one that says the provider was unreachable), a bad
/// request, a refused permission ([`is_refused_request`]) and anything else are not: None.
pub fn transient_cause(error: &str) -> Option<&'static str> {
    if (is_limit_error(error) && !is_gateway_error(error))
        || crate::recovery::auth_kind(error).is_some()
        || is_refused_request(error)
    {
        return None;
    }
    if is_capacity_error(error) {
        Some("capacity")
    } else if says_connection_dropped(error) {
        Some("transport")
    } else {
        None
    }
}

/// Whether `error` says the disk was full: `ENOSPC`, "No space left on device (os error 28)".
pub fn is_disk_full(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    lower.contains("no space left on device")
        || lower.contains("os error 28")
        || lower.contains("enospc")
}

/// A process exit needs its stderr-enriched explanation; transport errors keep their raw cause.
pub(crate) fn continuation_error<'a>(raw: Option<&'a str>, shown: &'a str) -> &'a str {
    match raw {
        Some(raw) if !raw.starts_with("agent process closed") => raw,
        _ => shown,
    }
}

/// Why a failed turn is continued by itself, if it is: `capacity` or `transport`
/// ([`transient_cause`]), `agent_exited` (its agent process died mid-turn: "agent process
/// closed"), or `context` (the chat outgrew its model's window, [`is_context_overflow`]: it is
/// compacted first, and only where its harness can compact, `auto_resume/compact_first.rs`).
/// `raw` is the
/// agent's own error, `shown` the turn's error as recorded (with the dead process's last stderr
/// line, or the sign-in explanation). An account's usage or rate limit (HTTP 429,
/// [`is_usage_limit_error`]) is `rate_limit`: the chat holds until its reset. A sign-in failure (including an expired credential unless the
/// provider was unreachable) is never continued. Nor is a
/// refused request ([`is_refused_request`]) in either: an agent that died of one would be
/// refused the same way again.
pub fn resume_cause(raw: &str, shown: &str) -> Option<&'static str> {
    if (is_limit_error(raw) && !is_usage_limit_error(raw) && !is_gateway_error(raw))
        || (is_limit_error(shown) && !is_usage_limit_error(shown) && !is_gateway_error(shown))
        || crate::recovery::auth_kind(raw).is_some()
        || crate::recovery::auth_kind(shown).is_some()
    {
        return None;
    }
    // A full disk clears by itself (a build's output reclaimed, a cache pruned): the chat waits
    // for free space, then goes on (`hub/auto_resume/disk_wait.rs`).
    if is_disk_full(raw) || is_disk_full(shown) {
        return Some("disk");
    }
    // Before the refused requests: a prompt past the window is a 400 that compacting answers.
    if is_context_overflow(raw) || is_context_overflow(shown) {
        return Some("context");
    }
    if is_refused_request(raw) || is_refused_request(shown) {
        return None;
    }
    // Limits are the account's: not sign-in failures, and not the provider's capacity. The chat
    // holds every turn until the reset, then goes on in this same conversation
    // (`hub/rate_hold.rs`); it does not switch accounts.
    if is_usage_limit_error(raw) || is_usage_limit_error(shown) {
        return Some("rate_limit");
    }
    if raw.starts_with("agent process closed") {
        return transient_cause(shown).or(Some("agent_exited"));
    }
    transient_cause(raw).or_else(|| transient_cause(shown))
}

#[cfg(test)]
#[path = "turn_errors_tests.rs"]
mod tests;
