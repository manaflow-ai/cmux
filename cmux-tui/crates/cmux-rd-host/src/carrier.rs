//! What carries one session's control messages and datagrams, so the media
//! session (stream.rs) is the same over every carrier:
//! - [`SocketCarrier`]: the development path, a TCP stream for control (and
//!   for datagrams when the viewer has no UDP) plus the host's UDP port,
//!   admitted by the per-launch token (host.rs);
//! - `LinkCarrier` (feature `link`): the secure link of a device hub session
//!   (cmux-rd-link), control records and sealed datagrams over whichever
//!   path the endpoint measured best.

use crate::wire::{
    write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
};
use std::io;
use std::net::{SocketAddr, TcpStream, UdpSocket};
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

/// The development carrier: TCP control stream plus the host's UDP socket.
pub struct SocketCarrier<'a> {
    pub stream: &'a mut TcpStream,
    pub reader: &'a mut FrameReader,
    pub udp: &'a UdpSocket,
    pub out: DatagramOut,
    /// Where the viewer's datagrams come from (UDP carrier); `None` on the stream carrier.
    pub peer_udp: Option<SocketAddr>,
}

impl<'a> SocketCarrier<'a> {
    pub fn new(
        stream: &'a mut TcpStream,
        reader: &'a mut FrameReader,
        udp: &'a UdpSocket,
        out: DatagramOut,
    ) -> Self {
        let peer_udp = match &out {
            DatagramOut::Udp { peer, .. } => Some(*peer),
            DatagramOut::Stream => None,
        };
        Self { stream, reader, udp, out, peer_udp }
    }
}

impl Carrier for SocketCarrier<'_> {
    fn fds(&self) -> Vec<RawFd> {
        vec![self.stream.as_raw_fd(), self.udp.as_raw_fd()]
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
            if self.peer_udp.is_none() {
                break;
            }
            match self.udp.recv_from(&mut buf) {
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
                    self.paths.push(path)
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
