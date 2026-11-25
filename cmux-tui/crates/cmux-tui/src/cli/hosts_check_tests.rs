use std::io::Write as _;
use std::net::TcpListener;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_config::hosts::HostDecl;

use super::*;

fn host(label: &str, endpoints: &[&str]) -> HostDecl {
    HostDecl {
        label: label.into(),
        endpoints: endpoints.iter().map(|e| (*e).to_owned()).collect(),
        icon: None,
        id: None,
    }
}

/// A local server that writes `greeting` to each connection, on its own thread.
fn server(greeting: &'static [u8]) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let _ = stream.write_all(greeting);
        }
    });
    port
}

fn local(port: u16) -> Dial {
    Dial::Direct { host: "127.0.0.1".into(), port }
}

#[test]
fn an_ssh_greeting_is_reachable_and_anything_else_is_down() {
    let start = Instant::now();
    let deadline = start + Duration::from_secs(5);
    let ssh = probe_dial("a", &local(server(b"SSH-2.0-OpenSSH_9.9\r\n")), start, deadline);
    assert_eq!(ssh.status, Status::Reachable);
    assert_eq!(ssh.detail, "SSH-2.0-OpenSSH_9.9");
    assert!(ssh.ms.is_some());
    let web = probe_dial("b", &local(server(b"HTTP/1.1 400 Bad Request\r\n")), start, deadline);
    assert_eq!(web.status, Status::Down);
}

#[test]
fn a_closed_port_or_unknown_name_is_unreachable_and_a_proxy_is_unchecked() {
    let closed = {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.local_addr().expect("addr").port()
    };
    let start = Instant::now();
    let deadline = start + Duration::from_secs(2);
    assert_eq!(probe_dial("c", &local(closed), start, deadline).status, Status::Unreachable);
    let nowhere = Dial::Direct { host: "no-such-host.invalid".into(), port: 22 };
    assert_eq!(probe_dial("d", &nowhere, start, deadline).status, Status::Unreachable);
    assert_eq!(probe_dial("e", &Dial::Proxied, start, deadline).status, Status::Unchecked);
}

fn fake(answers: &'static [(&'static str, Status, u64)]) -> Probe {
    Arc::new(move |endpoint: &str, start: Instant, _deadline: Instant| {
        let (_, status, delay) = answers
            .iter()
            .find(|(name, _, _)| *name == endpoint)
            .copied()
            .unwrap_or(("", Status::Unreachable, 0));
        std::thread::sleep(Duration::from_millis(delay));
        EndpointResult {
            endpoint: endpoint.to_owned(),
            status,
            detail: String::new(),
            ms: Some(u64::try_from(start.elapsed().as_millis()).unwrap_or(0)),
        }
    })
}

#[test]
fn a_host_takes_its_first_reachable_endpoint_in_its_own_order() {
    let probe = fake(&[
        ("lan", Status::Unreachable, 0),
        ("tail", Status::Reachable, 20),
        ("tail-2", Status::Reachable, 0),
        ("web", Status::Down, 0),
        ("jump", Status::Unchecked, 0),
    ]);
    let hosts = [
        host("studio", &["lan", "tail", "tail-2"]),
        host("box", &["web", "jump"]),
        host("gone", &["lan"]),
    ];
    let out = check_all(&hosts, Duration::from_secs(2), &probe);
    assert_eq!(out[0].status, Status::Reachable);
    assert_eq!(out[0].endpoint, "tail");
    assert_eq!(out[0].endpoints.len(), 3);
    assert_eq!(out[1].status, Status::Down);
    assert_eq!(out[2].status, Status::Unreachable);
}

#[test]
fn the_pass_ends_at_its_timeout_whatever_the_host_count() {
    // 200 hosts that each take 10 s: the pass still ends by its 300 ms timeout.
    let probe: Probe = Arc::new(|endpoint: &str, _, _| {
        std::thread::sleep(Duration::from_secs(10));
        EndpointResult {
            endpoint: endpoint.to_owned(),
            status: Status::Reachable,
            detail: String::new(),
            ms: None,
        }
    });
    let hosts: Vec<HostDecl> = (0..200).map(|i| host(&format!("h{i}"), &["slow"])).collect();
    let started = Instant::now();
    let out = check_all(&hosts, Duration::from_millis(300), &probe);
    assert!(started.elapsed() < Duration::from_secs(2), "took {:?}", started.elapsed());
    assert!(out.iter().all(|h| h.status == Status::Unreachable));
}
