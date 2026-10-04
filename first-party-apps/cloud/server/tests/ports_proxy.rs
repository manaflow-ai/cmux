//! `cloud.browser.open` and the proxy route: the route reaches the machine's
//! localhost only and refuses every other host, at the op and on the wire.

mod attach_common;
mod common;
mod edge_common;

use cmux_cloud::Request;
use cmux_cloud::proxy::{is_machine_host, parse_head};
use edge_common::rig;
use serde_json::json;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::time::Duration;

const FIXTURES: &[&str] = &["vm-get", "attach_endpoint_alpha"];

fn open(args: serde_json::Value, key: &str) -> Request {
    Request::new("cloud.browser.open", args).key(key)
}

fn exchange(proxy: SocketAddr, request: &[u8]) -> Vec<u8> {
    let mut tcp = TcpStream::connect(proxy).unwrap();
    tcp.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    tcp.write_all(request).unwrap();
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match tcp.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                out.extend_from_slice(&buf[..n]);
                // The echo machine answers forever on a tunnel; stop once
                // the request came back.
                if out.ends_with(b"\r\n\r\n")
                    || out.windows(4).filter(|w| w == b"\r\n\r\n").count() > 1
                {
                    break;
                }
            }
        }
    }
    out
}

#[test]
fn only_the_machine_itself_is_a_proxy_host() {
    for host in [
        "localhost",
        "LOCALHOST",
        "localhost.",
        "app.localhost",
        "127.0.0.1",
        "127.9.9.9",
        "[::1]",
        "::1",
        "::ffff:127.0.0.1",
    ] {
        assert!(is_machine_host(host), "{host}");
    }
    for host in [
        "evil.com?.localhost",
        "a/b.localhost",
        "x#.localhost",
        "a..localhost",
        "example.com",
        "10.0.0.5",
        "192.168.1.2",
        "127.0.0.1.nip.io",
        "localhost.evil.com",
        "0.0.0.0",
        "[::]",
        "169.254.169.254",
        "",
    ] {
        assert!(!is_machine_host(host), "{host}");
    }
}

#[test]
fn browser_open_returns_a_route_and_refuses_other_hosts() {
    let mut rig = rig(FIXTURES);
    let route =
        rig.server.handle(&open(json!({"machine": "vm-alpha01", "port": 3000}), "b-1")).unwrap();
    assert_eq!(route["proxy"]["kind"], "http");
    assert_eq!(route["proxy"]["host"], "127.0.0.1");
    assert_eq!(route["url"], "http://localhost:3000/");
    let again = rig
        .server
        .handle(&open(json!({"machine": "vm-alpha01", "port": 5173, "path": "/app?x=1"}), "b-2"))
        .unwrap();
    assert_eq!(again["proxy"], route["proxy"], "one route per machine");
    assert_eq!(again["url"], "http://localhost:5173/app?x=1");
    let v6 = rig
        .server
        .handle(&open(json!({"machine": "vm-alpha01", "port": 80, "host": "::1"}), "b-3"))
        .unwrap();
    assert_eq!(v6["url"], "http://[::1]:80/");
    for host in ["example.com", "10.200.0.2", "127.0.0.1.nip.io", "evil.com?.localhost"] {
        let err = rig
            .server
            .handle(&open(
                json!({"machine": "vm-alpha01", "port": 3000, "host": host}),
                &format!("b-{host}"),
            ))
            .unwrap_err();
        assert_eq!(err.code, "cmux.cloud.proxy_refused", "{host}");
    }
}

#[test]
fn the_proxy_refuses_hosts_that_are_not_the_machine_on_the_wire() {
    let mut rig = rig(FIXTURES);
    let route =
        rig.server.handle(&open(json!({"machine": "vm-alpha01", "port": 3000}), "b-1")).unwrap();
    let proxy = SocketAddr::from((
        Ipv4Addr::LOCALHOST,
        u16::try_from(route["proxy"]["port"].as_u64().unwrap()).unwrap(),
    ));
    for request in [
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
        "GET http://10.0.0.5:3000/ HTTP/1.1\r\nHost: 10.0.0.5\r\n\r\n",
        "GET http://127.0.0.1.nip.io:3000/ HTTP/1.1\r\nHost: x\r\n\r\n",
    ] {
        let answer = String::from_utf8(exchange(proxy, request.as_bytes())).unwrap();
        assert!(answer.starts_with("HTTP/1.1 403"), "{request:?} -> {answer:?}");
    }
    let origin_form =
        String::from_utf8(exchange(proxy, b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")).unwrap();
    assert!(origin_form.starts_with("HTTP/1.1 400"), "a page cannot use the route directly");
    assert!(rig.tunnel.log().opened.is_empty(), "no refused request opened a stream");

    let connect = exchange(
        proxy,
        b"CONNECT localhost:3000 HTTP/1.1\r\nHost: localhost:3000\r\n\r\nhello\r\n\r\n",
    );
    let text = String::from_utf8(connect).unwrap();
    assert!(text.starts_with("HTTP/1.1 200 Connection Established\r\n\r\n"), "{text:?}");
    let opened = rig.tunnel.log().opened.clone();
    assert_eq!((opened[0].host.as_str(), opened[0].port), ("localhost", 3000));
}

#[test]
fn absolute_form_requests_go_on_in_origin_form_without_proxy_headers() {
    let head = b"GET http://localhost:5173/src/main.ts?t=1 HTTP/1.1\r\nHost: localhost:5173\r\nProxy-Authorization: Basic eDp5\r\nProxy-Connection: keep-alive\r\nConnection: keep-alive\r\nAccept: */*\r\n\r\n";
    let target = parse_head(head).unwrap();
    assert_eq!((target.host.as_str(), target.port), ("localhost", 5173));
    let sent = String::from_utf8(target.forward_head.unwrap()).unwrap();
    assert_eq!(
        sent,
        "GET /src/main.ts?t=1 HTTP/1.1\r\nHost: localhost:5173\r\nAccept: */*\r\nConnection: close\r\n\r\n"
    );
    assert_eq!(
        parse_head(b"GET http://user:pw@localhost/ HTTP/1.1\r\n\r\n").unwrap_err().status,
        400
    );
    assert_eq!(parse_head(b"CONNECT [::1]:8443 HTTP/1.1\r\n\r\n").unwrap().port, 8443);
}
