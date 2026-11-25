//! One peer's paths: the routes it may be reached on, ranked by the shared
//! [`Selector`], probed on one schedule ([`PathWatch`]), with the numbers each path
//! earned ([`PathStats`]).
//!
//! Before this type every stack wrapped `Selector` with its own copy of the same
//! bookkeeping (RFD 0164 slice B4): a route-to-[`PathId`] map whose ids are never reused,
//! a probe watch per path, the poll that feeds lost probes and silences to the selector
//! and probes every other path at once when the one in use loses its standing, and the
//! pong that turns an answer into a round trip. `PathSet<R, M>` is that bookkeeping once,
//! generic over the route type `R` (a socket address, a carrier and an address, a relay)
//! and the caller's own per-path data `M`. It wraps the selector rather than replacing it:
//! ranking, hysteresis and relay-first stay in `cmux_transport`.

use cmux_transport::{
    Medium, PathId, PathKind, PathState, PathView, ProbeOutcome, Selector, SelectorConfig,
    SelectorError, Switch,
};
use tokio::time::{Duration, Instant};

use crate::last_good::LastGood;
use crate::probe::{DueProbes, PathWatch, ProbeConfig};

/// What one path earned: its round trips, their jitter, its probe loss, and when it last
/// answered.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct PathStats {
    /// The round trip of the latest answer, in microseconds.
    pub last_rtt_us: Option<u64>,
    /// Smoothed jitter: the mean deviation of successive round trips (RFC 3550 style,
    /// weight 1/16), in microseconds.
    pub jitter_us: f64,
    /// Smoothed probe loss in percent (weight 1/8 per probe).
    pub loss_pct: f64,
    /// When the path last answered a probe or opened.
    pub last_ok: Option<Instant>,
    /// Probes answered and lost since the path was added.
    pub answered: u64,
    pub lost: u64,
}

impl PathStats {
    fn record(&mut self, outcome: ProbeOutcome, now: Instant) {
        match outcome {
            ProbeOutcome::Answered { rtt_us } => {
                if let Some(last) = self.last_rtt_us {
                    let deviation = rtt_us.abs_diff(last) as f64;
                    self.jitter_us += (deviation - self.jitter_us) / 16.0;
                }
                self.last_rtt_us = Some(rtt_us);
                self.loss_pct -= self.loss_pct / 8.0;
                self.last_ok = Some(now);
                self.answered += 1;
            }
            ProbeOutcome::Lost => {
                self.loss_pct += (100.0 - self.loss_pct) / 8.0;
                self.lost += 1;
            }
        }
    }
}

/// One path of a [`PathSet`].
#[derive(Debug, Clone)]
pub struct Path<R, M> {
    id: PathId,
    route: R,
    /// The caller's own data about this path.
    pub meta: M,
    /// Its probes and quiet-path watch: tell it what was sent and heard on the path.
    pub watch: PathWatch,
    stats: PathStats,
    added_at: Instant,
    /// How long after it was added it first answered or opened.
    connect: Option<Duration>,
}

impl<R, M> Path<R, M> {
    #[must_use]
    pub fn id(&self) -> PathId {
        self.id
    }

    #[must_use]
    pub fn route(&self) -> &R {
        &self.route
    }

    #[must_use]
    pub fn stats(&self) -> PathStats {
        self.stats
    }

    /// How long after it was added the path first answered (or opened): its connect time.
    #[must_use]
    pub fn connect(&self) -> Option<Duration> {
        self.connect
    }

    fn reached(&mut self, now: Instant) {
        self.connect.get_or_insert_with(|| now.saturating_duration_since(self.added_at));
    }
}

/// How path ids are handed out. The selector never takes an id back (a late answer for a
/// removed path must not make a new one alive), so a long-lived set either wraps around
/// the 16-bit space, trying each id until the selector accepts one, or renumbers every
/// path onto a fresh selector when `renumber_at` ids were used.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct IdPolicy {
    /// The first id, and where a wrap starts again (ids below it may name something else:
    /// the iPhone link's receive origins).
    pub first: u16,
    /// Renumber onto a fresh selector once the next id reaches this. Every path starts
    /// probing again, and a pong for a probe sent before is ignored. `None`: wrap.
    pub renumber_at: Option<u16>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathSetError {
    /// A path on this route is already in the set.
    DuplicateRoute(PathId),
    /// Every path id was used and the policy does not renumber.
    OutOfIds,
}

/// One peer's paths over routes `R`, each carrying the caller's `M`.
#[derive(Debug, Clone)]
pub struct PathSet<R, M = ()> {
    config: SelectorConfig,
    selector: Selector,
    paths: Vec<Path<R, M>>,
    ids: IdPolicy,
    next_id: u16,
    probes: ProbeConfig,
    last_probe_id: u64,
}

impl<R: Clone + PartialEq, M> PathSet<R, M> {
    /// An empty set ranked by a selector of `config`, probed on `probes`.
    #[must_use]
    pub fn new(config: SelectorConfig, probes: ProbeConfig) -> Self {
        Self {
            config,
            selector: Selector::new(config),
            paths: Vec::new(),
            ids: IdPolicy::default(),
            next_id: 0,
            probes,
            last_probe_id: 0,
        }
    }

    /// The same set handing out ids by `ids`.
    #[must_use]
    pub fn with_ids(self, ids: IdPolicy) -> Self {
        Self { ids, next_id: self.next_id.max(ids.first), ..self }
    }

    /// The selector: states, smoothed round trips, the chosen path.
    #[must_use]
    pub fn selector(&self) -> &Selector {
        &self.selector
    }

    #[must_use]
    pub fn probes(&self) -> ProbeConfig {
        self.probes
    }

    /// The probe schedule from now on (a background app rests its standbys).
    pub fn set_probes(&mut self, probes: ProbeConfig) {
        self.probes = probes;
    }

    /// The id the next path gets, before any wrap or renumbering.
    #[must_use]
    pub fn next_id(&self) -> u16 {
        self.next_id
    }

    /// Where the next probe ids count from: a caller whose pongs could be forged by
    /// another address picks a random base for each poll.
    pub fn set_probe_base(&mut self, base: u64) {
        self.last_probe_id = base;
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.paths.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.paths.is_empty()
    }

    /// The paths in the order they were added.
    pub fn iter(&self) -> impl Iterator<Item = &Path<R, M>> {
        self.paths.iter()
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = &mut Path<R, M>> {
        self.paths.iter_mut()
    }

    #[must_use]
    pub fn get(&self, route: &R) -> Option<&Path<R, M>> {
        self.paths.iter().find(|path| path.route == *route)
    }

    pub fn get_mut(&mut self, route: &R) -> Option<&mut Path<R, M>> {
        self.paths.iter_mut().find(|path| path.route == *route)
    }

    #[must_use]
    pub fn by_id(&self, id: PathId) -> Option<&Path<R, M>> {
        self.paths.iter().find(|path| path.id == id)
    }

    pub fn by_id_mut(&mut self, id: PathId) -> Option<&mut Path<R, M>> {
        self.paths.iter_mut().find(|path| path.id == id)
    }

    #[must_use]
    pub fn id_of(&self, route: &R) -> Option<PathId> {
        self.get(route).map(Path::id)
    }

    #[must_use]
    pub fn route_of(&self, id: PathId) -> Option<&R> {
        self.by_id(id).map(Path::route)
    }

    /// The selector's view of path `id`: kind, medium, state, smoothed round trip.
    #[must_use]
    pub fn view(&self, id: PathId) -> Option<PathView> {
        self.selector.path(id)
    }

    /// The route the next datagram takes alone: an alive path the selector chose. `None`:
    /// every path (a dial, the chosen one is suspect, or every path died).
    #[must_use]
    pub fn primary(&self) -> Option<&R> {
        self.selector.current().and_then(|id| self.route_of(id))
    }

    /// The route the selector holds, alive or suspect.
    #[must_use]
    pub fn chosen(&self) -> Option<&R> {
        self.selector.chosen().and_then(|id| self.route_of(id))
    }

    /// The chosen path went quiet: datagrams go on every path until it answers or dies.
    #[must_use]
    pub fn suspect(&self) -> bool {
        self.selector.chosen().is_some() && self.selector.current().is_none()
    }

    /// The route a failover would take now: the best alive path the selector does not
    /// hold, by class, medium and smoothed round trip, as the selector ranks.
    #[must_use]
    pub fn standby(&self) -> Option<&R> {
        let chosen = self.selector.chosen();
        self.selector
            .paths()
            .filter(|view| view.state == PathState::Alive && Some(view.id) != chosen)
            .min_by_key(|view| (view.rank(), view.rtt_us.unwrap_or(u64::MAX), view.id))
            .and_then(|view| self.route_of(view.id))
    }

    /// Adds a probing path on `route`. Until some path answers, datagrams go on every path.
    pub fn insert(
        &mut self,
        route: R,
        kind: PathKind,
        medium: Medium,
        meta: M,
        now: Instant,
    ) -> Result<PathId, PathSetError> {
        if let Some(path) = self.get(&route) {
            return Err(PathSetError::DuplicateRoute(path.id));
        }
        if self.ids.renumber_at.is_some_and(|at| self.next_id >= at) {
            self.renumber();
        }
        let id = self.allocate(kind, medium)?;
        self.paths.push(Path {
            id,
            route,
            meta,
            watch: PathWatch::default(),
            stats: PathStats::default(),
            added_at: now,
            connect: None,
        });
        Ok(id)
    }

    fn allocate(&mut self, kind: PathKind, medium: Medium) -> Result<PathId, PathSetError> {
        for _ in 0..=u16::MAX {
            let id = PathId(self.next_id);
            self.next_id = self.next_id.checked_add(1).unwrap_or(self.ids.first);
            if self.selector.add_path_on(id, kind, medium).is_ok() {
                return Ok(id);
            }
        }
        Err(PathSetError::OutOfIds)
    }

    /// Every path onto a fresh selector with ids from [`IdPolicy::first`]: each starts
    /// probing again (datagrams go on every path until one answers).
    fn renumber(&mut self) {
        let mut selector = Selector::new(self.config);
        let mut next = self.ids.first;
        for path in &mut self.paths {
            let view = self.selector.path(path.id);
            path.id = PathId(next);
            next = next.wrapping_add(1);
            path.watch = PathWatch::default();
            if let Some(view) = view {
                let _ = selector.add_path_on(path.id, view.kind, view.medium);
            }
        }
        self.selector = selector;
        self.next_id = next;
    }

    /// Removes the path on `route` (the selector moves off it).
    pub fn remove(&mut self, route: &R) -> Option<(Path<R, M>, Option<Switch>)> {
        let index = self.paths.iter().position(|path| path.route == *route)?;
        let path = self.paths.remove(index);
        let switch = self.selector.remove_path(path.id).ok().flatten();
        Some((path, switch))
    }

    /// Removes every path `keep` refuses.
    pub fn retain(&mut self, mut keep: impl FnMut(&Path<R, M>) -> bool) {
        let gone: Vec<R> =
            self.paths.iter().filter(|path| !keep(path)).map(|path| path.route.clone()).collect();
        for route in gone {
            self.remove(&route);
        }
    }

    /// A path's medium, read again from a changed interface table (takes effect at the
    /// next reselection). Whether it changed.
    pub fn set_medium(&mut self, id: PathId, medium: Medium) -> bool {
        let changed = self.selector.path(id).is_some_and(|view| view.medium != medium);
        changed && self.selector.set_medium(id, medium).is_ok()
    }

    /// Reads every path's medium again with `medium_of`; returns the paths whose medium
    /// changed.
    pub fn reclassify(&mut self, mut medium_of: impl FnMut(&R, PathKind) -> Medium) -> Vec<PathId> {
        let wanted: Vec<(PathId, Medium)> = self
            .paths
            .iter()
            .filter_map(|path| {
                let view = self.selector.path(path.id)?;
                Some((path.id, medium_of(&path.route, view.kind)))
            })
            .collect();
        wanted
            .into_iter()
            .filter(|(id, medium)| self.set_medium(*id, *medium))
            .map(|(id, _)| id)
            .collect()
    }

    /// This side's network changed: every path starts probing again (mappings changed;
    /// each must answer again). With `fresh_watches`, the probe schedule starts over too.
    pub fn on_network_change(&mut self, fresh_watches: bool) -> Option<Switch> {
        let switch = self.selector.on_network_change();
        if fresh_watches {
            for path in &mut self.paths {
                path.watch = PathWatch::default();
            }
        }
        switch
    }

    /// One probe outcome the caller measured itself: the path's stats, then the selector.
    pub fn record(
        &mut self,
        id: PathId,
        outcome: ProbeOutcome,
        now: Instant,
    ) -> Result<Option<Switch>, SelectorError> {
        if let Some(path) = self.by_id_mut(id) {
            path.stats.record(outcome, now);
            if matches!(outcome, ProbeOutcome::Answered { .. }) {
                path.reached(now);
            }
        }
        self.selector.on_probe(id, outcome)
    }

    /// A dial opened path `id`: it carries the session before any probe measured it.
    pub fn opened(&mut self, id: PathId, now: Instant) -> Result<Option<Switch>, SelectorError> {
        if let Some(path) = self.by_id_mut(id) {
            path.stats.last_ok = Some(now);
            path.reached(now);
        }
        self.selector.on_opened(id)
    }

    /// Nothing came back on `id` for longer than its round trip allows: it turns suspect.
    pub fn silence(&mut self, id: PathId) -> Result<Option<Switch>, SelectorError> {
        self.selector.on_silence(id)
    }

    /// The answer to probe `probe` on path `id` arrived at `now`: its round trip, once it
    /// is the probe outstanding there, recorded in the stats and fed to the selector.
    pub fn answer(&mut self, id: PathId, probe: u64, now: Instant) -> Option<u64> {
        let probes = self.probes;
        let rtt_us = self.by_id_mut(id)?.watch.answer(&probes, probe, now)?;
        let _ = self.record(id, ProbeOutcome::Answered { rtt_us }, now);
        Some(rtt_us)
    }

    /// The pings due at `now` and when the paths next need anything, with lost probes and
    /// quiet chosen paths already fed to the selector.
    pub fn poll(&mut self, now: Instant) -> DueProbes {
        self.poll_where(now, |_, _, _| false)
    }

    /// [`PathSet::poll`] that leaves out the paths `skip` names (a failed carrier, a
    /// resting standby). `skip` sees the path, its view, and whether it is current and
    /// whether it is chosen.
    ///
    /// When the path in use loses its standing in this poll, by silence or by a lost
    /// probe, every other path is probed now rather than at its turn: the others were last
    /// heard up to a probe interval ago, and the cut may have taken them too, so the
    /// fallback is a path that answers today.
    pub fn poll_where(
        &mut self,
        now: Instant,
        mut skip: impl FnMut(&Path<R, M>, &PathView, (bool, bool)) -> bool,
    ) -> DueProbes {
        let current = self.selector.current();
        let chosen = self.selector.chosen();
        let mut due = DueProbes::default();
        let mut lost = Vec::new();
        let mut silent = Vec::new();
        let probes = self.probes;
        for path in &mut self.paths {
            let Some(view) = self.selector.path(path.id) else { continue };
            let roles = (current == Some(path.id), chosen == Some(path.id));
            if skip(path, &view, roles) {
                continue;
            }
            let step = path.watch.step(&probes, &view, roles, &mut self.last_probe_id, now);
            if step.lost {
                lost.push(path.id);
            }
            if step.silent {
                silent.push(path.id);
            }
            if let Some(probe) = step.ping {
                due.pings.push((path.id, probe));
            }
            due.next = earliest(due.next, step.next);
        }
        for id in lost {
            let _ = self.record(id, ProbeOutcome::Lost, now);
        }
        let chosen_quiet = chosen.is_some_and(|id| silent.contains(&id));
        for id in silent {
            let _ = self.selector.on_silence(id);
        }
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

    /// Remembers the primary route as the winner for `key`, with its connect time, so the
    /// next dial to that peer tries it first. Whether there was one to remember.
    pub fn remember<K: Eq + std::hash::Hash>(&self, memory: &LastGood<K, R>, key: K) -> bool {
        let Some(path) = self.selector.current().and_then(|id| self.by_id(id)) else {
            return false;
        };
        memory.record(key, path.route.clone(), path.connect.unwrap_or_default());
        true
    }
}

/// The earlier of two optional deadlines.
#[must_use]
pub fn earliest(a: Option<Instant>, b: Option<Instant>) -> Option<Instant> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

#[cfg(test)]
#[path = "path_set_tests.rs"]
mod tests;
