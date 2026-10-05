//! The pure origin rules: derivation, narrowing, gate A2, canonical params
//! hash and confirmation tokens (no connection needed).

use serde_json::json;

use super::*;

fn connection(role: HelloRole, verified_app: bool) -> ConnectionOrigin {
    ConnectionOrigin { role, verified_app, ..ConnectionOrigin::default() }
}

fn claim(origin: RequestOrigin, confirmation: Option<&str>) -> OriginClaim {
    OriginClaim { claim: origin, confirmation: confirmation.map(str::to_string) }
}

fn code(result: Result<RequestOrigin, ResourceError>) -> Result<RequestOrigin, String> {
    result.map_err(|error| error.code)
}

#[test]
fn derivation_follows_the_hello_role_and_verification() {
    assert_eq!(connection(HelloRole::Legacy, false).derive(), RequestOrigin::Agent);
    // verified_app without role main is never user (P8 sets it with role main).
    assert_eq!(connection(HelloRole::Legacy, true).derive(), RequestOrigin::Agent);
    assert_eq!(connection(HelloRole::Main, false).derive(), RequestOrigin::Agent);
    assert_eq!(connection(HelloRole::Main, true).derive(), RequestOrigin::User);
    assert_eq!(connection(HelloRole::PageRelay, true).derive(), RequestOrigin::Page);
}

#[test]
fn claims_only_narrow_off_a_page_relay() {
    let params = json!({});
    // apps.list is not a catalog operation, so page_access.rs (every catalog
    // operation is refused for a page) does not hide the claim result.
    let forbidden = || Err("origin.forbidden".to_string());
    for (verified, origin, expected) in [
        (false, RequestOrigin::Page, Ok(RequestOrigin::Page)),
        (false, RequestOrigin::Agent, Ok(RequestOrigin::Agent)),
        (false, RequestOrigin::App, forbidden()),
        (false, RequestOrigin::User, forbidden()),
        (true, RequestOrigin::App, Ok(RequestOrigin::App)),
        (true, RequestOrigin::User, Ok(RequestOrigin::User)),
    ] {
        let mut conn = connection(HelloRole::Main, verified);
        let claim = claim(origin, None);
        assert_eq!(code(conn.request_origin("apps.list", &params, Some(&claim), 0)), expected);
    }
    let mut user = connection(HelloRole::Main, true);
    // A confirmation means nothing off a page relay.
    let confirmed = claim(RequestOrigin::Page, Some("t"));
    assert_eq!(
        code(user.request_origin("apps.list", &params, Some(&confirmed), 0)),
        Err("origin.forbidden".to_string())
    );
}

#[test]
fn gate_a2_needs_user_and_app_origin_is_refused() {
    for operation in USER_ONLY_OPERATIONS {
        for origin in [RequestOrigin::Page, RequestOrigin::Agent, RequestOrigin::App] {
            let error = require_origin(operation, origin).unwrap_err();
            assert_eq!(error.code, "origin.forbidden");
            assert_eq!(error.message, NEEDS_VERIFIED_APP);
            assert_eq!(error.details, json!({"required": "user", "derived": origin.wire_name()}));
        }
        assert!(require_origin(operation, RequestOrigin::User).is_ok());
    }
    assert!(require_origin("apps.list", RequestOrigin::Page).is_ok());
}

#[test]
fn canonical_json_sorts_keys_at_every_depth_without_whitespace() {
    let value = json!({"b": [1, {"z": null, "a": "é/\""}], "a": {"y": true, "x": 1.5}});
    let mut out = String::new();
    write_canonical_json(&value, &mut out);
    assert_eq!(out, r#"{"a":{"x":1.5,"y":true},"b":[1,{"a":"é/\"","z":null}]}"#);
    let expected: String =
        Sha256::digest(out.as_bytes()).iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(params_sha256(&value), expected);
    assert!(valid_sha256_hex(&expected));
    assert!(!valid_sha256_hex(&expected.to_uppercase()));
    assert!(!valid_sha256_hex(&expected[1..]));
}

#[test]
fn a_confirmation_is_single_use_bound_and_expires() {
    let params = json!({"app": "cmux/demo"});
    let sha = params_sha256(&params);
    let mut relay = connection(HelloRole::PageRelay, false);
    let token = mint_token().unwrap();
    relay.store_confirmation(token.clone(), "apps.install".into(), sha.clone(), 1_000, 0);
    let user = claim(RequestOrigin::User, Some(&token));
    // Other params: refused, and the token is spent.
    let other = json!({"app": "cmux/other"});
    assert!(relay.request_origin("apps.install", &other, Some(&user), 10).is_err());
    assert!(relay.request_origin("apps.install", &params, Some(&user), 10).is_err());
    // A fresh token: other operation refused.
    relay.store_confirmation(token.clone(), "apps.install".into(), sha.clone(), 1_000, 0);
    assert!(relay.request_origin("apps.uninstall", &params, Some(&user), 10).is_err());
    // Expired at its deadline.
    relay.store_confirmation(token.clone(), "apps.install".into(), sha.clone(), 1_000, 0);
    assert!(relay.request_origin("apps.install", &params, Some(&user), 1_000).is_err());
    // Live, exact: user, once.
    relay.store_confirmation(token, "apps.install".into(), sha, 1_000, 0);
    assert_eq!(
        code(relay.request_origin("apps.install", &params, Some(&user), 999)),
        Ok(RequestOrigin::User)
    );
    assert!(relay.request_origin("apps.install", &params, Some(&user), 999).is_err());
}

#[test]
fn a_relay_holds_a_bounded_number_of_tokens_and_drops_expired_ones() {
    let mut relay = connection(HelloRole::PageRelay, false);
    for index in 0..40_u64 {
        relay.store_confirmation(format!("t{index}"), "op".into(), "s".into(), 100 + index, 0);
    }
    assert_eq!(relay.confirmations.len(), MAX_CONFIRMATIONS_PER_RELAY);
    assert_eq!(relay.confirmations[0].token, "t24");
    relay.store_confirmation("late".into(), "op".into(), "s".into(), 1_000, 200);
    assert_eq!(relay.confirmations.len(), 1);
}

#[test]
fn tokens_are_32_random_bytes_base64url() {
    let first = mint_token().unwrap();
    let second = mint_token().unwrap();
    assert_eq!(first.len(), 43);
    assert_ne!(first, second);
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(&first).unwrap();
    assert_eq!(bytes.len(), 32);
}

#[test]
fn install_ids_and_roles_have_one_shape() {
    assert!(valid_install_id("a"));
    assert!(valid_install_id(&"A-_9".repeat(32)));
    let long = "a".repeat(129);
    for bad in ["", "a b", "a/b", "é", long.as_str()] {
        assert!(!valid_install_id(bad), "{bad}");
    }
    assert_eq!(HelloRole::declared("main"), Some(HelloRole::Main));
    assert_eq!(HelloRole::declared("page_relay"), Some(HelloRole::PageRelay));
    assert_eq!(HelloRole::declared("legacy"), None);
    assert_eq!(HelloRole::declared("user"), None);
}

#[test]
fn the_token_clock_is_monotonic_and_the_wall_reading_is_separate() {
    let clock = OriginClock::default();
    clock.advance(0);
    let (monotonic, wall) = (clock.monotonic_ms(), clock.wall_ms());
    clock.jump_wall(-7_200_000);
    assert_eq!(clock.monotonic_ms(), monotonic);
    assert_eq!(clock.wall_ms(), wall.saturating_sub(7_200_000));
    clock.advance(CONFIRMATION_TTL_MS);
    assert_eq!(clock.monotonic_ms(), monotonic + CONFIRMATION_TTL_MS);
    assert_eq!(clock.wall_ms(), wall.saturating_sub(7_200_000) + CONFIRMATION_TTL_MS);
}
