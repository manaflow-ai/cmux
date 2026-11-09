//! The peers of a mesh: one WireGuard session each, the routes their
//! `allowed_ips` make, and the receiver-index map that finds a session for
//! an incoming datagram.

use std::collections::HashMap;
use std::net::IpAddr;
use std::time::Duration;

use boringtun::noise::Tunn;
use ip_network::IpNetwork;
use tokio::time::Instant;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::error::WgError;
use crate::mesh::WgPeer;
use crate::mesh_route::PeerRoute;
use crate::tcp_stack::PeerKey;
use crate::timers::TimerSchedule;

/// boringtun puts a session's peer index in the top 24 bits of every
/// receiver index it hands out; the low 8 bits count sessions.
const INDEX_BITS: u32 = 24;
const INDEX_MASK: u32 = (1 << INDEX_BITS) - 1;
/// How often a dial that waits on a handshake sends another initiation.
/// boringtun resends only after REKEY_TIMEOUT (5 s) plus jitter, as long as
/// `cmux link`'s whole dial: a dial whose first initiation was dropped (a
/// just-created Cloud VM's receiver that did not hold this key yet) sent
/// one initiation and never saw an answer.
const HANDSHAKE_RESEND: Duration = Duration::from_secs(1);
/// How long after its last queued packet a dial still counts as waiting:
/// TCP resends a SYN while its dial lasts, so a dial that gave up stops
/// the resends within this.
const WAIT_WINDOW: Duration = Duration::from_secs(5);

pub(crate) struct Peer {
    pub(crate) tunn: Tunn,
    /// This peer's 24-bit index: receiver indexes `index << 8 | n` are its.
    pub(crate) index: u32,
    pub(crate) allowed_ips: Vec<IpNetwork>,
    /// Where datagrams to the peer go: configured, or the source of its
    /// latest authenticated datagram.
    pub(crate) route: Option<PeerRoute>,
    pub(crate) schedule: TimerSchedule,
    /// When a packet was last queued for want of a session (a dial waiting
    /// on the handshake).
    pub(crate) waiting: Option<Instant>,
    /// When this side last sent the peer a handshake initiation.
    pub(crate) initiated: Option<Instant>,
    /// The session runs on this side's retired key (`WgMesh::add_peer_on_retired_key`).
    pub(crate) on_retired: bool,
}

impl Peer {
    /// Whether the peer may use `address` as a source (crypto-key routing).
    pub(crate) fn allows(&self, address: IpAddr) -> bool {
        self.allowed_ips.iter().any(|network| network.contains(address))
    }

    /// The peer proved its key in a datagram from `source`: it is reachable
    /// there now (first contact, or roaming).
    pub(crate) fn authenticated(&mut self, source: Option<PeerRoute>, now: Instant) {
        if let Some(source) = source {
            self.route = Some(source);
        }
        self.schedule.on_activity(now);
    }

    /// Whether a dial waits on this peer's handshake and the last initiation
    /// is [`HANDSHAKE_RESEND`] old: the driver then sends a new one.
    pub(crate) fn resend_due(&mut self, now: Instant) -> bool {
        if self.tunn.time_since_last_handshake().is_some()
            || self.waiting.is_none_or(|since| now >= since + WAIT_WINDOW)
        {
            self.waiting = None;
            return false;
        }
        self.initiated.is_none_or(|sent| now >= sent + HANDSHAKE_RESEND)
    }
}

pub(crate) struct PeerTable {
    private: StaticSecret,
    public: PublicKey,
    /// The key this side had before, still answered for the peers on it.
    retired: Option<(StaticSecret, PublicKey)>,
    peers: HashMap<PeerKey, Peer>,
    by_index: HashMap<u32, PeerKey>,
    next_index: u32,
}

impl PeerTable {
    pub(crate) fn new(private: &[u8; 32], retired: Option<&[u8; 32]>) -> Self {
        let private = StaticSecret::from(*private);
        let public = PublicKey::from(&private);
        let retired = retired.map(|retired| {
            let retired = StaticSecret::from(*retired);
            let public = PublicKey::from(&retired);
            (retired, public)
        });
        let mut seed = [0u8; 4];
        // A failure only makes the first index predictable; indexes are
        // not secrets, they only have to be unique.
        let _ = getrandom::fill(&mut seed);
        Self {
            private,
            public,
            retired,
            peers: HashMap::new(),
            by_index: HashMap::new(),
            next_index: u32::from_le_bytes(seed) & INDEX_MASK,
        }
    }

    pub(crate) fn private(&self) -> &StaticSecret {
        &self.private
    }

    pub(crate) fn public(&self) -> &PublicKey {
        &self.public
    }

    /// This side's retired key, when it has one.
    pub(crate) fn retired(&self) -> Option<(&StaticSecret, &PublicKey)> {
        self.retired.as_ref().map(|(private, public)| (private, public))
    }

    /// Whether `key` is a peer whose session runs on this side's retired key
    /// (`retired`) or on its current one.
    pub(crate) fn admits(&self, key: &PeerKey, retired: bool) -> bool {
        self.peers.get(key).is_some_and(|peer| peer.on_retired == retired)
    }

    pub(crate) fn get_mut(&mut self, key: &PeerKey) -> Option<&mut Peer> {
        self.peers.get_mut(key)
    }

    pub(crate) fn peers_mut(&mut self) -> impl Iterator<Item = &mut Peer> {
        self.peers.values_mut()
    }

    /// The key of the session that owns `receiver_index`.
    pub(crate) fn by_receiver(&self, receiver_index: u32) -> Option<PeerKey> {
        self.by_index.get(&(receiver_index >> 8)).copied()
    }

    /// The peer whose `allowed_ips` hold `destination`, longest prefix first.
    pub(crate) fn route(&self, destination: IpAddr) -> Option<PeerKey> {
        let mut best: Option<(u8, PeerKey)> = None;
        for (key, peer) in &self.peers {
            for network in &peer.allowed_ips {
                if network.contains(destination)
                    && best.is_none_or(|(prefix, _)| network.netmask() > prefix)
                {
                    best = Some((network.netmask(), *key));
                }
            }
        }
        best.map(|(_, key)| key)
    }

    /// Refuse a peer that is this side's own key (current or retired), one
    /// on a retired key this side does not have, or whose networks overlap
    /// each other or another peer's (a replaced peer's own networks do not
    /// count).
    pub(crate) fn check(&self, peer: &WgPeer, retired: bool) -> Result<(), WgError> {
        if peer.public_key == self.public.to_bytes()
            || self.retired.as_ref().is_some_and(|(_, public)| peer.public_key == public.to_bytes())
        {
            return Err(WgError::InvalidPeer("a mesh cannot peer with its own key"));
        }
        if retired && self.retired.is_none() {
            return Err(WgError::InvalidPeer("this mesh has no retired key"));
        }
        for (position, network) in peer.allowed_ips.iter().enumerate() {
            if peer.allowed_ips.iter().take(position).any(|earlier| overlaps(earlier, network)) {
                return Err(WgError::AllowedIpsOverlap(*network));
            }
            let taken = self.peers.iter().any(|(key, other)| {
                *key != peer.public_key
                    && other.allowed_ips.iter().any(|theirs| overlaps(theirs, network))
            });
            if taken {
                return Err(WgError::AllowedIpsOverlap(*network));
            }
        }
        Ok(())
    }

    /// Add `peer` with a new session, replacing one with the same key. A
    /// replaced peer keeps the route it was last seen on unless `peer`
    /// names one. Call [`PeerTable::check`] first.
    pub(crate) fn insert(&mut self, peer: WgPeer, now: Instant, retired: bool) -> &mut Peer {
        let previous = self.remove(&peer.public_key);
        let index = self.allocate_index();
        let own = match &self.retired {
            Some((private, _)) if retired => private.clone(),
            _ => self.private.clone(),
        };
        let tunn = Tunn::new(
            own,
            PublicKey::from(peer.public_key),
            peer.preshared_key.as_deref().copied(),
            peer.persistent_keepalive,
            index,
            None,
        );
        let keepalive = peer.persistent_keepalive.is_some_and(|seconds| seconds > 0);
        let entry = Peer {
            tunn,
            index,
            allowed_ips: peer.allowed_ips,
            route: peer.route.or(previous.and_then(|old| old.route)),
            schedule: TimerSchedule::new(now, keepalive),
            waiting: None,
            initiated: None,
            on_retired: retired && self.retired.is_some(),
        };
        self.by_index.insert(index, peer.public_key);
        self.peers.entry(peer.public_key).or_insert(entry)
    }

    pub(crate) fn remove(&mut self, key: &PeerKey) -> Option<Peer> {
        let peer = self.peers.remove(key)?;
        self.by_index.remove(&peer.index);
        Some(peer)
    }

    /// The earliest timer tick any session needs.
    pub(crate) fn next_tick(&self) -> Option<Instant> {
        self.peers.values().filter_map(|peer| peer.schedule.next_tick()).min()
    }

    /// A 24-bit index no current peer uses. A removed peer's index is not
    /// reused until the counter wraps, so its stale datagrams find nobody.
    fn allocate_index(&mut self) -> u32 {
        loop {
            let index = self.next_index;
            self.next_index = (self.next_index + 1) & INDEX_MASK;
            if !self.by_index.contains_key(&index) {
                return index;
            }
        }
    }
}

/// Whether two networks share an address.
pub(crate) fn overlaps(left: &IpNetwork, right: &IpNetwork) -> bool {
    left.is_ipv4() == right.is_ipv4()
        && (left.contains(right.network_address()) || right.contains(left.network_address()))
}
