//! Link details from the host-only op `cmux.host.link.get` and the event
//! `cmux.host.link.changed`, over the server's JSON-lines channel. One
//! frame shape for every host-only op:
//! `{"t":"host.request","id":n,"op","params"}`, answered by
//! `{"t":"host.result","id":n,"value"}` or
//! `{"t":"host.error","id":n,"code","message","retryable"}`; events are
//! `{"t":"host.event","op","data"}`. Connect answers `link_unavailable`
//! until the details came.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::{FakeSpawner, FakeTransport};
use cmux_cloud::link::Attach;
use cmux_cloud::ports::Edge;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use serve_common::Host;
use std::sync::Arc;

const FIXTURES: &[&str] = &["vm-get"];

/// A server whose host has not given link details yet.
fn host() -> Host {
    let spawner = FakeSpawner::default();
    let attach = Attach::new(Box::new(spawner.clone()), None, Box::new(FakeTransport::default()))
        .with_env(attach_common::test_env());
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()));
    Host::start_with(FIXTURES, spawner, attach, edge)
}

fn details(binary: &str) -> Value {
    json!({
        "binary": binary,
        "hub_socket": "/tmp/cmux-test/wg-hub.sock",
        "state_dir": "/tmp/cmux-test/link-state",
        "socket_dir": "/tmp/cmux-test",
        "device_name": "test-mac",
    })
}

fn is_request(line: &Value) -> bool {
    line["t"] == "host.request"
}

/// The first line: the one `link.get` request, read exactly.
fn link_get(host: &mut Host) -> Value {
    let line = host.next();
    let expected =
        json!({ "t": "host.request", "id": 1, "op": "cmux.host.link.get", "params": {} });
    assert_eq!(line.as_ref(), Some(&expected), "the first line asks for the link details");
    line.unwrap_or(expected)
}

fn connect(host: &mut Host, id: &str) -> Value {
    host.result(id, "cloud.machine.connect", json!({ "machine": "vm-alpha01" }), Some(id))
}

/// Lines up to the result of op `id`, plus whether a host request came.
fn connect_lines(host: &mut Host, id: &str) -> (Value, Vec<Value>) {
    host.send(&json!({ "type": "op", "id": id, "op": "cloud.machine.connect",
        "args": { "machine": "vm-alpha01" }, "origin": "user", "idempotency_key": id }));
    let mut lines = host.answer(id);
    let result = lines.pop().expect("result");
    (result, lines)
}

#[test]
fn the_host_frames_have_one_shape_for_request_result_error_and_event() {
    let mut host = host();
    let request = link_get(&mut host);
    assert_eq!(request["id"], 1);
    host.send(&json!({ "t": "host.result", "id": 1, "value": details("/opt/cmux/bin/cmux-tui") }));
    let up = connect(&mut host, "c-1");
    assert_eq!(up["ok"], true, "{up}");
    // An answer to no waiting request and a frame of unknown kind get no line.
    host.send(&json!({ "t": "host.result", "id": 99, "value": {} }));
    host.send(
        &json!({ "t": "host.error", "id": 98, "code": "x", "message": "y", "retryable": true }),
    );
    let read = host.result("r-1", "cloud.port.list", json!({}), None);
    assert_eq!(read["ok"], true, "the loop still serves ops: {read}");
}

#[test]
fn connect_waits_for_link_get_and_then_spawns_with_the_hosts_binary() {
    let mut host = host();
    link_get(&mut host);
    let early = connect(&mut host, "c-1");
    assert_eq!(early["ok"], false);
    assert_eq!(early["error"]["code"], "cmux.cloud.link_unavailable", "{early}");
    assert_eq!(host.spawner.spawns(), 0);
    host.send(&json!({ "t": "host.result", "id": 1, "value": details("/opt/cmux/v2/cmux-tui") }));
    let up = connect(&mut host, "c-2");
    assert_eq!(up["ok"], true, "{up}");
    assert_eq!(host.spawner.spawns(), 1);
    let binary = host.spawner.log().commands[0].binary.clone();
    assert_eq!(binary, std::path::PathBuf::from("/opt/cmux/v2/cmux-tui"));
}

#[test]
fn a_bad_answer_is_a_typed_error_and_nothing_spawns() {
    for bad in [
        details("bin/cmux-tui"),
        json!({ "binary": "/opt/cmux/bin/cmux-tui", "hub_socket": "hub.sock",
            "state_dir": "/tmp/s", "socket_dir": "/tmp", "device_name": "mac" }),
        json!({ "binary": "/opt/cmux/bin/cmux-tui", "hub_socket": "/tmp/hub.sock",
            "state_dir": "/tmp/s", "socket_dir": "/tmp", "device_name": "" }),
        json!({ "binary": "/opt/cmux/bin/cmux-tui", "hub_socket": "/tmp/hub.sock",
            "state_dir": "/tmp/s", "socket_dir": "/tmp", "device_name": "mac\u{7}" }),
        json!({ "binary": "/opt/cmux/bin/cmux-tui" }),
        json!({ "binary": "/opt/cmux/bin/cmux-tui", "hub_socket": "/tmp/hub.sock",
            "state_dir": "/tmp/s", "socket_dir": "/tmp", "device_name": "--carrier" }),
        json!({ "binary": "/opt/cmux/../bin/cmux-tui", "hub_socket": "/tmp/hub.sock",
            "state_dir": "/tmp/s", "socket_dir": "/tmp", "device_name": "mac" }),
    ] {
        let mut host = host();
        link_get(&mut host);
        host.send(&json!({ "t": "host.result", "id": 1, "value": bad }));
        let answer = connect(&mut host, "c-1");
        assert_eq!(answer["error"]["code"], "cmux.cloud.link_details_invalid", "{bad}: {answer}");
        assert_eq!(host.spawner.spawns(), 0, "{bad}: never a partial config");
    }
}

#[test]
fn link_changed_respawns_the_live_link_with_the_new_details() {
    let mut host = host();
    link_get(&mut host);
    host.send(&json!({ "t": "host.result", "id": 1, "value": details("/opt/cmux/v1/cmux-tui") }));
    let up = connect(&mut host, "c-1");
    assert_eq!(up["result"]["generation"], 1, "{up}");
    // Drop the connect's own `up` line.
    while let Some(line) = host.next() {
        if line["event"] == "cloud.link.changed" && line["state"] == "up" {
            break;
        }
    }
    host.send(&json!({ "t": "host.event", "op": "cmux.host.link.changed",
        "data": details("/opt/cmux/v2/cmux-tui") }));
    let down = host.next();
    let new_up = host.next();
    let state = |line: &Option<Value>| {
        (line.as_ref().map(|l| l["state"].clone()), line.as_ref().map(|l| l["generation"].clone()))
    };
    assert_eq!(state(&down), (Some(json!("down")), Some(json!(1))), "{down:?}");
    assert_eq!(state(&new_up), (Some(json!("up")), Some(json!(2))), "{new_up:?}");
    let log = host.spawner.log();
    assert_eq!(log.commands.len(), 2, "one respawn");
    assert_eq!(log.commands[1].binary, std::path::PathBuf::from("/opt/cmux/v2/cmux-tui"));
    assert_eq!(log.terminated.len(), 1, "the old link process ended");
}

#[test]
fn a_retryable_host_error_is_retried_once_on_the_next_connect() {
    let mut host = host();
    link_get(&mut host);
    host.send(&json!({ "t": "host.error", "id": 1, "code": "cmux.host.busy",
        "message": "the supervisor is starting", "retryable": true }));
    let (first, before) = connect_lines(&mut host, "c-1");
    assert!(before.iter().all(|l| !is_request(l)), "no request before the connect: {before:?}");
    assert_eq!(first["error"]["code"], "cmux.cloud.link_unavailable", "{first}");
    assert_eq!(first["error"]["retryable"], true, "{first}");
    let retry = host.next();
    let expected =
        json!({ "t": "host.request", "id": 2, "op": "cmux.host.link.get", "params": {} });
    assert_eq!(retry, Some(expected), "one new request after that connect");
    // While the retry waits, a connect sends no third request.
    let (second, around) = connect_lines(&mut host, "c-2");
    assert_eq!(second["error"]["code"], "cmux.cloud.link_unavailable", "{second}");
    assert!(around.iter().all(|l| !is_request(l)), "{around:?}");
    host.send(&json!({ "t": "host.result", "id": 2, "value": details("/opt/cmux/bin/cmux-tui") }));
    let up = connect(&mut host, "c-3");
    assert_eq!(up["ok"], true, "{up}");
}

#[test]
fn a_final_host_error_is_link_unavailable_with_the_hosts_code() {
    let mut host = host();
    link_get(&mut host);
    host.send(&json!({ "t": "host.error", "id": 1, "code": "cmux.host.link.not_installed",
        "message": "cmux link is not installed", "retryable": false }));
    for id in ["c-1", "c-2"] {
        let (answer, before) = connect_lines(&mut host, id);
        assert_eq!(answer["error"]["code"], "cmux.cloud.link_unavailable", "{answer}");
        assert_eq!(answer["error"]["upstream_code"], "cmux.host.link.not_installed", "{answer}");
        assert_eq!(answer["error"]["retryable"], false, "{answer}");
        assert!(before.iter().all(|l| !is_request(l)), "never a retry: {before:?}");
    }
    let read = host.result("r-1", "cloud.port.list", json!({}), None);
    assert_eq!(read["ok"], true, "no retry request came before this answer either: {read}");
    assert_eq!(host.spawner.spawns(), 0);
}

/// The details with no live `cmux link`: the supervisor sends a null hub.
fn no_hub() -> Value {
    let mut value = details("/opt/cmux/bin/cmux-tui");
    value["hub_socket"] = Value::Null;
    value
}

#[test]
fn a_null_hub_socket_is_link_unavailable_and_nothing_spawns() {
    let mut host = host();
    link_get(&mut host);
    host.send(&json!({ "t": "host.result", "id": 1, "value": no_hub() }));
    let answer = connect(&mut host, "c-1");
    assert_eq!(answer["error"]["code"], "cmux.cloud.link_unavailable", "{answer}");
    assert_eq!(answer["error"]["retryable"], true, "a later link.changed may bring the hub");
    assert_eq!(host.spawner.spawns(), 0);
}

#[test]
fn a_link_changed_with_a_hub_lets_the_next_connect_spawn() {
    let mut host = host();
    link_get(&mut host);
    host.send(&json!({ "t": "host.result", "id": 1, "value": no_hub() }));
    let early = connect(&mut host, "c-1");
    assert_eq!(early["error"]["code"], "cmux.cloud.link_unavailable", "{early}");
    host.send(&json!({ "t": "host.event", "op": "cmux.host.link.changed",
        "data": details("/opt/cmux/bin/cmux-tui") }));
    let up = connect(&mut host, "c-2");
    assert_eq!(up["ok"], true, "{up}");
    assert_eq!(host.spawner.spawns(), 1);
}

#[test]
fn a_link_changed_back_to_a_null_hub_ends_the_live_link() {
    let mut host = host();
    link_get(&mut host);
    host.send(&json!({ "t": "host.result", "id": 1, "value": details("/opt/cmux/bin/cmux-tui") }));
    let up = connect(&mut host, "c-1");
    assert_eq!(up["ok"], true, "{up}");
    while let Some(line) = host.next() {
        if line["event"] == "cloud.link.changed" && line["state"] == "up" {
            break;
        }
    }
    host.send(&json!({ "t": "host.event", "op": "cmux.host.link.changed", "data": no_hub() }));
    let down = host.next();
    assert_eq!(
        down.as_ref().map(|l| (l["event"].clone(), l["state"].clone(), l["generation"].clone())),
        Some((json!("cloud.link.changed"), json!("down"), json!(1))),
        "the live link ends when the hub goes away: {down:?}"
    );
    assert_eq!(host.spawner.log().terminated.len(), 1, "its process ended");
    let again = connect(&mut host, "c-2");
    assert_eq!(again["error"]["code"], "cmux.cloud.link_unavailable", "{again}");
    assert_eq!(host.spawner.spawns(), 1, "no new link without a hub");
}

#[test]
fn a_late_link_get_answer_never_replaces_newer_link_changed_details() {
    let mut host = host();
    link_get(&mut host);
    host.send(&json!({ "t": "host.event", "op": "cmux.host.link.changed",
        "data": details("/opt/cmux/v2/cmux-tui") }));
    host.send(&json!({ "t": "host.result", "id": 1, "value": details("/opt/cmux/v1/cmux-tui") }));
    let up = connect(&mut host, "c-1");
    assert_eq!(up["ok"], true, "{up}");
    let binary = host.spawner.log().commands[0].binary.clone();
    assert_eq!(binary, std::path::PathBuf::from("/opt/cmux/v2/cmux-tui"), "the newer details win");
}

#[test]
fn a_malformed_answer_ends_the_request_with_a_typed_error() {
    let mut host = host();
    link_get(&mut host);
    host.send(&json!({ "t": "host.result", "id": 1 }));
    let answer = connect(&mut host, "c-1");
    assert_eq!(answer["error"]["code"], "cmux.cloud.link_unavailable", "{answer}");
    assert_eq!(answer["error"]["upstream_code"], "cmux.cloud.host_answer_invalid", "{answer}");
    assert_eq!(host.spawner.spawns(), 0);
}
