use super::rate_wait;
use reqwest::header::HeaderValue;
use std::time::Duration;

#[test]
fn a_429_waits_what_the_server_names_within_bounds() {
    assert_eq!(rate_wait(Some(&HeaderValue::from_static("7"))), Duration::from_secs(7));
    assert_eq!(rate_wait(Some(&HeaderValue::from_static("0"))), Duration::from_secs(1));
    assert_eq!(rate_wait(Some(&HeaderValue::from_static("9999"))), Duration::from_secs(120));
    assert_eq!(rate_wait(Some(&HeaderValue::from_static("soon"))), Duration::from_secs(30));
    assert_eq!(rate_wait(None), Duration::from_secs(30));
}
