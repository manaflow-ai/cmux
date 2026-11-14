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
        assert_eq!(resume_cause(m, m), Some("capacity"), "{m}");
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
    assert_eq!(
        resume_cause(raw, "agent process closed (claude): You've hit your limit"),
        Some("capacity")
    );
    // An expired credential is a sign-in failure too (`recovery::auth_kind`: auth.expired).
    assert_eq!(resume_cause(raw, "agent process closed (claude): credential expired"), None);
    // An unreachable provider is still retried, whatever it says of a credential.
    let dropped = "token expired? connection refused";
    assert_eq!(resume_cause(dropped, dropped), Some("transport"));
    assert_eq!(
        resume_cause("HTTP 503: credential expired", "HTTP 503: credential expired"),
        Some("capacity")
    );
    for m in ["HTTP 503: OAuth token has expired", "connection error: OAuth token has expired"] {
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

/// Claude Code's own words when a chat outgrew its model's window (Leo, 2026-11-03: "this
/// should not have happened. this should have just started compacting"): a 400 that is
/// still worth going on from, once the chat is compacted (`auto_resume/compact_first.rs`).
const CONTEXT: &[&str] = &[
    "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 211234 tokens > 200000 maximum\"},\"request_id\":\"req_011CUx2\"}",
    "Prompt is too long",
    "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"input length and `max_tokens` exceed context limit: 188000 + 32000 > 200000, decrease input length or `max_tokens` and try again\"}}",
    "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"This model's maximum context length is 128000 tokens.\"}}",
];

#[test]
fn a_chat_that_outgrew_its_context_is_continued_after_compacting() {
    for m in CONTEXT {
        assert_eq!(resume_cause(m, m), Some("context"), "{m}");
        // A dead agent's last line says so too.
        let shown = format!("agent process closed (claude): {m}");
        assert_eq!(resume_cause("agent process closed", &shown), Some("context"), "{m}");
    }
    // Any other bad request is still refused for good.
    let other = "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"messages.3: tool_use ids must be unique\"}}";
    assert_eq!(resume_cause(other, other), None);
    // A sign-in failure wins over the window's words.
    let signed_out = "Not logged in · Please run /login (prompt is too long)";
    assert_eq!(resume_cause(signed_out, signed_out), None);
    // Not a transient error: nothing else retries it as one.
    assert_eq!(transient_cause(CONTEXT[0]), None);
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
        "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"messages.3: tool_use ids must be unique\"}}",
        "The user doesn't want to proceed with this tool use. The tool use was rejected.",
        "Permission denied: the person refused this command",
        "simulated internal error",
    ] {
        assert_eq!(transient_cause(m), None, "{m}");
        assert_eq!(
            resume_cause(m, m),
            if is_usage_limit_error(m) && !is_refused_request(m) { Some("capacity") } else { None },
            "{m}"
        );
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
        assert_eq!(
            resume_cause(m, m),
            if is_usage_limit_error(m) && !is_refused_request(m) { Some("capacity") } else { None },
            "{m}"
        );
    }
    // The gateway's address is no status: port 4016 is not a 401 nor a 403.
    assert!(!is_refused_request("check your inference gateway (127.0.0.1:4016)"));
    assert!(!is_refused_request("retry after 4003s"));
}
