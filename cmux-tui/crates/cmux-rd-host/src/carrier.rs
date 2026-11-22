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
pub use cmux_rd_proto::DatagramDeparture;
use cmux_rd_proto::{DatagramHeader, MAX_DEPARTURE_RECEIPTS};
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, UdpSocket};
use std::os::fd::{AsRawFd, RawFd};

/// UDP datagrams read per wake.
const MAX_UDP_PER_WAKE: usize = 64;

/// One thing that arrived.
pub enum Incoming {
    /// Boxed: a stats message is hundreds of bytes, a datagram is a `Vec` header.
    Control(Box<Control>),
    Datagram(Vec<u8>),
}

/// A snapshot of the bounded link media queue, included in host stats when
/// the session is using cmux-rd-link.
#[derive(Debug, Clone, Copy, Default)]
pub struct MediaQueueStats {
    pub queue_frames: usize,
    pub queue_datagrams: usize,
    pub dropped_frames: u64,
    pub dropped_datagrams: u64,
    pub dropped_replaced_frames: u64,
    pub dropped_replaced_datagrams: u64,
    pub dropped_evicted_for_protected_frames: u64,
    pub dropped_evicted_for_protected_datagrams: u64,
    pub dropped_rejected_protected_frames: u64,
    pub dropped_rejected_protected_datagrams: u64,
}

#[cfg(feature = "link")]
impl From<cmux_rd_link::net::NetStats> for MediaQueueStats {
    fn from(stats: cmux_rd_link::net::NetStats) -> Self {
        Self {
            queue_frames: stats.queue_frames,
            queue_datagrams: stats.queue_datagrams,
            dropped_frames: stats.dropped_frames,
            dropped_datagrams: stats.dropped_datagrams,
            dropped_replaced_frames: stats.dropped_replaced_frames,
            dropped_replaced_datagrams: stats.dropped_replaced_datagrams,
            dropped_evicted_for_protected_frames: stats.dropped_evicted_for_protected_frames,
            dropped_evicted_for_protected_datagrams: stats.dropped_evicted_for_protected_datagrams,
            dropped_rejected_protected_frames: stats.dropped_rejected_protected_frames,
            dropped_rejected_protected_datagrams: stats.dropped_rejected_protected_datagrams,
        }
    }
}

pub trait Carrier {
    /// Append a bounded batch of successful transport writes, never enqueue times.
    /// Each adapter must preserve the underlying transport's observations.
    fn drain_departures(&mut self, out: &mut Vec<DatagramDeparture>);
    /// Lost observations (not lost media). Consumers must mark affected timings incomplete.
    fn departure_overflows(&self) -> u64;

    /// Readable when [`Carrier::receive`] may have something.
    fn fds(&self) -> Vec<RawFd>;
    /// Takes everything waiting, without blocking. `Err` ends the session with its reason.
    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String>;
    /// The current media route's measured RTT. Reads do not consume it;
    /// None means the current route needs frame-ACK based sizing.
    fn path_rtt_us(&self) -> Option<u64> {
        None
    }
    fn media_queue_stats(&self) -> Option<MediaQueueStats> {
        None
    }
    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()>;
    /// Sends one complete encoded frame. Lossy carriers may replace an older
    /// pending frame, but control traffic remains independent and reliable.
    /// Every adapter must explicitly preserve the frame boundary or choose
    /// a transport fallback; a per-datagram default silently bypasses queues.
    fn send_datagram_frame(&mut self, datagrams: Vec<Vec<u8>>, droppable: bool) -> io::Result<()>;
    fn send_control(&mut self, control: &Control) -> io::Result<()>;
}

/// A control stream (TCP or Unix) plus, on TCP, the host's UDP socket.
pub struct SocketCarrier<'a, S> {
    departures: VecDeque<DatagramDeparture>,
    departure_overflows: u64,
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
        Self {
            stream,
            reader,
            udp,
            out,
            peer_udp,
            departures: VecDeque::new(),
            departure_overflows: 0,
        }
    }
}

impl<S: Read + Write + AsRawFd> Carrier for SocketCarrier<'_, S> {
    fn drain_departures(&mut self, out: &mut Vec<DatagramDeparture>) {
        out.extend(self.departures.drain(..));
    }

    fn departure_overflows(&self) -> u64 {
        self.departure_overflows
    }

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
                        out.push(Incoming::Control(Box::new(control)));
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
        let header = DatagramHeader::decode(datagram).ok().map(|(header, _)| header);
        if let Some(wire_bytes) = self.out.send_observed(self.stream, datagram)? {
            let departed_us = crate::clock::now_ns() / 1000;
            if let Some(header) = header.filter(|header| {
                matches!(
                    header.kind,
                    cmux_rd_proto::DatagramKind::Video
                        | cmux_rd_proto::DatagramKind::Fec
                        | cmux_rd_proto::DatagramKind::UpMedia
                )
            }) {
                if self.departures.len() < MAX_DEPARTURE_RECEIPTS {
                    self.departures.push_back(DatagramDeparture {
                        header,
                        departed_us,
                        wire_bytes,
                    });
                } else {
                    self.departure_overflows = self.departure_overflows.saturating_add(1);
                }
            }
        }
        Ok(())
    }

    fn send_datagram_frame(&mut self, datagrams: Vec<Vec<u8>>, _droppable: bool) -> io::Result<()> {
        // This carrier sends synchronously and owns no replaceable frame queue.
        for datagram in datagrams {
            self.send_datagram(&datagram)?;
        }
        Ok(())
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        write_control(self.stream, control)
    }
}

/// A device hub session's secure link (cmux-rd-link's UDP driver).
#[cfg(feature = "link")]
pub struct LinkCarrier {
    pub net: cmux_rd_link::net::Net,
    /// Path changes for the caller (the pane's path badge, the congestion controller).
    pub paths: Vec<cmux_rd_link::EndpointEvent>,
    /// The current path's round trip, retained between path events.
    pub rtt_us: Option<u64>,
}

#[cfg(feature = "link")]
impl LinkCarrier {
    /// Both setup and media processing retain only the current route's RTT.
    pub(crate) fn record_path(&mut self, path: cmux_rd_link::EndpointEvent) {
        if let cmux_rd_link::EndpointEvent::PathChanged { route, rtt_us, .. } = &path {
            self.rtt_us = route.and(*rtt_us);
            self.paths.push(path);
        }
    }
}

#[cfg(feature = "link")]
impl Carrier for LinkCarrier {
    fn drain_departures(&mut self, out: &mut Vec<DatagramDeparture>) {
        self.net.drain_departures(out);
    }

    fn departure_overflows(&self) -> u64 {
        self.net.departure_overflows()
    }

    fn fds(&self) -> Vec<RawFd> {
        vec![self.net.event_fd()]
    }

    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        use cmux_rd_link::net::NetEvent;
        use cmux_rd_link::{EndpointEvent, Event};
        for event in self.net.events() {
            match event {
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                    out.push(Incoming::Datagram(d));
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    if let Ok(control) = serde_json::from_slice::<Control>(&record) {
                        out.push(Incoming::Control(Box::new(control)));
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    return Err("viewer closed the link".into());
                }
                NetEvent::Failed(reason) => return Err(format!("link failed: {reason}")),
                NetEvent::Endpoint(path @ EndpointEvent::PathChanged { .. }) => {
                    self.record_path(path);
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn path_rtt_us(&self) -> Option<u64> {
        self.rtt_us
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.net.send_datagram(datagram.to_vec());
        Ok(())
    }

    fn send_datagram_frame(&mut self, datagrams: Vec<Vec<u8>>, droppable: bool) -> io::Result<()> {
        self.net.send_datagram_frame(datagrams, droppable);
        Ok(())
    }

    fn media_queue_stats(&self) -> Option<MediaQueueStats> {
        Some(self.net.stats().into())
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        let record = serde_json::to_vec(control).map_err(io::Error::other)?;
        self.net.send_control(record);
        Ok(())
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

/// Public STUN servers a session asks when its hub ticket names none. The hub hands out
/// STUN and TURN only with the cmux relay (a plan that includes it, workers/device-hub
/// `mintTurn`), so without it both ends gathered host candidates alone, and two machines with
/// no shared network (a Mac at home, a cloud VM) had nothing to punch through with. A STUN
/// server only tells each side its public address; no session traffic goes through it.
#[cfg(feature = "link")]
pub const FALLBACK_STUN: [&str; 2] = ["stun.cloudflare.com:3478", "stun.l.google.com:19302"];

/// The link's STUN servers: the ticket's `names`, resolved now (IPv4), or, when it names none
/// and the session is not relay only, [`FALLBACK_STUN`] resolving off the session's path
/// (for [`cmux_rd_link::net::Net::add_stun_later`]), so a slow resolver never delays a start.
#[cfg(feature = "link")]
pub fn stun_servers(
    names: &[String],
    relay_only: bool,
) -> (Vec<SocketAddr>, Option<cmux_rd_link::net::Later<SocketAddr>>) {
    if !names.is_empty() || relay_only {
        return (resolve_ipv4(names.iter().map(String::as_str)), None);
    }
    let found = std::sync::Arc::new(std::sync::Mutex::new(None));
    let slot = std::sync::Arc::clone(&found);
    let spawned = std::thread::Builder::new().name("cmux-rd-stun".into()).spawn(move || {
        let servers = resolve_ipv4(FALLBACK_STUN.into_iter());
        *slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(servers);
    });
    if spawned.is_err() {
        return (Vec::new(), None);
    }
    let later: cmux_rd_link::net::Later<SocketAddr> =
        Box::new(move || found.lock().unwrap_or_else(|e| e.into_inner()).take());
    (Vec::new(), Some(later))
}

/// Each `host:port` resolved to its first IPv4 address; an unresolvable one is skipped.
#[cfg(feature = "link")]
fn resolve_ipv4<'a>(names: impl Iterator<Item = &'a str>) -> Vec<SocketAddr> {
    names
        .filter_map(|s| std::net::ToSocketAddrs::to_socket_addrs(s).ok()?.find(SocketAddr::is_ipv4))
        .collect()
}

#[cfg(all(test, feature = "link"))]
mod path_tests {
    use super::*;
    use cmux_rd_link::net::{Net, NetConfig};
    use cmux_rd_link::{EndpointEvent, KeyPair, Role, Route};

    #[test]
    fn a_ticket_without_stun_falls_back_to_public_stun_unless_relay_only() {
        // The ticket's servers resolve now and nothing comes later.
        let (now, later) = stun_servers(&["127.0.0.1:3478".to_owned()], false);
        assert_eq!(now, vec!["127.0.0.1:3478".parse::<SocketAddr>().expect("addr")]);
        assert!(later.is_none());
        // None in the ticket: the fallback resolves off the start path.
        let (now, later) = stun_servers(&[], false);
        assert!(now.is_empty());
        assert!(later.is_some(), "a ticket with no STUN still gets a reflexive candidate");
        // Relay only never asks a STUN server.
        let (now, later) = stun_servers(&[], true);
        assert!(now.is_empty() && later.is_none());
    }

    fn carrier() -> LinkCarrier {
        let net = Net::start(NetConfig {
            role: Role::Responder,
            session: b"startup-path-rtt".to_vec(),
            local: KeyPair::generate().expect("local key"),
            expected_remote: KeyPair::generate().expect("peer key").public,
            stun: Vec::new(),
            bind: "127.0.0.1:0".parse().expect("bind"),
            turn: Vec::new(),
            relay_only: false,
        })
        .expect("link");
        LinkCarrier { net, paths: Vec::new(), rtt_us: None }
    }

    fn path(route: Option<Route>, rtt_us: Option<u64>) -> EndpointEvent {
        EndpointEvent::PathChanged { route, kind: None, medium: None, rtt_us }
    }

    fn assert_startup_forgets_rtt(next: EndpointEvent) {
        let mut carrier = carrier();
        let initial = path(Some(Route::Udp("127.0.0.1:4001".parse().unwrap())), Some(10_000));
        carrier.record_path(initial.clone());
        assert_eq!(carrier.path_rtt_us(), Some(10_000));
        carrier.record_path(next.clone());
        assert_eq!(carrier.path_rtt_us(), None, "startup must not retain the old route's RTT");
        assert_eq!(carrier.paths, vec![initial, next], "path badges still receive both changes");
    }

    #[test]
    fn startup_path_forgets_rtt_when_route_is_withdrawn() {
        assert_startup_forgets_rtt(path(None, None));
        assert_startup_forgets_rtt(path(None, Some(10_000)));
    }

    #[test]
    fn startup_path_forgets_rtt_when_replacement_is_unmeasured() {
        let route = Route::Udp("127.0.0.1:4002".parse().unwrap());
        assert_startup_forgets_rtt(path(Some(route), None));
    }
}

#[cfg(test)]
mod departure_tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    #[test]
    fn socket_departure_receipts_bound_storage_and_preserve_success_metadata() {
        let (mut stream, _peer_stream) = UnixStream::pair().unwrap();
        let peer = UdpSocket::bind("127.0.0.1:0").unwrap();
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        let mut reader = FrameReader::default();
        let mut carrier = SocketCarrier::new(
            &mut stream,
            &mut reader,
            None,
            DatagramOut::Udp { sock: socket, peer: peer.local_addr().unwrap() },
        );
        let header = DatagramHeader {
            flags: 0,
            kind: cmux_rd_proto::DatagramKind::Video,
            stream: 9,
            frame: 20,
            index: 0,
            count: 1,
            fec_count: 0,
            transport_seq: 200,
        };
        let packet = header.encode();
        let before = crate::clock::now_ns() / 1000;
        for _ in 0..MAX_DEPARTURE_RECEIPTS + 2 {
            carrier.send_datagram(&packet).unwrap();
        }
        let after = crate::clock::now_ns() / 1000;
        assert_eq!(carrier.departure_overflows(), 2);
        let mut receipts = Vec::new();
        carrier.drain_departures(&mut receipts);
        assert_eq!(receipts.len(), MAX_DEPARTURE_RECEIPTS);
        assert!(receipts.iter().all(|r| r.header == header
            && r.wire_bytes == packet.len()
            && (before..=after).contains(&r.departed_us)));
        // An oversized UDP send fails, and cannot be counted as a departure.
        let mut oversized = packet.to_vec();
        oversized.resize(65_536, 0);
        assert!(carrier.send_datagram(&oversized).is_err());
        receipts.clear();
        carrier.drain_departures(&mut receipts);
        assert!(receipts.is_empty());

        let input = DatagramHeader { kind: cmux_rd_proto::DatagramKind::Input, ..header }.encode();
        carrier.send_datagram(&input).unwrap();
        receipts.clear();
        carrier.drain_departures(&mut receipts);
        assert!(receipts.is_empty(), "control/input datagrams never become media receipts");
    }
}
