use serde_json::{Value, json};

use super::{agent_context, share_off, ticket_request, with_ticket};

#[test]
fn names_the_agent_session_from_the_environment() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |name: &str| {
            pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| (*value).to_owned())
        }
    };
    assert_eq!(
        agent_context(env(&[
            ("ACPMUX_SESSION_ID", "aid-1"),
            ("ACPMUX_SESSION_NAME", "lane"),
            ("CMUX_AGENT_SESSION", "x")
        ])),
        json!({"session": "aid-1", "name": "lane"})
    );
    assert_eq!(
        agent_context(env(&[("CMUX_AGENT_SESSION", "s-2")])),
        json!({"session": "s-2", "name": null})
    );
    assert_eq!(
        agent_context(env(&[("ACPMUX_SESSION_ID", "  ")])),
        json!({"session": null, "name": null})
    );
}

#[test]
fn the_ticket_request_carries_the_action_the_device_and_the_agent() {
    let agent = json!({"session": "aid-1", "name": null});
    let request = ticket_request("share", Some("Studio"), &agent);
    assert_eq!(request["cmd"], "remote-host-call");
    assert_eq!(request["method"], "agent.ticket");
    assert_eq!(request["params"], json!({"action": "share", "device": "Studio", "agent": agent}));
    assert!(ticket_request("unshare", None, &agent)["params"].get("device").is_none());
}

#[test]
fn without_a_ticket_the_app_gets_exactly_todays_request() {
    let today = json!({"action": "share", "on": true});
    // The daemon refuses (an older daemon, the permission refused, a page): unchanged.
    let refused = with_ticket(today.clone(), || Err(json!({"code": "bad_request"})));
    assert_eq!(refused, today);
    let empty = with_ticket(today.clone(), || Ok(json!({})));
    assert_eq!(empty, today);
    let ticketed = with_ticket(today, || Ok(json!({"ticket": "t1"})));
    assert_eq!(ticketed, json!({"action": "share", "on": true, "agent_ticket": "t1"}));
}

#[test]
fn share_off_goes_through_the_app_only_when_it_takes_the_agents_ticket() {
    // `took` is the app's change; `off` is today's path (cmux Remote's worker, or the app's
    // own action in a build without it).
    let took = |answer: Value| ("app", answer);
    let off = || ("today", Value::Null);
    // No ticket: today's path; the app is never asked.
    let (path, _) = share_off(
        || Err(json!({"code": "bad_request"})),
        |_| -> Result<Value, Value> { panic!("the app is not asked without a ticket") },
        took,
        off,
    );
    assert_eq!(path, "today");
    // A ticket the app takes: the app turns it off, today's path is not taken.
    let (path, answer) = share_off(
        || Ok(json!({"ticket": "t1"})),
        |params| {
            assert_eq!(params, json!({"action": "unshare", "agent_ticket": "t1"}));
            Ok(json!({"ok": true, "agent": true}))
        },
        took,
        off,
    );
    assert_eq!((path, answer["agent"].clone()), ("app", json!(true)));
    // The permission is off (the app says so) or the app is unreachable: today's path.
    for answer in
        [Ok(json!({"ok": false, "asks_person": true})), Err(json!({"code": "app.unreachable"}))]
    {
        let (path, _) = share_off(|| Ok(json!({"ticket": "t1"})), |_| answer, took, off);
        assert_eq!(path, "today");
    }
}
