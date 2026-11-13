//! What carries one session's control messages and datagrams, so the media
//! session (stream.rs) is the same over every carrier:
//! - [`SocketCarrier`]: a byte stream for control (and for datagrams when
//!   the viewer has no UDP) plus, on TCP, the host's UDP port: the development
//!   path admitted by the per-launch token, or the systemd socket of a Cloud
//!   machine admitted by the link (host.rs, systemd.rs);
//! - `LinkCarrier` (feature `link`): the secure link of a device hub session
//!   (cmux-rd-link), control records and sealed datagrams over whichever
//!   path the endpoint measured best.

use crate::wire::{
    write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
};
use std::io::{self, Read, Write};
use std::net::{SocketAddr, UdpSocket};
use std::os::fd::{AsRawFd, RawFd};

/// UDP datagrams read per wake.
const MAX_UDP_PER_WAKE: usize = 64;

/// One thing that arrived.
pub enum Incoming {
    Control(Control),
    Datagram(Vec<u8>),
}

pub trait Carrier {
    /// Readable when [`Carrier::receive`] may have something.
    fn fds(&self) -> Vec<RawFd>;
    /// Takes everything waiting, without blocking. `Err` ends the session with its reason.
    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String>;
    /// Returns the latest measured path RTT, if this carrier observed one.
    fn take_path_rtt_us(&mut self) -> Option<u64> {
        None
    }
    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()>;
    fn send_control(&mut self, control: &Control) -> io::Result<()>;
}

/// A control stream (TCP or Unix) plus, on TCP, the host's UDP socket.
pub struct SocketCarrier<'a, S> {
    pub stream: &'a mut S,
    pub reader: &'a mut FrameReader,
    /// `None` on a carrier without a UDP port (the systemd socket).
    pub udp: Option<&'a UdpSocket>,
    pub out: DatagramOut,
    /// Where the viewer's datagrams come from (UDP carrier); `None` on the stream carrier.
    pub peer_udp: Option<SocketAddr>,
}

impl<'a, S> SocketCarrier<'a, S> {
    pub fn new(
        stream: &'a mut S,
        reader: &'a mut FrameReader,
        udp: Option<&'a UdpSocket>,
        out: DatagramOut,
    ) -> Self {
        let peer_udp = match &out {
            DatagramOut::Udp { peer, .. } => Some(*peer),
            DatagramOut::Stream => None,
        };
        Self { stream, reader, udp, out, peer_udp }
    }
}

impl<S: Read + Write + AsRawFd> Carrier for SocketCarrier<'_, S> {
    fn fds(&self) -> Vec<RawFd> {
        let mut fds = vec![self.stream.as_raw_fd()];
        fds.extend(self.udp.map(AsRawFd::as_raw_fd));
        fds
    }

    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        // Control and stream-carried datagrams.
        self.reader.fill(self.stream).map_err(|e| format!("viewer closed: {e}"))?;
        loop {
            match self.reader.next() {
                Ok(Some((FRAME_CONTROL, payload))) => {
                    // A message the host does not know is ignored, as before.
                    if let Ok(control) = serde_json::from_slice::<Control>(&payload) {
                        out.push(Incoming::Control(control));
                    }
                }
                Ok(Some((FRAME_DATAGRAM, payload))) => out.push(Incoming::Datagram(payload)),
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(e) => return Err(format!("bad frame: {e}")),
            }
        }
        // UDP datagrams, only from the viewer's own socket, at most 64 per wake.
        let mut buf = vec![0u8; 65536];
        for _ in 0..MAX_UDP_PER_WAKE {
            let (Some(udp), Some(_)) = (self.udp, self.peer_udp) else {
                break;
            };
            match udp.recv_from(&mut buf) {
                Ok((n, from)) if Some(from) == self.peer_udp => {
                    out.push(Incoming::Datagram(buf[..n].to_vec()));
                }
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(format!("udp failed: {e}")),
            }
        }
        Ok(())
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.out.send(self.stream, datagram)
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        write_control(self.stream, control)
    }
}

/// A device hub session's secure link (cmux-rd-link's UDP driver).
#[cfg(feature = "link")]
pub struct LinkCarrier {
    pub net: cmux_rd_link::net::Net,
    wg: crate::wg_carrier::Negotiation,
    barrier: Option<std::sync::mpsc::Receiver<()>>,
    delivered: bool,
    fallback: Option<cmux_rd_proto::app_line::CarrierFallback>,
    terminal_emitted: bool,
    outer_established: bool,
    connected_emitted: bool,
    /// Path changes for the caller (the pane's path badge, the congestion controller).
    pub paths: Vec<cmux_rd_link::EndpointEvent>,
    /// The current path's round trip, until the engine reads it.
    pub rtt_us: Option<u64>,
}

#[cfg(feature = "link")]
impl Carrier for LinkCarrier {
    fn fds(&self) -> Vec<RawFd> {
        let mut fds = vec![self.net.event_fd()];
        fds.extend(self.wg.fd());
        fds
    }

    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        use cmux_rd_link::net::NetEvent;
        use cmux_rd_link::{EndpointEvent, Event};
        for event in self.events() {
            match event {
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                    out.push(Incoming::Datagram(d));
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    if let Ok(control) = serde_json::from_slice::<Control>(&record) {
                        out.push(Incoming::Control(control));
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    return Err("viewer closed the link".into());
                }
                cmux_rd_link::net::NetEvent::Failed(reason) => {
                    return Err(format!("link failed: {reason}"))
                }
                NetEvent::Endpoint(path @ EndpointEvent::PathChanged { rtt_us, .. }) => {
                    if rtt_us.is_some() {
                        self.rtt_us = rtt_us;
                    }
                    self.paths.push(path);
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn take_path_rtt_us(&mut self) -> Option<u64> {
        self.rtt_us.take()
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.wg.send(datagram)
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        let record = serde_json::to_vec(control).map_err(io::Error::other)?;
        self.net.send_control(record);
        Ok(())
    }
}

#[cfg(feature = "link")]
impl LinkCarrier {
    pub fn new(net: cmux_rd_link::net::Net, role: crate::wg_carrier::Role) -> io::Result<Self> {
        Ok(Self {
            net,
            wg: crate::wg_carrier::Negotiation::new(role)?,
            barrier: None,
            delivered: false,
            fallback: None,
            terminal_emitted: false,
            outer_established: false,
            connected_emitted: false,
            paths: Vec::new(),
            rtt_us: None,
        })
    }

    pub fn media_ready(&self) -> bool {
        self.connected_emitted && self.wg.state(false) == crate::wg_carrier::State::Ready
    }
    pub fn max_datagram(&self) -> usize {
        self.wg.max_datagram()
    }
    pub fn retry_ready(&self) -> bool {
        self.fallback.is_some()
    }
    pub fn take_fallback(&mut self) -> Option<cmux_rd_proto::app_line::CarrierFallback> {
        self.fallback.take()
    }
    pub fn invalidate(&mut self) {
        self.wg.invalidate();
        self.fallback = None;
    }

    /// Owns both event streams; WG ciphertext can never leak to the media decoder.
    pub fn events(&mut self) -> Vec<cmux_rd_link::net::NetEvent> {
        use crate::wg_carrier::State;
        use cmux_rd_link::net::NetEvent;
        use cmux_rd_link::{EndpointEvent, Event};
        let now = std::time::Instant::now();
        let sender = self.net.sender();
        let mut events = Vec::new();
        for event in self.net.events() {
            match event {
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    self.outer_established = true;
                    self.wg.begin(now);
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    if !self.wg.accept(&record, now) {
                        // A terminal control can never coexist with a transport retry.
                        if matches!(
                            serde_json::from_slice::<Control>(&record),
                            Ok(Control::Stop | Control::Ended { .. } | Control::Refused { .. })
                        ) {
                            self.invalidate();
                        }
                        events
                            .push(NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))));
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(datagram))) => {
                    self.wg.inject(datagram)
                }
                closed @ (NetEvent::Endpoint(EndpointEvent::Link(Event::Closed))
                | NetEvent::Failed(_)) => {
                    self.invalidate();
                    self.terminal_emitted = true;
                    events.push(closed);
                }
                other => events.push(other),
            }
        }
        self.wg.tick(&sender, now);
        if self.wg.ack_sent() && self.barrier.is_none() {
            self.barrier = Some(self.net.control_barrier());
        }
        if let Some(barrier) = &self.barrier {
            if matches!(barrier.try_recv(), Ok(())) {
                self.delivered = true;
            }
        }
        let state = self.wg.state(self.delivered);
        let mut decrypted = Vec::new();
        self.wg.receive(&mut decrypted);
        match state {
            State::Ready => {
                if self.outer_established && !self.connected_emitted {
                    self.connected_emitted = true;
                    self.wg.commit();
                    events.push(NetEvent::Endpoint(EndpointEvent::Link(Event::Established)));
                }
                events.extend(
                    decrypted
                        .into_iter()
                        .map(|d| NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d)))),
                );
            }
            State::Retry(reason) => self.fallback = Some(crate::wg_carrier::fallback(reason)),
            State::Failed if !self.terminal_emitted => {
                self.terminal_emitted = true;
                events.push(NetEvent::Failed(
                    "WG carrier failed or fallback was not acknowledged".into(),
                ));
            }
            _ => {}
        }
        events
    }
}

/// A TURN relay as the app passes it (the hub ticket's relays): `host:port` and
/// the long-term credential. Resolved to IPv4 here; an unresolvable one is skipped.
#[cfg(feature = "link")]
#[derive(serde::Deserialize)]
pub struct TurnSetup {
    pub addr: String,
    pub username: String,
    pub password: String,
}

#[cfg(feature = "link")]
pub fn turn_servers(setups: &[TurnSetup]) -> Vec<cmux_rd_link::net::TurnServer> {
    setups
        .iter()
        .filter_map(|t| {
            let addr = std::net::ToSocketAddrs::to_socket_addrs(&t.addr)
                .ok()?
                .find(SocketAddr::is_ipv4)?;
            Some(cmux_rd_link::net::TurnServer {
                addr,
                username: t.username.clone(),
                password: t.password.clone(),
            })
        })
        .collect()
}

#[cfg(test)]
#[cfg(feature = "link")]
mod wg_transport_tests {
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
        (LinkCarrier::new(a, Role::Host).unwrap(), LinkCarrier::new(b, Role::Viewer).unwrap())
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
            assert!(
                !ae.iter().chain(&be).any(|e| matches!(e, NetEvent::Failed(_))),
                "{ae:?} {be:?}"
            );
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
            br#"{"t":"wg_offer","version":255,"key":"00","address":"10.253.0.1","mtu":1088}"#
                .to_vec(),
        );
        let deadline = Instant::now() + Duration::from_secs(8);
        while !a.retry_ready() || !b.retry_ready() {
            let (ae, be) = step(&mut a, &mut b);
            assert!(!a.media_ready() && !b.media_ready());
            assert!(
                !ae.iter().chain(&be).any(|e| matches!(e, NetEvent::Failed(_))),
                "{ae:?} {be:?}"
            );
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
        let (mut a, mut b) =
            (LinkCarrier::new(a, Role::Host).unwrap(), LinkCarrier::new(b, Role::Viewer).unwrap());
        a.net.send_control(
            br#"{"t":"wg_offer","version":255,"key":"00","address":"10.253.0.1","mtu":1088}"#
                .to_vec(),
        );
        let deadline = Instant::now() + Duration::from_secs(8);
        while !a.retry_ready() && !b.retry_ready() {
            let (ae, be) = step(&mut a, &mut b);
            assert!(
                !ae.iter().chain(&be).any(|event| matches!(event, NetEvent::Failed(_))),
                "{ae:?} {be:?}"
            );
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
        let exit_deadline =
            Instant::now() + crate::wg_carrier::RETRY_TIMEOUT + Duration::from_secs(1);
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
            assert!(
                Instant::now() < exit_deadline,
                "lost final ACK left peer waiting indefinitely"
            );
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
}
