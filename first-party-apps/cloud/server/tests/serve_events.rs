//! The serve loop wakes on link events: a link change and the forwards it
//! closes reach the host at once, with no op after the change.
//!
//! The host side of the JSON-lines channel is this test: it writes op lines,
//! answers each `relay.request` from the fixtures (through the fake control
//! plane) and reads every line the server writes. The input stays open while
//! the test waits, so only a link event can wake the loop.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use serde_json::{Value, json};
use serve_common::Host;
use std::net::{Ipv4Addr, SocketAddr, TcpStream};

const FIXTURES: &[&str] = &["vm-get"];

fn link_changed(line: &Value) -> bool {
    line["type"] == "event" && line["event"] == "cloud.link.changed"
}

/// The daemon broadcasts only a server event's `data` (`apps-server-event
/// {app, name, data}`, cmux-tui-core apps/servers.rs): every field of an
/// event line is under `data`, and the line has no other field.
fn payload(line: &Value) -> &Value {
    let keys: Vec<&str> = line.as_object().expect("object").keys().map(String::as_str).collect();
    assert_eq!(keys, ["data", "event", "type"], "only type, event and data: {line}");
    assert!(line["data"].is_object(), "the fields are under data: {line}");
    &line["data"]
}

fn port_changed(line: &Value) -> bool {
    line["type"] == "event" && line["event"] == "cloud.port.changed"
}

fn local(answer: &Value) -> SocketAddr {
    let port = u16::try_from(answer["localPort"].as_u64().expect("localPort")).expect("u16");
    SocketAddr::from((Ipv4Addr::LOCALHOST, port))
}

#[test]
fn a_link_exit_reaches_the_host_with_no_op_after_it() {
    let mut host = Host::start(FIXTURES);
    let carrier = host.op("1", "cloud.machine.connect", json!({"machine": "vm-alpha01"}), "c-1");
    assert_eq!(carrier["state"], "up");
    // Read the op's own lines up to its `up` line, however late they come.
    // The loop pumps the link before it sends that line and never after it
    // in the same pass, so an exit after it cannot ride on the op's drain.
    loop {
        let line = host.next().expect("the up line of the connect");
        if link_changed(&line) && payload(&line)["state"] == "up" {
            break;
        }
    }
    host.spawner.exit("vm-alpha01", 1);
    let line = host.next().expect("a cloud.link.changed line with no op after the link exit");
    assert!(link_changed(&line), "{line}");
    let data = payload(&line);
    assert_eq!(data["machine"], "vm-alpha01");
    assert_eq!(data["state"], "down");
    assert_eq!(data["generation"], 1);
    assert_eq!(data["retryable"], true);
}

#[test]
fn a_forward_on_a_dead_link_closes_with_no_op_after_the_death() {
    let mut host = Host::start(FIXTURES);
    let forward =
        host.op("1", "cloud.port.forward", json!({"machine": "vm-alpha01", "port": 3000}), "f-1");
    let addr = local(&forward);
    TcpStream::connect(addr).expect("the forward listens while the link is up");

    host.spawner.exit("vm-alpha01", 1);
    // The loop closes the listener (and joins its accept thread) before it
    // sends the line, so one connect after the line is a deterministic check.
    let mut lines = Vec::new();
    let down = loop {
        let line = host.next().unwrap_or_else(|| {
            panic!("no cloud.port.changed line arrived with no op after the death: {lines:?}")
        });
        if port_changed(&line) {
            break line;
        }
        lines.push(line);
    };
    assert!(TcpStream::connect(addr).is_err(), "the listener of a dead link is closed");
    let down = payload(&down);
    assert_eq!(down["machine"], "vm-alpha01");
    assert_eq!(down["port"], 3000);
    assert_eq!(down["localPort"], forward["localPort"]);
    assert_eq!(down["state"], "down");
}

#[test]
fn the_events_of_one_link_death_keep_their_order() {
    let mut host = Host::start(FIXTURES);
    let first =
        host.op("1", "cloud.port.forward", json!({"machine": "vm-alpha01", "port": 3000}), "f-1");
    let second =
        host.op("2", "cloud.port.forward", json!({"machine": "vm-alpha01", "port": 5173}), "f-2");

    host.spawner.exit("vm-alpha01", 1);
    let mut lines = Vec::new();
    while lines.len() < 3 {
        let line = host.next().unwrap_or_else(|| panic!("three lines with no op: {lines:?}"));
        lines.push(line);
    }
    // The cause first, then each forward it closed, in port order.
    assert!(link_changed(&lines[0]) && payload(&lines[0])["state"] == "down", "{lines:?}");
    assert!(port_changed(&lines[1]) && payload(&lines[1])["port"] == 3000, "{lines:?}");
    assert_eq!(payload(&lines[1])["localPort"], first["localPort"]);
    assert!(port_changed(&lines[2]) && payload(&lines[2])["port"] == 5173, "{lines:?}");
    assert_eq!(payload(&lines[2])["localPort"], second["localPort"]);
    // Each change goes out once: an op after it repeats none of them.
    let lines = host.answer_of("3", "cloud.port.list", json!({}));
    assert!(lines.iter().all(|l| !link_changed(l) && !port_changed(l)), "{lines:?}");
}
