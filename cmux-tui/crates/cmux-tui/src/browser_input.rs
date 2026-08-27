//! Off-loop browser command forwarding.
//!
//! Forwarding input to a browser surface ultimately performs blocking
//! I/O: a CDP request/response on the shared WebSocket for local
//! surfaces (30s timeout, plus up to the reader's poll window to take
//! the socket lock), or a JSON request over the control socket (10s
//! timeout) for remote ones. A wedged Chrome or half-open session must
//! never freeze the TUI event loop just because the mouse moved, so
//! input events enter bounded per-surface queues scheduled fairly over a
//! fixed worker pool. One surface is never dispatched concurrently, so
//! its command order is preserved without creating an OS thread for it:
//!
//! - Consecutive mouse moves on the same surface are coalesced (latest
//!   wins) before dispatch, so a stalled endpoint never builds a replay
//!   backlog of stale hover/drag positions.
//! - Consecutive browser presentation acknowledgements also coalesce to the
//!   latest frame. Guarded pointer commands implicitly acknowledge their own
//!   frame, so dropping a redundant acknowledgement cannot strand input.
//! - A blocking request occupies one pool worker. Ready queues for other
//!   surfaces continue on the remaining workers, while total worker
//!   threads remain bounded.
//! - Global surface, event-count, and retained-byte limits cap scheduler
//!   memory even when every worker is blocked. Retiring a surface purges
//!   canceled work immediately while preserving accepted releases.
//! - When the queue is full (the worker is stuck inside a blocking
//!   call), pointer and key events are dropped instead of blocking the
//!   UI. Releases that close accepted pointer interactions are retained
//!   in a bounded fallback, and the latest rejected resize per surface
//!   and uninterrupted resize run is retained. Both fallbacks rejoin the
//!   ordinary lane in sequence order.
//!
//! Ordinary input errors are reported by the surface's own status. Resize
//! failures are retained per surface and reported to the app because retrying a
//! persistently failing CDP geometry update ahead of every input would stall the
//! browser lane. Discrete browser controls report failures separately so user
//! actions cannot disappear silently under backpressure.

use std::collections::{HashMap, HashSet, VecDeque};
use std::mem::{size_of, size_of_val};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use cmux_tui_core::SurfaceId;

use crate::session::SurfaceHandle;

/// Bounded queue depth. Input events are tiny; this is sized so bursts
/// (drag + key repeat) never drop while a healthy worker drains, but a
/// blocked worker caps queued work at a few hundred events.
const QUEUE_CAPACITY: usize = 512;
/// A fixed pool bounds OS-thread growth while retaining enough parallelism
/// that one blocked browser does not freeze all browser input.
const BROWSER_INPUT_WORKER_COUNT: usize = 8;
/// Surface lanes retain session handles, queues, and resize fallbacks. Bound
/// the live map independently from the event budget so idle surfaces cannot
/// grow scheduler state without limit.
const MAX_BROWSER_INPUT_SURFACES: usize = 256;
/// Aggregate queued work bounds all per-surface channels and scheduler-owned
/// pending queues, including surfaces waiting behind blocked workers.
const GLOBAL_QUEUE_CAPACITY: usize = 4_096;
const GLOBAL_QUEUE_MAX_BYTES: usize = 8 * 1024 * 1024;
/// Releases close already accepted presses and therefore receive a separate,
/// still-bounded reserve when ordinary global admission is saturated.
const GLOBAL_RELEASE_RESERVE_CAPACITY: usize = 2_048;
const GLOBAL_RELEASE_RESERVE_MAX_BYTES: usize = 1024 * 1024;
/// At most the ordinary queue plus its one in-flight event can contain
/// accepted presses awaiting releases while the browser worker is wedged.
const RETAINED_RELEASE_CAPACITY: usize = QUEUE_CAPACITY + 1;

pub struct BrowserInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub kind: BrowserInputKind,
}

impl BrowserInputEvent {
    fn retained_bytes(&self) -> usize {
        let dynamic = match &self.kind {
            BrowserInputKind::InsertText(text) | BrowserInputKind::Navigate(text) => {
                text.capacity()
            }
            BrowserInputKind::Resize { _claim, on_result, .. } => {
                _claim.as_ref().map_or(0, |claim| size_of_val(claim.as_ref())).saturating_add(
                    on_result.as_ref().map_or(0, |callback| size_of_val(callback.as_ref())),
                )
            }
            _ => 0,
        };
        size_of::<Self>().saturating_add(dynamic)
    }
}

#[derive(Debug, Clone)]
pub struct BrowserResizeFailure {
    pub surface_id: SurfaceId,
    pub cols: u16,
    pub rows: u16,
    pub error: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowserKey {
    Character(char),
    Named(&'static str),
}

impl BrowserKey {
    fn as_str(self, character_buffer: &mut [u8; 4]) -> &str {
        match self {
            Self::Character(character) => character.encode_utf8(character_buffer),
            Self::Named(name) => name,
        }
    }
}

pub enum BrowserInputKind {
    Presented {
        frame_seq: u64,
    },
    Mouse {
        event_type: &'static str,
        x: f64,
        y: f64,
        button: Option<&'static str>,
        click_count: Option<u32>,
        frame_seq: u64,
    },
    Wheel {
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: u64,
    },
    Key {
        event_type: &'static str,
        key: BrowserKey,
        code: &'static str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&'static str>,
    },
    KeyPress {
        key: BrowserKey,
        code: &'static str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&'static str>,
    },
    InsertText(String),
    Resize {
        cols: u16,
        rows: u16,
        reassert: bool,
        _claim: Option<Box<dyn Send>>,
        on_result: Option<Box<dyn FnOnce(Option<u64>) + Send>>,
    },
    Navigate(String),
    Back,
    Forward,
    Reload,
    Activate,
    #[cfg(test)]
    TestBlock {
        entered: std::sync::mpsc::Sender<()>,
        release: Receiver<()>,
    },
    #[cfg(test)]
    TestProbe(std::sync::mpsc::Sender<SurfaceId>),
}

struct SequencedBrowserInputEvent {
    sequence: u64,
    event: BrowserInputEvent,
    lifetime: Arc<AtomicBool>,
    retained_bytes: usize,
}

struct SurfaceEnqueueOutcome {
    accepted: bool,
    superseded: Option<SequencedBrowserInputEvent>,
}

#[derive(Default)]
struct BrowserEnqueueOrder {
    next_sequence: u64,
    /// Successfully queued non-resize input separates resize runs.
    barrier_epoch: u64,
    /// Browser presses accepted into the ordinary lane and still awaiting the
    /// matching surface/button release.
    accepted_pointer_presses: HashSet<(SurfaceId, &'static str)>,
}

#[derive(Clone, Copy)]
struct FailedBrowserResize {
    desired: (u16, u16),
    attempts: u8,
    retry_after: Option<Instant>,
}

fn next_failed_browser_resize(
    previous: Option<FailedBrowserResize>,
    desired: (u16, u16),
) -> FailedBrowserResize {
    let attempts = previous
        .filter(|failure| failure.desired == desired)
        .map_or(1, |failure| failure.attempts.saturating_add(1))
        .min(6);
    let delay_seconds = 1_u64 << u32::from(attempts.saturating_sub(1));
    FailedBrowserResize {
        desired,
        attempts,
        retry_after: (attempts < 6)
            .then(|| Instant::now() + Duration::from_secs(delay_seconds.min(30))),
    }
}

fn failed_browser_resize_blocks(failure: FailedBrowserResize, desired: (u16, u16)) -> bool {
    failure.desired == desired
        && failure.retry_after.is_none_or(|retry_after| Instant::now() < retry_after)
}

impl BrowserInputKind {
    fn is_presentation(&self) -> bool {
        matches!(self, BrowserInputKind::Presented { .. })
    }

    /// Mouse moves carry only a position; when several are queued for
    /// the same surface, only the newest matters.
    fn is_mouse_move(&self) -> bool {
        matches!(self, BrowserInputKind::Mouse { event_type: "mouseMoved", .. })
    }

    fn is_resize(&self) -> bool {
        matches!(self, BrowserInputKind::Resize { .. })
    }

    fn closes_pointer_interaction(&self) -> bool {
        matches!(self, BrowserInputKind::Mouse { event_type: "mouseReleased", .. })
    }

    fn pointer_press_button(&self) -> Option<&'static str> {
        match self {
            BrowserInputKind::Mouse {
                event_type: "mousePressed", button: Some(button), ..
            } => Some(*button),
            _ => None,
        }
    }

    fn pointer_release_button(&self) -> Option<&'static str> {
        match self {
            BrowserInputKind::Mouse {
                event_type: "mouseReleased", button: Some(button), ..
            } => Some(*button),
            _ => None,
        }
    }

    fn resize_dimensions(&self) -> Option<(u16, u16)> {
        match self {
            BrowserInputKind::Resize { cols, rows, .. } => Some((*cols, *rows)),
            _ => None,
        }
    }

    /// Discrete control actions the user explicitly invoked. Unlike disposable
    /// pointer/key input, a control command that fails to reach the browser
    /// must surface backpressure instead of vanishing.
    fn is_control(&self) -> bool {
        matches!(
            self,
            BrowserInputKind::Navigate(_)
                | BrowserInputKind::Back
                | BrowserInputKind::Forward
                | BrowserInputKind::Reload
                | BrowserInputKind::Activate
        )
    }
}

pub struct BrowserInputDispatcher {
    lanes: Mutex<HashMap<SurfaceId, Arc<ScheduledSurfaceInputLane>>>,
    scheduler: Option<Arc<BrowserInputScheduler>>,
    failed_resizes: Arc<Mutex<HashMap<SurfaceId, FailedBrowserResize>>>,
    #[cfg(test)]
    blocked_lane: Option<SurfaceInputLane>,
}

struct BrowserInputScheduler {
    ready: Mutex<ReadySurfaceLanes>,
    available: Condvar,
    admission: Mutex<BrowserInputAdmission>,
    failed_resizes: Arc<Mutex<HashMap<SurfaceId, FailedBrowserResize>>>,
    on_resize_failure: Arc<dyn Fn(BrowserResizeFailure) + Send + Sync>,
    on_control_failure: Arc<dyn Fn(String) + Send + Sync>,
}

#[derive(Default)]
struct BrowserInputAdmission {
    queued_events: usize,
    retained_bytes: usize,
}

#[derive(Default)]
struct ReadySurfaceLanes {
    lanes: VecDeque<Arc<ScheduledSurfaceInputLane>>,
    shutdown: bool,
}

struct ScheduledSurfaceInputLane {
    lane: SurfaceInputLane,
    rx: Mutex<Receiver<SequencedBrowserInputEvent>>,
    pending: Mutex<VecDeque<SequencedBrowserInputEvent>>,
    scheduled: AtomicBool,
    retired: AtomicBool,
    #[cfg(test)]
    examined_events: AtomicUsize,
}

struct SurfaceInputLane {
    expected_surface_id: Option<SurfaceId>,
    tx: SyncSender<SequencedBrowserInputEvent>,
    order: Arc<Mutex<BrowserEnqueueOrder>>,
    latest_resizes: Arc<Mutex<HashMap<(SurfaceId, u64), SequencedBrowserInputEvent>>>,
    retained_releases: Arc<Mutex<Vec<SequencedBrowserInputEvent>>>,
    surface_lifetimes: Mutex<HashMap<SurfaceId, Arc<AtomicBool>>>,
    queued_count: AtomicUsize,
}

#[cfg(test)]
pub(crate) struct BlockedBrowserInput {
    rx: Receiver<SequencedBrowserInputEvent>,
    retained_releases: Arc<Mutex<Vec<SequencedBrowserInputEvent>>>,
}

#[cfg(test)]
impl BlockedBrowserInput {
    pub(crate) fn drain_mouse_lifetimes(&self) -> Vec<(&'static str, bool)> {
        let mut pending = Vec::new();
        while let Ok(event) = self.rx.try_recv() {
            pending.push(event);
        }
        pending.append(&mut self.retained_releases.lock().unwrap());
        pending.sort_unstable_by_key(|event| event.sequence);
        let mut events = Vec::new();
        for event in pending {
            if let BrowserInputKind::Mouse { event_type, .. } = event.event.kind {
                events.push((event_type, event.lifetime.load(Ordering::Acquire)));
            }
        }
        events
    }
}

#[cfg(test)]
impl BlockedBrowserInput {
    pub(crate) fn recv_timeout(&self, timeout: Duration) -> Option<BrowserInputEvent> {
        self.rx.recv_timeout(timeout).ok().map(|event| event.event)
    }
}

impl BrowserInputDispatcher {
    pub fn spawn(
        on_resize_failure: impl Fn(BrowserResizeFailure) + Send + Sync + 'static,
        on_control_failure: impl Fn(String) + Send + Sync + 'static,
    ) -> anyhow::Result<Self> {
        let on_resize_failure = Arc::new(on_resize_failure);
        let on_control_failure = Arc::new(on_control_failure);
        let failed_resizes = Arc::new(Mutex::new(HashMap::new()));
        let scheduler = BrowserInputScheduler::spawn(
            BROWSER_INPUT_WORKER_COUNT,
            failed_resizes.clone(),
            on_resize_failure,
            on_control_failure,
        )?;
        Ok(Self {
            lanes: Mutex::new(HashMap::new()),
            scheduler: Some(scheduler),
            failed_resizes,
            #[cfg(test)]
            blocked_lane: None,
        })
    }

    #[cfg(test)]
    pub(crate) fn blocked(capacity: usize) -> (Self, BlockedBrowserInput) {
        let (lane, blocked) = SurfaceInputLane::blocked_for_any_surface(capacity);
        (
            Self {
                lanes: Mutex::new(HashMap::new()),
                scheduler: None,
                failed_resizes: Arc::new(Mutex::new(HashMap::new())),
                blocked_lane: Some(lane),
            },
            blocked,
        )
    }

    fn evict_idle_lane(lanes: &mut HashMap<SurfaceId, Arc<ScheduledSurfaceInputLane>>) -> bool {
        let idle_surface =
            lanes.iter().find_map(|(surface_id, lane)| lane.is_evictable().then_some(*surface_id));
        idle_surface.is_some_and(|surface_id| lanes.remove(&surface_id).is_some())
    }

    /// Queue an event without blocking. A full queue retains releases and
    /// the latest resize per surface and input-delimited run, and drops
    /// other input.
    #[must_use = "control commands must surface backpressure instead of dropping silently"]
    pub fn enqueue(&self, event: BrowserInputEvent) -> bool {
        if let Some(desired) = event.kind.resize_dimensions()
            && self.resize_failed(event.surface_id, desired)
        {
            return true;
        }
        #[cfg(test)]
        if let Some(lane) = &self.blocked_lane {
            return lane.enqueue(event);
        }
        let surface_id = event.surface_id;
        let is_release = event.kind.closes_pointer_interaction();
        let retained_bytes = event.retained_bytes();
        let scheduler = self.scheduler.as_ref().expect("production browser input has a scheduler");
        let (lane, outcome) = {
            let mut lanes = self.lanes.lock().unwrap();
            if is_release && !lanes.contains_key(&surface_id) {
                return false;
            }
            if !lanes.contains_key(&surface_id)
                && lanes.len() >= MAX_BROWSER_INPUT_SURFACES
                && !Self::evict_idle_lane(&mut lanes)
            {
                return false;
            }
            if !scheduler.try_reserve_event(retained_bytes, is_release) {
                return false;
            }
            let lane = lanes
                .entry(surface_id)
                .or_insert_with(|| ScheduledSurfaceInputLane::new(surface_id, QUEUE_CAPACITY))
                .clone();
            let outcome = lane.lane.enqueue_accounted(event, retained_bytes);
            (lane, outcome)
        };
        if let Some(superseded) = outcome.superseded {
            scheduler.release_event(&superseded);
        }
        if outcome.accepted {
            scheduler.schedule(lane);
        } else {
            scheduler.release_admission(retained_bytes);
        }
        outcome.accepted
    }

    pub fn resize_failed(&self, surface_id: SurfaceId, desired: (u16, u16)) -> bool {
        self.failed_resizes
            .lock()
            .unwrap()
            .get(&surface_id)
            .copied()
            .is_some_and(|failure| failed_browser_resize_blocks(failure, desired))
    }

    /// The app event loop uses this deadline as a scheduled retry wakeup, so
    /// a failed resize does not depend on unrelated user input to run again.
    pub fn resize_retry_due(&self) -> bool {
        let now = Instant::now();
        self.failed_resizes
            .lock()
            .unwrap()
            .values()
            .any(|failure| failure.retry_after.is_some_and(|retry_after| retry_after <= now))
    }

    /// Expired failures for hidden surfaces are retired. A later layout pass
    /// will enqueue the current geometry if that surface becomes visible again.
    pub fn visible_resize_retry_due(&self, visible_surfaces: &HashSet<SurfaceId>) -> bool {
        let now = Instant::now();
        let mut failures = self.failed_resizes.lock().unwrap();
        failures.retain(|surface, failure| {
            failure.retry_after.is_some_and(|retry_after| retry_after > now)
                || visible_surfaces.contains(surface)
        });
        failures
            .values()
            .any(|failure| failure.retry_after.is_some_and(|retry_after| retry_after <= now))
    }

    pub fn forget_surface(&self, surface_id: SurfaceId) {
        // Surface-exit handling removes the ID from app topology before this
        // call, so no later app input can create a fresh lifetime for it.
        #[cfg(test)]
        if let Some(lane) = &self.blocked_lane {
            let _ = lane.cancel_surface(surface_id);
            self.failed_resizes.lock().unwrap().remove(&surface_id);
            return;
        }
        let lane = self.lanes.lock().unwrap().remove(&surface_id);
        if let Some(lane) = lane {
            lane.retire(
                self.scheduler.as_ref().expect("production browser input has a scheduler"),
                surface_id,
            );
        }
        self.failed_resizes.lock().unwrap().remove(&surface_id);
    }

    pub fn clear_resize_failures(&self) {
        self.failed_resizes.lock().unwrap().clear();
    }

    #[cfg(test)]
    pub(crate) fn tracks_surface(&self, surface_id: SurfaceId) -> bool {
        if let Some(lane) = &self.blocked_lane {
            return lane.tracks_surface(surface_id)
                || self.failed_resizes.lock().unwrap().contains_key(&surface_id);
        }
        self.lanes
            .lock()
            .unwrap()
            .get(&surface_id)
            .is_some_and(|lane| lane.lane.tracks_surface(surface_id))
            || self.failed_resizes.lock().unwrap().contains_key(&surface_id)
    }

    #[cfg(test)]
    fn worker_count(&self) -> usize {
        self.scheduler.as_ref().map_or(0, |_| BROWSER_INPUT_WORKER_COUNT)
    }
}

impl Drop for BrowserInputDispatcher {
    fn drop(&mut self) {
        if let Some(scheduler) = &self.scheduler {
            scheduler.shutdown();
        }
    }
}

impl BrowserInputScheduler {
    fn spawn(
        worker_count: usize,
        failed_resizes: Arc<Mutex<HashMap<SurfaceId, FailedBrowserResize>>>,
        on_resize_failure: Arc<dyn Fn(BrowserResizeFailure) + Send + Sync>,
        on_control_failure: Arc<dyn Fn(String) + Send + Sync>,
    ) -> std::io::Result<Arc<Self>> {
        debug_assert!(worker_count > 0);
        let scheduler = Arc::new(Self {
            ready: Mutex::new(ReadySurfaceLanes::default()),
            available: Condvar::new(),
            admission: Mutex::new(BrowserInputAdmission::default()),
            failed_resizes,
            on_resize_failure,
            on_control_failure,
        });
        for worker_index in 0..worker_count {
            let worker = scheduler.clone();
            if let Err(error) = std::thread::Builder::new()
                .name(format!("mux-browser-input-{worker_index}"))
                .spawn(move || worker.run())
            {
                scheduler.shutdown();
                return Err(error);
            }
        }
        Ok(scheduler)
    }

    fn run(self: Arc<Self>) {
        while let Some(lane) = self.next_lane() {
            lane.process_one(&self);
            lane.scheduled.store(false, Ordering::Release);
            if lane.has_pending() {
                self.schedule(lane);
            }
        }
    }

    fn next_lane(&self) -> Option<Arc<ScheduledSurfaceInputLane>> {
        let mut ready = self.ready.lock().unwrap();
        loop {
            if ready.shutdown {
                return None;
            }
            if let Some(lane) = ready.lanes.pop_front() {
                return Some(lane);
            }
            ready = self.available.wait(ready).unwrap();
        }
    }

    fn schedule(&self, lane: Arc<ScheduledSurfaceInputLane>) {
        if !lane.has_pending() {
            return;
        }
        if lane
            .scheduled
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        let mut ready = self.ready.lock().unwrap();
        if ready.shutdown {
            lane.scheduled.store(false, Ordering::Release);
            return;
        }
        ready.lanes.push_back(lane);
        drop(ready);
        self.available.notify_one();
    }

    fn remove_ready(&self, lane: &Arc<ScheduledSurfaceInputLane>) -> bool {
        let mut ready = self.ready.lock().unwrap();
        let previous_len = ready.lanes.len();
        ready.lanes.retain(|queued| !Arc::ptr_eq(queued, lane));
        let removed = ready.lanes.len() != previous_len;
        if removed {
            lane.scheduled.store(false, Ordering::Release);
        }
        removed
    }

    fn try_reserve_event(&self, retained_bytes: usize, is_release: bool) -> bool {
        let event_limit =
            GLOBAL_QUEUE_CAPACITY + usize::from(is_release) * GLOBAL_RELEASE_RESERVE_CAPACITY;
        let byte_limit =
            GLOBAL_QUEUE_MAX_BYTES + usize::from(is_release) * GLOBAL_RELEASE_RESERVE_MAX_BYTES;
        let mut admission = self.admission.lock().unwrap();
        let next_events = admission.queued_events.saturating_add(1);
        let next_bytes = admission.retained_bytes.saturating_add(retained_bytes);
        if next_events > event_limit || next_bytes > byte_limit {
            return false;
        }
        admission.queued_events = next_events;
        admission.retained_bytes = next_bytes;
        true
    }

    fn release_event(&self, event: &SequencedBrowserInputEvent) {
        self.release_admission(event.retained_bytes);
    }

    fn release_admission(&self, retained_bytes: usize) {
        let mut admission = self.admission.lock().unwrap();
        debug_assert!(admission.queued_events > 0);
        debug_assert!(admission.retained_bytes >= retained_bytes);
        admission.queued_events = admission.queued_events.saturating_sub(1);
        admission.retained_bytes = admission.retained_bytes.saturating_sub(retained_bytes);
    }

    fn shutdown(&self) {
        let mut ready = self.ready.lock().unwrap();
        ready.shutdown = true;
        drop(ready);
        self.available.notify_all();
    }
}

impl ScheduledSurfaceInputLane {
    fn new(surface_id: SurfaceId, capacity: usize) -> Arc<Self> {
        let (lane, rx) = SurfaceInputLane::channel(Some(surface_id), capacity);
        Arc::new(Self {
            lane,
            rx: Mutex::new(rx),
            pending: Mutex::new(VecDeque::new()),
            scheduled: AtomicBool::new(false),
            retired: AtomicBool::new(false),
            #[cfg(test)]
            examined_events: AtomicUsize::new(0),
        })
    }

    fn process_one(&self, scheduler: &BrowserInputScheduler) {
        let (event, discarded) = self.take_next();
        for discarded in discarded {
            scheduler.release_event(&discarded);
        }
        let Some(event) = event else {
            return;
        };
        let mut event = event;
        if !event.lifetime.load(Ordering::Acquire) {
            dispatch_surface_event(
                &mut event,
                &scheduler.failed_resizes,
                scheduler.on_resize_failure.as_ref(),
                scheduler.on_control_failure.as_ref(),
            );
        }
        scheduler.release_event(&event);
    }

    fn has_pending(&self) -> bool {
        self.lane.queued_count.load(Ordering::Acquire) > 0
    }

    fn is_evictable(&self) -> bool {
        if self.scheduled.load(Ordering::Acquire) || self.has_pending() {
            return false;
        }
        self.lane.order.lock().unwrap().accepted_pointer_presses.is_empty()
    }

    fn retire(self: &Arc<Self>, scheduler: &BrowserInputScheduler, surface_id: SurfaceId) {
        self.retired.store(true, Ordering::Release);
        let canceled_fallbacks = self.lane.cancel_surface(surface_id);
        for event in canceled_fallbacks {
            scheduler.release_event(&event);
        }
        scheduler.remove_ready(self);
        let discarded = self.purge_canceled();
        for event in discarded {
            scheduler.release_event(&event);
        }
        if self.has_pending() {
            scheduler.schedule(self.clone());
        }
    }

    fn take_next(&self) -> (Option<SequencedBrowserInputEvent>, Vec<SequencedBrowserInputEvent>) {
        let order = self.lane.order.lock().unwrap();
        let mut pending = self.pending.lock().unwrap();
        let rx = self.rx.lock().unwrap();
        let mut incoming = Vec::new();
        while let Ok(event) = rx.try_recv() {
            incoming.push(event);
        }
        let latest = std::mem::take(&mut *self.lane.latest_resizes.lock().unwrap());
        let releases = std::mem::take(&mut *self.lane.retained_releases.lock().unwrap());
        merge_fallback_events(&mut incoming, latest, releases);
        #[cfg(test)]
        self.examined_events.fetch_add(incoming.len(), Ordering::Relaxed);
        let discarded = append_sequenced_browser_events(&mut pending, incoming);
        let event = pending.pop_front();
        let removed = discarded.len() + usize::from(event.is_some());
        self.lane.remove_queued_events(removed);
        drop(rx);
        drop(pending);
        drop(order);
        (event, discarded)
    }

    fn purge_canceled(&self) -> Vec<SequencedBrowserInputEvent> {
        debug_assert!(self.retired.load(Ordering::Acquire));
        let order = self.lane.order.lock().unwrap();
        let mut pending = self.pending.lock().unwrap();
        let rx = self.rx.lock().unwrap();
        let mut batch = pending.drain(..).collect::<Vec<_>>();
        while let Ok(event) = rx.try_recv() {
            batch.push(event);
        }
        let latest = std::mem::take(&mut *self.lane.latest_resizes.lock().unwrap());
        let releases = std::mem::take(&mut *self.lane.retained_releases.lock().unwrap());
        merge_fallback_events(&mut batch, latest, releases);
        let mut discarded = Vec::new();
        for event in batch {
            if event.lifetime.load(Ordering::Acquire) {
                discarded.push(event);
            } else {
                pending.push_back(event);
            }
        }
        self.lane.remove_queued_events(discarded.len());
        drop(rx);
        drop(pending);
        drop(order);
        discarded
    }
}

impl SurfaceInputLane {
    fn channel(
        expected_surface_id: Option<SurfaceId>,
        capacity: usize,
    ) -> (Self, Receiver<SequencedBrowserInputEvent>) {
        let (tx, rx) = sync_channel(capacity);
        let retained_releases = Arc::new(Mutex::new(Vec::new()));
        (
            Self {
                expected_surface_id,
                tx,
                order: Arc::new(Mutex::new(BrowserEnqueueOrder::default())),
                latest_resizes: Arc::new(Mutex::new(HashMap::new())),
                retained_releases,
                surface_lifetimes: Mutex::new(HashMap::new()),
                queued_count: AtomicUsize::new(0),
            },
            rx,
        )
    }

    #[cfg(test)]
    fn blocked(surface_id: SurfaceId, capacity: usize) -> (Self, BlockedBrowserInput) {
        Self::blocked_with_expected_surface(Some(surface_id), capacity)
    }

    #[cfg(test)]
    fn blocked_for_any_surface(capacity: usize) -> (Self, BlockedBrowserInput) {
        Self::blocked_with_expected_surface(None, capacity)
    }

    #[cfg(test)]
    fn blocked_with_expected_surface(
        expected_surface_id: Option<SurfaceId>,
        capacity: usize,
    ) -> (Self, BlockedBrowserInput) {
        let (lane, rx) = Self::channel(expected_surface_id, capacity);
        let retained_releases = lane.retained_releases.clone();
        (lane, BlockedBrowserInput { rx, retained_releases })
    }

    #[cfg(test)]
    fn enqueue(&self, event: BrowserInputEvent) -> bool {
        let retained_bytes = event.retained_bytes();
        self.enqueue_accounted(event, retained_bytes).accepted
    }

    fn enqueue_accounted(
        &self,
        event: BrowserInputEvent,
        retained_bytes: usize,
    ) -> SurfaceEnqueueOutcome {
        if let Some(expected_surface_id) = self.expected_surface_id {
            debug_assert_eq!(event.surface_id, expected_surface_id);
        }
        let is_resize = event.kind.is_resize();
        let is_release = event.kind.closes_pointer_interaction();
        let press = event.kind.pointer_press_button().map(|button| (event.surface_id, button));
        let release = event.kind.pointer_release_button().map(|button| (event.surface_id, button));
        let mut order = self.order.lock().unwrap();
        if is_release {
            let Some(release) = release else {
                return SurfaceEnqueueOutcome { accepted: false, superseded: None };
            };
            // This set governs producer admission only. The core browser
            // worker retains the runtime capture until CDP confirms release,
            // and schedules one bounded retry after an ambiguous timeout.
            if !order.accepted_pointer_presses.remove(&release) {
                return SurfaceEnqueueOutcome { accepted: false, superseded: None };
            }
        }
        let lifetime = if is_release {
            // A release terminates state established by an earlier press. It
            // must reach the retained surface handle even when retiring the
            // surface cancels ordinary queued input from that lifetime.
            Arc::new(AtomicBool::new(false))
        } else {
            self.surface_lifetimes
                .lock()
                .unwrap()
                .entry(event.surface_id)
                .or_insert_with(|| Arc::new(AtomicBool::new(false)))
                .clone()
        };
        let sequence = order.next_sequence;
        order.next_sequence = order.next_sequence.saturating_add(1);
        let event = SequencedBrowserInputEvent { sequence, event, lifetime, retained_bytes };
        let (accepted, superseded) = match self.tx.try_send(event) {
            Ok(()) if !is_resize => {
                if let Some(press) = press {
                    order.accepted_pointer_presses.insert(press);
                }
                order.barrier_epoch = order.barrier_epoch.saturating_add(1);
                (true, None)
            }
            Err(TrySendError::Full(event)) if is_resize => {
                let superseded = self
                    .latest_resizes
                    .lock()
                    .unwrap()
                    .insert((event.event.surface_id, order.barrier_epoch), event);
                (true, superseded)
            }
            Err(TrySendError::Full(event)) if is_release => {
                let mut releases = self.retained_releases.lock().unwrap();
                if releases.len() >= RETAINED_RELEASE_CAPACITY {
                    return SurfaceEnqueueOutcome { accepted: false, superseded: None };
                }
                releases.push(event);
                order.barrier_epoch = order.barrier_epoch.saturating_add(1);
                (true, None)
            }
            Ok(()) => (true, None),
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => (false, None),
        };
        if accepted {
            self.queued_count.fetch_add(1, Ordering::Release);
        }
        if superseded.is_some() {
            self.remove_queued_events(1);
        }
        SurfaceEnqueueOutcome { accepted, superseded }
    }

    fn cancel_surface(&self, surface_id: SurfaceId) -> Vec<SequencedBrowserInputEvent> {
        let mut order = self.order.lock().unwrap();
        order.accepted_pointer_presses.retain(|(surface, _)| *surface != surface_id);
        if let Some(lifetime) = self.surface_lifetimes.lock().unwrap().remove(&surface_id) {
            lifetime.store(true, Ordering::Release);
        }
        let mut latest_resizes = self.latest_resizes.lock().unwrap();
        let keys = latest_resizes
            .keys()
            .filter(|(surface, _)| *surface == surface_id)
            .copied()
            .collect::<Vec<_>>();
        let canceled =
            keys.into_iter().filter_map(|key| latest_resizes.remove(&key)).collect::<Vec<_>>();
        self.remove_queued_events(canceled.len());
        drop(latest_resizes);
        drop(order);
        canceled
    }

    fn remove_queued_events(&self, count: usize) {
        if count == 0 {
            return;
        }
        let previous = self.queued_count.fetch_sub(count, Ordering::AcqRel);
        debug_assert!(previous >= count, "browser input queued-count accounting underflow");
    }

    #[cfg(test)]
    fn tracks_surface(&self, surface_id: SurfaceId) -> bool {
        self.surface_lifetimes.lock().unwrap().contains_key(&surface_id)
            || self.latest_resizes.lock().unwrap().keys().any(|(surface, _)| *surface == surface_id)
    }
}

fn dispatch_surface_event(
    event: &mut SequencedBrowserInputEvent,
    failed_resizes: &Mutex<HashMap<SurfaceId, FailedBrowserResize>>,
    on_resize_failure: &(dyn Fn(BrowserResizeFailure) + Send + Sync),
    on_control_failure: &(dyn Fn(String) + Send + Sync),
) {
    let desired = event.event.kind.resize_dimensions();
    if desired.is_some_and(|desired| {
        failed_resizes
            .lock()
            .unwrap()
            .get(&event.event.surface_id)
            .copied()
            .is_some_and(|failure| failed_browser_resize_blocks(failure, desired))
    }) {
        return;
    }
    let result = match &mut event.event.kind {
        BrowserInputKind::Resize { cols, rows, reassert, on_result, .. } => {
            let report = on_result.take().unwrap_or_else(|| Box::new(|_| {}));
            event.event.surface.resize_reporting_acceptance(*cols, *rows, *reassert, report)
        }
        _ => dispatch(&event.event),
    };
    let Some((cols, rows)) = desired else {
        if event.event.kind.is_control()
            && let Err(error) = result
        {
            on_control_failure(format!("browser command failed: {error}"));
        }
        return;
    };
    if event.lifetime.load(Ordering::Acquire) {
        return;
    }
    match result {
        Ok(_) => {
            failed_resizes.lock().unwrap().remove(&event.event.surface_id);
        }
        Err(error) => {
            let desired = (cols, rows);
            let mut failures = failed_resizes.lock().unwrap();
            let failure =
                next_failed_browser_resize(failures.get(&event.event.surface_id).copied(), desired);
            failures.insert(event.event.surface_id, failure);
            drop(failures);
            on_resize_failure(BrowserResizeFailure {
                surface_id: event.event.surface_id,
                cols,
                rows,
                error: error.to_string(),
            });
        }
    }
}

#[cfg(test)]
fn finish_ordered_batch(
    rx: &Receiver<SequencedBrowserInputEvent>,
    order: &Mutex<BrowserEnqueueOrder>,
    latest_resizes: &Mutex<HashMap<(SurfaceId, u64), SequencedBrowserInputEvent>>,
    retained_releases: &Mutex<Vec<SequencedBrowserInputEvent>>,
    batch: &mut Vec<SequencedBrowserInputEvent>,
) {
    // Block new sequence assignments while establishing the batch cut.
    // Every earlier accepted event is drained before fallbacks are collected.
    let order_guard = order.lock().unwrap();
    while let Ok(next) = rx.try_recv() {
        batch.push(next);
    }
    let latest = std::mem::take(&mut *latest_resizes.lock().unwrap());
    let releases = std::mem::take(&mut *retained_releases.lock().unwrap());
    drop(order_guard);
    merge_fallback_events(batch, latest, releases);
}

fn merge_fallback_events(
    batch: &mut Vec<SequencedBrowserInputEvent>,
    latest: HashMap<(SurfaceId, u64), SequencedBrowserInputEvent>,
    releases: Vec<SequencedBrowserInputEvent>,
) {
    batch.extend(latest.into_values());
    batch.extend(releases);
    // A fallback may race with a later successful channel send. Restore
    // their common enqueue order before applying adjacency coalescing.
    batch.sort_unstable_by_key(|event| event.sequence);
}

/// Drop a mouse move when the next event is also a mouse move on the
/// same surface: only the final position of a consecutive run is
/// forwarded. Clicks, keys, and wheel events keep their order.
#[cfg(test)]
fn coalesce_browser_events(batch: &mut Vec<BrowserInputEvent>) {
    let mut index = 0;
    while index + 1 < batch.len() {
        let same_coalescing_kind = (batch[index].kind.is_mouse_move()
            && batch[index + 1].kind.is_mouse_move())
            || (batch[index].kind.is_presentation() && batch[index + 1].kind.is_presentation())
            || (batch[index].kind.is_resize() && batch[index + 1].kind.is_resize());
        let drop_current =
            same_coalescing_kind && batch[index].surface_id == batch[index + 1].surface_id;
        if drop_current {
            batch.remove(index);
        } else {
            index += 1;
        }
    }
}

fn append_sequenced_browser_events(
    pending: &mut VecDeque<SequencedBrowserInputEvent>,
    incoming: Vec<SequencedBrowserInputEvent>,
) -> Vec<SequencedBrowserInputEvent> {
    debug_assert!(
        pending
            .back()
            .zip(incoming.first())
            .is_none_or(|(previous, next)| previous.sequence <= next.sequence)
    );
    let mut discarded = Vec::new();
    for event in incoming {
        if event.lifetime.load(Ordering::Acquire) {
            discarded.push(event);
            continue;
        }
        let coalesces_with_previous = pending.back().is_some_and(|previous| {
            let current = &previous.event;
            let next = &event.event;
            let same_coalescing_kind = (current.kind.is_mouse_move() && next.kind.is_mouse_move())
                || (current.kind.is_presentation() && next.kind.is_presentation())
                || (current.kind.is_resize() && next.kind.is_resize());
            same_coalescing_kind && current.surface_id == next.surface_id
        });
        if coalesces_with_previous {
            discarded.push(pending.pop_back().expect("pending event exists"));
        }
        pending.push_back(event);
    }
    discarded
}

fn dispatch(event: &BrowserInputEvent) -> anyhow::Result<bool> {
    let surface = &event.surface;
    match &event.kind {
        BrowserInputKind::Presented { frame_seq } => {
            surface.browser_publish_pointer_frame(*frame_seq).map(|()| true)
        }
        BrowserInputKind::Mouse { event_type, x, y, button, click_count, frame_seq } => surface
            .browser_mouse_event_for_frame(
                event_type,
                *x,
                *y,
                *button,
                *click_count,
                Some(*frame_seq),
            )
            .map(|()| true),
        BrowserInputKind::Wheel { x, y, delta_y, frame_seq } => {
            surface.browser_wheel_for_frame(*x, *y, *delta_y, Some(*frame_seq)).map(|()| true)
        }
        BrowserInputKind::Key {
            event_type,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        } => {
            let mut character_buffer = [0; 4];
            surface
                .browser_key_event(
                    event_type,
                    (*key).as_str(&mut character_buffer),
                    code,
                    *windows_virtual_key_code,
                    *modifiers,
                    *text,
                )
                .map(|()| true)
        }
        BrowserInputKind::KeyPress { key, code, windows_virtual_key_code, modifiers, text } => {
            let mut character_buffer = [0; 4];
            surface
                .browser_key_press(
                    (*key).as_str(&mut character_buffer),
                    code,
                    *windows_virtual_key_code,
                    *modifiers,
                    *text,
                )
                .map(|()| true)
        }
        BrowserInputKind::InsertText(text) => surface.browser_insert_text(text).map(|()| true),
        BrowserInputKind::Resize { cols, rows, reassert, .. } => {
            if *reassert {
                surface.reassert_size(*cols, *rows)
            } else {
                surface.resize(*cols, *rows)
            }
        }
        BrowserInputKind::Navigate(url) => surface.browser_navigate(url).map(|()| true),
        BrowserInputKind::Back => surface.browser_back().map(|()| true),
        BrowserInputKind::Forward => surface.browser_forward().map(|()| true),
        BrowserInputKind::Reload => surface.browser_reload().map(|()| true),
        BrowserInputKind::Activate => surface.browser_activate().map(|()| true),
        #[cfg(test)]
        BrowserInputKind::TestBlock { entered, release } => {
            let _ = entered.send(());
            let _ = release.recv();
            Ok(true)
        }
        #[cfg(test)]
        BrowserInputKind::TestProbe(observed) => {
            let _ = observed.send(event.surface_id);
            Ok(true)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct DropProbe(Arc<AtomicBool>);

    impl Drop for DropProbe {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Release);
        }
    }

    fn move_event(surface: SurfaceId, x: f64) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Mouse {
                event_type: "mouseMoved",
                x,
                y: 0.0,
                button: Some("none"),
                click_count: None,
                frame_seq: 1,
            },
        }
    }

    fn presentation_event(surface: SurfaceId, frame_seq: u64) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Presented { frame_seq },
        }
    }

    fn click_event(surface: SurfaceId) -> BrowserInputEvent {
        click_event_with_button(surface, "left")
    }

    fn click_event_with_button(surface: SurfaceId, button: &'static str) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Mouse {
                event_type: "mousePressed",
                x: 0.0,
                y: 0.0,
                button: Some(button),
                click_count: Some(1),
                frame_seq: 1,
            },
        }
    }

    fn release_event(surface: SurfaceId) -> BrowserInputEvent {
        release_event_with_button(surface, "left")
    }

    fn release_event_with_button(surface: SurfaceId, button: &'static str) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Mouse {
                event_type: "mouseReleased",
                x: 0.0,
                y: 0.0,
                button: Some(button),
                click_count: Some(1),
                frame_seq: 1,
            },
        }
    }

    fn resize_event(surface: SurfaceId, cols: u16) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Resize {
                cols,
                rows: 24,
                reassert: false,
                _claim: None,
                on_result: None,
            },
        }
    }

    fn resize_event_with_probe(
        surface: SurfaceId,
        cols: u16,
        dropped: Arc<AtomicBool>,
    ) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Resize {
                cols,
                rows: 24,
                reassert: false,
                _claim: Some(Box::new(DropProbe(dropped))),
                on_result: None,
            },
        }
    }

    fn sequenced(sequence: u64, event: BrowserInputEvent) -> SequencedBrowserInputEvent {
        let retained_bytes = event.retained_bytes();
        SequencedBrowserInputEvent {
            sequence,
            event,
            lifetime: Arc::new(AtomicBool::new(false)),
            retained_bytes,
        }
    }

    fn reload_event(surface: SurfaceId) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Reload,
        }
    }

    fn key_press_event(surface: SurfaceId) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::KeyPress {
                key: BrowserKey::Character('j'),
                code: "KeyJ",
                windows_virtual_key_code: 74,
                modifiers: 1,
                text: None,
            },
        }
    }

    // Regression: a full dispatcher queue (worker wedged inside a blocking
    // browser call) must report the drop so control commands can surface
    // backpressure to the user, instead of the old `let _ = try_send` that
    // swallowed the failure and made a dropped reload/navigate look accepted.
    #[test]
    fn full_queue_reports_drop_instead_of_swallowing_it() {
        let (lane, _blocked) = SurfaceInputLane::blocked(1, QUEUE_CAPACITY);
        for _ in 0..QUEUE_CAPACITY {
            assert!(lane.enqueue(reload_event(1)), "queue should accept until full");
        }
        assert!(
            !lane.enqueue(reload_event(1)),
            "a full queue must report the drop, not swallow it as accepted"
        );
    }

    #[test]
    fn full_queue_retains_the_release_after_its_accepted_press() {
        let (lane, blocked) = SurfaceInputLane::blocked(7, 1);
        assert!(lane.enqueue(click_event(7)));
        assert!(
            lane.enqueue(release_event(7)),
            "a saturated ordinary lane must retain the release that closes its accepted press"
        );
        assert_eq!(
            blocked.drain_mouse_lifetimes(),
            vec![("mousePressed", false), ("mouseReleased", false)],
            "the retained release must keep its enqueue order behind the accepted press"
        );
    }

    #[test]
    fn full_queue_retains_only_a_matching_accepted_press_release() {
        let (lane, blocked) = SurfaceInputLane::blocked(7, 1);
        assert!(lane.enqueue(click_event(7)));
        assert!(
            !lane.enqueue(click_event_with_button(7, "right")),
            "the saturated ordinary lane must reject a second press"
        );
        assert!(
            !lane.enqueue(release_event_with_button(7, "right")),
            "a release for the dropped press must not enter the fallback lane"
        );
        assert!(
            lane.enqueue(release_event(7)),
            "the release matching the accepted press must retain its reserved fallback"
        );
        assert_eq!(
            blocked.drain_mouse_lifetimes(),
            vec![("mousePressed", false), ("mouseReleased", false)],
            "unmatched releases must leave no fallback backlog"
        );
    }

    #[test]
    fn release_requires_and_consumes_an_accepted_press() {
        let (lane, blocked) = SurfaceInputLane::blocked(7, 1);
        assert!(
            !lane.enqueue(release_event(7)),
            "an unmatched release must not enter an available ordinary lane"
        );
        assert!(blocked.drain_mouse_lifetimes().is_empty());

        assert!(lane.enqueue(click_event(7)));
        assert_eq!(blocked.drain_mouse_lifetimes(), vec![("mousePressed", false)]);
        assert!(lane.enqueue(release_event(7)));
        assert!(
            !lane.enqueue(release_event(7)),
            "one accepted release must consume pointer ownership exactly once"
        );
        assert_eq!(blocked.drain_mouse_lifetimes(), vec![("mouseReleased", false)]);
    }

    // Regression: a discrete control command that fails inside the worker
    // (here: RemoteBrowserUnsupported bails) must report a status event so the
    // user learns it did not take effect, instead of the old `let _ = ...` that
    // swallowed the inner result even after the outer queue accepted it.
    // Disposable input must not report.
    #[test]
    fn failed_control_command_reports_status_but_input_does_not() {
        let (tx, rx) = sync_channel(1);
        let dispatcher = BrowserInputDispatcher::spawn(
            |_| {},
            move |message| {
                let _ = tx.send(message);
            },
        )
        .unwrap();

        assert!(dispatcher.enqueue(reload_event(1)));
        let message = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(message, "browser panes are not supported over attach yet");

        // Disposable input never reports, so the worker stays quiet for it.
        assert!(dispatcher.enqueue(move_event(1, 1.0)));
        assert!(
            rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "disposable input must not emit status feedback"
        );
    }

    #[test]
    fn blocked_surface_does_not_stall_an_unrelated_surface() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (observed_tx, observed_rx) = std::sync::mpsc::channel();

        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id: 1,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestBlock { entered: entered_tx, release: release_rx },
        }));
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id: 1,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx.clone()),
        }));
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id: 2,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx),
        }));

        assert_eq!(
            observed_rx.recv_timeout(Duration::from_millis(250)),
            Ok(2),
            "one blocked surface stalled input for an unrelated surface"
        );
        assert!(
            observed_rx.try_recv().is_err(),
            "the blocked surface lost its own command ordering"
        );
        release_tx.send(()).unwrap();
        assert_eq!(observed_rx.recv_timeout(Duration::from_secs(1)), Ok(1));
    }

    #[test]
    fn blocked_surface_does_not_stall_an_unrelated_surface_with_the_same_legacy_shard() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (observed_tx, observed_rx) = std::sync::mpsc::channel();

        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id: 1,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestBlock { entered: entered_tx, release: release_rx },
        }));
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id: 1,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx.clone()),
        }));
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id: 9,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx),
        }));

        assert_eq!(
            observed_rx.recv_timeout(Duration::from_millis(250)),
            Ok(9),
            "a blocked surface stalled an unrelated surface assigned to the same worker"
        );
        assert!(
            observed_rx.try_recv().is_err(),
            "the blocked surface lost its own command ordering"
        );
        release_tx.send(()).unwrap();
        assert_eq!(observed_rx.recv_timeout(Duration::from_secs(1)), Ok(1));
    }

    fn block_all_browser_input_workers(
        dispatcher: &BrowserInputDispatcher,
    ) -> Vec<std::sync::mpsc::Sender<()>> {
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let mut releases = Vec::new();
        for surface_id in 1..=BROWSER_INPUT_WORKER_COUNT as u64 {
            let (release_tx, release_rx) = std::sync::mpsc::channel();
            assert!(dispatcher.enqueue(BrowserInputEvent {
                surface_id,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::TestBlock {
                    entered: entered_tx.clone(),
                    release: release_rx,
                },
            }));
            releases.push(release_tx);
        }
        for _ in 0..BROWSER_INPUT_WORKER_COUNT {
            entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        releases
    }

    #[test]
    fn scheduler_turn_dispatches_at_most_one_blocking_request() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let (first_entered_tx, first_entered_rx) = std::sync::mpsc::channel();
        let (second_entered_tx, _second_entered_rx) = std::sync::mpsc::channel();
        let mut first_releases = Vec::new();
        let mut second_releases = Vec::new();

        for surface_id in 1..=BROWSER_INPUT_WORKER_COUNT as u64 {
            let (first_release_tx, first_release_rx) = std::sync::mpsc::channel();
            let (second_release_tx, second_release_rx) = std::sync::mpsc::channel();
            assert!(dispatcher.enqueue(BrowserInputEvent {
                surface_id,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::TestBlock {
                    entered: first_entered_tx.clone(),
                    release: first_release_rx,
                },
            }));
            assert!(dispatcher.enqueue(BrowserInputEvent {
                surface_id,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::TestBlock {
                    entered: second_entered_tx.clone(),
                    release: second_release_rx,
                },
            }));
            first_releases.push(first_release_tx);
            second_releases.push(second_release_tx);
        }
        for _ in 0..BROWSER_INPUT_WORKER_COUNT {
            first_entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }

        let (observed_tx, observed_rx) = std::sync::mpsc::channel();
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id: 99,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx),
        }));
        first_releases[0].send(()).unwrap();

        assert_eq!(
            observed_rx.recv_timeout(Duration::from_millis(250)),
            Ok(99),
            "one surface dispatched a second blocking request before yielding its worker"
        );

        for release in first_releases.into_iter().skip(1).chain(second_releases) {
            let _ = release.send(());
        }
    }

    #[test]
    fn scheduler_bounds_aggregate_surface_admission() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let releases = block_all_browser_input_workers(&dispatcher);
        let (observed_tx, _observed_rx) = std::sync::mpsc::channel();
        let mut accepted = 0;

        for surface_id in 1_000..1_300 {
            accepted += usize::from(dispatcher.enqueue(BrowserInputEvent {
                surface_id,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::TestProbe(observed_tx.clone()),
            }));
        }

        assert!(
            accepted < 300,
            "blocked workers admitted an unbounded set of retained per-surface queues"
        );
        for release in releases {
            let _ = release.send(());
        }
    }

    #[test]
    fn synthetic_key_press_uses_one_global_admission() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let releases = block_all_browser_input_workers(&dispatcher);
        let (observed_tx, _observed_rx) = std::sync::mpsc::channel();
        for index in BROWSER_INPUT_WORKER_COUNT..GLOBAL_QUEUE_CAPACITY - 1 {
            let surface_id = index as u64 % BROWSER_INPUT_WORKER_COUNT as u64 + 1;
            assert!(dispatcher.enqueue(BrowserInputEvent {
                surface_id,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::TestProbe(observed_tx.clone()),
            }));
        }
        let lane = dispatcher.lanes.lock().unwrap().get(&1).unwrap().clone();
        let queued_before = lane.lane.queued_count.load(Ordering::Acquire);

        assert!(
            dispatcher.enqueue(key_press_event(1)),
            "one synthesized key press did not fit the scheduler's last event slot"
        );
        assert_eq!(
            lane.lane.queued_count.load(Ordering::Acquire),
            queued_before + 1,
            "one synthesized key press consumed multiple global admissions"
        );
        assert!(
            !dispatcher.enqueue(reload_event(1)),
            "the single key-press command did not consume the last global slot"
        );
        for release in releases {
            let _ = release.send(());
        }
    }

    #[test]
    fn synthetic_key_press_respects_the_surface_lane_capacity() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let releases = block_all_browser_input_workers(&dispatcher);

        for _ in 0..QUEUE_CAPACITY {
            assert!(
                dispatcher.enqueue(key_press_event(1)),
                "a surface lane rejected a key press before reaching its capacity"
            );
        }
        assert!(
            !dispatcher.enqueue(key_press_event(1)),
            "one stalled surface bypassed its lane capacity with synthesized key presses"
        );
        for release in releases {
            let _ = release.send(());
        }
    }

    #[test]
    fn idle_surface_lanes_do_not_exhaust_scheduler_admission() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let (observed_tx, observed_rx) = std::sync::mpsc::channel();

        for surface_id in 1..=MAX_BROWSER_INPUT_SURFACES as u64 {
            assert!(dispatcher.enqueue(BrowserInputEvent {
                surface_id,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::TestProbe(observed_tx.clone()),
            }));
        }
        for _ in 0..MAX_BROWSER_INPUT_SURFACES {
            observed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        let idle_deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < idle_deadline
            && dispatcher
                .lanes
                .lock()
                .unwrap()
                .values()
                .any(|lane| lane.scheduled.load(Ordering::Acquire) || lane.has_pending())
        {
            std::thread::yield_now();
        }

        let next_surface = MAX_BROWSER_INPUT_SURFACES as u64 + 1;
        assert!(
            dispatcher.enqueue(BrowserInputEvent {
                surface_id: next_surface,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::TestProbe(observed_tx),
            }),
            "drained lanes permanently disabled input for a later live browser surface"
        );
        assert_eq!(
            observed_rx.recv_timeout(Duration::from_secs(1)),
            Ok(next_surface),
            "the later browser surface was admitted but never dispatched"
        );
        assert!(
            dispatcher.lanes.lock().unwrap().len() <= MAX_BROWSER_INPUT_SURFACES,
            "evicting an idle lane exceeded the scheduler's surface-state bound"
        );
    }

    #[test]
    fn scheduler_examines_each_backlog_event_once() {
        const BACKLOG: usize = 128;
        let lane = ScheduledSurfaceInputLane::new(7, BACKLOG);
        for _ in 0..BACKLOG {
            assert!(lane.lane.enqueue(reload_event(7)));
        }

        for _ in 0..BACKLOG {
            let (event, discarded) = lane.take_next();
            assert!(event.is_some());
            assert!(discarded.is_empty());
        }

        assert_eq!(lane.lane.queued_count.load(Ordering::Acquire), 0);
        assert!(
            lane.examined_events.load(Ordering::Relaxed) <= BACKLOG * 2,
            "dispatch repeatedly rescanned the retained backlog"
        );
    }

    #[test]
    fn scheduler_rejects_an_event_over_the_global_byte_budget() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();

        assert!(
            !dispatcher.enqueue(BrowserInputEvent {
                surface_id: 99,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::InsertText("x".repeat(GLOBAL_QUEUE_MAX_BYTES + 1)),
            }),
            "one oversized event bypassed the scheduler's retained-byte bound"
        );
        assert!(
            dispatcher.lanes.lock().unwrap().is_empty(),
            "a rejected oversized event left an empty retained surface lane"
        );
    }

    #[test]
    fn forgetting_a_ready_surface_purges_its_retained_lane() {
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let releases = block_all_browser_input_workers(&dispatcher);
        let dropped = Arc::new(AtomicBool::new(false));
        assert!(dispatcher.enqueue(resize_event_with_probe(99, 80, dropped.clone())));

        dispatcher.forget_surface(99);

        assert!(
            dropped.load(Ordering::Acquire),
            "forgetting a ready surface retained its canceled queued event"
        );
        assert!(
            !dispatcher
                .scheduler
                .as_ref()
                .unwrap()
                .ready
                .lock()
                .unwrap()
                .lanes
                .iter()
                .any(|lane| lane.lane.expected_surface_id == Some(99)),
            "forgetting a ready surface left its lane in the global scheduler"
        );
        assert_eq!(
            dispatcher.scheduler.as_ref().unwrap().admission.lock().unwrap().queued_events,
            BROWSER_INPUT_WORKER_COUNT,
            "purging the retired lane did not release its global event admission"
        );
        for release in releases {
            let _ = release.send(());
        }
    }

    #[test]
    fn many_surfaces_use_a_bounded_worker_count() {
        const MAX_BROWSER_INPUT_WORKERS: usize = 8;
        let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
        let (observed_tx, observed_rx) = std::sync::mpsc::channel();

        for surface_id in 1..=32 {
            assert!(dispatcher.enqueue(BrowserInputEvent {
                surface_id,
                surface: SurfaceHandle::RemoteBrowserUnsupported,
                kind: BrowserInputKind::TestProbe(observed_tx.clone()),
            }));
        }
        for _ in 1..=32 {
            observed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }

        assert!(
            dispatcher.worker_count() <= MAX_BROWSER_INPUT_WORKERS,
            "visiting browser surfaces must not create an unbounded OS-thread-per-surface pool"
        );
    }

    fn positions(batch: &[BrowserInputEvent]) -> Vec<(&'static str, SurfaceId)> {
        batch
            .iter()
            .map(|event| match event.kind {
                BrowserInputKind::Mouse { event_type, .. } => (event_type, event.surface_id),
                _ => ("other", event.surface_id),
            })
            .collect()
    }

    #[test]
    fn consecutive_moves_on_same_surface_keep_latest_only() {
        let mut batch = vec![move_event(1, 1.0), move_event(1, 2.0), move_event(1, 3.0)];
        coalesce_browser_events(&mut batch);
        assert_eq!(batch.len(), 1);
        match batch[0].kind {
            BrowserInputKind::Mouse { x, .. } => assert_eq!(x, 3.0),
            _ => panic!("expected mouse event"),
        }
    }

    #[test]
    fn consecutive_presentations_on_same_surface_keep_latest_only() {
        let mut batch =
            vec![presentation_event(1, 7), presentation_event(1, 8), presentation_event(1, 9)];
        coalesce_browser_events(&mut batch);

        assert_eq!(batch.len(), 1);
        assert!(matches!(batch[0].kind, BrowserInputKind::Presented { frame_seq: 9 }));
    }

    #[test]
    fn clicks_break_coalescing_and_keep_order() {
        let mut batch = vec![move_event(1, 1.0), click_event(1), move_event(1, 2.0)];
        coalesce_browser_events(&mut batch);
        assert_eq!(
            positions(&batch),
            vec![("mouseMoved", 1), ("mousePressed", 1), ("mouseMoved", 1)]
        );
    }

    #[test]
    fn moves_on_different_surfaces_are_kept() {
        let mut batch = vec![move_event(1, 1.0), move_event(2, 1.0)];
        coalesce_browser_events(&mut batch);
        assert_eq!(batch.len(), 2);
    }

    #[test]
    fn consecutive_resizes_keep_latest_without_crossing_clicks() {
        let mut batch = vec![resize_event(1, 80), resize_event(1, 100), click_event(1)];
        coalesce_browser_events(&mut batch);
        assert_eq!(batch.len(), 2);
        match batch[0].kind {
            BrowserInputKind::Resize { cols, .. } => assert_eq!(cols, 100),
            _ => panic!("expected resize event"),
        }
        assert!(matches!(batch[1].kind, BrowserInputKind::Mouse { .. }));
    }

    #[test]
    fn resize_coalescing_stops_at_non_resize_input() {
        let mut batch = vec![resize_event(1, 80), click_event(1), resize_event(1, 100)];

        coalesce_browser_events(&mut batch);

        assert_eq!(batch.len(), 3);
        assert!(matches!(batch[0].kind, BrowserInputKind::Resize { cols: 80, .. }));
        assert!(matches!(batch[1].kind, BrowserInputKind::Mouse { .. }));
        assert!(matches!(batch[2].kind, BrowserInputKind::Resize { cols: 100, .. }));
    }

    #[test]
    fn only_full_resizes_are_saved_for_fallback_delivery() {
        let (lane, blocked) = SurfaceInputLane::blocked(1, 1);
        let latest_resizes = lane.latest_resizes.clone();

        let _ = lane.enqueue(click_event(1));
        let _ = lane.enqueue(resize_event(1, 132));
        assert!(matches!(blocked.rx.recv().unwrap().event.kind, BrowserInputKind::Mouse { .. }));
        assert!(matches!(
            latest_resizes.lock().unwrap().get(&(1, 1)).map(|event| &event.event.kind),
            Some(BrowserInputKind::Resize { cols: 132, .. })
        ));

        latest_resizes.lock().unwrap().clear();
        let _ = lane.enqueue(resize_event(1, 144));
        assert!(latest_resizes.lock().unwrap().is_empty());
        assert!(matches!(
            blocked.rx.recv().unwrap().event.kind,
            BrowserInputKind::Resize { cols: 144, .. }
        ));

        drop(blocked);
        let _ = lane.enqueue(resize_event(1, 156));
        assert!(latest_resizes.lock().unwrap().is_empty());
    }

    #[test]
    fn resize_claim_lives_through_queue_fallback_replacement_and_disconnect() {
        let (lane, blocked) = SurfaceInputLane::blocked(1, 1);
        let latest_resizes = lane.latest_resizes.clone();
        let accepted = Arc::new(AtomicBool::new(false));
        let _ = lane.enqueue(resize_event_with_probe(1, 80, accepted.clone()));
        assert!(!accepted.load(Ordering::Acquire));
        drop(blocked.rx.recv().unwrap());
        assert!(accepted.load(Ordering::Acquire));

        let _ = lane.enqueue(click_event(1));
        let replaced = Arc::new(AtomicBool::new(false));
        let retained = Arc::new(AtomicBool::new(false));
        let _ = lane.enqueue(resize_event_with_probe(1, 100, replaced.clone()));
        let _ = lane.enqueue(resize_event_with_probe(1, 120, retained.clone()));
        assert!(replaced.load(Ordering::Acquire));
        assert!(!retained.load(Ordering::Acquire));
        latest_resizes.lock().unwrap().clear();
        assert!(retained.load(Ordering::Acquire));

        drop(blocked);
        let disconnected = Arc::new(AtomicBool::new(false));
        let _ = lane.enqueue(resize_event_with_probe(1, 140, disconnected.clone()));
        assert!(disconnected.load(Ordering::Acquire));
    }

    #[test]
    fn resize_claim_drops_after_dispatch_failure() {
        let dropped = Arc::new(AtomicBool::new(false));
        let event = resize_event_with_probe(1, 80, dropped.clone());
        assert!(dispatch(&event).is_err());
        assert!(!dropped.load(Ordering::Acquire));
        drop(event);
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn failed_resize_is_reported_and_same_geometry_is_suppressed() {
        let (failure_tx, failure_rx) = std::sync::mpsc::channel();
        let dispatcher = BrowserInputDispatcher::spawn(
            move |failure| {
                failure_tx.send(failure).unwrap();
            },
            |_| {},
        )
        .unwrap();

        let callback_called = Arc::new(AtomicBool::new(false));
        let accepted = Arc::new(AtomicBool::new(true));
        let mut first = resize_event(7, 100);
        if let BrowserInputKind::Resize { on_result, .. } = &mut first.kind {
            let callback_called = callback_called.clone();
            let accepted_result = accepted.clone();
            *on_result = Some(Box::new(move |reservation_id| {
                accepted_result.store(reservation_id.is_some(), Ordering::Release);
                callback_called.store(true, Ordering::Release);
            }));
        }
        let _ = dispatcher.enqueue(first);
        let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(callback_called.load(Ordering::Acquire));
        assert!(!accepted.load(Ordering::Acquire));
        assert_eq!((failure.surface_id, failure.cols, failure.rows), (7, 100, 24));
        assert!(dispatcher.resize_failed(7, (100, 24)));

        let dropped = Arc::new(AtomicBool::new(false));
        let _ = dispatcher.enqueue(resize_event_with_probe(7, 100, dropped.clone()));
        assert!(dropped.load(Ordering::Acquire));
        assert!(failure_rx.try_recv().is_err());

        dispatcher.failed_resizes.lock().unwrap().get_mut(&7).unwrap().retry_after =
            Some(Instant::now() - Duration::from_millis(1));
        assert!(dispatcher.resize_retry_due());
        assert!(!dispatcher.visible_resize_retry_due(&HashSet::new()));
        assert!(!dispatcher.resize_retry_due());
        dispatcher.failed_resizes.lock().unwrap().insert(
            7,
            FailedBrowserResize {
                desired: (100, 24),
                attempts: 1,
                retry_after: Some(Instant::now() - Duration::from_millis(1)),
            },
        );
        assert!(dispatcher.visible_resize_retry_due(&HashSet::from([7])));
        let _ = dispatcher.enqueue(resize_event(7, 100));
        failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(dispatcher.failed_resizes.lock().unwrap().get(&7).unwrap().attempts, 2);

        dispatcher.forget_surface(7);
        assert!(!dispatcher.resize_failed(7, (100, 24)));
    }

    #[test]
    fn forgetting_surface_cancels_queued_resize_and_clears_fallback() {
        let (lane, blocked) = SurfaceInputLane::blocked(7, 1);
        let latest_resizes = lane.latest_resizes.clone();
        let queued = Arc::new(AtomicBool::new(false));
        let fallback = Arc::new(AtomicBool::new(false));
        let _ = lane.enqueue(resize_event_with_probe(7, 80, queued.clone()));
        let _ = lane.enqueue(resize_event_with_probe(7, 100, fallback.clone()));

        let _ = lane.cancel_surface(7);

        assert!(!queued.load(Ordering::Acquire));
        assert!(fallback.load(Ordering::Acquire));
        assert!(latest_resizes.lock().unwrap().is_empty());
        let queued_event = blocked.rx.recv().unwrap();
        assert!(queued_event.lifetime.load(Ordering::Acquire));
        drop(queued_event);
        assert!(queued.load(Ordering::Acquire));
    }

    #[test]
    fn persistent_resize_failure_requires_geometry_or_lifecycle_recovery() {
        let mut failure = None;
        for _ in 0..6 {
            failure = Some(next_failed_browser_resize(failure, (100, 24)));
        }
        let failure = failure.unwrap();

        assert_eq!(failure.attempts, 6);
        assert!(failure.retry_after.is_none());
        assert!(failed_browser_resize_blocks(failure, (100, 24)));
        assert!(!failed_browser_resize_blocks(failure, (120, 24)));
    }

    #[test]
    fn dropped_resize_slot_delivers_latest_geometry_after_queued_input() {
        let mut batch = vec![sequenced(0, click_event(1))];
        let latest = HashMap::from([((1, 0), sequenced(1, resize_event(1, 132)))]);

        merge_fallback_events(&mut batch, latest, Vec::new());

        assert_eq!(batch.len(), 2);
        assert!(matches!(batch[0].event.kind, BrowserInputKind::Mouse { .. }));
        assert!(matches!(batch[1].event.kind, BrowserInputKind::Resize { cols: 132, .. }));
    }

    #[test]
    fn rejected_resize_stays_before_later_accepted_input() {
        let (lane, blocked) = SurfaceInputLane::blocked(1, 1);
        let latest_resizes = lane.latest_resizes.clone();

        let _ = lane.enqueue(click_event(1));
        let _ = lane.enqueue(resize_event(1, 132));
        let first = blocked.rx.recv().unwrap();
        let _ = lane.enqueue(click_event(1));
        let _ = lane.enqueue(resize_event(1, 144));
        let mut batch = vec![first];
        finish_ordered_batch(
            &blocked.rx,
            &lane.order,
            &latest_resizes,
            &lane.retained_releases,
            &mut batch,
        );

        assert_eq!(batch.iter().map(|event| event.sequence).collect::<Vec<_>>(), vec![0, 1, 2, 3]);
        assert!(matches!(batch[0].event.kind, BrowserInputKind::Mouse { .. }));
        assert!(matches!(batch[1].event.kind, BrowserInputKind::Resize { cols: 132, .. }));
        assert!(matches!(batch[2].event.kind, BrowserInputKind::Mouse { .. }));
        assert!(matches!(batch[3].event.kind, BrowserInputKind::Resize { cols: 144, .. }));
    }
}
