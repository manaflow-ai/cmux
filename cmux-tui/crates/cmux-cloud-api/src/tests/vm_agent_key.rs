//! `vm.agent_key_create` against the fake: the route, headers and body the app's Swift used to send
//! (AppControl+VMAgentKey), and every status answered as `{status, body}` for the app's reading.

use super::*;

fn mint(origin: &str, args: Value) -> Result<Value, Failure> {
    go(&request(origin, Auth::Owner, "vm.agent_key_create", args))
}

#[test]
fn an_agent_key_mint_posts_the_body_with_the_session_and_team() {
    let key = r#"{"key":"cmux_ak_secret","id":"ak_1","expiresAt":"2026-11-28T00:00:00Z"}"#;
    let (origin, seen) = fake(move |_| Some((201, key.into())));
    let body = json!({ "name": "cli", "maxVms": 2, "budgetUsdPerHour": 1.5, "ttlSeconds": 3600 });
    let answer = mint(&origin, json!({ "body": body })).unwrap();
    assert_eq!(answer, json!({ "status": 201, "body": key }));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /v1/agent-keys");
    assert_eq!(seen[0].json(), body);
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(seen[0].header("x-cmux-team-id").as_deref(), Some("team-1"));
    assert_eq!(seen[0].header("content-type").as_deref(), Some("application/json"));
    // Owner auth: never the Stack refresh token.
    assert_eq!(seen[0].header("x-stack-refresh-token"), None);
}

#[test]
fn an_agent_key_refusal_is_its_status_and_body_text() {
    let (origin, _) = fake(|_| Some((402, r#"{"error":"payment_required"}"#.into())));
    let answer = mint(&origin, json!({ "body": {} })).unwrap();
    assert_eq!(answer, json!({ "status": 402, "body": r#"{"error":"payment_required"}"# }));
    let (origin, _) = fake(|_| Some((502, "bad gateway".into())));
    let answer = mint(&origin, json!({ "body": {} })).unwrap();
    assert_eq!(answer, json!({ "status": 502, "body": "bad gateway" }));
}

#[test]
fn an_agent_key_mint_needs_a_body_object_and_a_team_before_any_request() {
    let (origin, seen) = fake(|_| ok("{}"));
    for args in [
        json!({}),
        json!({ "body": [1] }),
        json!({ "body": "x" }),
        json!({ "body_json": "[1]" }),
        json!({ "body_json": "{not json" }),
        json!({ "body": {}, "body_json": "{}" }),
    ] {
        let refused = mint(&origin, args);
        assert!(matches!(refused, Err(Failure::Transport(_))), "{refused:?}");
    }
    let mut no_team = request(&origin, Auth::Owner, "vm.agent_key_create", json!({ "body": {} }));
    no_team.team = None;
    assert!(matches!(go(&no_team), Err(Failure::Transport(_))));
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn an_agent_key_body_may_come_as_the_apps_json_text() {
    let (origin, seen) = fake(|_| Some((201, "{}".into())));
    let text = r#"{"name":"cli","budgetUsdPerHour":1.5}"#;
    mint(&origin, json!({ "body_json": text })).unwrap();
    assert_eq!(seen.lock().unwrap()[0].json(), json!({ "name": "cli", "budgetUsdPerHour": 1.5 }));
}
