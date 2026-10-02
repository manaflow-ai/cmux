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
use tokio::sync::watch;
use tokio::time::Instant;

use crate::probe_schedule::{PathProbe, ProbeConfig};
use crate::underlay::{DueProbes, Origin, Received, Underlay, is_transient};

/// Times one carrier is re-polled after a transient receive error before the
/// poll moves on, so a burst of ICMP errors cannot starve the other paths.
const TRANSIENT_RETRIES: usize = 8;

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
}

impl Shared {
    fn slot_mut(&mut self, id: PathId) -> Option<&mut Slot> {
        self.slots.iter_mut().find(|slot| slot.id == id)
    }

    /// Publish the current path after anything that may have moved it.
    fn publish(&self) {
        let current = self.selector.current();
        self.current.send_if_modified(|seen| std::mem::replace(seen, current) != current);
    }

    fn probe(&mut self, id: PathId, outcome: ProbeOutcome) {
        let _ = self.selector.on_probe(id, outcome);
        self.publish();
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
        }));
        (Self { shared: Arc::clone(&shared) }, MultipathControl { shared })
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
            shared.slots.push(Slot { id, carrier, sent: 0, received: 0, failed: false, probe });
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
        let switch = shared.selector.on_probe(id, outcome);
        shared.publish();
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
        let Some(config) = shared.probes else { return DueProbes::default() };
        let current = shared.selector.current();
        let mut due = DueProbes::default();
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
