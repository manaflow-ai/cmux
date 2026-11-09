//! Two drivers over real UDP sockets on loopback: the handshake runs, a
//! control record and datagrams cross, and the peer's close ends the session.

use cmux_rd_link::net::{Candidate, CandidateKind, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use std::time::{Duration, Instant};

fn start(role: Role, local: &KeyPair, remote: [u8; 32]) -> Net {
    Net::start(NetConfig {
        role,
        session: b"loopback-session".to_vec(),
        local: local.clone(),
        expected_remote: remote,
        stun: Vec::new(),
        bind: "127.0.0.1:0".parse().unwrap(),
        turn: Vec::new(),
        relay_only: false,
    })
    .unwrap()
}

/// Collects events until `done` holds or 5 s pass, waiting on the event fd.
fn wait(net: &Net, seen: &mut Vec<NetEvent>, done: impl Fn(&[NetEvent]) -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if done(seen) {
            return true;
        }
        let mut fd = libc::pollfd { fd: net.event_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd.
        unsafe { libc::poll(&mut fd, 1, 100) };
        seen.extend(net.events());
    }
    done(seen)
}

#[test]
fn a_session_runs_over_real_udp_sockets() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public);
    let viewer = start(Role::Initiator, &v, h.public);
    // Signaling would carry these; on loopback the bound addresses are the routes.
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });
    viewer.send_control(b"hello".to_vec());

    let established =
        |e: &[NetEvent]| e.contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Established)));
    let (mut at_host, mut at_viewer) = (Vec::new(), Vec::new());
    let hello = NetEvent::Endpoint(EndpointEvent::Link(Event::Control(b"hello".to_vec())));
    assert!(wait(&host, &mut at_host, |e| e.contains(&hello)));
    assert!(wait(&viewer, &mut at_viewer, established));

    for i in 0..20u8 {
        host.send_datagram(vec![i; 1000]);
    }
    let datagrams = |e: &[NetEvent]| {
        e.iter().filter(|e| matches!(e, NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) if d.len() == 1000)).count() >= 18
    };
    assert!(wait(&viewer, &mut at_viewer, datagrams), "datagrams cross loopback");

    drop(host);
    assert!(wait(&viewer, &mut at_viewer, |e| e
        .contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)))));
}

/// A STUN server on loopback that answers every binding request with the sender's address.
fn stun_server() -> std::net::SocketAddr {
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let addr = socket.local_addr().unwrap();
    std::thread::spawn(move || {
        let mut buf = [0u8; 1500];
        while let Ok((n, from)) = socket.recv_from(&mut buf) {
            let Some(id) = buf.get(8..20).filter(|_| n >= 20) else { continue };
            let mut transaction = [0u8; 12];
            transaction.copy_from_slice(id);
            let _ = socket.send_to(&cmux_transport::stun::binding_success(transaction, from), from);
        }
    });
    addr
}

#[test]
fn stun_servers_that_resolve_after_the_link_started_still_give_a_reflexive_candidate() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let net = start(Role::Initiator, &v, h.public);
    let (resolved, late) = std::sync::mpsc::channel();
    net.late_stun(late);
    let mut seen = Vec::new();
    let reflexive = |seen: &[NetEvent]| {
        seen.iter().any(|e| {
            matches!(e, NetEvent::Candidate(Candidate { kind: CandidateKind::ServerReflexive, .. }))
        })
    };
    // Nothing to ask yet: no reflexive candidate while the names are still resolving.
    std::thread::sleep(Duration::from_millis(200));
    seen.extend(net.events());
    assert!(!reflexive(&seen));
    resolved.send(vec![stun_server()]).unwrap();
    assert!(wait(&net, &mut seen, reflexive), "the late STUN server was never asked: {seen:?}");
}

#[test]
fn a_late_stun_list_that_never_comes_leaves_the_link_working() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public);
    let viewer = start(Role::Initiator, &v, h.public);
    let (resolver, late) = std::sync::mpsc::channel::<Vec<std::net::SocketAddr>>();
    viewer.late_stun(late);
    // The resolver went away without an answer.
    drop(resolver);
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });
    let established =
        |e: &[NetEvent]| e.contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Established)));
    let mut at_viewer = Vec::new();
    assert!(wait(&viewer, &mut at_viewer, established), "{at_viewer:?}");
}
