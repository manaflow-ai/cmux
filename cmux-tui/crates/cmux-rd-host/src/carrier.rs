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
    /// Path changes for the caller (the pane's path badge, the congestion controller).
    pub paths: Vec<cmux_rd_link::EndpointEvent>,
    /// The current path's round trip, until the engine reads it.
    pub rtt_us: Option<u64>,
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

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.net.send_datagram(datagram.to_vec());
        Ok(())
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        let record = serde_json::to_vec(control).map_err(io::Error::other)?;
        self.net.send_control(record);
        Ok(())
    }
}

/// The stream carrier plus the datagram link a viewer offered (dlink.rs):
/// control on the stream; datagrams on the link while it is up, else on the
/// stream; datagrams taken from both.
#[cfg(feature = "link")]
pub struct HybridCarrier<'a, S> {
    pub inner: SocketCarrier<'a, S>,
    pub link: cmux_rd_link::dlink::DatagramLink,
}

#[cfg(feature = "link")]
impl<S: Read + Write + AsRawFd> Carrier for HybridCarrier<'_, S> {
    fn fds(&self) -> Vec<RawFd> {
        let mut fds = self.inner.fds();
        fds.extend(self.link.fd());
        fds
    }

    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        use cmux_rd_link::dlink::{LinkOut, LinkState};
        let start = out.len();
        self.inner.receive(out)?;
        // The viewer's routes are the link's, not the session's.
        let mut i = start;
        while i < out.len() {
            if let Incoming::Control(Control::LinkCandidate { candidate }) = &out[i] {
                self.link.add_remote_candidate(candidate);
                out.remove(i);
            } else {
                i += 1;
            }
        }
        let mut produced = Vec::new();
        self.link.poll(&mut produced);
        for item in produced {
            match item {
                LinkOut::Datagram(d) => out.push(Incoming::Datagram(d)),
                LinkOut::Candidate(candidate) => {
                    // A lost route only costs the link a path; the stream is what matters.
                    let _ = self.inner.send_control(&Control::LinkCandidate { candidate });
                }
                LinkOut::State(LinkState::Up) => eprintln!("cmux-rd host: datagram link up"),
                LinkOut::State(LinkState::Quiet) => {
                    eprintln!("cmux-rd host: datagram link quiet; datagrams on the stream")
                }
                LinkOut::State(LinkState::Failed(reason)) => {
                    eprintln!(
                        "cmux-rd host: datagram link ended ({reason}); datagrams on the stream"
                    )
                }
            }
        }
        Ok(())
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        if self.link.is_up() {
            self.link.send_datagram(datagram);
            Ok(())
        } else {
            self.inner.send_datagram(datagram)
        }
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        self.inner.send_control(control)
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
mod hybrid_tests {
    use super::*;
    use cmux_rd_link::dlink::{DatagramLink, LinkOut, ViewerOffer};
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    /// The viewer's end of the stream: frames it reads.
    fn read_frames(viewer: &mut UnixStream, reader: &mut FrameReader) -> Vec<(u8, Vec<u8>)> {
        let _ = reader.fill(viewer);
        let mut frames = Vec::new();
        while let Ok(Some(frame)) = reader.next() {
            frames.push(frame);
        }
        frames
    }

    #[test]
    fn the_hybrid_carrier_moves_datagrams_to_the_link_once_it_is_up_and_keeps_control_on_the_stream(
    ) {
        let (mut host_end, mut viewer_end) = UnixStream::pair().unwrap();
        host_end.set_nonblocking(true).unwrap();
        viewer_end.set_nonblocking(true).unwrap();
        let bind: SocketAddr = "0.0.0.0:0".parse().unwrap();
        let offer = ViewerOffer::new(Vec::new()).unwrap();
        let (host_link, answer) = DatagramLink::accept(&offer.offer, bind).unwrap();
        let mut viewer_link = offer.start(&answer, bind).unwrap();
        let mut reader = FrameReader::default();
        let mut carrier = HybridCarrier {
            inner: SocketCarrier::new(&mut host_end, &mut reader, None, DatagramOut::Stream),
            link: host_link,
        };
        // Before the link is up: datagrams on the stream.
        carrier.send_datagram(b"early").unwrap();
        let mut viewer_reader = FrameReader::default();
        let early = read_frames(&mut viewer_end, &mut viewer_reader);
        assert!(early.contains(&(FRAME_DATAGRAM, b"early".to_vec())), "{early:?}");
        // Routes cross on the stream, as the dial would carry them.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut incoming = Vec::new();
        while Instant::now() < deadline && !(carrier.link.is_up() && viewer_link.is_up()) {
            carrier.receive(&mut incoming).unwrap();
            for (ty, payload) in read_frames(&mut viewer_end, &mut viewer_reader) {
                if ty == FRAME_CONTROL {
                    if let Ok(Control::LinkCandidate { candidate }) =
                        serde_json::from_slice(&payload)
                    {
                        viewer_link.add_remote_candidate(&candidate);
                    }
                }
            }
            let mut produced = Vec::new();
            viewer_link.poll(&mut produced);
            for item in produced {
                if let LinkOut::Candidate(candidate) = item {
                    write_control(&mut viewer_end, &Control::LinkCandidate { candidate }).unwrap();
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(carrier.link.is_up(), "host side up");
        // The routes never reach the media session.
        assert!(
            !incoming.iter().any(|i| matches!(i, Incoming::Control(Control::LinkCandidate { .. }))),
            "link_candidate is the carrier's"
        );
        // Once up: datagrams on the link, none on the stream; control still on the stream.
        carrier.send_datagram(b"frame").unwrap();
        carrier.send_control(&Control::Stop).unwrap();
        viewer_link.send_datagram(b"input");
        let deadline = Instant::now() + Duration::from_secs(5);
        let (mut on_link, mut input) = (false, false);
        let mut on_stream = Vec::new();
        while Instant::now() < deadline && !(on_link && input) {
            let mut produced = Vec::new();
            viewer_link.poll(&mut produced);
            on_link |= produced.contains(&LinkOut::Datagram(b"frame".to_vec()));
            let mut incoming = Vec::new();
            carrier.receive(&mut incoming).unwrap();
            input |= incoming.iter().any(|i| matches!(i, Incoming::Datagram(d) if d == b"input"));
            on_stream.extend(read_frames(&mut viewer_end, &mut viewer_reader));
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(on_link, "the frame took the link");
        assert!(input, "the viewer's datagram reached the session");
        assert!(!on_stream.iter().any(|(ty, _)| *ty == FRAME_DATAGRAM), "{on_stream:?}");
        assert!(
            on_stream.iter().any(|(ty, _)| *ty == FRAME_CONTROL),
            "control stays on the stream"
        );
    }
}
