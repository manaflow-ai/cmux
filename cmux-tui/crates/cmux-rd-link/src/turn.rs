//! A TURN client (RFC 8656 over UDP), pure like [`crate::Link`]: no sockets,
//! no clock. The caller sends what [`TurnClient::poll_transmit`] returns to
//! the TURN server, feeds what the server sends to [`TurnClient::on_packet`],
//! and passes the time in microseconds.
//!
//! What it does: Allocate with long-term credentials (the 401 gives the realm
//! and nonce, MESSAGE-INTEGRITY is HMAC-SHA1 keyed with
//! MD5(username:realm:password), a 438 refreshes a stale nonce), learns the
//! relayed address, refreshes the allocation before its lifetime ends, keeps
//! a permission for each peer IP (CreatePermission every 4 minutes), and moves
//! data in ChannelData messages once a channel is bound (ChannelBind, every 9
//! minutes), with Send and Data indications before that.
//!
//! The server is a relay: untrusted for content (the sealed link above
//! authenticates every packet) and possibly hostile in what it sends. Every
//! message is parsed strictly with bounded lengths and attribute counts,
//! success responses to authenticated requests must carry a valid
//! MESSAGE-INTEGRITY, retries are bounded, and nothing here panics.
//!
//! Message classes share one UDP socket with the link by RFC 7983: STUN and
//! TURN messages start with 0..=3, ChannelData with 0x40..=0x4F, link
//! packets with 0xD0..=0xD7.

use hmac::{Hmac, Mac};
use md5::{Digest, Md5};
use sha1::Sha1;
use std::collections::HashMap;
use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

type HmacSha1 = Hmac<Sha1>;

/// A STUN transaction id.
pub type TransactionId = [u8; 12];

const MAGIC_COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];
const HEADER_LEN: usize = 20;

// Message types (method | class bits) this client sends or reads.
const ALLOCATE_REQUEST: u16 = 0x0003;
const REFRESH_REQUEST: u16 = 0x0004;
const CREATE_PERMISSION_REQUEST: u16 = 0x0008;
const CHANNEL_BIND_REQUEST: u16 = 0x0009;
const SEND_INDICATION: u16 = 0x0016;
const DATA_INDICATION: u16 = 0x0017;
const CLASS_MASK: u16 = 0x0110;
const CLASS_SUCCESS: u16 = 0x0100;
const CLASS_ERROR: u16 = 0x0110;

// Attributes.
const ATTR_USERNAME: u16 = 0x0006;
const ATTR_MESSAGE_INTEGRITY: u16 = 0x0008;
const ATTR_ERROR_CODE: u16 = 0x0009;
const ATTR_CHANNEL_NUMBER: u16 = 0x000C;
const ATTR_LIFETIME: u16 = 0x000D;
const ATTR_XOR_PEER_ADDRESS: u16 = 0x0012;
const ATTR_DATA: u16 = 0x0013;
const ATTR_REALM: u16 = 0x0014;
const ATTR_NONCE: u16 = 0x0015;
const ATTR_XOR_RELAYED_ADDRESS: u16 = 0x0016;
const ATTR_REQUESTED_TRANSPORT: u16 = 0x0019;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
const ATTR_FINGERPRINT: u16 = 0x8028;

const FAMILY_V4: u8 = 0x01;
const FAMILY_V6: u8 = 0x02;
/// REQUESTED-TRANSPORT value: UDP.
const PROTOCOL_UDP: u8 = 17;

/// The channel numbers a client may bind (RFC 8656 section 12).
pub const CHANNEL_MIN: u16 = 0x4000;
pub const CHANNEL_MAX: u16 = 0x4FFF;
/// Most peers (permissions and channels) per allocation.
pub const MAX_PEERS: usize = 16;
/// Most attributes read from one message.
const MAX_ATTRIBUTES: usize = 32;
/// REALM and NONCE are at most 763 bytes (RFC 8489 sections 14.9 and 14.10).
const MAX_TEXT: usize = 763;
/// Largest payload this client relays (it must fit one UDP datagram with headers).
pub const MAX_DATA: usize = 65_000;

/// Retransmission of requests (RFC 8489 section 6.2.1, with a shorter first RTO).
const RTO_INITIAL_US: u64 = 250_000;
const RTO_MAX_US: u64 = 2_000_000;
const MAX_ATTEMPTS: u32 = 7;
/// How often a 438 (stale nonce) may restart one request.
const MAX_STALE_RETRIES: u32 = 3;
/// Permissions last 5 minutes and channels 10; refresh them early.
const PERMISSION_REFRESH_US: u64 = 240_000_000;
const CHANNEL_REFRESH_US: u64 = 540_000_000;
/// A failed permission or channel request is tried again after this long.
const RETRY_LATER_US: u64 = 30_000_000;
/// A failed refresh is tried again after this long, until the allocation expires.
const REFRESH_RETRY_US: u64 = 5_000_000;
/// The allocation lifetime asked for and the bounds kept on what the server grants.
const DEFAULT_LIFETIME_S: u32 = 600;
const MAX_LIFETIME_S: u32 = 3600;
/// Refresh this long before the lifetime ends (at most half the lifetime).
const REFRESH_MARGIN_US: u64 = 60_000_000;

/// Why an allocation ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnError {
    /// The server refused the credentials (401 after authenticating).
    Unauthorized,
    /// The server did not answer a request in time.
    Timeout,
    /// The server answered an error code.
    Rejected(u16),
    /// The server's success response lacked what it must carry.
    Malformed,
    /// The allocation's lifetime ran out without a successful refresh.
    Expired,
}

impl fmt::Display for TurnError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TurnError::Unauthorized => f.write_str("turn: unauthorized (wrong credentials)"),
            TurnError::Timeout => f.write_str("turn: server did not answer"),
            TurnError::Rejected(code) => write!(f, "turn: server answered error {code}"),
            TurnError::Malformed => f.write_str("turn: malformed server response"),
            TurnError::Expired => f.write_str("turn: allocation expired"),
        }
    }
}

impl std::error::Error for TurnError {}

/// What the client reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnEvent {
    /// The allocation exists: peers reach this side at `relayed`. `mapped` is
    /// this side's address as the server sees it, when the server said.
    Allocated { relayed: SocketAddr, mapped: Option<SocketAddr> },
    /// The allocation failed or ended; the client stays inert.
    Failed(TurnError),
}

/// What one packet from the server was.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnReceive<'a> {
    /// Data a peer sent to the relayed address.
    Data { peer: SocketAddr, payload: &'a [u8] },
    /// A TURN message this client consumed (or dropped as invalid for it).
    Handled,
    /// Not a TURN message for this client (a STUN binding answer, say).
    Ignored,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Idle,
    Allocating,
    Allocated { relayed: SocketAddr, expires_us: u64, refresh_at_us: u64 },
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Purpose {
    Allocate,
    Refresh { lifetime: u32 },
    Permission(IpAddr),
    Bind { peer: SocketAddr, number: u16 },
}

struct Request {
    purpose: Purpose,
    tx: TransactionId,
    packet: Vec<u8>,
    next_us: u64,
    rto_us: u64,
    attempts: u32,
    stale: u32,
    authenticated: bool,
}

struct Refreshing {
    due_us: u64,
    in_flight: bool,
}

struct Channel {
    number: u16,
    bound: bool,
    due_us: u64,
    in_flight: bool,
}

/// One allocation on one TURN server.
pub struct TurnClient {
    username: Vec<u8>,
    password: Vec<u8>,
    seed: [u8; 32],
    counter: u64,
    realm: Option<Vec<u8>>,
    nonce: Option<Vec<u8>>,
    key: Option<[u8; 16]>,
    state: State,
    requests: Vec<Request>,
    permissions: HashMap<IpAddr, Refreshing>,
    channels: HashMap<SocketAddr, Channel>,
    by_number: HashMap<u16, SocketAddr>,
    next_channel: u16,
    outbox: Vec<Vec<u8>>,
    events: Vec<TurnEvent>,
}

impl fmt::Debug for TurnClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TurnClient").field("state", &self.state).finish_non_exhaustive()
    }
}

impl TurnClient {
    /// A client that allocates on the first [`TurnClient::poll_transmit`].
    /// `seed` must be random: transaction ids derive from it, and an off-path
    /// sender must not guess them.
    pub fn new(username: &str, password: &str, seed: [u8; 32]) -> Self {
        Self {
            username: username.as_bytes().to_vec(),
            password: password.as_bytes().to_vec(),
            seed,
            counter: 0,
            realm: None,
            nonce: None,
            key: None,
            state: State::Idle,
            requests: Vec::new(),
            permissions: HashMap::new(),
            channels: HashMap::new(),
            by_number: HashMap::new(),
            next_channel: CHANNEL_MIN,
            outbox: Vec::new(),
            events: Vec::new(),
        }
    }

    /// The relayed address, once allocated.
    pub fn relayed(&self) -> Option<SocketAddr> {
        match self.state {
            State::Allocated { relayed, .. } => Some(relayed),
            _ => None,
        }
    }

    /// The allocation failed or ended for good.
    pub fn is_failed(&self) -> bool {
        self.state == State::Failed
    }

    /// The events since the last call.
    pub fn take_events(&mut self) -> Vec<TurnEvent> {
        std::mem::take(&mut self.events)
    }

    fn next_tx(&mut self) -> TransactionId {
        self.counter = self.counter.wrapping_add(1);
        let mut tx = [0u8; 12];
        match HmacSha1::new_from_slice(&self.seed) {
            Ok(mut mac) => {
                mac.update(&self.counter.to_be_bytes());
                let digest = mac.finalize().into_bytes();
                for (out, byte) in tx.iter_mut().zip(digest.iter()) {
                    *out = *byte;
                }
            }
            Err(_) => {
                for (out, byte) in tx.iter_mut().zip(self.seed.iter()) {
                    *out = *byte;
                }
                for (out, byte) in tx[4..].iter_mut().zip(self.counter.to_be_bytes()) {
                    *out ^= byte;
                }
            }
        }
        tx
    }

    fn fail(&mut self, error: TurnError) {
        if matches!(self.state, State::Failed | State::Closed) {
            return;
        }
        self.state = State::Failed;
        self.requests.clear();
        self.outbox.clear();
        self.events.push(TurnEvent::Failed(error));
    }

    /// Adds a peer: a permission for its IP and a channel for its address.
    /// Requests go out once the allocation exists. False when the peer table
    /// is full or the allocation has ended.
    pub fn add_peer(&mut self, peer: SocketAddr, now_us: u64) -> bool {
        if matches!(self.state, State::Failed | State::Closed) {
            return false;
        }
        if self.channels.contains_key(&peer) {
            return true;
        }
        let ip = peer.ip();
        if self.channels.len() >= MAX_PEERS
            || (!self.permissions.contains_key(&ip) && self.permissions.len() >= MAX_PEERS)
            || self.next_channel > CHANNEL_MAX
        {
            return false;
        }
        let number = self.next_channel;
        self.next_channel += 1;
        self.permissions.entry(ip).or_insert(Refreshing { due_us: now_us, in_flight: false });
        self.channels
            .insert(peer, Channel { number, bound: false, due_us: now_us, in_flight: false });
        self.by_number.insert(number, peer);
        true
    }

    /// One payload for `peer` through the relay: a ChannelData message once
    /// the channel is bound, a Send indication before. `None` before the
    /// allocation exists, after it ended, or when the payload is too large.
    pub fn send(&mut self, peer: SocketAddr, payload: &[u8], now_us: u64) -> Option<Vec<u8>> {
        if !matches!(self.state, State::Allocated { .. }) || payload.len() > MAX_DATA {
            return None;
        }
        if !self.channels.contains_key(&peer) {
            self.add_peer(peer, now_us);
        }
        if let Some(channel) = self.channels.get(&peer).filter(|c| c.bound) {
            let length = u16::try_from(payload.len()).ok()?;
            let mut packet = Vec::with_capacity(4 + payload.len());
            packet.extend_from_slice(&channel.number.to_be_bytes());
            packet.extend_from_slice(&length.to_be_bytes());
            packet.extend_from_slice(payload);
            return Some(packet);
        }
        if !self.permissions.contains_key(&peer.ip()) {
            return None;
        }
        let tx = self.next_tx();
        let mut message = Builder::new(SEND_INDICATION, tx);
        message.address(ATTR_XOR_PEER_ADDRESS, peer);
        message.attribute(ATTR_DATA, payload);
        message.finish(None)
    }

    /// Ends the allocation (a Refresh with lifetime 0, sent once).
    pub fn close(&mut self) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        if matches!(self.state, State::Allocated { .. }) {
            let tx = self.next_tx();
            if let Some(packet) = self.encode(Purpose::Refresh { lifetime: 0 }, tx) {
                out.push(packet);
            }
        }
        if self.state != State::Failed {
            self.state = State::Closed;
        }
        self.requests.clear();
        self.outbox.clear();
        out
    }

    fn encode(&self, purpose: Purpose, tx: TransactionId) -> Option<Vec<u8>> {
        let mut message = match purpose {
            Purpose::Allocate => {
                let mut m = Builder::new(ALLOCATE_REQUEST, tx);
                m.attribute(ATTR_REQUESTED_TRANSPORT, &[PROTOCOL_UDP, 0, 0, 0]);
                m
            }
            Purpose::Refresh { lifetime } => {
                let mut m = Builder::new(REFRESH_REQUEST, tx);
                m.attribute(ATTR_LIFETIME, &lifetime.to_be_bytes());
                m
            }
            Purpose::Permission(ip) => {
                let mut m = Builder::new(CREATE_PERMISSION_REQUEST, tx);
                m.address(ATTR_XOR_PEER_ADDRESS, SocketAddr::new(ip, 0));
                m
            }
            Purpose::Bind { peer, number } => {
                let mut m = Builder::new(CHANNEL_BIND_REQUEST, tx);
                let [n0, n1] = number.to_be_bytes();
                m.attribute(ATTR_CHANNEL_NUMBER, &[n0, n1, 0, 0]);
                m.address(ATTR_XOR_PEER_ADDRESS, peer);
                m
            }
        };
        match (&self.key, &self.realm, &self.nonce) {
            (Some(key), Some(realm), Some(nonce)) => {
                message.attribute(ATTR_USERNAME, &self.username);
                message.attribute(ATTR_REALM, realm);
                message.attribute(ATTR_NONCE, nonce);
                message.finish(Some(key))
            }
            _ => message.finish(None),
        }
    }

    fn request(&mut self, purpose: Purpose, stale: u32, now_us: u64) {
        let tx = self.next_tx();
        let Some(packet) = self.encode(purpose, tx) else {
            self.request_failed(purpose, TurnError::Malformed, now_us);
            return;
        };
        self.outbox.push(packet.clone());
        self.requests.push(Request {
            purpose,
            tx,
            packet,
            next_us: now_us.saturating_add(RTO_INITIAL_US),
            rto_us: RTO_INITIAL_US,
            attempts: 1,
            stale,
            authenticated: self.key.is_some(),
        });
        match purpose {
            Purpose::Permission(ip) => {
                if let Some(p) = self.permissions.get_mut(&ip) {
                    p.in_flight = true;
                }
            }
            Purpose::Bind { peer, .. } => {
                if let Some(c) = self.channels.get_mut(&peer) {
                    c.in_flight = true;
                }
            }
            Purpose::Allocate | Purpose::Refresh { .. } => {}
        }
    }

    fn request_failed(&mut self, purpose: Purpose, error: TurnError, now_us: u64) {
        match purpose {
            Purpose::Allocate => self.fail(error),
            Purpose::Refresh { lifetime: 0 } => {}
            Purpose::Refresh { .. } => {
                if error == TurnError::Rejected(437) || error == TurnError::Unauthorized {
                    self.fail(error);
                } else if let State::Allocated { refresh_at_us, .. } = &mut self.state {
                    *refresh_at_us = now_us.saturating_add(REFRESH_RETRY_US);
                }
            }
            Purpose::Permission(ip) => {
                if let Some(p) = self.permissions.get_mut(&ip) {
                    p.in_flight = false;
                    p.due_us = now_us.saturating_add(RETRY_LATER_US);
                }
            }
            Purpose::Bind { peer, .. } => {
                if let Some(c) = self.channels.get_mut(&peer) {
                    c.in_flight = false;
                    c.due_us = now_us.saturating_add(RETRY_LATER_US);
                }
            }
        }
    }

    fn schedule_allocated(&mut self, relayed: SocketAddr, lifetime_s: u32, now_us: u64) {
        let lifetime_us = u64::from(lifetime_s.clamp(1, MAX_LIFETIME_S)) * 1_000_000;
        let margin = REFRESH_MARGIN_US.min(lifetime_us / 2);
        self.state = State::Allocated {
            relayed,
            expires_us: now_us.saturating_add(lifetime_us),
            refresh_at_us: now_us.saturating_add(lifetime_us - margin),
        };
    }

    /// Packets to send to the server now: new requests, retransmissions,
    /// refreshes that are due.
    pub fn poll_transmit(&mut self, now_us: u64) -> Vec<Vec<u8>> {
        match self.state {
            State::Failed | State::Closed => {
                self.requests.clear();
                return std::mem::take(&mut self.outbox);
            }
            State::Idle => {
                self.state = State::Allocating;
                self.request(Purpose::Allocate, 0, now_us);
            }
            State::Allocating => {}
            State::Allocated { expires_us, refresh_at_us, relayed } => {
                if now_us >= expires_us {
                    self.fail(TurnError::Expired);
                    return Vec::new();
                }
                let refreshing =
                    self.requests.iter().any(|r| matches!(r.purpose, Purpose::Refresh { .. }));
                if now_us >= refresh_at_us && !refreshing {
                    self.state =
                        State::Allocated { relayed, expires_us, refresh_at_us: expires_us };
                    self.request(Purpose::Refresh { lifetime: DEFAULT_LIFETIME_S }, 0, now_us);
                }
            }
        }
        // Retransmissions and timeouts.
        let mut timed_out = Vec::new();
        for r in self.requests.iter_mut().filter(|r| r.next_us <= now_us) {
            if r.attempts >= MAX_ATTEMPTS {
                timed_out.push(r.tx);
                continue;
            }
            r.attempts += 1;
            r.rto_us = (r.rto_us * 2).min(RTO_MAX_US);
            r.next_us = now_us.saturating_add(r.rto_us);
            self.outbox.push(r.packet.clone());
        }
        for tx in timed_out {
            if let Some(index) = self.requests.iter().position(|r| r.tx == tx) {
                let r = self.requests.swap_remove(index);
                self.request_failed(r.purpose, TurnError::Timeout, now_us);
            }
        }
        if matches!(self.state, State::Allocated { .. }) {
            let permissions: Vec<IpAddr> = self
                .permissions
                .iter()
                .filter(|(_, p)| !p.in_flight && p.due_us <= now_us)
                .map(|(ip, _)| *ip)
                .collect();
            for ip in permissions {
                self.request(Purpose::Permission(ip), 0, now_us);
            }
            let channels: Vec<(SocketAddr, u16)> = self
                .channels
                .iter()
                .filter(|(_, c)| !c.in_flight && c.due_us <= now_us)
                .map(|(peer, c)| (*peer, c.number))
                .collect();
            for (peer, number) in channels {
                self.request(Purpose::Bind { peer, number }, 0, now_us);
            }
        }
        std::mem::take(&mut self.outbox)
    }

    /// When to call [`TurnClient::poll_transmit`] next without input.
    pub fn next_deadline_us(&self) -> Option<u64> {
        let mut at = self.requests.iter().map(|r| r.next_us).min();
        let mut consider = |t: u64| at = Some(at.map_or(t, |a| a.min(t)));
        match self.state {
            State::Idle => consider(0),
            State::Allocated { expires_us, refresh_at_us, .. } => {
                consider(expires_us);
                consider(refresh_at_us);
                for p in self.permissions.values().filter(|p| !p.in_flight) {
                    consider(p.due_us);
                }
                for c in self.channels.values().filter(|c| !c.in_flight) {
                    consider(c.due_us);
                }
            }
            State::Allocating | State::Closed | State::Failed => {}
        }
        if !self.outbox.is_empty() {
            consider(0);
        }
        at
    }

    /// Feeds one packet that came from the server.
    pub fn on_packet<'a>(&mut self, packet: &'a [u8], now_us: u64) -> TurnReceive<'a> {
        match packet.first() {
            Some(0x40..=0x4F) => self.on_channel_data(packet),
            Some(0..=3) => match Message::parse(packet) {
                Some(message) => self.on_message(&message, now_us),
                None => TurnReceive::Ignored,
            },
            _ => TurnReceive::Ignored,
        }
    }

    fn on_channel_data<'a>(&self, packet: &'a [u8]) -> TurnReceive<'a> {
        if !matches!(self.state, State::Allocated { .. }) {
            return TurnReceive::Handled;
        }
        let Some(([n0, n1, l0, l1], rest)) = packet.split_first_chunk::<4>() else {
            return TurnReceive::Handled;
        };
        let number = u16::from_be_bytes([*n0, *n1]);
        let length = usize::from(u16::from_be_bytes([*l0, *l1]));
        let (Some(peer), Some(payload)) = (self.by_number.get(&number), rest.get(..length)) else {
            return TurnReceive::Handled;
        };
        TurnReceive::Data { peer: *peer, payload }
    }

    fn on_message<'a>(&mut self, message: &Message<'a>, now_us: u64) -> TurnReceive<'a> {
        if message.kind == DATA_INDICATION {
            if !matches!(self.state, State::Allocated { .. }) {
                return TurnReceive::Handled;
            }
            let peer =
                message.get(ATTR_XOR_PEER_ADDRESS).and_then(|v| decode_address(v, &message.tx));
            return match (peer, message.get(ATTR_DATA)) {
                (Some(peer), Some(payload)) if self.permissions.contains_key(&peer.ip()) => {
                    TurnReceive::Data { peer, payload }
                }
                _ => TurnReceive::Handled,
            };
        }
        let class = message.kind & CLASS_MASK;
        if class != CLASS_SUCCESS && class != CLASS_ERROR {
            return TurnReceive::Ignored;
        }
        let Some((index, request)) =
            self.requests.iter().enumerate().find(|(_, r)| r.tx == message.tx)
        else {
            return TurnReceive::Ignored;
        };
        let expected = match request.purpose {
            Purpose::Allocate => ALLOCATE_REQUEST,
            Purpose::Refresh { .. } => REFRESH_REQUEST,
            Purpose::Permission(_) => CREATE_PERMISSION_REQUEST,
            Purpose::Bind { .. } => CHANNEL_BIND_REQUEST,
        };
        if message.kind & !CLASS_MASK != expected {
            return TurnReceive::Handled;
        }
        let authenticated = request.authenticated;
        if class == CLASS_SUCCESS {
            // A success to an authenticated request must prove the server knows the key;
            // otherwise keep retransmitting and wait for a genuine answer.
            if authenticated && !self.key.as_ref().is_some_and(|key| message.verify(key)) {
                return TurnReceive::Handled;
            }
            let request = self.requests.swap_remove(index);
            self.on_success(request.purpose, message, now_us);
        } else {
            let request = self.requests.swap_remove(index);
            self.on_error(request, message, now_us);
        }
        TurnReceive::Handled
    }

    fn on_success(&mut self, purpose: Purpose, message: &Message<'_>, now_us: u64) {
        let lifetime = message
            .get(ATTR_LIFETIME)
            .and_then(|v| <[u8; 4]>::try_from(v).ok())
            .map(u32::from_be_bytes);
        match purpose {
            Purpose::Allocate => {
                let relayed = message
                    .get(ATTR_XOR_RELAYED_ADDRESS)
                    .and_then(|v| decode_address(v, &message.tx));
                let Some(relayed) = relayed.filter(|a| a.port() != 0 && !a.ip().is_unspecified())
                else {
                    self.fail(TurnError::Malformed);
                    return;
                };
                let mapped = message
                    .get(ATTR_XOR_MAPPED_ADDRESS)
                    .and_then(|v| decode_address(v, &message.tx));
                self.schedule_allocated(relayed, lifetime.unwrap_or(DEFAULT_LIFETIME_S), now_us);
                self.events.push(TurnEvent::Allocated { relayed, mapped });
            }
            Purpose::Refresh { lifetime: 0 } => {}
            Purpose::Refresh { .. } => {
                if let Some(relayed) = self.relayed() {
                    self.schedule_allocated(
                        relayed,
                        lifetime.unwrap_or(DEFAULT_LIFETIME_S),
                        now_us,
                    );
                }
            }
            Purpose::Permission(ip) => {
                if let Some(p) = self.permissions.get_mut(&ip) {
                    p.in_flight = false;
                    p.due_us = now_us.saturating_add(PERMISSION_REFRESH_US);
                }
            }
            Purpose::Bind { peer, .. } => {
                if let Some(c) = self.channels.get_mut(&peer) {
                    c.in_flight = false;
                    c.bound = true;
                    c.due_us = now_us.saturating_add(CHANNEL_REFRESH_US);
                }
            }
        }
    }

    fn on_error(&mut self, request: Request, message: &Message<'_>, now_us: u64) {
        let Some(code) = message.get(ATTR_ERROR_CODE).and_then(decode_error_code) else {
            self.request_failed(request.purpose, TurnError::Malformed, now_us);
            return;
        };
        let realm = message.get(ATTR_REALM).filter(|v| !v.is_empty() && v.len() <= MAX_TEXT);
        let nonce = message.get(ATTR_NONCE).filter(|v| !v.is_empty() && v.len() <= MAX_TEXT);
        match code {
            // The first Allocate learns the realm and nonce and tries again with the key.
            401 if !request.authenticated && request.purpose == Purpose::Allocate => {
                let (Some(realm), Some(nonce)) = (realm, nonce) else {
                    self.fail(TurnError::Malformed);
                    return;
                };
                self.set_realm(realm);
                self.nonce = Some(nonce.to_vec());
                self.request(Purpose::Allocate, request.stale, now_us);
            }
            401 => self.request_failed(request.purpose, TurnError::Unauthorized, now_us),
            438 if request.stale < MAX_STALE_RETRIES => {
                let Some(nonce) = nonce else {
                    self.request_failed(request.purpose, TurnError::Rejected(438), now_us);
                    return;
                };
                if let Some(realm) = realm {
                    self.set_realm(realm);
                }
                self.nonce = Some(nonce.to_vec());
                self.request(request.purpose, request.stale + 1, now_us);
            }
            _ => self.request_failed(request.purpose, TurnError::Rejected(code), now_us),
        }
    }

    fn set_realm(&mut self, realm: &[u8]) {
        let mut md5 = Md5::new();
        md5.update(&self.username);
        md5.update(b":");
        md5.update(realm);
        md5.update(b":");
        md5.update(&self.password);
        self.key = Some(md5.finalize().into());
        self.realm = Some(realm.to_vec());
    }
}

/// Writes one STUN message.
struct Builder {
    bytes: Vec<u8>,
    overflow: bool,
}

impl Builder {
    fn new(kind: u16, tx: TransactionId) -> Self {
        let mut bytes = Vec::with_capacity(128);
        bytes.extend_from_slice(&kind.to_be_bytes());
        bytes.extend_from_slice(&[0, 0]);
        bytes.extend_from_slice(&MAGIC_COOKIE);
        bytes.extend_from_slice(&tx);
        Self { bytes, overflow: false }
    }

    fn tx(&self) -> &[u8] {
        self.bytes.get(8..HEADER_LEN).unwrap_or_default()
    }

    fn attribute(&mut self, kind: u16, value: &[u8]) {
        let Ok(length) = u16::try_from(value.len()) else {
            self.overflow = true;
            return;
        };
        self.bytes.extend_from_slice(&kind.to_be_bytes());
        self.bytes.extend_from_slice(&length.to_be_bytes());
        self.bytes.extend_from_slice(value);
        let padding = value.len().next_multiple_of(4) - value.len();
        self.bytes.extend(std::iter::repeat_n(0u8, padding));
    }

    fn address(&mut self, kind: u16, addr: SocketAddr) {
        let value = encode_address(addr, self.tx());
        self.attribute(kind, &value);
    }

    fn set_length(&mut self, extra: usize) -> bool {
        let Some(length) =
            self.bytes.len().checked_sub(HEADER_LEN).and_then(|l| u16::try_from(l + extra).ok())
        else {
            return false;
        };
        let [l0, l1] = length.to_be_bytes();
        if let Some(field) = self.bytes.get_mut(2..4) {
            field.copy_from_slice(&[l0, l1]);
        }
        true
    }

    /// The message, with MESSAGE-INTEGRITY when a key is given.
    fn finish(mut self, key: Option<&[u8; 16]>) -> Option<Vec<u8>> {
        if self.overflow {
            return None;
        }
        if let Some(key) = key {
            // The HMAC covers the header with a length that already counts the attribute.
            if !self.set_length(24) {
                return None;
            }
            let mut mac = HmacSha1::new_from_slice(key).ok()?;
            mac.update(&self.bytes);
            let tag = mac.finalize().into_bytes();
            self.attribute(ATTR_MESSAGE_INTEGRITY, &tag);
        }
        if !self.set_length(0) {
            return None;
        }
        Some(self.bytes)
    }
}

/// One parsed STUN message, borrowing the packet.
struct Message<'a> {
    kind: u16,
    tx: TransactionId,
    attributes: Vec<(u16, &'a [u8])>,
    /// Offset of the MESSAGE-INTEGRITY attribute and its value.
    integrity: Option<(usize, &'a [u8])>,
    raw: &'a [u8],
}

impl<'a> Message<'a> {
    /// Strict parse: the length field matches the packet, the magic cookie
    /// is there, attributes fit, and at most [`MAX_ATTRIBUTES`] are read.
    fn parse(raw: &'a [u8]) -> Option<Self> {
        let (header, mut body) = raw.split_first_chunk::<HEADER_LEN>()?;
        let [t0, t1, l0, l1, c0, c1, c2, c3, tx @ ..] = *header;
        if t0 & 0xC0 != 0 || [c0, c1, c2, c3] != MAGIC_COOKIE {
            return None;
        }
        let length = usize::from(u16::from_be_bytes([l0, l1]));
        if length % 4 != 0 || length != body.len() {
            return None;
        }
        let mut attributes = Vec::new();
        let mut integrity = None;
        let mut fingerprint = false;
        let mut offset = HEADER_LEN;
        while !body.is_empty() {
            if attributes.len() >= MAX_ATTRIBUTES || fingerprint {
                return None;
            }
            let ([k0, k1, a0, a1], rest) = body.split_first_chunk::<4>()?;
            let kind = u16::from_be_bytes([*k0, *k1]);
            let len = usize::from(u16::from_be_bytes([*a0, *a1]));
            let padded = len.next_multiple_of(4);
            let value = rest.get(..len)?;
            body = rest.get(padded..)?;
            match kind {
                ATTR_MESSAGE_INTEGRITY => {
                    if integrity.is_some() || len != 20 {
                        return None;
                    }
                    integrity = Some((offset, value));
                }
                ATTR_FINGERPRINT => {
                    if len != 4 {
                        return None;
                    }
                    fingerprint = true;
                }
                // Attributes after MESSAGE-INTEGRITY are not covered by it; ignore them.
                _ if integrity.is_some() => {}
                _ => attributes.push((kind, value)),
            }
            offset += 4 + padded;
        }
        Some(Self { kind: u16::from_be_bytes([t0, t1]), tx, attributes, integrity, raw })
    }

    fn get(&self, kind: u16) -> Option<&'a [u8]> {
        self.attributes.iter().find(|(k, _)| *k == kind).map(|(_, v)| *v)
    }

    fn verify(&self, key: &[u8; 16]) -> bool {
        let Some((offset, tag)) = self.integrity else { return false };
        // The covered length field runs to the end of MESSAGE-INTEGRITY:
        // (offset - 20) bytes of attributes before it plus its own 24.
        let Some(covered) = self.raw.get(..offset) else { return false };
        let Some(length) =
            (offset + 24).checked_sub(HEADER_LEN).and_then(|l| u16::try_from(l).ok())
        else {
            return false;
        };
        let Some(([t0, t1, _, _], rest)) = covered.split_first_chunk::<4>() else { return false };
        let Ok(mut mac) = HmacSha1::new_from_slice(key) else { return false };
        mac.update(&[*t0, *t1]);
        mac.update(&length.to_be_bytes());
        mac.update(rest);
        mac.verify_slice(tag).is_ok()
    }
}

fn encode_address(addr: SocketAddr, tx: &[u8]) -> Vec<u8> {
    let [c0, c1, ..] = MAGIC_COOKIE;
    let port = addr.port() ^ u16::from_be_bytes([c0, c1]);
    let mask = MAGIC_COOKIE.iter().chain(tx.iter());
    let (family, octets): (u8, Vec<u8>) = match addr.ip() {
        IpAddr::V4(ip) => (FAMILY_V4, ip.octets().iter().zip(mask).map(|(a, m)| a ^ m).collect()),
        IpAddr::V6(ip) => (FAMILY_V6, ip.octets().iter().zip(mask).map(|(a, m)| a ^ m).collect()),
    };
    let mut value = vec![0, family];
    value.extend_from_slice(&port.to_be_bytes());
    value.extend_from_slice(&octets);
    value
}

fn decode_address(value: &[u8], tx: &TransactionId) -> Option<SocketAddr> {
    let ([_, family, p0, p1], address) = value.split_first_chunk::<4>()?;
    let [c0, c1, ..] = MAGIC_COOKIE;
    let port = u16::from_be_bytes([*p0, *p1]) ^ u16::from_be_bytes([c0, c1]);
    let mask = MAGIC_COOKIE.iter().chain(tx.iter());
    let ip = match (*family, address.len()) {
        (FAMILY_V4, 4) => {
            let mut octets = [0u8; 4];
            for ((o, a), m) in octets.iter_mut().zip(address).zip(mask) {
                *o = a ^ m;
            }
            IpAddr::V4(Ipv4Addr::from(octets))
        }
        (FAMILY_V6, 16) => {
            let mut octets = [0u8; 16];
            for ((o, a), m) in octets.iter_mut().zip(address).zip(mask) {
                *o = a ^ m;
            }
            IpAddr::V6(Ipv6Addr::from(octets))
        }
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

/// ERROR-CODE: two reserved bytes, the class (3..=6) and the number (0..=99).
fn decode_error_code(value: &[u8]) -> Option<u16> {
    let ([_, _, class, number], _) = value.split_first_chunk::<4>()?;
    let class = u16::from(class & 0x07);
    let number = u16::from(*number);
    ((3..=6).contains(&class) && number < 100).then_some(class * 100 + number)
}
