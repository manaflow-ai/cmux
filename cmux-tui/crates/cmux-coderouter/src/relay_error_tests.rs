use super::*;

#[test]
fn relay_refusals_that_retrying_cannot_fix_say_so() {
    let response = final_json_error(
        StatusCode::SERVICE_UNAVAILABLE,
        "router.no_upstream",
        "the cmux model router is not connected; open cmux",
    );
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(response.headers().get("x-should-retry").unwrap(), "false");
    assert_eq!(response.headers().get("content-type").unwrap(), "application/json");
    // A plain relay error (the router did not answer) stays retryable.
    let transient = json_error(
        StatusCode::BAD_GATEWAY,
        "router.unreachable",
        "the cmux model router did not answer",
    );
    assert!(transient.headers().get("x-should-retry").is_none());
    // The hosted router's own retry advice reaches the harness.
    assert!(FORWARD_RESPONSE_HEADERS.contains(&"x-should-retry"));
}
