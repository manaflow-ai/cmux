//! What a failed turn's error says about its cause: the account (`is_limit_error`, solved by
//! the fallback profile, `turns.rs`), or the connection or the agent's death (`resume_cause`,
//! solved by an automatic continuation, `auto_resume.rs`). [`transient_cause`] tells a
//! transient upstream error (capacity or transport) from everything else, for what retries in
//! place: a failed subagent (`subagent_retry.rs`).

/// Does an agent error mean the account cannot serve, not that the prompt
/// was wrong? Usage and rate limits, and missing or rejected credentials:
/// all of them are solved by another account, which the fallback provides.
pub fn is_limit_error(message: &str) -> bool {
    let m = message.to_lowercase();
    account_error(&m) || m.contains("overloaded") || m.contains("401") || m.contains("429")
}

/// The account cannot serve (lowercased `m`): sign-in or a usage or rate limit. Status codes
/// count only as whole numbers ("retry after 2401s" is no 401).
fn account_error(m: &str) -> bool {
    m.contains("not logged in")
        || m.contains("/login")
        || m.contains("unauthorized")
        || m.contains("authentication")
        || m.contains("invalid api key")
        || has_code(m, "401")
        || (m.contains("reached your") && m.contains("limit"))
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
        || has_code(m, "429")
}

/// Whether `m` holds `code` as a whole number, not inside a longer one.
fn has_code(m: &str, code: &str) -> bool {
    let digit =
        |at: Option<usize>| at.and_then(|i| m.as_bytes().get(i)).is_some_and(u8::is_ascii_digit);
    m.match_indices(code).any(|(at, _)| !digit(at.checked_sub(1)) && !digit(Some(at + code.len())))
}

/// The model's provider has no room right now (lowercased `m`): HTTP 503 or 529, an overloaded
/// model, or a gateway with no account left to route to (SR2's "API Error: 503 no
/// non-exhausted claude accounts available", 2026-10-26). It passes in minutes.
fn capacity_error(m: &str) -> bool {
    has_code(m, "503")
        || has_code(m, "529")
        || m.contains("overloaded")
        || m.contains("no non-exhausted")
        || m.contains("at capacity")
}

/// Why an error is transient, if it is: `capacity` ([`capacity_error`]) or `transport` (the
/// connection dropped, [`is_transport_error`]'s phrases). None for a usage limit or sign-in
/// failure (another account solves those, never a wait) and for anything else (a bad request, a
/// refused permission, a bug), which a retry would only repeat.
pub fn transient_cause(error: &str) -> Option<&'static str> {
    let m = error.to_lowercase();
    if account_error(&m) || crate::claude_auth::is_sign_in_failure(error) {
        None
    } else if capacity_error(&m) {
        Some("capacity")
    } else if transport_phrase(&m) {
        Some("transport")
    } else {
        None
    }
}

/// Does an agent error mean the connection to the model dropped, not that the prompt or the
/// account was at fault? Limit and sign-in errors are excluded: another account solves those.
pub fn is_transport_error(message: &str) -> bool {
    !is_limit_error(message) && transport_phrase(&message.to_lowercase())
}

/// Whether lowercased `m` says the connection to the model dropped.
fn transport_phrase(m: &str) -> bool {
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
    ];
    PHRASES.iter().any(|p| m.contains(p))
        || (m.contains("websocket")
            && (m.contains("handshake") || m.contains("closed") || m.contains("disconnect")))
}

/// A process exit needs its stderr-enriched explanation; transport errors keep their raw cause.
pub(super) fn continuation_error<'a>(raw: Option<&'a str>, shown: &'a str) -> &'a str {
    match raw {
        Some(raw) if !raw.starts_with("agent process closed") => raw,
        _ => shown,
    }
}

/// Why a failed turn is continued by itself, if it is: `transport` (the connection dropped) or
/// `agent_exited` (its agent process died mid-turn: "agent process closed"). `raw` is the
/// agent's own error, `shown` the turn's error as recorded (with the dead process's last stderr
/// line, or the sign-in explanation). A limit or sign-in failure in either is never continued:
/// the fallback profile, or the reconciler that reads `lastTurn`, moves that session.
pub fn resume_cause(raw: &str, shown: &str) -> Option<&'static str> {
    if is_limit_error(raw) || is_limit_error(shown) || crate::claude_auth::is_sign_in_failure(shown)
    {
        return None;
    }
    if raw.starts_with("agent process closed") {
        return Some("agent_exited");
    }
    is_transport_error(raw).then_some("transport")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transport_errors_are_told_from_limits_and_bugs() {
        for m in [
            "stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses)",
            "API Error: Connection error.",
            "request to https://api.anthropic.com failed, reason: socket hang up",
            "WebSocket handshake failed: 502",
            "upstream connect error or disconnect/reset before headers",
            "read ECONNRESET",
            "API Error: Connection lost mid-response. The response above may be incomplete.",
            "API Error: 500 {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Internal server error\"}}",
        ] {
            assert!(is_transport_error(m), "{m}");
        }
        for m in [
            "You've reached your usage limit for this account",
            "Selected model is at capacity. overloaded",
            "simulated internal error",
            "agent process closed",
            "Invalid API key",
        ] {
            assert!(!is_transport_error(m), "{m}");
        }
    }

    #[test]
    fn claude_limit_texts_are_limits() {
        for m in [
            "You've hit your limit · resets 3pm (America/Los_Angeles)",
            "Claude AI usage limit reached|1760000000",
            "You have hit your usage limit for Opus.",
            "API Error: 429 rate_limit_error",
        ] {
            assert!(is_limit_error(m), "{m}");
            assert!(!is_transport_error(m), "{m}");
            assert_eq!(resume_cause(m, m), None, "{m}");
        }
        assert!(!is_limit_error("agent process closed"));
        assert!(!is_limit_error("You've hit the end of the file"));
    }

    #[test]
    fn a_dead_agent_is_continued_unless_it_died_of_a_limit_or_sign_in() {
        let raw = "agent process closed";
        assert_eq!(resume_cause(raw, raw), Some("agent_exited"));
        assert_eq!(
            resume_cause(raw, "agent process closed (claude): Segmentation fault"),
            Some("agent_exited")
        );
        assert_eq!(resume_cause(raw, "agent process closed (claude): You've hit your limit"), None);
        assert_eq!(
            resume_cause(raw, "agent process closed (fake): Not logged in · Please run /login"),
            None
        );
        assert_eq!(
            resume_cause("API Error: Connection error.", "API Error: Connection error."),
            Some("transport")
        );
        assert_eq!(resume_cause("simulated internal error", "simulated internal error"), None);
    }

    /// Leo, 2026-10-26: "this needs to retry :(". Two subagents died on SR2's 503; a 529
    /// overloaded and a model at capacity are the same kind of wait. A usage limit, a sign-in
    /// failure and a bad request never are.
    #[test]
    fn capacity_and_transport_errors_are_transient_and_limits_are_not() {
        for m in [
            "Agent terminated early due to an API error: API Error: 503 no non-exhausted claude accounts available. This is a server-side issue, usually temporary \u{2014} try again in a moment. (error type server_error, HTTP 503, model sent to the API: claude-opus-5-5)",
            "API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
            "Selected model is at capacity",
        ] {
            assert_eq!(transient_cause(m), Some("capacity"), "{m}");
        }
        for m in
            ["API Error: Connection error.", "read ECONNRESET", "retry after 2401s: socket hang up"]
        {
            assert_eq!(transient_cause(m), Some("transport"), "{m}");
        }
        for m in [
            "You've hit your limit \u{b7} resets 3pm (America/Los_Angeles)",
            "API Error: 429 rate_limit_error",
            "API Error: 401 authentication_error",
            "Not logged in \u{b7} Please run /login",
            "API Error: 400 invalid_request_error: prompt is too long",
            "API Error: 5030 something else",
            "simulated internal error",
        ] {
            assert_eq!(transient_cause(m), None, "{m}");
        }
    }
}
