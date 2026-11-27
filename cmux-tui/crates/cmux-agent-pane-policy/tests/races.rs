//! Model-race requests use their parent session as the pane scope and only
//! starting a race consumes a user gesture.

use cmux_agent_pane_policy::gesture::needs_gesture;
use cmux_agent_pane_policy::params::session_refusal;
use cmux_agent_pane_policy::{Refusal, policy};
use serde_json::{Map, Value, json};

fn frame(method: &str, params: Value) -> Map<String, Value> {
    json!({"id": 1, "method": method, "params": params}).as_object().unwrap().clone()
}

#[test]
fn race_parent_is_the_session_scope() {
    let request = frame("_acpmux/race/list", json!({"parent": "parent-session"}));
    assert!(session_refusal(&request, |session| session == "parent-session").is_none());

    let refused = session_refusal(&request, |session| session == "another-session")
        .expect("a race for another pane's parent must be refused");
    assert_eq!(refused.refusal, Refusal::SessionNotInPane);
    assert_eq!(refused.method.as_deref(), Some("_acpmux/race/list"));

    for params in [json!({}), json!({"parent": null}), json!({"parent": 42})] {
        let request = frame("_acpmux/race/list", params);
        let refused = session_refusal(&request, |_| true)
            .expect("a race without a string parent must be refused");
        assert_eq!(refused.refusal, Refusal::SessionNotInPane);
    }
}

#[test]
fn every_race_method_is_parent_scoped() {
    let p = policy();
    let methods = [
        "_acpmux/race/start",
        "_acpmux/race/get",
        "_acpmux/race/list",
        "_acpmux/race/cancel",
        "_acpmux/race/stats",
    ];
    for method in methods {
        assert_eq!(p.primary_session_params.get(method).map(String::as_str), Some("parent"));
        assert!(p.session_scoped.contains(method), "{method} must be session scoped");
        assert!(p.requests.contains(method), "{method} must be request-allowlisted");
    }
}

#[test]
fn only_race_start_requires_a_gesture() {
    let start = frame("_acpmux/race/start", json!({"parent": "s"}));
    assert!(needs_gesture(&start, |_, _| false));

    for method in
        ["_acpmux/race/get", "_acpmux/race/list", "_acpmux/race/cancel", "_acpmux/race/stats"]
    {
        let request = frame(method, json!({"parent": "s"}));
        assert!(!needs_gesture(&request, |_, _| false), "{method} should not need a gesture");
    }
}
