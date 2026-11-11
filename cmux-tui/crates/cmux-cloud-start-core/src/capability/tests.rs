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
        fetch_id: None,
        sent_ms: sent,
        now_ms: now,
        status,
        body,
    })
}

fn used(state: &State, team: Option<&str>, now: u64) -> UseReply {
    let request = json!({"state": state, "team": team, "nowMs": now});
    use_for(&serde_json::from_value::<UseRequest>(request).unwrap())
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
        assert_eq!(reply.outcome, outcome, "{status}");
        assert!(!used(&reply.state, Some("team_a"), T0 + 10 + after - 1).fetch);
        assert!(used(&reply.state, Some("team_a"), T0 + 10 + after).fetch);
        // Only a backend with no capabilities holds off every team.
        let other = used(&reply.state, Some("team_b"), T0 + 20).fetch;
        assert_eq!(other, outcome != "off", "{status}");
    }
}

/// A failed refresh drops the team's old token: what the server would no longer take is not sent.
#[test]
fn a_failed_refresh_drops_the_old_token() {
    let state = kept("team_a", T0, T0 + 10, 200, answer("team_a", T0)).state;
    let reply = keep(&KeepRequest {
        state,
        team: "team_a".into(),
        fetch_id: None,
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

/// The tests of the process-wide state take turns: it is one per process.
static PROCESS: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn process() -> std::sync::MutexGuard<'static, ()> {
    PROCESS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[test]
fn the_process_holds_the_token_between_calls_and_a_drop_forgets_it() {
    // A test of the process-wide state: it holds `process()`; the pure rules' tests keep their own.
    let _turn = process();
    forget();
    let ask = |now: u64| asked("team_a", now);
    let first = ask(T0);
    assert_eq!((&first["header"], &first["fetch"]), (&Value::Null, &json!(true)));
    assert!(first["fetchId"].is_number(), "the fetch has an id");
    assert_eq!(ask(T0 + 1)["fetch"], json!(false), "one fetch in flight");
    assert_eq!(answer_wire("team_a", T0, T0 + 50, &first["fetchId"]), "held");
    let next = ask(T0 + 60);
    assert_eq!((&next["header"], &next["fetch"]), (&json!(TOKEN), &json!(false)));
    assert_eq!(next["fetchId"], Value::Null);
    forget();
    let again = ask(T0 + 70);
    assert_eq!((&again["header"], &again["fetch"]), (&Value::Null, &json!(true)));
    assert!(
        again["fetchId"].as_u64() > first["fetchId"].as_u64(),
        "ids keep counting across a drop"
    );
    forget();
}

/// A team switch inside the in-flight window (B's call while A's fetch is out) fetches B at once:
/// B never waits for A's answer, a later call or the refresh.
#[test]
fn a_team_switch_while_a_fetch_is_in_flight_fetches_the_new_team_at_once() {
    let a = used(&State::default(), Some("team_a"), T0);
    assert!(a.fetch);
    let b = used(&a.state, Some("team_b"), T0 + 5);
    assert_eq!((b.header, b.fetch), (None, true), "B's first call starts B's fetch");
    // B asked again while its own fetch is out starts no second one.
    let again = used(&b.state, Some("team_b"), T0 + 6);
    assert!(!again.fetch, "B is fetched once");
    // Nor does A, whose fetch is still out.
    assert!(!used(&again.state, Some("team_a"), T0 + 7).fetch, "A is fetched once");
}

/// Codex's review of #41178: A held, B's fetch out, the person goes back to A, then B answers. A is
/// still the one held: B's late answer is for a team the person left.
#[test]
fn a_late_answer_for_a_team_the_person_left_is_not_kept() {
    let held = kept("team_a", T0, T0 + 10, 200, answer("team_a", T0)).state;
    let b = used(&held, Some("team_b"), T0 + 20);
    assert!(b.fetch);
    let back = used(&b.state, Some("team_a"), T0 + 30);
    assert_eq!((back.header.as_deref(), back.fetch), (Some(TOKEN), false));
    let late = keep(&KeepRequest {
        state: back.state,
        team: "team_b".into(),
        fetch_id: b.fetch_id,
        sent_ms: T0 + 20,
        now_ms: T0 + 40,
        status: 200,
        body: answer("team_b", T0 + 20),
    });
    assert_eq!(late.state.held.as_ref().map(|held| held.team.as_str()), Some("team_a"));
    let a = used(&late.state, Some("team_a"), T0 + 50);
    assert_eq!((a.header.as_deref(), a.fetch), (Some(TOKEN), false));
}

/// A refusal (no plan in A, say) holds off A's next fetch, never another team's.
#[test]
fn a_refusal_for_one_team_never_holds_off_another() {
    let refused = json!({"ok": false, "error": {"code": "auth.forbidden", "message": "no"}});
    let state = kept("team_a", T0, T0 + 10, 403, refused).state;
    assert!(!used(&state, Some("team_a"), T0 + 20).fetch);
    assert!(used(&state, Some("team_b"), T0 + 20).fetch, "a switch to B fetches B");
}

/// A sign-out (or an account switch) while a fetch is out: its answer, for the account that left,
/// is never kept or sent, even for the same team.
#[test]
fn an_answer_to_a_fetch_sent_before_a_drop_is_not_kept() {
    let _turn = process();
    forget();
    let (fetched, before) = ask_wire("team_a", T0);
    assert!(fetched);
    forget();
    assert_eq!(answer_wire("team_a", T0, T0 + 50, &before), "dropped");
    assert_eq!(
        asked("team_a", T0 + 60)["header"],
        Value::Null,
        "the old account's token is never sent"
    );
    forget();
}

/// A seeded xorshift: the model's schedule, the same on every run.
struct Schedule(u64);

impl Schedule {
    fn below(&mut self, n: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % n
    }
}

/// `cloud_capability_header` as the app calls it, with a bearer captured at `generation`: the reply's
/// JSON, with every field the app reads (`null` when absent).
fn asked_at(team: Option<&str>, now: u64, generation: &Value) -> Value {
    let request = json!({"team": team, "nowMs": now, "generation": generation});
    let reply = serde_json::to_value(header(&serde_json::from_value(request).unwrap())).unwrap();
    let field = |name: &str| reply.get(name).cloned().unwrap_or(Value::Null);
    json!({"header": field("header"), "fetch": field("fetch"), "fetchId": field("fetchId"),
           "generation": field("generation")})
}

/// The generation, read as the app reads it when it captures a bearer: a call with no team.
fn generation() -> Value {
    asked_at(None, T0, &Value::Null)["generation"].clone()
}

/// A call whose bearer was captured just now.
fn asked(team: &str, now: u64) -> Value {
    asked_at(Some(team), now, &generation())
}

/// [`asked`]: whether it starts a fetch, and the fetch's id.
fn ask_wire(team: &str, now: u64) -> (bool, Value) {
    let reply = asked(team, now);
    (reply["fetch"] == json!(true), reply["fetchId"].clone())
}

/// A 200 answer through `cloud_capability_answer` as the app sends it, naming the fetch's id.
fn answer_wire(team: &str, sent: u64, now: u64, id: &Value) -> &'static str {
    let request: AnswerRequest = serde_json::from_value(json!({
        "team": team, "sentMs": sent, "nowMs": now, "status": 200,
        "body": answer(team, 1_000), "fetchId": id,
    }))
    .unwrap();
    super::answer(request).outcome
}

/// Codex's P1 on 1abfea56: a fetch sent before a sign-out and one sent after it, for the same team in
/// the same millisecond (an injected clock). The pre-drop answer is the old account's: refused, and
/// the new account's own answer is kept. A fetch is told apart by its id, never by its time.
#[test]
fn an_answer_to_a_pre_drop_fetch_is_refused_even_in_the_same_millisecond() {
    let _turn = process();
    forget();
    let (fetched, before) = ask_wire("team_a", T0);
    assert!(fetched);
    forget();
    let (fetched, after) = ask_wire("team_a", T0);
    assert!(fetched, "the new account fetches at once");
    assert_eq!(answer_wire("team_a", T0, T0, &before), "dropped", "the old account's answer");
    assert_eq!(answer_wire("team_a", T0, T0, &after), "held");
    assert!(!ask_wire("team_a", T0).0, "the new account's answer is held");
    // And the other way round: the new answer first, then the old one, which changes nothing.
    forget();
    let (_, before) = ask_wire("team_a", T0);
    forget();
    let (_, after) = ask_wire("team_a", T0);
    assert_eq!(answer_wire("team_a", T0, T0, &after), "held");
    assert_eq!(answer_wire("team_a", T0, T0, &before), "dropped");
    forget();
}

/// Codex's P1 on 0654637e: a call captures the old account's bearer, suspends, a drop runs (a
/// sign-out, or a switch to another account in the same team), then the call resumes and asks for a
/// fetch. Its bearer is from before the drop: no fetch, no id, nothing held, and the new account's
/// token never goes on it.
#[test]
fn a_bearer_captured_before_a_drop_starts_no_fetch_after_it() {
    let _turn = process();
    forget();
    let captured = generation();
    forget();
    let stale = asked_at(Some("team_a"), T0, &captured);
    assert_eq!(
        (&stale["header"], &stale["fetch"], &stale["fetchId"]),
        (&Value::Null, &json!(false), &Value::Null),
        "the old bearer gets no fetch and no id"
    );
    // Nothing is in flight or held off: the new account's own call fetches at once and is held.
    let (fetched, id) = ask_wire("team_a", T0);
    assert!(fetched, "the stale call left nothing in flight");
    assert_eq!(answer_wire("team_a", T0, T0 + 1, &id), "held");
    // And the new account's token never goes out on the old bearer.
    assert_eq!(asked_at(Some("team_a"), T0 + 2, &captured)["header"], Value::Null);
    assert_eq!(asked("team_a", T0 + 2)["header"], json!(TOKEN));
    forget();
}

/// The class: whatever team was asked for last is the one held once every fetch has answered, and
/// after a drop no answer to a fetch from before it is ever held. Over 5,000 random orders of calls in
/// three teams, answers in any order, drops (sign-out, an account or team switch) and a clock with few
/// distinct values, so fetches on both sides of a drop often share a millisecond. Calls also capture
/// their bearer, suspend across other steps and resume: one captured before a drop never fetches.
/// Through the process's own ops, as the app calls them.
#[test]
fn the_last_team_asked_for_is_held_once_every_fetch_has_answered() {
    let _turn = process();
    for seed in 1..=5_000_u64 {
        let mut schedule = Schedule(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        forget();
        let mut now = T0;
        let mut drops = 0_u32;
        let mut last = None;
        // Each fetch still out: its team, when it was sent, its id, and the drops before it.
        let mut out: Vec<(&str, u64, Value, u32)> = Vec::new();
        // Each call suspended after capturing its bearer: its team, the generation, the drops before it.
        let mut suspended: Vec<(&str, Value, u32)> = Vec::new();
        let mut steps = Vec::new();
        for _ in 0..2 + schedule.below(14) {
            // Most steps keep the same millisecond.
            now += match schedule.below(8) {
                0 if now < T0 + 150_000 => IN_FLIGHT_MS,
                1 | 2 => 1 + schedule.below(1_000),
                _ => 0,
            };
            let team = match schedule.below(3) {
                0 => "team_a",
                1 => "team_b",
                _ => "team_c",
            };
            match schedule.below(9) {
                0 | 1 => {
                    let (fetched, id) = ask_wire(team, now);
                    if fetched {
                        out.push((team, now, id, drops));
                    }
                    last = Some(team);
                    steps.push(format!(
                        "call {team}@{now}{}",
                        if fetched { " (fetch)" } else { "" }
                    ));
                }
                2 | 3 if !out.is_empty() => {
                    let index = usize::try_from(schedule.below(out.len() as u64)).unwrap_or(0);
                    let (team, sent, id, epoch) = out.swap_remove(index.min(out.len() - 1));
                    let outcome = answer_wire(team, sent, now, &id);
                    steps.push(format!("answer {team}@{sent}: {outcome}"));
                    assert!(
                        epoch == drops || outcome != "held",
                        "seed {seed}: a pre-drop answer was held after {steps:?}"
                    );
                }
                4 | 5 => {
                    // A sign-out, or an account or team switch: nothing is asked for in the new one yet.
                    forget();
                    drops += 1;
                    last = None;
                    steps.push("drop".to_owned());
                }
                6 => {
                    suspended.push((team, generation(), drops));
                    steps.push(format!("capture {team}"));
                }
                7 | 8 if !suspended.is_empty() => {
                    let index =
                        usize::try_from(schedule.below(suspended.len() as u64)).unwrap_or(0);
                    let (team, captured, epoch) =
                        suspended.swap_remove(index.min(suspended.len() - 1));
                    let reply = asked_at(Some(team), now, &captured);
                    let fetched = reply["fetch"] == json!(true);
                    steps.push(format!(
                        "resume {team}@{now}{}",
                        if fetched { " (fetch)" } else { "" }
                    ));
                    if epoch == drops {
                        if fetched {
                            out.push((team, now, reply["fetchId"].clone(), epoch));
                        }
                        last = Some(team);
                    } else {
                        assert_eq!(
                            (&reply["header"], &reply["fetch"], &reply["fetchId"]),
                            (&Value::Null, &json!(false), &Value::Null),
                            "seed {seed}: a bearer from before a drop was used after {steps:?}"
                        );
                    }
                }
                _ => {}
            }
        }
        // Settle: every fetch still out answers.
        for (team, sent, id, epoch) in std::mem::take(&mut out) {
            now += 1;
            let outcome = answer_wire(team, sent, now, &id);
            steps.push(format!("answer {team}@{sent}: {outcome}"));
            assert!(
                epoch == drops || outcome != "held",
                "seed {seed}: a pre-drop answer was held after {steps:?}"
            );
        }
        if let Some(team) = last {
            assert_eq!(
                asked(team, now + 1)["header"],
                json!(TOKEN),
                "seed {seed}: {team} not held after {steps:?}"
            );
        }
    }
    forget();
}
