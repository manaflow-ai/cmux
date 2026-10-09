//! The pure origin rules: derivation, narrowing, gate A2, canonical params
//! hash and confirmation tokens (no connection needed).

use serde_json::{Value, json};

use super::*;

fn connection(role: HelloRole, verified_app: bool) -> ConnectionOrigin {
    ConnectionOrigin { role, verified_app, ..ConnectionOrigin::default() }
}

fn claim(origin: RequestOrigin, confirmation: Option<&str>) -> OriginClaim {
    OriginClaim { claim: origin, confirmation: confirmation.map(str::to_string) }
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

/// What a request's result says: the origin it got, or the refusal details.
fn outcome(result: Result<RequestOrigin, ResourceError>) -> Value {
    result.map_or_else(|error| error.details, |origin| json!({"origin": origin.wire_name()}))
}

/// The page access refusal (page_access.rs): the claim was accepted and
/// the request got origin page, which no catalog operation allows.
fn page_denied() -> Value {
    json!({"required": "agent", "derived": "page"})
}

#[test]
fn claims_only_narrow_off_a_page_relay() {
    let params = json!({});
    let ping = ResourceOperation::SessionPing;
    let widen = |derived: &str, claim: &str| json!({"derived": derived, "claim": claim});
    for (verified, origin, expected) in [
        (false, RequestOrigin::Page, page_denied()),
        (false, RequestOrigin::Agent, json!({"origin": "agent"})),
        (false, RequestOrigin::App, widen("agent", "app")),
        (false, RequestOrigin::User, widen("agent", "user")),
        (true, RequestOrigin::App, json!({"origin": "app"})),
        (true, RequestOrigin::User, json!({"origin": "user"})),
    ] {
        let mut conn = connection(HelloRole::Main, verified);
        let claim = claim(origin, None);
        assert_eq!(outcome(conn.request_origin(ping, &params, Some(&claim), 0)), expected);
    }
    let mut user = connection(HelloRole::Main, true);
    // A confirmation means nothing off a page relay.
    let confirmed = claim(RequestOrigin::Page, Some("t"));
    assert_eq!(
        outcome(user.request_origin(ping, &params, Some(&confirmed), 0)),
        widen("user", "page")
    );
}

#[test]
fn issuing_a_confirmation_needs_user_after_narrowing() {
    let issue = ResourceOperation::OriginConfirmationIssue;
    let params = json!({});
    let mut app = connection(HelloRole::Main, true);
    assert_eq!(outcome(app.request_origin(issue, &params, None, 0)), json!({"origin": "user"}));
    for narrowed in [RequestOrigin::App, RequestOrigin::Agent] {
        let claim = claim(narrowed, None);
        assert_eq!(
            outcome(app.request_origin(issue, &params, Some(&claim), 0)),
            json!({"required": "user", "derived": narrowed.wire_name()})
        );
    }
    let mut plain = connection(HelloRole::Main, false);
    assert_eq!(
        outcome(plain.request_origin(issue, &params, None, 0)),
        json!({"required": "user", "derived": "agent"})
    );
}

#[test]
fn a_confirmation_is_single_use_bound_and_expires() {
    let ping = ResourceOperation::SessionPing;
    let params = json!({"machine": "current", "session": "current"});
    let sha = params_sha256(&params);
    let mut relay = connection(HelloRole::PageRelay, false);
    let token = mint_token().unwrap();
    let invalid = json!({"derived": "page", "claim": "user", "reason": "confirmation_invalid"});
    relay.store_confirmation(token.clone(), ping, sha.clone(), 1_000, 0);
    let user = claim(RequestOrigin::User, Some(&token));
    // Other params: refused, and the token is spent.
    let other = json!({"machine": "current", "session": "other"});
    assert_eq!(outcome(relay.request_origin(ping, &other, Some(&user), 10)), invalid);
    assert_eq!(outcome(relay.request_origin(ping, &params, Some(&user), 10)), invalid);
    // A fresh token: other operation refused.
    relay.store_confirmation(token.clone(), ping, sha.clone(), 1_000, 0);
    let get = ResourceOperation::SessionGet;
    assert_eq!(outcome(relay.request_origin(get, &params, Some(&user), 10)), invalid);
    // Expired at its deadline.
    relay.store_confirmation(token.clone(), ping, sha.clone(), 1_000, 0);
    assert_eq!(outcome(relay.request_origin(ping, &params, Some(&user), 1_000)), invalid);
    // Live and exact: the claim is accepted once. On a page relay the page
    // rule still refuses every catalog operation (the result reaches JS).
    relay.store_confirmation(token, ping, sha, 1_000, 0);
    assert_eq!(outcome(relay.request_origin(ping, &params, Some(&user), 999)), page_denied());
    assert_eq!(outcome(relay.request_origin(ping, &params, Some(&user), 999)), invalid);
}

#[test]
fn a_relay_holds_a_bounded_number_of_tokens_and_drops_expired_ones() {
    let mut relay = connection(HelloRole::PageRelay, false);
    for index in 0..40_u64 {
        relay.store_confirmation(
            format!("t{index}"),
            ResourceOperation::SessionPing,
            "s".into(),
            100 + index,
            0,
        );
    }
    assert_eq!(relay.confirmations.len(), MAX_CONFIRMATIONS_PER_RELAY);
    assert_eq!(relay.confirmations[0].token, "t24");
    relay.store_confirmation("late".into(), ResourceOperation::SessionPing, "s".into(), 1_000, 200);
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
