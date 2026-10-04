//! The peers of a mesh: one WireGuard session each, the routes their
//! `allowed_ips` make, and the receiver-index map that finds a session for
//! an incoming datagram.

use std::collections::HashMap;
use std::net::IpAddr;

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

pub(crate) struct Peer {
    pub(crate) tunn: Tunn,
    /// This peer's 24-bit index: receiver indexes `index << 8 | n` are its.
    pub(crate) index: u32,
    pub(crate) allowed_ips: Vec<IpNetwork>,
    /// Where datagrams to the peer go: configured, or the source of its
    /// latest authenticated datagram (a UDP address or a gateway).
    pub(crate) route: Option<PeerRoute>,
    pub(crate) schedule: TimerSchedule,
}

impl Peer {
    /// Whether the peer may use `address` as a source (crypto-key routing).
    pub(crate) fn allows(&self, address: IpAddr) -> bool {
        self.allowed_ips.iter().any(|network| network.contains(address))
    }

    /// The peer proved its key in a datagram from `source`: it is reachable
    /// there now (first contact, or roaming, across UDP and gateways).
    pub(crate) fn authenticated(&mut self, source: Option<PeerRoute>, now: Instant) {
        if let Some(source) = source {
            self.route = Some(source);
        }
        self.schedule.on_activity(now);
    }
}

pub(crate) struct PeerTable {
    private: StaticSecret,
    public: PublicKey,
    peers: HashMap<PeerKey, Peer>,
    by_index: HashMap<u32, PeerKey>,
    next_index: u32,
}

impl PeerTable {
    pub(crate) fn new(private: &[u8; 32]) -> Self {
        let private = StaticSecret::from(*private);
        let public = PublicKey::from(&private);
        let mut seed = [0u8; 4];
        // A failure only makes the first index predictable; indexes are
        // not secrets, they only have to be unique.
        let _ = getrandom::fill(&mut seed);
        Self {
            private,
            public,
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

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.peers.len()
    }

    #[cfg(test)]
    pub(crate) fn index_count(&self) -> usize {
        self.by_index.len()
    }

    pub(crate) fn contains(&self, key: &PeerKey) -> bool {
        self.peers.contains_key(key)
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

    /// Refuse a peer that is this side's own key, or whose networks overlap
    /// each other or another peer's (a replaced peer's own networks do not
    /// count).
    pub(crate) fn check(&self, peer: &WgPeer) -> Result<(), WgError> {
        if peer.public_key == self.public.to_bytes() {
            return Err(WgError::InvalidPeer("a mesh cannot peer with its own key"));
        }
        for (position, network) in peer.allowed_ips.iter().enumerate() {
            if peer.allowed_ips[..position].iter().any(|earlier| overlaps(earlier, network)) {
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
    pub(crate) fn insert(&mut self, peer: WgPeer, now: Instant) -> &mut Peer {
        let previous = self.remove(&peer.public_key);
        let index = self.allocate_index();
        let tunn = Tunn::new(
            self.private.clone(),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn net(text: &str, prefix: u8) -> IpNetwork {
        IpNetwork::new(text.parse::<IpAddr>().unwrap(), prefix).unwrap()
    }

    fn peer(allowed: Vec<IpNetwork>) -> WgPeer {
        WgPeer {
            public_key: crate::testing::random_keypair().1,
            preshared_key: None,
            allowed_ips: allowed,
            route: None,
            persistent_keepalive: None,
        }
    }

    #[test]
    fn overlap_needs_one_family_and_a_shared_address() {
        assert!(overlaps(&net("fd00::", 64), &net("fd00::5", 128)));
        assert!(overlaps(&net("fd00::5", 128), &net("fd00::", 64)));
        assert!(!overlaps(&net("fd00::", 64), &net("fd01::", 64)));
        assert!(!overlaps(&net("0.0.0.0", 0), &net("::", 0)), "families never overlap");
    }

    #[test]
    fn routes_pick_the_longest_prefix_and_indexes_find_their_peer() {
        let (private, _) = crate::testing::random_keypair();
        let mut table = PeerTable::new(&private);
        let wide = peer(vec![net("10.0.0.0", 8)]);
        let narrow = peer(vec![net("10.1.0.0", 16)]);
        // Nested networks overlap, so they are refused: a route never has
        // to choose between two peers.
        table.check(&wide).unwrap();
        let wide_index = table.insert(wide.clone(), Instant::now()).index;
        assert!(matches!(table.check(&narrow), Err(WgError::AllowedIpsOverlap(_))));
        let other = peer(vec![net("fd00::", 64)]);
        table.check(&other).unwrap();
        table.insert(other.clone(), Instant::now());

        assert_eq!(table.route("10.9.9.9".parse().unwrap()), Some(wide.public_key));
        assert_eq!(table.route("fd00::1".parse().unwrap()), Some(other.public_key));
        assert_eq!(table.route("fd01::1".parse().unwrap()), None);
        assert_eq!(table.by_receiver((wide_index << 8) | 3), Some(wide.public_key));

        // Replacing gets a new index; the old one finds nobody.
        let replaced_index = table.insert(wide.clone(), Instant::now()).index;
        assert_ne!(replaced_index, wide_index);
        assert_eq!(table.by_receiver(wide_index << 8), None);
        assert_eq!(table.len(), 2);
        assert_eq!(table.index_count(), 2);
        assert!(table.remove(&wide.public_key).is_some());
        assert_eq!(table.by_receiver(replaced_index << 8), None);
    }
}
