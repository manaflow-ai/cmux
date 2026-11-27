use std::time::{Duration, UNIX_EPOCH};

use super::*;

#[test]
fn an_endpoint_keeps_route_words_only() {
    assert_eq!(redacted_endpoint("/api/v1/users/me"), "/api/v1/users/me");
    assert_eq!(
        redacted_endpoint("/api/v1/teams/3f2a-11/invitations"),
        "/api/v1/teams/ID/invitations"
    );
    assert_eq!(redacted_endpoint("/api/v1/auth/otp/sign-in?code=123"), "/api/v1/auth/otp/sign-in");
    assert_eq!(redacted_endpoint("/a/person@example.com/B"), "/a/ID/ID");
    assert_eq!(redacted_endpoint("/v12/v1234"), "/v12/ID");
    assert_eq!(redacted_endpoint(""), "/");
    assert_eq!(redacted_endpoint(&format!("/{}", "a".repeat(25))), "/ID");
    assert_eq!(redacted_endpoint(&"/users".repeat(50)).chars().count(), 200);
}

#[test]
fn retry_after_reads_seconds_and_dates() {
    let now = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
    assert_eq!(retry_after_seconds(Some("120"), now), Some(120.0));
    assert_eq!(retry_after_seconds(Some(" 1.5 "), now), Some(1.5));
    assert_eq!(retry_after_seconds(Some("999999"), now), Some(86_400.0));
    assert_eq!(retry_after_seconds(Some("-1"), now), None);
    assert_eq!(retry_after_seconds(Some("soon"), now), None);
    assert_eq!(retry_after_seconds(Some(""), now), None);
    assert_eq!(retry_after_seconds(None, now), None);
    let date = httpdate::fmt_http_date(now + Duration::from_secs(30));
    assert_eq!(retry_after_seconds(Some(&date), now), Some(30.0));
    let past = httpdate::fmt_http_date(now - Duration::from_secs(30));
    assert_eq!(retry_after_seconds(Some(&past), now), Some(0.0));
}

#[test]
fn form_values_keep_only_unreserved_characters() {
    assert_eq!(form_encode("a-Z_0.9~"), "a-Z_0.9~");
    assert_eq!(form_encode("a b&c=d+e/f"), "a%20b%26c%3Dd%2Be%2Ff");
    assert_eq!(form_encode("é"), "%C3%A9");
    assert_eq!(form(&[("a", "1 2"), ("b", "x")]), "a=1%202&b=x");
}

#[test]
fn a_body_kind_reads_the_type_then_the_first_byte() {
    assert_eq!(BodyKind::classify(Some("application/json; charset=utf-8"), b"<"), BodyKind::Json);
    assert_eq!(BodyKind::classify(Some("text/HTML"), b"{"), BodyKind::Html);
    assert_eq!(BodyKind::classify(None, b"  \n<html>"), BodyKind::Html);
    assert_eq!(BodyKind::classify(Some("text/plain"), b" [1]"), BodyKind::Json);
    assert_eq!(BodyKind::classify(None, b"slow down"), BodyKind::Other);
    assert_eq!(BodyKind::classify(None, b""), BodyKind::Other);
}

#[test]
fn a_session_debug_line_has_no_token() {
    let line = format!("{:?}", Session::new(Some("tok-a"), Some("tok-r")));
    assert!(!line.contains("tok-"), "{line}");
    assert!(line.contains("<redacted>"));
}
