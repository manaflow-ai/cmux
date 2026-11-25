use super::*;

#[test]
fn real_error_texts_get_their_class() {
    use FailureCode::*;
    let table = [
        ("You've hit your usage limit", RateLimit),
        ("Claude AI usage limit reached|1700000000", RateLimit),
        ("API Error: 429 {\"type\":\"rate_limit_error\"}", RateLimit),
        ("Rate limit exceeded, retry in 20s", RateLimit),
        ("API Error: 529 Overloaded", RateLimit),
        ("overloaded_error: Overloaded", RateLimit),
        ("exceeded your current quota", RateLimit),
        ("Please run /login · API Error: 401", AuthExpired),
        ("Invalid API key · Please run /login", AuthExpired),
        ("401 Unauthorized", AuthExpired),
        ("OAuth token has expired. Please obtain a new token", AuthExpired),
        ("Your access token could not be refreshed: refresh token was already used", AuthExpired),
        ("Prompt is too long", ContextFull),
        ("API Error: 400 prompt is too long: 250000 tokens > 200000 maximum", ContextFull),
        ("Your input exceeds the context window of this model", ContextFull),
        ("context_length_exceeded", ContextFull),
        ("read ECONNRESET", Network),
        ("Network error: fetch failed", Network),
        ("stream disconnected before completion", Network),
        ("request timed out", Network),
        ("error sending request for url (https://api.openai.com)", Network),
        ("agent process exited unexpectedly", AgentCrashed),
        ("codex exited with code 137", AgentCrashed),
        ("thread 'main' panicked at src/lib.rs", AgentCrashed),
        ("Tool call failed: Edit", ToolError),
        ("MCP error -32000: request failed", ToolError),
        ("something odd happened", Other),
        ("", Other),
    ];
    for (text, want) in table {
        assert_eq!(failure_code(text), want, "{text:?}");
    }
}

#[test]
fn a_status_number_matches_whole_only() {
    assert_eq!(failure_code("job 14290 failed"), FailureCode::Other);
    assert_eq!(failure_code("HTTP 429"), FailureCode::RateLimit);
    assert_eq!(failure_code("HTTP 4010"), FailureCode::Other);
}

#[test]
fn context_wins_over_status_numbers() {
    assert_eq!(failure_code("401? no: prompt is too long"), FailureCode::ContextFull);
}

#[test]
fn codes_are_stable_strings() {
    let all = [
        (FailureCode::RateLimit, "rate_limit"),
        (FailureCode::AuthExpired, "auth_expired"),
        (FailureCode::ContextFull, "context_full"),
        (FailureCode::Network, "network"),
        (FailureCode::AgentCrashed, "agent_crashed"),
        (FailureCode::ToolError, "tool_error"),
        (FailureCode::Other, "other"),
    ];
    for (code, text) in all {
        assert_eq!(code.code(), text);
    }
}

#[test]
fn same_code_folds_within_the_window_and_other_never_does() {
    let mut folds = FailureFolds::default();
    let t = Instant::now();
    let code = FailureCode::RateLimit;
    assert_eq!(folds.admit(code, t), Fold::Own);
    assert_eq!(folds.admit(code, t + Duration::from_secs(5)), Fold::Group { window: 1, count: 2 });
    assert_eq!(folds.admit(code, t + Duration::from_secs(30)), Fold::Silent);
    // Another code has its own window.
    assert_eq!(folds.admit(FailureCode::Network, t + Duration::from_secs(31)), Fold::Own);
    // Past the window from its first failure: a new window.
    assert_eq!(folds.admit(code, t + Duration::from_secs(61)), Fold::Own);
    assert_eq!(folds.admit(code, t + Duration::from_secs(62)), Fold::Group { window: 3, count: 2 });
    assert_eq!(folds.admit(FailureCode::Other, t), Fold::Own);
    assert_eq!(folds.admit(FailureCode::Other, t), Fold::Own);
}
