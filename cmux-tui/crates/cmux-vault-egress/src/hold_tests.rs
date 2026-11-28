use std::time::Duration;

use http::{HeaderMap, HeaderValue, Method, header};

use super::*;

fn t() -> Timings {
    Timings::default()
}

#[test]
fn budget_follows_the_client_bound_less_slack() {
    // Claude Code's default API_TIMEOUT_MS is 600 s.
    assert_eq!(budget(&t(), true, Some("600")), Duration::from_secs(540));
    assert_eq!(budget(&t(), false, Some("600")), Duration::from_secs(240));
    assert_eq!(budget(&t(), false, Some("120")), Duration::from_secs(60));
    assert_eq!(budget(&t(), true, Some("30")), Duration::ZERO);
    assert_eq!(budget(&t(), true, Some("86400")), Duration::from_secs(3540));
}

#[test]
fn budget_without_a_bound_is_the_non_stream_one() {
    assert_eq!(budget(&t(), true, None), Duration::from_secs(240));
    assert_eq!(budget(&t(), true, Some("soon")), Duration::from_secs(240));
    assert_eq!(budget(&t(), false, Some("-5")), Duration::from_secs(240));
}

#[test]
fn stream_is_read_from_the_body() {
    assert!(is_stream(br#"{"model":"m","stream":true,"messages":[]}"#));
    assert!(!is_stream(br#"{"model":"m","messages":[]}"#));
    assert!(!is_stream(br#"{"stream":false}"#));
    assert!(!is_stream(b"not json"));
}

#[test]
fn only_model_posts_to_the_hub_are_held() {
    let hold = Hold { applies: Arc::new(|h, p| h == "hub.test" && p == 443), timings: t() };
    assert!(hold.wants(&Method::POST, "/v1/messages", "hub.test", 443));
    assert!(hold.wants(&Method::POST, "/v1/messages/count_tokens", "hub.test", 443));
    assert!(!hold.wants(&Method::GET, "/v1/messages", "hub.test", 443));
    assert!(!hold.wants(&Method::POST, "/v1/messagesx", "hub.test", 443));
    assert!(!hold.wants(&Method::POST, "/v1/models", "hub.test", 443));
    assert!(!hold.wants(&Method::POST, "/v1/messages", "api.anthropic.com", 443));
}

#[test]
fn retry_after_seconds_are_read() {
    let mut headers = HeaderMap::new();
    assert_eq!(retry_after(&headers), None);
    headers.insert(header::RETRY_AFTER, HeaderValue::from_static("7"));
    assert_eq!(retry_after(&headers), Some(Duration::from_secs(7)));
    headers.insert(header::RETRY_AFTER, HeaderValue::from_static("Wed, 21 Oct 2015 07:28:00 GMT"));
    assert_eq!(retry_after(&headers), None);
}

#[test]
fn jitter_adds_at_most_a_quarter() {
    let base = Duration::from_secs(4);
    for _ in 0..50 {
        let j = jitter(base);
        assert!(j >= base && j <= base + Duration::from_secs(1), "{j:?}");
    }
}

#[test]
fn sse_error_carries_the_hub_error_or_an_overload() {
    let hub = br#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#;
    let event = String::from_utf8(sse_error(hub).to_vec()).unwrap();
    assert!(event.starts_with("event: error\ndata: "), "{event}");
    assert!(event.contains("rate_limit_error") && event.ends_with("\n\n"), "{event}");
    let event = String::from_utf8(sse_error(b"<html>bad gateway</html>").to_vec()).unwrap();
    assert!(event.contains("overloaded_error"), "{event}");
}
