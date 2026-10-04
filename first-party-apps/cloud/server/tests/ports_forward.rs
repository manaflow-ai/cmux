//! `cloud.port.*`: forwards listen on 127.0.0.1 only, one per (machine,
//! port), carry bytes through the link, and close when the link goes down
//! with nothing queued for a later link. Listeners are 127.0.0.1 only and
//! close at the end of each test (the server drops them).

mod attach_common;
mod common;
mod edge_common;

use cmux_cloud::Request;
use edge_common::rig;
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::time::Duration;

const FIXTURES: &[&str] = &["vm-get", "attach_endpoint_alpha"];

fn forward(port: u16, key: &str) -> Request {
    Request::new("cloud.port.forward", json!({"machine": "vm-alpha01", "port": port})).key(key)
}

fn local(answer: &Value) -> SocketAddr {
    let port = u16::try_from(answer["localPort"].as_u64().unwrap()).unwrap();
    SocketAddr::from((Ipv4Addr::LOCALHOST, port))
}

fn echo(addr: SocketAddr, text: &[u8]) -> Vec<u8> {
    let mut tcp = TcpStream::connect(addr).unwrap();
    tcp.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    tcp.write_all(text).unwrap();
    let mut back = vec![0u8; text.len()];
    tcp.read_exact(&mut back).unwrap();
    back
}

#[test]
fn a_forward_binds_127_0_0_1_only_and_carries_bytes_through_the_link() {
    let mut rig = rig(FIXTURES);
    let answer = rig.server.handle(&forward(3000, "f-1")).unwrap();
    assert_eq!(answer["host"], "127.0.0.1");
    assert_eq!(answer["state"], "up");
    let addr = local(&answer);
    assert_ne!(addr.port(), 3000, "a random local port, not the machine's");
    assert_eq!(echo(addr, b"ping"), b"ping");
    let opened = rig.tunnel.log().opened.clone();
    assert_eq!(opened.len(), 1);
    assert_eq!((opened[0].host.as_str(), opened[0].port), ("localhost", 3000));
    assert_eq!(opened[0].carrier, "cloud-vm/vm-alpha01#1");
    // Not on any other address of this machine.
    for other in non_loopback_addresses() {
        let target = SocketAddr::new(other, addr.port());
        assert!(
            TcpStream::connect_timeout(&target, Duration::from_millis(500)).is_err(),
            "the forward must not answer on {target}"
        );
    }
}

/// This host's non-loopback IPv4 addresses (from the routing choice for an
/// outside address; no packet is sent).
fn non_loopback_addresses() -> Vec<std::net::IpAddr> {
    let socket = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).unwrap();
    match socket.connect(("192.0.2.1", 9)).and_then(|()| socket.local_addr()) {
        Ok(addr) if !addr.ip().is_loopback() && !addr.ip().is_unspecified() => vec![addr.ip()],
        _ => Vec::new(),
    }
}

#[test]
fn a_second_forward_for_the_same_machine_and_port_returns_the_same_local_port() {
    let mut rig = rig(FIXTURES);
    let first = rig.server.handle(&forward(5173, "f-1")).unwrap();
    let second = rig.server.handle(&forward(5173, "f-2")).unwrap();
    assert_eq!(first["localPort"], second["localPort"]);
    let other = rig.server.handle(&forward(8080, "f-3")).unwrap();
    assert_ne!(first["localPort"], other["localPort"]);
    assert_eq!(rig.spawner.spawns(), 1, "one link for the machine");
    let list = rig.server.handle(&Request::new("cloud.port.list", json!({}))).unwrap();
    assert_eq!(list["forwards"].as_array().unwrap().len(), 2);
}

#[test]
fn link_down_marks_forwards_down_and_a_later_connect_does_not_resurrect_bytes() {
    let mut rig = rig(FIXTURES);
    let first = rig.server.handle(&forward(3000, "f-1")).unwrap();
    let old = local(&first);
    assert_eq!(echo(old, b"before"), b"before");
    let mut open = TcpStream::connect(old).unwrap();
    open.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    open.write_all(b"x").unwrap();
    let mut one = [0u8; 1];
    open.read_exact(&mut one).unwrap();

    rig.spawner.exit("vm-alpha01", 1);
    let list = rig.server.handle(&Request::new("cloud.port.list", json!({}))).unwrap();
    assert_eq!(list["forwards"][0]["state"], "down");
    assert!(list["forwards"][0]["reason"].as_str().unwrap().contains("down"));
    // The open connection was ended, and the old port takes no new one.
    let mut rest = Vec::new();
    let _ = open.read_to_end(&mut rest);
    let _ = open.write_all(b"lost-after-down");
    assert!(TcpStream::connect(old).is_err(), "the old listener is closed");

    let again = rig.server.handle(&forward(3000, "f-2")).unwrap();
    assert_eq!(again["state"], "up");
    assert_eq!(again["generation"], 2, "a new link");
    assert_eq!(echo(local(&again), b"after"), b"after");
    let received = String::from_utf8(rig.tunnel.all_received()).unwrap();
    assert!(!received.contains("lost-after-down"), "nothing queued for the new link: {received}");
    assert_eq!(received, "beforexafter");
}

#[test]
fn close_ends_the_listener_and_forward_needs_a_key_and_a_valid_port() {
    let mut rig = rig(FIXTURES);
    let answer = rig.server.handle(&forward(3000, "f-1")).unwrap();
    let addr = local(&answer);
    let close = Request::new("cloud.port.close", json!({"machine": "vm-alpha01", "port": 3000}));
    let closed = rig.server.handle(&close.clone().key("c-1")).unwrap();
    assert_eq!(closed["closed"], true);
    assert!(TcpStream::connect(addr).is_err());
    assert_eq!(rig.server.handle(&close.key("c-2")).unwrap()["closed"], false);
    let unkeyed =
        Request::new("cloud.port.forward", json!({"machine": "vm-alpha01", "port": 3000}));
    assert_eq!(
        rig.server.handle(&unkeyed).unwrap_err().code,
        "cmux.cloud.idempotency_key_required"
    );
    for bad in [json!(0), json!(65_536), json!("3000"), json!(-1)] {
        let req = Request::new("cloud.port.forward", json!({"machine": "vm-alpha01", "port": bad}))
            .key("f-bad");
        assert_eq!(rig.server.handle(&req).unwrap_err().code, "cmux.cloud.invalid_args");
    }
}

#[test]
fn a_dead_tunnel_closes_the_connection_and_queues_nothing() {
    let mut rig = rig(FIXTURES);
    let answer = rig.server.handle(&forward(3000, "f-1")).unwrap();
    rig.tunnel.log().down = true;
    let mut tcp = TcpStream::connect(local(&answer)).unwrap();
    tcp.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let _ = tcp.write_all(b"queued?");
    let mut buf = Vec::new();
    let _ = tcp.read_to_end(&mut buf);
    assert!(buf.is_empty());
    rig.tunnel.log().down = false;
    assert_eq!(echo(local(&answer), b"next"), b"next");
    assert_eq!(rig.tunnel.all_received(), b"next", "the refused bytes went nowhere");
}
