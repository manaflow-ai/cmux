//! Parity with `MacScreenRunLinkTests` (routes) and the pages' open, push and resume rules.

use serde_json::json;

use super::*;

const DEVICE: &str = "6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b";

fn call(op: &str, args: Value) -> Value {
    handle(op, &args).expect("known op").expect("ok")
}

#[test]
fn the_route_keeps_the_runs_display() {
    let record = Record::device(DEVICE, Some(9), true, Some("a&b+c=d #run"));
    let r = route(&record);
    assert!(r.starts_with(&format!("device:{DEVICE}?display=9&control=1&name=")), "{r}");
    assert_eq!(r, format!("device:{DEVICE}?display=9&control=1&name=a%26b%2Bc%3Dd%20%23run"));
    assert_eq!(parse_route(&r), Some(record));
    assert_eq!(route(&Record::device(DEVICE, None, false, None)), format!("device:{DEVICE}"));
    assert_eq!(
        parse_route(&format!("device:{DEVICE}")),
        Some(Record::device(DEVICE, None, false, None))
    );
    assert_eq!(
        parse_route(&format!("device:{DEVICE}?display=nope")),
        Some(Record::device(DEVICE, None, false, None))
    );
    assert_eq!(parse_route("device:nope?display=9"), None);
}

#[test]
fn home_mac_and_bad_routes() {
    assert_eq!(route(&Record::default()), "home");
    assert_eq!(parse_route("home"), Some(Record::default()));
    let mac = "6F1C2A8E-3B4D-4E5F-8A9B-0C1D2E3F4A5B";
    let r = parse_route(&format!("mac:{}", mac.to_lowercase())).unwrap();
    assert_eq!(r.mac_id.as_deref(), Some(mac));
    assert_eq!(route(&r), format!("mac:{mac}"));
    assert_eq!(parse_route("mac:nope"), None);
    assert_eq!(parse_route("other"), None);
    // The id normalizes: an uppercase, padded id reads as the hub's.
    let upper = parse_route(&format!("device: {} ", DEVICE.to_uppercase())).unwrap();
    assert_eq!(upper.device_id.as_deref(), Some(DEVICE));
}

#[test]
fn record_fields_normalize() {
    assert_eq!(normalized_name("  two\nlines  ").as_deref(), Some("two lines"));
    assert_eq!(normalized_name("   "), None);
    assert_eq!(normalized_name(&"x".repeat(200)).map(|n| n.chars().count()), Some(80));
    assert_eq!(display_id("5"), Some(5));
    assert_eq!(display_id("0"), None);
    assert_eq!(display_id("-5"), None);
    assert_eq!(display_id("99999999999"), None);
    assert_eq!(display_id(""), None);
    assert_eq!(normalized_device_id("nope"), None);
    assert_eq!(normalized_device_id("6f1c2a8e3b4d4e5f8a9b0c1d2e3f4a5b"), None);
}

#[test]
fn titles_for_routes() {
    assert_eq!(call("titleForRoute", json!({"route": null})), Value::Null);
    assert_eq!(call("titleForRoute", json!({"route": "home"})), json!({"kind": "home"}));
    assert_eq!(call("titleForRoute", json!({"route": "garbage"})), json!({"kind": "home"}));
    assert_eq!(
        call("titleForRoute", json!({"route": format!("device:{DEVICE}")})),
        json!({"kind": "device", "deviceId": DEVICE})
    );
    assert_eq!(
        call("route", json!({"deviceId": DEVICE, "display": 3})),
        format!("device:{DEVICE}?display=3")
    );
    assert_eq!(
        call("parseRoute", json!({"route": format!("device:{DEVICE}?control=1")})),
        json!({"deviceId": DEVICE, "control": true})
    );
}

#[test]
fn prepare_and_connect() {
    let p = |by_person, starter, scope, tab| {
        prepare(&PrepareArgs {
            by_person,
            has_pending_starter: starter,
            has_pending_scope: scope,
            is_run_link: false,
            has_tab: tab,
        })
    };
    let person = p(true, true, true, false);
    assert!(person.confirm && person.move_scope && !person.keep_starter && !person.make_view);
    let agent = p(false, true, false, false);
    assert!(agent.confirm && agent.keep_starter && agent.make_view && !agent.move_scope);
    assert!(!p(false, true, false, true).make_view);
    let restored = p(false, false, true, false);
    assert!(!restored.confirm && !restored.move_scope);

    let c = |device, confirmed, scope, tab| ConnectArgs {
        is_device: device,
        confirmed,
        has_pending_scope: scope,
        has_tab: tab,
    };
    assert!(start_connecting(&c(true, true, false, false)));
    assert!(!start_connecting(&c(true, false, true, true)));
    assert!(!start_connecting(&c(false, true, true, true)));
    assert!(connect_in_background(&c(true, true, true, false)));
    assert!(connect_in_background(&c(true, true, false, true)));
    assert!(!connect_in_background(&c(true, true, false, false)));
}

fn tab(key: &str, device: &str, session: Option<&str>) -> Value {
    json!({"key": key, "deviceId": device, "sessionId": session, "movedSession": null})
}

#[test]
fn tickets_find_their_tab() {
    let tabs = json!([tab("b", DEVICE, Some("s2")), {"key": "a", "deviceId": DEVICE, "sessionId": null, "movedSession": null, "accepts": true}]);
    assert_eq!(
        call("ticketTarget", json!({"sessionId": "s2", "pushed": false, "tabs": tabs})),
        json!({"action": "accept", "key": "b"})
    );
    assert_eq!(
        call("ticketTarget", json!({"sessionId": "s9", "pushed": false, "tabs": tabs})),
        json!({"action": "accept", "key": "a"})
    );
    assert_eq!(
        call("ticketTarget", json!({"sessionId": "s9", "pushed": true, "tabs": []})),
        json!({"action": "openPushed"})
    );
    assert_eq!(
        call("ticketTarget", json!({"sessionId": "s9", "pushed": false, "tabs": []})),
        json!({"action": "none"})
    );
}

#[test]
fn pushed_tickets() {
    let other = "11111111-2222-3333-4444-555555555555";
    let pushed = |moved: Option<&str>, tabs: Value| {
        call("openPushed", json!({"deviceId": DEVICE, "movedFrom": moved, "tabs": tabs}))
    };
    assert_eq!(
        call("openPushed", json!({"deviceId": "nope", "movedFrom": null, "tabs": []})),
        json!({"action": "drop"})
    );
    // The moved share's tab, same host: switches in place.
    assert_eq!(
        pushed(Some("s1"), json!([tab("t", DEVICE, Some("s1"))])),
        json!({"action": "acceptPushed", "key": "t"})
    );
    // The moved share's tab on another host gives its place.
    assert_eq!(
        pushed(
            Some("s1"),
            json!([{"key": "t", "deviceId": other, "sessionId": null, "movedSession": "s1"}])
        ),
        json!({"action": "replace", "key": "t"})
    );
    // Else an idle tab of the host, else a new tab.
    let busy = json!({"key": "a", "deviceId": DEVICE, "sessionId": "x", "movedSession": null, "streaming": true});
    let idle = json!({"key": "b", "deviceId": DEVICE, "sessionId": null, "movedSession": null});
    assert_eq!(pushed(None, json!([idle, busy])), json!({"action": "replace", "key": "b"}));
    assert_eq!(pushed(None, json!([busy])), json!({"action": "open"}));
}

#[test]
fn sharing_and_resume() {
    let s = |on, last| host_sharing_changed(&SharingArgs { on, last_host_shared: last });
    assert_eq!(s(true, None), Sharing { mark_shared_before: true, clear_turned_off: true });
    assert_eq!(s(true, Some(false)), Sharing { mark_shared_before: true, clear_turned_off: true });
    assert_eq!(s(true, Some(true)), Sharing { mark_shared_before: true, clear_turned_off: false });
    assert_eq!(s(false, None), Sharing { mark_shared_before: false, clear_turned_off: false });

    let r = |confirmed, tab: Option<&str>, pending: Option<&str>, run_link, scope: &str| {
        resume_scope(&ResumeArgs {
            confirmed,
            tab_scope: tab.map(Into::into),
            pending_scope: pending.map(Into::into),
            run_link,
            record_scope: scope.into(),
        })
    };
    assert_eq!(
        r(true, Some("full"), Some("view"), false, "view"),
        Resume { scope: Some("full".into()), remove_tab_scope: true, remove_pending_scope: false }
    );
    assert_eq!(
        r(true, None, Some("view"), false, "view"),
        Resume { scope: Some("view".into()), remove_tab_scope: false, remove_pending_scope: true }
    );
    assert_eq!(r(false, Some("full"), None, false, "full").scope, None);
    // A run's link: View Only resumes unconfirmed; Full Control only confirmed.
    assert_eq!(r(false, None, None, true, "view").scope.as_deref(), Some("view"));
    assert_eq!(r(false, None, None, true, "full").scope, None);
    assert_eq!(r(true, None, None, true, "full").scope.as_deref(), Some("full"));
}

#[test]
fn unknown_op() {
    assert!(handle("nope", &json!({})).is_none());
}
