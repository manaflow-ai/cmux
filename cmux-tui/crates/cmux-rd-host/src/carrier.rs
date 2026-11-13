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

/// Selected by the authenticated offer/answer before either media protocol starts.
/// Only an omitted field selects legacy; unknown or null values fail deserialization.
#[cfg(feature = "link")]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Deserialize)]
pub enum LinkMode {
    #[default]
    #[serde(skip)]
    Legacy,
    #[serde(rename = "rd_wg/1")]
    Wg,
}

/// A device hub session's secure link (cmux-rd-link's UDP driver).
#[cfg(feature = "link")]
pub struct LinkCarrier {
    pub net: cmux_rd_link::net::Net,
    wg: Option<crate::wg_carrier::Negotiation>,
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
        fds.extend(self.wg.as_ref().and_then(crate::wg_carrier::Negotiation::fd));
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
        if self.terminal_emitted {
            return Err(io::Error::new(io::ErrorKind::NotConnected, "carrier closed"));
        }
        if let Some(wg) = &self.wg {
            wg.send(datagram)
        } else {
            self.net.send_datagram(datagram.to_vec());
            Ok(())
        }
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        let record = serde_json::to_vec(control).map_err(io::Error::other)?;
        self.net.send_control(record);
        Ok(())
    }
}

#[cfg(feature = "link")]
impl LinkCarrier {
    pub fn new(
        net: cmux_rd_link::net::Net,
        role: crate::wg_carrier::Role,
        mode: LinkMode,
    ) -> io::Result<Self> {
        Ok(Self {
            net,
            wg: match mode {
                LinkMode::Legacy => None,
                LinkMode::Wg => Some(crate::wg_carrier::Negotiation::new(role)?),
            },
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
        self.connected_emitted
            && !self.terminal_emitted
            && self.wg.as_ref().is_none_or(|wg| wg.state(false) == crate::wg_carrier::State::Ready)
    }
    pub fn max_datagram(&self) -> usize {
        self.wg.as_ref().map_or(
            1152 - cmux_rd_link::SEAL_OVERHEAD,
            crate::wg_carrier::Negotiation::max_datagram,
        )
    }
    pub fn wire_name(&self) -> &'static str {
        if self.wg.is_some() {
            "rd_wg"
        } else {
            "link"
        }
    }
    pub fn retry_ready(&self) -> bool {
        self.fallback.is_some()
    }
    pub fn take_fallback(&mut self) -> Option<cmux_rd_proto::app_line::CarrierFallback> {
        self.fallback.take()
    }
    pub fn invalidate(&mut self) {
        if let Some(wg) = &mut self.wg {
            wg.invalidate();
        }
        self.connected_emitted = false;
        self.fallback = None;
    }

    /// Owns both event streams; WG ciphertext can never leak to the media decoder.
    pub fn events(&mut self) -> Vec<cmux_rd_link::net::NetEvent> {
        use crate::wg_carrier::State;
        use cmux_rd_link::net::NetEvent;
        use cmux_rd_link::{EndpointEvent, Event};
        if self.wg.is_none() {
            let events = self.net.events();
            for event in &events {
                match event {
                    NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                        self.connected_emitted = true
                    }
                    NetEvent::Endpoint(EndpointEvent::Link(Event::Closed))
                    | NetEvent::Failed(_) => {
                        self.connected_emitted = false;
                        self.terminal_emitted = true;
                    }
                    _ => {}
                }
            }
            return events;
        }
        let now = std::time::Instant::now();
        let sender = self.net.sender();
        let mut events = Vec::new();
        for event in self.net.events() {
            let Some(wg) = self.wg.as_mut() else { break };
            match event {
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    self.outer_established = true;
                    wg.begin(now);
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    if !wg.accept(&record, now) {
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
                    wg.inject(datagram)
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
        let Some(wg) = self.wg.as_mut() else { return events };
        wg.tick(&sender, now);
        if wg.ack_sent() && self.barrier.is_none() {
            self.barrier = Some(self.net.control_barrier());
        }
        if let Some(barrier) = &self.barrier {
            if matches!(barrier.try_recv(), Ok(())) {
                self.delivered = true;
            }
        }
        let state = wg.state(self.delivered);
        let mut decrypted = Vec::new();
        wg.receive(&mut decrypted);
        match state {
            State::Ready => {
                if self.outer_established && !self.connected_emitted {
                    self.connected_emitted = true;
                    wg.commit();
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
mod wg_transport_tests;
