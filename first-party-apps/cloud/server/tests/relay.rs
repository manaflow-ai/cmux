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

#[test]
fn an_op_then_eof_during_a_call_is_unavailable_and_the_op_stays_queued() {
    let input = "{\"type\":\"op\",\"id\":\"1\",\"op\":\"cloud.machine.list\"}\n";
    let mut relay = HostRelay::new(Cursor::new(input), Vec::new());
    assert!(matches!(relay.call(&call()), Err(RelayError::Unavailable(_))));
    assert_eq!(relay.next_message().expect("io").expect("queued")["id"], "1");
}

#[test]
fn a_line_that_is_not_utf8_is_invalid_not_fatal() {
    let mut input = b"\xff\xfe not json\n".to_vec();
    input.extend_from_slice(b"{\"type\":\"op\",\"id\":\"2\"}\n");
    let mut relay = HostRelay::new(Cursor::new(input), Vec::new());
    assert_eq!(relay.next_message().expect("io").expect("line")["type"], "invalid");
    assert_eq!(relay.next_message().expect("io").expect("line")["id"], "2");
}

/// The lines the server wrote, parsed.
fn written(out: &[u8]) -> Vec<Value> {
    out.split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_slice(l).expect("JSON line"))
        .collect()
}

#[test]
fn op_lines_beyond_the_queue_bound_get_relay_busy_and_the_rest_keep_their_order() {
    use cmux_cloud::api::RELAY_QUEUE_LINES;
    let total = RELAY_QUEUE_LINES + 1;
    let mut input = String::new();
    for n in 1..=total {
        input.push_str(&format!(
            "{{\"type\":\"op\",\"id\":\"{n}\",\"op\":\"cloud.machine.list\"}}\n"
        ));
    }
    input.push_str("{\"type\":\"relay.response\",\"id\":\"r1\",\"status\":200,\"body\":{}}\n");
    let mut out = Vec::new();
    let mut relay = HostRelay::new(Cursor::new(input), &mut out);
    assert_eq!(relay.call(&call()).expect("reply").status, 200);
    let mut kept = Vec::new();
    while let Some(message) = relay.next_message().expect("io") {
        kept.push(message["id"].as_str().expect("id").to_owned());
    }
    drop(relay);
    let expected: Vec<String> = (1..=RELAY_QUEUE_LINES).map(|n| n.to_string()).collect();
    assert_eq!(kept, expected, "the first {RELAY_QUEUE_LINES} op lines run, in order");
    let busy: Vec<Value> = written(&out).into_iter().filter(|l| l["type"] == "result").collect();
    assert_eq!(busy.len(), 1, "exactly one op is answered at once: {busy:?}");
    assert_eq!(busy[0]["id"], total.to_string());
    assert_eq!(busy[0]["ok"], false);
    assert_eq!(busy[0]["error"]["code"], "cmux.cloud.relay_busy");
    assert_eq!(busy[0]["error"]["retryable"], true);
}

#[test]
fn host_events_during_a_call_keep_only_the_newest_of_each_op() {
    let mut input = String::new();
    for n in 0..(cmux_cloud::api::RELAY_QUEUE_LINES * 2) {
        input.push_str(&format!(
            "{{\"t\":\"host.event\",\"op\":\"cmux.host.link.changed\",\"data\":{{\"n\":{n}}}}}\n"
        ));
    }
    input.push_str("{\"type\":\"relay.response\",\"id\":\"r1\",\"status\":200,\"body\":{}}\n");
    let mut relay = HostRelay::new(Cursor::new(input), Vec::new());
    assert_eq!(relay.call(&call()).expect("reply").status, 200);
    let first = relay.next_message().expect("io").expect("the newest event");
    assert_eq!(first["data"]["n"], cmux_cloud::api::RELAY_QUEUE_LINES * 2 - 1);
    assert!(relay.next_message().expect("io").is_none(), "older events of the op were replaced");
}

#[test]
fn unknown_host_frames_during_a_call_are_dropped_and_host_answers_are_bounded() {
    let mut input = String::new();
    input.push_str("{\"t\":\"host.mystery\",\"op\":\"x\"}\n");
    for n in 0..(cmux_cloud::api::RELAY_QUEUE_LINES + 10) {
        input.push_str(&format!("{{\"t\":\"host.result\",\"id\":{n},\"value\":{{}}}}\n"));
    }
    input.push_str("{\"type\":\"relay.response\",\"id\":\"r1\",\"status\":200,\"body\":{}}\n");
    let mut relay = HostRelay::new(Cursor::new(input), Vec::new());
    assert_eq!(relay.call(&call()).expect("reply").status, 200);
    let mut kept = 0;
    while let Some(message) = relay.next_message().expect("io") {
        assert_eq!(message["t"], "host.result", "{message}");
        kept += 1;
    }
    assert_eq!(kept, cmux_cloud::api::RELAY_QUEUE_LINES);
}
