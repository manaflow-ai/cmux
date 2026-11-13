use super::*;
use crate::wg_carrier::Role;
use cmux_rd_link::net::{Candidate, CandidateKind, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair};
use std::time::{Duration, Instant};

fn pair() -> (LinkCarrier, LinkCarrier) {
    pair_with_identity(false)
}

fn net_pair(wrong_peer: bool) -> (Net, Net) {
    let host = KeyPair::generate().unwrap();
    let viewer = KeyPair::generate().unwrap();
    let host_public = host.public;
    let viewer_public = viewer.public;
    let make = |role, local, expected_remote| {
        Net::start(NetConfig {
            role,
            local,
            expected_remote,
            session: b"wg-carrier-pair".to_vec(),
            stun: vec![],
            bind: "127.0.0.1:0".parse().unwrap(),
            turn: vec![],
            relay_only: false,
        })
        .unwrap()
    };
    let a = make(cmux_rd_link::Role::Responder, host, viewer_public);
    let b = make(
        cmux_rd_link::Role::Initiator,
        viewer,
        if wrong_peer { [0x77; 32] } else { host_public },
    );
    (a, b)
}

fn pair_with_identity(wrong_peer: bool) -> (LinkCarrier, LinkCarrier) {
    let (a, b) = net_pair(wrong_peer);
    a.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: b.local_addr() });
    b.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: a.local_addr() });
    (
        LinkCarrier::new(a, Role::Host, LinkMode::Wg).unwrap(),
        LinkCarrier::new(b, Role::Viewer, LinkMode::Wg).unwrap(),
    )
}
fn step(a: &mut LinkCarrier, b: &mut LinkCarrier) -> (Vec<NetEvent>, Vec<NetEvent>) {
    let mut fds = a.fds();
    fds.extend(b.fds());
    crate::fdwait::wait_readable(&fds, Some(10_000_000)).unwrap();
    (a.events(), b.events())
}
#[test]
fn wg_transport_round_trip_max_media_and_async_wake() {
    let (mut a, mut b) = pair();
    let deadline = Instant::now() + Duration::from_secs(8);
    assert!(a.send_datagram(b"pre-ready").is_err());
    while !a.media_ready() || !b.media_ready() {
        let (ae, be) = step(&mut a, &mut b);
        assert!(!ae.iter().chain(&be).any(|e| matches!(e, NetEvent::Failed(_))), "{ae:?} {be:?}");
        assert!(!a.retry_ready() && !b.retry_ready());
        assert!(Instant::now() < deadline, "WG readiness timed out");
    }
    let payload = vec![0x5a; a.max_datagram()];
    a.send_datagram(&payload).unwrap();
    b.send_datagram(b"pointer-and-key").unwrap();
    let (mut got_host, mut got_viewer) = (false, false);
    while !got_host || !got_viewer {
        let (ae, be) = step(&mut a, &mut b);
        for event in ae {
            if let NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) = event {
                assert_eq!(d, b"pointer-and-key");
                got_host = true;
            }
        }
        for event in be {
            if let NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) = event {
                assert_eq!(d, payload);
                got_viewer = true;
            }
        }
        assert!(Instant::now() < deadline, "WG media/wakeup timed out");
    }
    assert!(a.send_datagram(&vec![0; a.max_datagram() + 1]).is_err());
    let start = Instant::now();
    drop(a);
    drop(b);
    assert!(start.elapsed() < Duration::from_secs(1));
}
#[test]
fn wg_transport_unsupported_agrees_before_retry() {
    let (mut a, mut b) = pair();
    // This record is queued before either side begins its WG negotiation.
    a.net.send_control(
        br#"{"t":"wg_offer","version":255,"key":"00","address":"10.253.0.1","mtu":1088}"#.to_vec(),
    );
    let deadline = Instant::now() + Duration::from_secs(8);
    while !a.retry_ready() || !b.retry_ready() {
        let (ae, be) = step(&mut a, &mut b);
        assert!(!a.media_ready() && !b.media_ready());
        assert!(!ae.iter().chain(&be).any(|e| matches!(e, NetEvent::Failed(_))), "{ae:?} {be:?}");
        assert!(Instant::now() < deadline);
    }
    assert!(a.take_fallback().is_some());
    assert!(b.take_fallback().is_some());
    assert!(a.send_datagram(b"no media on retry").is_err());
}
#[test]
fn wg_transport_noise_peer_mismatch_never_retries() {
    let (mut a, mut b) = pair_with_identity(true);
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        let (ae, be) = step(&mut a, &mut b);
        assert!(!a.retry_ready() && !b.retry_ready());
        assert!(!a.media_ready() && !b.media_ready());
        if ae.iter().chain(&be).any(|e| matches!(e, NetEvent::Failed(_))) {
            break;
        }
        assert!(Instant::now() < deadline, "wrong peer did not fail closed");
    }
}
// The proxy exercises real encrypted UDP packets. Drop every fifth packet
// until a peer retries, then lose all traffic (including its close/final ACK).
struct LossyPath {
    cut: std::sync::Arc<std::sync::atomic::AtomicBool>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}
impl LossyPath {
    fn start(a: &Net, b: &Net) -> Self {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_read_timeout(Some(Duration::from_millis(10))).unwrap();
        let addr = socket.local_addr().unwrap();
        let (a_addr, b_addr) = (a.local_addr(), b.local_addr());
        a.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr });
        b.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr });
        let cut = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let (cut_worker, stop_worker) = (cut.clone(), stop.clone());
        let join = std::thread::spawn(move || {
            let mut packet = [0u8; 4096];
            let mut count = 0usize;
            while !stop_worker.load(Ordering::Relaxed) {
                if let Ok((n, from)) = socket.recv_from(&mut packet) {
                    count += 1;
                    if cut_worker.load(Ordering::Relaxed) || count % 5 == 0 {
                        continue;
                    }
                    let target = if from == a_addr {
                        b_addr
                    } else if from == b_addr {
                        a_addr
                    } else {
                        continue;
                    };
                    socket.send_to(&packet[..n], target).unwrap();
                }
            }
        });
        Self { cut, stop, join: Some(join) }
    }
}
impl Drop for LossyPath {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        self.join.take().unwrap().join().unwrap();
    }
}

fn retry_then_peer_exit(lossy: bool) {
    let (a, b) = net_pair(false);
    let path = if lossy {
        Some(LossyPath::start(&a, &b))
    } else {
        a.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: b.local_addr() });
        b.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: a.local_addr() });
        None
    };
    let (mut a, mut b) = (
        LinkCarrier::new(a, Role::Host, LinkMode::Wg).unwrap(),
        LinkCarrier::new(b, Role::Viewer, LinkMode::Wg).unwrap(),
    );
    a.net.send_control(
        br#"{"t":"wg_offer","version":255,"key":"00","address":"10.253.0.1","mtu":1088}"#.to_vec(),
    );
    let deadline = Instant::now() + Duration::from_secs(8);
    while !a.retry_ready() && !b.retry_ready() {
        let mut fds = a.fds();
        fds.extend(b.fds());
        crate::fdwait::wait_readable(&fds, Some(10_000_000)).unwrap();
        let ae = a.events();
        assert!(!ae.iter().any(|event| matches!(event, NetEvent::Failed(_))), "{ae:?}");
        // Stop the first retrying process before the other app drains its
        // events, matching the Swift fallback owner's immediate stop.
        if a.retry_ready() {
            break;
        }
        let be = b.events();
        assert!(!be.iter().any(|event| matches!(event, NetEvent::Failed(_))), "{be:?}");
        assert!(!a.media_ready() && !b.media_ready());
        assert!(Instant::now() < deadline, "neither peer reached retry");
    }
    if let Some(path) = &path {
        path.cut.store(true, std::sync::atomic::Ordering::Relaxed);
    }
    let mut remaining = if a.retry_ready() {
        drop(a);
        b
    } else {
        drop(b);
        a
    };
    let exit_deadline = Instant::now() + crate::wg_carrier::RETRY_TIMEOUT + Duration::from_secs(1);
    loop {
        assert!(!remaining.media_ready());
        assert!(remaining.send_datagram(b"no media after retry").is_err());
        if remaining.retry_ready() {
            break;
        }
        crate::fdwait::wait_readable(&remaining.fds(), Some(10_000_000)).unwrap();
        let events = remaining.events();
        if events.iter().any(|event| {
            matches!(
                event,
                NetEvent::Failed(_) | NetEvent::Endpoint(EndpointEvent::Link(Event::Closed))
            )
        }) {
            assert!(!remaining.retry_ready(), "terminal close must suppress retry");
            break;
        }
        assert!(Instant::now() < exit_deadline, "lost final ACK left peer waiting indefinitely");
    }
}
#[test]
fn wg_transport_peer_worker_exit_has_bounded_outcome() {
    retry_then_peer_exit(false);
}
#[test]
fn wg_transport_packet_loss_and_immediate_exit_has_bounded_outcome() {
    retry_then_peer_exit(true);
}

#[derive(serde::Deserialize)]
struct Selection {
    #[serde(default)]
    peer_carrier: LinkMode,
}
fn selection(marker: Option<&str>) -> LinkMode {
    let value = marker
        .map_or_else(|| serde_json::json!({}), |marker| serde_json::json!({"peer_carrier":marker}));
    serde_json::from_value::<Selection>(value).unwrap().peer_carrier
}
#[test]
fn wg_selection_omission_is_legacy_but_unknown_or_malformed_never_downgrades() {
    assert_eq!(selection(None), LinkMode::Legacy);
    assert_eq!(selection(Some("rd_wg/1")), LinkMode::Wg);
    for value in [
        serde_json::Value::Null,
        serde_json::json!(""),
        serde_json::json!("legacy"),
        serde_json::json!("rd_wg/2"),
        serde_json::json!(false),
        serde_json::json!(["rd_wg/1"]),
    ] {
        assert!(
            serde_json::from_value::<Selection>(serde_json::json!({"peer_carrier":value})).is_err()
        );
    }
    assert!(serde_json::from_str::<Selection>(
        r#"{"peer_carrier":"rd_wg/1","peer_carrier":"rd_wg/1"}"#
    )
    .is_err());
}

enum VersionedPeer {
    Legacy(Net),
    Current(LinkCarrier),
}
impl VersionedPeer {
    fn events(&mut self) -> Vec<NetEvent> {
        match self {
            Self::Legacy(net) => net.events(),
            Self::Current(carrier) => carrier.events(),
        }
    }
    fn fds(&self) -> Vec<RawFd> {
        match self {
            Self::Legacy(net) => vec![net.event_fd()],
            Self::Current(carrier) => carrier.fds(),
        }
    }
    fn send(&mut self, data: &[u8]) {
        match self {
            Self::Legacy(net) => net.send_datagram(data.to_vec()),
            Self::Current(carrier) => carrier.send_datagram(data).unwrap(),
        }
    }
}
#[test]
fn wg_version_pairs_preserve_original_media_until_both_select_wg() {
    for (host_current, viewer_current) in
        [(false, false), (false, true), (true, false), (true, true)]
    {
        let (a, b) = net_pair(false);
        a.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: b.local_addr() });
        b.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: a.local_addr() });
        // Old host ignores the extra signed offer marker and answers without it.
        let offer = viewer_current.then_some("rd_wg/1");
        let answer = (host_current && viewer_current).then_some("rd_wg/1");
        let mut host = if host_current {
            VersionedPeer::Current(LinkCarrier::new(a, Role::Host, selection(offer)).unwrap())
        } else {
            VersionedPeer::Legacy(a)
        };
        let mut viewer = if viewer_current {
            VersionedPeer::Current(LinkCarrier::new(b, Role::Viewer, selection(answer)).unwrap())
        } else {
            VersionedPeer::Legacy(b)
        };
        for peer in [&host, &viewer] {
            if let VersionedPeer::Current(carrier) = peer {
                assert_eq!(
                    carrier.wire_name(),
                    if host_current && viewer_current { "rd_wg" } else { "link" }
                );
            }
        }
        let deadline = Instant::now() + Duration::from_secs(8);
        let (mut host_ready, mut viewer_ready) = (false, false);
        let (mut host_got, mut viewer_got) = (false, false);
        let mut sent = false;
        while !host_got || !viewer_got {
            let mut fds = host.fds();
            fds.extend(viewer.fds());
            crate::fdwait::wait_readable(&fds, Some(10_000_000)).unwrap();
            for (peer, ready, got, expected) in [
                (&mut host, &mut host_ready, &mut host_got, b"viewer-media".as_slice()),
                (&mut viewer, &mut viewer_ready, &mut viewer_got, b"host-media".as_slice()),
            ] {
                for event in peer.events() {
                    match event {
                        NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                            *ready = true
                        }
                        NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(data))) => {
                            assert_eq!(data, expected);
                            *got = true;
                        }
                        NetEvent::Failed(reason) => {
                            panic!("pair {host_current}/{viewer_current}: {reason}")
                        }
                        _ => {}
                    }
                }
            }
            if host_ready && viewer_ready && !sent {
                host.send(b"host-media");
                viewer.send(b"viewer-media");
                sent = true;
            }
            assert!(
                Instant::now() < deadline,
                "version pair {host_current}/{viewer_current} did not deliver media"
            );
        }
    }
}
#[test]
fn wg_selected_session_never_decodes_legacy_media_on_negotiation_failure() {
    let (a, legacy) = net_pair(false);
    a.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: legacy.local_addr() });
    legacy.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: a.local_addr() });
    let mut wg = LinkCarrier::new(a, Role::Host, LinkMode::Wg).unwrap();
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        let mut fds = wg.fds();
        fds.push(legacy.event_fd());
        crate::fdwait::wait_readable(&fds, Some(10_000_000)).unwrap();
        for event in legacy.events() {
            if matches!(event, NetEvent::Endpoint(EndpointEvent::Link(Event::Established))) {
                legacy.send_datagram(b"legacy media must not reach WG decoder".to_vec());
            }
        }
        let events = wg.events();
        assert_eq!(wg.wire_name(), "rd_wg");
        assert!(!wg.media_ready() && !wg.retry_ready());
        assert!(!events.iter().any(|event| matches!(
            event,
            NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(_) | Event::Established))
        )));
        if events.iter().any(|event| matches!(event, NetEvent::Failed(_))) {
            break;
        }
        assert!(Instant::now() < deadline, "unacknowledged WG failure did not end");
    }
}
