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

use cmux_transport::{
    LocalNetwork, Medium, PathId, PathKind, PathState, ProbeOutcome, Selector, SelectorConfig,
    medium_of,
};
use tokio::time::Instant;

use crate::multipath::medium_for;
use crate::probe_schedule::{PathWatch, ProbeConfig};
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

#[derive(Debug)]
struct MeshPath {
    id: PathId,
    address: SocketAddr,
    kind: PathKind,
    medium: Medium,
    watch: PathWatch,
    /// Data may go here: the caller named it, the peer was heard from it,
    /// or a probe on it was answered.
    proven: bool,
    heard_at: Option<Instant>,
}

#[derive(Debug)]
pub(crate) struct MeshPaths {
    selector: Selector,
    paths: Vec<MeshPath>,
    next_id: u16,
    last_probe_id: u64,
    probes: ProbeConfig,
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
            selector: Selector::new(SelectorConfig::default()),
            paths: Vec::new(),
            next_id: 0,
            last_probe_id: random_probe_base(),
            probes: ProbeConfig::default(),
            answered: false,
            latest: route.map(canonical),
        };
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

    fn find(&self, address: SocketAddr) -> Option<usize> {
        self.paths.iter().position(|path| path.address == address)
    }

    /// The path at `address`, added when new. `None` when every path id
    /// was used or nothing could make room.
    fn add(
        &mut self,
        address: SocketAddr,
        kind: Option<PathKind>,
        proven: bool,
        networks: &[LocalNetwork],
        now: Instant,
    ) -> Option<usize> {
        let address = canonical(address);
        if let Some(index) = self.find(address) {
            if let Some(path) = self.paths.get_mut(index) {
                path.proven |= proven;
            }
            return Some(index);
        }
        if self.paths.len() >= MAX_PATHS && !self.evict(proven) {
            return None;
        }
        let kind = kind.unwrap_or_else(|| direct_kind(address, networks));
        let medium = medium_for(networks, kind, Some(address));
        if self.next_id >= MAX_PATH_IDS {
            self.renumber();
        }
        let id = PathId(self.next_id);
        self.next_id += 1;
        self.selector.add_path_on(id, kind, medium).ok()?;
        self.paths.push(MeshPath {
            id,
            address,
            kind,
            medium,
            watch: PathWatch::default(),
            proven,
            heard_at: proven.then_some(now),
        });
        Some(self.paths.len() - 1)
    }

    /// Move every path to a fresh selector with ids from zero. Each path
    /// starts probing again (data goes on every proven path until one
    /// answers), and a pong for a probe sent before is ignored.
    fn renumber(&mut self) {
        self.selector = Selector::new(SelectorConfig::default());
        for (index, path) in self.paths.iter_mut().enumerate() {
            path.id = PathId(index as u16);
            path.watch = PathWatch::default();
            let _ = self.selector.add_path_on(path.id, path.kind, path.medium);
        }
        self.next_id = self.paths.len() as u16;
    }

    /// Drop the least useful path that is not the chosen one, to make room
    /// for a new one. An unproven newcomer replaces only a dead or unproven
    /// path, never one that carries data.
    fn evict(&mut self, for_proven: bool) -> bool {
        let chosen = self.selector.chosen();
        let victim = self
            .paths
            .iter()
            .enumerate()
            .filter(|(_, path)| Some(path.id) != chosen)
            .filter(|(_, path)| {
                let dead = self.selector.path(path.id).is_some_and(|v| v.state == PathState::Dead);
                for_proven || dead || !path.proven
            })
            .min_by_key(|(_, path)| {
                let dead = self.selector.path(path.id).is_some_and(|v| v.state == PathState::Dead);
                (!dead, path.proven, path.heard_at)
            })
            .map(|(index, _)| index);
        let Some(index) = victim else { return false };
        let path = self.paths.remove(index);
        let _ = self.selector.remove_path(path.id);
        true
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
        if let Some(path) =
            self.add(source, None, true, networks, now).and_then(|index| self.paths.get_mut(index))
        {
            path.watch.heard();
            path.heard_at = Some(now);
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
        self.latest.is_some() || self.paths.iter().any(|path| path.proven)
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
            let current = self.selector.current();
            let mut any = false;
            for path in &mut self.paths {
                if current.map_or(path.proven, |id| id == path.id) {
                    path.watch.sent(now);
                    send(path.address);
                    any = true;
                }
            }
            if any {
                return;
            }
        }
        let latest = self.latest.or_else(|| self.first_proven());
        if let Some(latest) = latest {
            if let Some(path) = self.find(latest).and_then(|index| self.paths.get_mut(index)) {
                path.watch.sent(now);
            }
            send(latest);
        }
        if initiation {
            for path in self.paths.iter().filter(|path| path.proven && Some(path.address) != latest)
            {
                send(path.address);
            }
        }
    }

    fn first_proven(&self) -> Option<SocketAddr> {
        self.paths.iter().find(|path| path.proven).map(|path| path.address)
    }

    /// The pings due now and when the paths next need anything, with the
    /// lost probes and quiet chosen paths already fed to the selector.
    pub(crate) fn poll(&mut self, now: Instant) -> DueProbes {
        self.last_probe_id = random_probe_base();
        let current = self.selector.current();
        let chosen = self.selector.chosen();
        let mut due = DueProbes::default();
        let mut chosen_quiet = false;
        for path in &mut self.paths {
            let Some(view) = self.selector.path(path.id) else { continue };
            let roles = (current == Some(path.id), chosen == Some(path.id));
            let step = path.watch.step(&self.probes, &view, roles, &mut self.last_probe_id, now);
            if step.lost {
                let _ = self.selector.on_probe(path.id, ProbeOutcome::Lost);
            }
            if step.silent {
                chosen_quiet |= chosen == Some(path.id);
                let _ = self.selector.on_silence(path.id);
            }
            if let Some(probe) = step.ping {
                due.pings.push((path.id, probe));
            }
            due.next = match (due.next, step.next) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
        }
        // As in `Multipath`: when the path we sent on loses its standing, by
        // silence or by a lost probe, every other path is probed now rather
        // than at its 30 s turn.
        let left_current = current.is_some() && self.selector.current() != current;
        if chosen_quiet || left_current {
            for path in &mut self.paths {
                if Some(path.id) != chosen {
                    path.watch.probe_now(now);
                }
            }
            due.next = Some(now);
        }
        due
    }

    /// The interface table changed: read each path's medium again. A path
    /// whose medium changed is probed now, and its answer lets the selector
    /// rank it on the new medium (a Thunderbolt address learned before the
    /// bridge came up beats the routed path it was ranked with).
    pub(crate) fn reclassify(&mut self, networks: &[LocalNetwork], now: Instant) {
        for path in &mut self.paths {
            let medium = medium_for(networks, path.kind, Some(path.address));
            if medium != path.medium {
                path.medium = medium;
                let _ = self.selector.set_medium(path.id, medium);
                path.watch.probe_now(now);
            }
        }
    }

    /// Where probes on `id` go.
    pub(crate) fn address_of(&self, id: PathId) -> Option<SocketAddr> {
        self.paths.iter().find(|path| path.id == id).map(|path| path.address)
    }

    /// The pong for probe `probe` on path `id` arrived from `source`. It
    /// counts only from the address the probe went to: the id is random, so
    /// only that address could have read it.
    pub(crate) fn pong(&mut self, id: PathId, probe: u64, source: SocketAddr, now: Instant) {
        let source = canonical(source);
        let Some(path) = self.paths.iter_mut().find(|path| path.id == id) else { return };
        if path.address != source {
            return;
        }
        let Some(rtt_us) = path.watch.answer(&self.probes, probe, now) else { return };
        path.proven = true;
        self.answered = true;
        let _ = self.selector.on_probe(id, ProbeOutcome::Answered { rtt_us });
    }

    pub(crate) fn views(&self) -> Vec<MeshPathView> {
        let current = if self.answered { self.selector.current() } else { None };
        self.paths
            .iter()
            .filter_map(|path| {
                let view = self.selector.path(path.id)?;
                Some(MeshPathView {
                    address: path.address,
                    kind: view.kind,
                    medium: view.medium,
                    state: view.state,
                    rtt_us: view.rtt_us,
                    current: current == Some(path.id)
                        || (!self.answered && self.latest == Some(path.address)),
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(text: &str) -> SocketAddr {
        text.parse().unwrap()
    }

    fn targets(paths: &mut MeshPaths, now: Instant) -> Vec<SocketAddr> {
        let mut out = Vec::new();
        paths.send(now, |address| out.push(address));
        out
    }

    /// Ping every path, and answer the pings on `answering`.
    fn probe_round(paths: &mut MeshPaths, answering: &[SocketAddr], now: Instant) {
        let due = paths.poll(now);
        for (id, probe) in due.pings {
            let address = paths.address_of(id).unwrap();
            if answering.contains(&address) {
                paths.pong(id, probe, address, now + std::time::Duration::from_millis(1));
            }
        }
    }

    #[test]
    fn until_the_peer_answers_a_probe_datagrams_follow_its_latest_source() {
        let now = Instant::now();
        let lan = addr("192.168.1.20:4101");
        let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
        assert_eq!(targets(&mut paths, now), vec![lan]);
        let roamed = addr("[::ffff:10.0.0.9]:4101");
        paths.heard(roamed, true, &[], now);
        assert_eq!(targets(&mut paths, now), vec![addr("10.0.0.9:4101")], "roams as before");
    }

    #[test]
    fn an_advertised_address_carries_data_only_once_a_probe_answered_there() {
        let now = Instant::now();
        let lan = addr("192.168.1.20:4101");
        let tailnet = addr("100.64.0.20:4101");
        let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
        paths.advertised(&[tailnet, addr("0.0.0.0:1"), addr("10.0.0.1:0")], &[], now);
        assert_eq!(paths.views().len(), 2, "unspecified and port 0 are ignored");
        // Only the LAN answers: the tailnet address never gets data.
        probe_round(&mut paths, &[lan], now);
        assert_eq!(targets(&mut paths, now), vec![lan]);
        let lost = now + std::time::Duration::from_secs(2);
        let _ = paths.poll(lost);
        assert!(!targets(&mut paths, lost).contains(&tailnet));
    }

    #[test]
    fn a_quiet_chosen_path_sprays_every_proven_path_then_falls_back() {
        let start = Instant::now();
        let lan = addr("192.168.1.20:4101");
        let relay = addr("203.0.113.5:4101");
        let candidates = [
            PeerCandidate { address: lan, kind: Some(PathKind::DirectLan) },
            PeerCandidate { address: relay, kind: Some(PathKind::DoRelay) },
        ];
        let mut paths = MeshPaths::new(Some(lan), &candidates, &[], start);
        probe_round(&mut paths, &[lan, relay], start);
        assert_eq!(targets(&mut paths, start), vec![lan], "a direct path beats the relay");
        // The LAN goes quiet: datagrams out, nothing back.
        let mut now = start;
        let mut sprayed = false;
        for _ in 0..100 {
            now += std::time::Duration::from_millis(50);
            probe_round(&mut paths, &[relay], now);
            let sent = targets(&mut paths, now);
            sprayed |= sent.len() == 2;
            if sent == vec![relay] {
                break;
            }
        }
        assert!(sprayed, "every proven path while the LAN is suspect");
        assert_eq!(targets(&mut paths, now), vec![relay]);
        assert!(
            now - start < std::time::Duration::from_secs(5),
            "fell back after {:?}",
            now - start
        );
    }

    #[test]
    fn a_slow_chosen_path_that_loses_a_probe_probes_the_others_at_once() {
        let ms = std::time::Duration::from_millis;
        let start = Instant::now();
        let lan = addr("192.168.1.20:4101");
        let relay = addr("203.0.113.5:4101");
        let candidates = [
            PeerCandidate { address: lan, kind: Some(PathKind::DirectLan) },
            PeerCandidate { address: relay, kind: Some(PathKind::DoRelay) },
        ];
        let mut paths = MeshPaths::new(Some(lan), &candidates, &[], start);
        // A 400 ms LAN: four round trips of silence outlast the 1 s probe
        // timeout, so the chosen path turns suspect by a lost probe. Answer
        // everything for 2 s, so each path is on its alive interval (the
        // relay's next probe is 30 s out).
        let mut now = start;
        while now < start + ms(2000) {
            for (id, probe) in paths.poll(now).pings {
                let address = paths.address_of(id).unwrap();
                paths.pong(id, probe, address, now + ms(400));
            }
            now += ms(10);
        }
        assert_eq!(targets(&mut paths, now), vec![lan]);
        // The LAN is cut; nothing is answered from here on.
        let mut refreshed = None;
        for _ in 0..1000 {
            now += ms(10);
            let due = paths.poll(now);
            let sprayed = targets(&mut paths, now).len() == 2;
            if due.pings.iter().any(|(id, _)| paths.address_of(*id) == Some(relay)) {
                refreshed = Some((now, sprayed));
                break;
            }
        }
        let (at, sprayed) = refreshed.expect("the relay is probed before its 30 s turn");
        assert!(sprayed, "the relay is probed when the LAN turns suspect, at {:?}", at - start);
    }

    #[test]
    fn a_thunderbolt_address_learned_before_the_bridge_came_up_wins_once_it_is_up() {
        let ms = std::time::Duration::from_millis;
        let start = Instant::now();
        let wan = addr("198.51.100.20:4101");
        let bridge = addr("10.254.2.2:4101");
        // Before the cable: no interface on the bridge's network, so its
        // address is routed like the WAN one.
        let before = vec![LocalNetwork {
            interface: "en0".into(),
            address: "192.168.1.10".parse().unwrap(),
            prefix: 24,
        }];
        let mut paths = MeshPaths::new(Some(wan), &[], &before, start);
        paths.advertised(&[bridge], &before, start);
        // The WAN answers first and is held; the bridge is 1 ms faster,
        // under the 3 ms margin, so RTT alone never moves the session.
        let mut now = start;
        for _ in 0..3 {
            for (id, probe) in paths.poll(now).pings {
                let address = paths.address_of(id).unwrap();
                let rtt = if address == wan { ms(2) } else { ms(1) };
                paths.pong(id, probe, address, now + rtt);
            }
            now += ms(6000);
        }
        assert_eq!(targets(&mut paths, now), vec![wan]);
        // The bridge comes up.
        let mut after = before.clone();
        after.push(LocalNetwork {
            interface: "bridge0".into(),
            address: "10.254.2.1".parse().unwrap(),
            prefix: 30,
        });
        paths.reclassify(&after, now);
        let due = paths.poll(now);
        assert!(
            due.pings.iter().any(|(id, _)| paths.address_of(*id) == Some(bridge)),
            "the reclassified path is probed at once"
        );
        for (id, probe) in due.pings {
            let address = paths.address_of(id).unwrap();
            paths.pong(id, probe, address, now + ms(1));
        }
        assert_eq!(targets(&mut paths, now + ms(1)), vec![bridge]);
    }

    #[test]
    fn the_path_set_is_bounded_and_keeps_the_chosen_path() {
        let now = Instant::now();
        let lan = addr("192.168.1.20:4101");
        let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
        probe_round(&mut paths, &[lan], now);
        for port in 1..40 {
            paths.advertised(&[SocketAddr::new([10, 0, 0, 1].into(), port)], &[], now);
            paths.heard(SocketAddr::new([10, 0, 1, 1].into(), port), true, &[], now);
        }
        let views = paths.views();
        assert_eq!(views.len(), MAX_PATHS);
        assert!(views.iter().any(|view| view.address == lan && view.current));
    }

    #[test]
    fn a_pong_counts_only_from_the_address_its_probe_went_to() {
        let now = Instant::now();
        let lan = addr("192.168.1.20:4101");
        let elsewhere = addr("198.51.100.7:4101");
        let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
        paths.advertised(&[elsewhere], &[], now);
        let due = paths.poll(now);
        let later = now + std::time::Duration::from_millis(1);
        for (id, probe) in due.pings {
            // The peer answers every probe from its own address.
            paths.pong(id, probe, lan, later);
        }
        assert_eq!(targets(&mut paths, later), vec![lan]);
        let elsewhere_view = paths.views().into_iter().find(|view| view.address == elsewhere);
        assert_ne!(elsewhere_view.map(|view| view.state), Some(PathState::Alive));
    }

    #[test]
    fn probe_ids_are_not_sequential_across_polls() {
        let now = Instant::now();
        let lan = addr("192.168.1.20:4101");
        let relay = addr("203.0.113.5:4101");
        let mut paths = MeshPaths::new(Some(lan), &[relay.into()], &[], now);
        let first: Vec<u64> = paths.poll(now).pings.iter().map(|(_, probe)| *probe).collect();
        let later = now + std::time::Duration::from_secs(2);
        let second: Vec<u64> = paths.poll(later).pings.iter().map(|(_, probe)| *probe).collect();
        assert!(!first.is_empty() && !second.is_empty());
        assert!(
            second.iter().all(|probe| first.iter().all(|before| probe.abs_diff(*before) > 1024))
        );
    }

    #[test]
    fn address_churn_never_runs_out_of_path_ids() {
        let now = Instant::now();
        let lan = addr("192.168.1.20:4101");
        let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
        probe_round(&mut paths, &[lan], now);
        for round in 0..4_000u32 {
            let port = 1 + (round % 60_000) as u16;
            paths.advertised(&[SocketAddr::new([10, 0, 0, 1].into(), port)], &[], now);
        }
        assert!(paths.next_id <= MAX_PATH_IDS);
        assert_eq!(paths.views().len(), MAX_PATHS);
        assert!(paths.views().iter().any(|view| view.address == lan));
        // A new address is still taken after all that churn.
        let fresh = addr("10.9.9.9:4101");
        paths.heard(fresh, true, &[], now);
        assert!(paths.views().iter().any(|view| view.address == fresh));
    }

    #[test]
    fn a_handshake_initiation_tries_every_named_address_before_any_answer() {
        let now = Instant::now();
        let down = addr("192.168.1.20:4101");
        let up = addr("10.0.0.20:4101");
        let mut paths = MeshPaths::new(Some(down), &[down.into(), up.into()], &[], now);
        let mut sent = Vec::new();
        paths.send_initiation(now, |address| sent.push(address));
        assert_eq!(sent, vec![down, up]);
        assert_eq!(targets(&mut paths, now), vec![down], "data still follows the route");
    }
}
