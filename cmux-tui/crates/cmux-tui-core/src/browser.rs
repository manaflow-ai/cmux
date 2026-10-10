use crate::lock_rank::{Condvar, Mutex, RankedMutex, rank};
use std::collections::{HashMap, VecDeque};
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use cmux_tui_cdp::{
    CDP_EVENT_QUEUE_CAPACITY, CapturedFrame, CdpClient, CdpEvent, CdpKeyEvent, FrameEpoch,
    TargetCreated, resolve_browser_ws_url,
};

use crate::browser_provider::{BrowserProviderAuthentication, BrowserProviderTargetLease};
use crate::resource::TabResourceIdentity;
use crate::surface::{Surface, SurfaceMeta, SurfaceOptions};
use crate::{Mux, MuxEvent, SurfaceId};

mod cdp_events;
mod navigation_hold;
mod navigation_hold_tests;
mod surface_input;
mod surface_navigation;
mod surface_paint_verification;
mod url_input;
use cdp_events::{
    dialog_response, handle_frame_navigated, handle_same_document_navigated, handle_target_created,
};
pub use url_input::normalize_url;
mod runtime;
mod surface_authority;
mod surface_frames;
mod surface_pointer;
mod surface_queue;
mod surface_reconfigure;
mod surface_state;
mod surface_transitions;
mod worker;
#[cfg(test)]
use runtime::runtime_endpoint;
use runtime::{browser_geometry_locked, capture_scale_for, scaled_pixels};
pub(crate) use runtime::{new_surface, new_surface_with_resource_identity};
use worker::{is_cdp_timeout_error, start_browser_worker, start_surface_thread};
#[cfg(test)]
use worker::{
    next_pointer_lifecycle_deadline, record_browser_worker_result,
    release_abandoned_pointer_presses, take_latest_worker_commands,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowserSource {
    External,
    Launched,
    Provider,
}

impl BrowserSource {
    pub fn as_str(self) -> &'static str {
        match self {
            BrowserSource::External => "external",
            BrowserSource::Launched => "launched",
            // Provider is a connection/ownership mode for a native external
            // browser. Keep the stable public source vocabulary unchanged.
            BrowserSource::Provider => "external",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserFrame {
    pub session_id: String,
    pub data_b64: String,
    pub css_width: u32,
    pub css_height: u32,
    pub image_width: u32,
    pub image_height: u32,
    pub seq: u64,
}

fn browser_frame_from_capture(session_id: &str, captured: CapturedFrame) -> BrowserFrame {
    BrowserFrame {
        session_id: session_id.to_string(),
        data_b64: captured.data_b64,
        css_width: captured.css_width,
        css_height: captured.css_height,
        image_width: captured.css_width,
        image_height: captured.css_height,
        seq: 0,
    }
}

pub struct BrowserFrameStream {
    pub slot: Arc<RankedMutex<BrowserAttachUpdate, { rank::LEAF }>>,
    /// Coalescing wake; a stream interrupt can also wake it.
    pub notify: crate::stream_interrupt::SignalReceiver,
}

pub(crate) type BrowserResizeOutcome = Result<(), Arc<str>>;
pub(crate) type BrowserResizeWaiter = SyncSender<BrowserResizeOutcome>;
type BrowserCommandOutcome = Result<(), Arc<str>>;

pub(crate) struct PendingBrowserResize {
    pub reservation: u64,
    pub completion: Receiver<BrowserResizeOutcome>,
}

struct BrowserFrameTap {
    slot: Arc<RankedMutex<BrowserAttachUpdate, { rank::LEAF }>>,
    notify: crate::stream_interrupt::SignalSender,
}

#[derive(Debug, Default)]
pub struct BrowserAttachUpdate {
    pub state: Option<BrowserAttachState>,
    pub frame: Option<BrowserFrameUpdate>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrowserStatus {
    Starting,
    Live,
    Failed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowserFailure<'a> {
    NotResponding,
    ResizeRecovery,
    NewPageVerification(&'a str),
    UpdatedPageVerification(&'a str),
    Other(&'a str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BrowserFailureKind {
    NotResponding,
    ResizeRecovery,
    NewPageVerification,
    UpdatedPageVerification,
    Other,
}

impl BrowserFailureKind {
    fn allows_navigation_recovery(self) -> bool {
        matches!(
            self,
            Self::ResizeRecovery | Self::NewPageVerification | Self::UpdatedPageVerification
        )
    }
}

impl BrowserStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            BrowserStatus::Starting => "starting",
            BrowserStatus::Live => "live",
            BrowserStatus::Failed(_) => "failed",
        }
    }

    pub fn error(&self) -> Option<String> {
        match self {
            BrowserStatus::Failed(error) => Some(error.clone()),
            BrowserStatus::Starting | BrowserStatus::Live => None,
        }
    }

    pub fn failure(&self) -> Option<BrowserFailure<'_>> {
        // This decoder is presentation compatibility for string-only remote
        // state. Local control flow uses BrowserState::failure_kind.
        let BrowserStatus::Failed(error) = self else { return None };
        if error == BROWSER_NOT_RESPONDING_MESSAGE {
            return Some(BrowserFailure::NotResponding);
        }
        if error == BROWSER_RESIZE_RECOVERY_FAILED_MESSAGE {
            return Some(BrowserFailure::ResizeRecovery);
        }
        if let Some(detail) = error
            .strip_prefix(BROWSER_NEW_PAGE_VERIFICATION_FAILED_PREFIX)
            .and_then(|detail| detail.strip_suffix(BROWSER_VERIFICATION_FAILED_SUFFIX))
        {
            return Some(BrowserFailure::NewPageVerification(detail));
        }
        if let Some(detail) = error
            .strip_prefix(BROWSER_UPDATED_PAGE_VERIFICATION_FAILED_PREFIX)
            .and_then(|detail| detail.strip_suffix(BROWSER_VERIFICATION_FAILED_SUFFIX))
        {
            return Some(BrowserFailure::UpdatedPageVerification(detail));
        }
        Some(BrowserFailure::Other(error))
    }
}

/// Latest-wins image update paired with the state that governs pointer input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserFrameUpdate {
    pub frame: BrowserFrame,
    pub status: BrowserStatus,
    /// Oldest bitmap token in the current document and coordinate mapping.
    /// Route membership alone does not authorize pointer input.
    pub pointer_frame_floor_seq: Option<u64>,
    pub pointer_frame_seq: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserAttachState {
    pub url: String,
    pub title: String,
    pub cols: u16,
    pub rows: u16,
    pub status: BrowserStatus,
    pub frame: Option<BrowserFrame>,
    /// Opaque pointer-authority token for this exact admitted bitmap.
    /// A later bitmap always carries a different token.
    pub pointer_frame_seq: Option<u64>,
    /// Oldest bitmap token in the current document and coordinate mapping.
    /// Route membership alone does not authorize pointer input.
    pub pointer_frame_floor_seq: Option<u64>,
    pub frames_stalled: bool,
}

#[derive(Clone)]
struct BrowserSession {
    runtime: Arc<BrowserRuntime>,
    target_id: String,
    session_id: String,
}

struct BrowserState {
    latest_frame: Option<Arc<BrowserFrame>>,
    // Frames are stamped at CDP ingress. A lifecycle barrier reserves the next
    // epoch and holds its first frame until the matching state change commits.
    accepted_frame_epoch: u64,
    accepted_navigation_epoch: u64,
    handled_navigation_epoch: u64,
    /// Latest same-document navigation already consumed by the surface
    /// thread. CDP ingress tracks this separately from generic frame restarts
    /// so a later restart cannot make an older queued navigation disappear.
    handled_same_document_navigation_epoch: u64,
    pending_frame_epoch: Option<u64>,
    // Navigation commands retain their own authority reservation because a
    // concurrent capture restart may advance and settle the shared frame
    // epoch without proving that the document committed.
    pending_navigation_epoch: Option<u64>,
    /// Cross-document navigation stays fail-closed until a loader-matched
    /// first paint is captured and admitted.
    pending_document_epoch: Option<u64>,
    /// One owner for the lifetime of an unresolved navigation or document
    /// paint barrier. The browser worker wakes at this deadline even when no
    /// further CDP event or input arrives.
    pending_authority_deadline: Option<Instant>,
    /// A targeted navigation may settle through a same-document event from
    /// the current main frame and loader.
    pending_same_document_navigation: bool,
    /// The pending navigation was explicitly started while a retryable
    /// terminal failure was visible. Only its verified paint may recover the
    /// surface; unrelated page lifecycle events cannot clear that failure.
    pending_failure_recovery: bool,
    /// Original rendered authority retained while a navigation remains
    /// unresolved. A latest-wins replacement may reuse it only when ingress
    /// proves the stopped navigation never committed.
    pending_navigation_rollback: Option<PointerFrameInvalidation>,
    /// Frame epoch with one loader-verified screenshot reserved or in flight.
    /// Further timestamp-less frames coalesce into that capture instead of
    /// inheriting its authority or starting parallel captures.
    pending_screencast_capture: Option<ScreencastCaptureReservation>,
    /// Frame epoch whose loader-verified recovery exhausted its bounded
    /// attempts. Further timestamp-less frames stay fail-closed until a later
    /// epoch or an authoritative streamed frame arrives.
    failed_screencast_capture_epoch: Option<u64>,
    pending_frame: Option<(u64, BrowserFrame)>,
    /// Opaque pointer-authority token for the exact admitted bitmap.
    /// Every later admissible bitmap rotates it.
    pointer_frame_seq: Option<u64>,
    /// First exact bitmap token admitted since the last document or geometry
    /// invalidation. This proves route membership without granting input
    /// authority by itself.
    pointer_frame_floor_seq: Option<u64>,
    /// Exact bitmap last acknowledged as presented by each input owner.
    /// One entry per active owner bounds authority without retaining frames.
    presented_pointer_frames: HashMap<BrowserPointerOwner, u64>,
    /// Changes whenever pointer route admission changes, so a failed command
    /// can restore its previous route and presentation acknowledgements only
    /// if no asynchronous browser event won the race in the meantime.
    pointer_frame_revision: u64,
    /// Release-ownership epoch for pointer captures. Unlike pointer authority,
    /// this survives ordinary repaints, geometry changes, and recoverable
    /// failures. It changes when a document replacement makes releasing into
    /// the page that accepted the press unsafe.
    pointer_capture_generation: u64,
    /// Coordinate-validity epoch for motion during an accepted press. This
    /// survives ordinary repaints but changes when navigation, geometry, or a
    /// failure makes the press's original coordinate mapping unsafe. Release
    /// ownership remains governed separately by `pointer_capture_generation`.
    pointer_motion_generation: u64,
    // Latest-wins attach frame taps. Broadcast overwrites each slot and
    // sends one wakeup; a slow client skips old frames but stays attached.
    taps: Vec<BrowserFrameTap>,
    title: String,
    url: String,
    size: (u16, u16),
    pane_pixels: (u32, u32),
    capture_pixels: (u32, u32),
    capture_scale: f64,
    pending_reconfigures: VecDeque<QueuedBrowserGeometry>,
    reconfigure_waiters: HashMap<u64, Vec<BrowserResizeWaiter>>,
    next_reconfigure_id: u64,
    reconfigure_failure: Option<BrowserReconfigureFailure>,
    page_viewport: Option<(u32, u32)>,
    status: BrowserStatus,
    failure_kind: Option<BrowserFailureKind>,
    source: Option<BrowserSource>,
    next_frame_seq: u64,
    live_since: Option<Instant>,
    last_frame_at: Option<Instant>,
    stall_nudged: bool,
    not_responding_reported: bool,
}

#[derive(Clone, Copy, PartialEq)]
struct BrowserGeometry {
    size: (u16, u16),
    pane_pixels: (u32, u32),
    capture_pixels: (u32, u32),
    capture_scale: f64,
}

#[derive(Clone, Copy, PartialEq)]
struct QueuedBrowserGeometry {
    id: u64,
    geometry: BrowserGeometry,
}

#[derive(Clone, Copy)]
struct BrowserReconfigureFailure {
    geometry: BrowserGeometry,
    attempts: u8,
    retry_at: Option<Instant>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct ScreencastCaptureReservation {
    id: u64,
    frame_epoch: u64,
    navigation_epoch: u64,
}

struct BrowserReconfigureCommandError {
    error: anyhow::Error,
    definitely_unchanged: bool,
}

#[derive(Clone)]
struct PointerFrameInvalidation {
    previous: Option<u64>,
    previous_floor: Option<u64>,
    previous_presented_pointer_frames: HashMap<BrowserPointerOwner, u64>,
    previous_latest_frame_seq: Option<u64>,
    previous_capture_generation: u64,
    previous_motion_generation: u64,
    previous_pending_frame_epoch: Option<u64>,
    previous_pending_navigation_epoch: Option<u64>,
    previous_pending_authority_deadline: Option<Instant>,
    previous_pending_same_document_navigation: bool,
    previous_accepted_navigation_epoch: u64,
    previous_pending_frame: Option<(u64, BrowserFrame)>,
    revision: u64,
    expected_frame_epoch: Option<u64>,
}

enum BrowserCommand {
    WakeLatest,
    Mouse {
        input_owner: BrowserPointerOwner,
        event_type: String,
        x: f64,
        y: f64,
        button: Option<String>,
        click_count: Option<u32>,
        frame_seq: Option<u64>,
        pointer_admission: Option<BrowserPointerAdmission>,
    },
    Wheel {
        input_owner: BrowserPointerOwner,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
        pointer_admission: Option<BrowserPointerAdmission>,
    },
    Key {
        event_type: String,
        key: String,
        code: String,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<String>,
    },
    KeyPress {
        key: String,
        code: String,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<String>,
    },
    InsertText(String),
    Navigate(String),
    Back,
    Forward,
    Reload,
    Activate,
    Close,
    Confirmed {
        command: Box<BrowserCommand>,
        completion: SyncSender<BrowserCommandOutcome>,
    },
    AuthorizeDocumentPaint {
        session_id: String,
        frame_id: String,
        loader_id: String,
        navigation_epoch: u64,
    },
    AuthorizeSameDocumentPaint {
        session_id: String,
        frame_id: String,
        loader_id: String,
    },
    AuthorizeScreencastCapture {
        session_id: String,
        frame_id: String,
        loader_id: String,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    },
    Reconfigure {
        queued: QueuedBrowserGeometry,
        report: Option<Box<dyn FnOnce(Option<u64>) + Send>>,
        completion: Option<BrowserResizeWaiter>,
    },
    #[cfg(test)]
    Hold {
        entered: Sender<()>,
        release: Receiver<()>,
    },
}

struct SequencedBrowserCommand {
    sequence: u64,
    command: BrowserCommand,
}

#[derive(Default)]
struct BrowserCommandOrder {
    next_sequence: u64,
    retained_releases: VecDeque<SequencedBrowserCommand>,
}

impl BrowserCommandOrder {
    fn sequence(&mut self, command: BrowserCommand) -> SequencedBrowserCommand {
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.wrapping_add(1);
        SequencedBrowserCommand { sequence, command }
    }
}

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
pub(crate) enum BrowserPointerOwner {
    Local,
    Legacy,
    Client(u64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct BrowserPointerAdmission {
    owner: BrowserPointerOwner,
    frame_seq: Option<u64>,
}

pub(crate) struct BrowserMouseDispatch<'a> {
    pub(crate) input_owner: BrowserPointerOwner,
    pub(crate) event_type: &'a str,
    pub(crate) x: f64,
    pub(crate) y: f64,
    pub(crate) button: Option<&'a str>,
    pub(crate) click_count: Option<u32>,
    pub(crate) frame_seq: Option<u64>,
}

#[derive(Clone, Copy)]
struct BrowserWheelDispatch {
    input_owner: BrowserPointerOwner,
    x: f64,
    y: f64,
    delta_x: f64,
    delta_y: f64,
    frame_seq: Option<u64>,
}

impl BrowserCommand {
    fn is_input(&self) -> bool {
        matches!(
            self,
            BrowserCommand::Mouse { .. }
                | BrowserCommand::Wheel { .. }
                | BrowserCommand::Key { .. }
                | BrowserCommand::KeyPress { .. }
                | BrowserCommand::InsertText(_)
        )
    }

    fn mouse_move_owner(&self) -> Option<BrowserPointerOwner> {
        match self {
            BrowserCommand::Mouse { input_owner, event_type, .. } if event_type == "mouseMoved" => {
                Some(*input_owner)
            }
            _ => None,
        }
    }
}

fn reject_reconfigure(mut command: BrowserCommand) -> Option<QueuedBrowserGeometry> {
    if let BrowserCommand::Reconfigure { report, completion, .. } = &mut command {
        if let Some(report) = report.take() {
            report(None);
        }
        if let Some(completion) = completion.take() {
            let _ = completion.send(Err(Arc::from("browser resize was rejected before execution")));
        }
    }
    match command {
        BrowserCommand::Reconfigure { queued, .. } => Some(queued),
        _ => None,
    }
}

#[derive(Default)]
struct BrowserWorkerErrorState {
    consecutive_timeouts: u8,
    active_pointer_presses: HashMap<String, ActivePointerPress>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BrowserWorkerSuccess {
    BrowserResponded,
    LocallySettled,
}

type BrowserWorkerResult = anyhow::Result<BrowserWorkerSuccess>;

#[derive(Clone, Copy, Debug, PartialEq)]
struct ActivePointerPress {
    input_owner: BrowserPointerOwner,
    capture_generation: u64,
    motion_generation: u64,
    ingress_motion_generation: u64,
    frame_seq: u64,
    last_target_x: f64,
    last_target_y: f64,
    click_count: Option<u32>,
    compatibility_expires_at: Option<Instant>,
    release_retry_at: Option<Instant>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum CapturedPointerRoute {
    Current((f64, f64)),
    MotionInvalidated,
    InvalidCapture,
}

impl ActivePointerPress {
    fn new(
        input_owner: BrowserPointerOwner,
        capture_generation: u64,
        motion_generation: u64,
        ingress_motion_generation: u64,
        frame_seq: u64,
        point: (f64, f64),
        click_count: Option<u32>,
    ) -> Self {
        Self {
            input_owner,
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            frame_seq,
            last_target_x: point.0,
            last_target_y: point.1,
            click_count,
            compatibility_expires_at: match input_owner {
                BrowserPointerOwner::Local => Some(Instant::now() + LOCAL_POINTER_PRESS_LEASE),
                BrowserPointerOwner::Client(_) => None,
                BrowserPointerOwner::Legacy => Some(Instant::now() + LEGACY_POINTER_PRESS_LEASE),
            },
            release_retry_at: None,
        }
    }

    fn refresh_pointer_position(&mut self, target_x: f64, target_y: f64) {
        self.last_target_x = target_x;
        self.last_target_y = target_y;
        self.compatibility_expires_at = match self.input_owner {
            BrowserPointerOwner::Local => Some(Instant::now() + LOCAL_POINTER_PRESS_LEASE),
            BrowserPointerOwner::Client(_) => None,
            BrowserPointerOwner::Legacy => Some(Instant::now() + LEGACY_POINTER_PRESS_LEASE),
        };
    }
}

pub struct BrowserRuntime {
    client: CdpClient,
    source: BrowserSource,
    endpoint: String,
    bearer_token: Option<String>,
    stealth_user_agent: Option<String>,
    routes: RankedMutex<Routes, { rank::LEAF }>,
    closed: AtomicBool,
}

#[derive(Default)]
struct Routes {
    by_session: HashMap<String, Arc<SurfaceRoute>>,
    by_target: HashMap<String, Arc<SurfaceRoute>>,
}

struct SurfaceRoute {
    state: RankedMutex<SurfaceRouteState, { rank::LEAF }>,
    ready: Condvar,
}

#[derive(Default)]
struct SurfaceRouteState {
    events: VecDeque<QueuedSurfaceEvent>,
    retained_bytes: usize,
    closed: bool,
}

struct QueuedSurfaceEvent {
    event: CdpEvent,
    retained_bytes: usize,
}

impl SurfaceRoute {
    fn new() -> Self {
        Self { state: RankedMutex::new(SurfaceRouteState::default()), ready: Condvar::new() }
    }

    /// Returns true when the route must be removed from the runtime maps.
    fn deliver(&self, event: CdpEvent) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.closed {
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
            self.ready.notify_one();
            return true;
        }
        state.events.push_back(QueuedSurfaceEvent { event, retained_bytes: event_bytes });
        state.retained_bytes += event_bytes;
        self.ready.notify_one();
        false
    }

    fn recv(&self) -> Option<CdpEvent> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(queued) = state.events.pop_front() {
                state.retained_bytes = state.retained_bytes.saturating_sub(queued.retained_bytes);
                return Some(queued.event);
            }
            if state.closed {
                return None;
            }
            state = self.ready.wait(state).unwrap();
        }
    }

    fn close(&self, reason: String) {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return;
        }
        fail_surface_route(&mut state, &reason);
        self.ready.notify_one();
    }

    #[cfg(test)]
    fn is_closed(&self) -> bool {
        self.state.lock().unwrap().closed
    }

    #[cfg(test)]
    fn try_recv(&self) -> Option<CdpEvent> {
        let mut state = self.state.lock().unwrap();
        let queued = state.events.pop_front()?;
        state.retained_bytes = state.retained_bytes.saturating_sub(queued.retained_bytes);
        Some(queued.event)
    }
}

fn fail_surface_route(state: &mut SurfaceRouteState, reason: &str) {
    state.events.clear();
    let event = CdpEvent::Closed(reason.to_string());
    let retained_bytes = cmux_tui_cdp::event_retained_bytes(&event);
    state.retained_bytes = retained_bytes;
    state.events.push_back(QueuedSurfaceEvent { event, retained_bytes });
    state.closed = true;
}

pub struct BrowserSurface {
    pub(crate) meta: SurfaceMeta,
    session: RankedMutex<Option<BrowserSession>, { rank::BROWSER_SESSION }>,
    // Navigation and pointer lifecycle state grows independently of the
    // Surface enum. Keep that payload out of line.
    state: RankedMutex<Box<BrowserState>, { rank::BROWSER_STATE }>,
    frame_epoch: Arc<FrameEpoch>,
    dirty: AtomicBool,
    dead: AtomicBool,
    cell_pixels: RankedMutex<(u16, u16), { rank::LEAF }>,
    capture_options: BrowserCaptureOptions,
    command_tx: RankedMutex<Option<SyncSender<SequencedBrowserCommand>>, { rank::LEAF }>,
    command_order: Arc<RankedMutex<BrowserCommandOrder, { rank::BROWSER_COMMAND_ORDER }>>,
    latest_nav: Arc<RankedMutex<Option<SequencedBrowserCommand>, { rank::LEAF }>>,
    latest_authority: Arc<RankedMutex<Option<SequencedBrowserCommand>, { rank::LEAF }>>,
    navigation_hold:
        RankedMutex<navigation_hold::NavigationHold, { rank::BROWSER_NAVIGATION_HOLD }>,
    #[cfg(test)]
    worker_done: Mutex<Option<Receiver<()>>>,
    /// Navigation commit waits that ran out their deadline: a test observes
    /// that a path never waited for an epoch, without timing it.
    #[cfg(test)]
    navigation_commit_wait_timeouts: AtomicUsize,
}

#[derive(Debug, Clone, Copy)]
struct BrowserCaptureOptions {
    max_capture_megapixels: f64,
    fixed_capture_scale: Option<f64>,
}

// Two megapixels leave headroom below the 16 MiB transport message cap even
// for an incompressible RGBA PNG after base64 and JSON encoding.
pub const TRANSPORT_SAFE_CAPTURE_MEGAPIXELS: f64 = 2.0;
const DEFAULT_CAPTURE_MEGAPIXELS: f64 = TRANSPORT_SAFE_CAPTURE_MEGAPIXELS;
const STALL_THRESHOLD: Duration = Duration::from_secs(2);
const BROWSER_COMMAND_QUEUE_CAPACITY: usize = 64;
const BROWSER_RETAINED_RELEASE_CAPACITY: usize = BROWSER_COMMAND_QUEUE_CAPACITY + 1;
const LEGACY_POINTER_PRESS_LEASE: Duration = Duration::from_secs(30);
const LOCAL_POINTER_PRESS_LEASE: Duration = Duration::from_secs(30);
const MAX_RECONFIGURE_WAITERS_PER_RESERVATION: usize = 64;
const BROWSER_NOT_RESPONDING_MESSAGE: &str = "browser is not responding";
const BROWSER_RESIZE_RECOVERY_FAILED_MESSAGE: &str =
    "browser resize recovery failed; reload to retry";
const BROWSER_NEW_PAGE_VERIFICATION_FAILED_PREFIX: &str = "could not verify new page pixels: ";
const BROWSER_UPDATED_PAGE_VERIFICATION_FAILED_PREFIX: &str =
    "could not verify updated page pixels: ";
const BROWSER_VERIFICATION_FAILED_SUFFIX: &str = "; reload to retry";
const AUTHORITY_CAPTURE_ATTEMPTS: usize = 3;
#[cfg(not(test))]
const AUTHORITY_CAPTURE_ATTEMPT_BUDGET: Duration = Duration::from_secs(2);
#[cfg(test)]
// A healthy capture performs seven serialized CDP round trips. The client's
// 20 ms read poll means 150 ms leaves essentially no scheduler margin.
const AUTHORITY_CAPTURE_ATTEMPT_BUDGET: Duration = Duration::from_millis(300);
const NAVIGATION_AUTHORITY_TIMEOUT: Duration = Duration::from_secs(15);
const POINTER_RELEASE_RETRY_DELAY: Duration = Duration::from_millis(250);
const BROWSER_RECONFIGURE_RETRY_DELAYS: [Duration; 2] =
    [Duration::from_millis(250), Duration::from_millis(500)];
#[cfg(not(test))]
const NAVIGATION_COMMIT_WAIT: Duration = Duration::from_millis(250);
#[cfg(test)]
const NAVIGATION_COMMIT_WAIT: Duration = Duration::from_millis(100);

pub(crate) enum BrowserBootstrap {
    ExistingTarget { target_id: String, url: String },
    Provider { tab_id: crate::resource::TabPublicId, url: String },
}

impl BrowserSurface {}

fn browser_attach_state_locked(
    state: &BrowserState,
    now: Instant,
    dead: bool,
    include_frame: bool,
    pointer_frame_floor_seq: Option<u64>,
    pointer_frame_seq: Option<u64>,
) -> BrowserAttachState {
    BrowserAttachState {
        url: state.url.clone(),
        title: state.title.clone(),
        cols: state.size.0,
        rows: state.size.1,
        status: state.status.clone(),
        frame: include_frame.then(|| state.latest_frame.as_deref().cloned()).flatten(),
        pointer_frame_seq,
        pointer_frame_floor_seq,
        frames_stalled: frames_stalled_locked(state, now, dead),
    }
}

fn frames_stalled_locked(state: &BrowserState, now: Instant, dead: bool) -> bool {
    if dead || !matches!(state.status, BrowserStatus::Live) {
        return false;
    }
    if state.source == Some(BrowserSource::Launched) {
        return false;
    }
    let Some(since) = state.last_frame_at.or(state.live_since) else {
        return false;
    };
    now.saturating_duration_since(since) > STALL_THRESHOLD
}

#[cfg(test)]
mod tests;
