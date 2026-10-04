//! The JSON-lines host relay: requests carry no credential, answers are
//! matched by id, and op lines that arrive during a call wait their turn.

use cmux_cloud::api::HostRelay;
use cmux_cloud::{ControlPlane, HttpCall, RelayError};
use serde_json::{Value, json};
use std::io::Cursor;

fn call() -> HttpCall {
    HttpCall {
        op: "cloud.machine.create".into(),
        method: "POST",
        path: "/api/vm".into(),
        body: Some(json!({})),
        idempotency_key: Some("k-1".into()),
    }
}

#[test]
fn a_call_goes_out_without_credentials_and_queues_op_lines() {
    let input = concat!(
        "{\"type\":\"op\",\"id\":\"7\",\"op\":\"cloud.machine.list\"}\n",
        "{\"type\":\"relay.response\",\"id\":\"r9\",\"status\":500}\n",
        "{\"type\":\"relay.response\",\"id\":\"r1\",\"status\":200,\"body\":{\"id\":\"vm-1\"}}\n",
    );
    let mut out = Vec::new();
    let mut relay = HostRelay::new(Cursor::new(input), &mut out);
    let reply = relay.call(&call()).expect("reply");
    assert_eq!(reply.status, 200, "a stray answer with another id is ignored");
    assert_eq!(reply.body, json!({ "id": "vm-1" }));
    let queued = relay.next_message().expect("io").expect("queued op");
    assert_eq!(queued["id"], "7");
    assert!(relay.next_message().expect("io").is_none());
    drop(relay);
    let sent: Value =
        serde_json::from_slice(out.split(|b| *b == b'\n').next().expect("line")).expect("JSON");
    assert_eq!(sent["type"], "relay.request");
    assert_eq!(sent["idempotency_key"], "k-1");
    let keys: Vec<&str> = sent.as_object().expect("object").keys().map(String::as_str).collect();
    for key in keys {
        assert!(
            ["type", "id", "op", "method", "path", "body", "idempotency_key"].contains(&key),
            "{key}"
        );
    }
}

#[test]
fn not_signed_in_and_a_closed_channel_are_typed() {
    let input = "{\"type\":\"relay.error\",\"id\":\"r1\",\"code\":\"not_signed_in\"}\n";
    let mut relay = HostRelay::new(Cursor::new(input), Vec::new());
    assert_eq!(relay.call(&call()), Err(RelayError::NotSignedIn));
    assert!(matches!(relay.call(&call()), Err(RelayError::Unavailable(_))));
}

#[test]
fn session_status_comes_from_the_host() {
    let input = "{\"type\":\"relay.session\",\"id\":\"r1\",\"signed_in\":true,\"team\":\"t-1\"}\n";
    let mut relay = HostRelay::new(Cursor::new(input), Vec::new());
    let status = relay.session().expect("status");
    assert!(status.signed_in);
    assert_eq!(status.team.as_deref(), Some("t-1"));
}
