//! The secure link under a `cmux.rd/1` session between two devices
//! (plans/cmux-next/remote-desktop-mac-host.md section 7).
//!
//! One [`Link`] per session and side. It runs a Noise_XX handshake
//! (25519, ChaCha20-Poly1305, BLAKE2s) whose prologue is the session id, and
//! accepts only the remote static key the caller expects: the device hub
//! vouches for that key (each side signs its session key with its device key,
//! and the other side checks the signature before it builds the link). After
//! the handshake every packet is sealed with an explicit 64-bit nonce, so
//! packets may be lost, reordered or duplicated on any path; a sliding window
//! drops replays. Inside the seal travel rd datagrams (best effort), control
//! records (ordered and reliable, for hello, start, stats and the like) and
//! path probes.
//!
//! Pure: no sockets, no threads, no clock. The caller feeds received packets
//! and the time, and sends what [`Link::poll_transmit`] returns on the path
//! the path selector chose. Packet tags sit in 0xD0..=0xD7, outside every
//! range RFC 7983 assigns, so one UDP socket also carries STUN and TURN.

mod control;
pub mod endpoint;
mod replay;

pub use endpoint::{Endpoint, EndpointEvent, Route, Transmit};
/// The datagram link next to a stream carrier (cmuxterm-hq#7976).
#[cfg(feature = "net")]
pub mod dlink;
#[cfg(feature = "net")]
pub mod net;
pub mod turn;

use control::{ControlReceiver, ControlSender};
use replay::ReplayWindow;
use std::collections::VecDeque;

/// The Noise protocol: mutual authentication with static keys, forward secrecy.
pub const NOISE_PARAMS: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";
/// Packet tags (first byte).
pub const TAG_HANDSHAKE_1: u8 = 0xD0;
pub const TAG_HANDSHAKE_2: u8 = 0xD1;
pub const TAG_HANDSHAKE_3: u8 = 0xD2;
pub const TAG_SEALED: u8 = 0xD3;
/// A responder's hole punch: one byte, sent to each of the initiator's routes
/// until the handshake finishes, so the responder's own NAT or firewall lets
/// the initiator's message 1 in (a responder behind address-dependent
/// filtering that only listens never hears it). Every side drops it unread;
/// an older initiator does too, as an unknown tag.
pub const TAG_PUNCH: u8 = 0xD4;
/// Bytes a sealed packet adds to its payload: tag, nonce, inner kind, AEAD tag.
pub const SEAL_OVERHEAD: usize = 1 + 8 + 1 + 16;
/// Largest handshake message (two keys, payloads and tags fit well inside).
const MAX_HANDSHAKE: usize = 256;
/// Resend the last handshake message this often until the peer answers.
pub const HANDSHAKE_RETRY_US: u64 = 250_000;
/// Give up on a handshake after this long from first contact: in an endpoint, the first
/// route to the peer; in a bare link, the initiator's start (it dials at once), or the moment
/// a responder first has the peer (a route from signaling, or a valid message 1).
pub const HANDSHAKE_TIMEOUT_US: u64 = 10_000_000;
/// The longest a responder waits for that first contact. A responder starts
/// its link before signaling has carried its answer to the peer (its key and
/// candidates are in that answer), so the peer's time to get the answer and
/// start is no part of the handshake's own [`HANDSHAKE_TIMEOUT_US`]. It
/// matches the host's 30 s wait for a viewer (`cmux-rd serve`).
pub const RESPONDER_WAIT_US: u64 = 30_000_000;
/// Give up when signaling has supplied no route to the peer after this long. Signaling (the
/// device hub, a relayed bench) can take longer than the handshake itself, so its wait does
/// not count against [`HANDSHAKE_TIMEOUT_US`]; this bounds it, so a peer that never shows up
/// does not hold the socket.
pub const SIGNALING_TIMEOUT_US: u64 = 60_000_000;
/// A viewer's bound for an established link that hears nothing at all
/// ([`Link::set_peer_lost`]): the host's own grace for a silent viewer
/// (`cmux-rd-host` `REATTACH_GRACE_NS`). A live peer answers a probe every
/// second, so only a peer that is gone stays silent this long; a network
/// drop or a sleep shorter than it still comes back.
pub const PEER_LOST_US: u64 = 90_000_000;

/// Inner kinds (first plaintext byte of a sealed packet).
mod inner {
    pub const DATAGRAM: u8 = 0;
    pub const CONTROL: u8 = 1;
    pub const CONTROL_ACK: u8 = 2;
    pub const PROBE: u8 = 3;
    pub const PROBE_REPLY: u8 = 4;
    pub const CLOSE: u8 = 5;
    /// Nothing to deliver: the packet only keeps the radios on the path awake
    /// ([`crate::endpoint::KEEP_AWAKE_US`]). A peer that predates it drops it as
    /// an unknown kind, so it needs no version or cap.
    pub const KEEP_AWAKE: u8 = 6;
}

/// Which side opens the handshake. The viewer initiates; the host responds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Initiator,
    Responder,
}

/// A session key pair (25519). Generated per session; never stored.
#[derive(Clone)]
pub struct KeyPair {
    pub private: [u8; 32],
    pub public: [u8; 32],
}

impl std::fmt::Debug for KeyPair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeyPair").field("public", &self.public).finish_non_exhaustive()
    }
}

impl KeyPair {
    pub fn generate() -> Result<Self, LinkError> {
        let keys = snow::Builder::new(params()?).generate_keypair().map_err(LinkError::Noise)?;
        let mut pair = KeyPair { private: [0; 32], public: [0; 32] };
        pair.private.copy_from_slice(&keys.private);
        pair.public.copy_from_slice(&keys.public);
        Ok(pair)
    }
}

/// Why the link refused or ended.
#[derive(Debug)]
pub enum LinkError {
    Noise(snow::Error),
    /// The peer authenticated with a static key the hub did not vouch for.
    WrongPeer,
    /// The handshake did not finish in [`HANDSHAKE_TIMEOUT_US`] from first
    /// contact, or a responder heard of no peer in [`RESPONDER_WAIT_US`].
    HandshakeTimeout,
    /// Signaling supplied no route to the peer in [`SIGNALING_TIMEOUT_US`].
    NoRoute,
    /// A sealed packet or control record before the handshake finished.
    NotReady,
    /// Too many unacknowledged control records (the peer stopped answering).
    ControlBacklog,
    /// An established link heard nothing from the peer for `silent_us`
    /// ([`Link::set_peer_lost`]): the peer is gone without a close.
    PeerLost {
        silent_us: u64,
    },
    /// A socket or thread could not be set up (the `net` driver).
    Io(String),
}

impl std::fmt::Display for LinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Noise(e) => write!(f, "noise: {e}"),
            Self::WrongPeer => write!(f, "the peer's key is not the one the hub vouched for"),
            Self::HandshakeTimeout => write!(f, "the secure handshake timed out"),
            Self::NoRoute => {
                write!(f, "no route to the peer arrived in {} s", SIGNALING_TIMEOUT_US / 1_000_000)
            }
            Self::NotReady => write!(f, "the secure handshake has not finished"),
            Self::ControlBacklog => write!(f, "the peer stopped acknowledging control messages"),
            Self::PeerLost { silent_us } => {
                write!(
                    f,
                    "the peer stopped answering ({} s with nothing heard)",
                    silent_us / 1_000_000
                )
            }
            Self::Io(e) => write!(f, "network: {e}"),
        }
    }
}

impl std::error::Error for LinkError {}

/// What a received packet produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The handshake finished: sealed traffic may flow.
    Established,
    /// An rd datagram, opened (best effort; order not kept).
    Datagram(Vec<u8>),
    /// A control record, in the order the peer sent it, exactly once.
    Control(Vec<u8>),
    /// The peer answered probe `id` (the caller measures the path's RTT).
    ProbeReply(u64),
    /// The peer closed the link.
    Closed,
}

enum State {
    Handshake(Box<snow::HandshakeState>),
    Transport(Box<snow::StatelessTransportState>),
    Failed,
}

fn params() -> Result<snow::params::NoiseParams, LinkError> {
    NOISE_PARAMS.parse().map_err(LinkError::Noise)
}

/// One side of a secure link.
pub struct Link {
    role: Role,
    state: State,
    expected_remote: [u8; 32],
    started_us: u64,
    /// When the handshake's own clock started: the initiator's start, a
    /// responder's first contact with the peer (`None` until then).
    contact_us: Option<u64>,
    /// The last handshake message this side sent, resent until answered.
    last_handshake: Option<(Vec<u8>, u64)>,
    send_nonce: u64,
    replay: ReplayWindow,
    control_out: ControlSender,
    control_in: ControlReceiver,
    /// Sealed packets ready to send, in order.
    out: VecDeque<Vec<u8>>,
    /// Control records the caller queued before the handshake finished.
    pending_control: VecDeque<Vec<u8>>,
    /// When an authenticated packet last arrived (or the handshake finished).
    heard_us: u64,
    /// [`Link::set_peer_lost`]: how long an established link may hear nothing.
    peer_lost_us: Option<u64>,
}

impl Link {
    /// A link for `session` (the hub's session id, the Noise prologue). `local`
    /// is this side's session key pair; `expected_remote` the peer's session
    /// public key, already checked against the peer's device key.
    pub fn new(
        role: Role,
        session: &[u8],
        local: &KeyPair,
        expected_remote: [u8; 32],
        now_us: u64,
    ) -> Result<Self, LinkError> {
        let builder = snow::Builder::new(params()?)
            .prologue(session)
            .and_then(|b| b.local_private_key(&local.private))
            .map_err(LinkError::Noise)?;
        let handshake = match role {
            Role::Initiator => builder.build_initiator(),
            Role::Responder => builder.build_responder(),
        }
        .map_err(LinkError::Noise)?;
        let mut link = Self {
            role,
            state: State::Handshake(Box::new(handshake)),
            expected_remote,
            started_us: now_us,
            contact_us: (role == Role::Initiator).then_some(now_us),
            last_handshake: None,
            send_nonce: 0,
            replay: ReplayWindow::default(),
            control_out: ControlSender::default(),
            control_in: ControlReceiver::default(),
            out: VecDeque::new(),
            pending_control: VecDeque::new(),
            heard_us: now_us,
            peer_lost_us: None,
        };
        if role == Role::Initiator {
            link.write_handshake(TAG_HANDSHAKE_1, now_us)?;
        }
        Ok(link)
    }

    pub fn role(&self) -> Role {
        self.role
    }

    /// A responder has the peer now (signaling gave a route to it): the
    /// handshake's [`HANDSHAKE_TIMEOUT_US`] runs from here, not from this
    /// link's start. The first contact counts; later ones change nothing.
    pub fn peer_contact(&mut self, now_us: u64) {
        if matches!(self.state, State::Handshake(_)) && self.contact_us.is_none() {
            self.contact_us = Some(now_us);
        }
    }

    pub fn is_established(&self) -> bool {
        matches!(self.state, State::Transport(_))
    }

    /// Ends an established link that hears nothing from the peer for
    /// `after_us` ([`LinkError::PeerLost`] from the next poll). `None` (the
    /// default) waits for the peer forever, as a host does: its session has
    /// its own grace.
    pub fn set_peer_lost(&mut self, after_us: Option<u64>) {
        self.peer_lost_us = after_us;
    }

    fn write_handshake(&mut self, tag: u8, now_us: u64) -> Result<(), LinkError> {
        let State::Handshake(handshake) = &mut self.state else { return Err(LinkError::NotReady) };
        let mut buf = vec![0u8; MAX_HANDSHAKE];
        let n = handshake.write_message(&[], &mut buf).map_err(LinkError::Noise)?;
        let mut packet = Vec::with_capacity(1 + n);
        packet.push(tag);
        buf.truncate(n);
        packet.extend_from_slice(&buf);
        self.out.push_back(packet.clone());
        self.last_handshake = Some((packet, now_us));
        Ok(())
    }

    /// Switches to transport mode once Noise says the handshake finished,
    /// after checking the peer's static key.
    fn finish_handshake(&mut self, events: &mut Vec<Event>, now_us: u64) -> Result<(), LinkError> {
        let state = std::mem::replace(&mut self.state, State::Failed);
        let State::Handshake(handshake) = state else {
            self.state = state;
            return Ok(());
        };
        if handshake.get_remote_static() != Some(&self.expected_remote[..]) {
            return Err(LinkError::WrongPeer);
        }
        let transport = handshake.into_stateless_transport_mode().map_err(LinkError::Noise)?;
        self.state = State::Transport(Box::new(transport));
        self.heard_us = now_us;
        // The responder's last handshake message needs no resend: the
        // initiator's first sealed packet (or message 3's retry) answers it.
        self.last_handshake =
            if self.role == Role::Initiator { self.last_handshake.take() } else { None };
        events.push(Event::Established);
        while let Some(record) = self.pending_control.pop_front() {
            self.send_control(record, now_us)?;
        }
        Ok(())
    }

    /// Feeds one received packet. Packets that are not this link's, fail to
    /// open, or replay an old nonce are dropped without an error: anyone can
    /// send datagrams to a UDP port.
    pub fn on_packet(&mut self, packet: &[u8], now_us: u64) -> Result<Vec<Event>, LinkError> {
        let mut events = Vec::new();
        let Some((&tag, body)) = packet.split_first() else { return Ok(events) };
        match (&mut self.state, tag) {
            // The first message 1; a retried one (this side already answered) is
            // answered again below.
            (State::Handshake(handshake), TAG_HANDSHAKE_1)
                if self.role == Role::Responder && self.last_handshake.is_none() =>
            {
                let mut scratch = [0u8; MAX_HANDSHAKE];
                if handshake.read_message(body, &mut scratch).is_ok() {
                    self.peer_contact(now_us);
                    self.write_handshake(TAG_HANDSHAKE_2, now_us)?;
                }
            }
            (State::Handshake(handshake), TAG_HANDSHAKE_2) if self.role == Role::Initiator => {
                let mut scratch = [0u8; MAX_HANDSHAKE];
                if handshake.read_message(body, &mut scratch).is_ok() {
                    // Message 2 carries the responder's static key: check it
                    // before saying anything that proves who this side is.
                    if handshake.get_remote_static() != Some(&self.expected_remote[..]) {
                        self.state = State::Failed;
                        return Err(LinkError::WrongPeer);
                    }
                    self.write_handshake(TAG_HANDSHAKE_3, now_us)?;
                    self.finish_handshake(&mut events, now_us)?;
                }
            }
            (State::Handshake(handshake), TAG_HANDSHAKE_3) if self.role == Role::Responder => {
                let mut scratch = [0u8; MAX_HANDSHAKE];
                if handshake.read_message(body, &mut scratch).is_ok() {
                    self.finish_handshake(&mut events, now_us)?;
                }
            }
            // A retried message 1: this side's message 2 was lost, send it again.
            (State::Handshake(_), TAG_HANDSHAKE_1) if self.role == Role::Responder => {
                if let Some((packet, _)) = &self.last_handshake {
                    self.out.push_back(packet.clone());
                }
            }
            (State::Transport(_), TAG_SEALED) => self.open_sealed(body, &mut events, now_us)?,
            _ => {}
        }
        Ok(events)
    }

    fn open_sealed(
        &mut self,
        body: &[u8],
        events: &mut Vec<Event>,
        now_us: u64,
    ) -> Result<(), LinkError> {
        let State::Transport(transport) = &self.state else { return Ok(()) };
        let Some((nonce, sealed)) = body.split_first_chunk::<8>() else { return Ok(()) };
        if sealed.len() < 16 {
            return Ok(());
        }
        let nonce = u64::from_le_bytes(*nonce);
        if !self.replay.check(nonce) {
            return Ok(());
        }
        let mut plain = vec![0u8; sealed.len()];
        let Ok(n) = transport.read_message(nonce, sealed, &mut plain) else { return Ok(()) };
        self.replay.accept(nonce);
        self.heard_us = self.heard_us.max(now_us);
        plain.truncate(n);
        // Any sealed packet proves the initiator's message 3 arrived.
        if self.role == Role::Initiator {
            self.last_handshake = None;
        }
        let Some((&kind, payload)) = plain.split_first() else { return Ok(()) };
        match kind {
            inner::DATAGRAM => events.push(Event::Datagram(payload.to_vec())),
            inner::CONTROL => {
                if let Some((seq, record)) = control::decode_record(payload) {
                    let ack = self
                        .control_in
                        .receive(seq, record, |record| events.push(Event::Control(record)));
                    let packet = self.seal(inner::CONTROL_ACK, &ack.to_le_bytes())?;
                    self.out.push_back(packet);
                }
            }
            inner::CONTROL_ACK => {
                if let Ok(seq) = <[u8; 4]>::try_from(payload) {
                    self.control_out.ack(u32::from_le_bytes(seq), now_us);
                }
            }
            inner::PROBE if payload.len() == 8 => {
                let packet = self.seal(inner::PROBE_REPLY, payload)?;
                self.out.push_back(packet);
            }
            inner::PROBE_REPLY => {
                if let Ok(id) = <[u8; 8]>::try_from(payload) {
                    events.push(Event::ProbeReply(u64::from_le_bytes(id)));
                }
            }
            inner::CLOSE => {
                self.state = State::Failed;
                events.push(Event::Closed);
            }
            // Its only job, waking this side's radio, is done by arriving.
            inner::KEEP_AWAKE => {}
            _ => {}
        }
        Ok(())
    }

    fn seal(&mut self, kind: u8, payload: &[u8]) -> Result<Vec<u8>, LinkError> {
        let State::Transport(transport) = &self.state else { return Err(LinkError::NotReady) };
        let nonce = self.send_nonce;
        self.send_nonce += 1;
        let mut plain = Vec::with_capacity(1 + payload.len());
        plain.push(kind);
        plain.extend_from_slice(payload);
        let mut packet = Vec::with_capacity(1 + 8 + plain.len() + 16);
        packet.push(TAG_SEALED);
        packet.extend_from_slice(&nonce.to_le_bytes());
        packet.resize(1 + 8 + plain.len() + 16, 0);
        let body = packet.get_mut(9..).unwrap_or_default();
        let n = transport.write_message(nonce, &plain, body).map_err(LinkError::Noise)?;
        packet.truncate(9 + n);
        Ok(packet)
    }

    /// Seals one rd datagram (best effort) and returns the packet to send now.
    pub fn seal_datagram(&mut self, datagram: &[u8]) -> Result<Vec<u8>, LinkError> {
        self.seal(inner::DATAGRAM, datagram)
    }

    /// Queues one control record: delivered once and in order. Records queued
    /// before the handshake finished go out when it does.
    pub fn send_control(&mut self, record: Vec<u8>, now_us: u64) -> Result<(), LinkError> {
        if !self.is_established() {
            self.pending_control.push_back(record);
            return Ok(());
        }
        let (seq, payload) =
            self.control_out.push(record, now_us).ok_or(LinkError::ControlBacklog)?;
        let packet = self.seal(inner::CONTROL, &control::encode_record(seq, &payload))?;
        self.out.push_back(packet);
        Ok(())
    }

    /// A probe with `id`, sealed, for one path (the caller sends it on that path).
    pub fn probe(&mut self, id: u64) -> Result<Vec<u8>, LinkError> {
        self.seal(inner::PROBE, &id.to_le_bytes())
    }

    /// A keep-awake packet (no payload, never answered), sealed, for the current path.
    pub fn keep_awake(&mut self) -> Result<Vec<u8>, LinkError> {
        self.seal(inner::KEEP_AWAKE, &[])
    }

    /// Tells the peer the link ends.
    pub fn close(&mut self) -> Result<Vec<u8>, LinkError> {
        let packet = self.seal(inner::CLOSE, &[])?;
        self.state = State::Failed;
        Ok(packet)
    }

    /// Packets to send now, on the current path: handshake messages and their
    /// retries, control records and their retransmissions, acks and probe replies.
    pub fn poll_transmit(&mut self, now_us: u64) -> Result<Vec<Vec<u8>>, LinkError> {
        if self.poll_handshake_timers(now_us)?
            && let Some((packet, _)) = &self.last_handshake
        {
            self.out.push_back(packet.clone());
        }
        if self.is_established() {
            for (seq, record) in self.control_out.due(now_us) {
                let packet = self.seal(inner::CONTROL, &control::encode_record(seq, &record))?;
                self.out.push_back(packet);
            }
        }
        Ok(self.out.drain(..).collect())
    }

    /// Starts the handshake's timeout clock over: the endpoint calls it when the first route
    /// arrives, so the wait for signaling does not count against the handshake.
    pub(crate) fn start_handshake_clock(&mut self, now_us: u64) {
        if let State::Handshake(_) = self.state {
            self.started_us = now_us;
            self.contact_us = Some(now_us);
        }
    }

    /// Ends a handshake that never got a route ([`LinkError::NoRoute`]).
    pub(crate) fn fail_no_route(&mut self) -> LinkError {
        self.state = State::Failed;
        LinkError::NoRoute
    }

    /// Advances handshake timers without creating another packet.  Endpoints
    /// use this while signaling has not supplied a route, so the queued first
    /// message stays available without a retry storm or a lost timeout.
    pub(crate) fn poll_handshake_timers(&mut self, now_us: u64) -> Result<bool, LinkError> {
        let expired = match self.contact_us {
            Some(at) => now_us.saturating_sub(at) > HANDSHAKE_TIMEOUT_US,
            None => now_us.saturating_sub(self.started_us) > RESPONDER_WAIT_US,
        };
        if let State::Handshake(_) = self.state
            && expired
        {
            self.state = State::Failed;
            return Err(LinkError::HandshakeTimeout);
        }
        if let Some(bound) = self.peer_lost_us
            && self.is_established()
        {
            let silent_us = now_us.saturating_sub(self.heard_us);
            if silent_us >= bound {
                self.state = State::Failed;
                return Err(LinkError::PeerLost { silent_us });
            }
        }
        let mut retry = false;
        if let Some((_, sent)) = &mut self.last_handshake
            && now_us.saturating_sub(*sent) >= HANDSHAKE_RETRY_US
        {
            *sent = now_us;
            retry = true;
        }
        Ok(retry)
    }

    /// When the caller should call [`Link::poll_transmit`] next without input.
    pub fn next_deadline_us(&self) -> Option<u64> {
        let handshake = self.last_handshake.as_ref().map(|(_, sent)| sent + HANDSHAKE_RETRY_US);
        let control =
            if self.is_established() { self.control_out.next_deadline_us() } else { None };
        let lost = self
            .peer_lost_us
            .filter(|_| self.is_established())
            .map(|bound| self.heard_us.saturating_add(bound));
        [handshake, control, lost].into_iter().flatten().min()
    }
}
