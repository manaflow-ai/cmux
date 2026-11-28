//! `owner.slack` and `owner.slack_awake` against the fake: the route, method, headers and body
//! of each, the answers they read, and their refusals (ported from the app's CloudSlackTests).

use super::*;

const CHIEF: &str = "agent_01HZX9ABCDEFGHJKMNPQRSTVWX";

fn slack(origin: &str, args: Value) -> Result<Value, Failure> {
    go(&request(origin, Auth::Worker, "owner.slack", args))
}

#[test]
fn slack_requests_go_to_their_route_with_the_install_token_and_the_team() {
    let (origin, seen) = fake(|_| ok(r#"{"connected":false,"teams":[]}"#));
    let answer = slack(&origin, json!({ "route": "connection" })).unwrap();
    assert_eq!(answer, json!({ "connected": false, "teams": [] }));
    slack(&origin, json!({ "route": "install_link" })).unwrap();
    assert_eq!(slack(&origin, json!({ "route": "disconnect" })).unwrap(), json!({}));
    let seen = seen.lock().unwrap();
    let targets: Vec<_> = seen.iter().map(Seen::target).collect();
    assert_eq!(
        targets,
        ["GET /v1/slack/connection", "POST /v1/slack/install-link", "DELETE /v1/slack/connection"]
    );
    for request in seen.iter() {
        assert_eq!(request.header("authorization").as_deref(), Some("Bearer access"));
        assert_eq!(request.header("x-cmux-team").as_deref(), Some("team-1"));
        assert_eq!(request.header("x-stack-refresh-token"), None);
    }
}

#[test]
fn a_disconnect_answers_an_empty_object_whatever_the_body() {
    let (origin, _) = fake(|_| Some((204, String::new())));
    assert_eq!(slack(&origin, json!({ "route": "disconnect" })).unwrap(), json!({}));
}

#[test]
fn an_own_bot_posts_its_configuration_token_and_name_once_and_a_refusal_never_echoes_it() {
    let token = "xoxe.xoxp-1-AAAAAAAAAAAA";
    let (origin, seen) = fake(|_| ok(r#"{"installUrl":"https://slack.com/x"}"#));
    let args = json!({ "route": "create_app", "configToken": token, "name": "Acme" });
    assert_eq!(slack(&origin, args).unwrap(), json!({ "installUrl": "https://slack.com/x" }));
    let args = json!({ "route": "create_app", "configToken": token });
    slack(&origin, args).unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /v1/slack/apps");
    assert_eq!(seen[0].json(), json!({ "configToken": token, "name": "Acme" }));
    assert_eq!(seen[1].json(), json!({ "configToken": token }));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team-1"));
    let (origin, _) = fake(move |_| {
        Some((
            400,
            format!(r#"{{"error":{{"code":"slack.invalid_token","message":"bad {token}"}}}}"#),
        ))
    });
    let args = json!({ "route": "create_app", "configToken": token });
    let refused = slack(&origin, args).unwrap_err();
    assert!(!answer_line(&Err(refused.clone())).contains(token), "{refused:?}");
    assert!(
        matches!(refused, Failure::Http { status: 400, code: Some(c), .. } if c == "slack.invalid_token")
    );
}

#[test]
fn a_slack_refusal_keeps_its_status_and_code() {
    let (origin, _) =
        fake(|_| Some((403, r#"{"error":{"code":"forbidden","message":"no"}}"#.into())));
    let refused = slack(&origin, json!({ "route": "connection" }));
    assert!(
        matches!(refused, Err(Failure::Http { status: 403, code: Some(c), .. }) if c == "forbidden")
    );
}

#[test]
fn an_unknown_slack_route_or_a_missing_token_is_refused_before_a_request() {
    let (origin, seen) = fake(|_| ok("{}"));
    for args in [
        json!({ "route": "PATCH" }),
        json!({}),
        json!({ "route": "create_app" }),
        json!({ "route": "create_app", "configToken": "" }),
    ] {
        assert!(matches!(slack(&origin, args.clone()), Err(Failure::Transport(_))), "{args}");
    }
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn slack_awake_reads_seven_days_and_writes_the_allowance_answering_the_value() {
    let (origin, seen) = fake(|_| ok(r#"{"ok":true,"value":{"allowance_seconds":7200}}"#));
    let awake = |args: Value| go(&request(&origin, Auth::Owner, "owner.slack_awake", args));
    let value = json!({ "allowance_seconds": 7200 });
    assert_eq!(awake(json!({ "chief": CHIEF })).unwrap(), value);
    assert_eq!(awake(json!({ "chief": CHIEF, "allowance": 3600 })).unwrap(), value);
    assert_eq!(awake(json!({ "chief": CHIEF, "allowance": null })).unwrap(), value);
    let seen = seen.lock().unwrap();
    let path = format!("/v1/chiefs/{CHIEF}/slack-awake");
    assert_eq!(seen[0].target(), format!("GET {path}?days=7"));
    assert_eq!(seen[1].target(), format!("PUT {path}"));
    assert_eq!(seen[1].json(), json!({ "allowance_seconds": 3600 }));
    assert_eq!(seen[2].json(), json!({ "allowance_seconds": null }));
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team-1"));
}

#[test]
fn slack_awake_refuses_a_non_chief_id_before_a_request_and_a_reply_with_no_value() {
    let (origin, seen) = fake(|_| ok(r#"{"ok":true}"#));
    let awake = |args: Value| go(&request(&origin, Auth::Owner, "owner.slack_awake", args));
    for chief in ["agent_01HZX9", "agent_01HZX9ABCDEFGHJKMNPQRSTVWI", "vm_x", "../x", ""] {
        let refused = awake(json!({ "chief": chief }));
        assert!(matches!(&refused, Err(Failure::Transport(m)) if m == "not a Chief id"), "{chief}");
    }
    assert!(matches!(
        awake(json!({ "chief": CHIEF, "allowance": "x" })),
        Err(Failure::Transport(_))
    ));
    assert!(seen.lock().unwrap().is_empty());
    let refused = awake(json!({ "chief": CHIEF }));
    assert!(matches!(&refused, Err(Failure::Transport(m)) if m == "unexpected slack-awake reply"));
}
