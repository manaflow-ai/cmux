//! Several paths to one peer under one WireGuard session.
//!
//! [`Multipath`] is the [`Underlay`] the driver owns; [`MultipathControl`] is
//! the handle the endpoint keeps to add and remove paths and to feed the
//! [`Selector`] probe outcomes and network changes. Each outgoing datagram
//! goes on the selector's current path, or on every path while
//! `current()` is `None` (a dial, or after every path died), so the first
//! path that works carries the session. Datagrams are accepted from every
//! path: WireGuard authenticates them, and its replay window drops the
//! duplicates that sending on every path produces. Switching paths
//! therefore never touches the session or its TCP streams.
//!
//! With a [`ProbeConfig`], the underlay also schedules path probes, which the
//! driver sends inside the session and answers on the arrival path; their
//! outcomes drive the selector with no help from the endpoint. Without one,
//! the endpoint drives the selector through [`MultipathControl::on_probe`].
//!
//! Each path carries the [`Medium`] its peer address is on, read from this
//! machine's interface table, so a Thunderbolt Bridge beats the office LAN
//! and the LAN beats a tailnet or relay address at once. With probes, a
//! current path that goes quiet (datagrams out, nothing authenticated back
//! for a silence window) is probed at once, and a probe unanswered for a
//! window makes it suspect: datagrams then go on every path until it
//! answers or dies, so a dropped fast path costs about two windows instead
//! of three probe timeouts.
//!
//! Both halves share one mutex. The driver holds it only for the duration of
//! one send or one receive poll, never across an await.

use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll, Waker};

use cmux_transport::selector::default_medium;
use cmux_transport::{
    LocalNetwork, Medium, PathId, PathKind, PathView, ProbeOutcome, Selector, SelectorConfig,
    SelectorError, Switch, local_networks, medium_of,
};
use tokio::sync::{broadcast, watch};
use tokio::time::Instant;

use crate::probe_schedule::{PathWatch, ProbeConfig};
use crate::underlay::{DueProbes, Origin, Received, Underlay, is_transient};

/// Times one carrier is re-polled after a transient receive error before the
/// poll moves on, so a burst of ICMP errors cannot starve the other paths.
const TRANSIENT_RETRIES: usize = 8;

/// Path events go out at least this often while the session carries traffic.
const EVENT_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);
/// Path events a slow subscriber may fall behind before it misses some.
const EVENT_BACKLOG: usize = 64;

/// `path.changed` (transport.md 12a): the path the session uses and how it
/// performs. Sent on every switch, and every 5 s while the session carries
/// traffic. `path` and `kind` are `None` while datagrams go on every path.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PathEvent {
    pub path: Option<PathId>,
    pub kind: Option<PathKind>,
    /// What the described path rides (Thunderbolt, LAN, routed).
    pub medium: Option<Medium>,
    pub rtt_ms: f64,
    pub jitter_ms: f64,
    pub loss_pct: f64,
    pub max_datagram: usize,
}

/// One path as the endpoint sees it: the selector's view plus counters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PathStats {
    pub view: PathView,
    /// Datagrams handed to this path's carrier.
    pub sent: u64,
    /// Datagrams received on this path, before authentication.
    pub received: u64,
    /// The carrier failed with a non-transient error and is no longer polled.
    pub failed: bool,
}

struct Slot {
    id: PathId,
    carrier: Box<dyn Underlay>,
    sent: u64,
    received: u64,
    failed: bool,
    /// Probes and silence: shared with the mesh's peer paths.
    watch: PathWatch,
    /// The last round trip measured, smoothed jitter (mean deviation of
    /// successive round trips, RFC 3550 style) and smoothed probe loss.
    last_rtt_us: Option<u64>,
    jitter_us: f64,
    loss_pct: f64,
}

struct Shared {
    selector: Selector,
    slots: Vec<Slot>,
    next_id: u16,
    /// Round-robin start of the next receive poll, for fairness.
    next_poll: usize,
    /// The driver's waker, so a path added later is polled at once.
    waker: Option<Waker>,
    probes: Option<ProbeConfig>,
    last_probe_id: u64,
    /// The selector's current path, for whoever shows or awaits it.
    current: watch::Sender<Option<PathId>>,
    events: broadcast::Sender<PathEvent>,
    last_event: Option<Instant>,
    max_datagram: usize,
    /// The last path that carried the session, described by events while
    /// no path does.
    last_path: Option<PathId>,
    /// The path the selector holds, sprayed around or not: its death while
    /// datagrams already go on every path is still an event.
    held: Option<PathId>,
    /// No path will ever be added: once every path failed, the underlay
    /// reports the last failure and the session ends, as a plain socket's
    /// would. Otherwise the endpoint may still add a path.
    fixed_paths: bool,
    /// This machine's interfaces, for each new path's medium.
    networks: Vec<LocalNetwork>,
}

impl Shared {
    fn slot_mut(&mut self, id: PathId) -> Option<&mut Slot> {
        self.slots.iter_mut().find(|slot| slot.id == id)
    }

    /// Publish the current path; a switch also sends a path event.
    fn publish(&mut self) {
        let current = self.selector.current();
        if current.is_some() {
            self.last_path = current;
        }
        let switched =
            self.current.send_if_modified(|seen| std::mem::replace(seen, current) != current);
        let held = self.selector.chosen();
        let held_died = self.held.is_some() && held.is_none();
        self.held = held;
        if switched || held_died {
            self.emit(Instant::now());
        }
    }

    /// The current path and how it performs, as a path event carries it.
    ///
    /// With no current path (every path dead, or none answered yet), the
    /// event names no path but still describes the last one that carried
    /// the session, if it still exists: its kind, last RTT and loss. A dead
    /// only path therefore reads as "cloud region, 60 % loss", not as a
    /// blank with 0 % loss.
    fn event(&self) -> PathEvent {
        let path = self.selector.current();
        let described =
            path.or(self.last_path).filter(|id| self.slots.iter().any(|slot| slot.id == *id));
        let view = described.and_then(|id| self.selector.path(id));
        let slot = described.and_then(|id| self.slots.iter().find(|slot| slot.id == id));
        PathEvent {
            path,
            kind: view.map(|view| view.kind),
            medium: view.map(|view| view.medium),
            rtt_ms: view.and_then(|view| view.rtt_us).map_or(0.0, |rtt| rtt as f64 / 1000.0),
            jitter_ms: slot.map_or(0.0, |slot| slot.jitter_us / 1000.0),
            loss_pct: slot.map_or(0.0, |slot| slot.loss_pct),
            max_datagram: self.max_datagram,
        }
    }

    fn emit(&mut self, now: Instant) {
        // No subscriber is fine: events are for whoever listens.
        let _ = self.events.send(self.event());
        self.last_event = Some(now);
    }

    /// Apply one probe outcome to the path's statistics and the selector.
    fn record(
        &mut self,
        id: PathId,
        outcome: ProbeOutcome,
    ) -> Result<Option<Switch>, SelectorError> {
        if let Some(slot) = self.slot_mut(id) {
            match outcome {
                ProbeOutcome::Answered { rtt_us } => {
                    if let Some(last) = slot.last_rtt_us {
                        let deviation = rtt_us.abs_diff(last) as f64;
                        slot.jitter_us += (deviation - slot.jitter_us) / 16.0;
                    }
                    slot.last_rtt_us = Some(rtt_us);
                    slot.loss_pct -= slot.loss_pct / 8.0;
                }
                ProbeOutcome::Lost => slot.loss_pct += (100.0 - slot.loss_pct) / 8.0,
            }
        }
        let switch = self.selector.on_probe(id, outcome);
        self.publish();
        switch
    }

    fn probe(&mut self, id: PathId, outcome: ProbeOutcome) {
        let _ = self.record(id, outcome);
    }

    /// Whether the next datagram has to wait: the current path is
    /// backlogged, or, while datagrams go on every path, every path is. A
    /// stuck path never holds back one that can still send, and a backlog
    /// on a path not in use never holds the session back.
    fn backlogged(&self) -> bool {
        let current = self.selector.current();
        let targeted = current.is_some_and(|id| self.slots.iter().any(|slot| slot.id == id));
        if targeted {
            return self
                .slots
                .iter()
                .any(|slot| !slot.failed && Some(slot.id) == current && slot.carrier.backlogged());
        }
        let mut live = self.slots.iter().filter(|slot| !slot.failed).peekable();
        live.peek().is_some() && live.all(|slot| slot.carrier.backlogged())
    }
}

/// The driver's half: an [`Underlay`] over every path of one peer.
pub struct Multipath {
    shared: Arc<Mutex<Shared>>,
}

/// The endpoint's half: path set, probe outcomes, and stats.
#[derive(Clone)]
pub struct MultipathControl {
    shared: Arc<Mutex<Shared>>,
}

fn lock(shared: &Mutex<Shared>) -> MutexGuard<'_, Shared> {
    shared.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Release the lock, then wake the driver so it re-polls the path set: a
/// path it waited on may be gone, or the backlog that held data may now
/// belong to a path no longer in use.
fn wake_driver(mut shared: MutexGuard<'_, Shared>) {
    let waker = shared.waker.take();
    drop(shared);
    if let Some(waker) = waker {
        waker.wake();
    }
}

impl Multipath {
    /// Paths whose selector the endpoint drives with
    /// [`MultipathControl::on_probe`].
    pub fn new(config: SelectorConfig) -> (Self, MultipathControl) {
        Self::build(config, None)
    }

    /// Paths probed by the engine itself, inside the session.
    pub fn with_probes(config: SelectorConfig, probes: ProbeConfig) -> (Self, MultipathControl) {
        Self::build(config, Some(probes))
    }

    fn build(config: SelectorConfig, probes: Option<ProbeConfig>) -> (Self, MultipathControl) {
        let shared = Arc::new(Mutex::new(Shared {
            selector: Selector::new(config),
            slots: Vec::new(),
            next_id: 0,
            next_poll: 0,
            waker: None,
            probes,
            last_probe_id: 0,
            current: watch::channel(None).0,
            events: broadcast::channel(EVENT_BACKLOG).0,
            last_event: None,
            max_datagram: 0,
            last_path: None,
            held: None,
            fixed_paths: false,
            networks: local_networks(),
        }));
        (Self { shared: Arc::clone(&shared) }, MultipathControl { shared })
    }

    /// Declare the path set final: when every path has failed, the next
    /// receive returns the failure and the driver ends the session.
    pub(crate) fn with_fixed_paths(self) -> Self {
        lock(&self.shared).fixed_paths = true;
        self
    }
}

impl MultipathControl {
    /// Add a path. It starts probing; until some path answers, datagrams go
    /// on every path.
    ///
    /// Path ids are 16 bits and the selector never takes one back, so the
    /// next id the selector accepts is used. After all 65536 ids are used,
    /// `add_path` logs, drops the path (its carrier) and returns an id that
    /// names no live path, so `remove_path` and `on_probe` on it fail.
    ///
    /// The path's medium comes from where the carrier's peer address is in
    /// this machine's interface table (a direct path), or from its kind.
    pub fn add_path(&self, kind: PathKind, carrier: impl Underlay) -> PathId {
        let medium = {
            let shared = lock(&self.shared);
            medium_for(&shared.networks, kind, carrier.peer_hint())
        };
        self.add_path_on(kind, medium, carrier)
    }

    /// [`MultipathControl::add_path`] with a medium the caller knows (a
    /// test, or an engine with better knowledge than the interface table).
    pub fn add_path_on(&self, kind: PathKind, medium: Medium, carrier: impl Underlay) -> PathId {
        let (id, waker) = {
            let mut shared = lock(&self.shared);
            let mut accepted = None;
            for _ in 0..=u16::MAX {
                let id = PathId(shared.next_id);
                shared.next_id = shared.next_id.wrapping_add(1);
                if shared.selector.add_path_on(id, kind, medium).is_ok() {
                    accepted = Some(id);
                    break;
                }
            }
            let Some(id) = accepted else {
                eprintln!("wireguard path not added: every path id was used");
                // A retired id, so `remove_path` and `on_probe` on it fail
                // instead of acting on a live path.
                let live = |id: &PathId| shared.slots.iter().any(|slot| slot.id == *id);
                return (0..=u16::MAX)
                    .map(PathId)
                    .find(|id| !live(id))
                    .unwrap_or(PathId(shared.next_id));
            };
            let carrier = Box::new(carrier);
            shared.slots.push(Slot {
                id,
                carrier,
                sent: 0,
                received: 0,
                failed: false,
                watch: PathWatch::default(),
                last_rtt_us: None,
                jitter_us: 0.0,
                loss_pct: 0.0,
            });
            (id, shared.waker.take())
        };
        // The driver must poll the new carrier once to register its waker.
        if let Some(waker) = waker {
            waker.wake();
        }
        id
    }

    /// Remove a path and drop its carrier.
    pub fn remove_path(&self, id: PathId) -> Result<Option<Switch>, SelectorError> {
        let mut shared = lock(&self.shared);
        let switch = shared.selector.remove_path(id)?;
        shared.slots.retain(|slot| slot.id != id);
        shared.publish();
        wake_driver(shared);
        Ok(switch)
    }

    pub fn on_probe(
        &self,
        id: PathId,
        outcome: ProbeOutcome,
    ) -> Result<Option<Switch>, SelectorError> {
        let mut shared = lock(&self.shared);
        let switch = shared.record(id, outcome);
        if matches!(switch, Ok(Some(_))) {
            wake_driver(shared);
        }
        switch
    }

    pub fn on_network_change(&self) -> Option<Switch> {
        let mut shared = lock(&self.shared);
        // Interfaces came or went: read the table again and re-rank.
        shared.networks = local_networks();
        let Shared { slots, selector, networks, .. } = &mut *shared;
        for slot in slots.iter() {
            if let Some(view) = selector.path(slot.id) {
                let medium = medium_for(networks, view.kind, slot.carrier.peer_hint());
                let _ = selector.set_medium(slot.id, medium);
            }
        }
        let switch = shared.selector.on_network_change();
        shared.publish();
        wake_driver(shared);
        switch
    }

    /// The path event that describes the session now, for a subscriber
    /// that must not wait for the next switch or the next 5 s tick.
    pub fn snapshot(&self) -> PathEvent {
        lock(&self.shared).event()
    }

    /// Subscribe to path events (`path.changed`).
    pub fn path_events(&self) -> broadcast::Receiver<PathEvent> {
        lock(&self.shared).events.subscribe()
    }

    /// Follow the current path (`None`: every path), for a path badge or a
    /// test that waits for a switch.
    pub fn watch_current(&self) -> watch::Receiver<Option<PathId>> {
        lock(&self.shared).current.subscribe()
    }

    /// The path the next datagram takes, or `None` for every path.
    pub fn current(&self) -> Option<PathId> {
        lock(&self.shared).selector.current()
    }

    pub fn path(&self, id: PathId) -> Option<PathStats> {
        self.paths().into_iter().find(|path| path.view.id == id)
    }

    pub fn paths(&self) -> Vec<PathStats> {
        let shared = lock(&self.shared);
        shared
            .slots
            .iter()
            .filter_map(|slot| {
                let view = shared.selector.path(slot.id)?;
                Some(PathStats {
                    view,
                    sent: slot.sent,
                    received: slot.received,
                    failed: slot.failed,
                })
            })
            .collect()
    }
}

impl Underlay for Multipath {
    fn send(&mut self, datagram: &[u8]) {
        let mut shared = lock(&self.shared);
        let current = shared.selector.current();
        let targeted = current.is_some_and(|id| shared.slots.iter().any(|slot| slot.id == id));
        for slot in &mut shared.slots {
            if slot.failed || (targeted && Some(slot.id) != current) {
                continue;
            }
            slot.carrier.send(datagram);
            slot.sent += 1;
            slot.watch.sent(Instant::now());
        }
    }

    fn send_on(&mut self, path: PathId, datagram: &[u8]) {
        if let Some(slot) = lock(&self.shared).slot_mut(path)
            && !slot.failed
        {
            slot.carrier.send(datagram);
            slot.sent += 1;
        }
    }

    fn poll_probes(&mut self, now: Instant) -> DueProbes {
        let mut shared = lock(&self.shared);
        // The driver asks only while the session carries traffic, which is
        // when periodic path events are due.
        if shared.last_event.is_none_or(|at| now >= at + EVENT_INTERVAL) {
            shared.emit(now);
        }
        let next_event = shared.last_event.map(|at| at + EVENT_INTERVAL);
        let Some(config) = shared.probes else {
            return DueProbes { pings: Vec::new(), next: next_event };
        };
        let Shared { slots, selector, last_probe_id, .. } = &mut *shared;
        let live = slots.iter_mut().filter(|slot| !slot.failed);
        let watched =
            config.watch(selector, live.map(|slot| (slot.id, &mut slot.watch)), last_probe_id, now);
        for id in watched.lost {
            shared.probe(id, ProbeOutcome::Lost);
        }
        for id in watched.silent {
            let _ = shared.selector.on_silence(id);
            shared.publish();
        }
        let next = match (next_event, watched.next) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        DueProbes { pings: watched.pings, next }
    }

    fn set_max_datagram(&mut self, bytes: usize) {
        lock(&self.shared).max_datagram = bytes;
    }

    fn on_pong(&mut self, path: PathId, id: u64, now: Instant) {
        let mut shared = lock(&self.shared);
        let Some(config) = shared.probes else { return };
        let Some(slot) = shared.slot_mut(path) else { return };
        if let Some(rtt_us) = config.answer(&mut slot.watch.probe, id, now) {
            shared.probe(path, ProbeOutcome::Answered { rtt_us });
        }
    }

    fn flush(&mut self) {
        for slot in &mut lock(&self.shared).slots {
            slot.carrier.flush();
        }
    }

    fn backlogged(&self) -> bool {
        lock(&self.shared).backlogged()
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        let mut shared = lock(&self.shared);
        for slot in &mut shared.slots {
            // Every path drains, but only the ones in use decide readiness.
            let _ = slot.carrier.poll_flush(cx);
        }
        if shared.backlogged() { Poll::Pending } else { Poll::Ready(()) }
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        let mut shared = lock(&self.shared);
        match &shared.waker {
            Some(waker) if waker.will_wake(cx.waker()) => {}
            _ => shared.waker = Some(cx.waker().clone()),
        }
        let count = shared.slots.len();
        for step in 0..count {
            let index = (shared.next_poll + step) % count;
            let Some(slot) = shared.slots.get_mut(index) else { continue };
            if slot.failed {
                continue;
            }
            for attempt in 1..=TRANSIENT_RETRIES {
                match slot.carrier.poll_recv(cx, buffer) {
                    Poll::Ready(Ok(received)) => {
                        slot.received += 1;
                        let origin = Origin { path: slot.id, addr: received.origin.addr };
                        shared.next_poll = index + 1;
                        return Poll::Ready(Ok(Received { len: received.len, origin }));
                    }
                    Poll::Ready(Err(error)) if is_transient(&error) => {
                        // Out of retries, the carrier has no waker registered:
                        // come back on the next driver pass.
                        if attempt == TRANSIENT_RETRIES {
                            cx.waker().wake_by_ref();
                        }
                    }
                    Poll::Ready(Err(error)) => {
                        eprintln!("wireguard path {:?} failed: {error}", slot.id);
                        slot.failed = true;
                        if shared.fixed_paths && shared.slots.iter().all(|slot| slot.failed) {
                            return Poll::Ready(Err(error));
                        }
                        break;
                    }
                    Poll::Pending => break,
                }
            }
        }
        Poll::Pending
    }

    fn authenticated(&mut self, origin: Origin) {
        if let Some(slot) = lock(&self.shared).slot_mut(origin.path) {
            slot.watch.heard();
            slot.carrier.authenticated(origin);
        }
    }

    fn has_peer(&self) -> bool {
        lock(&self.shared).slots.iter().any(|slot| !slot.failed && slot.carrier.has_peer())
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        let shared = lock(&self.shared);
        let current = shared.selector.current();
        shared
            .slots
            .iter()
            .find(|slot| Some(slot.id) == current)
            .or_else(|| shared.slots.first())
            .and_then(|slot| slot.carrier.peer_hint())
    }
}

/// A path's medium: where its peer address is in the interface table for a
/// direct path, else what its kind implies.
pub(crate) fn medium_for(networks: &[LocalNetwork], kind: PathKind, peer: Option<SocketAddr>) -> Medium {
    match peer {
        Some(peer) if kind.class().is_direct() && !networks.is_empty() => {
            medium_of(peer.ip(), networks)
        }
        _ => default_medium(kind),
    }
}
