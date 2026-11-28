use super::*;
use serde_json::json;

#[test]
fn lucas_dns_failure_is_dns_for_its_host() {
    let o = classify("Can't reach the API server (ENOTFOUND api.anthropic.com)").unwrap();
    assert_eq!(o, Outage { cause: "dns", host: Some("api.anthropic.com".into()) });
}

#[test]
fn connection_failures_name_their_kind() {
    let kind = |t: &str| classify(t).map(|o| o.cause);
    assert_eq!(kind("connect ECONNREFUSED 127.0.0.1:8080"), Some("refused"));
    assert_eq!(kind("request timed out"), Some("timeout"));
    assert_eq!(kind("getaddrinfo EAI_AGAIN api.openai.com"), Some("dns"));
    assert_eq!(kind("connect EHOSTUNREACH"), Some("unreachable"));
}

#[test]
fn a_provider_answer_is_no_outage() {
    assert_eq!(classify("503 server_error"), None);
    assert_eq!(classify("overloaded_error"), None);
    assert_eq!(classify("authentication_failed"), None);
    assert_eq!(classify("unknown"), None);
}

#[test]
fn the_host_comes_from_a_url_or_the_known_list() {
    let url = classify("fetch failed: ETIMEDOUT (https://gw.example.dev:443/v1/messages)");
    assert_eq!(url.unwrap().host.as_deref(), Some("gw.example.dev"));
    let known = classify("Unable to connect to API; is api.anthropic.com up?").unwrap();
    assert_eq!(known.host.as_deref(), Some("api.anthropic.com"));
    assert_eq!(classify("connect ECONNREFUSED").unwrap().host, None);
    let port = classify("connect ECONNREFUSED api.openai.com:443").unwrap();
    assert_eq!(port.host.as_deref(), Some("api.openai.com"));
}

#[test]
fn a_retry_lines_nested_strings_are_read() {
    let line = json!({"attempt": 2, "error": "unknown",
        "cause": {"code": "ENOTFOUND", "message": "getaddrinfo ENOTFOUND api.anthropic.com"}});
    assert_eq!(classify(&strings_of(&line)).unwrap().cause, "dns");
}

#[test]
fn the_deadline_is_now_plus_the_announced_delay() {
    assert_eq!(retry_at(1_000, Some(75_000)), Some(76_000));
    assert_eq!(retry_at(1_000, None), None);
    assert_eq!(retry_at(u64::MAX, Some(5)), Some(u64::MAX));
}
