//! Two drivers over real UDP sockets on loopback: the handshake runs, a
//! control record and datagrams cross, and the peer's close ends the session.

use cmux_rd_link::net::{Candidate, CandidateKind, ConnectPhase, Net, NetConfig, NetEvent};
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

/// Collects events until `done` holds or 5 s pass, waiting on the driver's wake-up (a pipe on
/// Unix, a loopback socket on Windows: this test runs on both).
fn wait(net: &Net, seen: &mut Vec<NetEvent>, done: impl Fn(&[NetEvent]) -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if done(seen) {
            return true;
        }
        net.wait(Some(Duration::from_millis(100)));
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

    host.send_datagram_frame((0..20u8).map(|i| vec![i; 1000]).collect(), true);
    host.send_control(b"control-after-frame".to_vec());
    let control =
        NetEvent::Endpoint(EndpointEvent::Link(Event::Control(b"control-after-frame".to_vec())));
    assert!(wait(&viewer, &mut at_viewer, |e| e.contains(&control)));
    let datagrams = |e: &[NetEvent]| {
        e.iter().filter(|e| matches!(e, NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) if d.len() == 1000)).count() >= 18
    };
    assert!(wait(&viewer, &mut at_viewer, datagrams), "datagrams cross loopback");

    drop(host);
    assert!(wait(&viewer, &mut at_viewer, |e| e
        .contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)))));
}

/// The wired-pair connect on real sockets: the host's STUN server never answers
/// and the viewer is also offered a tailnet address nothing listens on. The
/// session is up long before the first STUN retry (300 ms): connect waits on
/// neither gathering nor a dead candidate, every candidate is tried at once.
#[test]
fn connect_waits_on_neither_stun_nor_a_dead_candidate() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = Net::start(NetConfig {
        role: Role::Responder,
        session: b"loopback-session".to_vec(),
        local: h.clone(),
        expected_remote: v.public,
        stun: vec!["192.0.2.1:3478".parse().unwrap()], // TEST-NET-1: never answers
        bind: "127.0.0.1:0".parse().unwrap(),
        turn: Vec::new(),
        relay_only: false,
    })
    .unwrap();
    let viewer = start(Role::Initiator, &v, h.public);
    let t0 = Instant::now();
    viewer.add_remote_candidate(Candidate {
        kind: CandidateKind::Host,
        addr: "100.127.99.33:50100".parse().unwrap(),
    });
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    let established =
        |e: &[NetEvent]| e.contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Established)));
    let mut at_host = Vec::new();
    assert!(wait(&host, &mut at_host, established));
    let took = t0.elapsed();
    assert!(took < Duration::from_millis(250), "host connected after {took:?}");
}

/// Each side reports where its connect time went, once per phase, in order:
/// the lines `cmux rd serve` and `bench --link` print for a rig to time.
#[test]
fn each_side_reports_its_connect_phases_in_order() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public);
    let viewer = start(Role::Initiator, &v, h.public);
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    let established =
        |e: &[NetEvent]| e.contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Established)));
    let (mut at_host, mut at_viewer) = (Vec::new(), Vec::new());
    assert!(wait(&host, &mut at_host, established));
    assert!(wait(&viewer, &mut at_viewer, established));
    // The selector nominates on the first probe answer after the handshake.
    let nominated = |e: &[NetEvent]| {
        e.iter().any(|e| matches!(e, NetEvent::Phase { phase: ConnectPhase::Nominated, .. }))
    };
    assert!(wait(&host, &mut at_host, nominated));
    assert!(wait(&viewer, &mut at_viewer, nominated));
    for (side, seen) in [("viewer", &at_viewer), ("host", &at_host)] {
        let phases: Vec<(ConnectPhase, u64)> = seen
            .iter()
            .filter_map(|e| match e {
                NetEvent::Phase { phase, at_us, .. } => Some((*phase, *at_us)),
                _ => None,
            })
            .collect();
        let names: Vec<_> = phases.iter().map(|(p, _)| p.name()).collect();
        for phase in [
            ConnectPhase::GatherDone,
            ConnectPhase::FirstCheckSent,
            ConnectPhase::FirstCheckAnswered,
            ConnectPhase::HandshakeStart,
            ConnectPhase::HandshakeDone,
            ConnectPhase::Nominated,
        ] {
            assert_eq!(
                phases.iter().filter(|(p, _)| *p == phase).count(),
                1,
                "{side}: {} once in {names:?}",
                phase.name()
            );
        }
        let at = |want: ConnectPhase| phases.iter().find(|(p, _)| *p == want).unwrap().1;
        assert!(at(ConnectPhase::HandshakeStart) <= at(ConnectPhase::HandshakeDone), "{side}");
        assert!(at(ConnectPhase::FirstCheckAnswered) <= at(ConnectPhase::HandshakeDone), "{side}");
        let line = seen.iter().find_map(|e| match e {
            NetEvent::Phase { phase: ConnectPhase::FirstCheckAnswered, .. } => e.phase_line(),
            _ => None,
        });
        let line = line.unwrap();
        for e in seen.iter() {
            if let Some(l) = e.phase_line() {
                eprintln!("{side} {l}");
            }
        }
        assert!(
            line.starts_with(r#"{"phase":"first_check_answered","ms":"#)
                && line.contains(r#","route":"127.0.0.1:"#),
            "{side}: {line}"
        );
    }
}

#[test]
fn queued_frames_replace_whole_frames_without_dropping_control_or_input() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public);
    let viewer = start(Role::Initiator, &v, h.public);
    // No route exists yet, so the driver cannot race the replacement.
    host.send_datagram_frame(vec![b"old-a".to_vec(), b"old-b".to_vec()], true);
    host.send_control(b"control".to_vec());
    host.send_datagram_frame(vec![b"new-a".to_vec(), b"new-b".to_vec()], true);
    assert_eq!(host.stats().dropped_frames, 1);
    assert_eq!(host.stats().dropped_datagrams, 2);
    assert_eq!(host.stats().queue_frames, 1);
    // These commands are queued only after the handshake below; they must
    // not evict media while preserving the legacy pre-handshake semantics.
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });
    let mut at_host = Vec::new();
    assert!(wait(&host, &mut at_host, |events| events
        .contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Established)))));
    host.send_datagram(b"input".to_vec());
    host.send_datagram(b"repair".to_vec());
    let mut received = Vec::new();
    let control = NetEvent::Endpoint(EndpointEvent::Link(Event::Control(b"control".to_vec())));
    let packets = [b"input".to_vec(), b"repair".to_vec(), b"new-a".to_vec(), b"new-b".to_vec()];
    assert!(wait(&viewer, &mut received, |events| {
        events.contains(&control)
            && packets.iter().all(|data| {
                events.contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(
                    data.clone(),
                ))))
            })
    }));
    assert!(!received.iter().any(|event| matches!(event,
        NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(data)))
        if data.starts_with(b"old-"))));
}

#[test]
fn a_protected_single_datagram_waits_for_link_establishment() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public);
    let viewer = start(Role::Initiator, &v, h.public);
    let datagram = receipt_datagram(9, 0, 900);

    // The host has no route yet. A legacy one-datagram send must wait rather
    // than disappear while the Noise handshake gathers its candidate.
    host.send_datagram(datagram.clone());
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });

    let mut received = Vec::new();
    assert!(wait(&viewer, &mut received, |events| {
        events.contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(datagram.clone()))))
    }));
    let mut departures = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while departures.is_empty() && Instant::now() < deadline {
        host.drain_departures(&mut departures);
        if departures.is_empty() {
            host.wait(Some(Duration::from_millis(100)));
            host.events();
        }
    }
    assert!(departures.iter().any(|receipt| receipt.header.frame == 9));
}

#[test]
fn a_stun_server_that_resolves_after_start_still_gives_the_reflexive_candidate() {
    // A STUN server on loopback that answers every binding request with a fixed address.
    let server = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let server_addr = server.local_addr().unwrap();
    let reflexive: std::net::SocketAddr = "203.0.113.7:4242".parse().unwrap();
    std::thread::spawn(move || {
        let mut buf = [0u8; 1500];
        while let Ok((n, from)) = server.recv_from(&mut buf) {
            if let Some(tx) = buf.get(8..20).filter(|_| n >= 20) {
                let tx: [u8; 12] = tx.try_into().unwrap();
                let _ = server.send_to(&cmux_transport::stun::binding_success(tx, reflexive), from);
            }
        }
    });
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let net = start(Role::Initiator, &v, h.public);
    // The resolver answers on the driver's fourth ask, as a slow lookup would.
    let mut asks = 0;
    net.add_stun_later(Box::new(move || {
        asks += 1;
        (asks > 3).then(|| vec![server_addr])
    }));
    let mut seen = Vec::new();
    let late =
        NetEvent::Candidate(Candidate { kind: CandidateKind::ServerReflexive, addr: reflexive });
    assert!(wait(&net, &mut seen, |e| e.contains(&late)), "the late STUN server is queried");
}

#[test]
fn a_record_sent_just_before_the_close_still_reaches_the_peer() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public);
    let viewer = start(Role::Initiator, &v, h.public);
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });
    viewer.send_control(b"hello".to_vec());
    let established =
        |e: &[NetEvent]| e.contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Established)));
    let (mut at_host, mut at_viewer) = (Vec::new(), Vec::new());
    assert!(wait(&host, &mut at_host, established));
    assert!(wait(&viewer, &mut at_viewer, established));

    // As `cmux-rd serve` ends a session: its `ended` reason, then the link dropped at once.
    host.send_control(b"ended: failed: no grant".to_vec());
    drop(host);
    let closed = NetEvent::Endpoint(EndpointEvent::Link(Event::Closed));
    assert!(wait(&viewer, &mut at_viewer, |e| e.contains(&closed)));
    let ended = NetEvent::Endpoint(EndpointEvent::Link(Event::Control(
        b"ended: failed: no grant".to_vec(),
    )));
    let ended_at = at_viewer.iter().position(|e| *e == ended);
    let closed_at = at_viewer.iter().position(|e| *e == closed);
    assert!(ended_at.is_some(), "the last record crosses before the close: {at_viewer:?}");
    assert!(ended_at < closed_at, "the record comes before the close");
}

/// A send the system refuses (here a broadcast address without SO_BROADCAST; on a Mac, a LAN
/// address while the app has no Local Network access) used to be dropped without a word, so
/// the failure read only "heard 0" (cmuxterm-hq CMUX-572). The reason now counts it.
#[test]
fn a_link_whose_sends_are_refused_says_so_when_it_fails() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let viewer = Net::start(NetConfig {
        role: Role::Initiator,
        session: b"refused-session".to_vec(),
        local: v,
        expected_remote: h.public,
        stun: Vec::new(),
        bind: "0.0.0.0:0".parse().unwrap(),
        turn: Vec::new(),
        relay_only: false,
    })
    .unwrap();
    viewer.add_remote_candidate(Candidate {
        kind: CandidateKind::Host,
        addr: "255.255.255.255:9".parse().unwrap(),
    });
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut failed = None;
    while failed.is_none() && Instant::now() < deadline {
        viewer.wait(Some(Duration::from_millis(100)));
        failed = viewer.events().into_iter().find_map(|e| match e {
            NetEvent::Failed(reason) => Some(reason),
            _ => None,
        });
    }
    let reason = failed.expect("the handshake times out");
    assert!(reason.contains("heard 0"), "{reason}");
    assert!(reason.contains("sends refused: "), "{reason}");
    assert!(reason.contains("os error"), "{reason}");
}

fn receipt_datagram(frame: u32, index: u16, seq: u16) -> Vec<u8> {
    cmux_rd_proto::DatagramHeader {
        flags: 0,
        kind: cmux_rd_proto::DatagramKind::Video,
        stream: 7,
        frame,
        index,
        count: 2,
        fec_count: 0,
        transport_seq: seq,
    }
    .encode()
    .to_vec()
}

#[cfg(unix)]
fn monotonic_us() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: a valid timespec for the same protocol clock as the host ledger.
    assert_eq!(unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) }, 0);
    ts.tv_sec as u64 * 1_000_000 + ts.tv_nsec as u64 / 1000
}

/// Windows: the performance counter, the clock the link stamps departures with.
#[cfg(windows)]
fn monotonic_us() -> u64 {
    use windows_sys::Win32::System::Performance::{
        QueryPerformanceCounter, QueryPerformanceFrequency,
    };
    let (mut count, mut freq) = (0i64, 0i64);
    // SAFETY: both calls write one i64 into a live local.
    let ok = unsafe {
        QueryPerformanceCounter(&mut count) != 0 && QueryPerformanceFrequency(&mut freq) != 0
    };
    assert!(ok && freq > 0);
    (count as u128 * 1_000_000 / freq as u128) as u64
}

#[test]
fn departure_receipts_follow_successful_sends_not_enqueue_or_replaced_frames() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public);
    let viewer = start(Role::Initiator, &v, h.public);
    host.send_datagram_frame(vec![receipt_datagram(1, 0, 100)], true);
    host.send_datagram_frame(vec![receipt_datagram(2, 0, 101), receipt_datagram(2, 1, 102)], true);
    let mut receipts = Vec::new();
    host.drain_departures(&mut receipts);
    assert!(receipts.is_empty(), "an enqueued frame has not departed");
    assert_eq!(host.stats().dropped_frames, 1);
    let before = monotonic_us();
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });
    host.send_control(b"control-still-flows".to_vec());
    let mut received = Vec::new();
    assert!(wait(&viewer, &mut received, |events| events.contains(&NetEvent::Endpoint(
        EndpointEvent::Link(Event::Datagram(receipt_datagram(2, 1, 102)))
    ))));
    let deadline = Instant::now() + Duration::from_secs(5);
    while receipts.len() < 2 && Instant::now() < deadline {
        host.drain_departures(&mut receipts);
        if receipts.len() < 2 {
            host.wait(Some(Duration::from_millis(100)));
            host.events();
        }
    }
    let after = monotonic_us();
    assert_eq!(receipts.len(), 2, "both successfully sent shards have receipts");
    for (i, receipt) in receipts.iter().enumerate() {
        assert_eq!(receipt.header.frame, 2);
        assert_eq!(receipt.header.stream, 7);
        assert_eq!(receipt.header.index, i as u16);
        assert_eq!(receipt.header.transport_seq, 101 + i as u16);
        assert!(
            (before..=after).contains(&receipt.departed_us),
            "host protocol clock, not driver epoch"
        );
        assert!(receipt.wire_bytes > cmux_rd_proto::HEADER_LEN, "includes link encryption");
    }
    assert_eq!(host.departure_overflows(), 0);
    assert!(wait(&viewer, &mut received, |events| events.contains(&NetEvent::Endpoint(
        EndpointEvent::Link(Event::Control(b"control-still-flows".to_vec()))
    ))));
}

#[test]
fn departure_receipts_overflow_is_bounded_without_stalling_media_or_control() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = start(Role::Responder, &h, v.public);
    let viewer = start(Role::Initiator, &v, h.public);
    viewer.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: host.local_addr() });
    host.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: viewer.local_addr() });
    let mut events = Vec::new();
    assert!(wait(&host, &mut events, |e| e
        .contains(&NetEvent::Endpoint(EndpointEvent::Link(Event::Established)))));
    let limit = cmux_rd_proto::MAX_DEPARTURE_RECEIPTS;
    host.send_datagram_frame(
        (0..limit + 2).map(|i| receipt_datagram(3, 0, i as u16)).collect(),
        false,
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while host.departure_overflows() < 2 && Instant::now() < deadline {
        // The wake-up is coalesced after the driver's send batch.
        host.wait(Some(Duration::from_millis(100)));
        host.events();
    }
    assert_eq!(host.departure_overflows(), 2);
    assert_eq!(host.stats().departure_overflows, 2);
    let mut receipts = Vec::new();
    host.drain_departures(&mut receipts);
    assert_eq!(receipts.len(), limit);
    assert_eq!(host.stats().dropped_frames, 0, "receipt overflow is not media loss");
    host.send_control(b"control-after-overflow".to_vec());
    let mut received = Vec::new();
    assert!(wait(&viewer, &mut received, |e| e.contains(&NetEvent::Endpoint(
        EndpointEvent::Link(Event::Control(b"control-after-overflow".to_vec()))
    ))));
}
