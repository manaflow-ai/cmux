//! The pre-approval token's rules: what a call sends, when the next is asked for, what an answer keeps.

use super::*;
use serde_json::json;

const T0: u64 = 1_794_304_118_456;
const TOKEN: &str = "cc1.eyJ2IjoxfQ.c2ln-_x";

fn answer(team: &str, issued: u64) -> Value {
    json!({"ok": true, "value": {
        "capability": TOKEN, "team": team, "plan_id": "pro", "cloud": true,
        "issued_at": issued, "expires_at": issued + 300_000, "refresh_at": issued + 240_000,
    }})
}

fn kept(team: &str, sent: u64, now: u64, status: u64, body: Value) -> KeepReply {
    keep(&KeepRequest {
        state: State::default(),
        team: team.into(),
        sent_ms: sent,
        now_ms: now,
        status,
        body,
    })
}

fn used(state: &State, team: Option<&str>, now: u64) -> UseReply {
    use_for(&UseRequest { state: state.clone(), team: team.map(str::to_owned), now_ms: now })
}

/// Signed in with nothing held: the call goes with no token (the full checks) and starts the fetch;
/// a second call meanwhile starts no second fetch.
#[test]
fn the_first_call_fetches_once_and_never_waits() {
    let first = used(&State::default(), Some("team_a"), T0);
    assert_eq!((first.header, first.fetch), (None, true));
    let second = used(&first.state, Some("team_a"), T0 + 5);
    assert_eq!((second.header, second.fetch), (None, false));
    assert!(
        used(&first.state, Some("team_a"), T0 + IN_FLIGHT_MS).fetch,
        "a fetch that never answered is asked again"
    );
}

#[test]
fn a_held_token_goes_on_its_teams_calls_until_its_refresh_then_still_until_expiry() {
    let state = kept("team_a", T0, T0 + 400, 200, answer("team_a", 9_999_999)).state;
    let held = state.held.clone().unwrap();
    assert_eq!(held.refresh_at_ms, T0 + 240_000);
    assert_eq!(held.use_until_ms, T0 + 300_000 - EXPIRY_MARGIN_MS);
    let fresh = used(&state, Some("team_a"), T0 + 1_000);
    assert_eq!((fresh.header.as_deref(), fresh.fetch), (Some(TOKEN), false));
    // Past the refresh: still sent, and this call asks for the next one.
    let due = used(&state, Some("team_a"), T0 + 240_000);
    assert_eq!((due.header.as_deref(), due.fetch), (Some(TOKEN), true));
    // Past its use: never sent.
    let late = used(&state, Some("team_a"), held.use_until_ms);
    assert_eq!(late.header, None);
}

/// The server's clock is read only as a lifetime from the send: a Mac clock hours off keeps the
/// same 5 minutes.
#[test]
fn a_skewed_mac_clock_never_stretches_a_token() {
    for issued in [1, T0 - 3_600_000, T0 + 3_600_000] {
        let held = kept("team_a", T0, T0 + 10, 200, answer("team_a", issued)).state.held.unwrap();
        assert_eq!(held.use_until_ms, T0 + 300_000 - EXPIRY_MARGIN_MS, "{issued}");
    }
}

#[test]
fn another_teams_token_is_never_sent_and_a_switch_fetches() {
    let state = kept("team_a", T0, T0 + 10, 200, answer("team_a", T0)).state;
    let other = used(&state, Some("team_b"), T0 + 20);
    assert_eq!((other.header, other.fetch), (None, true));
    let signed_out = used(&state, None, T0 + 20);
    assert_eq!((signed_out.header, signed_out.fetch), (None, false));
    assert_eq!(used(&state, Some(""), T0 + 20).header, None);
}

#[test]
fn an_answer_for_another_team_is_not_kept() {
    let reply = kept("team_a", T0, T0 + 10, 200, answer("team_b", T0));
    assert_eq!((reply.state.held, reply.outcome), (None, "wrong_team"));
}

#[test]
fn a_failed_fetch_backs_off_by_what_it_was() {
    let refused = json!({"ok": false, "error": {"code": "auth.forbidden", "message": "no"}});
    let busy = json!({"ok": false, "error": {"code": "owner.unreachable", "message": "retry"}});
    let off = json!({"ok": false, "error": {"code": "cloud.capability_off", "message": "off"}});
    for (status, body, outcome, after) in [
        (404, off, "off", RETRY_OFF_MS),
        (403, refused, "refused", RETRY_REFUSED_MS),
        (403, busy.clone(), "failed", RETRY_UNREACHABLE_MS),
        (503, busy, "failed", RETRY_UNREACHABLE_MS),
        (0, Value::Null, "unreachable", RETRY_UNREACHABLE_MS),
        (200, json!({"ok": true, "value": {}}), "unreadable", RETRY_UNREACHABLE_MS),
    ] {
        let reply = kept("team_a", T0, T0 + 10, status, body);
        assert_eq!(
            (reply.outcome, reply.state.next_fetch_ms),
            (outcome, T0 + 10 + after),
            "{status}"
        );
        assert!(!used(&reply.state, Some("team_a"), T0 + 10 + after - 1).fetch);
        assert!(used(&reply.state, Some("team_a"), T0 + 10 + after).fetch);
    }
}

/// A failed refresh drops the team's old token: what the server would no longer take is not sent.
#[test]
fn a_failed_refresh_drops_the_old_token() {
    let state = kept("team_a", T0, T0 + 10, 200, answer("team_a", T0)).state;
    let reply = keep(&KeepRequest {
        state,
        team: "team_a".into(),
        sent_ms: T0 + 240_000,
        now_ms: T0 + 240_100,
        status: 503,
        body: Value::Null,
    });
    assert_eq!(reply.state.held, None);
}

/// Only a token that can go in a header as is: no line break, no space, not past the platform's
/// longest.
#[test]
fn a_token_that_cannot_go_in_a_header_is_not_kept() {
    for bad in ["", "cc1.a\r\nx-evil: 1", "cc1.a b", "cc1.é", &"a".repeat(MAX_TOKEN_CHARS + 1)] {
        let mut body = answer("team_a", T0);
        body["value"]["capability"] = json!(bad);
        assert_eq!(kept("team_a", T0, T0 + 10, 200, body).outcome, "unreadable", "{bad:?}");
    }
}

/// A fetch that answered after its token's lifetime (a stalled request) keeps nothing.
#[test]
fn an_answer_that_arrives_expired_is_not_kept() {
    let reply = kept("team_a", T0, T0 + 300_000, 200, answer("team_a", T0));
    assert_eq!((reply.state.held, reply.outcome), (None, "expired"));
}

/// Swift's `JSONValue` sends every number as a `Double`: `1.0e12` reads as a whole ms; a fraction or a
/// negative is refused, never rounded.
#[test]
fn numbers_from_swift_read_as_whole_ms() {
    let request: UseRequest = serde_json::from_str(
        r#"{"state":{"nextFetchMs":5.0},"team":"t","nowMs":1.794304118456e12}"#,
    )
    .unwrap();
    assert_eq!((request.now_ms, request.state.next_fetch_ms), (1_794_304_118_456, 5));
    for bad in ["1.5", "-1", "1e300"] {
        assert!(
            serde_json::from_str::<UseRequest>(&format!(r#"{{"team":"t","nowMs":{bad}}}"#))
                .is_err(),
            "{bad}"
        );
    }
}

/// The route's answer reaches Rust re-encoded by Swift's `JSONValue`, every number a float.
#[test]
fn an_answer_with_float_times_is_kept() {
    let body = json!({"ok": true, "value": {"capability": TOKEN, "team": "team_a", "issued_at": 5.0, "expires_at": 300_005.0, "refresh_at": 240_005.0}});
    let reply = kept("team_a", T0, T0 + 10, 200, body);
    assert_eq!(reply.outcome, "held");
    assert_eq!(reply.state.held.unwrap().refresh_at_ms, T0 + 240_000);
}

#[test]
fn the_process_holds_the_token_between_calls_and_a_drop_forgets_it() {
    // The only test of the process-wide state: the others use the pure rules with their own state.
    forget();
    let ask = |now: u64| header(&HeaderRequest { team: Some("team_a".to_owned()), now_ms: now });
    assert_eq!(ask(T0), HeaderReply { header: None, fetch: true });
    assert!(!ask(T0 + 1).fetch, "one fetch in flight");
    let kept = super::answer(AnswerRequest {
        team: "team_a".to_owned(),
        sent_ms: T0,
        now_ms: T0 + 50,
        status: 200,
        body: answer("team_a", 1_000),
    });
    assert_eq!(kept.outcome, "held");
    assert_eq!(ask(T0 + 60), HeaderReply { header: Some(TOKEN.to_owned()), fetch: false });
    forget();
    assert_eq!(ask(T0 + 70), HeaderReply { header: None, fetch: true });
    forget();
}
