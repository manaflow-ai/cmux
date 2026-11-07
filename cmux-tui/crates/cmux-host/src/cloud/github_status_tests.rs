use super::github_status::{REQUEST_KEY, STATUS_PATH, check_ask, reply_for, sanitize};
use super::sender::Answer;
use serde_json::json;

const TOKEN: &str = "ghu_16C7e42F292c6912E7710c838347Ae178B4a";

#[test]
fn the_ask_takes_no_fields_and_names_the_platform_route() {
    assert_eq!(REQUEST_KEY, "github_status");
    assert_eq!(STATUS_PATH, "/v1/me/github");
    assert!(check_ask(&json!({})).is_ok());
    assert!(check_ask(&serde_json::Value::Null).is_ok());
    assert!(check_ask(&json!({"origin": "https://evil.example"})).is_err());
}

#[test]
fn a_connected_answer_keeps_only_the_contract_fields_and_never_a_token() {
    let body = json!({
        "connected": true, "login": "octocat", "name": "The Octocat",
        "avatarUrl": "https://avatars.githubusercontent.com/u/583231?v=4",
        "htmlUrl": "https://github.com/octocat", "source": "github-app", "accountType": "user",
        "repositories": {"count": 8, "selection": "selected"},
        "token": TOKEN, "accessToken": TOKEN, "installationToken": TOKEN,
    });
    let reply = reply_for(&Answer::Http { status: 200, body });
    assert_eq!(
        reply,
        json!({
            "ok": true, "connected": true, "login": "octocat", "name": "The Octocat",
            "avatarUrl": "https://avatars.githubusercontent.com/u/583231?v=4",
            "htmlUrl": "https://github.com/octocat", "source": "github-app", "accountType": "user",
            "repositories": {"count": 8, "selection": "selected"},
        })
    );
    assert!(!reply.to_string().contains("ghu_"));
}

#[test]
fn a_token_hidden_in_a_profile_field_is_dropped() {
    let body = json!({
        "connected": true, "login": "octocat", "name": TOKEN,
        "htmlUrl": format!("https://github.com/octocat?access_token={TOKEN}"),
        "avatarUrl": format!("https://avatars.githubusercontent.com/{TOKEN}"),
        "source": TOKEN,
    });
    let reply = sanitize(&body);
    assert_eq!(reply, json!({"ok": true, "connected": true, "login": "octocat"}));
    // A login that is not a GitHub login is not an account.
    let reply = sanitize(&json!({"connected": true, "login": TOKEN.repeat(2)}));
    assert_eq!(reply, json!({"ok": true, "connected": false}));
}

#[test]
fn not_connected_carries_only_a_connect_link() {
    let reply = sanitize(&json!({
        "connected": false, "connectUrl": "https://github.com/apps/cmux/installations/new",
        "login": "octocat",
    }));
    assert_eq!(
        reply,
        json!({"ok": true, "connected": false,
               "connectUrl": "https://github.com/apps/cmux/installations/new"})
    );
    let reply = sanitize(&json!({"connected": false, "connectUrl": "http://phish.example"}));
    assert_eq!(reply, json!({"ok": true, "connected": false}));
}

#[test]
fn platform_failures_are_fixed_refusals_without_the_body() {
    for (answer, code) in [
        (Answer::Http { status: 401, body: json!({"token": TOKEN}) }, "auth.refused"),
        (Answer::Http { status: 404, body: json!({}) }, "integration.unavailable"),
        (Answer::Http { status: 500, body: json!({"token": TOKEN}) }, "integration.unavailable"),
        (Answer::Http { status: 200, body: json!(TOKEN) }, "integration.bad_answer"),
        (Answer::Transport, "integration.unreachable"),
    ] {
        let reply = reply_for(&answer);
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error"]["code"], code, "{reply}");
        assert!(!reply.to_string().contains("ghu_"), "{reply}");
    }
}
