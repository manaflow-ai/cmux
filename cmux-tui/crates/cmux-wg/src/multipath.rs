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
//! Both halves share one mutex. The driver holds it only for the duration of
//! one send or one receive poll, never across an await.

use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll, Waker};

use cmux_transport::{
    PathId, PathKind, PathView, ProbeOutcome, Selector, SelectorConfig, SelectorError, Switch,
};
use tokio::sync::{broadcast, watch};
use tokio::time::Instant;

use crate::probe_schedule::{PathProbe, ProbeConfig};
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
    probe: PathProbe,
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
    /// No path will ever be added: once every path failed, the underlay
    /// reports the last failure and the session ends, as a plain socket's
    /// would. Otherwise the endpoint may still add a path.
    fixed_paths: bool,
}

impl Shared {
    fn slot_mut(&mut self, id: PathId) -> Option<&mut Slot> {
        self.slots.iter_mut().find(|slot| slot.id == id)
    }

    /// Publish the current path; a switch also sends a path event.
    fn publish(&mut self) {
        let current = self.selector.current();
        let switched =
            self.current.send_if_modified(|seen| std::mem::replace(seen, current) != current);
        if switched {
            self.emit(Instant::now());
        }
    }

    /// The current path and how it performs, as a path event carries it.
    fn event(&self) -> PathEvent {
        let path = self.selector.current();
        let view = path.and_then(|id| self.selector.path(id));
        let slot = path.and_then(|id| self.slots.iter().find(|slot| slot.id == id));
        PathEvent {
            path,
            kind: view.map(|view| view.kind),
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

    /// Whether a path the next datagram would take is backlogged: the
    /// current path, or any path while datagrams go on every path. A
    /// backlog on a path not in use never holds the session back.
    fn backlogged(&self) -> bool {
        let current = self.selector.current();
        let targeted = current.is_some_and(|id| self.slots.iter().any(|slot| slot.id == id));
        self.slots.iter().any(|slot| {
            !slot.failed && (!targeted || Some(slot.id) == current) && slot.carrier.backlogged()
        })
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
            fixed_paths: false,
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
    pub fn add_path(&self, kind: PathKind, carrier: impl Underlay) -> PathId {
        let (id, waker) = {
            let mut shared = lock(&self.shared);
            let id = PathId(shared.next_id);
            shared.next_id = shared.next_id.wrapping_add(1);
            shared.selector.add_path(id, kind).expect("path ids are never reused");
            let carrier = Box::new(carrier);
            let probe = PathProbe::default();
            shared.slots.push(Slot {
                id,
                carrier,
                sent: 0,
                received: 0,
                failed: false,
                probe,
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
        let current = shared.selector.current();
        let mut due = DueProbes { pings: Vec::new(), next: next_event };
        let mut lost = Vec::new();
        let Shared { slots, selector, last_probe_id, .. } = &mut *shared;
        for slot in slots.iter_mut().filter(|slot| !slot.failed) {
            let Some(view) = selector.path(slot.id) else { continue };
            let is_current = current == Some(slot.id);
            let step = config.step(&mut slot.probe, &view, is_current, last_probe_id, now);
            if step.lost {
                lost.push(slot.id);
            }
            if let Some(id) = step.ping {
                due.pings.push((slot.id, id));
            }
            due.next = match (due.next, step.next) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
        }
        for id in lost {
            shared.probe(id, ProbeOutcome::Lost);
        }
        due
    }

    fn set_max_datagram(&mut self, bytes: usize) {
        lock(&self.shared).max_datagram = bytes;
    }

    fn on_pong(&mut self, path: PathId, id: u64, now: Instant) {
        let mut shared = lock(&self.shared);
        let Some(config) = shared.probes else { return };
        let Some(slot) = shared.slot_mut(path) else { return };
        if let Some(rtt_us) = config.answer(&mut slot.probe, id, now) {
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
            let slot = &mut shared.slots[index];
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
