use super::*;

#[test]
fn node_fetch_is_not_a_browser_but_a_page_is() {
    let with = |pairs: &[(&'static str, &'static str)]| {
        let mut headers = HeaderMap::new();
        for (name, value) in pairs {
            headers.insert(*name, value.parse().unwrap());
        }
        headers
    };
    // Node's undici fetch (pi 1.6.0 through the OpenAI SDK): only sec-fetch-mode.
    assert!(!from_a_browser(&with(&[("sec-fetch-mode", "cors"), ("accept-language", "*")])));
    assert!(!from_a_browser(&with(&[("user-agent", "curl/8")])));
    // A page's fetch, form or navigation.
    assert!(from_a_browser(&with(&[("origin", "https://evil.example")])));
    assert!(from_a_browser(&with(&[("sec-fetch-mode", "cors"), ("sec-fetch-site", "cross-site")])));
    assert!(from_a_browser(&with(&[("sec-fetch-dest", "empty")])));
    assert!(from_a_browser(&with(&[("sec-fetch-user", "?1")])));
}

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
