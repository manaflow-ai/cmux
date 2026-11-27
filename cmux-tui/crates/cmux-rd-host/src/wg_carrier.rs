//! Session-scoped WG media inside the authenticated hub rd-link. Only public
//! keys cross control. Transport fallback needs a peer ACK and delivery barrier;
//! authentication, consent, revocation and failures after readiness never retry.
mod runtime;
use cmux_rd_link::net::NetSender;
use cmux_rd_proto::app_line::{CarrierFallback, CarrierKind, RetryCarrier, WgFallbackReason};
use cmux_wg::{InterfaceAddress, IpNetwork, WgConfig};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::io;
use std::net::{IpAddr, Ipv4Addr};
use std::os::fd::RawFd;
use std::time::{Duration, Instant};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

const VERSION: u8 = 1;
const MEDIA_PORT: u16 = 4103;
const QUEUE: usize = 256;
pub const READY_TIMEOUT: Duration = Duration::from_secs(3);
pub const RETRY_TIMEOUT: Duration = Duration::from_secs(3);
const OUTER_MAX: usize = 1152 - cmux_rd_link::SEAL_OVERHEAD;
// WG adds 32 bytes and pads the inner packet to 16 bytes; the UDP API budgets
// IPv6+UDP (48 bytes), even with our IPv4 point-to-point addresses.
const MTU: u16 = (((OUTER_MAX - 32) / 16) * 16) as u16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Host,
    Viewer,
}
impl Role {
    fn local(self) -> Ipv4Addr {
        Ipv4Addr::new(10, 253, 0, if self == Self::Host { 1 } else { 2 })
    }
    fn peer(self) -> Ipv4Addr {
        Ipv4Addr::new(10, 253, 0, if self == Self::Host { 2 } else { 1 })
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "t", rename_all = "snake_case", deny_unknown_fields)]
// The `Wg` prefix is the wire tag (`wg_offer`, `wg_ready`, ...), not decoration.
#[allow(clippy::enum_variant_names)]
pub enum Control {
    WgOffer { version: u8, key: String, address: Ipv4Addr, mtu: u16 },
    WgAnswer { version: u8, key: String, address: Ipv4Addr, mtu: u16 },
    WgReady,
    WgFallback { reason: WgFallbackReason },
    WgFallbackAck { reason: WgFallbackReason },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Negotiating,
    Ready,
    Retrying,
    Retry(WgFallbackReason),
    Failed,
}

/// Pure retry exchange. Each side proposes once and acknowledges the peer's
/// proposal. A valid peer ACK alone is insufficient: our outgoing ACK must also
/// have been delivered (rd-link's reliable-control barrier).
#[derive(Default)]
struct Retry {
    requested: Option<WgFallbackReason>,
    peer: Option<WgFallbackReason>,
    acknowledged: bool,
    ack_sent: bool,
    deadline: Option<Instant>,
}
impl Retry {
    fn request(&mut self, reason: WgFallbackReason, now: Instant, out: &mut VecDeque<Control>) {
        if self.requested.is_none() {
            self.requested = Some(reason);
            self.deadline = Some(now + RETRY_TIMEOUT);
            out.push_back(Control::WgFallback { reason });
        }
    }
    fn receive(&mut self, record: &Control, now: Instant, out: &mut VecDeque<Control>) {
        match *record {
            Control::WgFallback { reason } if self.peer.is_none() => {
                self.peer = Some(reason);
                self.request(reason, now, out);
                out.push_back(Control::WgFallbackAck { reason });
                self.ack_sent = true;
            }
            Control::WgFallbackAck { reason } if self.requested == Some(reason) => {
                self.acknowledged = true
            }
            _ => {}
        }
    }
    fn expired(&self, now: Instant) -> bool {
        self.deadline.is_some_and(|deadline| now >= deadline)
    }
    fn ready(&self, delivered: bool) -> Option<WgFallbackReason> {
        (self.acknowledged && self.ack_sent && delivered).then_some(self.requested).flatten()
    }
}

pub struct Negotiation {
    role: Role,
    private: Zeroizing<[u8; 32]>,
    public: [u8; 32],
    peer: Option<([u8; 32], u16)>,
    started: Option<Instant>,
    session: Option<runtime::Session>,
    pending: VecDeque<Vec<u8>>,
    outgoing: VecDeque<Control>,
    ready_sent: bool,
    peer_ready: bool,
    committed: bool,
    failed: bool,
    retry: Retry,
}
impl Negotiation {
    pub fn new(role: Role) -> io::Result<Self> {
        let mut bytes = Zeroizing::new([0u8; 32]);
        getrandom::fill(&mut *bytes).map_err(|_| io::Error::other("WG key generation failed"))?;
        let secret = StaticSecret::from(*bytes);
        let public = PublicKey::from(&secret).to_bytes();
        Ok(Self {
            role,
            private: Zeroizing::new(secret.to_bytes()),
            public,
            peer: None,
            started: None,
            session: None,
            pending: VecDeque::new(),
            outgoing: VecDeque::new(),
            ready_sent: false,
            peer_ready: false,
            committed: false,
            failed: false,
            retry: Retry::default(),
        })
    }
    pub fn begin(&mut self, now: Instant) {
        if self.started.is_none() {
            self.started = Some(now);
            self.outgoing.push_back(Control::WgOffer {
                version: VERSION,
                key: crate::serve::hex(&self.public),
                address: self.role.local(),
                mtu: MTU,
            });
        }
    }
    pub fn accept(&mut self, record: &[u8], now: Instant) -> bool {
        let parsed = serde_json::from_slice::<Control>(record);
        let control = match parsed {
            Ok(control) => control,
            Err(_) => {
                let ours = serde_json::from_slice::<serde_json::Value>(record)
                    .ok()
                    .and_then(|v| v.get("t").and_then(|t| t.as_str()).map(|t| t.starts_with("wg_")))
                    .unwrap_or(false);
                if ours {
                    // Unknown/authorization retry reasons are not transport failures.
                    let tag = serde_json::from_slice::<serde_json::Value>(record)
                        .ok()
                        .and_then(|v| v.get("t").and_then(|v| v.as_str()).map(str::to_owned));
                    if matches!(tag.as_deref(), Some("wg_offer" | "wg_answer")) {
                        self.fail(WgFallbackReason::Malformed, now);
                    } else {
                        self.failed = true;
                    }
                }
                return ours;
            }
        };
        if self.started.is_none() || self.failed {
            return true;
        }
        if self.committed {
            if matches!(control, Control::WgFallback { .. } | Control::WgFallbackAck { .. }) {
                self.failed = true;
            }
            return true;
        }
        match control {
            Control::WgFallback { .. } | Control::WgFallbackAck { .. } => {
                self.retry.receive(&control, now, &mut self.outgoing)
            }
            Control::WgReady => {
                if self.peer.is_some() {
                    self.peer_ready = true;
                }
            }
            Control::WgOffer { version, key, address, mtu }
            | Control::WgAnswer { version, key, address, mtu } => {
                if self.retry.requested.is_some() {
                    return true;
                }
                if version != VERSION {
                    self.fail(WgFallbackReason::Unsupported, now);
                    return true;
                }
                let Some(key) = crate::serve::unhex32(&key)
                    .filter(|key| *key != [0; 32] && *key != self.public)
                else {
                    self.fail(WgFallbackReason::Malformed, now);
                    return true;
                };
                if address != self.role.peer() || mtu < 576 {
                    self.fail(WgFallbackReason::Malformed, now);
                    return true;
                }
                if let Some(previous) = self.peer {
                    if previous != (key, mtu.min(MTU)) {
                        self.fail(WgFallbackReason::Malformed, now);
                    }
                    return true;
                }
                self.peer = Some((key, mtu.min(MTU)));
                self.outgoing.push_back(Control::WgAnswer {
                    version: VERSION,
                    key: crate::serve::hex(&self.public),
                    address: self.role.local(),
                    mtu: mtu.min(MTU),
                });
            }
        }
        true
    }
    fn fail(&mut self, reason: WgFallbackReason, now: Instant) {
        if self.committed {
            self.failed = true;
        } else {
            self.retry.request(reason, now, &mut self.outgoing);
        }
    }
    pub fn tick(&mut self, sender: &NetSender, now: Instant) {
        if self.failed {
            return;
        }
        if self.retry.requested.is_none() && self.session.is_none() {
            if let Some((peer_public_key, mtu)) = self.peer {
                let config = WgConfig {
                    private_key: self.private.clone(),
                    addresses: vec![InterfaceAddress {
                        address: IpAddr::V4(self.role.local()),
                        prefix: 32,
                    }],
                    mtu,
                    peer_public_key,
                    preshared_key: None,
                    allowed_ips: vec![IpNetwork::V4(self.role.peer().into())],
                    endpoint: None,
                    persistent_keepalive: None,
                    peer_addresses: vec![IpAddr::V4(self.role.peer())],
                    ultra: cmux_wg::UltraChoice::Off,
                };
                match runtime::Session::start(config, sender.clone(), self.role.peer()) {
                    Ok(session) => {
                        for packet in self.pending.drain(..) {
                            session.inject(packet);
                        }
                        self.session = Some(session);
                    }
                    Err(_) => self.fail(WgFallbackReason::Overloaded, now),
                }
            }
        }
        if self.retry.requested.is_none() {
            if self.session.as_ref().is_some_and(runtime::Session::failed) {
                self.fail(WgFallbackReason::Closed, now);
            } else if self.session.as_ref().is_some_and(runtime::Session::ready) && !self.ready_sent
            {
                self.ready_sent = true;
                self.outgoing.push_back(Control::WgReady);
            }
            if !self.committed
                && self
                    .started
                    .is_some_and(|start| now.saturating_duration_since(start) >= READY_TIMEOUT)
                && !(self.ready_sent && self.peer_ready)
            {
                self.fail(
                    if self.peer.is_some() {
                        WgFallbackReason::Timeout
                    } else {
                        WgFallbackReason::Unsupported
                    },
                    now,
                );
            }
        }
        if self.retry.expired(now) {
            self.failed = true;
        }
        while let Some(record) = self.outgoing.pop_front() {
            match serde_json::to_vec(&record) {
                Ok(bytes) => sender.send_control(bytes),
                Err(_) => self.failed = true,
            }
        }
    }
    pub fn state(&self, delivered: bool) -> State {
        if self.failed {
            return State::Failed;
        }
        if let Some(reason) = self.retry.ready(delivered) {
            return State::Retry(reason);
        }
        if self.retry.requested.is_some() {
            return State::Retrying;
        }
        if self.ready_sent
            && self.peer_ready
            && self.session.as_ref().is_some_and(runtime::Session::ready)
        {
            State::Ready
        } else {
            State::Negotiating
        }
    }
    pub fn commit(&mut self) {
        self.committed = true;
    }
    pub fn invalidate(&mut self) {
        self.failed = true;
    }
    pub fn ack_sent(&self) -> bool {
        self.retry.ack_sent
    }
    pub fn fd(&self) -> Option<RawFd> {
        self.session.as_ref().map(runtime::Session::fd)
    }
    pub fn max_datagram(&self) -> usize {
        usize::from(self.peer.map_or(MTU, |(_, mtu)| mtu)) - 48
    }
    pub fn inject(&mut self, payload: Vec<u8>) {
        if self.retry.requested.is_some() || self.failed || payload.len() > OUTER_MAX {
            return;
        }
        if let Some(session) = &self.session {
            session.inject(payload);
        } else if self.pending.len() < 32 {
            self.pending.push_back(payload);
        }
    }
    pub fn send(&self, payload: &[u8]) -> io::Result<()> {
        if self.state(false) != State::Ready {
            return Err(io::Error::new(io::ErrorKind::NotConnected, "WG media is not ready"));
        }
        self.session
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "WG missing"))?
            .send(payload)
    }
    pub fn receive(&self, out: &mut Vec<Vec<u8>>) {
        if let Some(session) = &self.session {
            session.drain(out);
        }
    }
}
pub fn fallback(reason: WgFallbackReason) -> CarrierFallback {
    CarrierFallback { carrier: CarrierKind::RdWg, reason, retry: RetryCarrier::WebRtc }
}

#[cfg(test)]
#[path = "wg_carrier_tests.rs"]
mod tests;
