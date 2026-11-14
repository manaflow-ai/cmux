use serde_json::{Value, json};

use super::{Failure, answered};

/// `cmux cloud api`'s request line as the app sends it, read by [`crate::parse`].
fn sent(call: &str, args: Value, classic: Option<Value>, unread: bool) -> crate::Request {
    let mut line = json!({"call": call, "api": "https://worker.invalid", "auth": "owner",
            "credential": "worker-access", "team": "team_cmux", "args": args});
    if let Some(classic) = classic {
        line["classic"] = classic;
    }
    if unread {
        line["classic_unread"] = json!(true);
    }
    crate::parse(line.to_string().as_bytes()).unwrap().0
}

fn session() -> Value {
    json!({"api": "https://classic.invalid", "access": "stack-access",
            "refresh": "stack-refresh", "team": "team_stack"})
}

#[test]
fn a_wait_a_cancel_and_an_incognito_create_take_the_classic_session_nothing_else() {
    for (call, args) in [
        ("runs.wait", json!({"id": "r-old", "timeoutMs": 1})),
        ("runs.cancel", json!({"id": "r-old"})),
        ("runs.create", json!({"task": "private", "incognito": true})),
    ] {
        let request = sent(call, args, Some(session()), false);
        assert_eq!(request.credential, "stack-access", "{call}");
        assert_eq!(request.refresh.as_deref(), Some("stack-refresh"), "{call}");
        assert_eq!(request.args["classicApi"], "https://classic.invalid", "{call}");
        assert_eq!(request.args["classicTeam"], "team_stack", "{call}");
        assert_eq!(request.team.as_deref(), Some("team_cmux"), "the daemon's own team stays");
    }
    for (call, args) in [("runs.create", json!({"task": "hi"})), ("vm.domains", json!({}))] {
        let request = sent(call, args, Some(session()), false);
        assert_eq!(request.credential, "worker-access", "{call}");
        assert_eq!(request.refresh, None, "{call}");
        assert!(!request.args.contains_key("classicApi"), "{call}");
        assert!(!request.args.contains_key("classicUnread"), "{call}");
    }
}

#[test]
fn a_session_the_app_could_not_read_never_ends_a_classic_run() {
    let not_found =
        || Err(Failure::http(404, Some("run_not_found".into()), Some("no such Run".into())));
    let unread = sent("runs.wait", json!({"id": "r-old", "timeoutMs": 1}), None, true);
    assert!(!unread.args.contains_key("classicApi"));
    assert!(matches!(answered(&unread, not_found()), Err(Failure::Transport(_))));
    // A session with no refresh token is no session either.
    let mut empty = session();
    empty["refresh"] = json!("");
    let empty = sent("runs.cancel", json!({"id": "r-old"}), Some(empty), false);
    assert!(matches!(answered(&empty, not_found()), Err(Failure::Transport(_))));
    // A client with no classic session at all: the daemon's answer stands.
    let none = sent("runs.wait", json!({"id": "r-x", "timeoutMs": 1}), None, false);
    assert!(matches!(answered(&none, not_found()), Err(Failure::Http { status: 404, .. })));
    // A Run the daemon knows answers as it is.
    assert_eq!(answered(&unread, Ok(json!({"run": {}}))).unwrap(), json!({"run": {}}));
}
