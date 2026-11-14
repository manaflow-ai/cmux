use super::is_route_failure;

#[test]
fn overloads_with_or_without_a_status_are_route_failures() {
    for m in [
        "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
        "Selected model is at capacity. overloaded",
        "API Error: 529 overloaded_error",
        "API Error: 503 no non-exhausted claude accounts available",
        "You've reached your usage limit for this account",
        "API Error: 500 Internal server error",
        "connection refused",
    ] {
        assert!(is_route_failure(m), "{m}");
    }
    assert!(!is_route_failure("simulated internal error"));
}
