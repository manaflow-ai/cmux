use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};

use super::*;

const NOW: u64 = 1_800_000_000;

fn now() -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(NOW)
}

fn token(claims: serde_json::Value) -> String {
    format!("h.{}.s", URL_SAFE_NO_PAD.encode(claims.to_string()))
}

const LEAD: Duration = Duration::from_secs(60);

#[test]
fn expiry_reads_exp() {
    assert!(is_token_expired(None, now()));
    assert!(is_token_expired(Some("not-a-jwt"), now()));
    assert!(is_token_expired(Some(&token(serde_json::json!({ "exp": NOW }))), now()));
    assert!(!is_token_expired(Some(&token(serde_json::json!({ "exp": NOW + 1 }))), now()));
    // No exp: never expires.
    assert!(!is_token_expired(Some(&token(serde_json::json!({}))), now()));
}

#[test]
fn a_token_is_fresh_until_the_lead() {
    let long =
        |left: u64| token(serde_json::json!({ "exp": NOW + left, "iat": NOW + left - 3600 }));
    assert!(is_token_fresh_enough(Some(&long(61)), LEAD, now()));
    assert!(!is_token_fresh_enough(Some(&long(60)), LEAD, now()));
    assert!(!is_token_fresh_enough(None, LEAD, now()));
    assert!(!is_token_fresh_enough(Some("x.y"), LEAD, now()));
}

#[test]
fn a_short_lived_token_gets_half_its_life_but_at_least_twenty_seconds() {
    // 60 s life: the lead is 30 s, not 60.
    let short = token(serde_json::json!({ "exp": NOW + 31, "iat": NOW - 29 }));
    assert!(is_token_fresh_enough(Some(&short), LEAD, now()));
    // 20 s life: half is 10 s, floored to 20.
    let tiny = token(serde_json::json!({ "exp": NOW + 19, "iat": NOW - 1 }));
    assert!(!is_token_fresh_enough(Some(&tiny), LEAD, now()));
}

#[test]
fn an_old_token_with_time_left_is_still_fresh() {
    // Issued an hour ago (the upstream SDK's 75 s staleness rule would refresh it).
    let old = token(serde_json::json!({ "exp": NOW + 600, "iat": NOW - 3600 }));
    assert!(is_token_fresh_enough(Some(&old), LEAD, now()));
}

#[test]
fn a_padded_or_plain_base64_payload_reads_too() {
    let claims = serde_json::json!({ "exp": NOW + 600, "iat": NOW, "sub": "??>>" }).to_string();
    let padded = format!("h.{}.s", STANDARD.encode(&claims));
    assert!(is_token_fresh_enough(Some(&padded), LEAD, now()));
}
