use super::*;

/// The matrix every consumer is held to (OptChat's turn and compactor test against it too).
#[test]
fn capacity_account_limit_and_retry_after_matrix() {
    let rows: &[(&str, bool, bool, Option<u64>)] = &[
        ("API Error: 529 {\"type\":\"overloaded_error\"}", true, false, None),
        ("HTTP 529 overloaded_error; retry-after: 30", true, false, Some(30)),
        ("API error: 503 no non-exhausted accounts; retry after 3596s", true, false, Some(3596)),
        ("503 Service Unavailable", true, false, None),
        ("502 the gateway is at its call limit; retry", true, false, None),
        ("Selected model is at capacity", true, false, None),
        ("{\"code\":529,\"reason\":\"overloaded\"}", true, false, None),
        ("{\"error\":{\"type\":\"overloaded_error\"},\"retry_after\":12}", true, false, Some(12)),
        ("API Error: 429 rate_limit_error", false, true, None),
        ("Too Many Requests; retry-after 90", false, true, Some(90)),
        ("waited 2503s for the build", false, false, None),
        ("API Error: 400 invalid_request_error", false, false, None),
    ];
    for (message, capacity, limit, wait) in rows {
        assert_eq!(is_capacity(message), *capacity, "is_capacity({message})");
        assert_eq!(is_account_limit(message), *limit, "is_account_limit({message})");
        assert_eq!(retry_after(message), wait.map(Duration::from_secs), "retry_after({message})");
    }
}

#[test]
fn a_status_is_a_number_of_its_own() {
    assert!(has_status("http 503 unavailable", "503"));
    assert!(!has_status("took 2503s", "503"));
    assert!(!has_status("id 5290", "529"));
}
