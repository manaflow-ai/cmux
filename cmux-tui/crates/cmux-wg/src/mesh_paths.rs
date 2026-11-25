//! The paths to one mesh peer: every address it may be reached at, ranked by
//! the shared [`Selector`] exactly as a [`crate::Multipath`] ranks its paths.
//!
//! A path is one UDP address of the peer on the mesh's one socket. Paths
//! come from three places:
//!
//! - the caller's [`crate::WgPeer`]: its route and its candidates;
//! - every address an authenticated datagram of the peer came from;
//! - the addresses the peer advertised inside the session
//!   ([`cmux_transport::candidates`]).
//!
//! The first two may carry data at once. An advertised address gets only
//! probes until one is answered there, so a peer cannot point this side's
//! traffic at an address that never answered.
//!
//! Each path is probed inside the session ([`crate::probing`]) on the same
//! schedule as a [`crate::Multipath`] path, and the same quiet-path rule
//! ([`PathWatch::step`]) makes a chosen path that stops answering suspect
//! within about two silence windows, while datagrams go on every proven
//! path. A peer that never answers a probe (a build from before path
//! probes) keeps the old rule: datagrams follow its latest authenticated
//! source.

use std::net::{IpAddr, SocketAddr};

use cmux_braid_path::{IdPolicy, PathSet};
use cmux_transport::{
    LocalNetwork, Medium, PathId, PathKind, PathState, SelectorConfig, medium_of,
};
use tokio::time::Instant;

use crate::multipath::medium_for;
use crate::probe_schedule::ProbeConfig;
use crate::underlay::DueProbes;

/// Paths one peer holds at most. A new address past it replaces the least
/// useful path that is not the chosen one (dead first, then one that never
/// carried data, then the one heard from longest ago).
pub(crate) const MAX_PATHS: usize = 8;

/// Path ids one selector hands out before the paths are renumbered on a
/// fresh one. The selector never reuses a removed path's id and checks new
/// ids against every removed one, so this bounds that list (and the work of
/// adding a path) however often the peer's addresses churn.
const MAX_PATH_IDS: u16 = 256;

/// A random first probe id for one poll: a pong must echo an id that only
/// the probed address was sent, so another address can't answer for it.
/// Half the range, so the poll's few increments never overflow.
fn random_probe_base() -> u64 {
    let mut bytes = [0u8; 8];
    let _ = getrandom::fill(&mut bytes);
    u64::from_le_bytes(bytes) >> 1
}

/// An address the caller knows for a peer, with the kind of path it is
/// when the caller knows better than this machine's interface table (a
/// relay, a region).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PeerCandidate {
    pub address: SocketAddr,
    /// `None`: a direct path, LAN or routed by the interface table.
    pub kind: Option<PathKind>,
}

impl From<SocketAddr> for PeerCandidate {
    fn from(address: SocketAddr) -> Self {
        Self { address, kind: None }
    }
}

/// One path of a peer as [`crate::WgMesh::peer_paths`] reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeshPathView {
    pub address: SocketAddr,
    pub kind: PathKind,
    pub medium: Medium,
    pub state: PathState,
    pub rtt_us: Option<u64>,
    /// The path the next datagram takes alone.
    pub current: bool,
}

/// What the mesh keeps per path beside the shared path set's own.
#[derive(Debug)]
struct MeshPath {
    /// Data may go here: the caller named it, the peer was heard from it,
    /// or a probe on it was answered.
    proven: bool,
    heard_at: Option<Instant>,
}

#[derive(Debug)]
pub(crate) struct MeshPaths {
    paths: PathSet<SocketAddr, MeshPath>,
    /// The peer answered a probe: the selector decides from now on.
    answered: bool,
    /// The latest authenticated source, else the configured route: where
    /// datagrams go until the peer answers a probe.
    latest: Option<SocketAddr>,
}

/// An IPv4 address seen on a dual-stack socket is the same path as the
/// plain IPv4 address.
fn canonical(address: SocketAddr) -> SocketAddr {
    match address.ip() {
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => SocketAddr::new(IpAddr::V4(v4), address.port()),
            None => address,
        },
        IpAddr::V4(_) => address,
    }
}

/// A direct path's kind from the interface table: on a local network
/// (LAN or Thunderbolt) or routed.
fn direct_kind(address: SocketAddr, networks: &[LocalNetwork]) -> PathKind {
    match medium_of(address.ip(), networks) {
        Medium::Link | Medium::Lan => PathKind::DirectLan,
        Medium::Routed => PathKind::DirectWan,
    }
}

impl MeshPaths {
    pub(crate) fn new(
        route: Option<SocketAddr>,
        candidates: &[PeerCandidate],
        networks: &[LocalNetwork],
        now: Instant,
    ) -> Self {
        let mut paths = Self {
            paths: PathSet::new(SelectorConfig::default(), ProbeConfig::default())
                .with_ids(IdPolicy { first: 0, renumber_at: Some(MAX_PATH_IDS) }),
            answered: false,
            latest: route.map(canonical),
        };
        paths.paths.set_probe_base(random_probe_base());
        for candidate in candidates {
            paths.add(candidate.address, candidate.kind, true, networks, now);
        }
        if let Some(route) = route {
            paths.add(route, None, true, networks, now);
        }
        paths
    }

    /// Where datagrams went before the peer answered a probe, for a
    /// replaced peer that names no route of its own.
    pub(crate) fn latest(&self) -> Option<SocketAddr> {
        self.latest
    }

    /// The path at `address`, added when new. `false` when every path id
    /// was used or nothing could make room.
    fn add(
        &mut self,
        address: SocketAddr,
        kind: Option<PathKind>,
        proven: bool,
        networks: &[LocalNetwork],
        now: Instant,
    ) -> bool {
        let address = canonical(address);
        if let Some(path) = self.paths.get_mut(&address) {
            path.meta.proven |= proven;
            return true;
        }
        if self.paths.len() >= MAX_PATHS && !self.evict(proven) {
            return false;
        }
        let kind = kind.unwrap_or_else(|| direct_kind(address, networks));
        let medium = medium_for(networks, kind, Some(address));
        let meta = MeshPath { proven, heard_at: proven.then_some(now) };
        self.paths.insert(address, kind, medium, meta, now).is_ok()
    }

    /// Drop the least useful path that is not the chosen one, to make room
    /// for a new one. An unproven newcomer replaces only a dead or unproven
    /// path, never one that carries data.
    fn evict(&mut self, for_proven: bool) -> bool {
        let chosen = self.paths.selector().chosen();
        let dead = |id: PathId| self.paths.view(id).is_some_and(|v| v.state == PathState::Dead);
        let victim = self
            .paths
            .iter()
            .filter(|path| Some(path.id()) != chosen)
            .filter(|path| for_proven || dead(path.id()) || !path.meta.proven)
            .min_by_key(|path| (!dead(path.id()), path.meta.proven, path.meta.heard_at))
            .map(|path| *path.route());
        let Some(address) = victim else { return false };
        self.paths.remove(&address).is_some()
    }

    /// An authenticated datagram of the peer came from `source`. Only
    /// traffic (`roams`), not a probe, moves where datagrams go before the
    /// peer answered a probe: a peer probing all its paths would otherwise
    /// flip it to whichever path pinged last.
    pub(crate) fn heard(
        &mut self,
        source: SocketAddr,
        roams: bool,
        networks: &[LocalNetwork],
        now: Instant,
    ) {
        let source = canonical(source);
        if roams {
            self.latest = Some(source);
        }
        if self.add(source, None, true, networks, now)
            && let Some(path) = self.paths.get_mut(&source)
        {
            path.watch.heard();
            path.meta.heard_at = Some(now);
        }
    }

    /// Addresses the peer advertised inside the session.
    pub(crate) fn advertised(
        &mut self,
        addresses: &[SocketAddr],
        networks: &[LocalNetwork],
        now: Instant,
    ) {
        for address in addresses {
            let address = canonical(*address);
            if address.port() != 0 && crate::mesh_driver::advertisable(address.ip()) {
                self.add(address, None, false, networks, now);
            }
        }
    }

    pub(crate) fn path_count(&self) -> usize {
        self.paths.len()
    }

    /// Whether any datagram has somewhere to go.
    pub(crate) fn has_target(&self) -> bool {
        self.latest.is_some() || self.paths.iter().any(|path| path.meta.proven)
    }

    /// Call `send` with each address the next datagram goes to: the
    /// selector's current path; every proven path while it has none (a
    /// dial, or the chosen path went quiet); or, until the peer answers a
    /// probe, its latest authenticated source.
    pub(crate) fn send(&mut self, now: Instant, send: impl FnMut(SocketAddr)) {
        self.send_datagram(now, false, send);
    }

    /// [`MeshPaths::send`] for a handshake initiation: until the peer
    /// answers a probe, it goes to the latest source and every address the
    /// caller named too, so a session can start on any of them when the
    /// first is unreachable.
    pub(crate) fn send_initiation(&mut self, now: Instant, send: impl FnMut(SocketAddr)) {
        self.send_datagram(now, true, send);
    }

    fn send_datagram(&mut self, now: Instant, initiation: bool, mut send: impl FnMut(SocketAddr)) {
        if self.answered {
            let current = self.paths.selector().current();
            let mut any = false;
            for path in self.paths.iter_mut() {
                if current.map_or(path.meta.proven, |id| id == path.id()) {
                    path.watch.sent(now);
                    send(*path.route());
                    any = true;
                }
            }
            if any {
                return;
            }
        }
        let latest = self.latest.or_else(|| self.first_proven());
        if let Some(latest) = latest {
            if let Some(path) = self.paths.get_mut(&latest) {
                path.watch.sent(now);
            }
            send(latest);
        }
        if initiation {
            for path in
                self.paths.iter().filter(|path| path.meta.proven && Some(*path.route()) != latest)
            {
                send(*path.route());
            }
        }
    }

    fn first_proven(&self) -> Option<SocketAddr> {
        self.paths.iter().find(|path| path.meta.proven).map(|path| *path.route())
    }

    /// The pings due now and when the paths next need anything, with the
    /// lost probes and quiet chosen paths already fed to the selector (and
    /// every other path probed at once when the one in use lost its
    /// standing, as in `Multipath`).
    pub(crate) fn poll(&mut self, now: Instant) -> DueProbes {
        self.paths.set_probe_base(random_probe_base());
        self.paths.poll(now)
    }

    /// The interface table changed: read each path's medium again. A path
    /// whose medium changed is probed now, and its answer lets the selector
    /// rank it on the new medium (a Thunderbolt address learned before the
    /// bridge came up beats the routed path it was ranked with).
    pub(crate) fn reclassify(&mut self, networks: &[LocalNetwork], now: Instant) {
        let changed =
            self.paths.reclassify(|address, kind| medium_for(networks, kind, Some(*address)));
        for id in changed {
            if let Some(path) = self.paths.by_id_mut(id) {
                path.watch.probe_now(now);
            }
        }
    }

    /// Where probes on `id` go.
    pub(crate) fn address_of(&self, id: PathId) -> Option<SocketAddr> {
        self.paths.route_of(id).copied()
    }

    /// The pong for probe `probe` on path `id` arrived from `source`. It
    /// counts only from the address the probe went to: the id is random, so
    /// only that address could have read it.
    pub(crate) fn pong(&mut self, id: PathId, probe: u64, source: SocketAddr, now: Instant) {
        if self.address_of(id) != Some(canonical(source)) {
            return;
        }
        if self.paths.answer(id, probe, now).is_none() {
            return;
        }
        if let Some(path) = self.paths.by_id_mut(id) {
            path.meta.proven = true;
        }
        self.answered = true;
    }

    pub(crate) fn views(&self) -> Vec<MeshPathView> {
        let current = if self.answered { self.paths.selector().current() } else { None };
        self.paths
            .iter()
            .filter_map(|path| {
                let view = self.paths.view(path.id())?;
                Some(MeshPathView {
                    address: *path.route(),
                    kind: view.kind,
                    medium: view.medium,
                    state: view.state,
                    rtt_us: view.rtt_us,
                    current: current == Some(path.id())
                        || (!self.answered && self.latest == Some(*path.route())),
                })
            })
            .collect()
    }
}

#[cfg(test)]
#[path = "mesh_paths_tests.rs"]
mod tests;
