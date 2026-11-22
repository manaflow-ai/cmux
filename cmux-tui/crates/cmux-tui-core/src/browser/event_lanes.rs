//! CDP event lanes: one ordered lane per browser surface, served by one small
//! process-wide pool instead of one `browser-surface-{id}-events` thread per
//! surface (perf-lead F6, chrome-parity p01-process task 206).
//!
//! Owner: the browser runtime. The runtime's router (`browser-runtime-events`)
//! demultiplexes CDP events by session into each surface's [`SurfaceRoute`]
//! and never waits on a lane. A route with queued events and a handler is in
//! the pool's ready queue at most once, so at most one pool thread runs a
//! surface's handler at a time and its events keep CDP order. A thread serves
//! at most [`EVENTS_PER_TURN`] events of one lane, then puts the lane back at
//! the end of the ready queue, so a flooding page never starves the others.
//! This is Chrome's `SequencedTaskRunner` on a shared pool: sequences, not
//! threads, per object.
//!
//! Handlers must not wait on CDP replies or durable registry work. CDP sends
//! are fire-and-forget (`*_detached`); registry work suspends just its lane
//! while the surface's command worker runs it. A panic ends only that lane.

#[cfg(test)]
use std::collections::HashSet;
use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Condvar, Mutex, OnceLock};

use cmux_tui_cdp::{CDP_EVENT_QUEUE_CAPACITY, CdpEvent};

use crate::panic_free::RecoverPoison;

/// Threads in the process-wide lane pool; blocking work runs elsewhere.
pub(super) const EVENT_POOL_THREADS: usize = 2;
/// Events one pool thread serves from a lane before it yields the lane.
const EVENTS_PER_TURN: usize = 32;

/// What a lane does after a handler served one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum LaneFlow {
    Continue,
    /// The surface is done with its events: the handler is dropped, and the
    /// route refuses further events (the router then drops it).
    End,
}

pub(super) type LaneHandler = Box<dyn FnMut(CdpEvent) -> LaneFlow + Send>;

pub(super) struct SurfaceRoute {
    state: Mutex<SurfaceRouteState>,
    /// Taken by the one pool thread that serves this lane, put back after.
    handler: Mutex<Option<LaneHandler>>,
    /// Wakes tests that read a lane directly ([`Self::recv`], [`Self::wait_ended`]).
    #[cfg(test)]
    changed: Condvar,
}

#[derive(Default)]
struct SurfaceRouteState {
    events: VecDeque<QueuedSurfaceEvent>,
    retained_bytes: usize,
    closed: bool,
    has_handler: bool,
    /// In the pool's ready queue or being served.
    scheduled: bool,
    paused: bool,
    /// Its handler ended; nothing is served any more.
    ended: bool,
}

struct QueuedSurfaceEvent {
    event: CdpEvent,
    retained_bytes: usize,
}

impl SurfaceRoute {
    pub(super) fn new() -> Self {
        Self {
            state: Mutex::new(SurfaceRouteState::default()),
            handler: Mutex::new(None),
            #[cfg(test)]
            changed: Condvar::new(),
        }
    }

    /// Returns true when the route must be removed from the runtime maps.
    pub(super) fn deliver(self: &Arc<Self>, event: CdpEvent) -> bool {
        let mut state = self.state.lock().recover_poison();
        if state.closed || state.ended {
            return true;
        }

        let replacement = match &event {
            CdpEvent::ScreencastFrame(_) => state
                .events
                .iter()
                .position(|queued| matches!(&queued.event, CdpEvent::ScreencastFrame(_))),
            CdpEvent::ScreencastFrameCaptureRequested { .. } => {
                state.events.iter().position(|queued| {
                    matches!(
                        &queued.event,
                        CdpEvent::ScreencastFrameCaptureRequested { .. }
                    )
                })
            }
            CdpEvent::TargetInfoChanged(info) => state.events.iter().position(|queued| {
                matches!(&queued.event, CdpEvent::TargetInfoChanged(existing) if existing.target_id == info.target_id)
            }),
            _ => None,
        };
        if let Some(index) = replacement
            && let Some(removed) = state.events.remove(index)
        {
            state.retained_bytes = state.retained_bytes.saturating_sub(removed.retained_bytes);
        }
        let event_bytes = cmux_tui_cdp::event_retained_bytes(&event);
        if state.events.len() >= CDP_EVENT_QUEUE_CAPACITY
            || event_bytes > cmux_tui_cdp::CDP_EVENT_QUEUE_MAX_BYTES - state.retained_bytes
        {
            fail_surface_route(&mut state, "CDP surface event queue overflow");
            self.schedule_locked(&mut state);
            return true;
        }
        state.events.push_back(QueuedSurfaceEvent { event, retained_bytes: event_bytes });
        state.retained_bytes += event_bytes;
        self.schedule_locked(&mut state);
        false
    }

    pub(super) fn close(self: &Arc<Self>, reason: String) {
        let mut state = self.state.lock().recover_poison();
        if state.closed {
            return;
        }
        fail_surface_route(&mut state, &reason);
        self.schedule_locked(&mut state);
    }

    /// Starts serving this route's events, queued ones first, with `handler`
    /// on the shared pool.
    pub(super) fn attach_handler(self: &Arc<Self>, handler: LaneHandler) -> anyhow::Result<()> {
        start_event_pool()?;
        *self.handler.lock().recover_poison() = Some(handler);
        let mut state = self.state.lock().recover_poison();
        state.has_handler = true;
        self.schedule_locked(&mut state);
        Ok(())
    }

    /// Puts the lane in the ready queue when it has a handler, an event and
    /// is not there yet. Called with the state locked, so a delivery and the
    /// serving thread's "nothing left" never both miss the lane.
    fn schedule_locked(self: &Arc<Self>, state: &mut SurfaceRouteState) {
        #[cfg(test)]
        self.changed.notify_all();
        if !state.has_handler || state.scheduled || state.ended || !state.has_runnable_event() {
            return;
        }
        // `has_handler` is set only after the pool started.
        state.scheduled = true;
        EVENT_POOL.push(self.clone());
    }

    fn pop_event(&self, state: &mut SurfaceRouteState) -> Option<CdpEvent> {
        let queued = state.events.pop_front()?;
        state.retained_bytes = state.retained_bytes.saturating_sub(queued.retained_bytes);
        Some(queued.event)
    }

    /// One pool turn: serves up to [`EVENTS_PER_TURN`] events. Returns true
    /// when the lane has more and goes back in the ready queue.
    fn serve_turn(&self) -> bool {
        let Some(mut handler) = self.handler.lock().recover_poison().take() else {
            self.state.lock().recover_poison().scheduled = false;
            return false;
        };
        for _ in 0..EVENTS_PER_TURN {
            let event = {
                let mut state = self.state.lock().recover_poison();
                let next = if state.paused {
                    // A command-worker CDP call can wait for a dialog answer.
                    // Let that detached control acknowledgment bypass the
                    // registry pause, without reordering page changes.
                    state
                        .events
                        .iter()
                        .position(|queued| is_dialog(&queued.event))
                        .and_then(|index| state.events.remove(index))
                        .map(|queued| {
                            state.retained_bytes =
                                state.retained_bytes.saturating_sub(queued.retained_bytes);
                            queued.event
                        })
                } else {
                    self.pop_event(&mut state)
                };
                match next {
                    Some(event) => event,
                    None => {
                        state.scheduled = false;
                        if state.closed && state.events.is_empty() {
                            self.end_locked(&mut state);
                            drop(state);
                            drop_handler(handler);
                        } else {
                            // Back before the state unlocks: the next
                            // delivery schedules a lane that has its handler.
                            *self.handler.lock().recover_poison() = Some(handler);
                        }
                        return false;
                    }
                }
            };
            #[cfg(test)]
            record_serving_thread();
            let flow = catch_unwind(AssertUnwindSafe(|| handler(event))).unwrap_or(LaneFlow::End);
            if flow == LaneFlow::End {
                let mut state = self.state.lock().recover_poison();
                state.scheduled = false;
                self.end_locked(&mut state);
                drop(state);
                drop_handler(handler);
                return false;
            }
        }
        let mut state = self.state.lock().recover_poison();
        *self.handler.lock().recover_poison() = Some(handler);
        if !state.has_runnable_event() {
            state.scheduled = false;
            false
        } else {
            true
        }
    }

    /// Keeps the route alive even if the runtime unregisters it while its
    /// command worker is busy. Dropping the token resumes the ordered lane.
    pub(super) fn pause(self: &Arc<Self>) -> ResumeEventLane {
        self.state.lock().recover_poison().paused = true;
        ResumeEventLane(self.clone())
    }

    fn resume(self: &Arc<Self>) {
        let mut state = self.state.lock().recover_poison();
        state.paused = false;
        self.schedule_locked(&mut state);
    }

    fn end_locked(&self, state: &mut SurfaceRouteState) {
        state.ended = true;
        state.has_handler = false;
        state.events.clear();
        state.retained_bytes = 0;
        #[cfg(test)]
        self.changed.notify_all();
    }

    #[cfg(test)]
    pub(super) fn is_closed(&self) -> bool {
        self.state.lock().recover_poison().closed
    }

    #[cfg(test)]
    pub(super) fn try_recv(&self) -> Option<CdpEvent> {
        let mut state = self.state.lock().recover_poison();
        self.pop_event(&mut state)
    }

    /// Blocks for the next event of a route no handler serves (a test reads
    /// the lane itself); `None` once it is closed and drained.
    #[cfg(test)]
    pub(super) fn recv(&self) -> Option<CdpEvent> {
        let mut state = self.state.lock().recover_poison();
        debug_assert!(!state.has_handler, "recv reads only a lane no handler serves");
        loop {
            if let Some(event) = self.pop_event(&mut state) {
                return Some(event);
            }
            if state.closed {
                return None;
            }
            state = self.changed.wait(state).recover_poison();
        }
    }

    /// Waits until the lane's handler ended (a test observes a whole lane).
    #[cfg(test)]
    pub(super) fn wait_ended(&self, timeout: std::time::Duration) -> bool {
        let state = self.state.lock().recover_poison();
        let (state, _) =
            self.changed.wait_timeout_while(state, timeout, |state| !state.ended).recover_poison();
        state.ended
    }
}

pub(super) struct ResumeEventLane(Arc<SurfaceRoute>);

impl Drop for ResumeEventLane {
    fn drop(&mut self) {
        self.0.resume();
    }
}

impl SurfaceRouteState {
    fn has_runnable_event(&self) -> bool {
        if self.paused {
            self.events.iter().any(|queued| is_dialog(&queued.event))
        } else {
            !self.events.is_empty()
        }
    }
}

fn is_dialog(event: &CdpEvent) -> bool {
    matches!(event, CdpEvent::Other { method, .. } if method == "Page.javascriptDialogOpening")
}

/// Drops an ended lane's handler (often the last owner of its surface) so a
/// panicking drop ends only that lane, never a pool thread.
fn drop_handler(handler: LaneHandler) {
    let _ = catch_unwind(AssertUnwindSafe(move || drop(handler)));
}

fn fail_surface_route(state: &mut SurfaceRouteState, reason: &str) {
    state.events.clear();
    let event = CdpEvent::Closed(reason.to_string());
    let retained_bytes = cmux_tui_cdp::event_retained_bytes(&event);
    state.retained_bytes = retained_bytes;
    state.events.push_back(QueuedSurfaceEvent { event, retained_bytes });
    state.closed = true;
}

struct EventPool {
    ready: Mutex<VecDeque<Arc<SurfaceRoute>>>,
    wake: Condvar,
}

static EVENT_POOL: EventPool =
    EventPool { ready: Mutex::new(VecDeque::new()), wake: Condvar::new() };
static EVENT_POOL_STARTED: OnceLock<Result<(), String>> = OnceLock::new();

impl EventPool {
    fn push(&self, route: Arc<SurfaceRoute>) {
        self.ready.lock().recover_poison().push_back(route);
        self.wake.notify_one();
    }

    fn run(&self) {
        loop {
            let route = {
                let mut ready = self.ready.lock().recover_poison();
                loop {
                    if let Some(route) = ready.pop_front() {
                        break route;
                    }
                    ready = self.wake.wait(ready).recover_poison();
                }
            };
            if route.serve_turn() {
                self.push(route);
            }
        }
    }
}

/// Starts the pool on first use. Its threads live as long as the process and
/// park on one condvar while no lane has events (no timers, no polling).
fn start_event_pool() -> anyhow::Result<()> {
    EVENT_POOL_STARTED
        .get_or_init(|| {
            for index in 0..EVENT_POOL_THREADS {
                std::thread::Builder::new()
                    .name(format!("browser-events-{index}"))
                    .spawn(|| EVENT_POOL.run())
                    .map_err(|error| format!("could not start browser event pool: {error}"))?;
            }
            Ok(())
        })
        .clone()
        .map_err(|error| anyhow::anyhow!(error))
}

#[cfg(test)]
static SERVING_THREADS: Mutex<Option<HashSet<String>>> = Mutex::new(None);

#[cfg(test)]
fn record_serving_thread() {
    let name = std::thread::current().name().unwrap_or("<unnamed>").to_string();
    SERVING_THREADS.lock().recover_poison().get_or_insert_with(HashSet::new).insert(name);
}

/// Names of every thread that ran a lane handler in this test process.
#[cfg(test)]
pub(super) fn serving_threads() -> HashSet<String> {
    SERVING_THREADS.lock().recover_poison().clone().unwrap_or_default()
}
