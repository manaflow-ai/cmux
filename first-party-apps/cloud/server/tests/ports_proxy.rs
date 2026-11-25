//! `cloud.browser.open` and the proxy route: the route reaches the machine's
//! localhost only and refuses every other host, at the op and on the wire.

mod attach_common;
mod common;
mod edge_common;

use cmux_cloud::Request;
use cmux_cloud::proxy::{is_machine_host, parse_head};
use edge_common::rig;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::time::Duration;

const FIXTURES: &[&str] = &["vm-get"];

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

fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut key_block = [0u8; 64];
    if key.len() > key_block.len() {
        key_block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }
    let mut inner_pad = [0x36u8; 64];
    let mut outer_pad = [0x5cu8; 64];
    for index in 0..key_block.len() {
        inner_pad[index] ^= key_block[index];
        outer_pad[index] ^= key_block[index];
    }
    let inner = Sha256::new().chain_update(inner_pad).chain_update(message).finalize();
    Sha256::new().chain_update(outer_pad).chain_update(inner).finalize().into()
}

fn proxy_authorization(route: &serde_json::Value, authority: &str) -> (String, String) {
    let username = route["proxy"]["username"].as_str().expect("proxy username");
    let password = route["proxy"]["password"].as_str().expect("proxy password");
    let nonce = "00".repeat(32);
    let client = format!("cmux-client-v1\n{nonce}\n{authority}");
    let server = format!("cmux-server-v1\n{nonce}\n{authority}");
    let hex =
        |digest: [u8; 32]| digest.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    (
        format!(
            "CMUX {username}:{nonce}:{}",
            hex(hmac_sha256(password.as_bytes(), client.as_bytes()))
        ),
        hex(hmac_sha256(password.as_bytes(), server.as_bytes())),
    )
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
    assert!(route["proxy"]["username"].as_str().is_some_and(|value| !value.is_empty()));
    assert!(route["proxy"]["password"].as_str().is_some_and(|value| value.len() >= 64));
    assert!(route["incarnation"].as_u64().is_some_and(|value| value > 0));
    assert_eq!(route["url"], "http://localhost:3000/");
    let again = rig
        .server
        .handle(&open(json!({"machine": "vm-alpha01", "port": 5173, "path": "/app?x=1"}), "b-2"))
        .unwrap();
    assert_eq!(again["proxy"], route["proxy"], "one route per machine");
    assert_eq!(again["incarnation"], route["incarnation"], "one server process incarnation");
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
    for (request, authority) in [
        ("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443", "example.com:443"),
        ("GET http://10.0.0.5:3000/ HTTP/1.1\r\nHost: 10.0.0.5", "10.0.0.5:3000"),
        ("GET http://127.0.0.1.nip.io:3000/ HTTP/1.1\r\nHost: x", "127.0.0.1.nip.io:3000"),
    ] {
        let (authorization, _) = proxy_authorization(&route, authority);
        let request = format!("{request}\r\nProxy-Authorization: {authorization}\r\n\r\n");
        let answer = String::from_utf8(exchange(proxy, request.as_bytes())).unwrap();
        assert!(answer.starts_with("HTTP/1.1 403"), "{request:?} -> {answer:?}");
    }
    let origin_form =
        String::from_utf8(exchange(proxy, b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")).unwrap();
    assert!(origin_form.starts_with("HTTP/1.1 400"), "a page cannot use the route directly");
    let (absolute_auth, _) = proxy_authorization(&route, "localhost:5173");
    let absolute_request = format!(
        "GET http://localhost:5173/ HTTP/1.1\r\nHost: localhost:5173\r\nProxy-Authorization: {absolute_auth}\r\n\r\n"
    );
    let absolute_form = String::from_utf8(exchange(proxy, absolute_request.as_bytes())).unwrap();
    assert!(absolute_form.starts_with("HTTP/1.1 400"), "absolute form bypassed CONNECT");
    assert!(rig.tunnel.log().opened.is_empty(), "no refused request opened a stream");

    let unauthenticated = String::from_utf8(exchange(
        proxy,
        b"CONNECT localhost:3000 HTTP/1.1\r\nHost: localhost:3000\r\n\r\n",
    ))
    .unwrap();
    assert!(unauthenticated.starts_with("HTTP/1.1 407"), "{unauthenticated:?}");
    assert!(rig.tunnel.log().opened.is_empty(), "an unauthenticated request opened a stream");
    let wrong = String::from_utf8(exchange(
        proxy,
        b"CONNECT localhost:3000 HTTP/1.1\r\nHost: localhost:3000\r\nProxy-Authorization: CMUX cmux:bad:bad\r\n\r\n",
    ))
    .unwrap();
    assert!(wrong.starts_with("HTTP/1.1 407"), "{wrong:?}");
    assert!(rig.tunnel.log().opened.is_empty(), "a wrongly authenticated request opened a stream");

    let (authorization, server_proof) = proxy_authorization(&route, "localhost:3000");
    let connect_request = format!(
        "CONNECT localhost:3000 HTTP/1.1\r\nHost: localhost:3000\r\nProxy-Authorization: {authorization}\r\n\r\nhello\r\n\r\n"
    );
    let connect = exchange(proxy, connect_request.as_bytes());
    let text = String::from_utf8(connect).unwrap();
    assert!(text.starts_with("HTTP/1.1 200 Connection Established\r\n"), "{text:?}");
    assert!(text.contains(&format!("Proxy-Authentication-Info: CMUX {server_proof}\r\n")));
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
