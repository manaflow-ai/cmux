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
    /// Their IPv4 addresses once resolved; `None` before the first session that
    /// negotiated `link.udp` asked. Shared by every session of this host.
    #[cfg_attr(not(feature = "link"), allow(dead_code))]
    resolved: Arc<Mutex<Option<Vec<SocketAddr>>>>,
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
        if slot.is_some() {
            return;
        }
        if self.names.is_empty() {
            *slot = Some(Vec::new());
            return;
        }
        *slot = Some(Vec::new());
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
                *slot = Some(found);
            }
        });
        if spawned.is_err() {
            eprintln!("cmux-rd: link: no thread to resolve --link-stun; no reflexive candidate");
        }
    }

    /// The STUN servers resolved so far (none while they are still resolving).
    #[cfg_attr(not(feature = "link"), allow(dead_code))]
    pub fn stun(&self) -> Vec<SocketAddr> {
        self.resolved.lock().ok().and_then(|s| s.clone()).unwrap_or_default()
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
            let net = match Net::start(NetConfig {
                role: Role::Responder,
                session: session.into_bytes(),
                local: keys,
                expected_remote,
                stun: self.cfg.stun(),
                bind: SocketAddr::from(([0, 0, 0, 0], 0)),
                turn: Vec::new(),
                relay_only: false,
            }) {
                Ok(n) => n,
                Err(e) => return self.state(false, Some(format!("link start: {e}"))),
            };
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
                    NetEvent::Endpoint(EndpointEvent::PathChanged { route, .. }) => {
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
mod tests {
    use super::*;
    use crate::carrier::{Carrier, Incoming, SocketCarrier};
    use crate::wire::{
        write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
    };
    use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
    use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    /// The viewer's end of the stream: reads frames, writes controls.
    struct Viewer {
        stream: UnixStream,
        reader: FrameReader,
    }

    impl Viewer {
        fn frames(&mut self) -> Vec<(u8, Vec<u8>)> {
            let _ = self.reader.fill(&mut self.stream);
            let mut out = Vec::new();
            while let Ok(Some(f)) = self.reader.next() {
                out.push(f);
            }
            out
        }
    }

    fn controls(frames: &[(u8, Vec<u8>)]) -> Vec<Control> {
        frames
            .iter()
            .filter(|(ty, _)| *ty == FRAME_CONTROL)
            .filter_map(|(_, p)| serde_json::from_slice(p).ok())
            .collect()
    }

    fn pair() -> (UnixStream, Viewer) {
        let (host, viewer) = UnixStream::pair().expect("pair");
        host.set_nonblocking(true).expect("nb");
        viewer.set_nonblocking(true).expect("nb");
        (host, Viewer { stream: viewer, reader: FrameReader::default() })
    }

    #[test]
    fn media_stays_on_the_stream_until_an_offer_and_a_bad_offer_says_why() {
        let (mut host, mut viewer) = pair();
        let mut reader = FrameReader::default();
        let stream = SocketCarrier::new(&mut host, &mut reader, None, DatagramOut::Stream);
        let mut carrier = HybridCarrier::new(stream, LinkCfg::default());
        carrier.send_datagram(b"frame").expect("send");
        let frames = viewer.frames();
        assert!(frames.iter().any(|(ty, p)| *ty == FRAME_DATAGRAM && p == b"frame"));
        write_control(
            &mut viewer.stream,
            &Control::LinkOffer { session: "s".into(), key: "zz".into(), candidates: vec![] },
        )
        .expect("offer");
        write_control(&mut viewer.stream, &Control::Stop).expect("stop");
        let mut out = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(2);
        while out.is_empty() && Instant::now() < deadline {
            carrier.receive(&mut out).expect("receive");
        }
        // The link messages are the carrier's; the session sees only the rest.
        assert!(matches!(out.as_slice(), [Incoming::Control(Control::Stop)]));
        let states = controls(&viewer.frames());
        assert!(
            states.iter().any(|c| matches!(c, Control::LinkState { up: false, reason: Some(r) } if r.contains("64 hex"))),
            "{states:?}"
        );
        assert!(!carrier.is_up());
    }

    /// The whole exchange on loopback: offer, answer and candidates on the stream,
    /// then media on the link, and back to the stream when the viewer closes it.
    #[test]
    fn an_offer_moves_media_onto_the_link_and_a_close_moves_it_back() {
        let (mut host, mut viewer) = pair();
        let mut reader = FrameReader::default();
        let stream = SocketCarrier::new(&mut host, &mut reader, None, DatagramOut::Stream);
        let mut carrier = HybridCarrier::new(stream, LinkCfg::default());
        let keys = KeyPair::generate().expect("keys");
        let viewer_key = crate::serve::hex(&keys.public);
        let mut viewer_net: Option<Net> = None;
        let mut pending_keys = Some(keys);
        write_control(
            &mut viewer.stream,
            &Control::LinkOffer { session: "cloud-1".into(), key: viewer_key, candidates: vec![] },
        )
        .expect("offer");
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut got = Vec::new();
        let mut out = Vec::new();
        while Instant::now() < deadline
            && !(carrier.is_up() && got.iter().any(|d: &Vec<u8>| d == b"up"))
        {
            carrier.receive(&mut out).expect("receive");
            for item in out.drain(..) {
                if let Incoming::Datagram(d) = item {
                    got.push(d);
                }
            }
            for control in controls(&viewer.frames()) {
                match control {
                    Control::LinkAnswer { key } => {
                        let net = Net::start(NetConfig {
                            role: Role::Initiator,
                            session: b"cloud-1".to_vec(),
                            local: pending_keys.take().expect("one answer"),
                            expected_remote: crate::serve::unhex32(&key).expect("key"),
                            stun: Vec::new(),
                            bind: "127.0.0.1:0".parse().expect("bind"),
                            turn: Vec::new(),
                            relay_only: false,
                        })
                        .expect("viewer link");
                        viewer_net = Some(net);
                    }
                    Control::LinkCandidate { candidate } => {
                        let c = Candidate::from_wire(&candidate).expect("candidate");
                        // Loopback only in the test: the host binds 0.0.0.0.
                        let c = Candidate {
                            addr: SocketAddr::from(([127, 0, 0, 1], c.addr.port())),
                            ..c
                        };
                        viewer_net.as_ref().expect("answered first").add_remote_candidate(c);
                    }
                    _ => {}
                }
            }
            if let Some(net) = &viewer_net {
                for event in net.events() {
                    if let NetEvent::Candidate(c) = event {
                        write_control(
                            &mut viewer.stream,
                            &Control::LinkCandidate { candidate: c.to_wire() },
                        )
                        .expect("candidate");
                    }
                    if let NetEvent::Endpoint(EndpointEvent::PathChanged {
                        route: Some(_), ..
                    }) = event
                    {
                        net.send_datagram(b"up".to_vec());
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(carrier.is_up(), "the link never came up");
        assert!(got.iter().any(|d| d == b"up"), "the viewer's datagram never arrived");
        // Media goes on the link now, not on the stream.
        carrier.send_datagram(b"media").expect("send");
        let net = viewer_net.take().expect("viewer link");
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut on_link = false;
        while !on_link && Instant::now() < deadline {
            on_link = net.events().iter().any(|e| {
                matches!(e, NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) if d == b"media")
            });
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(on_link, "media did not ride the link");
        assert!(!viewer.frames().iter().any(|(ty, _)| *ty == FRAME_DATAGRAM));
        // The viewer closes its link: media falls back to the stream.
        drop(net);
        let deadline = Instant::now() + Duration::from_secs(5);
        while carrier.is_up() && Instant::now() < deadline {
            carrier.receive(&mut out).expect("receive");
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!carrier.is_up(), "still on the link after the viewer closed it");
        carrier.send_datagram(b"back").expect("send");
        assert!(viewer.frames().iter().any(|(ty, p)| *ty == FRAME_DATAGRAM && p == b"back"));
    }

    /// A new offer while media rides the link: the viewer hears it is back on the stream
    /// before the answer.
    #[test]
    fn a_replacement_offer_reports_media_back_on_the_stream() {
        let (mut host, mut viewer) = pair();
        let mut reader = FrameReader::default();
        let stream = SocketCarrier::new(&mut host, &mut reader, None, DatagramOut::Stream);
        let mut carrier = HybridCarrier::new(stream, LinkCfg::default());
        carrier.force_up();
        let keys = KeyPair::generate().expect("keys");
        write_control(
            &mut viewer.stream,
            &Control::LinkOffer {
                session: "cloud-2".into(),
                key: crate::serve::hex(&keys.public),
                candidates: vec![],
            },
        )
        .expect("offer");
        let mut out = Vec::new();
        let mut seen = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !seen.iter().any(|c| matches!(c, Control::LinkAnswer { .. }))
            && Instant::now() < deadline
        {
            carrier.receive(&mut out).expect("receive");
            seen.extend(controls(&viewer.frames()));
            std::thread::sleep(Duration::from_millis(5));
        }
        let down = seen.iter().position(|c| {
            matches!(c, Control::LinkState { up: false, reason: Some(r) } if r.contains("replaced"))
        });
        let answer = seen.iter().position(|c| matches!(c, Control::LinkAnswer { .. }));
        assert!(matches!((down, answer), (Some(d), Some(a)) if d < a), "{seen:?}");
        assert!(!carrier.is_up());
    }

    #[test]
    fn link_stun_takes_a_list_and_refuses_a_bad_entry() {
        assert_eq!(stun_names(None).expect("none"), Vec::<String>::new());
        let list = stun_names(Some("127.0.0.1:3478, stun.example.com:3478")).expect("list");
        assert_eq!(list, vec!["127.0.0.1:3478", "stun.example.com:3478"]);
        assert!(stun_names(Some("nope")).is_err());
        assert!(stun_names(Some("host:0")).is_err());
    }

    #[test]
    fn link_stun_resolves_only_when_asked_and_leaves_out_a_name_that_does_not_resolve() {
        let cfg = LinkCfg::new(vec!["127.0.0.1:3478".into(), "stun.invalid:3478".into()]);
        assert!(cfg.stun().is_empty(), "nothing resolves before a session asks");
        cfg.resolve_stun();
        let deadline = Instant::now() + Duration::from_secs(10);
        while cfg.stun().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(cfg.stun(), vec!["127.0.0.1:3478".parse::<SocketAddr>().unwrap()]);
    }
}
