//! Two drivers that cannot reach each other directly (each only learns the
//! other's TURN relayed address) run a session through an in-process TURN
//! server on loopback: the handshake, a control record and datagrams cross
//! the relay, the path is `turn_relay`, the allocation is refreshed, and bad
//! credentials or a hostile server fail without bringing the driver down.

#[path = "support/fake_turn.rs"]
mod fake_turn;
#[path = "support/stun.rs"]
mod stun;

use cmux_rd_link::net::{Candidate, CandidateKind, Net, NetConfig, NetEvent, TurnServer};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_transport::PathKind;
use fake_turn::{FakeTurn, Options};
use std::time::{Duration, Instant};

fn start(role: Role, local: &KeyPair, remote: [u8; 32], turn: Vec<TurnServer>) -> Net {
    start_with(role, local, remote, turn, false)
}

fn start_with(
    role: Role,
    local: &KeyPair,
    remote: [u8; 32],
    turn: Vec<TurnServer>,
    relay_only: bool,
) -> Net {
    Net::start(NetConfig {
        role,
        session: b"turn-session".to_vec(),
        local: local.clone(),
        expected_remote: remote,
        stun: Vec::new(),
        bind: "127.0.0.1:0".parse().unwrap(),
        turn,
        relay_only,
    })
    .unwrap()
}

fn server(turn: &FakeTurn, password: &str) -> TurnServer {
    TurnServer { addr: turn.addr, username: "alice".into(), password: password.into() }
}

/// Collects events until `done` holds or `limit` passes, waiting on the event fd.
fn wait_for(
    net: &Net,
    seen: &mut Vec<NetEvent>,
    limit: Duration,
    done: impl Fn(&[NetEvent]) -> bool,
) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if done(seen) {
            return true;
        }
        let mut fd = libc::pollfd { fd: net.event_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd.
        unsafe { libc::poll(&mut fd, 1, 50) };
        seen.extend(net.events());
    }
    done(seen)
}

fn wait(net: &Net, seen: &mut Vec<NetEvent>, done: impl Fn(&[NetEvent]) -> bool) -> bool {
    wait_for(net, seen, Duration::from_secs(5), done)
}

fn relay_candidate(events: &[NetEvent]) -> Option<Candidate> {
    events.iter().find_map(|e| match e {
        NetEvent::Candidate(c) if c.kind == CandidateKind::Relay => Some(*c),
        _ => None,
    })
}

fn done(events: &[NetEvent]) -> bool {
    events.contains(&NetEvent::CandidatesDone)
}

fn path_kinds(events: &[NetEvent]) -> Vec<PathKind> {
    events
        .iter()
        .filter_map(|e| match e {
            NetEvent::Endpoint(EndpointEvent::PathChanged { kind: Some(kind), .. }) => Some(*kind),
            _ => None,
        })
        .collect()
}

fn datagrams(events: &[NetEvent], len: usize) -> usize {
    events
        .iter()
        .filter(|e| {
            matches!(e, NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) if d.len() == len)
        })
        .count()
}

#[test]
fn a_session_runs_through_turn_relays_when_no_direct_path_exists() {
    // A 2 s lifetime makes the client refresh every second; the server drops
    // an allocation that is not refreshed in time.
    let turn =
        FakeTurn::start(Options { lifetime_s: 2, stale_nonce_once: true, ..Options::default() });
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public, vec![server(&turn, "correct horse")]);
    let viewer = start(Role::Initiator, &v, h.public, vec![server(&turn, "correct horse")]);

    let (mut at_host, mut at_viewer) = (Vec::new(), Vec::new());
    assert!(wait(&host, &mut at_host, |e| relay_candidate(e).is_some() && done(e)));
    assert!(wait(&viewer, &mut at_viewer, |e| relay_candidate(e).is_some() && done(e)));
    let host_relay = relay_candidate(&at_host).unwrap();
    let viewer_relay = relay_candidate(&at_viewer).unwrap();
    assert_eq!(host_relay.to_wire(), format!("relay {}", host_relay.addr));
    assert_eq!(Candidate::from_wire(&host_relay.to_wire()), Some(host_relay));
    assert_ne!(host_relay.addr, host.local_addr(), "the relayed address is the server's");

    // Signaling carries only the relay candidates: neither side learns the
    // other's socket address, so every packet goes through the TURN server.
    viewer.add_remote_candidate(host_relay);
    host.add_remote_candidate(viewer_relay);
    viewer.send_control(b"hello".to_vec());

    let hello = NetEvent::Endpoint(EndpointEvent::Link(Event::Control(b"hello".to_vec())));
    let established =
        |e: &[NetEvent]| e.contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Established)));
    assert!(wait(&host, &mut at_host, |e| e.contains(&hello)), "control record crosses the relay");
    assert!(wait(&viewer, &mut at_viewer, established), "handshake completes through the relay");

    for i in 0..20u8 {
        host.send_datagram(vec![i; 1000]);
    }
    assert!(
        wait(&viewer, &mut at_viewer, |e| datagrams(e, 1000) >= 18),
        "datagrams cross the relay"
    );
    assert!(wait(&viewer, &mut at_viewer, |e| !path_kinds(e).is_empty()));
    assert!(wait(&host, &mut at_host, |e| !path_kinds(e).is_empty()));
    for kinds in [path_kinds(&at_viewer), path_kinds(&at_host)] {
        assert!(kinds.iter().all(|k| *k == PathKind::TurnRelay), "{kinds:?}");
        assert_eq!(kinds[0].wire_name(), "turn_relay");
    }

    // Past two lifetimes the allocations live on because they were refreshed.
    let mut idle = Vec::new();
    wait_for(&viewer, &mut idle, Duration::from_millis(4500), |_| false);
    at_viewer.extend(idle);
    for i in 0..20u8 {
        host.send_datagram(vec![i; 900]);
    }
    assert!(
        wait(&viewer, &mut at_viewer, |e| datagrams(e, 900) >= 18),
        "datagrams still cross after the first lifetime"
    );

    let stats = turn.stats();
    assert_eq!(stats.allocations, 2, "{stats:?}");
    assert_eq!(stats.stale_sent, 1, "a 438 stale nonce was answered: {stats:?}");
    assert!(stats.refreshes >= 4, "{stats:?}");
    assert_eq!(stats.expired, 0, "{stats:?}");
    assert!(stats.permissions >= 2 && stats.channel_binds >= 2, "{stats:?}");
    assert!(stats.channel_data_to_clients > 0, "{stats:?}");
    assert!(
        !at_host
            .iter()
            .chain(&at_viewer)
            .any(|e| matches!(e, NetEvent::Failed(_) | NetEvent::RelayFailed { .. }))
    );

    drop(host);
    assert!(wait(&viewer, &mut at_viewer, |e| e
        .contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)))));
}

#[test]
fn wrong_turn_credentials_fail_the_relay_and_not_the_driver() {
    let turn = FakeTurn::start(Options::default());
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let viewer = start(Role::Initiator, &v, h.public, vec![server(&turn, "wrong password")]);
    let mut seen = Vec::new();
    let failed = |e: &[NetEvent]| {
        e.iter().any(|e| matches!(e, NetEvent::RelayFailed { reason, .. } if reason.contains("unauthorized")))
    };
    assert!(wait(&viewer, &mut seen, |e| failed(e) && done(e)), "{seen:?}");
    assert!(relay_candidate(&seen).is_none());
    assert!(!seen.iter().any(|e| matches!(e, NetEvent::Failed(_))));
    assert_eq!(turn.stats().allocations, 0);
    assert_eq!(turn.stats().unauthorized, 1, "the client does not retry a refused key");

    // The driver still runs: a session over a direct path works.
    let host = start(Role::Responder, &h, v.public, Vec::new());
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });
    viewer.send_control(b"still here".to_vec());
    let mut at_host = Vec::new();
    let record = NetEvent::Endpoint(EndpointEvent::Link(Event::Control(b"still here".to_vec())));
    assert!(wait(&host, &mut at_host, |e| e.contains(&record)));
}

#[test]
fn a_hostile_turn_server_cannot_bring_the_driver_down() {
    let turn = FakeTurn::start(Options { hostile: true, ..Options::default() });
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let viewer = start(Role::Initiator, &v, h.public, vec![server(&turn, "correct horse")]);
    let mut seen = Vec::new();
    // Gathering ends within its bound whatever the server sends.
    assert!(wait(&viewer, &mut seen, done), "{seen:?}");
    let mut more = Vec::new();
    wait_for(&viewer, &mut more, Duration::from_secs(1), |_| false);
    seen.extend(more);
    assert!(turn.stats().hostile_sent >= 200);
    assert!(!seen.iter().any(|e| matches!(e, NetEvent::Failed(_))), "{seen:?}");

    // The driver still runs a session.
    let host = start(Role::Responder, &h, v.public, Vec::new());
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });
    viewer.send_control(b"alive".to_vec());
    let mut at_host = Vec::new();
    let record = NetEvent::Endpoint(EndpointEvent::Link(Event::Control(b"alive".to_vec())));
    assert!(wait(&host, &mut at_host, |e| e.contains(&record)));
}

#[test]
fn a_relay_only_side_reaches_the_peer_only_through_its_turn_allocation() {
    // Both sides are on loopback, where a direct path would work: the viewer's
    // "relay only" must still keep every packet on the TURN server, gather no
    // address of its own and send none to the host.
    let turn = FakeTurn::start(Options::default());
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public, Vec::new());
    let viewer =
        start_with(Role::Initiator, &v, h.public, vec![server(&turn, "correct horse")], true);

    let (mut at_host, mut at_viewer) = (Vec::new(), Vec::new());
    assert!(wait(&host, &mut at_host, done));
    assert!(wait(&viewer, &mut at_viewer, |e| relay_candidate(e).is_some() && done(e)));
    let own: Vec<Candidate> = at_viewer
        .iter()
        .filter_map(|e| match e {
            NetEvent::Candidate(c) => Some(*c),
            _ => None,
        })
        .collect();
    assert!(
        own.iter().all(|c| c.kind == CandidateKind::Relay),
        "only the relayed address: {own:?}"
    );

    // The host's direct address reaches the viewer (its socket is on
    // loopback, so that is its host candidate here), which must not use it
    // directly: its relay sends to it instead.
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    for c in &own {
        host.add_remote_candidate(*c);
    }
    viewer.send_control(b"hello".to_vec());
    let hello = NetEvent::Endpoint(EndpointEvent::Link(Event::Control(b"hello".to_vec())));
    assert!(wait(&host, &mut at_host, |e| e.contains(&hello)), "control record crosses the relay");
    for i in 0..20u8 {
        host.send_datagram(vec![i; 1000]);
    }
    assert!(
        wait(&viewer, &mut at_viewer, |e| datagrams(e, 1000) >= 18),
        "datagrams cross the relay"
    );
    assert!(wait(&viewer, &mut at_viewer, |e| !path_kinds(e).is_empty()));
    assert!(wait(&host, &mut at_host, |e| !path_kinds(e).is_empty()));
    for kinds in [path_kinds(&at_viewer), path_kinds(&at_host)] {
        assert!(kinds.iter().all(|k| *k == PathKind::TurnRelay), "{kinds:?}");
    }
    assert!(turn.stats().channel_data_to_clients > 0);
}
