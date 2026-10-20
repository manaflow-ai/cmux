//! What a failed turn's error says about its cause: the account (`is_limit_error`, solved by
//! the fallback profile, `turns.rs`) or the connection (`is_transport_error`, solved by an
//! automatic continuation, `auto_resume.rs`).

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
}
