//! What a failed turn's error says about its cause: the account (`is_limit_error`, solved by
//! the fallback profile, `turns.rs`), or the connection or the agent's death (`resume_cause`,
//! solved by an automatic continuation, `auto_resume.rs`).

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
        || m.contains("401")
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
        || m.contains("overloaded")
        || m.contains("429")
}

/// Does an agent error mean the connection to the model dropped, not that the prompt or the
/// account was at fault? Limit and sign-in errors are excluded: another account solves those.
pub fn is_transport_error(message: &str) -> bool {
    if is_limit_error(message) {
        return false;
    }
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
}
