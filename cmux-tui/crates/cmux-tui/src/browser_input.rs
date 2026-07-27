//! Off-loop browser command forwarding.
//!
//! Forwarding input to a browser surface ultimately performs blocking
//! I/O: a CDP request/response on the shared WebSocket for local
//! surfaces (30s timeout, plus up to the reader's poll window to take
//! the socket lock), or a JSON request over the control socket (10s
//! timeout) for remote ones. A wedged Chrome or half-open session must
//! never freeze the TUI event loop just because the mouse moved, so
//! input events are handed to a fixed pool of bounded worker lanes.
//! Surfaces map to one stable lane, which preserves their command order
//! without creating an OS thread for every surface:
//!
//! - Consecutive mouse moves on the same surface are coalesced (latest
//!   wins) before dispatch, so a stalled endpoint never builds a replay
//!   backlog of stale hover/drag positions.
//! - A blocking request stalls only its fixed shard. Surfaces on other
//!   shards keep dispatching independently, while total worker threads
//!   remain bounded.
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

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_tui_core::SurfaceId;

use crate::session::SurfaceHandle;

/// Bounded queue depth. Input events are tiny; this is sized so bursts
/// (drag + key repeat) never drop while a healthy worker drains, but a
/// blocked worker caps queued work at a few hundred events.
const QUEUE_CAPACITY: usize = 512;
/// Stable sharding bounds OS-thread and queue growth while retaining enough
/// parallel lanes that one blocked browser does not freeze all browser input.
const BROWSER_INPUT_WORKER_COUNT: usize = 8;
/// At most the ordinary queue plus its one in-flight event can contain
/// accepted presses awaiting releases while the browser worker is wedged.
const RETAINED_RELEASE_CAPACITY: usize = QUEUE_CAPACITY + 1;

pub struct BrowserInputEvent {
    pub surface_id: SurfaceId,
    pub surface: SurfaceHandle,
    pub kind: BrowserInputKind,
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
    lanes: Vec<SurfaceInputLane>,
    failed_resizes: Arc<Mutex<HashMap<SurfaceId, FailedBrowserResize>>>,
    #[cfg(test)]
    blocked_lane: Option<SurfaceInputLane>,
}

struct SurfaceInputLane {
    expected_surface_id: Option<SurfaceId>,
    tx: SyncSender<SequencedBrowserInputEvent>,
    order: Arc<Mutex<BrowserEnqueueOrder>>,
    latest_resizes: Arc<Mutex<HashMap<(SurfaceId, u64), SequencedBrowserInputEvent>>>,
    retained_releases: Arc<Mutex<Vec<SequencedBrowserInputEvent>>>,
    surface_lifetimes: Mutex<HashMap<SurfaceId, Arc<AtomicBool>>>,
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
        let mut lanes = Vec::with_capacity(BROWSER_INPUT_WORKER_COUNT);
        for worker_index in 0..BROWSER_INPUT_WORKER_COUNT {
            lanes.push(SurfaceInputLane::spawn_shard(
                worker_index,
                QUEUE_CAPACITY,
                failed_resizes.clone(),
                on_resize_failure.clone(),
                on_control_failure.clone(),
            )?);
        }
        Ok(Self {
            lanes,
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
                lanes: Vec::new(),
                failed_resizes: Arc::new(Mutex::new(HashMap::new())),
                blocked_lane: Some(lane),
            },
            blocked,
        )
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
        self.lane(surface_id).enqueue(event)
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
            lane.cancel_surface(surface_id);
            self.failed_resizes.lock().unwrap().remove(&surface_id);
            return;
        }
        self.lane(surface_id).cancel_surface(surface_id);
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
        self.lane(surface_id).tracks_surface(surface_id)
            || self.failed_resizes.lock().unwrap().contains_key(&surface_id)
    }

    #[cfg(test)]
    fn worker_count(&self) -> usize {
        self.lanes.len()
    }

    fn lane(&self, surface_id: SurfaceId) -> &SurfaceInputLane {
        let index = (surface_id % self.lanes.len() as u64) as usize;
        &self.lanes[index]
    }
}

impl SurfaceInputLane {
    fn spawn_shard(
        worker_index: usize,
        capacity: usize,
        failed_resizes: Arc<Mutex<HashMap<SurfaceId, FailedBrowserResize>>>,
        on_resize_failure: Arc<dyn Fn(BrowserResizeFailure) + Send + Sync>,
        on_control_failure: Arc<dyn Fn(String) + Send + Sync>,
    ) -> std::io::Result<Self> {
        let (tx, rx) = sync_channel(capacity);
        let order = Arc::new(Mutex::new(BrowserEnqueueOrder::default()));
        let latest_resizes = Arc::new(Mutex::new(HashMap::new()));
        let retained_releases = Arc::new(Mutex::new(Vec::new()));
        let worker_order = order.clone();
        let worker_resizes = latest_resizes.clone();
        let worker_releases = retained_releases.clone();
        std::thread::Builder::new().name(format!("mux-browser-input-{worker_index}")).spawn(
            move || {
                surface_worker(
                    rx,
                    worker_order,
                    worker_resizes,
                    worker_releases,
                    failed_resizes,
                    on_resize_failure,
                    on_control_failure,
                );
            },
        )?;
        Ok(Self {
            expected_surface_id: None,
            tx,
            order,
            latest_resizes,
            retained_releases,
            surface_lifetimes: Mutex::new(HashMap::new()),
        })
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
        let (tx, rx) = sync_channel(capacity);
        let retained_releases = Arc::new(Mutex::new(Vec::new()));
        (
            Self {
                expected_surface_id,
                tx,
                order: Arc::new(Mutex::new(BrowserEnqueueOrder::default())),
                latest_resizes: Arc::new(Mutex::new(HashMap::new())),
                retained_releases: retained_releases.clone(),
                surface_lifetimes: Mutex::new(HashMap::new()),
            },
            BlockedBrowserInput { rx, retained_releases },
        )
    }

    fn enqueue(&self, event: BrowserInputEvent) -> bool {
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
                return false;
            };
            // This set governs producer admission only. The core browser
            // worker retains the runtime capture until CDP confirms release,
            // and schedules one bounded retry after an ambiguous timeout.
            if !order.accepted_pointer_presses.remove(&release) {
                return false;
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
        let event = SequencedBrowserInputEvent { sequence, event, lifetime };
        match self.tx.try_send(event) {
            Ok(()) if !is_resize => {
                if let Some(press) = press {
                    order.accepted_pointer_presses.insert(press);
                }
                order.barrier_epoch = order.barrier_epoch.saturating_add(1);
                true
            }
            Err(TrySendError::Full(event)) if is_resize => {
                self.latest_resizes
                    .lock()
                    .unwrap()
                    .insert((event.event.surface_id, order.barrier_epoch), event);
                true
            }
            Err(TrySendError::Full(event)) if is_release => {
                let mut releases = self.retained_releases.lock().unwrap();
                if releases.len() >= RETAINED_RELEASE_CAPACITY {
                    return false;
                }
                releases.push(event);
                order.barrier_epoch = order.barrier_epoch.saturating_add(1);
                true
            }
            Ok(()) => true,
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => false,
        }
    }

    fn cancel_surface(&self, surface_id: SurfaceId) {
        self.order
            .lock()
            .unwrap()
            .accepted_pointer_presses
            .retain(|(surface, _)| *surface != surface_id);
        if let Some(lifetime) = self.surface_lifetimes.lock().unwrap().remove(&surface_id) {
            lifetime.store(true, Ordering::Release);
        }
        self.latest_resizes.lock().unwrap().retain(|(surface, _), _| *surface != surface_id);
    }

    #[cfg(test)]
    fn tracks_surface(&self, surface_id: SurfaceId) -> bool {
        self.surface_lifetimes.lock().unwrap().contains_key(&surface_id)
            || self.latest_resizes.lock().unwrap().keys().any(|(surface, _)| *surface == surface_id)
    }
}

fn surface_worker(
    rx: Receiver<SequencedBrowserInputEvent>,
    order: Arc<Mutex<BrowserEnqueueOrder>>,
    latest_resizes: Arc<Mutex<HashMap<(SurfaceId, u64), SequencedBrowserInputEvent>>>,
    retained_releases: Arc<Mutex<Vec<SequencedBrowserInputEvent>>>,
    failed_resizes: Arc<Mutex<HashMap<SurfaceId, FailedBrowserResize>>>,
    on_resize_failure: Arc<dyn Fn(BrowserResizeFailure) + Send + Sync>,
    on_control_failure: Arc<dyn Fn(String) + Send + Sync>,
) {
    while let Ok(event) = rx.recv() {
        let mut batch = vec![event];
        finish_ordered_batch(&rx, &order, &latest_resizes, &retained_releases, &mut batch);
        coalesce_sequenced_browser_events(&mut batch);
        for mut event in batch {
            if event.lifetime.load(Ordering::Acquire) {
                continue;
            }
            let desired = event.event.kind.resize_dimensions();
            if desired.is_some_and(|desired| {
                failed_resizes
                    .lock()
                    .unwrap()
                    .get(&event.event.surface_id)
                    .copied()
                    .is_some_and(|failure| failed_browser_resize_blocks(failure, desired))
            }) {
                continue;
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
                continue;
            };
            if event.lifetime.load(Ordering::Acquire) {
                continue;
            }
            match result {
                Ok(_) => {
                    failed_resizes.lock().unwrap().remove(&event.event.surface_id);
                }
                Err(error) => {
                    let desired = (cols, rows);
                    let mut failures = failed_resizes.lock().unwrap();
                    let failure = next_failed_browser_resize(
                        failures.get(&event.event.surface_id).copied(),
                        desired,
                    );
                    failures.insert(event.event.surface_id, failure);
                    drop(failures);
                    let failure = BrowserResizeFailure {
                        surface_id: event.event.surface_id,
                        cols,
                        rows,
                        error: error.to_string(),
                    };
                    drop(event);
                    on_resize_failure(failure);
                }
            }
        }
    }
}

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

fn coalesce_sequenced_browser_events(batch: &mut Vec<SequencedBrowserInputEvent>) {
    let mut index = 0;
    while index + 1 < batch.len() {
        let current = &batch[index].event;
        let next = &batch[index + 1].event;
        let same_coalescing_kind = (current.kind.is_mouse_move() && next.kind.is_mouse_move())
            || (current.kind.is_resize() && next.kind.is_resize());
        if same_coalescing_kind && current.surface_id == next.surface_id {
            batch.remove(index);
        } else {
            index += 1;
        }
    }
}

fn dispatch(event: &BrowserInputEvent) -> anyhow::Result<bool> {
    let surface = &event.surface;
    match &event.kind {
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
        SequencedBrowserInputEvent { sequence, event, lifetime: Arc::new(AtomicBool::new(false)) }
    }

    fn reload_event(surface: SurfaceId) -> BrowserInputEvent {
        BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Reload,
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
        assert!(message.contains("browser command failed"), "unexpected message: {message}");

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

        lane.cancel_surface(7);

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
