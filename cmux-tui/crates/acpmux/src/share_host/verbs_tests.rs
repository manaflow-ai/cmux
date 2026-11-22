use super::*;
use std::cell::RefCell;

/// A fake hub: answers by method and path, and keeps every call.
struct FakeHub {
    calls: RefCell<Vec<(String, String, Option<Value>)>>,
    answer: Box<dyn Fn(&str, &str, Option<&Value>) -> Res<Value>>,
}

impl FakeHub {
    fn new(answer: impl Fn(&str, &str, Option<&Value>) -> Res<Value> + 'static) -> Self {
        Self { calls: RefCell::new(Vec::new()), answer: Box::new(answer) }
    }

    fn call(&self, method: &str, path: &str, body: Option<&Value>) -> Res<Value> {
        self.calls.borrow_mut().push((method.to_owned(), path.to_owned(), body.cloned()));
        (self.answer)(method, path, body)
    }

    fn writes(&self) -> Vec<(String, String, Option<Value>)> {
        self.calls.borrow().iter().filter(|(m, _, _)| m != "GET").cloned().collect()
    }
}

const OWN: &str = "aaaaaaaa-0000-0000-0000-000000000001";
const LAPTOP: &str = "bbbbbbbb-0000-0000-0000-000000000002";
const STUDIO: &str = "cccccccc-0000-0000-0000-000000000003";
const SESSION: &str = "5e55e55e-1111-2222-3333-444444444444";

fn account(method: &str, path: &str, body: Option<&Value>) -> Res<Value> {
    match (method, path) {
        ("GET", "/v1/devices") => Ok(json!({"devices": [
            {"id": OWN, "name": "This Mac"},
            {"id": LAPTOP, "name": "Laptop"},
            {"id": STUDIO, "name": "Studio"},
        ]})),
        ("GET", "/v1/sessions") => Ok(json!({"sessions": [{
            "id": SESSION, "hostId": OWN, "hostName": "This Mac", "viewerId": LAPTOP,
            "viewerName": "Laptop", "scope": "full", "state": "live", "createdAt": 1, "startedAt": 2,
            "movedFrom": null,
        }]})),
        ("POST", "/v1/sessions") => Ok(json!({"session": {
            "id": "new-1", "state": "approved", "scope": body.and_then(|b| b.get("scope")).cloned(),
            "hostId": OWN, "viewerId": body.and_then(|b| b.get("viewerId")).cloned(),
        }})),
        ("POST", p) if p.ends_with("/move") => Ok(json!({"session": {
            "id": "new-2", "state": "approved", "scope": "full", "movedFrom": SESSION,
            "hostId": body.and_then(|b| b.get("hostId")).cloned().unwrap_or(json!(OWN)),
            "viewerId": body.and_then(|b| b.get("viewerId")).cloned().unwrap_or(json!(LAPTOP)),
        }})),
        ("POST", p) if p.ends_with("/end") => Ok(json!({})),
        _ => Err(format!("unexpected {method} {path}").into()),
    }
}

fn refusal(code: &str) -> Res<Value> {
    Err(Box::new(HubError { status: 409, code: code.to_owned(), message: code.to_owned() }))
}

#[test]
fn screens_lists_the_hubs_live_shares_as_records() {
    let hub = FakeHub::new(account);
    let listed = list(&|m, p, b| hub.call(m, p, b)).expect("list");
    assert_eq!(listed["schema"], LIST_SCHEMA);
    assert_eq!(listed["shares"][0]["schema"], RECORD_SCHEMA);
    assert_eq!(listed["shares"][0]["id"], SESSION);
    assert_eq!(listed["shares"][0]["viewerName"], "Laptop");
    assert!(hub.writes().is_empty(), "a list changes nothing");
}

#[test]
fn move_to_a_named_device_hands_the_viewer_side() {
    let hub = FakeHub::new(account);
    let moved = move_share(&|m, p, b| hub.call(m, p, b), OWN, "5e55", Side::Viewer, "studio")
        .expect("move");
    assert_eq!(moved["movedFrom"], SESSION);
    assert_eq!(moved["viewerId"], STUDIO);
    assert_eq!(
        hub.writes(),
        vec![(
            "POST".into(),
            format!("/v1/sessions/{SESSION}/move"),
            Some(json!({"viewerId": STUDIO}))
        )]
    );
}

#[test]
fn move_with_host_hands_the_host_side() {
    let hub = FakeHub::new(account);
    move_share(&|m, p, b| hub.call(m, p, b), OWN, SESSION, Side::Host, "Studio").expect("move");
    assert_eq!(
        hub.writes(),
        vec![(
            "POST".into(),
            format!("/v1/sessions/{SESSION}/move"),
            Some(json!({"hostId": STUDIO}))
        )]
    );
}

#[test]
fn a_refused_move_says_why_in_words_and_sends_nothing_else() {
    let hub = FakeHub::new(|m, p, b| {
        if p.ends_with("/move") { refusal("needs_approval") } else { account(m, p, b) }
    });
    let err = move_share(&|m, p, b| hub.call(m, p, b), OWN, SESSION, Side::Viewer, "laptop")
        .expect_err("refused")
        .to_string();
    assert!(err.contains("Laptop") && err.contains("allow it first"), "{err}");
    assert_eq!(hub.writes().len(), 1, "no end and no retry after a refusal");
}

#[test]
fn a_move_of_an_unknown_share_reaches_no_hub_write() {
    let hub = FakeHub::new(account);
    let err = move_share(&|m, p, b| hub.call(m, p, b), OWN, "ffff", Side::Viewer, "laptop")
        .expect_err("unknown share")
        .to_string();
    assert!(err.contains("no live share"), "{err}");
    assert!(hub.writes().is_empty());
}

#[test]
fn start_shares_this_machine_to_the_named_device() {
    let hub = FakeHub::new(account);
    let started = start(&|m, p, b| hub.call(m, p, b), OWN, "Laptop", true).expect("start");
    assert_eq!(started["scope"], "view");
    assert_eq!(
        hub.writes(),
        vec![(
            "POST".into(),
            "/v1/sessions".into(),
            Some(json!({"hostId": OWN, "viewerId": LAPTOP, "scope": "view"}))
        )]
    );
}

#[test]
fn stop_ends_the_named_share() {
    let hub = FakeHub::new(account);
    let stopped = stop(&|m, p, b| hub.call(m, p, b), "5e5").expect("stop");
    assert_eq!(stopped["state"], "ended");
    assert_eq!(
        hub.writes(),
        vec![(
            "POST".into(),
            format!("/v1/sessions/{SESSION}/end"),
            Some(json!({"reason": "stopped"}))
        )]
    );
}

#[test]
fn pick_device_takes_an_id_a_prefix_or_a_name_and_never_this_device() {
    let devices = vec![
        Device { id: LAPTOP.into(), name: "Laptop".into() },
        Device { id: STUDIO.into(), name: "Studio".into() },
        Device { id: "bbbbbbbb-9999-0000-0000-000000000009".into(), name: "Laptop 2".into() },
    ];
    assert_eq!(pick_device(&devices, STUDIO).map(|d| d.id), Ok(STUDIO.to_owned()));
    assert_eq!(
        pick_device(&devices, "CCC").map(|d| d.id),
        Ok(STUDIO.to_owned()),
        "prefix in any case"
    );
    assert_eq!(pick_device(&devices, "laptop").map(|d| d.id), Ok(LAPTOP.to_owned()));
    assert!(pick_device(&devices, "bbbbbbbb").expect_err("two").contains("several"));
    assert!(pick_device(&devices, "Kitchen").expect_err("none").contains("Studio"));
    assert!(pick_device(&devices, " ").is_err());
}

#[test]
fn pick_session_takes_a_whole_id_or_one_prefix() {
    let ids = ["abc-1", "abd-2"];
    assert_eq!(pick_session(&ids, "abc-1"), Ok("abc-1".to_owned()));
    assert_eq!(pick_session(&ids, "abd"), Ok("abd-2".to_owned()));
    assert!(pick_session(&ids, "ab").expect_err("several").contains("several"));
    assert!(pick_session(&ids, "x").expect_err("none").contains("no live share"));
}
