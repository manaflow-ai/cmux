//! Pins the Swift `InstallAuthClient`'s exchange (CmuxInstallAuthCore's InstallAuthClientTests
//! and InstallTeamTokenTests) as it moved: each request, each check and each recovery.

use super::*;

const NOW: f64 = 1_800_000_000_000.0;
const TEAM: &str = "team_0123456789abcdef0123";
const NONCE: &str = "nonce-0123456789abcdef";

fn x963() -> String {
    let mut point = vec![0x04];
    point.extend(1..=64u8);
    STANDARD.encode(point)
}

fn jwt(claims: &Value) -> String {
    format!("h.{}.s", URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap()))
}

fn start(record: Option<Record>, team: Option<&str>, mode: Mode) -> Event {
    Event::Start(Start {
        mode,
        stack_user: "stack-1".into(),
        team: team.map(str::to_owned),
        environment: None,
        device_name: "Leo's Mac".into(),
        profile: Profile::mac(),
        client_version: Some("1.2.3".into()),
        record,
        has_session: true,
        fresh_ids: vec!["id-a".into(), "id-b".into()],
    })
}

fn record() -> Record {
    Record { user: "user_1".into(), install: "inst_1".into() }
}

fn http(status: u16, body: &Value) -> Event {
    Event::Http { status, body: body.to_string() }
}

fn ok(value: &Value) -> Event {
    http(200, &json!({ "ok": true, "value": value }))
}

struct Run {
    state: Option<State>,
}

impl Run {
    fn go(&mut self, event: Event) -> Effect {
        let (state, effect) = step(self.state.take(), event, NOW);
        self.state = state;
        effect
    }
}

fn post(effect: &Effect) -> (String, Value, Option<String>) {
    let Effect::Post { path, body, bearer, headers } = effect else {
        panic!("expected a post, got {effect:?}");
    };
    assert_eq!(headers.get(CLIENT_VERSION_HEADER).map(String::as_str), Some("1.2.3"));
    (path.clone(), serde_json::from_str(body).unwrap(), bearer.clone())
}

fn challenge_reply(prefix_env: &str, install: &str, team: Option<&str>) -> Event {
    let prefix = match team {
        None => format!("cmux-auth-v1\n{prefix_env}\n{install}\n"),
        Some(team) => format!("cmux-auth-team-v1\n{prefix_env}\n{install}\n{team}\n"),
    };
    http(200, &json!({ "nonce": NONCE, "message_prefix": prefix }))
}

/// Challenge, sign, token, from a record.
fn finish_mint(run: &mut Run, install: &str, token_reply: &Value) -> Effect {
    let sign = run.go(challenge_reply("production", install, None));
    assert_eq!(
        sign,
        Effect::Sign { message: format!("cmux-auth-v1\nproduction\n{install}\n{NONCE}") }
    );
    let (path, body, bearer) =
        post(&run.go(Event::Signature { signature: STANDARD.encode([0xfb, 0xff]) }));
    assert_eq!(path, "/v1/auth/token");
    assert_eq!(bearer, None);
    assert_eq!(body["signature"], "-_8");
    assert_eq!(body["nonce"], NONCE);
    run.go(http(200, token_reply))
}

#[test]
fn a_registered_install_mints_from_a_fresh_challenge() {
    let mut run = Run { state: None };
    let (path, body, bearer) = post(&run.go(start(Some(record()), None, Mode::Mint)));
    assert_eq!(path, "/v1/auth/challenge");
    assert_eq!(body, json!({ "user": "user_1", "install": "inst_1" }));
    assert_eq!(bearer, None);
    let token = jwt(&json!({ "iss": "https://cmux-api/production" }));
    let done = finish_mint(
        &mut run,
        "inst_1",
        &json!({ "access_token": token, "expires_at": NOW + 300_000.0 }),
    );
    assert_eq!(
        done,
        Effect::Done { token, environment: "production".into(), expires_at_ms: NOW + 300_000.0 }
    );
}

#[test]
fn a_token_is_never_trusted_past_nine_minutes() {
    let mut run = Run { state: None };
    run.go(start(Some(record()), None, Mode::Mint));
    let token = jwt(&json!({ "iss": "https://cmux-api/production" }));
    let done =
        finish_mint(&mut run, "inst_1", &json!({ "access_token": token, "expires_at": NOW * 2.0 }));
    assert!(
        matches!(done, Effect::Done { expires_at_ms, .. } if expires_at_ms == NOW + MAXIMUM_LIFETIME_MS)
    );
    let mut run = Run { state: None };
    run.go(start(Some(record()), None, Mode::Mint));
    let done = finish_mint(&mut run, "inst_1", &json!({ "access_token": token }));
    assert!(
        matches!(done, Effect::Done { expires_at_ms, .. } if expires_at_ms == NOW + MAXIMUM_LIFETIME_MS)
    );
}

#[test]
fn a_new_install_ensures_the_user_and_registers_its_key() {
    let mut run = Run { state: None };
    assert_eq!(run.go(start(None, None, Mode::Mint)), Effect::SessionToken);
    let (path, body, bearer) = post(&run.go(Event::Session { token: "stack-session".into() }));
    assert_eq!(path, "/v1/ops");
    assert_eq!(bearer.as_deref(), Some("stack-session"));
    assert_eq!(
        body,
        json!({ "op": "user.ensure", "params": {}, "idempotency_key": "user-ensure-id-a", "origin": "cli" })
    );
    assert_eq!(
        run.go(ok(&json!({ "id": "user_1", "stack_user_id": "stack-1" }))),
        Effect::PublicKey
    );
    let (_, body, _) = post(&run.go(Event::PublicKey { x963: x963() }));
    assert_eq!(body["op"], "install.register");
    let thumbprint = hex(&Sha256::digest(STANDARD.decode(x963()).unwrap())[..16]);
    assert_eq!(body["idempotency_key"], format!("install-register-user_1-{thumbprint}"));
    assert_eq!(
        body["params"],
        json!({
            "public_jwk": public_jwk(&STANDARD.decode(x963()).unwrap()).unwrap(),
            "kind": "mac", "name": "cmux", "device_name": "Leo's Mac", "platform": "macos",
            "op_classes": ["read", "mutate-own", "mutate-shared", "cloud-link"],
        })
    );
    assert_eq!(
        run.go(ok(&json!({ "id": "inst_1" }))),
        Effect::SaveRecord { record: Some(record()) }
    );
    let (path, _, _) = post(&run.go(Event::Saved));
    assert_eq!(path, "/v1/auth/challenge");
}

#[test]
fn a_session_for_another_user_is_refused() {
    let mut run = Run { state: None };
    run.go(start(None, None, Mode::Mint));
    run.go(Event::Session { token: "s".into() });
    assert_eq!(
        run.go(ok(&json!({ "id": "user_1", "stack_user_id": "other" }))),
        Effect::Fail(Error::UserMismatch)
    );
}

#[test]
fn no_session_and_no_record_cannot_register() {
    let Event::Start(mut facts) = start(None, None, Mode::Mint) else { unreachable!() };
    facts.has_session = false;
    assert_eq!(step(None, Event::Start(facts), NOW).1, Effect::Fail(Error::NoSession));
}

#[test]
fn a_key_already_registered_rotates_once() {
    let mut run = Run { state: None };
    run.go(start(None, None, Mode::Mint));
    run.go(Event::Session { token: "s".into() });
    run.go(ok(&json!({ "id": "user_1", "stack_user_id": "stack-1" })));
    run.go(Event::PublicKey { x963: x963() });
    let held = http(
        200,
        &json!({ "ok": false, "error": { "code": "conflict", "message": "key already registered" } }),
    );
    assert_eq!(run.go(held.clone()), Effect::Rotate);
    assert_eq!(run.go(Event::Rotated), Effect::PublicKey);
    run.go(Event::PublicKey { x963: x963() });
    assert_eq!(run.go(held), Effect::Fail(Error::refused("key.already_registered")));
}

#[test]
fn a_revoked_personal_install_rotates_forgets_and_mints_again_once() {
    let mut run = Run { state: None };
    run.go(start(Some(record()), None, Mode::Mint));
    let forbidden = http(403, &json!({ "code": "auth.forbidden" }));
    assert_eq!(run.go(forbidden.clone()), Effect::Rotate);
    assert_eq!(run.go(Event::Rotated), Effect::SaveRecord { record: None });
    assert_eq!(run.go(Event::Saved), Effect::SessionToken);
    let (_, body, _) = post(&run.go(Event::Session { token: "s".into() }));
    // A second register takes the second fresh id.
    assert_eq!(body["idempotency_key"], "user-ensure-id-b");
    run.go(ok(&json!({ "id": "user_1", "stack_user_id": "stack-1" })));
    run.go(Event::PublicKey { x963: x963() });
    run.go(ok(&json!({ "id": "inst_2" })));
    run.go(Event::Saved);
    assert_eq!(run.go(forbidden), Effect::Fail(Error::refused("auth.forbidden")));
}

#[test]
fn a_team_refusal_keeps_the_key_and_record() {
    let mut run = Run { state: None };
    run.go(start(Some(record()), Some(TEAM), Mode::Mint));
    assert_eq!(
        run.go(http(403, &json!({ "code": "auth.forbidden" }))),
        Effect::Fail(Error::refused("auth.forbidden"))
    );
}

#[test]
fn a_team_mint_signs_the_team_challenge_and_checks_every_claim() {
    let claims = json!({
        "iss": "https://cmux-api/production", "team": TEAM, "sub": "user_1", "inst": "inst_1",
        "grant": "g1", "aud": "api",
    });
    let answer = |claims: &Value| json!({ "access_token": jwt(claims), "team": TEAM, "user": "user_1", "install": "inst_1", "grant": "g1" });
    let mint = |answer: &Value| {
        let mut run = Run { state: None };
        let (_, body, _) = post(&run.go(start(Some(record()), Some(TEAM), Mode::Mint)));
        assert_eq!(body["team"], TEAM);
        let sign = run.go(challenge_reply("production", "inst_1", Some(TEAM)));
        assert!(matches!(sign, Effect::Sign { .. }));
        run.go(Event::Signature { signature: STANDARD.encode([1]) });
        run.go(http(200, answer))
    };
    assert!(matches!(mint(&answer(&claims)), Effect::Done { .. }));
    for (name, value) in [
        ("team", json!("team_ffffffffffffffffffff")),
        ("sub", json!("user_2")),
        ("inst", json!("inst_2")),
        ("grant", json!("g2")),
        ("aud", json!("web")),
        ("agt", json!("a")),
        ("vm", Value::Null),
        ("tvm", json!("t")),
    ] {
        let mut bad = claims.clone();
        bad[name] = value;
        assert_eq!(mint(&answer(&bad)), Effect::Fail(Error::UnexpectedChallenge), "claim {name}");
    }
    let mut no_grant = answer(&claims);
    no_grant["grant"] = json!("");
    assert_eq!(mint(&no_grant), Effect::Fail(Error::UnexpectedChallenge));
}

#[test]
fn a_malformed_team_is_refused_before_any_request() {
    assert_eq!(
        step(None, start(Some(record()), Some("team_xyz"), Mode::Mint), NOW).1,
        Effect::Fail(Error::UnexpectedChallenge)
    );
}

#[test]
fn only_the_expected_challenge_is_signed() {
    let refused = |reply: Event| {
        let mut run = Run { state: None };
        run.go(start(Some(record()), None, Mode::Mint));
        run.go(reply)
    };
    let fail = Effect::Fail(Error::UnexpectedChallenge);
    assert_eq!(refused(challenge_reply("production", "inst_2", None)), fail);
    assert_eq!(refused(challenge_reply("Production", "inst_1", None)), fail);
    assert_eq!(refused(challenge_reply("1prod", "inst_1", None)), fail);
    assert_eq!(refused(challenge_reply(&"a".repeat(33), "inst_1", None)), fail);
    assert_eq!(refused(challenge_reply("", "inst_1", None)), fail);
    assert_eq!(refused(challenge_reply("production", "inst_1", Some(TEAM))), fail);
    assert_eq!(
        refused(http(
            200,
            &json!({ "nonce": "short", "message_prefix": "cmux-auth-v1\nproduction\ninst_1\n" })
        )),
        fail
    );
    assert_eq!(refused(http(200, &json!({ "nonce": NONCE }))), fail);
    assert!(matches!(
        refused(challenge_reply(&"a".repeat(32), "inst_1", None)),
        Effect::Sign { .. }
    ));
}

#[test]
fn a_learned_environment_never_changes() {
    let Event::Start(mut facts) = start(Some(record()), None, Mode::Mint) else { unreachable!() };
    facts.environment = Some("staging".into());
    let mut run = Run { state: None };
    run.go(Event::Start(facts));
    assert_eq!(
        run.go(challenge_reply("production", "inst_1", None)),
        Effect::Fail(Error::UnexpectedChallenge)
    );
}

#[test]
fn a_token_from_another_issuer_is_dropped() {
    let mut run = Run { state: None };
    run.go(start(Some(record()), None, Mode::Mint));
    let token = jwt(&json!({ "iss": "https://cmux-api/staging" }));
    assert_eq!(
        finish_mint(&mut run, "inst_1", &json!({ "access_token": token })),
        Effect::Fail(Error::UnexpectedChallenge)
    );
    let mut run = Run { state: None };
    run.go(start(Some(record()), None, Mode::Mint));
    assert_eq!(finish_mint(&mut run, "inst_1", &json!({})), Effect::Fail(Error::MalformedReply));
}

#[test]
fn http_answers_are_classified_as_the_swift_did() {
    let first = |reply: Event| {
        let mut run = Run { state: None };
        run.go(start(Some(record()), Some(TEAM), Mode::Mint));
        run.go(reply)
    };
    assert_eq!(
        first(Event::Http { status: 200, body: "not json".into() }),
        Effect::Fail(Error::MalformedReply)
    );
    assert_eq!(
        first(Event::Http { status: 502, body: "<html>".into() }),
        Effect::Fail(Error::refused("http_502"))
    );
    assert_eq!(first(http(500, &json!({}))), Effect::Fail(Error::refused("http_500")));
    assert_eq!(
        first(http(426, &json!({ "code": "client.too_old", "minimum_version": "2.0" }))),
        Effect::Fail(Error::ClientTooOld { minimum_version: Some("2.0".into()) })
    );
    assert_eq!(
        first(Event::TransportError { url_error_code: Some(-1001) }),
        Effect::Fail(Error::Transport {
            path: "/v1/auth/challenge".into(),
            url_error_code: Some(-1001)
        })
    );
}

#[test]
fn an_op_refusal_names_its_code() {
    let mut run = Run { state: None };
    run.go(start(None, None, Mode::Mint));
    run.go(Event::Session { token: "s".into() });
    assert_eq!(
        run.go(http(200, &json!({ "ok": false, "error": { "code": "rate.limited" } }))),
        Effect::Fail(Error::refused("rate.limited"))
    );
    let mut run = Run { state: None };
    run.go(start(None, None, Mode::Mint));
    run.go(Event::Session { token: "s".into() });
    assert_eq!(run.go(http(200, &json!({ "ok": false }))), Effect::Fail(Error::refused("unknown")));
    let mut run = Run { state: None };
    run.go(start(None, None, Mode::Mint));
    run.go(Event::Session { token: "s".into() });
    assert_eq!(run.go(http(200, &json!({ "ok": true }))), Effect::Fail(Error::MalformedReply));
}

#[test]
fn revoke_asks_the_owner_then_the_app_forgets() {
    assert_eq!(
        step(None, start(None, None, Mode::Revoke), NOW).1,
        Effect::Revoked { revoked: false }
    );
    let mut run = Run { state: None };
    assert_eq!(run.go(start(Some(record()), None, Mode::Revoke)), Effect::SessionToken);
    let (path, body, bearer) = post(&run.go(Event::Session { token: "s".into() }));
    assert_eq!((path.as_str(), bearer.as_deref()), ("/v1/ops", Some("s")));
    assert_eq!(
        body,
        json!({ "op": "install.revoke", "params": { "install": "inst_1" },
                "idempotency_key": "install-revoke-inst_1", "origin": "cli" })
    );
    assert_eq!(run.go(ok(&json!({}))), Effect::Revoked { revoked: true });
    // A revoke refused auth.forbidden is not a mint: no recovery.
    let mut run = Run { state: None };
    run.go(start(Some(record()), None, Mode::Revoke));
    run.go(Event::Session { token: "s".into() });
    assert_eq!(
        run.go(http(403, &json!({ "code": "auth.forbidden" }))),
        Effect::Fail(Error::refused("auth.forbidden"))
    );
}

#[test]
fn an_unexpected_event_fails_closed() {
    let mut run = Run { state: None };
    run.go(start(Some(record()), None, Mode::Mint));
    assert_eq!(run.go(Event::Rotated), Effect::Fail(Error::MalformedReply));
    assert_eq!(step(None, Event::Saved, NOW).1, Effect::Fail(Error::MalformedReply));
}

#[test]
fn an_invalid_public_key_is_refused() {
    let mut run = Run { state: None };
    run.go(start(None, None, Mode::Mint));
    run.go(Event::Session { token: "s".into() });
    run.go(ok(&json!({ "id": "user_1", "stack_user_id": "stack-1" })));
    assert_eq!(
        run.go(Event::PublicKey { x963: STANDARD.encode([4u8; 64]) }),
        Effect::Fail(Error::InvalidPublicKey)
    );
}

#[test]
fn public_jwk_checks_point_shape_and_preserves_both_coordinates() {
    for len in 0..=130 {
        if len != 65 {
            assert_eq!(public_jwk(&vec![0x04; len]), Err(Error::InvalidPublicKey));
        }
    }
    for prefix in 0..=255u8 {
        if prefix != 0x04 {
            let mut point = vec![prefix];
            point.extend(1..=64u8);
            assert_eq!(public_jwk(&point), Err(Error::InvalidPublicKey));
        }
    }
    let point = STANDARD.decode(x963()).unwrap();
    assert_eq!(
        public_jwk(&point).unwrap(),
        json!({
            "kty": "EC", "crv": "P-256",
            "x": URL_SAFE_NO_PAD.encode((1..=32u8).collect::<Vec<_>>()),
            "y": URL_SAFE_NO_PAD.encode((33..=64u8).collect::<Vec<_>>()),
        })
    );
}

#[test]
fn display_names_are_cut_to_80_utf16_units_on_a_character() {
    assert_eq!(display_name("", "iPhone"), "iPhone");
    assert_eq!(display_name("Leo's Mac", "Mac"), "Leo's Mac");
    assert_eq!(display_name(&"a".repeat(81), "Mac"), "a".repeat(80));
    // 👍🏽 is one character of four UTF-16 units: it is kept whole or dropped.
    let name = format!("{}👍🏽", "a".repeat(77));
    assert_eq!(display_name(&name, "Mac"), "a".repeat(77));
    let name = format!("{}👍🏽", "a".repeat(76));
    assert_eq!(display_name(&name, "Mac"), name);
}

#[test]
fn headers_carry_a_non_empty_client_version() {
    assert!(headers(None).is_empty());
    assert!(headers(Some("")).is_empty());
    assert_eq!(headers(Some("1.0"))[CLIENT_VERSION_HEADER], "1.0");
}

#[test]
fn the_profiles_never_ask_for_execute() {
    for profile in [Profile::ios(), Profile::mac()] {
        assert!(!profile.op_classes.iter().any(|class| class == "execute"));
    }
    assert_eq!(Profile::ios().fallback_device_name, "iPhone");
}

#[test]
fn state_and_effects_round_trip_through_json() {
    let (state, effect) = step(None, start(Some(record()), None, Mode::Mint), NOW);
    let again: Option<State> =
        serde_json::from_value(serde_json::to_value(&state).unwrap()).unwrap();
    assert_eq!(again, state);
    let back: Effect = serde_json::from_value(serde_json::to_value(&effect).unwrap()).unwrap();
    assert_eq!(back, effect);
    assert_eq!(serde_json::to_value(&effect).unwrap()["effect"], "post");
    let fail = serde_json::to_value(Effect::Fail(Error::refused("x"))).unwrap();
    assert_eq!(fail, json!({ "effect": "fail", "error": "refused", "code": "x" }));
    let event: Event =
        serde_json::from_value(json!({ "event": "http", "status": 200, "body": "{}" })).unwrap();
    assert!(matches!(event, Event::Http { status: 200, .. }));
}
