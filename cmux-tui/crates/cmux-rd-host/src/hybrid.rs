//! A Cloud machine's UDP media path (cap `link.udp`): control stays on the
//! systemd stream, which the carrier admitted, and media datagrams move to a
//! cmux-rd-link (Noise_XX over one UDP socket) once one of its paths answers.
//!
//! The viewer sends `link_offer` (its link key, a prologue and candidates) on
//! the stream after `welcome` lists `link.udp`; the host answers `link_answer`
//! with its own key and sends its candidates as `link_candidate`. Both keys
//! cross the carrier's authenticated stream, so the link trusts what the
//! carrier trusts and needs no other signaling. `link_state` tells the viewer
//! where media goes. Until a path answers, and whenever none does (no UDP
//! egress, a firewall, no candidate pair), media stays on the stream.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

/// What the host needs to offer `link.udp` (systemd mode; `--no-udp-link` turns it off).
#[derive(Debug, Clone, Default)]
pub struct LinkCfg {
    /// STUN servers for the host's reflexive candidate (`--link-stun`), as named.
    names: Vec<String>,
    /// Their IPv4 addresses once resolved. Shared by every session of this host.
    #[cfg_attr(not(feature = "link"), allow(dead_code))]
    resolved: Arc<Mutex<Stun>>,
}

/// How far resolving `--link-stun` got.
#[derive(Debug, Default)]
#[cfg_attr(not(feature = "link"), allow(dead_code))]
enum Stun {
    /// No session negotiated `link.udp` yet.
    #[default]
    Unasked,
    Resolving,
    Resolved(Vec<SocketAddr>),
}

impl LinkCfg {
    pub fn new(names: Vec<String>) -> Self {
        Self { names, resolved: Arc::default() }
    }

    /// Resolves the STUN names once, on their own thread, so neither a slow
    /// resolver nor an unresolvable name holds a session or stops the host. A
    /// name that does not resolve is left out. Nothing resolves (no socket
    /// opens) until a session negotiated `link.udp`.
    pub fn resolve_stun(&self) {
        let Ok(mut slot) = self.resolved.lock() else { return };
        if !matches!(*slot, Stun::Unasked) {
            return;
        }
        if self.names.is_empty() {
            *slot = Stun::Resolved(Vec::new());
            return;
        }
        *slot = Stun::Resolving;
        let (names, resolved) = (self.names.clone(), self.resolved.clone());
        let spawned = std::thread::Builder::new().name("rd-link-stun".into()).spawn(move || {
            let found: Vec<SocketAddr> = names
                .iter()
                .filter_map(|name| {
                    let found = std::net::ToSocketAddrs::to_socket_addrs(name.as_str())
                        .ok()
                        .and_then(|mut a| a.find(SocketAddr::is_ipv4));
                    if found.is_none() {
                        eprintln!("cmux-rd: link: --link-stun {name} did not resolve; left out");
                    }
                    found
                })
                .collect();
            if let Ok(mut slot) = resolved.lock() {
                *slot = Stun::Resolved(found);
            }
        });
        if spawned.is_err() {
            eprintln!("cmux-rd: link: no thread to resolve --link-stun; no reflexive candidate");
            *slot = Stun::Resolved(Vec::new());
        }
    }

    /// The STUN servers resolved so far (none while they are still resolving).
    #[cfg(all(test, feature = "link"))]
    pub fn stun(&self) -> Vec<SocketAddr> {
        match self.resolved.lock().as_deref() {
            Ok(Stun::Resolved(found)) => found.clone(),
            _ => Vec::new(),
        }
    }

    /// The STUN servers resolved so far and, while they are still resolving,
    /// the list when it arrives ([`cmux_rd_link::net::Net::add_stun_later`]),
    /// so the first session on a fresh machine still gets its reflexive candidate.
    #[cfg(feature = "link")]
    pub fn stun_now_or_later(
        &self,
    ) -> (Vec<SocketAddr>, Option<cmux_rd_link::net::Later<SocketAddr>>) {
        match self.resolved.lock().as_deref() {
            Ok(Stun::Resolved(found)) => (found.clone(), None),
            Ok(Stun::Resolving) => {
                let resolved = self.resolved.clone();
                let later: cmux_rd_link::net::Later<SocketAddr> =
                    Box::new(move || match resolved.lock().as_deref() {
                        Ok(Stun::Resolving) => None,
                        Ok(Stun::Resolved(found)) => Some(found.clone()),
                        // Poisoned, or never asked: nothing more will come.
                        _ => Some(Vec::new()),
                    });
                (Vec::new(), Some(later))
            }
            _ => (Vec::new(), None),
        }
    }
}

/// Datagrams larger than this stay on the stream (the link seals each one).
#[cfg(feature = "link")]
pub const LINK_MAX_DATAGRAM: usize = 1152 - cmux_rd_link::SEAL_OVERHEAD;
/// Candidates taken from the viewer per offer.
#[cfg(feature = "link")]
const MAX_CANDIDATES: usize = 16;
/// Offers per session: a viewer may offer again after its network changed.
#[cfg(feature = "link")]
const MAX_OFFERS: u32 = 8;
#[cfg(feature = "link")]
const MAX_PROLOGUE: usize = 128;

#[cfg(feature = "link")]
pub use with_link::HybridCarrier;

#[cfg(feature = "link")]
mod with_link {
    use super::{LinkCfg, LINK_MAX_DATAGRAM, MAX_CANDIDATES, MAX_OFFERS, MAX_PROLOGUE};
    use crate::carrier::{Carrier, Incoming, SocketCarrier};
    use crate::wire::Control;
    use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
    use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
    use std::io::{self, Read, Write};
    use std::net::SocketAddr;
    use std::os::fd::{AsRawFd, RawFd};

    /// The stream carrier plus, after an offer, the link that carries media.
    pub struct HybridCarrier<'a, S> {
        stream: SocketCarrier<'a, S>,
        cfg: LinkCfg,
        net: Option<Net>,
        /// A link path answers: datagrams go on the link.
        up: bool,
        offers: u32,
        candidates: usize,
        incoming: Vec<Incoming>,
        path_rtt_us: Option<u64>,
    }

    impl<'a, S: Read + Write + AsRawFd> HybridCarrier<'a, S> {
        pub fn new(stream: SocketCarrier<'a, S>, cfg: LinkCfg) -> Self {
            Self {
                stream,
                cfg,
                net: None,
                up: false,
                offers: 0,
                candidates: 0,
                incoming: Vec::new(),
                path_rtt_us: None,
            }
        }

        /// Datagrams go on the link now.
        #[cfg(test)]
        pub fn is_up(&self) -> bool {
            self.up
        }

        /// As if a link path answered (the replacement test needs no second handshake).
        #[cfg(test)]
        pub fn force_up(&mut self) {
            self.up = true;
        }

        fn state(&mut self, up: bool, reason: Option<String>) -> io::Result<()> {
            if let Some(reason) = &reason {
                eprintln!("cmux-rd host: udp link down: {reason}");
            }
            self.up = up;
            self.stream.send_control(&Control::LinkState { up, reason })
        }

        /// Starts (or restarts) the link for an offer; a bad offer leaves media on the stream.
        fn on_offer(
            &mut self,
            session: String,
            key: String,
            candidates: Vec<String>,
        ) -> io::Result<()> {
            self.offers += 1;
            // Dropping the old link closes it; media is on the stream until the new one answers,
            // and the viewer hears so before the answer.
            self.net = None;
            self.candidates = 0;
            if self.up {
                self.state(false, Some("replaced by a new offer".into()))?;
            }
            let refused = if self.offers > MAX_OFFERS {
                Some(format!("more than {MAX_OFFERS} offers"))
            } else if session.is_empty() || session.len() > MAX_PROLOGUE {
                Some("bad session".to_owned())
            } else {
                None
            };
            if let Some(reason) = refused {
                return self.state(false, Some(reason));
            }
            let Some(expected_remote) = crate::serve::unhex32(&key) else {
                return self.state(false, Some("key must be 64 hex characters".into()));
            };
            let keys = match KeyPair::generate() {
                Ok(k) => k,
                Err(e) => return self.state(false, Some(format!("link key: {e}"))),
            };
            let public = crate::serve::hex(&keys.public);
            let (stun, stun_later) = self.cfg.stun_now_or_later();
            let net = match Net::start(NetConfig {
                role: Role::Responder,
                session: session.into_bytes(),
                local: keys,
                expected_remote,
                stun,
                bind: SocketAddr::from(([0, 0, 0, 0], 0)),
                turn: Vec::new(),
                relay_only: false,
            }) {
                Ok(n) => n,
                Err(e) => return self.state(false, Some(format!("link start: {e}"))),
            };
            if let Some(later) = stun_later {
                net.add_stun_later(later);
            }
            self.net = Some(net);
            self.up = false;
            self.stream.send_control(&Control::LinkAnswer { key: public })?;
            for c in candidates {
                self.on_candidate(&c);
            }
            Ok(())
        }

        fn on_candidate(&mut self, wire: &str) {
            let (Some(net), Some(c)) = (&self.net, Candidate::from_wire(wire)) else {
                return;
            };
            if self.candidates < MAX_CANDIDATES {
                self.candidates += 1;
                net.add_remote_candidate(c);
            }
        }

        /// The link's events: candidates go to the viewer, datagrams in, path changes
        /// move media between the link and the stream.
        fn pump_link(&mut self, out: &mut Vec<Incoming>) -> io::Result<()> {
            let Some(net) = &self.net else {
                return Ok(());
            };
            for event in net.events() {
                match event {
                    NetEvent::Candidate(c) => self
                        .stream
                        .send_control(&Control::LinkCandidate { candidate: c.to_wire() })?,
                    NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                        out.push(Incoming::Datagram(d));
                    }
                    NetEvent::Endpoint(EndpointEvent::PathChanged { route, rtt_us, .. }) => {
                        if rtt_us.is_some() {
                            self.path_rtt_us = rtt_us;
                        }
                        match (route.is_some(), self.up) {
                            (true, false) => self.state(true, None)?,
                            (false, true) => {
                                self.state(false, Some("no link path answers".into()))?
                            }
                            _ => {}
                        }
                    }
                    NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                        self.net = None;
                        return self.state(false, Some("viewer closed the link".into()));
                    }
                    NetEvent::Failed(reason) => {
                        self.net = None;
                        return self.state(false, Some(format!("link failed: {reason}")));
                    }
                    // Control stays on the stream; a record on the link is not used.
                    _ => {}
                }
            }
            Ok(())
        }
    }

    impl<S: Read + Write + AsRawFd> Carrier for HybridCarrier<'_, S> {
        fn fds(&self) -> Vec<RawFd> {
            let mut fds = self.stream.fds();
            fds.extend(self.net.as_ref().map(Net::event_fd));
            fds
        }

        fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
            let mut incoming = std::mem::take(&mut self.incoming);
            let received = self.stream.receive(&mut incoming);
            let mut answered = Ok(());
            for item in incoming.drain(..) {
                let result = match item {
                    Incoming::Control(Control::LinkOffer { session, key, candidates }) => {
                        self.on_offer(session, key, candidates)
                    }
                    Incoming::Control(Control::LinkCandidate { candidate }) => {
                        self.on_candidate(&candidate);
                        Ok(())
                    }
                    // Host-to-viewer messages are not taken from the viewer.
                    Incoming::Control(Control::LinkAnswer { .. } | Control::LinkState { .. }) => {
                        Ok(())
                    }
                    other => {
                        out.push(other);
                        Ok(())
                    }
                };
                if answered.is_ok() {
                    answered = result;
                }
            }
            self.incoming = incoming;
            received?;
            answered.map_err(|e| format!("control write failed: {e}"))?;
            self.pump_link(out).map_err(|e| format!("control write failed: {e}"))
        }

        fn take_path_rtt_us(&mut self) -> Option<u64> {
            self.path_rtt_us.take()
        }

        fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
            match &self.net {
                Some(net) if self.up && datagram.len() <= LINK_MAX_DATAGRAM => {
                    net.send_datagram(datagram.to_vec());
                    Ok(())
                }
                _ => self.stream.send_datagram(datagram),
            }
        }

        fn send_control(&mut self, control: &Control) -> io::Result<()> {
            self.stream.send_control(control)
        }
    }
}

/// Parses `--link-stun HOST:PORT[,HOST:PORT...]`. Only the form is checked
/// here (a malformed entry is an error); names resolve later
/// ([`LinkCfg::resolve_stun`]), and one that does not is left out.
pub fn stun_names(list: Option<&str>) -> Result<Vec<String>, String> {
    let Some(list) = list else {
        return Ok(Vec::new());
    };
    list.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| {
            let ok = s.rsplit_once(':').is_some_and(|(host, port)| {
                !host.is_empty() && host.len() <= 253 && port.parse::<u16>().is_ok_and(|p| p > 0)
            });
            ok.then(|| s.to_owned()).ok_or_else(|| format!("--link-stun {s}: not HOST:PORT"))
        })
        .collect()
}

#[cfg(all(test, feature = "link"))]
mod tests;
