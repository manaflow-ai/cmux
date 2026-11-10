//! The signed Cloud capability's app rules (cmux-platform#1126): what a mint answers, what a
//! relayed call sends, and when the app mints again.

use super::*;
use serde_json::json;

const TOKEN: &str = "cc1.eyJ2IjoxfQ.c2lnbmF0dXJl";
const TEAM: &str = "team_a";

/// The route's answer (CloudCapabilityRoute.ts): server times, 5 min life, refresh at 4.
fn minted(team: &str, issued: i64) -> Value {
    json!({"ok": true, "value": {
        "capability": TOKEN, "team": team, "plan_id": "max", "cloud": true, "company": false,
        "limits": null, "issued_at": issued, "expires_at": issued + 300_000, "refresh_at": issued + 240_000,
    }})
}

fn held(now: i64) -> Held {
    read_mint(200, &minted(TEAM, 1_000_000), TEAM, now).expect("a capability")
}

fn state(held: Option<Held>, team: Option<&str>, now: i64) -> State {
    State { held, team: team.map(str::to_owned), now, ..State::default() }
}

#[test]
fn a_mint_is_held_on_this_macs_clock_whatever_the_servers_clock_says() {
    // The server's clock is an hour behind this Mac's: the lifetime still counts from arrival.
    let now = 1_000_000 + 3_600_000;
    let held = read_mint(200, &minted(TEAM, 1_000_000), TEAM, now).unwrap();
    assert_eq!(held.token, TOKEN);
    assert_eq!(held.team, TEAM);
    assert_eq!(held.expires_at, now + 300_000);
    assert_eq!(held.refresh_at, now + 240_000);
}

#[test]
fn a_refusal_another_team_or_a_malformed_answer_holds_nothing() {
    let now = 5;
    assert_eq!(read_mint(403, &minted(TEAM, 0), TEAM, now), None);
    assert_eq!(
        read_mint(404, &json!({"ok": false, "error": {"code": "cloud.capability_off"}}), TEAM, now),
        None
    );
    assert_eq!(read_mint(200, &minted("team_b", 0), TEAM, now), None, "minted for another team");
    for token in ["", "cc2.a.b", "cc1.a", "cc1.a.b.c", "cc1.a b.c", "cc1..c", "cc1.a\n.b"] {
        let mut body = minted(TEAM, 0);
        body["value"]["capability"] = json!(token);
        assert_eq!(read_mint(200, &body, TEAM, now), None, "{token:?}");
    }
    let mut long = minted(TEAM, 0);
    long["value"]["capability"] = json!(format!("cc1.{}.sig", "a".repeat(4096)));
    assert_eq!(read_mint(200, &long, TEAM, now), None, "longer than the server accepts");
    let mut forever = minted(TEAM, 0);
    forever["value"]["expires_at"] = json!(3_600_000);
    assert_eq!(read_mint(200, &forever, TEAM, now), None, "lives longer than the TTL");
    let mut dead = minted(TEAM, 0);
    dead["value"]["expires_at"] = json!(0);
    assert_eq!(read_mint(200, &dead, TEAM, now), None, "already expired");
}

#[test]
fn a_mint_without_a_refresh_time_refreshes_a_minute_before_expiry() {
    let mut body = minted(TEAM, 0);
    body["value"].as_object_mut().unwrap().remove("refresh_at");
    let held = read_mint(200, &body, TEAM, 10).unwrap();
    assert_eq!(held.refresh_at, 10 + 240_000);
}

#[test]
fn a_call_sends_the_capability_of_its_own_team_until_just_before_it_expires() {
    let held = held(0);
    let at = |now| plan(&state(Some(held.clone()), Some(TEAM), now), Reason::Call);
    assert_eq!(at(0).send.as_deref(), Some(TOKEN));
    assert!(!at(0).fetch, "a fresh one is not minted again");
    assert_eq!(at(0).wake_in, Some(240_000));
    assert_eq!(at(300_000 - SEND_MARGIN_MS - 1).send.as_deref(), Some(TOKEN));
    assert_eq!(at(300_000 - SEND_MARGIN_MS).send, None, "too close to expiry to send");
    assert_eq!(at(400_000).send, None);
}

#[test]
fn a_call_after_a_team_switch_sends_nothing_and_mints_for_the_new_team() {
    let switched = plan(&state(Some(held(0)), Some("team_b"), 10), Reason::Call);
    assert_eq!(switched.send, None, "never another team's capability");
    assert!(switched.fetch);
    assert_eq!(switched.wake_in, None);
}

#[test]
fn signed_out_nothing_is_sent_or_minted() {
    assert_eq!(plan(&state(Some(held(0)), None, 10), Reason::Intent), Plan::default());
    assert_eq!(plan(&state(None, Some(""), 10), Reason::Intent), Plan::default());
}

#[test]
fn sign_in_and_intent_mint_when_none_is_held_and_once_it_is_due() {
    assert!(plan(&state(None, Some(TEAM), 0), Reason::Intent).fetch);
    assert!(!plan(&state(Some(held(0)), Some(TEAM), 239_999), Reason::Intent).fetch);
    let due = plan(&state(Some(held(0)), Some(TEAM), 240_000), Reason::Call);
    assert!(due.fetch, "due at refresh_at");
    assert_eq!(
        due.send.as_deref(),
        Some(TOKEN),
        "the held one still goes while the next is minted"
    );
}

#[test]
fn a_failed_mint_waits_before_the_next_for_that_team_only() {
    let mut failed = state(None, Some(TEAM), 100_000);
    failed.failed_at = Some(100_000 - RETRY_AFTER_MS + 1);
    failed.failed_team = Some(TEAM.to_owned());
    assert!(!plan(&failed, Reason::Call).fetch);
    assert!(!plan(&failed, Reason::Intent).fetch);
    failed.now += 1;
    assert!(plan(&failed, Reason::Call).fetch, "the wait is over");
    failed.now -= 1;
    failed.team = Some("team_b".to_owned());
    assert!(plan(&failed, Reason::Call).fetch, "another team's failure does not hold this one");
}

#[test]
fn the_timer_keeps_one_warm_only_while_cloud_is_in_use() {
    let mut timer = state(Some(held(0)), Some(TEAM), 240_000);
    assert!(!plan(&timer, Reason::Timer).fetch, "never used: no mint every 4 minutes for nothing");
    timer.last_use = Some(240_000 - IDLE_STOP_MS + 1);
    assert!(plan(&timer, Reason::Timer).fetch);
    timer.last_use = Some(240_000 - IDLE_STOP_MS);
    assert!(!plan(&timer, Reason::Timer).fetch);
    assert!(plan(&timer, Reason::Call).fetch, "a call always may");
}

#[test]
fn the_wire_names_match_the_server() {
    assert_eq!(HEADER, "x-cmux-cloud-capability");
    assert_eq!(PATH, "v1/cloud/capability");
    assert_eq!(serde_json::to_value(Reason::Intent).unwrap(), "intent");
    let value =
        serde_json::to_value(plan(&state(Some(held(0)), Some(TEAM), 0), Reason::Call)).unwrap();
    assert_eq!(value, json!({"send": TOKEN, "fetch": false, "wakeIn": 240_000}));
    let back: State =
        serde_json::from_value(json!({"held": held(0), "team": TEAM, "now": 3})).unwrap();
    assert_eq!(back.now, 3);
}

/// A refresh that failed wakes again when the backoff ends, not at once, and only while Cloud is in use.
#[test]
fn a_failed_refresh_wakes_again_when_the_backoff_ends_while_cloud_is_in_use() {
    let mut failed = state(Some(held(0)), Some(TEAM), 250_000);
    failed.failed_at = Some(250_000);
    failed.failed_team = Some(TEAM.to_owned());
    failed.last_use = Some(240_000);
    let retry = plan(&failed, Reason::Timer);
    assert!(!retry.fetch, "inside the backoff");
    assert_eq!(retry.wake_in, Some(RETRY_AFTER_MS), "re-armed for the backoff's end");
    failed.now += RETRY_AFTER_MS;
    let recovered = plan(&failed, Reason::Timer);
    assert!(recovered.fetch, "the retry mints");
    failed.last_use = Some(250_000 - IDLE_STOP_MS);
    assert_eq!(plan(&failed, Reason::Timer).wake_in, None, "idle: no timer");
}
