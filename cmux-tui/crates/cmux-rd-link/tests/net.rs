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
