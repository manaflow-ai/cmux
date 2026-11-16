//! `cloud.machine.board`, the team board's one read (webviews/src/pages/board): the
//! platform's answer reaches the page as it came, and a relay or backend error maps the
//! way every other read's does.

mod wire_common;

use cmux_cloud::{CloudError, Request, Server};
use serde_json::{Value, json};
use wire_common::{WireFake, vm};

const OP: &str = "cloud.machine.board";
const ME: &str = "user_a0000000000000000001";

fn server() -> Server<WireFake> {
    Server::new(WireFake::load())
}

fn err_json(out: Result<Value, CloudError>) -> Value {
    match out {
        Ok(v) => json!({ "unexpected_ok": v }),
        Err(e) => serde_json::to_value(&e).expect("error"),
    }
}

/// A board as the platform answers it, with fields the catalog does not name at every level.
fn board() -> Value {
    json!({
        "machines": [
            { "id": vm(1), "creator": ME, "state": "running", "createdAt": 1_790_000_000_000i64,
              "cost": { "hourlyUsd": 0.12, "totalUsd": 3.5 }, "origin": { "kind": "lane", "label": "lane one-board" } },
            { "id": vm(2), "creator": "user_b0000000000000000002", "state": "paused", "present": [] },
        ],
        "usage": { "since": 1, "until": 2, "knownCostUsd": 3.5, "totalCostUsd": null,
                   "byCreator": [], "byStartedBy": [], "byMachine": [] },
        "audit": [{ "at": 5, "target": "machine", "targetId": vm(1), "creator": ME, "actor": ME,
                    "actorKind": "person", "action": "start", "result": "ok" }],
        "members": [{ "user": ME, "name": "Ada", "email": "ada@example.com" }],
        "self": ME,
        "newer_field": { "kept": true },
    })
}

#[test]
fn the_board_passes_through_as_the_platform_answered_it() {
    let mut s = server();
    s.control_plane_mut().answer(OP, json!({}), None, board());
    let out = s.handle(&Request::new(OP, json!({}))).expect("board");
    assert_eq!(out, board(), "every field of every record reaches the page");
    let calls = &s.control_plane().calls;
    assert_eq!(calls.len(), 1, "{calls:?}");
    assert_eq!((calls[0].op.as_str(), &calls[0].params), (OP, &json!({})));
    assert_eq!(calls[0].idempotency_key, None, "a read carries no key");
    // The page's full name and a null member list (the caller may not read them) work too.
    let mut hidden = board();
    hidden["members"] = Value::Null;
    s.control_plane_mut().answer(OP, json!({}), None, hidden.clone());
    assert_eq!(
        s.handle(&Request::new("cmux.cloud.machine.board", json!({}))).expect("board"),
        hidden
    );
}

#[test]
fn the_board_is_a_read_with_no_args() {
    let mut s = server();
    let keyed = err_json(s.handle(&Request::new(OP, json!({})).key("k1")));
    assert_eq!(keyed["code"], "cmux.cloud.idempotency_key_forbidden", "{keyed}");
    let extra = err_json(s.handle(&Request::new(OP, json!({ "team": "t" }))));
    assert_eq!(extra["code"], "cmux.cloud.invalid_args", "{extra}");
    assert!(s.control_plane().calls.is_empty(), "nothing reached the backend");
}

#[test]
fn a_relay_error_maps_like_every_other_read() {
    // The same failure on `cloud.plan.get` and on the board answers the same error.
    let fails = |op: &str, set: fn(&mut WireFake)| {
        let mut s = server();
        set(s.control_plane_mut());
        let mut error = err_json(s.handle(&Request::new(op, json!({}))));
        error.as_object_mut().expect("error").remove("message");
        error
    };
    let cases: [(&str, fn(&mut WireFake)); 2] = [
        ("cmux.cloud.relay_unavailable", |fake| fake.fail_next = 1),
        ("cmux.cloud.auth_required", |fake| fake.signed_in = false),
    ];
    for (code, set) in cases {
        let board = fails(OP, set);
        assert_eq!(board["code"], code, "{board}");
        assert_eq!(board, fails("cloud.plan.get", set), "{code}");
    }
    let mut s = server();
    s.control_plane_mut().fail_next = 1;
    let out = err_json(s.handle(&Request::new(OP, json!({}))));
    assert_eq!(out["retryable"], true, "a relay that did not answer may be asked again: {out}");
}

#[test]
fn a_backend_refusal_is_typed_and_a_broken_answer_is_bad_response() {
    let mut s = server();
    let refusal = json!({ "error": { "code": "auth.forbidden", "message": "not on this team" } });
    s.control_plane_mut().answer(OP, json!({}), None, refusal);
    let forbidden = err_json(s.handle(&Request::new(OP, json!({}))));
    assert_eq!(forbidden["code"], "cmux.cloud.forbidden", "{forbidden}");
    assert_eq!(forbidden["upstream_code"], "auth.forbidden");

    let mut broken = board();
    broken.as_object_mut().expect("board").remove("self");
    s.control_plane_mut().answer(OP, json!({}), None, broken);
    let bad = err_json(s.handle(&Request::new(OP, json!({}))));
    assert_eq!(bad["code"], "cmux.cloud.bad_response", "{bad}");
}
