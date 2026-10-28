//! What a failed turn's error says about its cause: the account (`is_limit_error`, solved by
//! the fallback profile, `turns.rs`), or a moment's trouble upstream, the provider's or the
//! gateway's capacity, the connection, or the agent's death (`resume_cause`, solved by an
//! automatic continuation in the same session, `auto_resume.rs`).
//!
//! A capacity error (`is_capacity_error`) is not a limit: the SR2 gateway's 503 "no
//! non-exhausted ... accounts" comes from the pool the fallback profile would move the session
//! onto, and a 529 overloaded is the provider's, whichever account asks. The session waits and
//! goes on where it is (subsession-card, 2026-10-26).

/// Whether `code` (three digits) is in `m` as a number of its own: "HTTP 503", not "2503s".
fn has_status(m: &str, code: &str) -> bool {
    let bytes = m.as_bytes();
    m.match_indices(code).any(|(at, _)| {
        let before = at.checked_sub(1).map(|i| bytes[i]);
        let after = bytes.get(at + code.len()).copied();
        !before.is_some_and(|b| b.is_ascii_alphanumeric())
            && !after.is_some_and(|b| b.is_ascii_alphanumeric())
    })
}

/// Does an agent error mean the account cannot serve, not that the prompt
/// was wrong? Usage and rate limits, and missing or rejected credentials:
/// all of them are solved by another account, which the fallback provides.
pub fn is_limit_error(message: &str) -> bool {
    let m = message.to_lowercase();
    m.contains("not logged in")
        || m.contains("/login")
        || m.contains("unauthorized")
        || m.contains("authentication")
        || m.contains("invalid api key")
        || has_status(&m, "401")
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
        || has_status(&m, "429")
}

/// Does an agent error mean the provider or the gateway had no capacity for the request a
/// moment ago: HTTP 503 or 529, `overloaded_error`, the SR2 gateway's "no non-exhausted ...
/// accounts", Codex's "Selected model is at capacity"? Usage limits and sign-in failures are
/// not (`transient_cause` checks those first).
pub fn is_capacity_error(message: &str) -> bool {
    let m = message.to_lowercase();
    has_status(&m, "503")
        || has_status(&m, "529")
        || m.contains("overloaded")
        || m.contains("at capacity")
        || (m.contains("no non-exhausted") && m.contains("account"))
}

/// Does an agent error mean the connection to the model dropped, not that the prompt or the
/// account was at fault? Limit and sign-in errors are excluded: another account solves those.
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
    ];
    PHRASES.iter().any(|p| m.contains(p))
        || (m.contains("websocket")
            && (m.contains("handshake") || m.contains("closed") || m.contains("disconnect")))
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

/// Why an agent's error is worth trying again in a moment, if it is: `capacity`
/// ([`is_capacity_error`]) or `transport` ([`is_transport_error`]). A usage limit, a sign-in
/// failure (`recovery::auth_kind`: not one that says the provider was unreachable), a bad
/// request, a refused permission ([`is_refused_request`]) and anything else are not: None.
pub fn transient_cause(error: &str) -> Option<&'static str> {
    if is_limit_error(error)
        || crate::recovery::auth_kind(error).is_some()
        || is_refused_request(error)
    {
        return None;
    }
    if is_capacity_error(error) {
        Some("capacity")
    } else if is_transport_error(error) {
        Some("transport")
    } else {
        None
    }
}

/// A process exit needs its stderr-enriched explanation; transport errors keep their raw cause.
pub(super) fn continuation_error<'a>(raw: Option<&'a str>, shown: &'a str) -> &'a str {
    match raw {
        Some(raw) if !raw.starts_with("agent process closed") => raw,
        _ => shown,
    }
}

/// Why a failed turn is continued by itself, if it is: `capacity` or `transport`
/// ([`transient_cause`]), or `agent_exited` (its agent process died mid-turn: "agent process
/// closed"). `raw` is the
/// agent's own error, `shown` the turn's error as recorded (with the dead process's last stderr
/// line, or the sign-in explanation). A limit or sign-in failure (an expired credential too,
/// unless the error also says the provider was unreachable) in either is never continued:
/// the fallback profile, or the reconciler that reads `lastTurn`, moves that session. Nor is a
/// refused request ([`is_refused_request`]) in either: an agent that died of one would be
/// refused the same way again.
pub fn resume_cause(raw: &str, shown: &str) -> Option<&'static str> {
    if is_limit_error(raw)
        || is_limit_error(shown)
        || crate::recovery::auth_kind(shown).is_some()
        || is_refused_request(raw)
        || is_refused_request(shown)
    {
        return None;
    }
    if raw.starts_with("agent process closed") {
        return Some("agent_exited");
    }
    transient_cause(raw)
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
        // An expired credential is a sign-in failure too (`recovery::auth_kind`: auth.expired).
        assert_eq!(resume_cause(raw, "agent process closed (claude): credential expired"), None);
        // An unreachable provider is still retried, whatever it says of a credential.
        let dropped = "token expired? connection refused";
        assert_eq!(resume_cause(dropped, dropped), Some("transport"));
        assert_eq!(
            resume_cause("HTTP 503: credential expired", "HTTP 503: credential expired"),
            Some("capacity")
        );
        for m in ["HTTP 503: OAuth token has expired", "connection error: OAuth token has expired"]
        {
            assert!(resume_cause(m, m).is_some(), "{m}");
        }
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

    /// The gateway's and the provider's "try again in a moment" (subsession-card, 2026-10-26:
    /// five helpers died on the first of these and sat failed until a person typed "continue").
    const CAPACITY: &[&str] = &[
        "API Error: 503 no non-exhausted claude accounts available. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (sr2-gateway.tail137216.ts.net:4016). (error type server_error, HTTP 503 Service Unavailable)",
        "API Error: 503 no non-exhausted claude accounts available, next account frees up in 50m (retry after 2401s). This is a server-side issue, usually temporary. Try again in a moment.",
        "API Error: 503 no non-exhausted claude accounts available, next account frees up in 7m (retry after 429s).",
        "API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
        "Selected model is at capacity.",
        "Selected model is at capacity. overloaded",
        "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
    ];

    #[test]
    fn an_agent_that_died_of_a_refused_request_is_not_continued() {
        let raw = "agent process closed";
        let shown = "agent process closed (fake): HTTP 403 permission denied";
        assert_eq!(resume_cause(raw, shown), None);
        let shown = "agent process closed (claude): API Error: 400 invalid_request_error";
        assert_eq!(resume_cause(raw, shown), None);
        // Its last line naming its own process id or port is still a death to continue.
        let shown = "agent process closed (claude): exited 4003";
        assert_eq!(resume_cause(raw, shown), Some("agent_exited"));
    }

    #[test]
    fn capacity_errors_are_continued_in_place() {
        for m in CAPACITY {
            assert!(!is_limit_error(m), "{m}");
            assert!(is_capacity_error(m), "{m}");
            assert_eq!(transient_cause(m), Some("capacity"), "{m}");
            assert_eq!(resume_cause(m, m), Some("capacity"), "{m}");
        }
        // A status code is a number of its own, not digits inside another one.
        assert!(!is_capacity_error("retry after 2503s"));
        assert!(!is_limit_error("next account frees up in 4290s"));
        assert!(!is_limit_error("session 7f401ab"));
        assert!(is_limit_error("HTTP 401 Unauthorized"));
        assert!(is_limit_error("API Error: 429 Too Many Requests"));
    }

    #[test]
    fn a_dropped_gateway_connection_is_continued() {
        for m in [
            "API Error: request to http://127.0.0.1:4016/v1/messages failed, reason: read ECONNRESET",
            "error sending request: connection reset by peer",
            "API Error: unexpected EOF while reading the response from the gateway",
            "stream error: unexpected end of file",
        ] {
            assert_eq!(transient_cause(m), Some("transport"), "{m}");
            assert_eq!(resume_cause(m, m), Some("transport"), "{m}");
        }
    }

    #[test]
    fn limits_sign_in_bad_requests_and_refusals_are_never_continued() {
        for m in [
            "You've hit your limit · resets 3pm (America/Los_Angeles)",
            "API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Rate limited\"}}",
            "You've reached your usage limit for this account",
            "API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}",
            "Not logged in · Please run /login",
            "Invalid API key · Fix external API key",
            "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long\"}}",
            "The user doesn't want to proceed with this tool use. The tool use was rejected.",
            "Permission denied: the person refused this command",
            "simulated internal error",
        ] {
            assert_eq!(transient_cause(m), None, "{m}");
            assert_eq!(resume_cause(m, m), None, "{m}");
        }
        // A limit, a sign-in failure or a refused request wins over a capacity or connection
        // word in the same text.
        for m in [
            "API Error: 429 rate_limit_error: the service is at capacity for your plan",
            "API Error: 400 invalid_request_error: unexpected EOF while parsing JSON",
            "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"overloaded_error is not a valid tool name\"}}",
            "API Error: 403 {\"type\":\"error\",\"error\":{\"type\":\"permission_error\",\"message\":\"connection reset by policy\"}}",
            "HTTP 413 request_too_large: the gateway closed the connection (connection reset)",
            "Bad Request: stream disconnected",
            "Not logged in · Please run /login (connection error)",
        ] {
            assert!(is_refused_request(m) || is_limit_error(m) || m.contains("/login"), "{m}");
            assert_eq!(transient_cause(m), None, "{m}");
            assert_eq!(resume_cause(m, m), None, "{m}");
        }
        // The gateway's address is no status: port 4016 is not a 401 nor a 403.
        assert!(!is_refused_request("check your inference gateway (127.0.0.1:4016)"));
        assert!(!is_refused_request("retry after 4003s"));
    }
}
