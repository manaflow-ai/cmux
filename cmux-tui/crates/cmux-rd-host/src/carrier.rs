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
    /// The current media route's measured RTT. Reads do not consume it;
    /// None means the current route needs frame-ACK based sizing.
    fn path_rtt_us(&self) -> Option<u64> {
        None
    }
    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()>;
    /// Sends one complete encoded frame. Lossy carriers may replace an older
    /// pending frame, but control traffic remains independent and reliable.
    fn send_datagram_frame(&mut self, datagrams: Vec<Vec<u8>>, _droppable: bool) -> io::Result<()> {
        for datagram in &datagrams {
            self.send_datagram(datagram)?;
        }
        Ok(())
    }
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
                        out.push(Incoming::Control(control));
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

#[cfg(all(test, feature = "link"))]
mod path_tests {
    use super::*;
    use cmux_rd_link::net::{Net, NetConfig};
    use cmux_rd_link::{EndpointEvent, KeyPair, Role, Route};

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
