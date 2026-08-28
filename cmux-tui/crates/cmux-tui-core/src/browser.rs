use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use cmux_tui_cdp::{
    CDP_EVENT_QUEUE_CAPACITY, CapturedFrame, CdpClient, CdpCloseReason, CdpEvent, CdpKeyEvent,
    Chrome, FrameEpoch, TargetCreated, resolve_browser_ws_url,
};

use crate::browser_provider::{BrowserProviderAuthentication, BrowserProviderTargetLease};
use crate::resource::TabResourceIdentity;
use crate::surface::{Surface, SurfaceMeta, SurfaceOptions};
use crate::{Mux, MuxEvent, SurfaceId};

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
    pub slot: Arc<Mutex<BrowserAttachUpdate>>,
    pub notify: Receiver<()>,
}

pub(crate) type BrowserResizeOutcome = Result<(), Arc<str>>;
pub(crate) type BrowserResizeWaiter = SyncSender<BrowserResizeOutcome>;
type BrowserCommandOutcome = Result<(), Arc<str>>;

pub(crate) struct PendingBrowserResize {
    pub reservation: u64,
    pub completion: Receiver<BrowserResizeOutcome>,
}

struct BrowserFrameTap {
    slot: Arc<Mutex<BrowserAttachUpdate>>,
    notify: SyncSender<()>,
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
    chrome: Option<Chrome>,
    source: BrowserSource,
    endpoint: String,
    bearer_token: Option<String>,
    stealth_user_agent: Option<String>,
    routes: Mutex<Routes>,
    closed: AtomicBool,
}

#[derive(Default)]
struct Routes {
    by_session: HashMap<String, Arc<SurfaceRoute>>,
    by_target: HashMap<String, Arc<SurfaceRoute>>,
}

struct SurfaceRoute {
    state: Mutex<SurfaceRouteState>,
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
        Self { state: Mutex::new(SurfaceRouteState::default()), ready: Condvar::new() }
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
            fail_surface_route(&mut state, CdpCloseReason::EventQueueOverflow);
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

    fn close(&self, reason: CdpCloseReason) {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return;
        }
        fail_surface_route(&mut state, reason);
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

fn fail_surface_route(state: &mut SurfaceRouteState, reason: CdpCloseReason) {
    state.events.clear();
    let event = CdpEvent::Closed(reason);
    let retained_bytes = cmux_tui_cdp::event_retained_bytes(&event);
    state.retained_bytes = retained_bytes;
    state.events.push_back(QueuedSurfaceEvent { event, retained_bytes });
    state.closed = true;
}

pub struct BrowserSurface {
    pub(crate) meta: SurfaceMeta,
    session: Mutex<Option<BrowserSession>>,
    // Navigation and pointer lifecycle state grows independently of the
    // Surface enum. Keep that payload out of line.
    state: Mutex<Box<BrowserState>>,
    frame_epoch: Arc<FrameEpoch>,
    dirty: AtomicBool,
    dead: AtomicBool,
    cell_pixels: Mutex<(u16, u16)>,
    capture_options: BrowserCaptureOptions,
    command_tx: Mutex<Option<SyncSender<SequencedBrowserCommand>>>,
    command_order: Arc<Mutex<BrowserCommandOrder>>,
    latest_nav: Arc<Mutex<Option<SequencedBrowserCommand>>>,
    latest_authority: Arc<Mutex<Option<SequencedBrowserCommand>>>,
    #[cfg(test)]
    worker_done: Mutex<Option<Receiver<()>>>,
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

impl BrowserRuntime {
    pub fn connect(opts: &SurfaceOptions) -> anyhow::Result<Arc<Self>> {
        let (web_socket_url, chrome, source) = runtime_endpoint(opts)?;
        Self::connect_to_endpoint(&web_socket_url, chrome, source)
    }

    pub(crate) fn connect_provider(
        endpoint: &str,
        authentication: &BrowserProviderAuthentication,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_to_endpoint_with_bearer(
            endpoint,
            None,
            BrowserSource::Provider,
            authentication.bearer_token(),
        )
    }

    fn connect_to_endpoint(
        web_socket_url: &str,
        chrome: Option<Chrome>,
        source: BrowserSource,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_to_endpoint_with_bearer(web_socket_url, chrome, source, None)
    }

    fn connect_to_endpoint_with_bearer(
        web_socket_url: &str,
        chrome: Option<Chrome>,
        source: BrowserSource,
        bearer_token: Option<&str>,
    ) -> anyhow::Result<Arc<Self>> {
        let (event_tx, event_rx) = sync_channel(CDP_EVENT_QUEUE_CAPACITY);
        let client = CdpClient::connect_with_bearer(web_socket_url, bearer_token, event_tx)?;
        let stealth_user_agent = if source == BrowserSource::Launched {
            client.browser_version().ok().and_then(|ua| clean_headless_user_agent(&ua))
        } else {
            None
        };
        let runtime = Arc::new(BrowserRuntime {
            client,
            chrome,
            source,
            endpoint: web_socket_url.to_string(),
            bearer_token: bearer_token.map(str::to_string),
            stealth_user_agent,
            routes: Mutex::new(Routes::default()),
            closed: AtomicBool::new(false),
        });
        start_router(Arc::downgrade(&runtime), event_rx)?;
        runtime.client.set_discover_targets(true)?;
        Ok(runtime)
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    pub fn source(&self) -> BrowserSource {
        self.source
    }

    pub(crate) fn matches_provider(
        &self,
        endpoint: &str,
        authentication: &BrowserProviderAuthentication,
    ) -> bool {
        self.source == BrowserSource::Provider
            && self.endpoint == endpoint
            && self.bearer_token.as_deref() == authentication.bearer_token()
    }

    pub(crate) fn bootstrap_surface_sync(
        self: &Arc<Self>,
        surface: Arc<Surface>,
        bootstrap: BrowserBootstrap,
        mux: Weak<Mux>,
    ) -> anyhow::Result<()> {
        if self.is_closed() {
            anyhow::bail!("CDP browser connection is closed");
        }
        let (target_id, normalized_url) = match bootstrap {
            BrowserBootstrap::ExistingTarget { target_id, url } => (target_id, normalize_url(&url)),
            BrowserBootstrap::Provider { .. } => {
                anyhow::bail!("browser provider target was not resolved before CDP bootstrap")
            }
        };
        let session_id = self.client.attach_to_target(&target_id)?;
        let events = self.register(&target_id, &session_id);
        if surface.as_browser().is_none() {
            self.release_bootstrap_session(&target_id, &session_id);
            anyhow::bail!("browser bootstrap got a non-browser surface");
        }
        let setup_result =
            self.setup_attached_surface(&surface, &target_id, &session_id, &normalized_url);
        if let Err(err) = setup_result {
            self.release_bootstrap_session(&target_id, &session_id);
            return Err(err);
        }

        start_surface_thread(surface, events, mux, Arc::downgrade(self), session_id)?;
        Ok(())
    }

    fn setup_attached_surface(
        self: &Arc<Self>,
        surface: &Arc<Surface>,
        target_id: &str,
        session_id: &str,
        normalized_url: &str,
    ) -> anyhow::Result<()> {
        let Surface::Browser(browser) = surface.as_ref() else {
            anyhow::bail!("browser bootstrap got a non-browser surface");
        };
        if browser.is_dead() {
            anyhow::bail!("browser surface was closed before it started");
        }
        self.client.register_frame_epoch(session_id, browser.frame_epoch.clone());
        if let Some(user_agent) = self.stealth_user_agent.as_deref() {
            let _ = self.client.set_user_agent(session_id, user_agent);
        }
        self.client.page_enable(session_id)?;
        self.client.set_lifecycle_events_enabled(session_id)?;
        self.client.seed_main_frame(session_id)?;
        let (pixel_w, pixel_h) = browser.pixel_size();
        self.client.set_device_metrics(session_id, pixel_w, pixel_h)?;
        self.client.start_screencast(session_id, pixel_w, pixel_h)?;
        if browser.is_dead() {
            anyhow::bail!("browser surface was closed before it started");
        }
        browser.mark_live(BrowserSession {
            runtime: self.clone(),
            target_id: target_id.to_string(),
            session_id: session_id.to_string(),
        })?;
        browser.set_url_title(normalized_url.to_string(), normalized_url.to_string());
        Ok(())
    }

    fn register(&self, target_id: &str, session_id: &str) -> Arc<SurfaceRoute> {
        let route = Arc::new(SurfaceRoute::new());
        let mut routes = self.routes.lock().unwrap();
        if self.closed.load(Ordering::Acquire) {
            drop(routes);
            route.close(CdpCloseReason::RuntimeClosed);
            return route;
        }
        routes.by_session.insert(session_id.to_string(), route.clone());
        routes.by_target.insert(target_id.to_string(), route.clone());
        route
    }

    fn unregister(&self, target_id: &str, session_id: &str) {
        self.client.unregister_frame_epoch(session_id);
        let route = {
            let mut routes = self.routes.lock().unwrap();
            let by_session = routes.by_session.remove(session_id);
            let by_target = routes.by_target.remove(target_id);
            by_session.or(by_target)
        };
        if let Some(route) = route {
            route.close(CdpCloseReason::SurfaceClosed);
        }
    }

    fn remove_route(&self, route: &Arc<SurfaceRoute>) {
        let mut routes = self.routes.lock().unwrap();
        routes.by_session.retain(|_, candidate| !Arc::ptr_eq(candidate, route));
        routes.by_target.retain(|_, candidate| !Arc::ptr_eq(candidate, route));
    }

    fn close_surface_detached(&self, target_id: &str, session_id: &str) {
        self.unregister(target_id, session_id);
        if self.is_closed() {
            return;
        }
        if self.source == BrowserSource::Provider {
            let _ = self.client.detach_from_target_detached(session_id);
        } else {
            let _ = self.client.close_target_detached(target_id);
        }
    }

    fn release_bootstrap_session(&self, target_id: &str, session_id: &str) {
        self.unregister(target_id, session_id);
        if self.is_closed() {
            return;
        }
        if self.source == BrowserSource::Provider {
            let _ = self.client.detach_from_target_detached(session_id);
        } else {
            let _ = self.client.close_target(target_id);
        }
    }

    pub fn shutdown(&self) {
        close_browser_runtime(self, CdpCloseReason::RuntimeClosed);
        let _ = self.client.flush_outbound(Duration::from_secs(1));
        if let Some(chrome) = &self.chrome {
            chrome.kill();
        }
    }
}

pub(crate) enum BrowserBootstrap {
    ExistingTarget { target_id: String, url: String },
    Provider { tab_id: crate::resource::TabPublicId, url: String },
}

pub(crate) fn new_surface(
    id: SurfaceId,
    url: String,
    size: (u16, u16),
    cell_pixels: (u16, u16),
    opts: &SurfaceOptions,
    mux: Weak<Mux>,
) -> anyhow::Result<Arc<Surface>> {
    new_surface_with_resource_identity(
        id,
        url,
        size,
        cell_pixels,
        opts,
        mux,
        TabResourceIdentity::browser()?,
    )
}

pub(crate) fn new_surface_with_resource_identity(
    id: SurfaceId,
    url: String,
    size: (u16, u16),
    cell_pixels: (u16, u16),
    opts: &SurfaceOptions,
    mux: Weak<Mux>,
    resource_identity: TabResourceIdentity,
) -> anyhow::Result<Arc<Surface>> {
    if !matches!(resource_identity.content_id, crate::resource::ContentPublicId::Browser(_)) {
        anyhow::bail!("browser surface cannot use a terminal resource identity");
    }
    let normalized_url = normalize_url(&url);
    let (cols, rows) = (size.0.max(1), size.1.max(1));
    let (cell_w, cell_h) = (cell_pixels.0.max(1), cell_pixels.1.max(1));
    let pixel_w = cols as u32 * cell_w as u32;
    let pixel_h = rows as u32 * cell_h as u32;
    let capture_options = BrowserCaptureOptions::from_options(opts);
    let capture_scale = capture_scale_for(pixel_w, pixel_h, capture_options);
    let capture_pixels = scaled_pixels(pixel_w, pixel_h, capture_scale);
    let (command_tx, command_rx) = sync_channel(BROWSER_COMMAND_QUEUE_CAPACITY);
    let command_order = Arc::new(Mutex::new(BrowserCommandOrder::default()));
    let latest_nav = Arc::new(Mutex::new(None));
    let latest_authority = Arc::new(Mutex::new(None));
    let frame_epoch = Arc::new(FrameEpoch::default());
    #[cfg(test)]
    let (worker_done_tx, worker_done_rx) = std::sync::mpsc::channel();
    #[cfg(test)]
    let worker_done_tx = Some(worker_done_tx);
    #[cfg(not(test))]
    let worker_done_tx = None;
    let surface = Arc::new(Surface::Browser(BrowserSurface {
        meta: SurfaceMeta {
            id,
            resource_identity: Some(resource_identity),
            name: Mutex::new(None),
            selection: Mutex::new(None),
        },
        session: Mutex::new(None),
        state: Mutex::new(Box::new(BrowserState {
            latest_frame: None,
            accepted_frame_epoch: frame_epoch.current(),
            accepted_navigation_epoch: frame_epoch.latest_navigation(),
            handled_navigation_epoch: frame_epoch.latest_navigation(),
            handled_same_document_navigation_epoch: frame_epoch.latest_same_document_navigation(),
            pending_frame_epoch: None,
            pending_navigation_epoch: None,
            pending_document_epoch: None,
            pending_authority_deadline: None,
            pending_same_document_navigation: false,
            pending_failure_recovery: false,
            pending_navigation_rollback: None,
            pending_screencast_capture: None,
            failed_screencast_capture_epoch: None,
            pending_frame: None,
            pointer_frame_seq: None,
            pointer_frame_floor_seq: None,
            presented_pointer_frames: HashMap::new(),
            pointer_frame_revision: 0,
            pointer_capture_generation: 0,
            pointer_motion_generation: 0,
            taps: Vec::new(),
            title: normalized_url.clone(),
            url: normalized_url,
            size: (cols, rows),
            pane_pixels: (pixel_w, pixel_h),
            capture_pixels,
            capture_scale,
            pending_reconfigures: VecDeque::new(),
            reconfigure_waiters: HashMap::new(),
            next_reconfigure_id: 1,
            reconfigure_failure: None,
            page_viewport: None,
            status: BrowserStatus::Starting,
            failure_kind: None,
            source: None,
            next_frame_seq: 1,
            live_since: None,
            last_frame_at: None,
            stall_nudged: false,
            not_responding_reported: false,
        })),
        frame_epoch,
        dirty: AtomicBool::new(true),
        dead: AtomicBool::new(false),
        cell_pixels: Mutex::new((cell_w, cell_h)),
        capture_options,
        command_tx: Mutex::new(Some(command_tx)),
        command_order: command_order.clone(),
        latest_nav: latest_nav.clone(),
        latest_authority: latest_authority.clone(),
        #[cfg(test)]
        worker_done: Mutex::new(Some(worker_done_rx)),
    }));
    start_browser_worker(
        surface.clone(),
        command_rx,
        command_order,
        latest_nav,
        latest_authority,
        mux,
        worker_done_tx,
    );
    Ok(surface)
}

impl BrowserCaptureOptions {
    fn from_options(opts: &SurfaceOptions) -> Self {
        let max_capture_megapixels = if opts.browser_max_capture_megapixels.is_finite()
            && opts.browser_max_capture_megapixels > 0.0
        {
            opts.browser_max_capture_megapixels
        } else {
            DEFAULT_CAPTURE_MEGAPIXELS
        }
        .min(TRANSPORT_SAFE_CAPTURE_MEGAPIXELS);
        let fixed_capture_scale = opts
            .browser_capture_scale
            .filter(|scale| scale.is_finite() && *scale > 0.0 && *scale <= 1.0);
        BrowserCaptureOptions { max_capture_megapixels, fixed_capture_scale }
    }
}

fn browser_geometry_locked(state: &BrowserState) -> BrowserGeometry {
    BrowserGeometry {
        size: state.size,
        pane_pixels: state.pane_pixels,
        capture_pixels: state.capture_pixels,
        capture_scale: state.capture_scale,
    }
}

fn capture_scale_for(pane_px_w: u32, pane_px_h: u32, opts: BrowserCaptureOptions) -> f64 {
    let area = f64::from(pane_px_w.max(1)) * f64::from(pane_px_h.max(1));
    let budget = opts.max_capture_megapixels.max(f64::MIN_POSITIVE) * 1_000_000.0;
    let budget_scale =
        if area <= budget { 1.0 } else { (budget / area).sqrt().clamp(f64::MIN_POSITIVE, 1.0) };
    opts.fixed_capture_scale.map_or(budget_scale, |scale| scale.min(budget_scale))
}

fn scaled_pixels(pane_px_w: u32, pane_px_h: u32, scale: f64) -> (u32, u32) {
    let width = (f64::from(pane_px_w.max(1)) * scale).round().max(1.0) as u32;
    let height = (f64::from(pane_px_h.max(1)) * scale).round().max(1.0) as u32;
    (width, height)
}

fn runtime_endpoint(
    opts: &SurfaceOptions,
) -> anyhow::Result<(String, Option<Chrome>, BrowserSource)> {
    if let Ok(url) = std::env::var("CMUX_MUX_CDP_URL")
        && !url.trim().is_empty()
    {
        return Ok((resolve_browser_ws_url(&url)?, None, BrowserSource::External));
    }
    if let Some(url) = opts.cdp_url.as_deref().filter(|url| !url.trim().is_empty()) {
        return Ok((resolve_browser_ws_url(url)?, None, BrowserSource::External));
    }
    anyhow::bail!(
        "no cmux-browser provider is attached; launch cmux-browser or set CMUX_MUX_CDP_URL for an explicit development endpoint"
    )
}

fn clean_headless_user_agent(user_agent: &str) -> Option<String> {
    user_agent.contains("HeadlessChrome").then(|| user_agent.replace("HeadlessChrome", "Chrome"))
}

fn start_router(runtime: Weak<BrowserRuntime>, events: Receiver<CdpEvent>) -> anyhow::Result<()> {
    std::thread::Builder::new().name("browser-runtime-events".into()).spawn(move || {
        while let Ok(event) = events.recv() {
            let Some(runtime) = runtime.upgrade() else { break };
            match event {
                CdpEvent::ScreencastFrame(frame) => {
                    let tx = {
                        runtime.routes.lock().unwrap().by_session.get(&frame.session_id).cloned()
                    };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::ScreencastFrame(frame))
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::ScreencastFrameCaptureRequested {
                    session_id,
                    frame_id,
                    loader_id,
                    request_id,
                    frame_epoch,
                    navigation_epoch,
                } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::ScreencastFrameCaptureRequested {
                            session_id,
                            frame_id,
                            loader_id,
                            request_id,
                            frame_epoch,
                            navigation_epoch,
                        })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::FrameNavigated { params, session_id, frame_epoch } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::FrameNavigated { params, session_id, frame_epoch })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::DocumentPainted { session_id, frame_id, loader_id, navigation_epoch } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::DocumentPainted {
                            session_id,
                            frame_id,
                            loader_id,
                            navigation_epoch,
                        })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::NavigatedWithinDocument {
                    params,
                    session_id,
                    frame_id,
                    loader_id,
                    frame_epoch,
                } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::NavigatedWithinDocument {
                            params,
                            session_id,
                            frame_id,
                            loader_id,
                            frame_epoch,
                        })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::TargetCreated(created) => {
                    let tx = created.opener_id.as_ref().and_then(|opener_id| {
                        runtime.routes.lock().unwrap().by_target.get(opener_id).cloned()
                    });
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::TargetCreated(created))
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::TargetInfoChanged(info) => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_target.get(&info.target_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::TargetInfoChanged(info))
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::Other { method, params, session_id: Some(session_id) } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::Other {
                            method,
                            params,
                            session_id: Some(session_id),
                        })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::Closed(reason) => {
                    close_browser_runtime(&runtime, reason);
                    break;
                }
                CdpEvent::Other { .. } => {}
            }
        }
        if let Some(runtime) = runtime.upgrade() {
            close_browser_runtime(&runtime, CdpCloseReason::EventReceiverClosed);
        }
    })?;
    Ok(())
}

fn close_browser_runtime(runtime: &BrowserRuntime, reason: CdpCloseReason) {
    let senders = {
        let mut routes = runtime.routes.lock().unwrap();
        runtime.closed.store(true, Ordering::Release);
        let senders = routes.by_session.values().cloned().collect::<Vec<_>>();
        routes.by_session.clear();
        routes.by_target.clear();
        senders
    };
    for tx in senders {
        tx.close(reason);
    }
}

fn start_surface_thread(
    surface: Arc<Surface>,
    events: Arc<SurfaceRoute>,
    mux: Weak<Mux>,
    runtime: Weak<BrowserRuntime>,
    route_session_id: String,
) -> anyhow::Result<()> {
    let id = surface.id;
    std::thread::Builder::new().name(format!("browser-surface-{id}-events")).spawn(move || {
        while let Some(event) = events.recv() {
            let Surface::Browser(browser) = surface.as_ref() else { break };
            match event {
                CdpEvent::ScreencastFrame(frame) => {
                    let frame_epoch = frame.frame_epoch;
                    let frame = BrowserFrame {
                        session_id: frame.session_id,
                        data_b64: frame.data_b64,
                        css_width: frame.css_width,
                        css_height: frame.css_height,
                        image_width: frame.image_width,
                        image_height: frame.image_height,
                        seq: 0,
                    };
                    let visible_state_changed = browser.store_frame_for_epoch(frame, frame_epoch);
                    if visible_state_changed
                        && !browser.dirty.swap(true, Ordering::AcqRel)
                        && let Some(mux) = mux.upgrade()
                    {
                        mux.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
                CdpEvent::ScreencastFrameCaptureRequested {
                    session_id,
                    frame_id,
                    loader_id,
                    request_id,
                    frame_epoch,
                    navigation_epoch,
                } => {
                    let reservation_id = request_id;
                    if !browser.reserve_screencast_capture(
                        reservation_id,
                        frame_epoch,
                        navigation_epoch,
                    ) {
                        if let Some(runtime) = runtime.upgrade() {
                            let _ = runtime.client.cancel_timestampless_screencast_capture(
                                &session_id,
                                reservation_id,
                                frame_epoch,
                                navigation_epoch,
                            );
                        }
                        continue;
                    }
                    if browser
                        .enqueue_latest_authority(BrowserCommand::AuthorizeScreencastCapture {
                            session_id: session_id.clone(),
                            frame_id,
                            loader_id,
                            reservation_id,
                            frame_epoch,
                            navigation_epoch,
                        })
                        .is_err()
                    {
                        browser.cancel_screencast_capture(reservation_id);
                        if let Some(runtime) = runtime.upgrade() {
                            let _ = runtime.client.cancel_timestampless_screencast_capture(
                                &session_id,
                                reservation_id,
                                frame_epoch,
                                navigation_epoch,
                            );
                        }
                    }
                }
                CdpEvent::TargetCreated(created) => {
                    handle_target_created(browser, &created, &mux, &runtime, id);
                }
                CdpEvent::TargetInfoChanged(info) => {
                    let title = if info.title.is_empty() { info.url.clone() } else { info.title };
                    let url_changed =
                        if info.url.is_empty() { false } else { browser.set_url(info.url) };
                    let title_changed = browser.set_title(title);
                    if (url_changed || title_changed)
                        && let Some(mux) = mux.upgrade()
                    {
                        mux.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: browser.title().into(),
                        });
                    }
                }
                CdpEvent::FrameNavigated { params, frame_epoch, .. } => {
                    handle_frame_navigated(browser, params, frame_epoch);
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: browser.title().into(),
                        });
                        mux.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
                CdpEvent::DocumentPainted { session_id, frame_id, loader_id, navigation_epoch }
                    if browser.needs_document_paint(navigation_epoch) =>
                {
                    let _ =
                        browser.enqueue_latest_authority(BrowserCommand::AuthorizeDocumentPaint {
                            session_id,
                            frame_id,
                            loader_id,
                            navigation_epoch,
                        });
                }
                CdpEvent::NavigatedWithinDocument {
                    params,
                    session_id,
                    frame_id,
                    loader_id,
                    frame_epoch,
                } => {
                    let _ = handle_same_document_navigated(browser, &params, frame_epoch);
                    if browser.needs_same_document_paint() {
                        let _ = browser.enqueue_latest_authority(
                            BrowserCommand::AuthorizeSameDocumentPaint {
                                session_id,
                                frame_id,
                                loader_id,
                            },
                        );
                    }
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: browser.title().into(),
                        });
                        mux.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
                CdpEvent::Other { method, params, .. }
                    if method == "Page.javascriptDialogOpening" =>
                {
                    let (accept, message) = dialog_response(&params);
                    let _ = browser.handle_javascript_dialog(accept);
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::Status(message));
                    }
                }
                CdpEvent::Closed(reason) => {
                    if let Some(runtime) = runtime
                        .upgrade()
                        .filter(|runtime| runtime.source() == BrowserSource::Provider)
                    {
                        // Route closure is session-scoped. A replacement can
                        // attach to the same browser-level WebSocket before
                        // this old event thread drains its close marker; never
                        // let that stale marker tear down the new session.
                        if browser.prepare_provider_reconnect(&runtime, &route_session_id)
                            && let Some(mux) = mux.upgrade()
                        {
                            mux.emit(MuxEvent::Status(format!(
                                "cmux-browser provider disconnected: {}; waiting to reconnect",
                                reason.public_message()
                            )));
                            mux.emit(MuxEvent::SurfaceOutput(id));
                            mux.restart_provider_browser_surface(surface.clone());
                        }
                    } else if !browser.is_dead() {
                        browser.kill();
                        if let Some(mux) = mux.upgrade() {
                            mux.surface_exited(id);
                        }
                    }
                    break;
                }
                _ => {}
            }
        }
    })?;
    Ok(())
}

fn start_browser_worker(
    surface: Arc<Surface>,
    rx: Receiver<SequencedBrowserCommand>,
    command_order: Arc<Mutex<BrowserCommandOrder>>,
    latest_nav: Arc<Mutex<Option<SequencedBrowserCommand>>>,
    latest_authority: Arc<Mutex<Option<SequencedBrowserCommand>>>,
    mux: Weak<Mux>,
    done_tx: Option<Sender<()>>,
) {
    let id = surface.id;
    let _ =
        std::thread::Builder::new().name(format!("browser-surface-{id}-worker")).spawn(move || {
            let mut failures = BrowserWorkerErrorState::default();
            loop {
                let first = match next_browser_lifecycle_deadline(&surface, &failures) {
                    Some(deadline) => {
                        match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                            Ok(first) => first,
                            Err(RecvTimeoutError::Timeout) => {
                                service_due_browser_lifecycles(&surface, &mux, id, &mut failures);
                                continue;
                            }
                            Err(RecvTimeoutError::Disconnected) => break,
                        }
                    }
                    None => match rx.recv() {
                        Ok(first) => first,
                        Err(_) => break,
                    },
                };
                let mut batch = vec![first];
                let mut order = command_order.lock().unwrap();
                while let Ok(next) = rx.try_recv() {
                    batch.push(next);
                }
                batch.extend(order.retained_releases.drain(..));
                if let Some(command) = take_latest_worker_commands(&latest_nav) {
                    batch.push(command);
                }
                if let Some(command) = take_latest_worker_commands(&latest_authority) {
                    batch.push(command);
                }
                drop(order);
                batch.sort_unstable_by_key(|queued| queued.sequence);
                service_due_browser_lifecycles(&surface, &mux, id, &mut failures);
                batch.retain(|queued| !matches!(&queued.command, BrowserCommand::WakeLatest));
                coalesce_worker_mouse_moves(&mut batch);
                for queued in batch {
                    service_due_browser_lifecycles(&surface, &mux, id, &mut failures);
                    run_browser_worker_command(&surface, queued.command, &mux, id, &mut failures);
                }
            }
            if let Some(done_tx) = done_tx {
                let _ = done_tx.send(());
            }
        });
}

fn next_browser_lifecycle_deadline(
    surface: &Surface,
    failures: &BrowserWorkerErrorState,
) -> Option<Instant> {
    [
        next_pointer_lifecycle_deadline(failures),
        surface.as_browser().and_then(BrowserSurface::pending_authority_deadline),
    ]
    .into_iter()
    .flatten()
    .min()
}

fn next_pointer_lifecycle_deadline(failures: &BrowserWorkerErrorState) -> Option<Instant> {
    failures
        .active_pointer_presses
        .values()
        .filter_map(|press| press.release_retry_at.or(press.compatibility_expires_at))
        .min()
}

fn service_due_browser_lifecycles(
    surface: &Surface,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
) {
    release_due_pointer_presses(surface, mux, id, failures);
    if let Some(message) =
        surface.as_browser().and_then(|browser| browser.expire_navigation_authority(Instant::now()))
    {
        emit_browser_failure(mux, id, message);
    }
}

fn release_due_pointer_presses(
    surface: &Surface,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
) {
    loop {
        release_abandoned_pointer_presses(surface, mux, id, failures, Instant::now());
        let now = Instant::now();
        if next_pointer_lifecycle_deadline(failures).is_none_or(|deadline| deadline > now) {
            break;
        }
    }
}

fn release_abandoned_pointer_presses(
    surface: &Surface,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
    now: Instant,
) {
    let active_clients = mux.upgrade();
    let expired = failures
        .active_pointer_presses
        .iter()
        .filter(|(_, press)| {
            if let Some(retry_at) = press.release_retry_at {
                return retry_at <= now;
            }
            let compatibility_lease_expired =
                press.compatibility_expires_at.is_some_and(|deadline| deadline <= now);
            match press.input_owner {
                BrowserPointerOwner::Local | BrowserPointerOwner::Legacy => {
                    compatibility_lease_expired
                }
                BrowserPointerOwner::Client(client) => {
                    active_clients.as_ref().is_none_or(|mux| !mux.control_clients.contains(client))
                }
            }
        })
        .map(|(button, _)| button.clone())
        .collect::<Vec<_>>();
    for button in expired {
        let Some(press) = failures.active_pointer_presses.remove(&button) else {
            continue;
        };
        let result =
            surface.as_browser().map_or(Ok(BrowserWorkerSuccess::LocallySettled), |browser| {
                browser.release_abandoned_pointer_press_blocking(&button, press)
            });
        if press.release_retry_at.is_none()
            && result.as_ref().is_err_and(|error| is_cdp_timeout_error(&error.to_string()))
        {
            let mut retry = press;
            // Delivery is ambiguous after a CDP timeout. Preserve ownership
            // for exactly one balancing retry, but yield the worker before a
            // second potentially long CDP call.
            retry.release_retry_at = Some(Instant::now() + POINTER_RELEASE_RETRY_DELAY);
            failures.active_pointer_presses.insert(button, retry);
        }
        record_browser_worker_result(surface, mux, id, true, result, failures);
    }
}

fn take_latest_worker_commands(
    latest_nav: &Arc<Mutex<Option<SequencedBrowserCommand>>>,
) -> Option<SequencedBrowserCommand> {
    latest_nav.lock().unwrap().take()
}

fn coalesce_worker_mouse_moves(batch: &mut Vec<SequencedBrowserCommand>) {
    let mut index = 0;
    while index + 1 < batch.len() {
        if batch[index].command.mouse_move_owner().is_some()
            && batch[index].command.mouse_move_owner()
                == batch[index + 1].command.mouse_move_owner()
        {
            batch.remove(index);
        } else {
            index += 1;
        }
    }
}

fn run_browser_worker_command(
    surface: &Surface,
    command: BrowserCommand,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
) {
    let (mut command, confirmed) = match command {
        BrowserCommand::Confirmed { command, completion } => (*command, Some(completion)),
        command => (command, None),
    };
    let completion =
        if let BrowserCommand::Reconfigure { queued, report, completion } = &mut command {
            if let Some(report) = report.take() {
                report(Some(queued.id));
            }
            completion.take()
        } else {
            None
        };
    let is_input = command.is_input();
    let is_reconfigure = matches!(command, BrowserCommand::Reconfigure { .. });
    let reconfigure = match &command {
        BrowserCommand::Reconfigure { queued, .. } => Some(*queued),
        _ => None,
    };
    let disconnected_pointer_client = match &command {
        BrowserCommand::Mouse { input_owner: BrowserPointerOwner::Client(client), .. }
        | BrowserCommand::Wheel { input_owner: BrowserPointerOwner::Client(client), .. } => {
            mux.upgrade().is_none_or(|mux| !mux.control_clients.contains(*client))
        }
        _ => false,
    };
    if disconnected_pointer_client {
        return;
    }
    let result = {
        let Some(browser) = surface.as_browser() else {
            return;
        };
        match command {
            BrowserCommand::WakeLatest => Ok(BrowserWorkerSuccess::LocallySettled),
            BrowserCommand::Mouse {
                input_owner,
                event_type,
                x,
                y,
                button,
                click_count,
                frame_seq,
                pointer_admission,
            } => browser.mouse_event_blocking_with_admission(
                BrowserMouseDispatch {
                    input_owner,
                    event_type: &event_type,
                    x,
                    y,
                    button: button.as_deref(),
                    click_count,
                    frame_seq,
                },
                pointer_admission,
                &mut failures.active_pointer_presses,
            ),
            BrowserCommand::Wheel {
                input_owner,
                x,
                y,
                delta_x,
                delta_y,
                frame_seq,
                pointer_admission,
            } => browser.wheel_blocking(
                BrowserWheelDispatch { input_owner, x, y, delta_x, delta_y, frame_seq },
                pointer_admission,
            ),
            BrowserCommand::Key {
                event_type,
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text,
            } => browser
                .key_event_blocking(
                    &event_type,
                    &key,
                    &code,
                    windows_virtual_key_code,
                    modifiers,
                    text.as_deref(),
                )
                .map(|_| BrowserWorkerSuccess::BrowserResponded),
            BrowserCommand::KeyPress { key, code, windows_virtual_key_code, modifiers, text } => {
                browser
                    .key_press_blocking(
                        &key,
                        &code,
                        windows_virtual_key_code,
                        modifiers,
                        text.as_deref(),
                    )
                    .map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::InsertText(text) => {
                browser.insert_text_blocking(&text).map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Navigate(url) => {
                browser.navigate_blocking(&url).map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Back => {
                browser.back_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Forward => {
                browser.forward_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Reload => {
                browser.reload_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Activate => {
                browser.activate_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::AuthorizeDocumentPaint {
                session_id,
                frame_id,
                loader_id,
                navigation_epoch,
            } => browser.authorize_document_paint_blocking(
                &session_id,
                &frame_id,
                &loader_id,
                navigation_epoch,
            ),
            BrowserCommand::AuthorizeSameDocumentPaint { session_id, frame_id, loader_id } => {
                browser.authorize_same_document_paint_blocking(&session_id, &frame_id, &loader_id)
            }
            BrowserCommand::AuthorizeScreencastCapture {
                session_id,
                frame_id,
                loader_id,
                reservation_id,
                frame_epoch,
                navigation_epoch,
            } => browser.authorize_screencast_capture_blocking(
                &session_id,
                &frame_id,
                &loader_id,
                reservation_id,
                frame_epoch,
                navigation_epoch,
            ),
            BrowserCommand::Close => {
                browser.close_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Confirmed { .. } => {
                unreachable!("confirmed wrappers are removed before execution")
            }
            BrowserCommand::Reconfigure { queued, .. } => {
                browser.reconfigure_reserved_blocking(queued)
            }
            #[cfg(test)]
            BrowserCommand::Hold { entered, release } => {
                let _ = entered.send(());
                release
                    .recv()
                    .map(|_| BrowserWorkerSuccess::LocallySettled)
                    .map_err(anyhow::Error::msg)
            }
        }
    };
    if let Some(completion) = confirmed {
        let outcome = result.as_ref().map(|_| ()).map_err(|error| Arc::from(error.to_string()));
        let _ = completion.send(outcome);
    }
    if is_reconfigure
        && result.is_ok()
        && let Some(mux) = mux.upgrade()
        && let Some(queued) = reconfigure
    {
        let (cols, rows) = queued.geometry.size;
        mux.emit(MuxEvent::SurfaceResized {
            surface: id,
            cols,
            rows,
            reservation_id: Some(queued.id),
        });
    }
    if let Some(queued) = reconfigure
        && let Err(error) = &result
        && let Some(browser) = surface.as_browser()
        && let Some((_, retry_delay)) = browser.fail_reconfigure(queued)
        && let Some(mux) = mux.upgrade()
    {
        let (cols, rows) = queued.geometry.size;
        mux.emit(MuxEvent::SurfaceResizeFailed {
            surface: id,
            cols,
            rows,
            error: Arc::<str>::from(error.to_string()),
            retry_after_ms: retry_delay.map(|delay| delay.as_millis() as u64),
            reservation_id: Some(queued.id),
        });
    }
    if let Some(completion) = completion {
        let outcome = result.as_ref().map(|_| ()).map_err(|error| Arc::from(error.to_string()));
        let _ = completion.send(outcome);
    }
    if let Some(queued) = reconfigure
        && let Some(browser) = surface.as_browser()
    {
        let outcome = result.as_ref().map(|_| ()).map_err(|error| Arc::from(error.to_string()));
        browser.complete_reconfigure_waiters(queued.id, outcome);
    }
    record_browser_worker_result(surface, mux, id, is_input, result, failures);
}

fn record_browser_worker_result(
    surface: &Surface,
    mux: &Weak<Mux>,
    id: SurfaceId,
    is_input: bool,
    result: BrowserWorkerResult,
    failures: &mut BrowserWorkerErrorState,
) {
    match result {
        Ok(success) => {
            // Superseded and stale work is intentionally successful at the
            // queue boundary, but it carries no evidence that CDP recovered.
            if success == BrowserWorkerSuccess::BrowserResponded {
                failures.consecutive_timeouts = 0;
            }
            if !is_input {
                emit_browser_dirty(mux, id);
            }
        }
        Err(err) => {
            let message = err.to_string();
            let timeout = is_cdp_timeout_error(&message);
            if timeout {
                failures.consecutive_timeouts = failures.consecutive_timeouts.saturating_add(1);
                if failures.consecutive_timeouts >= 2 {
                    let should_report = surface
                        .as_browser()
                        .is_some_and(BrowserSurface::claim_not_responding_report);
                    if should_report {
                        if let Some(browser) = surface.as_browser() {
                            browser.mark_not_responding();
                        }
                        emit_browser_failure(mux, id, BROWSER_NOT_RESPONDING_MESSAGE.to_string());
                    }
                }
            } else {
                failures.consecutive_timeouts = 0;
            }
            if !(is_input || timeout && failures.consecutive_timeouts >= 2) {
                emit_browser_status(mux, message);
                emit_browser_dirty(mux, id);
            }
        }
    }
}

fn is_cdp_timeout_error(message: &str) -> bool {
    message.contains("CDP call ") && message.contains(" timed out")
}

fn emit_browser_status(mux: &Weak<Mux>, message: String) {
    if let Some(mux) = mux.upgrade() {
        mux.emit(MuxEvent::Status(message));
    }
}

fn emit_browser_dirty(mux: &Weak<Mux>, id: SurfaceId) {
    if let Some(mux) = mux.upgrade() {
        let title = mux.surface(id).map(|surface| surface.title()).unwrap_or_default();
        mux.emit(MuxEvent::TitleChanged { surface: id, title: title.into() });
        mux.emit(MuxEvent::SurfaceOutput(id));
    }
}

fn emit_browser_failure(mux: &Weak<Mux>, id: SurfaceId, message: String) {
    if let Some(mux) = mux.upgrade() {
        mux.emit(MuxEvent::Status(message));
        let title = mux.surface(id).map(|surface| surface.title()).unwrap_or_default();
        mux.emit(MuxEvent::TitleChanged { surface: id, title: title.into() });
        mux.emit(MuxEvent::SurfaceOutput(id));
    }
}

impl BrowserSurface {
    pub fn latest_frame(&self) -> Option<Arc<BrowserFrame>> {
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            None
        } else {
            state.latest_frame.clone()
        }
    }

    pub fn latest_frame_metadata(&self) -> Option<(u64, u32, u32, Option<u64>)> {
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            None
        } else {
            let pointer_frame_seq = self.exported_pointer_frame_seq_locked(&state);
            state
                .latest_frame
                .as_ref()
                .map(|frame| (frame.seq, frame.css_width, frame.css_height, pointer_frame_seq))
        }
    }

    /// Return the opaque authority token for guarded pointer input. The token
    /// identifies the latest admitted bitmap and rotates on every later bitmap.
    pub fn latest_frame_seq(&self) -> Option<u64> {
        let state = self.state.lock().unwrap();
        self.exported_pointer_frame_seq_locked(&state)
    }

    /// Return whether the local input owner has acknowledged this exact
    /// bitmap as its current presentation.
    pub fn accepts_pointer_frame(&self, frame_seq: u64) -> bool {
        let state = self.state.lock().unwrap();
        self.presented_pointer_frame_is_current_locked(
            &state,
            BrowserPointerOwner::Local,
            frame_seq,
        )
    }

    /// Return whether a bitmap belongs to the current document and coordinate
    /// mapping. Route membership does not authorize pointer input.
    pub fn pointer_frame_is_in_current_route(&self, frame_seq: u64) -> bool {
        let state = self.state.lock().unwrap();
        self.pointer_frame_is_in_current_route_locked(&state, frame_seq)
    }

    /// Record that the local renderer presented this exact bitmap. Returns
    /// whether the renderer's acknowledged token changed.
    pub fn acknowledge_pointer_frame(&self, frame_seq: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        let changed =
            state.presented_pointer_frames.get(&BrowserPointerOwner::Local) != Some(&frame_seq);
        changed
            && self.acknowledge_pointer_frame_locked(
                &mut state,
                BrowserPointerOwner::Local,
                frame_seq,
            )
    }

    pub(crate) fn acknowledge_pointer_frame_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: u64,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        self.acknowledge_pointer_frame_locked(&mut state, owner, frame_seq)
    }

    pub(crate) fn forget_pointer_owner(&self, owner: BrowserPointerOwner) {
        self.state.lock().unwrap().presented_pointer_frames.remove(&owner);
    }

    pub fn latest_frame_update(&self) -> Option<BrowserFrameUpdate> {
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            return None;
        }
        state.latest_frame.as_ref().map(|frame| BrowserFrameUpdate {
            frame: frame.as_ref().clone(),
            status: state.status.clone(),
            pointer_frame_floor_seq: self.exported_pointer_frame_floor_seq_locked(&state),
            pointer_frame_seq: self.exported_pointer_frame_seq_locked(&state),
        })
    }

    pub fn has_latest_frame(&self) -> bool {
        let state = self.state.lock().unwrap();
        !matches!(state.status, BrowserStatus::Failed(_)) && state.latest_frame.is_some()
    }

    pub fn title(&self) -> String {
        self.state.lock().unwrap().title.clone()
    }

    pub fn url(&self) -> String {
        self.state.lock().unwrap().url.clone()
    }

    pub fn status(&self) -> BrowserStatus {
        self.state.lock().unwrap().status.clone()
    }

    pub fn frames_stalled(&self) -> bool {
        self.frames_stalled_at(Instant::now())
    }

    pub fn source(&self) -> Option<BrowserSource> {
        self.session.lock().unwrap().as_ref().map(|session| session.runtime.source())
    }

    pub(crate) fn prepare_provider_bootstrap_attempt(&self) -> bool {
        if self.is_dead() || self.session.lock().unwrap().is_some() {
            return false;
        }
        let mut state = self.state.lock().unwrap();
        state.status = BrowserStatus::Starting;
        state.failure_kind = None;
        state.source = None;
        state.title = state.url.clone();
        state.live_since = None;
        state.last_frame_at = None;
        state.stall_nudged = false;
        state.not_responding_reported = false;
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
        true
    }

    fn prepare_provider_reconnect(&self, runtime: &Arc<BrowserRuntime>, session_id: &str) -> bool {
        self.prepare_provider_session_replacement(|session| {
            session.session_id == session_id && Arc::ptr_eq(&session.runtime, runtime)
        })
    }

    pub(crate) fn prepare_provider_lease_replacement(
        &self,
        lease: Option<&BrowserProviderTargetLease>,
    ) -> bool {
        self.prepare_provider_session_replacement(|session| {
            !lease.is_some_and(|lease| {
                session.target_id == lease.target_id
                    && session.runtime.matches_provider(&lease.endpoint, &lease.authentication)
            })
        })
    }

    fn prepare_provider_session_replacement(
        &self,
        should_replace: impl FnOnce(&BrowserSession) -> bool,
    ) -> bool {
        if self.is_dead() {
            return false;
        }
        let Some(session) = ({
            let mut current = self.session.lock().unwrap();
            let matches = current.as_ref().is_some_and(|session| {
                session.runtime.source() == BrowserSource::Provider && should_replace(session)
            });
            matches.then(|| current.take()).flatten()
        }) else {
            return false;
        };
        session.runtime.close_surface_detached(&session.target_id, &session.session_id);

        let frame_epoch = self.frame_epoch.advance();
        let mut state = self.state.lock().unwrap();
        self.invalidate_pointer_frame_locked(&mut state, true);
        state.latest_frame = None;
        state.pending_frame = None;
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_navigation_rollback = None;
        state.pending_screencast_capture = None;
        state.failed_screencast_capture_epoch = None;
        state.accepted_frame_epoch = frame_epoch;
        state.page_viewport = None;
        state.status = BrowserStatus::Starting;
        state.failure_kind = None;
        state.source = None;
        state.title = state.url.clone();
        state.live_since = None;
        state.last_frame_at = None;
        state.stall_nudged = false;
        state.not_responding_reported = false;
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
        true
    }

    pub fn size(&self) -> (u16, u16) {
        self.state.lock().unwrap().size
    }

    fn pixel_size(&self) -> (u32, u32) {
        self.state.lock().unwrap().capture_pixels
    }

    pub fn is_dead(&self) -> bool {
        self.dead.load(Ordering::Acquire)
    }

    pub fn take_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::AcqRel)
    }

    #[cfg(test)]
    pub(crate) fn take_worker_done_for_test(&self) -> Receiver<()> {
        self.worker_done.lock().unwrap().take().expect("worker done receiver already taken")
    }

    pub fn kill(&self) {
        if self.dead.swap(true, Ordering::AcqRel) {
            return;
        }
        self.close_taps();
        if let Some(session) = self.session.lock().unwrap().take() {
            session.runtime.close_surface_detached(&session.target_id, &session.session_id);
        }
        self.close_command_sender();
    }

    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_reporting_acceptance(cols, rows, Box::new(|_| {}))
            .map(|reservation_id| reservation_id.is_some())
    }

    pub fn resize_reporting_acceptance(
        &self,
        cols: u16,
        rows: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        self.resize_reporting_completion(cols, rows, report, None)
    }

    pub(crate) fn resize_reporting_completion(
        &self,
        cols: u16,
        rows: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
        completion: Option<BrowserResizeWaiter>,
    ) -> anyhow::Result<Option<u64>> {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let Some(queued) = self.reserve_reconfigure(cols, rows) else {
            report(None);
            if let Some(completion) = completion {
                let _ = completion.send(Ok(()));
            }
            return Ok(None);
        };
        self.enqueue_reconfigure(BrowserCommand::Reconfigure {
            queued,
            report: Some(report),
            completion,
        })?;
        Ok(Some(queued.id))
    }

    fn reconfigure_reserved_blocking(&self, queued: QueuedBrowserGeometry) -> BrowserWorkerResult {
        let invalidation = self.begin_reconfigure_frame_transition();
        let result = self.reconfigure_blocking(
            queued.geometry.capture_pixels.0,
            queued.geometry.capture_pixels.1,
        );
        match result {
            Ok((frame_epoch, success)) => {
                self.confirm_reconfigure(queued, frame_epoch);
                Ok(success)
            }
            Err(failure) => {
                if failure.definitely_unchanged {
                    self.restore_pointer_frame_after_failed_command(invalidation);
                }
                Err(failure.error)
            }
        }
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
        self.set_cell_pixel_size_reporting(width_px, height_px, Box::new(|_| {}))
            .map(|reservation_id| reservation_id.is_some())
    }

    pub(crate) fn cell_pixel_size(&self) -> (u16, u16) {
        *self.cell_pixels.lock().unwrap()
    }

    pub fn set_cell_pixel_size_reporting(
        &self,
        width_px: u16,
        height_px: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        // Store desired metrics before calculating the candidate geometry.
        // Settled geometry remains in BrowserState, so an enqueue rejection
        // leaves a visible mismatch that the same request can retry.
        *self.cell_pixels.lock().unwrap() = (width_px.max(1), height_px.max(1));
        let (cols, rows) = self.size();
        self.resize_reporting_acceptance(cols, rows, report)
    }

    fn reserve_reconfigure(&self, cols: u16, rows: u16) -> Option<QueuedBrowserGeometry> {
        let geometry = self.resize_geometry(cols, rows);
        let mut state = self.state.lock().unwrap();
        if state.pending_reconfigures.back().is_some_and(|queued| queued.geometry == geometry)
            || state.pending_reconfigures.is_empty() && browser_geometry_locked(&state) == geometry
        {
            return None;
        }
        if let Some(failure) = state.reconfigure_failure {
            if failure.geometry == geometry {
                if failure.retry_at.is_none_or(|retry_at| Instant::now() < retry_at) {
                    return None;
                }
            } else {
                state.reconfigure_failure = None;
            }
        }
        let queued = QueuedBrowserGeometry { id: state.next_reconfigure_id, geometry };
        state.next_reconfigure_id = state.next_reconfigure_id.wrapping_add(1).max(1);
        state.pending_reconfigures.push_back(queued);
        Some(queued)
    }

    pub(crate) fn pending_resize_completion(
        &self,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<Option<PendingBrowserResize>> {
        let geometry = self.resize_geometry(cols, rows);
        let mut state = self.state.lock().unwrap();
        if let Some(pending) =
            state.pending_reconfigures.iter().rev().find(|pending| pending.geometry == geometry)
        {
            let reservation = pending.id;
            if state
                .reconfigure_waiters
                .get(&reservation)
                .is_some_and(|waiters| waiters.len() >= MAX_RECONFIGURE_WAITERS_PER_RESERVATION)
            {
                anyhow::bail!("browser resize reservation {reservation} has too many waiters");
            }
            let (completion, completed) = sync_channel(1);
            state.reconfigure_waiters.entry(reservation).or_default().push(completion);
            return Ok(Some(PendingBrowserResize { reservation, completion: completed }));
        }
        if browser_geometry_locked(&state) == geometry {
            return Ok(None);
        }
        if state.reconfigure_failure.is_some_and(|failure| failure.geometry == geometry) {
            anyhow::bail!("browser resize is waiting to retry after a previous failure");
        }
        anyhow::bail!("browser resize was not accepted");
    }

    fn complete_reconfigure_waiters(&self, reservation: u64, outcome: BrowserResizeOutcome) {
        let waiters =
            self.state.lock().unwrap().reconfigure_waiters.remove(&reservation).unwrap_or_default();
        for waiter in waiters {
            let _ = waiter.send(outcome.clone());
        }
    }

    fn confirm_reconfigure(&self, queued: QueuedBrowserGeometry, frame_epoch: u64) {
        let mut state = self.state.lock().unwrap();
        let Some(index) =
            state.pending_reconfigures.iter().position(|pending| pending.id == queued.id)
        else {
            return;
        };
        state.pending_reconfigures.remove(index);
        let geometry = queued.geometry;
        let changed = browser_geometry_locked(&state) != geometry;
        state.reconfigure_failure = None;
        state.size = geometry.size;
        state.pane_pixels = geometry.pane_pixels;
        state.capture_pixels = geometry.capture_pixels;
        state.capture_scale = geometry.capture_scale;
        if changed {
            state.latest_frame = None;
            Self::set_pointer_frame_locked(&mut state, None);
            self.set_pending_attach_frame_locked(&mut state, None);
            state.page_viewport = None;
            state.live_since = Some(Instant::now());
            state.last_frame_at = None;
            state.stall_nudged = false;
        }
        if frame_epoch >= state.accepted_frame_epoch
            && state.pending_frame_epoch.is_none_or(|pending_epoch| frame_epoch >= pending_epoch)
        {
            let accepted_navigation_epoch = state.accepted_navigation_epoch;
            self.accept_frame_epoch_locked(&mut state, frame_epoch, accepted_navigation_epoch);
        }
        self.mark_state_dirty_locked(&mut state);
    }

    fn fail_reconfigure(&self, queued: QueuedBrowserGeometry) -> Option<(u8, Option<Duration>)> {
        let mut state = self.state.lock().unwrap();
        let index =
            state.pending_reconfigures.iter().position(|pending| pending.id == queued.id)?;
        state.pending_reconfigures.remove(index);
        let geometry = queued.geometry;
        let attempts = state
            .reconfigure_failure
            .filter(|failure| failure.geometry == geometry)
            .map_or(1, |failure| failure.attempts.saturating_add(1));
        let retry_delay = BROWSER_RECONFIGURE_RETRY_DELAYS.get(usize::from(attempts - 1)).copied();
        state.reconfigure_failure = Some(BrowserReconfigureFailure {
            geometry,
            attempts,
            retry_at: retry_delay.map(|delay| Instant::now() + delay),
        });
        if retry_delay.is_none() && state.pending_reconfigures.is_empty() {
            state.pending_frame_epoch = None;
            state.pending_navigation_epoch = None;
            state.pending_document_epoch = None;
            state.pending_same_document_navigation = false;
            state.pending_failure_recovery = false;
            state.pending_frame = None;
            state.pending_navigation_rollback = None;
            self.mark_failed_locked(
                &mut state,
                BrowserFailureKind::ResizeRecovery,
                BROWSER_RESIZE_RECOVERY_FAILED_MESSAGE,
            );
            self.mark_state_dirty_locked(&mut state);
            self.dirty.store(true, Ordering::Release);
        }
        Some((attempts, retry_delay))
    }

    fn release_reconfigure(&self, queued: QueuedBrowserGeometry) {
        let waiters = {
            let mut state = self.state.lock().unwrap();
            if let Some(index) =
                state.pending_reconfigures.iter().position(|pending| pending.id == queued.id)
            {
                state.pending_reconfigures.remove(index);
            }
            state.reconfigure_waiters.remove(&queued.id).unwrap_or_default()
        };
        for waiter in waiters {
            let _ = waiter.send(Err(Arc::from("browser resize was rejected before execution")));
        }
    }

    fn reconfigure_blocking(
        &self,
        width: u32,
        height: u32,
    ) -> Result<(u64, BrowserWorkerSuccess), BrowserReconfigureCommandError> {
        let Some(session) = self.attached_session().map_err(|error| {
            BrowserReconfigureCommandError { error, definitely_unchanged: true }
        })?
        else {
            return Ok((self.frame_epoch.advance(), BrowserWorkerSuccess::LocallySettled));
        };
        if let Err(error) =
            session.runtime.client.set_device_metrics(&session.session_id, width, height)
        {
            let definitely_unchanged = !is_cdp_timeout_error(&error.to_string());
            return Err(BrowserReconfigureCommandError { error, definitely_unchanged });
        }
        let _ = session.runtime.client.stop_screencast(&session.session_id);
        session
            .runtime
            .client
            .start_screencast_with_frame_barrier(&session.session_id, width, height)
            .map(|frame_epoch| (frame_epoch, BrowserWorkerSuccess::BrowserResponded))
            .map_err(|error| BrowserReconfigureCommandError { error, definitely_unchanged: false })
    }

    pub(crate) fn resize_needed(&self, cols: u16, rows: u16) -> bool {
        let geometry = self.resize_geometry(cols, rows);
        let mut state = self.state.lock().unwrap();
        if state.reconfigure_failure.is_some_and(|failure| failure.geometry != geometry) {
            state.reconfigure_failure = None;
        }
        if state.pending_reconfigures.back().is_some_and(|queued| queued.geometry == geometry) {
            return false;
        }
        if let Some(failure) = state.reconfigure_failure
            && failure.geometry == geometry
            && failure.retry_at.is_none_or(|retry_at| Instant::now() < retry_at)
        {
            return false;
        }
        browser_geometry_locked(&state) != geometry || !state.pending_reconfigures.is_empty()
    }

    fn resize_geometry(&self, cols: u16, rows: u16) -> BrowserGeometry {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let cell = *self.cell_pixels.lock().unwrap();
        let pixel_w = cols as u32 * cell.0.max(1) as u32;
        let pixel_h = rows as u32 * cell.1.max(1) as u32;
        let capture_scale = capture_scale_for(pixel_w, pixel_h, self.capture_options);
        let capture_pixels = scaled_pixels(pixel_w, pixel_h, capture_scale);
        BrowserGeometry {
            size: (cols, rows),
            pane_pixels: (pixel_w, pixel_h),
            capture_pixels,
            capture_scale,
        }
    }

    pub fn attach_frames(&self) -> (BrowserAttachState, BrowserFrameStream) {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(BrowserAttachUpdate::default()));
        let mut state = self.state.lock().unwrap();
        let pointer_frame_floor_seq = self.exported_pointer_frame_floor_seq_locked(&state);
        let pointer_frame_seq = self.exported_pointer_frame_seq_locked(&state);
        let snapshot = browser_attach_state_locked(
            &state,
            Instant::now(),
            self.is_dead(),
            true,
            pointer_frame_floor_seq,
            pointer_frame_seq,
        );
        if !self.is_dead() {
            state.taps.push(BrowserFrameTap { slot: slot.clone(), notify: tx });
        }
        (snapshot, BrowserFrameStream { slot, notify: rx })
    }

    #[cfg(test)]
    fn store_frame(&self, frame: BrowserFrame) {
        self.store_frame_for_epoch(frame, self.frame_epoch.current());
    }

    fn store_frame_for_epoch(&self, frame: BrowserFrame, frame_epoch: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        if let Some(pending_epoch) = state.pending_frame_epoch {
            if frame_epoch >= pending_epoch
                && state
                    .pending_frame
                    .as_ref()
                    .is_none_or(|(retained_epoch, _)| frame_epoch >= *retained_epoch)
            {
                state.pending_frame = Some((frame_epoch, frame));
            }
            return false;
        }
        if frame_epoch > state.accepted_frame_epoch {
            if state
                .pending_frame
                .as_ref()
                .is_none_or(|(retained_epoch, _)| frame_epoch >= *retained_epoch)
            {
                state.pending_frame = Some((frame_epoch, frame));
            }
            return false;
        }
        if frame_epoch < state.accepted_frame_epoch {
            return false;
        }
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.frame_epoch == frame_epoch)
        {
            state.pending_screencast_capture = None;
        }
        if state.failed_screencast_capture_epoch == Some(frame_epoch) {
            state.failed_screencast_capture_epoch = None;
        }
        self.store_frame_locked(&mut state, frame);
        true
    }

    fn store_frame_locked(&self, state: &mut BrowserState, mut frame: BrowserFrame) {
        // Screencast frames keep streaming the previous page after a
        // failed navigation; they must not mask that failure. A fresh
        // frame does prove Chrome recovered from the worker's
        // not-responding state, so clear only that class here.
        let clears_not_responding = state.failure_kind == Some(BrowserFailureKind::NotResponding);
        if !matches!(state.status, BrowserStatus::Failed(_)) || clears_not_responding {
            state.status = BrowserStatus::Live;
            if clears_not_responding {
                state.failure_kind = None;
                state.not_responding_reported = false;
                // `mark_failed` overwrote the title with "browser failed: ..."
                // and broadcast the failure to attach clients. Recovering only
                // in-memory would leave remote TUIs stuck on the failed
                // status/title even as fresh frames arrive. Restore a non-failed
                // title from the retained URL (the next CDP title event refines
                // it) and broadcast the recovered state to attach clients the
                // same way the failure was broadcast.
                //
                // Do NOT set `self.dirty` here: the caller that delivers this
                // frame emits `SurfaceOutput` via `if !dirty.swap(true)`, which
                // is what redraws the local TUI. Pre-setting `dirty` would
                // consume that transition and suppress the local recovery
                // redraw, leaving the local status line stuck on the failure.
                state.title = state.url.clone();
            }
        }
        frame.seq = state.next_frame_seq;
        state.next_frame_seq = state.next_frame_seq.saturating_add(1);
        state.last_frame_at = Some(Instant::now());
        state.stall_nudged = false;
        let page_viewport = (frame.css_width.max(1), frame.css_height.max(1));
        let pointer_geometry_changed =
            state.page_viewport.is_some_and(|previous| previous != page_viewport);
        if pointer_geometry_changed {
            state.pointer_motion_generation = state.pointer_motion_generation.wrapping_add(1);
        }
        state.page_viewport = Some(page_viewport);
        let can_authorize_pointer = matches!(state.status, BrowserStatus::Live)
            && state.pending_navigation_epoch.is_none()
            && state.pending_document_epoch.is_none()
            && !state.pending_same_document_navigation;
        let pointer_frame_seq = can_authorize_pointer.then_some(frame.seq);
        if pointer_geometry_changed {
            Self::set_pointer_frame_locked(state, pointer_frame_seq);
        } else if state.pointer_frame_seq != pointer_frame_seq {
            Self::advance_pointer_frame_locked(state, pointer_frame_seq);
        }
        if clears_not_responding {
            self.mark_state_dirty_locked(state);
        }
        let frame = Arc::new(frame);
        state.latest_frame = Some(frame.clone());
        let update = BrowserFrameUpdate {
            frame: frame.as_ref().clone(),
            status: state.status.clone(),
            pointer_frame_floor_seq: self.exported_pointer_frame_floor_seq_locked(state),
            pointer_frame_seq: self.exported_pointer_frame_seq_locked(state),
        };
        let attach_state = browser_attach_state_locked(
            state,
            Instant::now(),
            false,
            false,
            update.pointer_frame_floor_seq,
            update.pointer_frame_seq,
        );
        state.taps.retain(|tap| {
            let mut slot = tap.slot.lock().unwrap();
            slot.frame = Some(update.clone());
            if slot.state.is_some() {
                slot.state = Some(attach_state.clone());
            }
            drop(slot);
            match tap.notify.try_send(()) {
                Ok(()) | Err(TrySendError::Full(())) => true,
                Err(TrySendError::Disconnected(())) => false,
            }
        });
    }

    fn reconcile_navigation_capture_locked(state: &mut BrowserState, navigation_epoch: u64) {
        if navigation_epoch > state.accepted_navigation_epoch {
            state.accepted_navigation_epoch = navigation_epoch;
            state.pointer_capture_generation = state.pointer_capture_generation.wrapping_add(1);
        }
    }

    fn accept_frame_epoch_locked(
        &self,
        state: &mut BrowserState,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) {
        if frame_epoch < state.accepted_frame_epoch {
            return;
        }
        Self::reconcile_navigation_capture_locked(state, navigation_epoch);
        state.accepted_frame_epoch = frame_epoch;
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.frame_epoch <= frame_epoch)
        {
            state.pending_screencast_capture = None;
        }
        if state.failed_screencast_capture_epoch == Some(frame_epoch) {
            state.failed_screencast_capture_epoch = None;
        }
        if state.pending_frame_epoch.is_some_and(|pending_epoch| frame_epoch >= pending_epoch) {
            state.pending_frame_epoch = None;
        }
        let pending = match state.pending_frame.take() {
            Some((pending_epoch, frame)) if pending_epoch == frame_epoch => Some(frame),
            newer @ Some((pending_epoch, _)) if pending_epoch > frame_epoch => {
                state.pending_frame = newer;
                None
            }
            _ => None,
        };
        if let Some(frame) = pending {
            self.store_frame_locked(state, frame);
        }
    }

    fn close_taps(&self) {
        self.state.lock().unwrap().taps.clear();
    }

    fn mark_live(&self, session: BrowserSession) -> anyhow::Result<()> {
        let mut current_session = self.session.lock().unwrap();
        if self.is_dead() {
            anyhow::bail!("browser surface was closed before it started");
        }
        *current_session = Some(session);
        let mut state = self.state.lock().unwrap();
        state.source = current_session.as_ref().map(|session| session.runtime.source());
        if !matches!(state.status, BrowserStatus::Failed(_)) {
            state.status = BrowserStatus::Live;
            state.failure_kind = None;
        }
        let now = Instant::now();
        state.live_since = Some(now);
        state.last_frame_at = None;
        state.stall_nudged = false;
        self.mark_state_dirty_locked(&mut state);
        Ok(())
    }

    fn mark_failed_locked(
        &self,
        state: &mut BrowserState,
        kind: BrowserFailureKind,
        message: &str,
    ) {
        state.status = BrowserStatus::Failed(message.to_string());
        state.failure_kind = Some(kind);
        // Failure revokes admission for new input, but does not always prove
        // that the document or its coordinate mapping changed. Preserve an
        // accepted press long enough to deliver its balancing release.
        self.invalidate_pointer_frame_locked(state, false);
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        state.pending_screencast_capture = None;
        state.title = format!("browser failed: {message}");
        state.stall_nudged = false;
    }

    fn mark_pending_authority_failed_locked(
        &self,
        state: &mut BrowserState,
        kind: BrowserFailureKind,
        message: &str,
    ) {
        state.status = BrowserStatus::Failed(message.to_string());
        state.failure_kind = Some(kind);
        // Keep the current navigation generation pending so a late
        // loader-verified paint can recover it without a manual reload.
        self.invalidate_pointer_frame_locked(state, false);
        state.pending_authority_deadline = None;
        state.pending_failure_recovery = true;
        state.title = format!("browser failed: {message}");
        state.stall_nudged = false;
    }

    pub fn mark_failed(&self, message: String) {
        let mut state = self.state.lock().unwrap();
        self.mark_failed_locked(&mut state, BrowserFailureKind::Other, &message);
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }

    fn mark_not_responding(&self) {
        let mut state = self.state.lock().unwrap();
        self.mark_failed_locked(
            &mut state,
            BrowserFailureKind::NotResponding,
            BROWSER_NOT_RESPONDING_MESSAGE,
        );
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }

    fn clear_error_locked(&self, state: &mut BrowserState) -> bool {
        if matches!(state.status, BrowserStatus::Failed(_)) {
            state.status = BrowserStatus::Live;
            state.failure_kind = None;
            // A verified paint from an explicit navigation or reload is the
            // recovery action for an exhausted resize. Let the desired
            // geometry enter a new bounded retry cycle only after that proof.
            state.reconfigure_failure = None;
            state.title = state.url.clone();
            return true;
        }
        false
    }

    #[cfg(test)]
    fn clear_error(&self) {
        let mut state = self.state.lock().unwrap();
        if self.clear_error_locked(&mut state) {
            self.mark_state_dirty_locked(&mut state);
        }
    }

    fn set_title(&self, title: String) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.title == title {
            return false;
        }
        state.title = title;
        self.mark_state_dirty_locked(&mut state);
        true
    }

    fn set_url(&self, url: String) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.url != url {
            state.url = url;
            self.mark_state_dirty_locked(&mut state);
            return true;
        }
        false
    }

    fn set_url_title(&self, url: String, title: String) {
        let mut state = self.state.lock().unwrap();
        state.url = url;
        state.title = title;
        state.stall_nudged = false;
        self.mark_state_dirty_locked(&mut state);
    }

    fn mark_state_dirty_locked(&self, state: &mut BrowserState) {
        let pointer_frame_floor_seq = self.exported_pointer_frame_floor_seq_locked(state);
        let pointer_frame_seq = self.exported_pointer_frame_seq_locked(state);
        let snapshot = browser_attach_state_locked(
            state,
            Instant::now(),
            false,
            false,
            pointer_frame_floor_seq,
            pointer_frame_seq,
        );
        state.taps.retain(|tap| {
            let mut slot = tap.slot.lock().unwrap();
            if let Some(frame) = slot.frame.as_mut() {
                frame.status = snapshot.status.clone();
                frame.pointer_frame_floor_seq = snapshot.pointer_frame_floor_seq;
                frame.pointer_frame_seq = snapshot.pointer_frame_seq;
            }
            slot.state = Some(snapshot.clone());
            drop(slot);
            match tap.notify.try_send(()) {
                Ok(()) | Err(TrySendError::Full(())) => true,
                Err(TrySendError::Disconnected(())) => false,
            }
        });
    }

    fn attached_session(&self) -> anyhow::Result<Option<BrowserSession>> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        Ok(self.session.lock().unwrap().clone())
    }

    fn require_attached_session(&self) -> anyhow::Result<BrowserSession> {
        self.attached_session()?.ok_or_else(|| anyhow::anyhow!("browser is still starting"))
    }

    fn require_live_session(&self) -> anyhow::Result<BrowserSession> {
        let session = self.require_attached_session()?;
        match self.status() {
            BrowserStatus::Live => Ok(session),
            BrowserStatus::Starting => anyhow::bail!("browser is still starting"),
            BrowserStatus::Failed(error) => anyhow::bail!("browser failed: {error}"),
        }
    }

    fn require_navigation_session(&self) -> anyhow::Result<BrowserSession> {
        let session = self.require_attached_session()?;
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Live)
            || state.failure_kind.is_some_and(BrowserFailureKind::allows_navigation_recovery)
        {
            return Ok(session);
        }
        match &state.status {
            BrowserStatus::Starting => anyhow::bail!("browser is still starting"),
            BrowserStatus::Failed(error) => anyhow::bail!("browser failed: {error}"),
            BrowserStatus::Live => unreachable!(),
        }
    }

    fn require_verification_session(&self) -> anyhow::Result<BrowserSession> {
        let session = self.require_attached_session()?;
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Live)
            || state.pending_failure_recovery
                && state.failure_kind.is_some_and(BrowserFailureKind::allows_navigation_recovery)
        {
            return Ok(session);
        }
        match &state.status {
            BrowserStatus::Starting => anyhow::bail!("browser is still starting"),
            BrowserStatus::Failed(error) => anyhow::bail!("browser failed: {error}"),
            BrowserStatus::Live => unreachable!(),
        }
    }

    fn frames_stalled_at(&self, now: Instant) -> bool {
        let state = self.state.lock().unwrap();
        frames_stalled_locked(&state, now, self.is_dead())
    }

    fn scale_input_point_locked(state: &BrowserState, x: f64, y: f64) -> (f64, f64) {
        let (pane_width, pane_height) = state.pane_pixels;
        let (page_width, page_height) = state.page_viewport.unwrap_or(state.capture_pixels);
        let page_width = page_width.max(1);
        let page_height = page_height.max(1);
        let x = x / f64::from(pane_width.max(1)) * f64::from(page_width);
        let y = y / f64::from(pane_height.max(1)) * f64::from(page_height);
        (x.clamp(0.0, f64::from(page_width)), y.clamp(0.0, f64::from(page_height)))
    }

    #[cfg(test)]
    fn scale_input_point(&self, x: f64, y: f64) -> (f64, f64) {
        Self::scale_input_point_locked(&self.state.lock().unwrap(), x, y)
    }

    fn pointer_epoch_is_current_locked(&self, state: &BrowserState) -> bool {
        state.pending_frame_epoch.is_none()
            && state.pending_navigation_epoch.is_none()
            && state.pending_document_epoch.is_none()
            && !state.pending_same_document_navigation
            && state.accepted_frame_epoch == self.frame_epoch.current()
            && state.accepted_navigation_epoch == self.frame_epoch.latest_navigation()
            && state.handled_same_document_navigation_epoch
                == self.frame_epoch.latest_same_document_navigation()
    }

    fn exported_pointer_frame_seq_locked(&self, state: &BrowserState) -> Option<u64> {
        self.pointer_epoch_is_current_locked(state).then_some(state.pointer_frame_seq).flatten()
    }

    fn exported_pointer_frame_floor_seq_locked(&self, state: &BrowserState) -> Option<u64> {
        self.pointer_epoch_is_current_locked(state)
            .then_some(state.pointer_frame_floor_seq)
            .flatten()
    }

    fn pointer_frame_is_in_current_route_locked(
        &self,
        state: &BrowserState,
        frame_seq: u64,
    ) -> bool {
        let Some((floor, latest)) = state.pointer_frame_floor_seq.zip(state.pointer_frame_seq)
        else {
            return false;
        };
        self.pointer_epoch_is_current_locked(state) && (floor..=latest).contains(&frame_seq)
    }

    fn presented_pointer_frame_is_current_locked(
        &self,
        state: &BrowserState,
        owner: BrowserPointerOwner,
        frame_seq: u64,
    ) -> bool {
        state.presented_pointer_frames.get(&owner) == Some(&frame_seq)
            && self.pointer_frame_is_in_current_route_locked(state, frame_seq)
    }

    fn acknowledge_pointer_frame_locked(
        &self,
        state: &mut BrowserState,
        owner: BrowserPointerOwner,
        frame_seq: u64,
    ) -> bool {
        if !self.pointer_frame_is_in_current_route_locked(state, frame_seq)
            || state
                .presented_pointer_frames
                .get(&owner)
                .is_some_and(|presented| *presented > frame_seq)
        {
            return false;
        }
        state.presented_pointer_frames.insert(owner, frame_seq);
        true
    }

    fn admit_pointer_frame(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: Option<u64>,
    ) -> Option<BrowserPointerAdmission> {
        let mut state = self.state.lock().unwrap();
        let admitted = match frame_seq {
            Some(frame_seq) => self.acknowledge_pointer_frame_locked(&mut state, owner, frame_seq),
            None => {
                state.pointer_frame_seq.is_some() && self.pointer_epoch_is_current_locked(&state)
            }
        };
        admitted.then_some(BrowserPointerAdmission { owner, frame_seq })
    }

    fn pointer_guard_is_current_locked(
        &self,
        state: &BrowserState,
        owner: BrowserPointerOwner,
        frame_seq: Option<u64>,
        pointer_admission: Option<BrowserPointerAdmission>,
    ) -> bool {
        if pointer_admission != Some(BrowserPointerAdmission { owner, frame_seq }) {
            return false;
        }
        match frame_seq {
            Some(frame_seq) => self.pointer_frame_is_in_current_route_locked(state, frame_seq),
            None => {
                state.pointer_frame_seq.is_some() && self.pointer_epoch_is_current_locked(state)
            }
        }
    }

    fn scale_guarded_input_point_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: Option<u64>,
        pointer_admission: Option<BrowserPointerAdmission>,
        x: f64,
        y: f64,
    ) -> Option<(f64, f64)> {
        let state = self.state.lock().unwrap();
        if !self.pointer_guard_is_current_locked(&state, owner, frame_seq, pointer_admission) {
            return None;
        }
        Some(Self::scale_input_point_locked(&state, x, y))
    }

    #[cfg(test)]
    fn scale_guarded_input_point(
        &self,
        frame_seq: Option<u64>,
        x: f64,
        y: f64,
    ) -> Option<(f64, f64)> {
        let admitted = frame_seq.is_none_or(|frame_seq| {
            let state = self.state.lock().unwrap();
            self.presented_pointer_frame_is_current_locked(
                &state,
                BrowserPointerOwner::Local,
                frame_seq,
            )
        });
        let pointer_admission = admitted
            .then_some(BrowserPointerAdmission { owner: BrowserPointerOwner::Local, frame_seq });
        self.scale_guarded_input_point_from(
            BrowserPointerOwner::Local,
            frame_seq,
            pointer_admission,
            x,
            y,
        )
    }

    fn capture_guarded_input_point_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: u64,
        pointer_admission: Option<BrowserPointerAdmission>,
        x: f64,
        y: f64,
    ) -> Option<((f64, f64), u64, u64, u64)> {
        let ingress_motion_generation = self.frame_epoch.pointer_motion_generation();
        let state = self.state.lock().unwrap();
        if !ingress_motion_generation.is_multiple_of(2)
            || !self.pointer_guard_is_current_locked(
                &state,
                owner,
                Some(frame_seq),
                pointer_admission,
            )
            || ingress_motion_generation != self.frame_epoch.pointer_motion_generation()
        {
            return None;
        }
        Some((
            Self::scale_input_point_locked(&state, x, y),
            state.pointer_capture_generation,
            state.pointer_motion_generation,
            ingress_motion_generation,
        ))
    }

    #[cfg(test)]
    fn capture_guarded_input_point(
        &self,
        frame_seq: u64,
        x: f64,
        y: f64,
    ) -> Option<((f64, f64), u64, u64, u64)> {
        let admitted = {
            let state = self.state.lock().unwrap();
            self.presented_pointer_frame_is_current_locked(
                &state,
                BrowserPointerOwner::Local,
                frame_seq,
            )
        };
        let pointer_admission = admitted.then_some(BrowserPointerAdmission {
            owner: BrowserPointerOwner::Local,
            frame_seq: Some(frame_seq),
        });
        self.capture_guarded_input_point_from(
            BrowserPointerOwner::Local,
            frame_seq,
            pointer_admission,
            x,
            y,
        )
    }

    #[cfg(test)]
    fn scale_captured_input_point(
        &self,
        capture_generation: u64,
        x: f64,
        y: f64,
    ) -> Option<(f64, f64)> {
        let state = self.state.lock().unwrap();
        if state.pointer_capture_generation != capture_generation
            || state.accepted_navigation_epoch != self.frame_epoch.latest_navigation()
        {
            return None;
        }
        Some(Self::scale_input_point_locked(&state, x, y))
    }

    fn captured_pointer_route(
        &self,
        capture_generation: u64,
        motion_generation: u64,
        ingress_motion_generation: u64,
        frame_seq: u64,
        dispatch_frame_seq: u64,
        point: (f64, f64),
    ) -> CapturedPointerRoute {
        let state = self.state.lock().unwrap();
        if state.pointer_capture_generation != capture_generation
            || state.accepted_navigation_epoch != self.frame_epoch.latest_navigation()
        {
            return CapturedPointerRoute::InvalidCapture;
        }
        if state.pointer_motion_generation != motion_generation
            || self.frame_epoch.pointer_motion_generation() != ingress_motion_generation
            || dispatch_frame_seq != frame_seq
        {
            return CapturedPointerRoute::MotionInvalidated;
        }
        CapturedPointerRoute::Current(Self::scale_input_point_locked(&state, point.0, point.1))
    }

    fn pointer_capture_is_current(&self, capture_generation: u64) -> bool {
        let state = self.state.lock().unwrap();
        state.pointer_capture_generation == capture_generation
            && state.accepted_navigation_epoch == self.frame_epoch.latest_navigation()
    }

    fn set_pointer_frame_range_locked(
        state: &mut BrowserState,
        floor: Option<u64>,
        latest: Option<u64>,
    ) {
        debug_assert_eq!(floor.is_some(), latest.is_some());
        debug_assert!(floor.zip(latest).is_none_or(|(floor, latest)| floor <= latest));
        state.pointer_frame_floor_seq = floor;
        state.pointer_frame_seq = latest;
        state.pointer_frame_revision = state.pointer_frame_revision.wrapping_add(1);
    }

    fn set_pointer_frame_locked(state: &mut BrowserState, frame_seq: Option<u64>) {
        Self::set_pointer_frame_range_locked(state, frame_seq, frame_seq);
        state.presented_pointer_frames.clear();
    }

    fn advance_pointer_frame_locked(state: &mut BrowserState, frame_seq: Option<u64>) {
        let floor = frame_seq.and(state.pointer_frame_floor_seq.or(frame_seq));
        Self::set_pointer_frame_range_locked(state, floor, frame_seq);
    }

    fn set_pending_attach_frame_locked(
        &self,
        state: &mut BrowserState,
        frame: Option<Arc<BrowserFrame>>,
    ) {
        let update = frame.map(|frame| BrowserFrameUpdate {
            frame: frame.as_ref().clone(),
            status: state.status.clone(),
            pointer_frame_floor_seq: self.exported_pointer_frame_floor_seq_locked(state),
            pointer_frame_seq: self.exported_pointer_frame_seq_locked(state),
        });
        for tap in &state.taps {
            tap.slot.lock().unwrap().frame = update.clone();
        }
    }

    fn invalidate_pointer_frame_locked(
        &self,
        state: &mut BrowserState,
        revoke_capture: bool,
    ) -> PointerFrameInvalidation {
        let previous = state.pointer_frame_seq;
        let previous_floor = state.pointer_frame_floor_seq;
        let previous_presented_pointer_frames = state.presented_pointer_frames.clone();
        let previous_latest_frame_seq = state.latest_frame.as_ref().map(|frame| frame.seq);
        let previous_capture_generation = state.pointer_capture_generation;
        let previous_motion_generation = state.pointer_motion_generation;
        let previous_pending_frame_epoch = state.pending_frame_epoch;
        let previous_pending_navigation_epoch = state.pending_navigation_epoch;
        let previous_pending_authority_deadline = state.pending_authority_deadline;
        let previous_pending_same_document_navigation = state.pending_same_document_navigation;
        let previous_accepted_navigation_epoch = state.accepted_navigation_epoch;
        let previous_pending_frame = state.pending_frame.clone();
        Self::set_pointer_frame_locked(state, None);
        self.set_pending_attach_frame_locked(state, None);
        state.pending_screencast_capture = None;
        state.pointer_motion_generation = state.pointer_motion_generation.wrapping_add(1);
        if revoke_capture {
            state.pointer_capture_generation = state.pointer_capture_generation.wrapping_add(1);
        }
        PointerFrameInvalidation {
            previous,
            previous_floor,
            previous_presented_pointer_frames,
            previous_latest_frame_seq,
            previous_capture_generation,
            previous_motion_generation,
            previous_pending_frame_epoch,
            previous_pending_navigation_epoch,
            previous_pending_authority_deadline,
            previous_pending_same_document_navigation,
            previous_accepted_navigation_epoch,
            previous_pending_frame,
            revision: state.pointer_frame_revision,
            expected_frame_epoch: None,
        }
    }

    #[cfg(test)]
    fn invalidate_pointer_frame(&self) -> PointerFrameInvalidation {
        self.begin_frame_transition(true)
    }

    #[cfg(test)]
    fn begin_navigation_frame_transition(&self) -> anyhow::Result<PointerFrameInvalidation> {
        self.begin_navigation_frame_transition_to(false)
    }

    #[cfg(test)]
    fn begin_targeted_navigation_frame_transition(
        &self,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        self.begin_navigation_frame_transition_to(true)
    }

    fn begin_navigation_frame_transition_to(
        &self,
        may_be_same_document: bool,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        let mut state = self.state.lock().unwrap();
        if state.pending_frame_epoch.is_some()
            || state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
        {
            anyhow::bail!("browser navigation is still committing");
        }
        Ok(self.reserve_navigation_frame_transition_locked(&mut state, may_be_same_document))
    }

    fn reserve_navigation_frame_transition_locked(
        &self,
        state: &mut BrowserState,
        may_be_same_document: bool,
    ) -> PointerFrameInvalidation {
        // A targeted navigation can resolve within the current document. Keep
        // an accepted press alive until ingress proves a document replacement.
        let invalidation = self.invalidate_pointer_frame_locked(state, !may_be_same_document);
        self.install_navigation_frame_transition_locked(state, may_be_same_document, invalidation)
    }

    fn install_navigation_frame_transition_locked(
        &self,
        state: &mut BrowserState,
        may_be_same_document: bool,
        mut invalidation: PointerFrameInvalidation,
    ) -> PointerFrameInvalidation {
        let pending_frame_epoch = self.frame_epoch.current().wrapping_add(1);
        state.pending_frame_epoch = Some(pending_frame_epoch);
        state.pending_navigation_epoch = Some(pending_frame_epoch);
        state.pending_authority_deadline = Some(Instant::now() + NAVIGATION_AUTHORITY_TIMEOUT);
        state.pending_same_document_navigation = may_be_same_document;
        state.pending_failure_recovery =
            state.failure_kind.is_some_and(BrowserFailureKind::allows_navigation_recovery);
        state.pending_frame = None;
        invalidation.expected_frame_epoch = Some(pending_frame_epoch);
        state.pending_navigation_rollback = Some(invalidation.clone());
        self.mark_state_dirty_locked(state);
        invalidation
    }

    fn navigation_transition_pending(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
            || state.pending_same_document_navigation
    }

    fn begin_superseding_navigation_frame_transition(
        &self,
        may_be_same_document: bool,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        let mut state = self.state.lock().unwrap();
        let navigation_pending = state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
            || state.pending_same_document_navigation;
        if !navigation_pending && state.pending_frame_epoch.is_some() {
            anyhow::bail!("browser frame reconfiguration is still committing");
        }
        let current_frame_epoch = self.frame_epoch.current();
        let preserved_rollback = may_be_same_document
            .then(|| {
                state.pending_navigation_rollback.as_ref().filter(|rollback| {
                    state.pending_document_epoch.is_none()
                        && rollback.revision == state.pointer_frame_revision
                        && rollback
                            .expected_frame_epoch
                            .is_some_and(|expected_epoch| current_frame_epoch < expected_epoch)
                        && state.latest_frame.as_ref().map(|frame| frame.seq)
                            == rollback.previous_latest_frame_seq
                })
            })
            .flatten()
            .cloned();
        let verified_committed_frame_seq = (state.pending_document_epoch.is_none()
            && matches!(state.status, BrowserStatus::Live)
            && state.accepted_navigation_epoch == self.frame_epoch.latest_navigation()
            && state.accepted_frame_epoch == current_frame_epoch)
            .then(|| state.latest_frame.as_ref().map(|frame| frame.seq))
            .flatten();
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        if preserved_rollback.is_none()
            && let Some(frame_seq) = verified_committed_frame_seq
        {
            // stopLoading settled the command that kept this verified document
            // behind its barrier. Reinstall its pointer token before the
            // replacement invalidates it, so a rejected replacement can roll
            // back to the pixels that are actually displayed.
            Self::set_pointer_frame_locked(&mut state, Some(frame_seq));
            let retained_frame = state.latest_frame.clone();
            self.set_pending_attach_frame_locked(&mut state, retained_frame);
        }
        Ok(match preserved_rollback {
            Some(rollback) => {
                // Page.stopLoading is ordered after old lifecycle events on
                // this CDP session. An ingress epoch still below the old
                // reservation proves that navigation never committed, so the
                // replacement may retain the original rollback authority.
                self.install_navigation_frame_transition_locked(
                    &mut state,
                    may_be_same_document,
                    rollback,
                )
            }
            None => {
                self.reserve_navigation_frame_transition_locked(&mut state, may_be_same_document)
            }
        })
    }

    #[cfg(test)]
    fn begin_frame_transition(&self, revoke_capture: bool) -> PointerFrameInvalidation {
        let mut state = self.state.lock().unwrap();
        let pending_frame_epoch =
            state.pending_frame_epoch.unwrap_or_else(|| self.frame_epoch.current()).wrapping_add(1);
        let mut invalidation = self.invalidate_pointer_frame_locked(&mut state, revoke_capture);
        state.pending_frame_epoch = Some(pending_frame_epoch);
        state.pending_frame = None;
        invalidation.expected_frame_epoch = Some(pending_frame_epoch);
        self.mark_state_dirty_locked(&mut state);
        invalidation
    }

    fn begin_reconfigure_frame_transition(&self) -> PointerFrameInvalidation {
        let mut state = self.state.lock().unwrap();
        // A capture restart advances the shared ingress epoch exactly once on
        // success. A failed attempt advances it zero times, so every retry,
        // including one for replacement geometry, waits on current + 1.
        let pending_frame_epoch = self.frame_epoch.current().wrapping_add(1);
        let mut invalidation = self.invalidate_pointer_frame_locked(&mut state, false);
        state.pending_frame_epoch = Some(pending_frame_epoch);
        state.pending_frame = None;
        invalidation.expected_frame_epoch = Some(pending_frame_epoch);
        self.mark_state_dirty_locked(&mut state);
        invalidation
    }

    fn abandon_frame_transition(&self) {
        let mut state = self.state.lock().unwrap();
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
    }

    fn observe_navigation_frame_epoch(&self, frame_epoch: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        if frame_epoch <= state.handled_navigation_epoch {
            return false;
        }
        let latest_same_document_navigation = self.frame_epoch.latest_same_document_navigation();
        if latest_same_document_navigation < frame_epoch {
            // A later cross-document navigation supersedes any same-document
            // event that entered CDP first, even if the surface thread has not
            // consumed that older event yet.
            state.handled_same_document_navigation_epoch = latest_same_document_navigation;
        }
        let precedes_pending_command =
            state.pending_navigation_epoch.is_some_and(|pending_epoch| frame_epoch < pending_epoch);
        if precedes_pending_command && frame_epoch != self.frame_epoch.latest_navigation() {
            return false;
        }
        if precedes_pending_command {
            // CDP ingress already committed this document before the newer
            // command reserved its epoch. Retain that command's rollback and
            // barrier, but expose the committed document for loader-verified
            // paint. If the newer command fails, its rollback reconciles to
            // this document instead of restoring the older page.
            state.handled_navigation_epoch = frame_epoch;
            state.pending_document_epoch = Some(frame_epoch);
            state
                .pending_authority_deadline
                .get_or_insert_with(|| Instant::now() + NAVIGATION_AUTHORITY_TIMEOUT);
            self.mark_state_dirty_locked(&mut state);
            drop(state);
            self.wake_lifecycle_worker();
            return true;
        }
        if state.pending_navigation_epoch.is_none() {
            state.pending_failure_recovery = false;
        }
        let capture_revoked_at_command =
            state.pending_navigation_epoch.is_some() && !state.pending_same_document_navigation;
        state.handled_navigation_epoch = frame_epoch;
        if state.pending_navigation_epoch.is_some_and(|pending_epoch| frame_epoch >= pending_epoch)
        {
            state.pending_navigation_epoch = None;
        }
        state.pending_same_document_navigation = false;
        state.pending_navigation_rollback = None;
        self.invalidate_pointer_frame_locked(&mut state, !capture_revoked_at_command);
        state.pending_document_epoch = Some(frame_epoch);
        state.pending_authority_deadline = Some(Instant::now() + NAVIGATION_AUTHORITY_TIMEOUT);
        let pending_frame_epoch = state
            .pending_frame_epoch
            .unwrap_or(frame_epoch)
            .max(frame_epoch)
            .max(state.accepted_frame_epoch);
        state.pending_frame_epoch = Some(pending_frame_epoch);
        state.pending_frame = None;
        self.mark_state_dirty_locked(&mut state);
        drop(state);
        self.wake_lifecycle_worker();
        true
    }

    fn needs_document_paint(&self, navigation_epoch: u64) -> bool {
        self.state.lock().unwrap().pending_document_epoch == Some(navigation_epoch)
    }

    fn pending_authority_deadline(&self) -> Option<Instant> {
        self.state.lock().unwrap().pending_authority_deadline
    }

    fn expire_navigation_authority(&self, now: Instant) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        if state.pending_authority_deadline.is_none_or(|deadline| deadline > now) {
            return None;
        }
        let has_pending_authority = state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
            || state.pending_same_document_navigation;
        if !has_pending_authority {
            state.pending_authority_deadline = None;
            return None;
        }
        let same_document =
            state.pending_document_epoch.is_none() && state.pending_same_document_navigation;
        let detail = "navigation did not produce verifiable pixels before its safety deadline";
        let (kind, message) = if same_document {
            (
                BrowserFailureKind::UpdatedPageVerification,
                format!(
                    "{BROWSER_UPDATED_PAGE_VERIFICATION_FAILED_PREFIX}{detail}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
                ),
            )
        } else {
            (
                BrowserFailureKind::NewPageVerification,
                format!(
                    "{BROWSER_NEW_PAGE_VERIFICATION_FAILED_PREFIX}{detail}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
                ),
            )
        };
        self.mark_pending_authority_failed_locked(&mut state, kind, &message);
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
        Some(message)
    }

    fn screencast_capture_context_matches(
        &self,
        state: &BrowserState,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        matches!(state.status, BrowserStatus::Live)
            && state.pending_navigation_epoch.is_none()
            && state.pending_document_epoch.is_none()
            && !state.pending_same_document_navigation
            && state.accepted_navigation_epoch == navigation_epoch
            && self.frame_epoch.latest_navigation() == navigation_epoch
            && self.frame_epoch.current() == frame_epoch
            && state.accepted_frame_epoch <= frame_epoch
    }

    fn reserve_screencast_capture(
        &self,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        if !self.screencast_capture_context_matches(&state, frame_epoch, navigation_epoch)
            || state.pending_screencast_capture.is_some_and(|reservation| {
                reservation.frame_epoch == frame_epoch
                    && reservation.navigation_epoch == navigation_epoch
            })
            || state.failed_screencast_capture_epoch == Some(frame_epoch)
        {
            return false;
        }
        state.pending_screencast_capture = Some(ScreencastCaptureReservation {
            id: reservation_id,
            frame_epoch,
            navigation_epoch,
        });
        true
    }

    fn may_need_screencast_capture(
        &self,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        let state = self.state.lock().unwrap();
        self.screencast_capture_context_matches(&state, frame_epoch, navigation_epoch)
            && state.pending_screencast_capture
                == Some(ScreencastCaptureReservation {
                    id: reservation_id,
                    frame_epoch,
                    navigation_epoch,
                })
            && state.failed_screencast_capture_epoch != Some(frame_epoch)
    }

    fn cancel_screencast_capture(&self, reservation_id: u64) {
        let mut state = self.state.lock().unwrap();
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.id == reservation_id)
        {
            state.pending_screencast_capture = None;
        }
    }

    fn needs_same_document_paint(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.pending_document_epoch.is_none() && state.pending_same_document_navigation
    }

    fn reconcile_same_document_snapshot(&self, same_document_navigation_epoch: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        if same_document_navigation_epoch != self.frame_epoch.latest_same_document_navigation()
            || state.pending_document_epoch.is_some()
            || !state.pending_same_document_navigation
        {
            return false;
        }
        state.handled_same_document_navigation_epoch = same_document_navigation_epoch;
        true
    }

    fn observe_same_document_frame_epoch(&self, frame_epoch: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        if frame_epoch <= state.handled_same_document_navigation_epoch
            || frame_epoch != self.frame_epoch.latest_same_document_navigation()
            || state.pending_document_epoch.is_some()
            || state.pending_navigation_epoch.is_some() && !state.pending_same_document_navigation
            || !(matches!(state.status, BrowserStatus::Live)
                || state.pending_failure_recovery
                    && state
                        .failure_kind
                        .is_some_and(BrowserFailureKind::allows_navigation_recovery))
        {
            return false;
        }
        state.handled_same_document_navigation_epoch = frame_epoch;
        let already_pending = state.pending_same_document_navigation;
        if already_pending {
            // The ingress event proves the targeted command committed, so a
            // later command error cannot roll pointer authority back. Motion
            // was already invalidated when that command reserved its barrier.
            Self::set_pointer_frame_locked(&mut state, None);
            self.set_pending_attach_frame_locked(&mut state, None);
            state.pending_screencast_capture = None;
        } else {
            // Page-initiated history/hash changes have no preceding cmux
            // command. Establish the same fail-closed pixel barrier here while
            // preserving only an accepted press's balancing release.
            self.invalidate_pointer_frame_locked(&mut state, false);
            state.pending_failure_recovery = false;
        }
        state.pending_frame_epoch =
            Some(state.pending_frame_epoch.map_or(frame_epoch, |pending| pending.max(frame_epoch)));
        state.pending_navigation_epoch = None;
        state.pending_authority_deadline = Some(Instant::now() + NAVIGATION_AUTHORITY_TIMEOUT);
        state.pending_same_document_navigation = true;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        self.mark_state_dirty_locked(&mut state);
        drop(state);
        self.wake_lifecycle_worker();
        true
    }

    fn accept_document_paint(
        &self,
        navigation_epoch: u64,
        frame_epoch: u64,
        frame: BrowserFrame,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.pending_document_epoch != Some(navigation_epoch)
            || state.handled_navigation_epoch != navigation_epoch
            || self.frame_epoch.latest_navigation() != navigation_epoch
            || frame_epoch < navigation_epoch
        {
            return false;
        }
        let precedes_pending_command = state
            .pending_navigation_epoch
            .is_some_and(|pending_epoch| navigation_epoch < pending_epoch);
        let recovers_failure = state.pending_failure_recovery && !precedes_pending_command;
        state.pending_document_epoch = None;
        if !precedes_pending_command {
            state.pending_navigation_epoch = None;
            state.pending_authority_deadline = None;
            state.pending_same_document_navigation = false;
            state.pending_failure_recovery = false;
            state.pending_frame_epoch = None;
            state.pending_frame = None;
            state.pending_navigation_rollback = None;
        }
        state.accepted_navigation_epoch = navigation_epoch;
        state.accepted_frame_epoch = frame_epoch;
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.frame_epoch == frame_epoch)
        {
            state.pending_screencast_capture = None;
        }
        state.failed_screencast_capture_epoch = None;
        if recovers_failure {
            self.clear_error_locked(&mut state);
        }
        self.store_frame_locked(&mut state, frame);
        self.mark_state_dirty_locked(&mut state);
        true
    }

    fn accept_same_document_paint(&self, frame_epoch: u64, frame: BrowserFrame) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.pending_document_epoch.is_some()
            || !state.pending_same_document_navigation
            || state.handled_same_document_navigation_epoch
                != self.frame_epoch.latest_same_document_navigation()
            || state.accepted_navigation_epoch != self.frame_epoch.latest_navigation()
            || frame_epoch != self.frame_epoch.current()
        {
            return false;
        }
        let recovers_failure = state.pending_failure_recovery;
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        state.accepted_frame_epoch = frame_epoch;
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.frame_epoch == frame_epoch)
        {
            state.pending_screencast_capture = None;
        }
        state.failed_screencast_capture_epoch = None;
        if recovers_failure {
            self.clear_error_locked(&mut state);
        }
        self.store_frame_locked(&mut state, frame);
        self.mark_state_dirty_locked(&mut state);
        true
    }

    fn accept_screencast_capture(
        &self,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
        frame: BrowserFrame,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        let reservation =
            ScreencastCaptureReservation { id: reservation_id, frame_epoch, navigation_epoch };
        let reserved = state.pending_screencast_capture == Some(reservation);
        if !reserved
            || !matches!(state.status, BrowserStatus::Live)
            || state.pending_frame_epoch.is_some()
            || state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
            || state.pending_same_document_navigation
            || state.accepted_navigation_epoch != navigation_epoch
            || self.frame_epoch.latest_navigation() != navigation_epoch
            || self.frame_epoch.current() != frame_epoch
            || state.accepted_frame_epoch > frame_epoch
        {
            if reserved {
                state.pending_screencast_capture = None;
            }
            return false;
        }
        state.pending_frame = None;
        state.accepted_frame_epoch = frame_epoch;
        state.pending_screencast_capture = None;
        state.failed_screencast_capture_epoch = None;
        self.store_frame_locked(&mut state, frame);
        self.mark_state_dirty_locked(&mut state);
        true
    }

    fn suppress_failed_screencast_capture(
        &self,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
        error: &anyhow::Error,
    ) {
        let mut state = self.state.lock().unwrap();
        let reserved = state.pending_screencast_capture
            == Some(ScreencastCaptureReservation {
                id: reservation_id,
                frame_epoch,
                navigation_epoch,
            });
        if reserved {
            state.pending_screencast_capture = None;
        }
        if reserved
            && matches!(state.status, BrowserStatus::Live)
            && state.pending_navigation_epoch.is_none()
            && state.pending_document_epoch.is_none()
            && !state.pending_same_document_navigation
            && state.accepted_navigation_epoch == navigation_epoch
            && self.frame_epoch.latest_navigation() == navigation_epoch
            && self.frame_epoch.current() == frame_epoch
            && state.accepted_frame_epoch <= frame_epoch
        {
            state.failed_screencast_capture_epoch = Some(frame_epoch);
            self.mark_failed_locked(
                &mut state,
                BrowserFailureKind::UpdatedPageVerification,
                &format!(
                    "{BROWSER_UPDATED_PAGE_VERIFICATION_FAILED_PREFIX}{error}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
                ),
            );
            self.mark_state_dirty_locked(&mut state);
            self.dirty.store(true, Ordering::Release);
        }
    }

    fn fail_document_authority(&self, navigation_epoch: u64, error: &anyhow::Error) {
        let mut state = self.state.lock().unwrap();
        if state.pending_document_epoch != Some(navigation_epoch) {
            return;
        }
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        self.mark_failed_locked(
            &mut state,
            BrowserFailureKind::NewPageVerification,
            &format!(
                "{BROWSER_NEW_PAGE_VERIFICATION_FAILED_PREFIX}{error}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
            ),
        );
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }

    fn fail_same_document_authority(&self, error: &anyhow::Error) {
        let mut state = self.state.lock().unwrap();
        if state.pending_document_epoch.is_some() || !state.pending_same_document_navigation {
            return;
        }
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        self.mark_failed_locked(
            &mut state,
            BrowserFailureKind::UpdatedPageVerification,
            &format!(
                "{BROWSER_UPDATED_PAGE_VERIFICATION_FAILED_PREFIX}{error}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
            ),
        );
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }

    fn restore_pointer_frame_after_failed_command(&self, invalidation: PointerFrameInvalidation) {
        let mut state = self.state.lock().unwrap();
        let owns_navigation_rollback =
            state.pending_navigation_rollback.as_ref().is_some_and(|rollback| {
                rollback.revision == invalidation.revision
                    && rollback.expected_frame_epoch == invalidation.expected_frame_epoch
            });
        let committed_navigation_epoch = self.frame_epoch.latest_navigation();
        let committed_navigation_precedes_failed_command = owns_navigation_rollback
            && invalidation.expected_frame_epoch.is_some_and(|expected_epoch| {
                committed_navigation_epoch > invalidation.previous_accepted_navigation_epoch
                    && committed_navigation_epoch < expected_epoch
                    && state.handled_navigation_epoch >= committed_navigation_epoch
            });
        if committed_navigation_precedes_failed_command {
            state.pending_navigation_epoch = invalidation.previous_pending_navigation_epoch;
            if invalidation.previous_pending_navigation_epoch.is_some() {
                state.pending_authority_deadline = invalidation.previous_pending_authority_deadline;
            }
            state.pending_same_document_navigation =
                invalidation.previous_pending_same_document_navigation;
            state.pending_failure_recovery = false;
            state.pending_navigation_rollback = None;
            state.pointer_capture_generation = invalidation.previous_capture_generation;
            state.pointer_motion_generation = invalidation.previous_motion_generation;
            state.pending_frame = None;
            if state.accepted_navigation_epoch == committed_navigation_epoch {
                state.pointer_capture_generation =
                    invalidation.previous_capture_generation.wrapping_add(1);
                state.pointer_motion_generation =
                    invalidation.previous_motion_generation.wrapping_add(1);
                state.pending_frame_epoch = invalidation.previous_pending_frame_epoch;
                let pointer_frame_seq = matches!(state.status, BrowserStatus::Live)
                    .then(|| state.latest_frame.as_ref().map(|frame| frame.seq))
                    .flatten();
                Self::set_pointer_frame_locked(&mut state, pointer_frame_seq);
                let retained_frame = state.latest_frame.clone();
                self.set_pending_attach_frame_locked(&mut state, retained_frame);
            } else {
                state.pointer_motion_generation =
                    invalidation.previous_motion_generation.wrapping_add(1);
                state.pending_frame_epoch = state.pending_document_epoch.map(|navigation_epoch| {
                    self.frame_epoch.current().max(navigation_epoch).max(state.accepted_frame_epoch)
                });
                Self::set_pointer_frame_locked(&mut state, None);
                self.set_pending_attach_frame_locked(&mut state, None);
            }
            self.mark_state_dirty_locked(&mut state);
            return;
        }
        let restoring_failed_recovery = state.pending_failure_recovery
            && state.failure_kind.is_some_and(BrowserFailureKind::allows_navigation_recovery);
        if state.pointer_frame_revision != invalidation.revision
            || !(matches!(state.status, BrowserStatus::Live) || restoring_failed_recovery)
            || state.latest_frame.as_ref().map(|frame| frame.seq)
                != invalidation.previous_latest_frame_seq
        {
            if owns_navigation_rollback {
                state.pending_navigation_rollback = None;
                state.pending_failure_recovery = false;
            }
            return;
        }
        if owns_navigation_rollback {
            state.pending_navigation_rollback = None;
        }
        state.pointer_capture_generation = invalidation.previous_capture_generation;
        state.pointer_motion_generation = invalidation.previous_motion_generation;
        state.pending_frame_epoch = invalidation.previous_pending_frame_epoch;
        state.pending_navigation_epoch = invalidation.previous_pending_navigation_epoch;
        state.pending_authority_deadline = invalidation.previous_pending_authority_deadline;
        state.pending_same_document_navigation =
            invalidation.previous_pending_same_document_navigation;
        state.pending_failure_recovery = false;
        state.pending_frame = invalidation.previous_pending_frame;
        Self::set_pointer_frame_range_locked(
            &mut state,
            invalidation.previous_floor,
            invalidation.previous,
        );
        state.presented_pointer_frames = invalidation.previous_presented_pointer_frames;
        let retained_frame = state.latest_frame.clone();
        self.set_pending_attach_frame_locked(&mut state, retained_frame);
        self.mark_state_dirty_locked(&mut state);
    }

    #[cfg(test)]
    fn restore_pointer_frame_on_command_error<T>(
        &self,
        invalidation: PointerFrameInvalidation,
        result: anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        if let Err(error) = &result
            && !is_cdp_timeout_error(&error.to_string())
        {
            self.restore_pointer_frame_after_failed_command(invalidation);
        }
        result
    }

    fn settle_navigation_transition(&self, invalidation: PointerFrameInvalidation) {
        let Some(expected_frame_epoch) = invalidation.expected_frame_epoch else {
            return;
        };
        // Command acknowledgment does not mean the document committed. The
        // ingress navigation event owns this barrier and may arrive after the
        // short synchronous wait on a slow page.
        let _ = self.frame_epoch.wait_until_at_least(expected_frame_epoch, NAVIGATION_COMMIT_WAIT);
    }

    fn finish_navigation_command<T>(
        &self,
        invalidation: PointerFrameInvalidation,
        result: anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        match &result {
            Ok(_) => self.settle_navigation_transition(invalidation),
            // The command may already have reached Chrome. Only a later
            // main-frame event can safely settle this ambiguous transition.
            Err(error) if is_cdp_timeout_error(&error.to_string()) => {}
            Err(_) => self.restore_pointer_frame_after_failed_command(invalidation),
        }
        result
    }

    fn scale_delta_locked(state: &BrowserState, delta: f64) -> f64 {
        if let Some((_, page_height)) = state.page_viewport {
            delta * f64::from(page_height.max(1)) / f64::from(state.pane_pixels.1.max(1))
        } else {
            delta * state.capture_scale
        }
    }

    #[cfg(test)]
    fn scale_delta(&self, delta: f64) -> f64 {
        Self::scale_delta_locked(&self.state.lock().unwrap(), delta)
    }

    #[cfg(test)]
    fn scale_guarded_wheel_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: Option<u64>,
        pointer_admission: Option<BrowserPointerAdmission>,
        x: f64,
        y: f64,
        delta_y: f64,
    ) -> Option<(f64, f64, f64)> {
        self.scale_guarded_wheel_2d_from(
            BrowserWheelDispatch { input_owner: owner, x, y, delta_x: 0.0, delta_y, frame_seq },
            pointer_admission,
        )
        .map(|(x, y, _, delta_y)| (x, y, delta_y))
    }

    fn scale_guarded_wheel_2d_from(
        &self,
        dispatch: BrowserWheelDispatch,
        pointer_admission: Option<BrowserPointerAdmission>,
    ) -> Option<(f64, f64, f64, f64)> {
        let state = self.state.lock().unwrap();
        if !self.pointer_guard_is_current_locked(
            &state,
            dispatch.input_owner,
            dispatch.frame_seq,
            pointer_admission,
        ) {
            return None;
        }
        let (x, y) = Self::scale_input_point_locked(&state, dispatch.x, dispatch.y);
        Some((
            x,
            y,
            Self::scale_delta_locked(&state, dispatch.delta_x),
            Self::scale_delta_locked(&state, dispatch.delta_y),
        ))
    }

    #[cfg(test)]
    fn scale_guarded_wheel(
        &self,
        frame_seq: Option<u64>,
        x: f64,
        y: f64,
        delta_y: f64,
    ) -> Option<(f64, f64, f64)> {
        let admitted = frame_seq.is_none_or(|frame_seq| {
            let state = self.state.lock().unwrap();
            self.presented_pointer_frame_is_current_locked(
                &state,
                BrowserPointerOwner::Local,
                frame_seq,
            )
        });
        let pointer_admission = admitted
            .then_some(BrowserPointerAdmission { owner: BrowserPointerOwner::Local, frame_seq });
        self.scale_guarded_wheel_from(
            BrowserPointerOwner::Local,
            frame_seq,
            pointer_admission,
            x,
            y,
            delta_y,
        )
    }

    fn maybe_nudge_stalled_external(&self, session: &BrowserSession) {
        if session.runtime.source() == BrowserSource::Launched {
            return;
        }
        let should_nudge = {
            let mut state = self.state.lock().unwrap();
            if frames_stalled_locked(&state, Instant::now(), self.is_dead()) && !state.stall_nudged
            {
                state.stall_nudged = true;
                true
            } else {
                false
            }
        };
        if should_nudge {
            let _ = session.runtime.client.activate_target(&session.target_id, &session.session_id);
        }
    }

    // Bounded, in-order delivery for disposable pointer/key input. Input events
    // are high-frequency and individually expendable, so under backpressure the
    // worker queue drops the newest event rather than blocking or replacing an
    // unrelated queued one. Callers are intentionally told `ok` even on drop:
    // losing one mouse-move or keystroke frame is not a reported failure.
    fn enqueue_bounded(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        match tx.try_send(command) {
            Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
            Err(TrySendError::Disconnected(_)) => anyhow::bail!("browser command worker is closed"),
        }
    }

    fn wake_lifecycle_worker(&self) {
        let _ = self.enqueue_bounded(BrowserCommand::WakeLatest);
    }

    // A release closes state established by an earlier accepted press. If the
    // ordinary lane is full, retain it in the same bounded sequence space and
    // wake the worker without blocking the shared browser-input producer.
    fn enqueue_pointer_release(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        match tx.try_send(command) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(command)) => {
                if order.retained_releases.len() >= BROWSER_RETAINED_RELEASE_CAPACITY {
                    anyhow::bail!("browser pointer release queue is full")
                }
                order.retained_releases.push_back(command);
                let wake = order.sequence(BrowserCommand::WakeLatest);
                match tx.try_send(wake) {
                    Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
                    Err(TrySendError::Disconnected(_)) => {
                        order.retained_releases.pop_back();
                        anyhow::bail!("browser command worker is closed")
                    }
                }
            }
            Err(TrySendError::Disconnected(_)) => {
                anyhow::bail!("browser command worker is closed")
            }
        }
    }

    // Bounded, in-order delivery for discrete control actions
    // (back/forward/reload/activate). These stay in FIFO order so a `Back` can
    // never be swallowed by a later `Forward` (unlike the latest-wins nav slot),
    // but unlike disposable input they must not be silently dropped: losing a
    // control action the caller asked for is a user-visible action that
    // vanished. When the queue is full (a wedged/unresponsive worker) report
    // backpressure as an error instead of a false `ok` so the caller learns the
    // command was rejected. `try_send` never blocks, so this preserves the
    // non-blocking contract. URL navigation uses the latest-wins slot instead
    // (see `enqueue_latest_nav`), where only the final destination matters.
    fn enqueue_control(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        match tx.try_send(command) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => {
                anyhow::bail!("browser command queue is full; browser may be unresponsive")
            }
            Err(TrySendError::Disconnected(_)) => anyhow::bail!("browser command worker is closed"),
        }
    }

    fn execute_confirmed(&self, command: BrowserCommand) -> anyhow::Result<()> {
        let (completion, outcome) = sync_channel(1);
        self.enqueue_control(BrowserCommand::Confirmed { command: Box::new(command), completion })?;
        outcome
            .recv()
            .map_err(|_| anyhow::anyhow!("browser command worker closed before completion"))?
            .map_err(anyhow::Error::msg)
    }

    fn enqueue_reconfigure(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            if let Some(queued) = reject_reconfigure(command) {
                self.release_reconfigure(queued);
            }
            anyhow::bail!("browser surface is closed");
        }
        let tx = match self.command_sender() {
            Ok(tx) => tx,
            Err(error) => {
                if let Some(queued) = reject_reconfigure(command) {
                    self.release_reconfigure(queued);
                }
                return Err(error);
            }
        };
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        match tx.try_send(command) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(command)) => {
                if let Some(queued) = reject_reconfigure(command.command) {
                    self.release_reconfigure(queued);
                }
                anyhow::bail!("browser command queue is full; browser may be unresponsive")
            }
            Err(TrySendError::Disconnected(command)) => {
                if let Some(queued) = reject_reconfigure(command.command) {
                    self.release_reconfigure(queued);
                }
                anyhow::bail!("browser command worker is closed")
            }
        }
    }

    fn enqueue_latest_nav(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        self.enqueue_latest_nav_ignoring_dead(command)
    }

    fn enqueue_latest_nav_ignoring_dead(&self, command: BrowserCommand) -> anyhow::Result<()> {
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        let mut latest_nav = self.latest_nav.lock().unwrap();
        *latest_nav = Some(command);
        drop(latest_nav);
        let wake = order.sequence(BrowserCommand::WakeLatest);
        match tx.try_send(wake) {
            Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
            Err(TrySendError::Disconnected(_)) => {
                self.latest_nav.lock().unwrap().take();
                anyhow::bail!("browser command worker is closed")
            }
        }
    }

    fn enqueue_latest_authority(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        let displaced = self.latest_authority.lock().unwrap().replace(command);
        let wake = order.sequence(BrowserCommand::WakeLatest);
        let (result, rejected) = match tx.try_send(wake) {
            Ok(()) | Err(TrySendError::Full(_)) => (Ok(()), None),
            Err(TrySendError::Disconnected(_)) => {
                let rejected = self.latest_authority.lock().unwrap().take();
                (Err(anyhow::anyhow!("browser command worker is closed")), rejected)
            }
        };
        drop(order);
        self.release_screencast_capture_command(displaced);
        self.release_screencast_capture_command(rejected);
        result
    }

    fn release_screencast_capture_command(&self, command: Option<SequencedBrowserCommand>) {
        let Some(BrowserCommand::AuthorizeScreencastCapture {
            session_id,
            reservation_id,
            frame_epoch,
            navigation_epoch,
            ..
        }) = command.map(|queued| queued.command)
        else {
            return;
        };
        self.cancel_screencast_capture(reservation_id);
        if let Some(session) = self.session.lock().unwrap().clone() {
            let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                &session_id,
                reservation_id,
                frame_epoch,
                navigation_epoch,
            );
        }
    }

    pub(crate) fn wake_pointer_cleanup(&self) {
        let Ok(tx) = self.command_sender() else { return };
        let mut order = self.command_order.lock().unwrap();
        let wake = order.sequence(BrowserCommand::WakeLatest);
        let _ = tx.try_send(wake);
    }

    fn command_sender(&self) -> anyhow::Result<SyncSender<SequencedBrowserCommand>> {
        self.command_tx
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| anyhow::anyhow!("browser command worker is closed"))
    }

    #[cfg(test)]
    fn enqueue_test_command(&self, command: BrowserCommand) -> bool {
        let Ok(tx) = self.command_sender() else { return false };
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        tx.try_send(command).is_ok()
    }

    fn close_command_sender(&self) {
        let _ = self.command_tx.lock().unwrap().take();
    }

    fn claim_not_responding_report(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.not_responding_reported {
            false
        } else {
            state.not_responding_reported = true;
            true
        }
    }

    pub fn mouse_event(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        self.mouse_event_for_frame(event_type, x, y, button, click_count, None)
    }

    /// Queue a mouse event admitted by the opaque `frame_seq` authority token.
    /// Uncaptured events with stale authority are ignored. An accepted press
    /// retains motion across ordinary repaints while its document and geometry
    /// remain valid, plus ownership of its balancing release after either is
    /// invalidated.
    pub fn mouse_event_for_frame(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        self.mouse_event_for_frame_from(BrowserMouseDispatch {
            input_owner: BrowserPointerOwner::Local,
            event_type,
            x,
            y,
            button,
            click_count,
            frame_seq,
        })
    }

    /// Queue guarded mouse input under one capture owner. Local in-process
    /// input has a reserved stable owner. Legacy remote sockets use a bounded
    /// compatibility lease; negotiated sockets use their connection registry id.
    pub(crate) fn mouse_event_for_frame_from(
        &self,
        dispatch: BrowserMouseDispatch<'_>,
    ) -> anyhow::Result<()> {
        let pointer_admission = self.admit_pointer_frame(dispatch.input_owner, dispatch.frame_seq);
        let command = BrowserCommand::Mouse {
            input_owner: dispatch.input_owner,
            event_type: dispatch.event_type.to_string(),
            x: dispatch.x,
            y: dispatch.y,
            button: dispatch.button.map(ToOwned::to_owned),
            click_count: dispatch.click_count,
            frame_seq: dispatch.frame_seq,
            pointer_admission,
        };
        if dispatch.event_type == "mouseReleased" {
            self.enqueue_pointer_release(command)
        } else {
            self.enqueue_bounded(command)
        }
    }

    fn mouse_event_blocking_with_admission(
        &self,
        dispatch: BrowserMouseDispatch<'_>,
        pointer_admission: Option<BrowserPointerAdmission>,
        active_pointer_presses: &mut HashMap<String, ActivePointerPress>,
    ) -> BrowserWorkerResult {
        let button = dispatch.button.unwrap_or("none");
        if let Some(press) = active_pointer_presses.get(button).copied()
            && press.input_owner != dispatch.input_owner
        {
            if self.pointer_capture_is_current(press.capture_generation) {
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            active_pointer_presses.remove(button);
        }
        let session = if dispatch.event_type == "mouseReleased"
            && active_pointer_presses.contains_key(button)
        {
            self.require_attached_session()?
        } else {
            self.require_live_session()?
        };
        if dispatch.event_type == "mousePressed" {
            self.maybe_nudge_stalled_external(&session);
        }
        let mut captured_press = None;
        let mut captured_release = false;
        let point = match (dispatch.event_type, dispatch.frame_seq) {
            ("mousePressed", Some(frame_seq)) => {
                let Some((point, capture_generation, motion_generation, ingress_motion_generation)) =
                    self.capture_guarded_input_point_from(
                        dispatch.input_owner,
                        frame_seq,
                        pointer_admission,
                        dispatch.x,
                        dispatch.y,
                    )
                else {
                    return Ok(BrowserWorkerSuccess::LocallySettled);
                };
                captured_press = Some(ActivePointerPress::new(
                    dispatch.input_owner,
                    capture_generation,
                    motion_generation,
                    ingress_motion_generation,
                    frame_seq,
                    point,
                    dispatch.click_count,
                ));
                Some(point)
            }
            ("mouseReleased", Some(dispatch_frame_seq)) => {
                let Some(press) = active_pointer_presses.get(button).copied() else {
                    return Ok(BrowserWorkerSuccess::LocallySettled);
                };
                let point = match self.captured_pointer_route(
                    press.capture_generation,
                    press.motion_generation,
                    press.ingress_motion_generation,
                    press.frame_seq,
                    dispatch_frame_seq,
                    (dispatch.x, dispatch.y),
                ) {
                    CapturedPointerRoute::Current(point) => Some(point),
                    CapturedPointerRoute::MotionInvalidated => {
                        Some((press.last_target_x, press.last_target_y))
                    }
                    CapturedPointerRoute::InvalidCapture => {
                        active_pointer_presses.remove(button);
                        None
                    }
                };
                if point.is_some() {
                    captured_release = true;
                }
                point
            }
            ("mouseMoved", Some(dispatch_frame_seq)) => {
                if let Some(press) = active_pointer_presses.get(button).copied() {
                    match self.captured_pointer_route(
                        press.capture_generation,
                        press.motion_generation,
                        press.ingress_motion_generation,
                        press.frame_seq,
                        dispatch_frame_seq,
                        (dispatch.x, dispatch.y),
                    ) {
                        CapturedPointerRoute::Current(point) => {
                            if press.input_owner == dispatch.input_owner
                                && let Some(press) = active_pointer_presses.get_mut(button)
                            {
                                press.refresh_pointer_position(point.0, point.1);
                            }
                            Some(point)
                        }
                        CapturedPointerRoute::MotionInvalidated => None,
                        CapturedPointerRoute::InvalidCapture => {
                            active_pointer_presses.remove(button);
                            None
                        }
                    }
                } else {
                    self.scale_guarded_input_point_from(
                        dispatch.input_owner,
                        dispatch.frame_seq,
                        pointer_admission,
                        dispatch.x,
                        dispatch.y,
                    )
                }
            }
            ("mouseReleased", None) => self.scale_guarded_input_point_from(
                dispatch.input_owner,
                None,
                pointer_admission,
                dispatch.x,
                dispatch.y,
            ),
            _ => self.scale_guarded_input_point_from(
                dispatch.input_owner,
                dispatch.frame_seq,
                pointer_admission,
                dispatch.x,
                dispatch.y,
            ),
        };
        let Some((x, y)) = point else {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        };
        let replaced_press = captured_press
            .map(|generation| active_pointer_presses.insert(button.to_string(), generation));
        let result = session.runtime.client.dispatch_mouse_event(
            &session.session_id,
            dispatch.event_type,
            x,
            y,
            dispatch.button,
            dispatch.click_count,
        );
        if let Err(error) = result {
            if is_cdp_timeout_error(&error.to_string()) {
                if captured_release && let Some(press) = active_pointer_presses.get_mut(button) {
                    press.last_target_x = x;
                    press.last_target_y = y;
                    if dispatch.click_count.is_some() {
                        press.click_count = dispatch.click_count;
                    }
                    // The first call may have reached Chrome. Retain its exact
                    // capture and schedule one balancing retry before any later
                    // pointer command can replace that ownership.
                    press.release_retry_at = Some(Instant::now() + POINTER_RELEASE_RETRY_DELAY);
                }
            } else {
                match replaced_press {
                    Some(Some(previous)) => {
                        active_pointer_presses.insert(button.to_string(), previous);
                    }
                    Some(None) => {
                        active_pointer_presses.remove(button);
                    }
                    None => {}
                }
            }
            return Err(error);
        }
        if captured_release {
            active_pointer_presses.remove(button);
        }
        Ok(BrowserWorkerSuccess::BrowserResponded)
    }

    #[cfg(test)]
    fn mouse_event_blocking(
        &self,
        dispatch: BrowserMouseDispatch<'_>,
        active_pointer_presses: &mut HashMap<String, ActivePointerPress>,
    ) -> BrowserWorkerResult {
        let pointer_admission = self.admit_pointer_frame(dispatch.input_owner, dispatch.frame_seq);
        self.mouse_event_blocking_with_admission(
            dispatch,
            pointer_admission,
            active_pointer_presses,
        )
    }

    pub(crate) fn mouse_event_confirmed(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: u64,
    ) -> anyhow::Result<()> {
        let input_owner = BrowserPointerOwner::Legacy;
        let frame_seq = Some(frame_seq);
        let pointer_admission = self.admit_pointer_frame(input_owner, frame_seq);
        self.execute_confirmed(BrowserCommand::Mouse {
            input_owner,
            event_type: event_type.to_string(),
            x,
            y,
            button: button.map(ToOwned::to_owned),
            click_count,
            frame_seq,
            pointer_admission,
        })
    }

    fn release_abandoned_pointer_press_blocking(
        &self,
        button: &str,
        press: ActivePointerPress,
    ) -> BrowserWorkerResult {
        if !self.pointer_capture_is_current(press.capture_generation) {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let session = self.require_attached_session()?;
        session
            .runtime
            .client
            .dispatch_mouse_event(
                &session.session_id,
                "mouseReleased",
                press.last_target_x,
                press.last_target_y,
                Some(button),
                press.click_count,
            )
            .map(|_| BrowserWorkerSuccess::BrowserResponded)
    }

    pub fn wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        self.wheel_for_frame(x, y, delta_y, None)
    }

    pub fn wheel_2d(&self, x: f64, y: f64, delta_x: f64, delta_y: f64) -> anyhow::Result<()> {
        self.wheel_2d_for_frame_from(BrowserPointerOwner::Local, x, y, delta_x, delta_y, None)
    }

    /// Queue a wheel event only if `frame_seq` is still the live pointer-authority token.
    pub fn wheel_for_frame(
        &self,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        self.wheel_for_frame_from(BrowserPointerOwner::Local, x, y, delta_y, frame_seq)
    }

    pub(crate) fn wheel_for_frame_from(
        &self,
        input_owner: BrowserPointerOwner,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        self.wheel_2d_for_frame_from(input_owner, x, y, 0.0, delta_y, frame_seq)
    }

    fn wheel_2d_for_frame_from(
        &self,
        input_owner: BrowserPointerOwner,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        let pointer_admission = self.admit_pointer_frame(input_owner, frame_seq);
        self.enqueue_bounded(BrowserCommand::Wheel {
            input_owner,
            x,
            y,
            delta_x,
            delta_y,
            frame_seq,
            pointer_admission,
        })
    }

    fn wheel_blocking(
        &self,
        dispatch: BrowserWheelDispatch,
        pointer_admission: Option<BrowserPointerAdmission>,
    ) -> BrowserWorkerResult {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        let Some((x, y, delta_x, delta_y)) =
            self.scale_guarded_wheel_2d_from(dispatch, pointer_admission)
        else {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        };
        session
            .runtime
            .client
            .dispatch_wheel(&session.session_id, x, y, delta_x, delta_y)
            .map(|_| BrowserWorkerSuccess::BrowserResponded)
    }

    pub(crate) fn wheel_confirmed(
        &self,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        frame_seq: u64,
    ) -> anyhow::Result<()> {
        let input_owner = BrowserPointerOwner::Legacy;
        let frame_seq = Some(frame_seq);
        let pointer_admission = self.admit_pointer_frame(input_owner, frame_seq);
        self.execute_confirmed(BrowserCommand::Wheel {
            input_owner,
            x,
            y,
            delta_x,
            delta_y,
            frame_seq,
            pointer_admission,
        })
    }

    pub fn key_event(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        self.enqueue_bounded(BrowserCommand::Key {
            event_type: event_type.to_string(),
            key: key.to_string(),
            code: code.to_string(),
            windows_virtual_key_code,
            modifiers,
            text: text.map(ToOwned::to_owned),
        })
    }

    pub fn key_press(
        &self,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        self.enqueue_bounded(BrowserCommand::KeyPress {
            key: key.to_string(),
            code: code.to_string(),
            windows_virtual_key_code,
            modifiers,
            text: text.map(ToOwned::to_owned),
        })
    }

    fn key_event_blocking(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        session.runtime.client.dispatch_key_event(
            &session.session_id,
            CdpKeyEvent { event_type, key, code, windows_virtual_key_code, modifiers, text },
        )
    }

    fn key_press_blocking(
        &self,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        let key_down = session.runtime.client.dispatch_key_event(
            &session.session_id,
            CdpKeyEvent {
                event_type: "keyDown",
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text,
            },
        );
        let key_up = session.runtime.client.dispatch_key_event(
            &session.session_id,
            CdpKeyEvent {
                event_type: "keyUp",
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text: None,
            },
        );
        key_down.and(key_up)
    }

    pub(crate) fn key_event_confirmed(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Key {
            event_type: event_type.to_string(),
            key: key.to_string(),
            code: code.to_string(),
            windows_virtual_key_code,
            modifiers,
            text: text.map(ToOwned::to_owned),
        })
    }

    pub fn insert_text(&self, text: &str) -> anyhow::Result<()> {
        self.enqueue_bounded(BrowserCommand::InsertText(text.to_string()))
    }

    fn insert_text_blocking(&self, text: &str) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        session.runtime.client.insert_text(&session.session_id, text)
    }

    pub(crate) fn insert_text_confirmed(&self, text: &str) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::InsertText(text.to_string()))
    }

    fn authorize_document_paint_blocking(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
        navigation_epoch: u64,
    ) -> BrowserWorkerResult {
        self.authorize_document_paint_with_attempt_budget_blocking(
            session_id,
            frame_id,
            loader_id,
            navigation_epoch,
            AUTHORITY_CAPTURE_ATTEMPT_BUDGET,
        )
    }

    fn authorize_document_paint_with_attempt_budget_blocking(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
        navigation_epoch: u64,
        attempt_budget: Duration,
    ) -> BrowserWorkerResult {
        if !self.needs_document_paint(navigation_epoch)
            || self.frame_epoch.latest_navigation() != navigation_epoch
        {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let session = self.require_verification_session()?;
        if session.session_id != session_id {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let mut last_error = None;
        for _ in 0..AUTHORITY_CAPTURE_ATTEMPTS {
            if !self.needs_document_paint(navigation_epoch)
                || self.frame_epoch.latest_navigation() != navigation_epoch
            {
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            let deadline = Instant::now() + attempt_budget;
            match self.capture_main_frame_after_restart(&session, frame_id, loader_id, deadline) {
                Ok((frame_epoch, captured)) => {
                    let accepted = self.accept_document_paint(
                        navigation_epoch,
                        frame_epoch,
                        browser_frame_from_capture(session_id, captured),
                    );
                    if accepted {
                        self.dirty.store(true, Ordering::Release);
                    }
                    return Ok(BrowserWorkerSuccess::BrowserResponded);
                }
                Err(_) if self.frame_epoch.latest_navigation() != navigation_epoch => {
                    return Ok(BrowserWorkerSuccess::LocallySettled);
                }
                Err(error) => {
                    let timed_out = is_cdp_timeout_error(&error.to_string());
                    last_error = Some(error);
                    if timed_out {
                        break;
                    }
                }
            }
        }
        let error = last_error.expect("authority capture attempts must record an error");
        self.fail_document_authority(navigation_epoch, &error);
        Err(error)
    }

    fn authorize_same_document_paint_blocking(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
    ) -> BrowserWorkerResult {
        if !self.needs_same_document_paint() {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let session = self.require_verification_session()?;
        if session.session_id != session_id {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let mut last_error = None;
        for _ in 0..AUTHORITY_CAPTURE_ATTEMPTS {
            if !self.needs_same_document_paint() {
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            let deadline = Instant::now() + AUTHORITY_CAPTURE_ATTEMPT_BUDGET;
            match self.capture_main_frame_after_restart(&session, frame_id, loader_id, deadline) {
                Ok((frame_epoch, captured)) => {
                    let accepted = self.accept_same_document_paint(
                        frame_epoch,
                        browser_frame_from_capture(session_id, captured),
                    );
                    if accepted {
                        self.dirty.store(true, Ordering::Release);
                    }
                    return Ok(BrowserWorkerSuccess::BrowserResponded);
                }
                Err(error) => {
                    let timed_out = is_cdp_timeout_error(&error.to_string());
                    last_error = Some(error);
                    if timed_out {
                        break;
                    }
                }
            }
        }
        let error = last_error.expect("authority capture attempts must record an error");
        self.fail_same_document_authority(&error);
        Err(error)
    }

    fn authorize_screencast_capture_blocking(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> BrowserWorkerResult {
        if !self.may_need_screencast_capture(reservation_id, frame_epoch, navigation_epoch) {
            self.cancel_screencast_capture(reservation_id);
            if let Some(session) = self.session.lock().unwrap().clone() {
                let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                    session_id,
                    reservation_id,
                    frame_epoch,
                    navigation_epoch,
                );
            }
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let session = match self.require_live_session() {
            Ok(session) => session,
            Err(error) => {
                self.cancel_screencast_capture(reservation_id);
                if let Some(session) = self.session.lock().unwrap().clone() {
                    let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                        session_id,
                        reservation_id,
                        frame_epoch,
                        navigation_epoch,
                    );
                }
                return Err(error);
            }
        };
        if session.session_id != session_id {
            self.cancel_screencast_capture(reservation_id);
            let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                session_id,
                reservation_id,
                frame_epoch,
                navigation_epoch,
            );
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let mut last_error = None;
        for _ in 0..AUTHORITY_CAPTURE_ATTEMPTS {
            if !self.may_need_screencast_capture(reservation_id, frame_epoch, navigation_epoch) {
                self.cancel_screencast_capture(reservation_id);
                let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                    session_id,
                    reservation_id,
                    frame_epoch,
                    navigation_epoch,
                );
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            let deadline = Instant::now() + AUTHORITY_CAPTURE_ATTEMPT_BUDGET;
            match session
                .runtime
                .client
                .capture_main_frame_for_loader_before(session_id, frame_id, loader_id, deadline)
            {
                Ok(captured) => {
                    let accepted = self.accept_screencast_capture(
                        reservation_id,
                        frame_epoch,
                        navigation_epoch,
                        browser_frame_from_capture(session_id, captured),
                    );
                    if accepted {
                        self.dirty.store(true, Ordering::Release);
                        let _ = session.runtime.client.settle_timestampless_screencast_capture(
                            session_id,
                            reservation_id,
                            frame_epoch,
                            navigation_epoch,
                        );
                    } else {
                        let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                            session_id,
                            reservation_id,
                            frame_epoch,
                            navigation_epoch,
                        );
                    }
                    return Ok(BrowserWorkerSuccess::BrowserResponded);
                }
                Err(error) => {
                    let timed_out = is_cdp_timeout_error(&error.to_string());
                    last_error = Some(error);
                    if timed_out {
                        break;
                    }
                }
            }
        }
        let error = last_error.expect("authority capture attempts must record an error");
        let suppressed = session.runtime.client.suppress_timestampless_screencast_capture(
            session_id,
            reservation_id,
            frame_epoch,
            navigation_epoch,
        );
        if suppressed {
            self.suppress_failed_screencast_capture(
                reservation_id,
                frame_epoch,
                navigation_epoch,
                &error,
            );
        } else {
            self.cancel_screencast_capture(reservation_id);
        }
        Err(error)
    }

    fn capture_main_frame_after_restart(
        &self,
        session: &BrowserSession,
        frame_id: &str,
        loader_id: &str,
        deadline: Instant,
    ) -> anyhow::Result<(u64, CapturedFrame)> {
        let frame_epoch = self.restart_screencast_for_authority(session, deadline)?;
        let captured = session.runtime.client.capture_main_frame_for_loader_before(
            &session.session_id,
            frame_id,
            loader_id,
            deadline,
        )?;
        Ok((frame_epoch, captured))
    }

    fn restart_screencast_for_authority(
        &self,
        session: &BrowserSession,
        deadline: Instant,
    ) -> anyhow::Result<u64> {
        let (width, height) = self.pixel_size();
        session.runtime.client.stop_screencast_before(&session.session_id, deadline)?;
        session.runtime.client.start_screencast_with_frame_barrier_before(
            &session.session_id,
            width,
            height,
            deadline,
        )
    }

    pub fn navigate(&self, url: &str) -> anyhow::Result<()> {
        self.enqueue_latest_nav(BrowserCommand::Navigate(url.to_string()))
    }

    fn begin_latest_navigation_frame_transition(
        &self,
        session: &BrowserSession,
        may_be_same_document: bool,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        match self.begin_navigation_frame_transition_to(may_be_same_document) {
            Ok(invalidation) => Ok(invalidation),
            Err(_) if self.navigation_transition_pending() => {
                // Page.stopLoading is ordered on the same CDP session. By the
                // time it responds, ingress has assigned epochs to every old
                // navigation event Chrome emitted, so a fresh current + 1
                // reservation rejects any old event still queued to the
                // surface while allowing the latest-wins URL to proceed.
                session.runtime.client.stop_loading(&session.session_id)?;
                self.begin_superseding_navigation_frame_transition(may_be_same_document)
            }
            Err(first_error) => {
                // The previous transition may have settled between the first
                // reservation attempt and the state check.
                self.begin_navigation_frame_transition_to(may_be_same_document)
                    .map_err(|_| first_error)
            }
        }
    }

    fn reconcile_loaderless_navigation(&self, session: &BrowserSession) -> anyhow::Result<()> {
        if !self.needs_same_document_paint() {
            return Ok(());
        }
        // CDP omits loaderId for same-document Page.navigate results. If the
        // corresponding event was delayed or absent, snapshot the subscribed
        // session and authorize freshly captured pixels for that loader.
        for _ in 0..AUTHORITY_CAPTURE_ATTEMPTS {
            let snapshot =
                match session.runtime.client.snapshot_main_frame_with_retry(&session.session_id) {
                    Ok(snapshot) => snapshot,
                    Err(error) => {
                        self.fail_same_document_authority(&error);
                        return Err(error);
                    }
                };
            if self.reconcile_same_document_snapshot(snapshot.same_document_navigation_epoch) {
                return self
                    .authorize_same_document_paint_blocking(
                        &session.session_id,
                        &snapshot.frame_id,
                        &snapshot.loader_id,
                    )
                    .map(|_| ());
            }
            if !self.needs_same_document_paint() {
                return Ok(());
            }
        }
        let error =
            anyhow::anyhow!("main-frame snapshot was invalidated by repeated page navigation");
        self.fail_same_document_authority(&error);
        Err(error)
    }

    fn navigate_blocking(&self, url: &str) -> anyhow::Result<()> {
        let session = self.require_navigation_session()?;
        let normalized = normalize_url(url);
        let invalidation = self.begin_latest_navigation_frame_transition(&session, true)?;
        match session.runtime.client.navigate(&session.session_id, &normalized) {
            Ok(result) => {
                if result.is_download {
                    // Chrome explicitly confirmed that the response was handed
                    // to the download manager, so the current document and its
                    // rendered frame remain authoritative.
                    self.restore_pointer_frame_after_failed_command(invalidation);
                    return Ok(());
                }
                if let Some(error) = result.error_text {
                    self.abandon_frame_transition();
                    self.mark_failed(error.clone());
                    anyhow::bail!("browser failed: {error}");
                }
                let loaderless = result.loader_id.is_none();
                if loaderless {
                    self.reconcile_loaderless_navigation(&session)?;
                } else {
                    self.finish_navigation_command(invalidation, Ok(()))?;
                }
            }
            Err(error) => self.finish_navigation_command(invalidation, Err(error))?,
        }
        self.set_url_title(normalized.clone(), normalized);
        self.dirty.store(true, Ordering::Release);
        Ok(())
    }

    pub(crate) fn navigate_confirmed(&self, url: &str) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Navigate(url.to_string()))
    }

    pub fn back(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Back)
    }

    pub fn forward(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Forward)
    }

    fn back_blocking(&self) -> anyhow::Result<()> {
        self.navigate_history_blocking(-1)
    }

    fn forward_blocking(&self) -> anyhow::Result<()> {
        self.navigate_history_blocking(1)
    }

    pub(crate) fn back_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Back)
    }

    pub(crate) fn forward_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Forward)
    }

    fn navigate_history_blocking(&self, delta: isize) -> anyhow::Result<()> {
        let session = self.require_navigation_session()?;
        let invalidation = self.begin_latest_navigation_frame_transition(&session, true)?;
        let history = match session.runtime.client.navigation_history(&session.session_id) {
            Ok(history) => history,
            Err(error) => {
                self.restore_pointer_frame_after_failed_command(invalidation);
                return Err(error);
            }
        };
        let next = history.current_index as isize + delta;
        if next < 0 || next as usize >= history.entries.len() {
            self.restore_pointer_frame_after_failed_command(invalidation);
            anyhow::bail!(
                "browser has no {} history entry",
                if delta < 0 { "back" } else { "forward" }
            );
        }
        let entry = &history.entries[next as usize];
        self.finish_navigation_command(
            invalidation,
            session.runtime.client.navigate_to_history_entry(&session.session_id, entry.id),
        )?;
        Ok(())
    }

    pub fn reload(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Reload)
    }

    fn reload_blocking(&self) -> anyhow::Result<()> {
        let session = self.require_navigation_session()?;
        let invalidation = self.begin_latest_navigation_frame_transition(&session, false)?;
        self.finish_navigation_command(
            invalidation,
            session.runtime.client.reload(&session.session_id),
        )?;
        Ok(())
    }

    pub(crate) fn reload_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Reload)
    }

    pub fn activate(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Activate)
    }

    fn activate_blocking(&self) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        session.runtime.client.activate_target(&session.target_id, &session.session_id)
    }

    pub(crate) fn activate_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Activate)
    }

    fn close_blocking(&self) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        if session.runtime.source() != BrowserSource::Provider {
            session.runtime.client.close_target(&session.target_id)?;
        }
        if !self.dead.swap(true, Ordering::AcqRel) {
            self.close_taps();
            if let Some(session) = self.session.lock().unwrap().take() {
                if session.runtime.source() == BrowserSource::Provider {
                    session.runtime.close_surface_detached(&session.target_id, &session.session_id);
                } else {
                    session.runtime.unregister(&session.target_id, &session.session_id);
                }
            }
            self.close_command_sender();
        }
        Ok(())
    }

    pub(crate) fn close_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Close)
    }

    fn handle_javascript_dialog(&self, accept: bool) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        session.runtime.client.handle_javascript_dialog(&session.session_id, accept)
    }
}

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

fn handle_frame_navigated(browser: &BrowserSurface, params: serde_json::Value, frame_epoch: u64) {
    let frame = params.get("frame").unwrap_or(&params);
    if frame.get("parentId").is_some() {
        return;
    }
    if !browser.observe_navigation_frame_epoch(frame_epoch) {
        return;
    }
    if let Some(url) = frame.get("url").and_then(|v| v.as_str()).filter(|url| !url.is_empty()) {
        browser.set_url(url.to_string());
        let title = frame
            .get("name")
            .and_then(|v| v.as_str())
            .filter(|title| !title.is_empty())
            .unwrap_or(url);
        let _ = browser.set_title(title.to_string());
    }
}

fn handle_same_document_navigated(
    browser: &BrowserSurface,
    params: &serde_json::Value,
    frame_epoch: u64,
) -> Option<String> {
    browser.observe_same_document_frame_epoch(frame_epoch);
    let url = params.get("url").and_then(|value| value.as_str())?.to_string();
    if !url.is_empty() {
        browser.set_url(url.clone());
        let _ = browser.set_title(url.clone());
    }
    Some(url)
}

fn dialog_response(params: &serde_json::Value) -> (bool, String) {
    let kind = params.get("type").and_then(|v| v.as_str()).unwrap_or("dialog");
    let message = params.get("message").and_then(|v| v.as_str()).unwrap_or_default();
    let accept = kind == "beforeunload";
    let action = if accept { "accepted" } else { "dismissed" };
    let text = if message.is_empty() {
        format!("browser {kind} dialog {action}")
    } else {
        format!("browser {kind} dialog {action}: {message}")
    };
    (accept, text)
}

fn handle_target_created(
    browser: &BrowserSurface,
    created: &TargetCreated,
    mux: &Weak<Mux>,
    runtime: &Weak<BrowserRuntime>,
    opener_surface: SurfaceId,
) {
    if created.target_type != "page" {
        return;
    }
    let Some(session) = browser.session.lock().unwrap().clone() else {
        if let Some(runtime) = runtime.upgrade() {
            let _ = runtime.client.close_target(&created.target_id);
        }
        return;
    };
    // cmux-browser owns popup materialization and commits its canonical tab
    // before publishing a target lease. CDP is only the rendering/input data
    // plane in provider mode, so adopting this event here would create a
    // second tab and race the browser's journal mutation.
    if session.runtime.source() == BrowserSource::Provider {
        return;
    }
    if created.opener_id.as_deref() != Some(session.target_id.as_str()) {
        return;
    }
    let Some(mux) = mux.upgrade() else {
        let _ = session.runtime.client.close_target(&created.target_id);
        return;
    };
    let adopted = mux.adopt_browser_target(
        opener_surface,
        created.target_id.clone(),
        if created.url.is_empty() { "about:blank".to_string() } else { created.url.clone() },
        session.runtime.clone(),
    );
    if !matches!(adopted, Ok(true)) {
        let _ = session.runtime.client.close_target(&created.target_id);
        if let Err(error) = adopted {
            mux.emit(MuxEvent::Status(format!("browser target adoption failed: {error}")));
        }
    }
}

/// Turn user-entered text into a navigable URL, the same way for every
/// entrypoint (TUI omnibar, `browser-navigate` and `new-browser-tab`
/// over the control socket, direct [`BrowserSurface::navigate`]):
/// explicit schemes pass through, loopback hosts get `http://`, dotted
/// hosts get `https://`, and anything else becomes a web search.
/// Idempotent, so layered callers may each apply it.
pub fn normalize_url(input: &str) -> String {
    let trimmed = input.trim();
    if trimmed.contains("://") {
        return trimmed.to_string();
    }
    if is_loopback_address(trimmed) {
        return format!("http://{trimmed}");
    }
    if has_bare_scheme(trimmed) {
        return trimmed.to_string();
    }
    if !trimmed.chars().any(char::is_whitespace) && trimmed.contains('.') {
        return format!("https://{trimmed}");
    }
    format!("https://www.google.com/search?q={}", percent_encode_query(trimmed))
}

/// A scheme-looking prefix (`about:`, `mailto:`, `data:`, ...) that is
/// not a host:port pair: `myhost:8080` is a search, `mailto:x` is not.
fn has_bare_scheme(input: &str) -> bool {
    let Some((scheme, rest)) = input.split_once(':') else {
        return false;
    };
    if scheme.contains('.') || (!rest.is_empty() && rest.chars().all(|ch| ch.is_ascii_digit())) {
        return false;
    }
    let mut chars = scheme.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    first.is_ascii_alphabetic()
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-'))
}

fn is_loopback_address(input: &str) -> bool {
    let starts = ["localhost", "127.0.0.1", "[::1]"];
    starts.iter().any(|prefix| {
        let Some(rest) = input.strip_prefix(prefix) else {
            return false;
        };
        rest.is_empty() || matches!(rest.as_bytes()[0], b':' | b'/' | b'?')
    })
}

fn percent_encode_query(input: &str) -> String {
    let mut out = String::new();
    for byte in input.as_bytes() {
        match *byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            other => {
                const HEX: &[u8; 16] = b"0123456789ABCDEF";
                out.push('%');
                out.push(HEX[(other >> 4) as usize] as char);
                out.push(HEX[(other & 0x0F) as usize] as char);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{
        AUTHORITY_CAPTURE_ATTEMPTS, BROWSER_COMMAND_QUEUE_CAPACITY, BrowserCaptureOptions,
        BrowserCommand, BrowserFrame, BrowserSession, BrowserSource, BrowserStatus,
        MAX_RECONFIGURE_WAITERS_PER_RESERVATION, SequencedBrowserCommand, capture_scale_for,
        handle_frame_navigated, handle_same_document_navigated, new_surface, normalize_url,
        runtime_endpoint, scaled_pixels, start_surface_thread, take_latest_worker_commands,
    };
    use crate::{Mux, MuxEvent, Surface, SurfaceOptions};
    use serde_json::{Value, json};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex, Weak, mpsc};
    use std::thread;
    use std::time::{Duration, Instant};
    use tungstenite::{Message, accept};

    const BROWSER_TEST_EVENT_TIMEOUT: Duration = Duration::from_secs(5);

    fn test_frame(seq: u64) -> BrowserFrame {
        BrowserFrame {
            session_id: "session-test".to_string(),
            data_b64: "AAAA".to_string(),
            css_width: 80,
            css_height: 48,
            image_width: 80,
            image_height: 48,
            seq,
        }
    }

    fn runtime_rejecting_one_mouse_dispatch() -> (Arc<super::BrowserRuntime>, thread::JoinHandle<()>)
    {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let mouse = read_ws_json(&mut ws);
            assert_eq!(mouse["method"], "Input.dispatchMouseEvent");
            write_ws_json(
                &mut ws,
                json!({
                    "id": mouse["id"],
                    "error": {"message": "CDP call Input.dispatchMouseEvent timed out"}
                }),
            );
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        (runtime, server)
    }

    fn runtime_rejecting_then_observing_mouse_retry()
    -> (Arc<super::BrowserRuntime>, thread::JoinHandle<()>, mpsc::Receiver<bool>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (observed_tx, observed_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let mouse = read_ws_json(&mut ws);
            assert_eq!(mouse["method"], "Input.dispatchMouseEvent");
            write_ws_json(
                &mut ws,
                json!({
                    "id": mouse["id"],
                    "error": {"message": "CDP call Input.dispatchMouseEvent timed out"}
                }),
            );

            ws.get_mut().set_read_timeout(Some(BROWSER_TEST_EVENT_TIMEOUT)).unwrap();
            let retry = loop {
                match ws.read() {
                    Ok(Message::Text(text)) => break serde_json::from_str::<Value>(&text).ok(),
                    Ok(Message::Binary(bytes)) => {
                        break serde_json::from_slice::<Value>(&bytes).ok();
                    }
                    Ok(_) => {}
                    Err(_) => break None,
                }
            };
            let observed =
                retry.as_ref().is_some_and(|retry| retry["method"] == "Input.dispatchMouseEvent");
            if let Some(retry) = retry {
                write_ws_json(&mut ws, json!({"id": retry["id"], "result": {}}));
            }
            observed_tx.send(observed).unwrap();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        (runtime, server, observed_rx)
    }

    fn runtime_accepting_mouse_dispatches(
        expected_types: Vec<&'static str>,
    ) -> (Arc<super::BrowserRuntime>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            for expected_type in expected_types {
                let mouse = read_ws_json(&mut ws);
                assert_eq!(mouse["method"], "Input.dispatchMouseEvent");
                assert_eq!(mouse["params"]["type"], expected_type);
                write_ws_json(&mut ws, json!({"id": mouse["id"], "result": {}}));
            }
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        (runtime, server)
    }

    fn runtime_recording_key_dispatches() -> (
        Arc<super::BrowserRuntime>,
        thread::JoinHandle<()>,
        mpsc::Receiver<Vec<String>>,
        mpsc::Sender<()>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (observed_tx, observed_rx) = mpsc::channel();
        let (start_tx, start_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(BROWSER_TEST_EVENT_TIMEOUT)).unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            start_rx.recv().unwrap();
            let mut event_types = Vec::new();
            while event_types.len() < 2 {
                let request = match ws.read() {
                    Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).ok(),
                    Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).ok(),
                    Ok(_) => None,
                    Err(tungstenite::Error::Io(error))
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        break;
                    }
                    Err(_) => break,
                };
                let Some(request) = request else { continue };
                if request["method"] == "Input.dispatchKeyEvent" {
                    event_types.push(request["params"]["type"].as_str().unwrap().to_string());
                }
                write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
            }
            observed_tx.send(event_types).unwrap();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        (runtime, server, observed_rx, start_tx)
    }

    fn runtime_recording_mouse_dispatches()
    -> (Arc<super::BrowserRuntime>, thread::JoinHandle<()>, mpsc::Receiver<Value>, mpsc::Sender<()>)
    {
        const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (events_tx, events_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            loop {
                if stop_rx.try_recv().is_ok() {
                    break;
                }
                let request = match ws.read() {
                    Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).ok(),
                    Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).ok(),
                    Ok(_) => None,
                    Err(tungstenite::Error::Io(error))
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        continue;
                    }
                    Err(_) => break,
                };
                let Some(request) = request else { continue };
                if request["method"] == "Input.dispatchMouseEvent" {
                    events_tx.send(request.clone()).unwrap();
                }
                let result = match request["method"].as_str().unwrap() {
                    "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                    "Runtime.evaluate" => {
                        json!({"result": {"type": "number", "value": 10_000.0}})
                    }
                    "Page.getFrameTree" => json!({
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test/#recovery"
                            }
                        }
                    }),
                    "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                    _ => json!({}),
                };
                write_ws_json(&mut ws, json!({"id": request["id"], "result": result}));
            }
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        (runtime, server, events_rx, stop_tx)
    }

    fn test_surface() -> Arc<Surface> {
        let opts = SurfaceOptions::default();
        new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new()).unwrap()
    }

    fn acknowledge_local_presentation(browser: &super::BrowserSurface, frame_seq: u64) {
        assert!(
            browser.acknowledge_pointer_frame(frame_seq),
            "test frame {frame_seq} must belong to the current pointer route"
        );
    }

    fn read_ws_json(ws: &mut tungstenite::WebSocket<TcpStream>) -> Value {
        loop {
            match ws.read().unwrap() {
                Message::Text(text) => return serde_json::from_str(&text).unwrap(),
                Message::Binary(bytes) => return serde_json::from_slice(&bytes).unwrap(),
                _ => {}
            }
        }
    }

    fn write_ws_json(ws: &mut tungstenite::WebSocket<TcpStream>, value: Value) {
        ws.send(Message::Text(value.to_string().into())).unwrap();
    }

    #[test]
    fn confirmed_provider_close_detaches_without_closing_the_target() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (detached_tx, detached_rx) = mpsc::channel();
        let server = thread::Builder::new()
            .name("browser-provider-close-fake-cdp".into())
            .spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut ws = accept(stream).unwrap();
                let discover = read_ws_json(&mut ws);
                assert_eq!(discover["method"], "Target.setDiscoverTargets");
                write_ws_json(&mut ws, json!({"id":discover["id"],"result":{}}));

                let detached = read_ws_json(&mut ws);
                detached_tx.send(detached.clone()).unwrap();
                write_ws_json(&mut ws, json!({"id":detached["id"],"result":{}}));
            })
            .unwrap();
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::Provider,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let _route = runtime.register("provider-target", "provider-session");
        browser
            .mark_live(BrowserSession {
                runtime: runtime.clone(),
                target_id: "provider-target".to_string(),
                session_id: "provider-session".to_string(),
            })
            .unwrap();

        browser.close_confirmed().unwrap();
        runtime.client.flush_outbound(Duration::from_secs(1)).unwrap();
        let detached = detached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(detached["method"], "Target.detachFromTarget");
        assert_eq!(detached["params"]["sessionId"], "provider-session");
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after close");

        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn frames_do_not_clear_failed_status() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        assert_eq!(browser.status(), BrowserStatus::Live);

        // Chrome keeps streaming frames of the previous page after a
        // failed navigation; they must not mask the failure: the status
        // stays Failed and latest_frame() hides the stale frame so the
        // pane shows the failure text.
        browser.mark_failed("nope".into());
        browser.store_frame(test_frame(2));
        assert_eq!(browser.status(), BrowserStatus::Failed("nope".into()));
        assert_eq!(browser.latest_frame(), None);
        assert_eq!(browser.latest_frame_metadata(), None);

        // Clearing the error restores the retained frame.
        browser.clear_error();
        assert_eq!(browser.status(), BrowserStatus::Live);
        assert_eq!(browser.latest_frame().map(|frame| frame.seq), Some(2));
        assert_eq!(browser.latest_frame_metadata(), Some((2, 80, 48, None)));
    }

    #[test]
    fn arbitrary_failure_text_cannot_grant_navigation_recovery() {
        let (runtime, server) = runtime_accepting_mouse_dispatches(vec![]);
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.mark_failed(format!(
            "{}untrusted transport text{}",
            super::BROWSER_NEW_PAGE_VERIFICATION_FAILED_PREFIX,
            super::BROWSER_VERIFICATION_FAILED_SUFFIX
        ));

        let recovery = browser.require_navigation_session();

        runtime.shutdown();
        server.join().unwrap();
        assert!(
            recovery.is_err(),
            "display text that resembles a retryable failure must not grant recovery authority"
        );
    }

    #[test]
    fn repeated_latest_frame_reads_share_the_encoded_payload() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));

        let first = browser.latest_frame().expect("first frame");
        let second = browser.latest_frame().expect("second frame");

        assert_eq!(
            first.data_b64.as_ptr(),
            second.data_b64.as_ptr(),
            "reading the current frame must not copy its encoded image payload"
        );
    }

    #[test]
    fn capture_scale_respects_budget_and_fixed_override() {
        let opts = BrowserCaptureOptions { max_capture_megapixels: 2.0, fixed_capture_scale: None };
        let scale = capture_scale_for(4760, 2548, opts);
        assert!(scale < 1.0);
        assert_eq!(scaled_pixels(4760, 2548, scale), (1933, 1035));

        let small = capture_scale_for(800, 600, opts);
        assert_eq!(small, 1.0);
        assert_eq!(scaled_pixels(800, 600, small), (800, 600));

        let fixed =
            BrowserCaptureOptions { max_capture_megapixels: 2.0, fixed_capture_scale: Some(0.5) };
        assert_eq!(capture_scale_for(800, 600, fixed), 0.5);
        assert_eq!(scaled_pixels(800, 600, 0.5), (400, 300));

        let configured = BrowserCaptureOptions::from_options(&SurfaceOptions {
            browser_max_capture_megapixels: 20.0,
            browser_capture_scale: Some(1.0),
            ..SurfaceOptions::default()
        });
        let capped_scale = capture_scale_for(4760, 2548, configured);
        let capped = scaled_pixels(4760, 2548, capped_scale);
        assert!(u64::from(capped.0) * u64::from(capped.1) <= 2_010_000);
    }

    #[test]
    fn launched_runtime_cleans_headless_user_agent_once_and_replays_per_surface() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (seen_tx, seen_rx) = mpsc::channel();

        let server = thread::Builder::new()
            .name("browser-stealth-ua-fake-cdp".into())
            .spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut ws = accept(stream).unwrap();
                let mut start_count = 0;
                loop {
                    let request = read_ws_json(&mut ws);
                    let id = request["id"].clone();
                    let method = request["method"].as_str().unwrap().to_string();
                    seen_tx.send(request.clone()).unwrap();
                    match method.as_str() {
                        "Target.setDiscoverTargets" => {
                            write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                        }
                        "Browser.getVersion" => {
                            write_ws_json(
                                &mut ws,
                                json!({
                                    "id": id,
                                    "result": {
                                        "userAgent": "Mozilla/5.0 HeadlessChrome/136.0 HeadlessChrome/136.0 Safari/537.36"
                                    }
                                }),
                            );
                        }
                        "Emulation.setUserAgentOverride" => {
                            assert_eq!(
                                request["params"]["userAgent"],
                                "Mozilla/5.0 Chrome/136.0 Chrome/136.0 Safari/537.36"
                            );
                            write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                        }
                        "Page.getFrameTree" => {
                            write_ws_json(
                                &mut ws,
                                json!({
                                    "id": id,
                                    "result": {
                                        "frameTree": {
                                            "frame": {
                                                "id": "main-frame",
                                                "loaderId": "loader-1",
                                                "url": "about:blank"
                                            }
                                        }
                                    }
                                }),
                            );
                        }
                        "Page.enable"
                        | "Page.setLifecycleEventsEnabled"
                        | "Emulation.setDeviceMetricsOverride"
                        | "Page.startScreencast" => {
                            write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                            if method == "Page.startScreencast" {
                                start_count += 1;
                                if start_count == 2 {
                                    break;
                                }
                            }
                        }
                        method => panic!("unexpected CDP method {method}"),
                    }
                }
            })
            .unwrap();

        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::Launched,
        )
        .unwrap();
        let opts = SurfaceOptions::default();
        let first =
            new_surface(11, "https://one.test".into(), (10, 5), (8, 16), &opts, Weak::new())
                .unwrap();
        runtime
            .setup_attached_surface(&first, "target-1", "session-1", "https://one.test")
            .unwrap();
        let second =
            new_surface(12, "https://two.test".into(), (10, 5), (8, 16), &opts, Weak::new())
                .unwrap();
        runtime
            .setup_attached_surface(&second, "target-2", "session-2", "https://two.test")
            .unwrap();

        server.join().unwrap();
        let methods = seen_rx
            .try_iter()
            .map(|value| value["method"].as_str().unwrap().to_string())
            .collect::<Vec<_>>();
        assert_eq!(
            methods.iter().filter(|method| method.as_str() == "Browser.getVersion").count(),
            1
        );
        assert_eq!(
            methods
                .iter()
                .filter(|method| method.as_str() == "Emulation.setUserAgentOverride")
                .count(),
            2
        );
        runtime.shutdown();
    }

    #[test]
    fn launched_runtime_continues_when_browser_version_fails() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (seen_tx, seen_rx) = mpsc::channel();

        let server = thread::Builder::new()
            .name("browser-stealth-version-failure-fake-cdp".into())
            .spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut ws = accept(stream).unwrap();
                loop {
                    let request = read_ws_json(&mut ws);
                    let id = request["id"].clone();
                    let method = request["method"].as_str().unwrap().to_string();
                    seen_tx.send(request.clone()).unwrap();
                    match method.as_str() {
                        "Target.setDiscoverTargets" => {
                            write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                        }
                        "Browser.getVersion" => {
                            write_ws_json(
                                &mut ws,
                                json!({"id": id, "error": {"code": -32000, "message": "unavailable"}}),
                            );
                        }
                        "Page.getFrameTree" => {
                            write_ws_json(
                                &mut ws,
                                json!({
                                    "id": id,
                                    "result": {
                                        "frameTree": {
                                            "frame": {
                                                "id": "main-frame",
                                                "loaderId": "loader-1",
                                                "url": "about:blank"
                                            }
                                        }
                                    }
                                }),
                            );
                        }
                        "Page.enable"
                        | "Page.setLifecycleEventsEnabled"
                        | "Emulation.setDeviceMetricsOverride"
                        | "Page.startScreencast" => {
                            write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                            if method == "Page.startScreencast" {
                                break;
                            }
                        }
                        "Emulation.setUserAgentOverride" => {
                            panic!("user agent override should be skipped after getVersion failure")
                        }
                        method => panic!("unexpected CDP method {method}"),
                    }
                }
            })
            .unwrap();

        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::Launched,
        )
        .unwrap();
        let surface = test_surface();
        runtime
            .setup_attached_surface(&surface, "target-1", "session-1", "https://example.test")
            .unwrap();

        server.join().unwrap();
        let methods = seen_rx
            .try_iter()
            .map(|value| value["method"].as_str().unwrap().to_string())
            .collect::<Vec<_>>();
        assert!(methods.iter().any(|method| method == "Browser.getVersion"));
        assert!(!methods.iter().any(|method| method == "Emulation.setUserAgentOverride"));
        runtime.shutdown();
    }

    #[test]
    fn discovery_events_are_drained_before_the_discovery_response() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::Builder::new()
            .name("browser-discovery-backpressure-fake-cdp".into())
            .spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut ws = accept(stream).unwrap();
                let request = read_ws_json(&mut ws);
                assert_eq!(request["method"], "Target.setDiscoverTargets");
                for index in 0..=cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY {
                    write_ws_json(
                        &mut ws,
                        json!({
                            "method": "Target.targetCreated",
                            "params": {
                                "targetInfo": {
                                    "targetId": format!("target-{index}"),
                                    "type": "page",
                                    "title": "",
                                    "url": "about:blank"
                                }
                            }
                        }),
                    );
                }
                write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
            })
            .unwrap();
        let (done_tx, done_rx) = mpsc::sync_channel(1);
        let connect = thread::spawn(move || {
            done_tx
                .send(super::BrowserRuntime::connect_to_endpoint(
                    &format!("ws://{addr}/devtools/browser/fake"),
                    None,
                    BrowserSource::External,
                ))
                .unwrap();
        });

        let runtime = done_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("discovery events blocked the response")
            .unwrap();
        runtime.shutdown();
        connect.join().unwrap();
        server.join().unwrap();
    }

    #[test]
    fn stalled_surface_route_does_not_block_shared_cdp_reader() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (flood_tx, flood_rx) = mpsc::channel();
        let (sent_tx, sent_rx) = mpsc::channel();
        let (reply_tx, reply_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::Builder::new()
            .name("browser-surface-backpressure-fake-cdp".into())
            .spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut ws = accept(stream).unwrap();
                let request = read_ws_json(&mut ws);
                assert_eq!(request["method"], "Target.setDiscoverTargets");
                write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
                flood_rx.recv().unwrap();
                for index in 0..=(cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY + 1) {
                    write_ws_json(
                        &mut ws,
                        json!({
                            "method": "Target.targetInfoChanged",
                            "params": {
                                "targetInfo": {
                                    "targetId": "target-stalled",
                                    "type": "page",
                                    "title": format!("title-{index}"),
                                    "url": "https://example.test"
                                }
                            }
                        }),
                    );
                }
                sent_tx.send(()).unwrap();
                reply_rx.recv().unwrap();
                write_ws_json(
                    &mut ws,
                    json!({
                        "id": 2,
                        "result": {"userAgent": "Mozilla/5.0 Chrome/136.0 Safari/537.36"}
                    }),
                );
                let _ = stop_rx.recv();
            })
            .unwrap();

        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let _stalled_route = runtime.register("target-stalled", "session-stalled");
        flood_tx.send(()).unwrap();
        sent_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        thread::sleep(Duration::from_millis(50));

        let client = runtime.client.clone();
        let (version_tx, version_rx) = mpsc::channel();
        let version_call = thread::spawn(move || {
            version_tx.send(client.browser_version()).unwrap();
        });
        thread::sleep(Duration::from_millis(20));
        reply_tx.send(()).unwrap();
        let version = version_rx.recv_timeout(Duration::from_millis(200));
        stop_tx.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();
        version_call.join().unwrap();
        assert!(version.is_ok(), "stalled surface blocked the shared CDP reader: {version:?}");
    }

    #[test]
    fn title_event_burst_keeps_surface_route_live_and_delivers_latest() {
        let route = Arc::new(super::SurfaceRoute::new());
        let event = |index| {
            cmux_tui_cdp::CdpEvent::TargetInfoChanged(cmux_tui_cdp::TargetInfo {
                session_id: Some("session-1".to_string()),
                target_id: "target-1".to_string(),
                title: format!("title-{index}"),
                url: "https://example.test".to_string(),
            })
        };

        assert!(!route.deliver(event(0)));
        for index in 1..=cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY {
            assert!(!route.deliver(event(index)));
        }
        assert!(!route.is_closed());

        let mut latest = String::new();
        while let Some(received) = route.try_recv() {
            if let cmux_tui_cdp::CdpEvent::TargetInfoChanged(info) = received {
                latest = info.title;
                if latest == format!("title-{}", cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY) {
                    break;
                }
            }
        }
        assert_eq!(latest, format!("title-{}", cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY));
    }

    #[test]
    fn coalesced_surface_state_keeps_chronological_order() {
        let route = Arc::new(super::SurfaceRoute::new());
        let target = |title: &str| {
            cmux_tui_cdp::CdpEvent::TargetInfoChanged(cmux_tui_cdp::TargetInfo {
                session_id: Some("session-1".to_string()),
                target_id: "target-1".to_string(),
                title: title.to_string(),
                url: "https://example.test".to_string(),
            })
        };
        assert!(!route.deliver(target("old")));
        assert!(!route.deliver(cmux_tui_cdp::CdpEvent::FrameNavigated {
            params: Value::Null,
            session_id: "session-1".to_string(),
            frame_epoch: 1,
        }));
        assert!(!route.deliver(target("new")));

        assert!(matches!(route.try_recv().unwrap(), cmux_tui_cdp::CdpEvent::FrameNavigated { .. }));
        assert!(matches!(
            route.try_recv().unwrap(),
            cmux_tui_cdp::CdpEvent::TargetInfoChanged(cmux_tui_cdp::TargetInfo { title, .. })
                if title == "new"
        ));
    }

    #[test]
    fn surface_route_retains_only_the_latest_screencast_frame() {
        let route = Arc::new(super::SurfaceRoute::new());
        let frame = |index| {
            cmux_tui_cdp::CdpEvent::ScreencastFrame(cmux_tui_cdp::ScreencastFrame {
                session_id: "session-1".to_string(),
                data_b64: format!("frame-{index}"),
                css_width: 80,
                css_height: 24,
                image_width: 80,
                image_height: 24,
                ack_id: index,
                frame_epoch: 0,
            })
        };

        for index in 1..=3 {
            assert!(!route.deliver(frame(index)));
        }
        let received = route.try_recv().unwrap();
        let cmux_tui_cdp::CdpEvent::ScreencastFrame(frame) = received else {
            panic!("expected a screencast frame");
        };
        assert_eq!(frame.ack_id, 3);
        assert!(route.try_recv().is_none(), "stale frames remained queued");
    }

    #[test]
    fn critical_overflow_does_not_silently_evict_latest_frame() {
        let route = Arc::new(super::SurfaceRoute::new());
        let frame = cmux_tui_cdp::CdpEvent::ScreencastFrame(cmux_tui_cdp::ScreencastFrame {
            session_id: "session-1".to_string(),
            data_b64: "frame-latest".to_string(),
            css_width: 80,
            css_height: 24,
            image_width: 80,
            image_height: 24,
            ack_id: 1,
            frame_epoch: 0,
        });
        assert!(!route.deliver(frame));
        for index in 1..cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY {
            assert!(!route.deliver(cmux_tui_cdp::CdpEvent::Other {
                method: format!("Test.event{index}"),
                params: Value::Null,
                session_id: Some("session-1".to_string()),
            }));
        }

        let overflowed = route.deliver(cmux_tui_cdp::CdpEvent::Other {
            method: "Test.overflow".to_string(),
            params: Value::Null,
            session_id: Some("session-1".to_string()),
        });
        assert!(overflowed, "critical overflow silently evicted authoritative state");
        assert!(route.is_closed());
    }

    #[test]
    fn final_frame_overflow_fails_route_instead_of_going_stale() {
        let route = Arc::new(super::SurfaceRoute::new());
        for index in 0..cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY {
            assert!(!route.deliver(cmux_tui_cdp::CdpEvent::Other {
                method: format!("Test.event{index}"),
                params: Value::Null,
                session_id: Some("session-1".to_string()),
            }));
        }
        let overflowed =
            route.deliver(cmux_tui_cdp::CdpEvent::ScreencastFrame(cmux_tui_cdp::ScreencastFrame {
                session_id: "session-1".to_string(),
                data_b64: "frame-final".to_string(),
                css_width: 80,
                css_height: 24,
                image_width: 80,
                image_height: 24,
                ack_id: 1,
                frame_epoch: 0,
            }));

        assert!(overflowed);
        assert!(route.is_closed());
    }

    #[test]
    fn oversized_surface_event_fails_the_route() {
        let route = Arc::new(super::SurfaceRoute::new());
        let overflowed = route.deliver(cmux_tui_cdp::CdpEvent::Other {
            method: "Test.large".to_string(),
            params: json!({
                "payload": "x".repeat(cmux_tui_cdp::CDP_EVENT_QUEUE_MAX_BYTES),
            }),
            session_id: Some("session-1".to_string()),
        });

        assert!(overflowed);
        assert!(route.is_closed());
    }

    #[test]
    fn unregister_closes_and_wakes_surface_route() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let request = read_ws_json(&mut ws);
            assert_eq!(request["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
            let _ = stop_rx.recv();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let route = runtime.register("target-1", "session-1");
        let cleanup_route = route.clone();
        let (done_tx, done_rx) = mpsc::channel();
        let waiter = thread::spawn(move || {
            let first = route.recv();
            let second = route.recv();
            done_tx.send((first, second)).unwrap();
        });

        runtime.unregister("target-1", "session-1");
        let events = done_rx.recv_timeout(Duration::from_millis(200));
        stop_tx.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();
        if events.is_err() {
            cleanup_route.close(CdpCloseReason::SurfaceClosed);
        }
        waiter.join().unwrap();
        let (first, second) = events.expect("unregister left surface route blocked");
        assert!(matches!(first, Some(cmux_tui_cdp::CdpEvent::Closed(_))));
        assert!(second.is_none());
    }

    #[test]
    fn shutdown_closes_and_wakes_surface_route_before_cdp_disconnect() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let request = read_ws_json(&mut ws);
            assert_eq!(request["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
            let _ = stop_rx.recv();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let route = runtime.register("target-1", "session-1");
        let (done_tx, done_rx) = mpsc::channel();
        let waiter = thread::spawn(move || {
            let first = route.recv();
            let second = route.recv();
            done_tx.send((first, second)).unwrap();
        });

        runtime.shutdown();
        let (first, second) = done_rx
            .recv_timeout(Duration::from_millis(200))
            .expect("shutdown left surface route blocked");
        assert!(matches!(first, Some(cmux_tui_cdp::CdpEvent::Closed(_))));
        assert!(second.is_none());

        stop_tx.send(()).unwrap();
        server.join().unwrap();
        waiter.join().unwrap();
    }

    #[test]
    fn closed_surface_route_closes_its_cdp_target() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (closed_tx, closed_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
            let close = read_ws_json(&mut ws);
            assert_eq!(close["method"], "Target.closeTarget");
            assert_eq!(close["params"]["targetId"], "target-1");
            write_ws_json(&mut ws, json!({"id": close["id"], "result": {"success": true}}));
            closed_tx.send(()).unwrap();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().unwrap();
        let route = runtime.register("target-1", "session-1");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        start_surface_thread(
            surface.clone(),
            route.clone(),
            Weak::new(),
            Arc::downgrade(&runtime),
            "session-1".to_string(),
        )
        .unwrap();

        route.close(CdpCloseReason::EventQueueOverflow);
        closed_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("closed surface route did not close its CDP target");
        assert!(browser.is_dead());
        assert!(browser.session.lock().unwrap().is_none());

        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn external_runtime_does_not_query_or_override_user_agent() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();

        let server = thread::Builder::new()
            .name("browser-external-stealth-negative-fake-cdp".into())
            .spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut ws = accept(stream).unwrap();
                loop {
                    let request = read_ws_json(&mut ws);
                    let id = request["id"].clone();
                    let method = request["method"].as_str().unwrap().to_string();
                    match method.as_str() {
                        "Target.setDiscoverTargets" => {
                            write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                        }
                        "Page.getFrameTree" => {
                            write_ws_json(
                                &mut ws,
                                json!({
                                    "id": id,
                                    "result": {
                                        "frameTree": {
                                            "frame": {
                                                "id": "main-frame",
                                                "loaderId": "loader-1",
                                                "url": "about:blank"
                                            }
                                        }
                                    }
                                }),
                            );
                        }
                        "Page.enable"
                        | "Page.setLifecycleEventsEnabled"
                        | "Emulation.setDeviceMetricsOverride"
                        | "Page.startScreencast" => {
                            write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                            if method == "Page.startScreencast" {
                                break;
                            }
                        }
                        "Browser.getVersion" | "Emulation.setUserAgentOverride" => {
                            panic!(
                                "external runtimes must not receive launched-runtime stealth calls"
                            )
                        }
                        method => panic!("unexpected CDP method {method}"),
                    }
                }
            })
            .unwrap();

        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        runtime
            .setup_attached_surface(&surface, "target-1", "session-1", "https://example.test")
            .unwrap();

        server.join().unwrap();
        runtime.shutdown();
    }

    #[test]
    fn setup_subscribes_before_seeding_main_frame_authority() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::Builder::new()
            .name("browser-main-frame-seed-fake-cdp".into())
            .spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut ws = accept(stream).unwrap();
                let discover = read_ws_json(&mut ws);
                assert_eq!(discover["method"], "Target.setDiscoverTargets");
                write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

                for expected in ["Page.enable", "Page.setLifecycleEventsEnabled"] {
                    let request = read_ws_json(&mut ws);
                    assert_eq!(
                        request["method"], expected,
                        "document events must be subscribed before authority is snapshotted"
                    );
                    write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
                }

                let frame_tree = read_ws_json(&mut ws);
                assert_eq!(
                    frame_tree["method"], "Page.getFrameTree",
                    "the post-subscription snapshot must reconcile the current root loader"
                );
                write_ws_json(
                    &mut ws,
                    json!({
                        "id": frame_tree["id"],
                        "result": {
                            "frameTree": {
                                "frame": {
                                    "id": "main-frame",
                                    "loaderId": "loader-1",
                                    "url": "https://example.test"
                                }
                            }
                        }
                    }),
                );

                for expected in ["Emulation.setDeviceMetricsOverride", "Page.startScreencast"] {
                    let request = read_ws_json(&mut ws);
                    assert_eq!(request["method"], expected);
                    write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
                }
            })
            .unwrap();

        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());

        runtime
            .setup_attached_surface(&surface, "target-1", "session-1", "https://example.test")
            .unwrap();

        server.join().unwrap();
        runtime.shutdown();
    }

    #[test]
    fn latest_navigation_slot_drains_once() {
        let latest_nav = Arc::new(Mutex::new(Some(SequencedBrowserCommand {
            sequence: 7,
            command: BrowserCommand::Navigate("https://next.test".to_string()),
        })));

        let command = take_latest_worker_commands(&latest_nav).expect("pending navigation");
        assert_eq!(command.sequence, 7);
        match &command.command {
            BrowserCommand::Navigate(url) => assert_eq!(url, "https://next.test"),
            _ => panic!("nav command was lost"),
        }
        assert!(latest_nav.lock().unwrap().is_none());
    }

    #[test]
    fn coalesced_navigation_keeps_replacement_order_after_intervening_input() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
        started.recv_timeout(Duration::from_secs(1)).unwrap();

        browser.navigate("https://first.test").unwrap();
        browser.mouse_event("mousePressed", 1.0, 1.0, Some("left"), Some(1)).unwrap();
        let replacement_sequence = browser.command_order.lock().unwrap().next_sequence;
        browser.navigate("https://latest.test").unwrap();

        {
            let pending = browser.latest_nav.lock().unwrap();
            let pending = pending.as_ref().expect("coalesced navigation");
            assert_eq!(
                pending.sequence, replacement_sequence,
                "the replacement navigation must retain its position after intervening pointer input"
            );
            assert!(matches!(
                &pending.command,
                BrowserCommand::Navigate(url) if url == "https://latest.test"
            ));
        }

        release.send(()).unwrap();
        browser.kill();
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after kill");
    }

    #[test]
    fn replacing_queued_screencast_authority_releases_its_reservation() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        browser.store_frame(test_frame(1));
        let frame_epoch = browser.frame_epoch.current();
        let navigation_epoch = browser.frame_epoch.latest_navigation();
        let reservation_id = 71;
        assert!(browser.reserve_screencast_capture(reservation_id, frame_epoch, navigation_epoch,));
        browser
            .enqueue_latest_authority(BrowserCommand::AuthorizeScreencastCapture {
                session_id: "session-1".to_string(),
                frame_id: "main-frame".to_string(),
                loader_id: "loader-1".to_string(),
                reservation_id,
                frame_epoch,
                navigation_epoch,
            })
            .unwrap();
        browser
            .enqueue_latest_authority(BrowserCommand::AuthorizeSameDocumentPaint {
                session_id: "session-1".to_string(),
                frame_id: "main-frame".to_string(),
                loader_id: "loader-1".to_string(),
            })
            .unwrap();

        let released = browser.state.lock().unwrap().pending_screencast_capture.is_none();
        browser.kill();
        release.send(()).unwrap();
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after kill");
        assert!(released, "replacing a queued recovery must not retain its ownership token");
    }

    #[test]
    fn kill_drops_sender_and_worker_exits() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();

        browser.kill();
        assert!(browser.navigate("after-close.test").is_err());
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after kill");
    }

    #[test]
    fn browser_resizes_preserve_input_barriers_and_completion() {
        let mux = Mux::new("ordered-browser-resize-test", SurfaceOptions::default());
        let surface = new_surface(
            1,
            "https://example.test".into(),
            (10, 5),
            (8, 16),
            &SurfaceOptions::default(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let events = mux.subscribe();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
        started.recv_timeout(Duration::from_secs(1)).unwrap();

        assert!(browser.resize(11, 5).unwrap());
        browser.mouse_event("mousePressed", 1.0, 1.0, Some("left"), Some(1)).unwrap();
        assert!(browser.resize(12, 6).unwrap());

        release.send(()).unwrap();
        let resized = (0..2)
            .map(|_| {
                loop {
                    if let MuxEvent::SurfaceResized { cols, rows, .. } = events.recv().unwrap() {
                        break (cols, rows);
                    }
                }
            })
            .collect::<Vec<_>>();
        assert_eq!(resized, vec![(11, 5), (12, 6)]);
        browser.kill();
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after release");
    }

    #[test]
    fn full_command_queue_retains_mouse_releases_without_unbounded_growth() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        browser.enqueue_control(BrowserCommand::Hold { entered, release: held }).unwrap();
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
            browser.enqueue_control(BrowserCommand::Activate).unwrap();
        }

        let (attempting_tx, attempting_rx) = mpsc::channel();
        let (enqueued_tx, enqueued_rx) = mpsc::channel();
        let release_surface = surface.clone();
        let enqueue = thread::spawn(move || {
            attempting_tx.send(()).unwrap();
            let result = release_surface.browser_mouse_event(
                "mouseReleased",
                1.0,
                1.0,
                Some("left"),
                Some(1),
            );
            enqueued_tx.send(result).unwrap();
        });
        attempting_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        enqueued_rx
            .recv_timeout(Duration::from_millis(100))
            .expect("retaining a mouse release must not wait for regular queue capacity")
            .unwrap();
        for offset in 1..super::BROWSER_RETAINED_RELEASE_CAPACITY {
            surface
                .browser_mouse_event(
                    "mouseReleased",
                    1.0 + offset as f64,
                    1.0,
                    Some("left"),
                    Some(1),
                )
                .expect("the bounded release lane must retain accepted releases");
        }
        assert!(
            surface
                .browser_mouse_event("mouseReleased", 100.0, 2.0, Some("left"), Some(1))
                .is_err(),
            "the bounded release lane must reject input beyond its capacity"
        );

        release.send(()).unwrap();
        enqueue.join().unwrap();
        browser.kill();
        done.recv_timeout(Duration::from_secs(1))
            .expect("browser worker exited after reliable release");
    }

    #[test]
    fn timeout_failed_status_notice_is_emitted_once_per_stall_episode() {
        let surface = test_surface();
        let mux = Mux::new("timeout-latch-test", SurfaceOptions::default());
        let events = mux.subscribe();
        let weak = Arc::downgrade(&mux);
        let mut failures = super::BrowserWorkerErrorState::default();

        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            false,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
            &mut failures,
        );
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)).unwrap(),
            MuxEvent::Status(message) if message == "CDP call Page.navigate timed out"
        ));
        while events.try_recv().is_ok() {}

        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            false,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
            &mut failures,
        );
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)).unwrap(),
            MuxEvent::Status(message) if message == super::BROWSER_NOT_RESPONDING_MESSAGE
        ));
        while events.try_recv().is_ok() {}

        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            false,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
            &mut failures,
        );
        assert!(events.recv_timeout(Duration::from_millis(100)).is_err());
    }

    #[test]
    fn locally_discarded_pointer_input_preserves_browser_timeout_streak() {
        let (runtime, server, dispatched, stop) = runtime_recording_mouse_dispatches();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let mux = Mux::new("discarded-pointer-timeout-test", SurfaceOptions::default());
        let events = mux.subscribe();
        let weak = Arc::downgrade(&mux);
        let mut failures = super::BrowserWorkerErrorState::default();

        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            false,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
            &mut failures,
        );
        while events.try_recv().is_ok() {}
        browser.invalidate_pointer_frame();
        let discarded = browser.mouse_event_blocking(
            super::BrowserMouseDispatch {
                input_owner: super::BrowserPointerOwner::Local,
                event_type: "mouseMoved",
                x: 1.0,
                y: 1.0,
                button: None,
                click_count: None,
                frame_seq: Some(1),
            },
            &mut failures.active_pointer_presses,
        );
        assert_eq!(discarded.as_ref().unwrap(), &super::BrowserWorkerSuccess::LocallySettled);
        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            true,
            discarded,
            &mut failures,
        );
        let streak_after_discard = failures.consecutive_timeouts;

        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            false,
            Err(anyhow::anyhow!("CDP call Page.reload timed out")),
            &mut failures,
        );
        let reported_not_responding = events.try_iter().any(|event| {
            matches!(
                event,
                MuxEvent::Status(message) if message == super::BROWSER_NOT_RESPONDING_MESSAGE
            )
        });
        let dispatched_stale_input = dispatched.recv_timeout(Duration::from_millis(100)).is_ok();

        stop.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();

        assert_eq!(
            streak_after_discard, 1,
            "a locally discarded pointer sample must not count as a browser response"
        );
        assert!(
            reported_not_responding,
            "the second real CDP timeout must still enter the visible recovery state"
        );
        assert!(!dispatched_stale_input, "stale pointer input must remain local");
    }

    #[test]
    fn frame_clearing_not_responding_rearms_timeout_notice() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let mux = Mux::new("timeout-frame-reset-test", SurfaceOptions::default());
        let events = mux.subscribe();
        let weak = Arc::downgrade(&mux);
        let mut failures = super::BrowserWorkerErrorState::default();

        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            false,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
            &mut failures,
        );
        while events.try_recv().is_ok() {}

        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            false,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
            &mut failures,
        );
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)).unwrap(),
            MuxEvent::Status(message) if message == super::BROWSER_NOT_RESPONDING_MESSAGE
        ));
        assert_eq!(
            browser.status(),
            BrowserStatus::Failed(super::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
        );
        while events.try_recv().is_ok() {}

        browser.store_frame(test_frame(1));
        assert_eq!(browser.status(), BrowserStatus::Live);

        super::record_browser_worker_result(
            &surface,
            &weak,
            surface.id,
            false,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
            &mut failures,
        );
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)).unwrap(),
            MuxEvent::Status(message) if message == super::BROWSER_NOT_RESPONDING_MESSAGE
        ));
        assert_eq!(
            browser.status(),
            BrowserStatus::Failed(super::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
        );
    }

    // Regression: when a fresh frame clears the worker's not-responding
    // failure, the recovery must be broadcast to attach clients (remote TUIs),
    // not just flipped in memory. Before the fix `store_frame` set status back
    // to Live but left the "browser failed: ..." title `mark_failed` had
    // written and never marked the state dirty, so attached clients stayed
    // stuck on the failed status/title even as frames streamed in.
    #[test]
    fn recovery_from_not_responding_broadcasts_live_state_to_attach_clients() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        // Give the surface a known URL so the recovered title is derived from it.
        browser.set_url_title("https://recovered.test".to_string(), "recovered".to_string());
        // Attach before the failure so the tap observes both the failure and the recovery.
        let (_snapshot, stream) = browser.attach_frames();

        let failed_title = format!("browser failed: {}", super::BROWSER_NOT_RESPONDING_MESSAGE);
        browser.mark_not_responding();
        let failed = stream.slot.lock().unwrap().state.clone().expect("failure was broadcast");
        assert_eq!(
            failed.status,
            BrowserStatus::Failed(super::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
        );
        assert_eq!(failed.title, failed_title);
        // Simulate the event thread drawing the failure and consuming the dirty
        // flag, so the recovery below starts from a clean flag like it would in
        // production.
        assert!(browser.take_dirty(), "mark_failed must mark the surface dirty");

        // A fresh frame proves Chrome recovered.
        browser.store_frame(test_frame(1));
        assert_eq!(browser.status(), BrowserStatus::Live);
        // The event thread that delivers this frame emits the local TUI redraw
        // via `if !dirty.swap(true)`. store_frame must leave that transition
        // available (dirty still clear) instead of pre-consuming it, or the
        // local status line stays stuck on the failure.
        assert!(
            !browser.take_dirty(),
            "recovery must not pre-consume the dirty transition the event thread emits on"
        );
        let recovered =
            stream.slot.lock().unwrap().state.clone().expect("recovery must be broadcast too");
        assert_eq!(recovered.status, BrowserStatus::Live);
        assert_ne!(
            recovered.title, failed_title,
            "recovered attach state still shows the stale failure title"
        );
        assert_eq!(recovered.title, "https://recovered.test");
        let recovered_frame =
            stream.slot.lock().unwrap().frame.clone().expect("recovery must publish the frame");
        assert_eq!(
            recovered.pointer_frame_seq, recovered_frame.pointer_frame_seq,
            "coalesced recovery state must not revoke the frame's pointer authority"
        );
        assert!(
            recovered.pointer_frame_seq.is_some(),
            "the recovery snapshot must expose the fresh frame's pointer authority"
        );
    }

    #[test]
    fn runtime_never_discovers_or_launches_an_isolated_browser() {
        let opts = SurfaceOptions::default();
        let explicit_opts = SurfaceOptions {
            cdp_url: Some("ws://127.0.0.1:9/devtools/browser/explicit".to_string()),
            ..opts.clone()
        };
        let (url, chrome, source) = runtime_endpoint(&explicit_opts).unwrap();
        assert_eq!(url, "ws://127.0.0.1:9/devtools/browser/explicit");
        assert!(chrome.is_none());
        assert_eq!(source, BrowserSource::External);

        let error = runtime_endpoint(&opts).err().expect("provider-less runtime must fail");
        assert!(error.to_string().contains("no cmux-browser provider is attached"));

        let discover_opts = SurfaceOptions {
            browser_discover: true,
            browser_discover_ports: vec![9],
            chrome_binary: Some("/definitely/missing/chrome".to_string()),
            ..opts
        };
        let error = runtime_endpoint(&discover_opts)
            .err()
            .expect("legacy discovery options must not launch or discover Chrome");
        assert!(error.to_string().contains("no cmux-browser provider is attached"));
    }

    #[test]
    fn input_mapping_uses_latest_frame_viewport() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new())
                .unwrap();
        let browser = surface.as_browser().expect("browser surface");
        {
            let state = browser.state.lock().unwrap();
            assert_eq!(state.pane_pixels, (4760, 2548));
        }

        let mut frame = test_frame(1);
        frame.css_width = 2320;
        frame.css_height = 1363;
        browser.store_frame(frame);

        assert_eq!(browser.scale_input_point(2380.0, 1274.0), (1160.0, 681.5));
        assert_eq!(browser.scale_delta(100.0), 100.0 * 1363.0 / 2548.0);
    }

    #[test]
    fn input_mapping_falls_back_to_capture_pixels_before_first_frame() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new())
                .unwrap();
        let browser = surface.as_browser().expect("browser surface");

        assert_eq!(browser.scale_input_point(2380.0, 1274.0), (966.5, 517.5));
        let expected_scale = browser.state.lock().unwrap().capture_scale;
        assert!((browser.scale_delta(100.0) - 100.0 * expected_scale).abs() < f64::EPSILON);
    }

    #[test]
    fn input_mapping_uses_new_capture_geometry_while_waiting_for_resized_frame() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new())
                .unwrap();
        let browser = surface.as_browser().expect("browser surface");

        let mut frame = test_frame(1);
        frame.css_width = 2320;
        frame.css_height = 1363;
        browser.store_frame(frame);

        let queued = browser.reserve_reconfigure(400, 100).expect("changed geometry");
        browser.confirm_reconfigure(queued, browser.frame_epoch.advance());

        let state = browser.state.lock().unwrap();
        assert_eq!(state.latest_frame, None);
        assert_eq!(state.page_viewport, None);
        let (pane_width, pane_height) = state.pane_pixels;
        let (capture_width, capture_height) = state.capture_pixels;
        let capture_scale = state.capture_scale;
        drop(state);

        assert_eq!(
            browser.scale_input_point(f64::from(pane_width), f64::from(pane_height)),
            (f64::from(capture_width), f64::from(capture_height))
        );
        assert!((browser.scale_delta(100.0) - 100.0 * capture_scale).abs() < f64::EPSILON);
    }

    #[test]
    fn input_mapping_clamps_to_page_viewport() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));

        assert_eq!(browser.scale_input_point(-5.0, 999.0), (0.0, 48.0));
    }

    #[test]
    fn guarded_input_mapping_requires_current_route_pointer_authority() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some());

        browser.store_frame(test_frame(2));
        assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some());
        assert!(
            browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_none(),
            "receiving a replacement frame must not acknowledge its presentation"
        );
        acknowledge_local_presentation(browser, 2);
        assert!(
            browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none(),
            "acknowledging the replacement must retire the owner's previous exact token"
        );
        assert!(browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_some());

        browser.mark_failed("failed".to_string());
        assert!(browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_none());
    }

    #[test]
    fn pointer_presentations_are_exact_and_scoped_to_each_input_owner() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let first = super::BrowserPointerOwner::Client(7);
        let second = super::BrowserPointerOwner::Client(8);
        browser.store_frame(test_frame(1));

        assert!(browser.acknowledge_pointer_frame_from(first, 1));
        {
            let state = browser.state.lock().unwrap();
            assert!(browser.presented_pointer_frame_is_current_locked(&state, first, 1));
            assert!(!browser.presented_pointer_frame_is_current_locked(&state, second, 1));
        }

        browser.store_frame(test_frame(2));
        {
            let state = browser.state.lock().unwrap();
            assert!(browser.presented_pointer_frame_is_current_locked(&state, first, 1));
            assert!(!browser.presented_pointer_frame_is_current_locked(&state, first, 2));
        }
        assert!(browser.acknowledge_pointer_frame_from(first, 2));
        {
            let state = browser.state.lock().unwrap();
            assert!(!browser.presented_pointer_frame_is_current_locked(&state, first, 1));
            assert!(browser.presented_pointer_frame_is_current_locked(&state, first, 2));
            assert!(!browser.presented_pointer_frame_is_current_locked(&state, second, 2));
        }
        browser.forget_pointer_owner(first);
        assert!(browser.state.lock().unwrap().presented_pointer_frames.is_empty());
    }

    #[test]
    fn queued_pointer_admission_survives_only_same_route_repaints() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let owner = super::BrowserPointerOwner::Client(7);
        browser.store_frame(test_frame(1));
        let admission =
            browser.admit_pointer_frame(owner, Some(1)).expect("initial pointer admission");

        browser.store_frame(test_frame(2));
        assert!(browser.acknowledge_pointer_frame_from(owner, 2));
        assert!(
            browser
                .scale_guarded_input_point_from(owner, Some(1), Some(admission), 1.0, 1.0)
                .is_some(),
            "a later presentation must not discard an already queued click"
        );

        browser.invalidate_pointer_frame();
        assert!(
            browser
                .scale_guarded_input_point_from(owner, Some(1), Some(admission), 1.0, 1.0)
                .is_none(),
            "document or geometry invalidation must still revoke queued input"
        );
    }

    #[test]
    fn ingress_navigation_epoch_revokes_pointer_before_surface_event_delivery() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let (_, capture_generation, _, _) =
            browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live pointer capture");

        browser.frame_epoch.advance_navigation();

        assert!(
            browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none(),
            "a queued navigation event must close guarded pointer admission at CDP ingress"
        );
        assert!(
            browser.capture_guarded_input_point(1, 1.0, 1.0).is_none(),
            "a queued navigation event must reject a new pointer capture"
        );
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_none(),
            "a queued navigation event must revoke an existing pointer capture"
        );
    }

    #[test]
    fn navigation_invalidates_pointer_admission_until_a_new_frame() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some());
        assert_eq!(browser.latest_frame_seq(), Some(1));

        let frame_epoch = browser.frame_epoch.advance_navigation();
        handle_frame_navigated(
            browser,
            json!({"frame": {"url": "https://next.test", "name": "next"}}),
            frame_epoch,
        );

        assert_eq!(
            browser.latest_frame().map(|frame| frame.seq),
            Some(1),
            "navigation keeps the last image available for rendering"
        );
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "the retained image must not remain pointer-admissible"
        );
        assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none());
        browser.store_frame(test_frame(2));
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "an unverified streamed frame must remain non-interactive"
        );
        assert!(browser.accept_document_paint(frame_epoch, frame_epoch, test_frame(2)));
        assert_eq!(browser.latest_frame_seq(), Some(2));
        assert!(
            browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_none(),
            "verified pixels must still wait for the renderer presentation"
        );
        acknowledge_local_presentation(browser, 2);
        assert!(browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_some());
    }

    #[test]
    fn post_commit_screencast_frame_does_not_claim_document_authority() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));

        let navigation_epoch = browser.frame_epoch.advance_navigation();
        handle_frame_navigated(
            browser,
            json!({
                "frame": {
                    "id": "main-frame",
                    "loaderId": "next-loader",
                    "url": "https://next.test"
                }
            }),
            navigation_epoch,
        );
        browser.store_frame_for_epoch(test_frame(2), navigation_epoch);

        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "a streamed frame without committed-loader paint proof must remain non-interactive"
        );
    }

    #[test]
    fn old_screencast_generation_cannot_overwrite_authorized_pixels() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let navigation_epoch = browser.frame_epoch.advance_navigation();
        handle_frame_navigated(
            browser,
            json!({
                "frame": {
                    "id": "main-frame",
                    "loaderId": "next-loader",
                    "url": "https://next.test"
                }
            }),
            navigation_epoch,
        );
        let capture_epoch = browser.frame_epoch.advance();
        assert!(browser.accept_document_paint(navigation_epoch, capture_epoch, test_frame(2)));

        browser.store_frame_for_epoch(test_frame(3), navigation_epoch);
        assert_eq!(
            browser.latest_frame_seq(),
            Some(2),
            "a delayed frame from the stopped stream must not replace authorized pixels"
        );
        browser.store_frame_for_epoch(test_frame(3), capture_epoch);
        assert_eq!(
            browser.latest_frame_seq(),
            Some(3),
            "the restarted stream must bind authority to its newly admitted bitmap"
        );
        assert_eq!(
            browser.latest_frame().map(|frame| frame.seq),
            Some(3),
            "the restarted stream may advance the visual frame"
        );
    }

    #[test]
    fn lifecycle_paint_authorizes_loader_bracketed_capture_end_to_end() {
        const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (start_tx, start_rx) = mpsc::channel();
        let (next_frame_tx, next_frame_rx) = mpsc::channel();
        let (recaptured_tx, recaptured_rx) = mpsc::channel();
        let (race_start_tx, race_start_rx) = mpsc::channel();
        let (stale_capture_started_tx, stale_capture_started_rx) = mpsc::channel();
        let (send_replacement_tx, send_replacement_rx) = mpsc::channel();
        let (replacement_sent_tx, replacement_sent_rx) = mpsc::channel();
        let (release_stale_tx, release_stale_rx) = mpsc::channel();
        let (replacement_captured_tx, replacement_captured_rx) = mpsc::channel();
        let (final_frame_tx, final_frame_rx) = mpsc::channel();
        let (final_capture_tx, final_capture_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
            start_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.frameNavigated",
                    "sessionId": "session-1",
                    "params": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "loader-2",
                            "url": "https://next.test"
                        }
                    }
                }),
            );
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "AAAA",
                        "sessionId": 9,
                        "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                    }
                }),
            );
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.lifecycleEvent",
                    "sessionId": "session-1",
                    "params": {
                        "frameId": "main-frame",
                        "loaderId": "loader-2",
                        "name": "firstPaint",
                        "timestamp": 1.0
                    }
                }),
            );

            let mut authority_calls = 0;
            while authority_calls < 7 {
                let request = read_ws_json(&mut ws);
                match request["method"].as_str().unwrap() {
                    "Page.screencastFrameAck" => {}
                    "Page.stopScreencast" | "Page.startScreencast" => {
                        authority_calls += 1;
                        write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
                    }
                    "Page.getFrameTree" => {
                        authority_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {
                                    "frameTree": {
                                        "frame": {
                                            "id": "main-frame",
                                            "loaderId": "loader-2",
                                            "url": "https://next.test"
                                        }
                                    }
                                }
                            }),
                        );
                    }
                    "Page.createIsolatedWorld" => {
                        authority_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {"executionContextId": 41}
                            }),
                        );
                    }
                    "Runtime.evaluate" => {
                        authority_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {
                                    "result": {"type": "number", "value": 10_000.0}
                                }
                            }),
                        );
                    }
                    "Page.captureScreenshot" => {
                        authority_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {"data": ONE_PIXEL_PNG}
                            }),
                        );
                    }
                    method => panic!("unexpected CDP method {method}"),
                }
            }
            next_frame_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "c2Vjb25k",
                        "sessionId": 10,
                        "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                    }
                }),
            );
            let mut recapture_calls = 0;
            while recapture_calls < 3 {
                let request = read_ws_json(&mut ws);
                match request["method"].as_str().unwrap() {
                    "Page.screencastFrameAck" => {}
                    "Page.getFrameTree" => {
                        recapture_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {
                                    "frameTree": {
                                        "frame": {
                                            "id": "main-frame",
                                            "loaderId": "loader-2",
                                            "url": "https://next.test"
                                        }
                                    }
                                }
                            }),
                        );
                    }
                    "Page.captureScreenshot" => {
                        recapture_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {"data": ONE_PIXEL_PNG}
                            }),
                        );
                    }
                    method => panic!("unexpected CDP method {method}"),
                }
            }
            recaptured_tx.send(()).unwrap();
            race_start_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "cHJlcA==",
                        "sessionId": 11,
                        "metadata": {
                            "deviceWidth": 80,
                            "deviceHeight": 48,
                            "timestamp": 10_001.0
                        }
                    }
                }),
            );
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "c3RhbGU=",
                        "sessionId": 12,
                        "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                    }
                }),
            );
            loop {
                let request = read_ws_json(&mut ws);
                match request["method"].as_str().unwrap() {
                    "Page.screencastFrameAck" => {}
                    "Page.getFrameTree" => {
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {
                                    "frameTree": {
                                        "frame": {
                                            "id": "main-frame",
                                            "loaderId": "loader-2",
                                            "url": "https://next.test"
                                        }
                                    }
                                }
                            }),
                        );
                    }
                    "Page.captureScreenshot" => {
                        stale_capture_started_tx.send(()).unwrap();
                        send_replacement_rx.recv_timeout(Duration::from_secs(1)).unwrap();
                        write_ws_json(
                            &mut ws,
                            json!({
                                "method": "Page.screencastFrame",
                                "sessionId": "session-1",
                                "params": {
                                    "data": "dGltZWQ=",
                                    "sessionId": 13,
                                    "metadata": {
                                        "deviceWidth": 80,
                                        "deviceHeight": 48,
                                        "timestamp": 10_002.0
                                    }
                                }
                            }),
                        );
                        write_ws_json(
                            &mut ws,
                            json!({
                                "method": "Page.screencastFrame",
                                "sessionId": "session-1",
                                "params": {
                                    "data": "bmV3ZXI=",
                                    "sessionId": 14,
                                    "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                                }
                            }),
                        );
                        replacement_sent_tx.send(()).unwrap();
                        release_stale_rx.recv_timeout(Duration::from_secs(1)).unwrap();
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "error": {
                                    "code": -32000,
                                    "message": "CDP call Page.captureScreenshot timed out"
                                }
                            }),
                        );
                        break;
                    }
                    method => panic!("unexpected CDP method {method}"),
                }
            }
            let mut replacement_calls = 0;
            while replacement_calls < 3 {
                let request = read_ws_json(&mut ws);
                match request["method"].as_str().unwrap() {
                    "Page.screencastFrameAck" => {}
                    "Page.getFrameTree" => {
                        replacement_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {
                                    "frameTree": {
                                        "frame": {
                                            "id": "main-frame",
                                            "loaderId": "loader-2",
                                            "url": "https://next.test"
                                        }
                                    }
                                }
                            }),
                        );
                    }
                    "Page.captureScreenshot" => {
                        replacement_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {"data": ONE_PIXEL_PNG}
                            }),
                        );
                    }
                    method => panic!("unexpected CDP method {method}"),
                }
            }
            replacement_captured_tx.send(()).unwrap();
            final_frame_rx.recv_timeout(Duration::from_secs(2)).unwrap();
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "ZmluYWw=",
                        "sessionId": 15,
                        "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                    }
                }),
            );
            ws.get_mut().set_read_timeout(Some(Duration::from_millis(20))).unwrap();
            let deadline = Instant::now() + Duration::from_secs(1);
            let mut final_calls = 0;
            while final_calls < 3 && Instant::now() < deadline {
                let request = match ws.read() {
                    Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).unwrap(),
                    Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).unwrap(),
                    Ok(_) => continue,
                    Err(tungstenite::Error::Io(error))
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        continue;
                    }
                    Err(_) => break,
                };
                match request["method"].as_str().unwrap() {
                    "Page.screencastFrameAck" => {}
                    "Page.getFrameTree" => {
                        final_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {
                                    "frameTree": {
                                        "frame": {
                                            "id": "main-frame",
                                            "loaderId": "loader-2",
                                            "url": "https://next.test"
                                        }
                                    }
                                }
                            }),
                        );
                    }
                    "Page.captureScreenshot" => {
                        final_calls += 1;
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": request["id"],
                                "result": {"data": ONE_PIXEL_PNG}
                            }),
                        );
                    }
                    method => panic!("unexpected CDP method {method}"),
                }
            }
            final_capture_tx.send(final_calls == 3).unwrap();
            stop_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let route = runtime.register("target-1", "session-1");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        start_surface_thread(
            surface.clone(),
            route,
            Weak::new(),
            Arc::downgrade(&runtime),
            "session-1".to_string(),
        )
        .unwrap();
        browser.store_frame(test_frame(1));

        start_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline && browser.latest_frame_seq() != Some(2) {
            thread::yield_now();
        }
        assert_eq!(browser.latest_frame_seq(), Some(2));
        assert_eq!(
            browser.latest_frame().map(|frame| frame.data_b64.clone()),
            Some(ONE_PIXEL_PNG.to_string())
        );

        next_frame_tx.send(()).unwrap();
        recaptured_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline && browser.latest_frame().is_none_or(|frame| frame.seq != 3)
        {
            thread::yield_now();
        }
        assert_eq!(
            browser.latest_frame().map(|frame| frame.seq),
            Some(3),
            "the timestamp-less stream frame must not be admitted before its replacement"
        );
        assert_eq!(
            browser.latest_frame_seq(),
            Some(3),
            "the loader-verified replacement must rotate pointer authority with its bitmap"
        );
        assert_eq!(
            browser.latest_frame().map(|frame| frame.data_b64.clone()),
            Some(ONE_PIXEL_PNG.to_string()),
            "later timestamp-less pixels must update through a loader-verified capture"
        );

        race_start_tx.send(()).unwrap();
        stale_capture_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let stale_reservation = browser
            .state
            .lock()
            .unwrap()
            .pending_screencast_capture
            .expect("first timestamp-less capture reservation")
            .id;
        send_replacement_tx.send(()).unwrap();
        replacement_sent_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        let replacement_reservation = loop {
            let state = browser.state.lock().unwrap();
            if state.latest_frame.as_ref().is_some_and(|frame| frame.data_b64 == "dGltZWQ=")
                && let Some(reservation) = state.pending_screencast_capture
                && reservation.id != stale_reservation
            {
                break reservation.id;
            }
            drop(state);
            assert!(Instant::now() < deadline, "replacement reservation was not established");
            thread::yield_now();
        };
        release_stale_tx.send(()).unwrap();
        replacement_captured_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let state = browser.state.lock().unwrap();
            if state.latest_frame.as_ref().is_some_and(|frame| frame.seq == 6)
                && state.pending_screencast_capture.is_none()
            {
                break;
            }
            drop(state);
            assert!(
                Instant::now() < deadline,
                "replacement capture {replacement_reservation} was not accepted"
            );
            thread::yield_now();
        }
        // Recovery is intentionally rate-limited at CDP ingress. Wait past
        // that bound without emitting a timestamped frame, so this still
        // proves the stale failure did not suppress the later request.
        thread::sleep(Duration::from_millis(1_100));
        final_frame_tx.send(()).unwrap();
        let final_capture_started = final_capture_rx.recv_timeout(Duration::from_secs(2)).unwrap();

        stop_tx.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();
        assert!(
            final_capture_started,
            "a stale capture failure must not suppress later same-epoch recovery"
        );
    }

    #[test]
    fn same_document_capture_reopens_authority_without_a_new_navigation_epoch() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let navigation_epoch = browser.frame_epoch.latest_navigation();
        let url = "https://example.test/#next";
        browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");

        let _observed = handle_same_document_navigated(
            browser,
            &json!({"frameId": "main-frame", "url": url}),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("same-document URL");
        assert!(browser.needs_same_document_paint());
        let capture_epoch = browser.frame_epoch.advance();
        assert!(browser.accept_same_document_paint(capture_epoch, test_frame(2)));

        let state = browser.state.lock().unwrap();
        assert_eq!(browser.frame_epoch.latest_navigation(), navigation_epoch);
        assert_eq!(state.pending_frame_epoch, None);
        assert_eq!(state.pending_navigation_epoch, None);
        assert_eq!(state.pointer_frame_seq, Some(2));
    }

    #[test]
    fn failed_same_document_capture_exposes_a_retryable_terminal_failure() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");
        handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/#next"
            }),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("same-document URL");
        let failed_capture_epoch = browser.frame_epoch.advance();

        browser.fail_same_document_authority(&anyhow::anyhow!("injected capture failure"));

        assert!(
            matches!(
                browser.status(),
                BrowserStatus::Failed(ref error) if error.contains("reload to retry")
            ),
            "exhausted same-document verification must expose a bounded recovery action"
        );
        browser.store_frame_for_epoch(test_frame(2), failed_capture_epoch);
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "later unverified frames must not escape the terminal failure"
        );
        assert!(
            browser.begin_targeted_navigation_frame_transition().is_ok(),
            "reload must be able to start a fresh navigation after terminal failure"
        );
    }

    #[test]
    fn unrelated_same_document_event_cannot_clear_verification_failure() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");
        handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/#failed"
            }),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("same-document URL");
        browser.fail_same_document_authority(&anyhow::anyhow!("injected capture failure"));

        handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/#unrelated"
            }),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("later same-document URL");
        browser.store_frame_for_epoch(test_frame(2), browser.frame_epoch.current());

        assert!(
            matches!(
                browser.status().failure(),
                Some(super::BrowserFailure::UpdatedPageVerification(_))
            ),
            "an unrelated lifecycle event must preserve the terminal verification failure"
        );
        assert!(
            browser.latest_frame().is_none(),
            "unverified pixels must remain hidden after the unrelated event"
        );
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "unverified pixels must not recreate pointer authority"
        );

        browser.begin_targeted_navigation_frame_transition().expect("explicit recovery");
        handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/#recovery"
            }),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("recovery URL");
        assert!(
            matches!(
                browser.status().failure(),
                Some(super::BrowserFailure::UpdatedPageVerification(_))
            ),
            "the recovery command acknowledgment must not clear failure before pixel verification"
        );
        assert!(browser.accept_same_document_paint(browser.frame_epoch.current(), test_frame(3)));
        assert_eq!(browser.status(), BrowserStatus::Live);
        assert!(
            browser.latest_frame_seq().is_some(),
            "the matching verified recovery paint must reopen pointer authority"
        );
    }

    #[test]
    fn explicit_retry_can_verify_pixels_while_surface_is_failed() {
        let (runtime, server, _dispatched, stop) = runtime_recording_mouse_dispatches();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        runtime.client.seed_main_frame("session-1").unwrap();
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        browser.begin_targeted_navigation_frame_transition().expect("failed navigation");
        handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/#failed"
            }),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("failed URL");
        browser.fail_same_document_authority(&anyhow::anyhow!("injected capture failure"));
        browser.begin_targeted_navigation_frame_transition().expect("explicit retry");
        handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/#recovery"
            }),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("recovery URL");
        assert!(
            browser.require_live_session().is_err(),
            "ordinary browser input must remain blocked until retry pixels are verified"
        );

        let recovery =
            browser.authorize_same_document_paint_blocking("session-1", "main-frame", "loader-1");

        stop.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();

        assert!(
            recovery.is_ok(),
            "the explicit retry must be allowed to capture verification pixels: {recovery:?}"
        );
        assert_eq!(browser.status(), BrowserStatus::Live);
        assert!(
            browser.latest_frame_seq().is_some(),
            "verified retry pixels must restore pointer authority"
        );
    }

    #[test]
    fn rejected_streamed_frames_do_not_emit_surface_output() {
        let options = SurfaceOptions::default();
        let mux = Mux::new("rejected-browser-frame-redraw-test", options.clone());
        let surface = new_surface(
            1,
            "https://example.test".into(),
            (10, 5),
            (8, 16),
            &options,
            Arc::downgrade(&mux),
        )
        .expect("browser surface creation");
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");
        let rejected_epoch = browser.frame_epoch.advance();
        browser.fail_same_document_authority(&anyhow::anyhow!("injected capture failure"));
        assert!(browser.take_dirty(), "terminal failure must request its own redraw");

        let events = mux.subscribe();
        let route = Arc::new(super::SurfaceRoute::new());
        start_surface_thread(
            surface.clone(),
            route.clone(),
            Arc::downgrade(&mux),
            Weak::new(),
            "session-test".to_string(),
        )
        .unwrap();
        assert!(!route.deliver(cmux_tui_cdp::CdpEvent::ScreencastFrame(
            cmux_tui_cdp::ScreencastFrame {
                session_id: "session-test".to_string(),
                data_b64: "rejected-after-failure".to_string(),
                css_width: 80,
                css_height: 48,
                image_width: 80,
                image_height: 48,
                ack_id: 2,
                frame_epoch: rejected_epoch,
            },
        )));

        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline
            && browser
                .state
                .lock()
                .unwrap()
                .pending_frame
                .as_ref()
                .is_none_or(|(_, frame)| frame.data_b64 != "rejected-after-failure")
        {
            thread::yield_now();
        }
        assert!(
            browser
                .state
                .lock()
                .unwrap()
                .pending_frame
                .as_ref()
                .is_some_and(|(_, frame)| frame.data_b64 == "rejected-after-failure"),
            "surface thread did not process the rejected frame"
        );
        assert!(
            events.recv_timeout(Duration::from_millis(100)).is_err(),
            "a frame rejected by the epoch gate must not request a TUI redraw"
        );
        assert!(!browser.take_dirty(), "a rejected frame must not mark the surface dirty");

        route.close(CdpCloseReason::SurfaceClosed);
    }

    #[test]
    fn same_document_navigation_preserves_an_accepted_pointer_capture() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let authority = browser.latest_frame_seq().expect("initial pointer authority");
        let (_, capture_generation, _, _) = browser
            .capture_guarded_input_point(authority, 1.0, 1.0)
            .expect("accepted pointer press");
        browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");

        let _observed = handle_same_document_navigated(
            browser,
            &json!({"frameId": "main-frame", "url": "https://example.test/#next"}),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("same-document URL");
        let capture_epoch = browser.frame_epoch.advance();
        assert!(browser.accept_same_document_paint(capture_epoch, test_frame(2)));

        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "a same-document navigation must preserve the balancing release for an accepted press"
        );
    }

    #[test]
    fn page_initiated_same_document_navigation_requires_verified_pixels() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let authority = browser.latest_frame_seq().expect("initial pointer authority");
        let (_, capture_generation, motion_generation, ingress_motion_generation) = browser
            .capture_guarded_input_point(authority, 1.0, 1.0)
            .expect("accepted pointer press");
        let navigation_epoch = browser.frame_epoch.latest_navigation();
        let frame_epoch = browser.frame_epoch.advance_same_document();

        handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/#page-initiated"
            }),
            frame_epoch,
        )
        .expect("same-document URL");

        assert!(
            browser.needs_same_document_paint(),
            "page-initiated navigation must reserve verified replacement pixels"
        );
        assert_eq!(
            browser.state.lock().unwrap().pointer_frame_seq,
            None,
            "the displayed pre-navigation bitmap must lose pointer admission immediately"
        );
        assert_eq!(
            browser.frame_epoch.latest_navigation(),
            navigation_epoch,
            "same-document navigation must not claim a new document epoch"
        );
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "an accepted press must retain only its balancing release ownership"
        );
        assert_eq!(
            browser.captured_pointer_route(
                capture_generation,
                motion_generation,
                ingress_motion_generation,
                authority,
                authority,
                (1.0, 1.0),
            ),
            super::CapturedPointerRoute::MotionInvalidated,
            "same-document navigation must stop motion from the pre-navigation press"
        );
        assert!(browser.accept_same_document_paint(frame_epoch, test_frame(2)));
        assert_eq!(browser.latest_frame_seq(), Some(2));
    }

    #[test]
    fn queued_same_document_navigation_survives_a_later_screencast_epoch() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let same_document_epoch = browser.frame_epoch.advance_same_document();

        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        browser.begin_reconfigure_frame_transition();
        let restart_epoch = browser.frame_epoch.advance();
        browser.confirm_reconfigure(queued, restart_epoch);
        assert!(browser.store_frame_for_epoch(test_frame(2), restart_epoch));

        handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/#queued"
            }),
            same_document_epoch,
        )
        .expect("same-document URL");

        assert!(
            browser.needs_same_document_paint(),
            "a later screencast restart must not discard the queued navigation barrier"
        );
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "pixels captured after the restart but before navigation handling are not authoritative"
        );
    }

    #[test]
    fn ordinary_repaint_retains_presented_pointer_authority_and_capture() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let authority = browser.latest_frame_seq().expect("initial pointer authority");
        let (_, capture_generation, _, _) = browser
            .capture_guarded_input_point(authority, 1.0, 1.0)
            .expect("accepted pointer press");

        browser.store_frame(test_frame(2));

        assert_eq!(
            browser.latest_frame().map(|frame| frame.seq),
            Some(2),
            "the visual frame must advance"
        );
        assert_eq!(
            browser.latest_frame_seq(),
            Some(2),
            "each admitted bitmap must carry its own pointer authority"
        );
        assert_eq!(browser.state.lock().unwrap().pointer_frame_floor_seq, Some(1));
        assert!(
            browser.capture_guarded_input_point(authority, 1.0, 1.0).is_some(),
            "a still-presented bitmap must remain guarded while its route geometry is current"
        );
        assert!(
            browser.capture_guarded_input_point(2, 1.0, 1.0).is_none(),
            "the newly admitted bitmap must wait for a presentation acknowledgement"
        );
        acknowledge_local_presentation(browser, 2);
        assert!(
            browser.capture_guarded_input_point(authority, 1.0, 1.0).is_none(),
            "the owner must retain only its exact latest acknowledged bitmap"
        );
        assert!(browser.capture_guarded_input_point(2, 1.0, 1.0).is_some());
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "rotating bitmap authority must preserve ownership of a balancing release"
        );
    }

    #[test]
    fn ordinary_repaint_preserves_captured_drag_motion() {
        let (runtime, server, events, stop) = runtime_recording_mouse_dispatches();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let mut active_pointer_presses = std::collections::HashMap::new();

        browser
            .mouse_event_blocking(
                super::BrowserMouseDispatch {
                    input_owner: super::BrowserPointerOwner::Local,
                    event_type: "mousePressed",
                    x: 8.0,
                    y: 16.0,
                    button: Some("left"),
                    click_count: Some(1),
                    frame_seq: Some(1),
                },
                &mut active_pointer_presses,
            )
            .unwrap();
        let press = events.recv_timeout(Duration::from_secs(1)).unwrap();

        browser.store_frame(test_frame(2));
        browser
            .mouse_event_blocking(
                super::BrowserMouseDispatch {
                    input_owner: super::BrowserPointerOwner::Local,
                    event_type: "mouseMoved",
                    x: 24.0,
                    y: 32.0,
                    button: Some("left"),
                    click_count: None,
                    frame_seq: Some(1),
                },
                &mut active_pointer_presses,
            )
            .unwrap();
        let motion = events.recv_timeout(Duration::from_millis(100)).ok();

        browser
            .mouse_event_blocking(
                super::BrowserMouseDispatch {
                    input_owner: super::BrowserPointerOwner::Local,
                    event_type: "mouseReleased",
                    x: 24.0,
                    y: 32.0,
                    button: Some("left"),
                    click_count: Some(1),
                    frame_seq: Some(1),
                },
                &mut active_pointer_presses,
            )
            .unwrap();
        let release = events.recv_timeout(Duration::from_secs(1)).unwrap();
        stop.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();

        let motion = motion.expect("ordinary repaint must not stall an accepted drag");
        assert_eq!(motion["params"]["type"], "mouseMoved");
        assert_ne!(motion["params"]["x"], press["params"]["x"]);
        assert_ne!(motion["params"]["y"], press["params"]["y"]);
        assert_eq!(release["params"]["type"], "mouseReleased");
        assert_eq!(release["params"]["x"], motion["params"]["x"]);
        assert_eq!(release["params"]["y"], motion["params"]["y"]);
        assert!(active_pointer_presses.is_empty());
    }

    #[test]
    fn viewport_change_rotates_pointer_authority() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let (_, capture_generation, motion_generation, ingress_motion_generation) = browser
            .capture_guarded_input_point(1, 1.0, 1.0)
            .expect("captured press under the original viewport");
        let mut resized = test_frame(2);
        resized.css_width += 1;

        browser.store_frame(resized);

        assert_eq!(browser.latest_frame_seq(), Some(2));
        assert_eq!(browser.state.lock().unwrap().pointer_frame_floor_seq, Some(2));
        assert!(
            browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none(),
            "a bitmap viewport change must revoke the old coordinate mapping"
        );
        assert_eq!(
            browser.captured_pointer_route(
                capture_generation,
                motion_generation,
                ingress_motion_generation,
                1,
                1,
                (1.0, 1.0),
            ),
            super::CapturedPointerRoute::MotionInvalidated,
            "captured motion must not cross an unsolicited viewport mapping change"
        );
    }

    #[test]
    fn legacy_pointer_capture_has_a_bounded_worker_lease() {
        let (runtime, server) = runtime_accepting_mouse_dispatches(vec!["mouseReleased"]);
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
        let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
        let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
        let now = Instant::now();
        let mut press = super::ActivePointerPress::new(
            super::BrowserPointerOwner::Legacy,
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            1,
            (1.0, 1.0),
            Some(1),
        );
        press.compatibility_expires_at = Some(now);
        let mut failures = super::BrowserWorkerErrorState::default();
        failures.active_pointer_presses.insert("left".to_string(), press);

        super::release_abandoned_pointer_presses(
            &surface,
            &Weak::new(),
            surface.id,
            &mut failures,
            now,
        );

        assert!(
            failures.active_pointer_presses.is_empty(),
            "expiry must clear compatibility ownership even if release dispatch later fails"
        );
        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn stationary_legacy_pointer_hold_outlives_five_seconds() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
        let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
        let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
        let started = Instant::now();
        let press = super::ActivePointerPress::new(
            super::BrowserPointerOwner::Legacy,
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            1,
            (1.0, 1.0),
            Some(1),
        );
        let mut failures = super::BrowserWorkerErrorState::default();
        failures.active_pointer_presses.insert("left".to_string(), press);

        super::release_abandoned_pointer_presses(
            &surface,
            &Weak::new(),
            surface.id,
            &mut failures,
            started + Duration::from_millis(5_100),
        );

        assert!(
            failures.active_pointer_presses.contains_key("left"),
            "a live stationary legacy hold must not synthesize mouseReleased after five seconds"
        );
    }

    #[test]
    fn local_pointer_capture_has_a_bounded_worker_lease() {
        let surface = test_surface();
        let press = super::ActivePointerPress::new(
            super::BrowserPointerOwner::Local,
            u64::MAX,
            1,
            1,
            1,
            (1.0, 1.0),
            Some(1),
        );
        let expiry = press
            .compatibility_expires_at
            .expect("local capture must schedule a balancing-release deadline");
        let mut failures = super::BrowserWorkerErrorState::default();
        failures.active_pointer_presses.insert("left".to_string(), press);

        super::release_abandoned_pointer_presses(
            &surface,
            &Weak::new(),
            surface.id,
            &mut failures,
            expiry,
        );

        assert!(
            failures.active_pointer_presses.is_empty(),
            "an orphaned local press must not remain held in Chrome indefinitely"
        );
    }

    #[test]
    fn expired_pointer_capture_does_not_release_into_a_new_document() {
        let (runtime, server, events_rx, stop_tx) = runtime_recording_mouse_dispatches();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
        let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
        let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
        let now = Instant::now();
        let mut press = super::ActivePointerPress::new(
            super::BrowserPointerOwner::Legacy,
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            1,
            (1.0, 1.0),
            Some(1),
        );
        press.compatibility_expires_at = Some(now);
        let mut failures = super::BrowserWorkerErrorState::default();
        failures.active_pointer_presses.insert("left".to_string(), press);

        browser.frame_epoch.advance_navigation();
        super::release_abandoned_pointer_presses(
            &surface,
            &Weak::new(),
            surface.id,
            &mut failures,
            now,
        );
        let released_into_new_document = events_rx.recv_timeout(Duration::from_millis(250)).is_ok();

        stop_tx.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();

        assert!(failures.active_pointer_presses.is_empty());
        assert!(
            !released_into_new_document,
            "an expired capture must be discarded after its document authority changes"
        );
    }

    #[test]
    fn negotiated_pointer_capture_has_no_idle_lease() {
        let mut failures = super::BrowserWorkerErrorState::default();
        failures.active_pointer_presses.insert(
            "left".to_string(),
            super::ActivePointerPress::new(
                super::BrowserPointerOwner::Client(41),
                1,
                1,
                1,
                1,
                (1.0, 1.0),
                Some(1),
            ),
        );

        assert!(
            super::next_pointer_lifecycle_deadline(&failures).is_none(),
            "a live negotiated client must retain a stationary browser capture"
        );
    }

    #[test]
    fn idle_browser_worker_has_no_fixed_pointer_cleanup_poll() {
        let mut failures = super::BrowserWorkerErrorState::default();
        assert!(
            super::next_pointer_lifecycle_deadline(&failures).is_none(),
            "an idle browser worker must have no synthetic polling deadline"
        );

        let deadline = Instant::now() + Duration::from_secs(1);
        let mut press = super::ActivePointerPress::new(
            super::BrowserPointerOwner::Legacy,
            1,
            1,
            1,
            1,
            (1.0, 1.0),
            Some(1),
        );
        press.compatibility_expires_at = Some(deadline);
        failures.active_pointer_presses.insert("left".to_string(), press);

        assert_eq!(
            super::next_pointer_lifecycle_deadline(&failures),
            Some(deadline),
            "a compatibility capture must schedule only its real expiry"
        );
    }

    #[test]
    fn pointer_release_retry_supersedes_expired_lease_deadline() {
        let now = Instant::now();
        let retry_at = now + Duration::from_millis(250);
        let mut press = super::ActivePointerPress::new(
            super::BrowserPointerOwner::Legacy,
            1,
            1,
            1,
            1,
            (1.0, 1.0),
            Some(1),
        );
        press.compatibility_expires_at = Some(now - Duration::from_millis(1));
        press.release_retry_at = Some(retry_at);
        let mut failures = super::BrowserWorkerErrorState::default();
        failures.active_pointer_presses.insert("left".to_string(), press);

        assert_eq!(
            super::next_pointer_lifecycle_deadline(&failures),
            Some(retry_at),
            "an abandoned-release retry must replace the expired compatibility deadline"
        );
    }

    #[test]
    fn disconnected_client_pointer_capture_is_balanced() {
        let (runtime, server) = runtime_accepting_mouse_dispatches(vec!["mouseReleased"]);
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
        let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
        let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
        let press = super::ActivePointerPress::new(
            super::BrowserPointerOwner::Client(41),
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            1,
            (1.0, 1.0),
            Some(1),
        );
        let mut failures = super::BrowserWorkerErrorState::default();
        failures.active_pointer_presses.insert("left".to_string(), press);
        let mux = Mux::new("disconnected-pointer-owner-test", SurfaceOptions::default());

        super::release_abandoned_pointer_presses(
            &surface,
            &Arc::downgrade(&mux),
            surface.id,
            &mut failures,
            Instant::now(),
        );

        assert!(
            failures.active_pointer_presses.is_empty(),
            "a disconnected client must lose capture through a balancing release"
        );
        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn canonicalized_same_document_url_still_requests_capture() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");

        let _observed = handle_same_document_navigated(
            browser,
            &json!({
                "frameId": "main-frame",
                "url": "https://example.test/path#section"
            }),
            browser.frame_epoch.advance_same_document(),
        )
        .expect("same-document URL");

        assert!(
            browser.needs_same_document_paint(),
            "Chrome URL canonicalization must not strand the navigation authority reservation"
        );
    }

    #[test]
    fn verified_capture_settles_one_timestampless_reservation_after_resize() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        browser.begin_reconfigure_frame_transition();
        let frame_epoch = browser.frame_epoch.advance();
        browser.confirm_reconfigure(queued, frame_epoch);
        let navigation_epoch = browser.frame_epoch.latest_navigation();

        assert_eq!(browser.latest_frame(), None);
        let reservation = 41;
        assert!(browser.reserve_screencast_capture(reservation, frame_epoch, navigation_epoch));
        assert!(browser.may_need_screencast_capture(reservation, frame_epoch, navigation_epoch));
        assert!(browser.accept_screencast_capture(
            reservation,
            frame_epoch,
            navigation_epoch,
            test_frame(2),
        ));
        assert_eq!(browser.latest_frame_seq(), Some(2));
        assert!(
            !browser.may_need_screencast_capture(reservation, frame_epoch, navigation_epoch),
            "the verified replacement must settle its in-flight reservation"
        );
        let later = 42;
        assert!(browser.reserve_screencast_capture(later, frame_epoch, navigation_epoch));
        browser.cancel_screencast_capture(later);
    }

    #[test]
    fn stale_screencast_capture_cannot_settle_a_newer_same_epoch_reservation() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let frame_epoch = browser.frame_epoch.current();
        let navigation_epoch = browser.frame_epoch.latest_navigation();
        let stale = 51;
        assert!(browser.reserve_screencast_capture(stale, frame_epoch, navigation_epoch));
        assert!(
            !browser.reserve_screencast_capture(99, frame_epoch, navigation_epoch),
            "concurrent timestamp-less frames must coalesce into one reservation"
        );

        browser.store_frame(test_frame(2));
        let current = 52;
        assert!(browser.reserve_screencast_capture(current, frame_epoch, navigation_epoch));

        assert!(!browser.accept_screencast_capture(
            stale,
            frame_epoch,
            navigation_epoch,
            test_frame(3),
        ));
        assert!(
            browser.may_need_screencast_capture(current, frame_epoch, navigation_epoch),
            "a stale completion must preserve the replacement reservation"
        );
        assert!(browser.accept_screencast_capture(
            current,
            frame_epoch,
            navigation_epoch,
            test_frame(3),
        ));
        assert_eq!(browser.latest_frame().map(|frame| frame.seq), Some(3));
    }

    #[test]
    fn failed_screencast_authority_suppresses_retries_for_epoch() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
            let mut ws = accept(stream).unwrap();
            let mut capture_attempts = 0;
            loop {
                if stop_rx.try_recv().is_ok() {
                    break;
                }
                let request = match ws.read() {
                    Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).unwrap(),
                    Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).unwrap(),
                    Ok(_) => continue,
                    Err(tungstenite::Error::Io(error))
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        continue;
                    }
                    Err(_) => break,
                };
                let method = request["method"].as_str().unwrap();
                let response = match method {
                    "Target.setDiscoverTargets" => {
                        json!({"id": request["id"], "result": {}})
                    }
                    "Page.getFrameTree" => json!({
                        "id": request["id"],
                        "result": {
                            "frameTree": {
                                "frame": {
                                    "id": "main-frame",
                                    "loaderId": "loader-1",
                                    "url": "https://example.test"
                                }
                            }
                        }
                    }),
                    "Page.createIsolatedWorld" => json!({
                        "id": request["id"],
                        "result": {"executionContextId": 41}
                    }),
                    "Runtime.evaluate" => json!({
                        "id": request["id"],
                        "result": {
                            "result": {"type": "number", "value": 10_000.0}
                        }
                    }),
                    "Page.startScreencast" => {
                        let response = json!({"id": request["id"], "result": {}});
                        write_ws_json(&mut ws, response);
                        write_ws_json(
                            &mut ws,
                            json!({
                                "method": "Page.screencastFrame",
                                "sessionId": "session-1",
                                "params": {
                                    "data": "AAAA",
                                    "sessionId": 9,
                                    "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                                }
                            }),
                        );
                        continue;
                    }
                    "Page.screencastFrameAck" => continue,
                    "Page.captureScreenshot" => {
                        capture_attempts += 1;
                        json!({
                            "id": request["id"],
                            "error": {
                                "code": -32000,
                            "message": "CDP call Page.captureScreenshot timed out"
                            }
                        })
                    }
                    method => panic!("unexpected CDP method {method}"),
                };
                write_ws_json(&mut ws, response);
            }
            capture_attempts
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let route = runtime.register("target-1", "session-1");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        runtime.client.seed_main_frame("session-1").unwrap();
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let frame_epoch =
            runtime.client.start_screencast_with_frame_barrier("session-1", 80, 48).unwrap();
        let request = route.recv().expect("timestamp-less frame recovery request");
        let cmux_tui_cdp::CdpEvent::ScreencastFrameCaptureRequested {
            request_id: reservation,
            navigation_epoch,
            ..
        } = request
        else {
            panic!("expected timestamp-less frame recovery request");
        };
        assert!(browser.reserve_screencast_capture(reservation, frame_epoch, navigation_epoch));

        let capture = browser.authorize_screencast_capture_blocking(
            "session-1",
            "main-frame",
            "loader-1",
            reservation,
            frame_epoch,
            navigation_epoch,
        );
        let retry_needed =
            browser.may_need_screencast_capture(reservation, frame_epoch, navigation_epoch);

        stop_tx.send(()).unwrap();
        runtime.shutdown();
        let capture_attempts = server.join().unwrap();
        assert!(capture.is_err());
        assert_eq!(
            capture_attempts, 1,
            "a timeout must stop the retry batch before monopolizing the browser worker"
        );
        assert!(
            !retry_needed,
            "an exhausted recovery epoch must not start another frame-rate capture batch"
        );
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "exhausted timestamp-less recovery must revoke stale pixel authority"
        );
        assert!(
            matches!(
                browser.status(),
                BrowserStatus::Failed(ref error) if error.contains("reload to retry")
            ),
            "exhausted timestamp-less recovery must expose a bounded reload action"
        );
    }

    #[test]
    fn failed_document_capture_exposes_a_retryable_terminal_failure() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
            let mut ws = accept(stream).unwrap();
            let mut capture_attempts = 0;
            loop {
                if stop_rx.try_recv().is_ok() {
                    break;
                }
                let request = match ws.read() {
                    Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).unwrap(),
                    Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).unwrap(),
                    Ok(_) => continue,
                    Err(tungstenite::Error::Io(error))
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        continue;
                    }
                    Err(_) => break,
                };
                let method = request["method"].as_str().unwrap();
                let response = match method {
                    "Target.setDiscoverTargets"
                    | "Page.stopScreencast"
                    | "Page.startScreencast" => {
                        json!({"id": request["id"], "result": {}})
                    }
                    "Page.createIsolatedWorld" => json!({
                        "id": request["id"],
                        "result": {"executionContextId": 41}
                    }),
                    "Runtime.evaluate" => json!({
                        "id": request["id"],
                        "result": {
                            "result": {"type": "number", "value": 10_000.0}
                        }
                    }),
                    "Page.getFrameTree" => json!({
                        "id": request["id"],
                        "result": {
                            "frameTree": {
                                "frame": {
                                    "id": "main-frame",
                                    "loaderId": "loader-2",
                                    "url": "https://next.test"
                                }
                            }
                        }
                    }),
                    "Page.captureScreenshot" => {
                        capture_attempts += 1;
                        json!({
                            "id": request["id"],
                            "error": {
                                "code": -32000,
                                "message": "injected transient capture failure"
                            }
                        })
                    }
                    method => panic!("unexpected CDP method {method}"),
                };
                write_ws_json(&mut ws, response);
            }
            capture_attempts
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        runtime.client.seed_main_frame("session-1").unwrap();
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let navigation_epoch = browser.frame_epoch.advance_navigation();
        handle_frame_navigated(
            browser,
            json!({
                "frame": {
                    "id": "main-frame",
                    "loaderId": "loader-2",
                    "url": "https://next.test"
                }
            }),
            navigation_epoch,
        );

        let capture = browser.authorize_document_paint_blocking(
            "session-1",
            "main-frame",
            "loader-2",
            navigation_epoch,
        );
        assert!(capture.is_err());
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "capture failure must not restore pointer authority to the previous document"
        );
        assert!(
            matches!(
                browser.status(),
                BrowserStatus::Failed(ref error) if error.contains("reload to retry")
            ),
            "exhausted document verification must expose a bounded recovery action"
        );
        browser.store_frame_for_epoch(test_frame(2), browser.frame_epoch.current());
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "later unverified frames must not escape the terminal failure"
        );
        let next_navigation = browser.begin_targeted_navigation_frame_transition();

        stop_tx.send(()).unwrap();
        runtime.shutdown();
        let capture_attempts = server.join().unwrap();
        assert!(
            (1..=AUTHORITY_CAPTURE_ATTEMPTS).contains(&capture_attempts),
            "document verification must make progress without exceeding its retry cap"
        );
        let next_error = next_navigation.as_ref().err().map(ToString::to_string);
        assert!(
            next_navigation.is_ok(),
            "reload must be able to start a fresh navigation after terminal failure: {next_error:?}"
        );
    }

    #[test]
    fn document_verification_gives_each_bounded_attempt_a_full_budget() {
        const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        const ATTEMPT_BUDGET: Duration = Duration::from_secs(2);
        const TRANSIENT_FAILURE_DELAY: Duration = Duration::from_millis(950);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let seed = read_ws_json(&mut ws);
            assert_eq!(seed["method"], "Page.getFrameTree");
            write_ws_json(
                &mut ws,
                json!({
                    "id": seed["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test"
                            }
                        }
                    }
                }),
            );

            let mut attempts = 0;
            loop {
                let request = match ws.read() {
                    Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).ok(),
                    Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).ok(),
                    Ok(_) => None,
                    Err(_) => break,
                };
                let Some(request) = request else { continue };
                let method = request["method"].as_str().unwrap();
                if method == "Page.stopScreencast" {
                    attempts += 1;
                    if attempts < AUTHORITY_CAPTURE_ATTEMPTS {
                        thread::sleep(TRANSIENT_FAILURE_DELAY);
                        if ws
                            .send(Message::Text(
                                json!({
                                    "id": request["id"],
                                    "error": {"message": "injected restart failure"}
                                })
                                .to_string()
                                .into(),
                            ))
                            .is_err()
                        {
                            break;
                        }
                        continue;
                    }
                }
                let result = match method {
                    "Page.stopScreencast" | "Page.startScreencast" => json!({}),
                    "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                    "Runtime.evaluate" => {
                        json!({"result": {"type": "number", "value": 10_000.0}})
                    }
                    "Page.getFrameTree" => json!({
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-2",
                                "url": "https://next.test"
                            }
                        }
                    }),
                    "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                    method => panic!("unexpected CDP method {method}"),
                };
                if ws
                    .send(Message::Text(
                        json!({"id": request["id"], "result": result}).to_string().into(),
                    ))
                    .is_err()
                {
                    break;
                }
            }
            attempts
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        runtime.client.seed_main_frame("session-1").unwrap();
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let navigation_epoch = browser.frame_epoch.advance_navigation();
        handle_frame_navigated(
            browser,
            json!({
                "frame": {
                    "id": "main-frame",
                    "loaderId": "loader-2",
                    "url": "https://next.test"
                }
            }),
            navigation_epoch,
        );
        browser.state.lock().unwrap().pending_authority_deadline =
            Some(Instant::now() + Duration::from_secs(5));

        let result = browser.authorize_document_paint_with_attempt_budget_blocking(
            "session-1",
            "main-frame",
            "loader-2",
            navigation_epoch,
            ATTEMPT_BUDGET,
        );

        runtime.shutdown();
        let attempts = server.join().unwrap();
        assert!(
            result.is_ok(),
            "two slow transient restart failures must not starve the healthy bounded attempt: {result:?}"
        );
        assert_eq!(
            attempts, AUTHORITY_CAPTURE_ATTEMPTS,
            "document verification must reach the healthy final attempt"
        );
    }

    #[test]
    fn late_document_paint_recovers_expired_navigation_authority() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let navigation_epoch = browser.frame_epoch.advance_navigation();
        handle_frame_navigated(
            browser,
            json!({
                "frame": {
                    "id": "main-frame",
                    "loaderId": "loader-2",
                    "url": "https://never-paints.test"
                }
            }),
            navigation_epoch,
        );
        browser.state.lock().unwrap().pending_authority_deadline = Some(Instant::now());
        let message = browser
            .expire_navigation_authority(Instant::now())
            .expect("expired authority must surface a bounded recovery action");
        let status = browser.status();
        let state = browser.state.lock().unwrap();
        let pending_frame_epoch = state.pending_frame_epoch;
        let pending_document_epoch = state.pending_document_epoch;
        let pending_failure_recovery = state.pending_failure_recovery;
        drop(state);

        assert!(
            matches!(status.failure(), Some(super::BrowserFailure::NewPageVerification(_))),
            "an unpainted committed document must surface a reloadable failure: {status:?}"
        );
        assert!(message.contains("reload to retry"));
        assert_eq!(pending_frame_epoch, Some(navigation_epoch));
        assert_eq!(pending_document_epoch, Some(navigation_epoch));
        assert!(
            pending_failure_recovery,
            "the expired barrier must retain authority for a late current-document paint"
        );
        assert_eq!(browser.latest_frame_seq(), None);

        assert!(
            browser.accept_document_paint(navigation_epoch, navigation_epoch, test_frame(2),),
            "a late loader-verified paint must recover the still-current document"
        );
        assert_eq!(browser.status(), BrowserStatus::Live);
        assert_eq!(browser.latest_frame_seq(), Some(2));
    }

    #[test]
    fn unguarded_pointer_input_requires_a_current_admitted_frame() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        {
            let mut state = browser.state.lock().unwrap();
            super::BrowserSurface::set_pointer_frame_locked(&mut state, None);
        }

        assert!(
            browser.scale_guarded_input_point(None, 1.0, 1.0).is_none(),
            "legacy mouse input must not bypass invalidated pointer authority"
        );
        assert!(
            browser.scale_guarded_wheel(None, 1.0, 1.0, 1.0).is_none(),
            "legacy wheel input must not bypass invalidated pointer authority"
        );
    }

    #[test]
    fn queued_frame_before_navigation_barrier_stays_non_authoritative() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let route = Arc::new(super::SurfaceRoute::new());
        assert!(!route.deliver(cmux_tui_cdp::CdpEvent::ScreencastFrame(
            cmux_tui_cdp::ScreencastFrame {
                session_id: "session-test".to_string(),
                data_b64: "queued-before-barrier".to_string(),
                css_width: 80,
                css_height: 48,
                image_width: 80,
                image_height: 48,
                ack_id: 2,
                frame_epoch: 0,
            },
        )));

        browser.invalidate_pointer_frame();
        let queued = route.try_recv().expect("queued screencast frame");
        let cmux_tui_cdp::CdpEvent::ScreencastFrame(frame) = queued else {
            panic!("expected queued screencast frame");
        };
        browser.store_frame_for_epoch(
            BrowserFrame {
                session_id: frame.session_id,
                data_b64: frame.data_b64,
                css_width: frame.css_width,
                css_height: frame.css_height,
                image_width: frame.image_width,
                image_height: frame.image_height,
                seq: 0,
            },
            frame.frame_epoch,
        );

        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "a frame queued before invalidation must not reopen pointer admission"
        );
    }

    #[test]
    fn older_navigation_event_cannot_settle_a_newer_command_barrier() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let older_epoch = browser.frame_epoch.advance();
        browser.begin_navigation_frame_transition().expect("navigation reservation");
        let expected_epoch = browser.state.lock().unwrap().pending_frame_epoch.unwrap();
        assert_ne!(older_epoch, expected_epoch);

        handle_frame_navigated(
            browser,
            json!({"frame": {"url": "https://old.test", "name": "old"}}),
            older_epoch,
        );

        assert_eq!(browser.latest_frame_seq(), None);
        assert_eq!(browser.state.lock().unwrap().pending_frame_epoch, Some(expected_epoch));
        assert_ne!(browser.url(), "https://old.test");
    }

    #[test]
    fn failed_newer_navigation_preserves_a_queued_committed_navigation() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let committed_epoch = browser.frame_epoch.advance_navigation();
        let newer = browser.begin_navigation_frame_transition().expect("newer navigation");
        let newer_epoch = newer.expected_frame_epoch.expect("newer navigation epoch");
        assert!(committed_epoch < newer_epoch);

        handle_frame_navigated(
            browser,
            json!({"frame": {"url": "https://committed.test", "name": "committed"}}),
            committed_epoch,
        );
        browser.restore_pointer_frame_after_failed_command(newer);

        assert_eq!(browser.url(), "https://committed.test");
        assert!(
            browser.needs_document_paint(committed_epoch),
            "the committed document must remain pending after the newer command fails"
        );
        let paint_epoch = browser.frame_epoch.advance();
        assert!(browser.accept_document_paint(committed_epoch, paint_epoch, test_frame(2)));
        assert_eq!(browser.latest_frame_seq(), Some(2));
        let state = browser.state.lock().unwrap();
        assert_eq!(state.accepted_navigation_epoch, committed_epoch);
        assert_eq!(state.accepted_frame_epoch, paint_epoch);
        assert_eq!(state.pending_navigation_epoch, None);
        assert_eq!(state.pending_document_epoch, None);
    }

    #[test]
    fn verified_committed_navigation_survives_a_newer_command_failure() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let committed_epoch = browser.frame_epoch.advance_navigation();
        let newer = browser.begin_navigation_frame_transition().expect("newer navigation");

        handle_frame_navigated(
            browser,
            json!({"frame": {"url": "https://committed.test", "name": "committed"}}),
            committed_epoch,
        );
        let paint_epoch = browser.frame_epoch.advance();
        assert!(browser.accept_document_paint(committed_epoch, paint_epoch, test_frame(2)));
        browser.restore_pointer_frame_after_failed_command(newer);

        assert_eq!(browser.url(), "https://committed.test");
        assert_eq!(browser.latest_frame_seq(), Some(2));
        let state = browser.state.lock().unwrap();
        assert_eq!(state.accepted_navigation_epoch, committed_epoch);
        assert_eq!(state.accepted_frame_epoch, paint_epoch);
        assert_eq!(state.pending_frame_epoch, None);
        assert_eq!(state.pending_navigation_epoch, None);
        assert_eq!(state.pending_document_epoch, None);
    }

    #[test]
    fn failed_replacement_restores_a_verified_commit_from_the_superseded_command() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let committed_epoch = browser.frame_epoch.advance_navigation();
        browser.begin_navigation_frame_transition().expect("unresolved newer navigation");
        handle_frame_navigated(
            browser,
            json!({"frame": {"url": "https://committed.test", "name": "committed"}}),
            committed_epoch,
        );
        let paint_epoch = browser.frame_epoch.advance();
        assert!(browser.accept_document_paint(committed_epoch, paint_epoch, test_frame(2)));

        let replacement =
            browser.begin_superseding_navigation_frame_transition(true).expect("replacement");
        browser.restore_pointer_frame_after_failed_command(replacement);

        assert_eq!(
            browser.latest_frame_seq(),
            Some(2),
            "the stopped command's verified document must regain pointer authority"
        );
        let state = browser.state.lock().unwrap();
        assert_eq!(state.accepted_navigation_epoch, committed_epoch);
        assert_eq!(state.accepted_frame_epoch, paint_epoch);
        assert_eq!(state.pending_navigation_epoch, None);
    }

    #[test]
    fn reconfigure_completion_dominates_queued_older_navigation_epoch() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        browser.begin_reconfigure_frame_transition();

        let navigation_epoch = browser.frame_epoch.advance_navigation();
        let reconfigure_epoch = browser.frame_epoch.advance();
        browser.confirm_reconfigure(queued, reconfigure_epoch);
        handle_frame_navigated(
            browser,
            json!({"frame": {"url": "https://next.test", "name": "next"}}),
            navigation_epoch,
        );
        browser.store_frame_for_epoch(test_frame(2), reconfigure_epoch);

        let state = browser.state.lock().unwrap();
        assert_eq!(
            state.accepted_frame_epoch, reconfigure_epoch,
            "an older queued navigation must not roll frame admission behind a completed resize"
        );
        assert_eq!(state.pending_frame_epoch, Some(reconfigure_epoch));
        assert_eq!(state.pending_document_epoch, Some(navigation_epoch));
        assert_eq!(
            state.latest_frame.as_ref().map(|frame| frame.seq),
            None,
            "unverified frames must remain pending even at the newest capture epoch"
        );
    }

    #[test]
    fn reconfigure_completion_does_not_release_uncommitted_navigation() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        browser.begin_navigation_frame_transition().expect("navigation reservation");

        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        browser.begin_reconfigure_frame_transition();
        let reconfigure_epoch = browser.frame_epoch.advance();
        browser.confirm_reconfigure(queued, reconfigure_epoch);
        browser.store_frame_for_epoch(test_frame(2), reconfigure_epoch);

        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "a resize frame cannot prove that an unresolved navigation committed"
        );
        assert!(
            browser.begin_navigation_frame_transition().is_err(),
            "the unresolved navigation must keep command serialization ownership across a resize"
        );

        let navigation_epoch = browser.frame_epoch.advance_navigation();
        handle_frame_navigated(
            browser,
            json!({"frame": {"url": "https://next.test", "name": "next"}}),
            navigation_epoch,
        );
        browser.store_frame_for_epoch(test_frame(3), navigation_epoch);
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "the navigation stream cannot authorize its own document identity"
        );
        assert!(browser.accept_document_paint(navigation_epoch, navigation_epoch, test_frame(3)));

        assert_eq!(
            browser.latest_frame_seq(),
            Some(3),
            "a loader-authorized paint may regain pointer authority"
        );
    }

    #[test]
    fn latest_navigation_supersedes_an_uncommitted_reload_epoch() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (superseded_tx, superseded_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let reload = read_ws_json(&mut ws);
            assert_eq!(reload["method"], "Page.reload");
            write_ws_json(&mut ws, json!({"id": reload["id"], "result": {}}));

            let Ok(message) = ws.read() else {
                superseded_tx.send(false).unwrap();
                return;
            };
            let stop_loading: Value = serde_json::from_str(message.to_text().unwrap()).unwrap();
            if stop_loading["method"] != "Page.stopLoading" {
                superseded_tx.send(false).unwrap();
                return;
            }
            write_ws_json(&mut ws, json!({"id": stop_loading["id"], "result": {}}));

            let navigate = read_ws_json(&mut ws);
            assert_eq!(navigate["method"], "Page.navigate");
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.frameNavigated",
                    "sessionId": "session-1",
                    "params": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "next-loader",
                            "url": "https://next.test"
                        }
                    }
                }),
            );
            write_ws_json(
                &mut ws,
                json!({
                    "id": navigate["id"],
                    "result": {"frameId": "main-frame", "loaderId": "next-loader"}
                }),
            );
            superseded_tx.send(true).unwrap();
            stop_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let route = runtime.register("target-1", "session-1");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        start_surface_thread(
            surface.clone(),
            route,
            Weak::new(),
            Arc::downgrade(&runtime),
            "session-1".to_string(),
        )
        .unwrap();
        browser.store_frame(test_frame(1));

        browser.reload_blocking().unwrap();
        let navigate_result = browser.navigate_blocking("https://next.test");
        let superseded = superseded_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap_or(false);

        let mut admitted = false;
        if navigate_result.is_ok() {
            let deadline = Instant::now() + BROWSER_TEST_EVENT_TIMEOUT;
            while Instant::now() < deadline
                && browser.state.lock().unwrap().pending_navigation_epoch.is_some()
            {
                thread::yield_now();
            }
            let navigation_epoch = browser.frame_epoch.current();
            admitted =
                browser.accept_document_paint(navigation_epoch, navigation_epoch, test_frame(2));
        }
        let _ = stop_tx.send(());
        runtime.shutdown();
        server.join().unwrap();

        assert!(
            navigate_result.is_ok(),
            "the latest URL must replace an unresolved reload instead of being consumed"
        );
        assert!(
            superseded,
            "Chrome must cancel the unresolved load before accepting its replacement"
        );
        assert!(admitted, "the replacement document must regain pointer authority");
        let state = browser.state.lock().unwrap();
        assert_eq!(state.pending_frame_epoch, None);
        assert_eq!(state.pending_navigation_epoch, None);
        assert_eq!(state.accepted_frame_epoch, browser.frame_epoch.current());
        drop(state);
        assert_eq!(browser.url(), "https://next.test");
    }

    #[test]
    fn reload_supersedes_an_uncommitted_navigation() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (superseded_tx, superseded_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let first_reload = read_ws_json(&mut ws);
            assert_eq!(first_reload["method"], "Page.reload");
            write_ws_json(&mut ws, json!({"id": first_reload["id"], "result": {}}));

            let Ok(message) = ws.read() else {
                superseded_tx.send(false).unwrap();
                return;
            };
            let stop_loading: Value = serde_json::from_str(message.to_text().unwrap()).unwrap();
            if stop_loading["method"] != "Page.stopLoading" {
                superseded_tx.send(false).unwrap();
                return;
            }
            write_ws_json(&mut ws, json!({"id": stop_loading["id"], "result": {}}));

            let second_reload = read_ws_json(&mut ws);
            if second_reload["method"] != "Page.reload" {
                superseded_tx.send(false).unwrap();
                return;
            }
            write_ws_json(&mut ws, json!({"id": second_reload["id"], "result": {}}));
            superseded_tx.send(true).unwrap();
            stop_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));

        browser.reload_blocking().unwrap();
        let second_reload = browser.reload_blocking();
        let superseded = superseded_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap_or(false);

        let _ = stop_tx.send(());
        runtime.shutdown();
        server.join().unwrap();

        assert!(
            second_reload.is_ok(),
            "reload must replace an unresolved navigation instead of remaining permanently blocked"
        );
        assert!(
            superseded,
            "Chrome must cancel the unresolved navigation before accepting the retry"
        );
        let state = browser.state.lock().unwrap();
        assert!(state.pending_navigation_epoch.is_some());
        assert_eq!(state.pointer_frame_seq, None, "the retry must remain fail-closed until paint");
    }

    #[test]
    fn superseded_uncommitted_navigation_rollback_restores_original_authority() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let (_, capture_generation, _, _) =
            browser.capture_guarded_input_point(1, 1.0, 1.0).expect("initial pointer authority");
        let first = browser.begin_navigation_frame_transition().unwrap();
        browser.finish_navigation_command(first, Ok(())).unwrap();
        assert_eq!(browser.latest_frame_seq(), None);

        let replacement = browser.begin_superseding_navigation_frame_transition(true).unwrap();
        browser.restore_pointer_frame_after_failed_command(replacement);

        assert_eq!(
            browser.latest_frame_seq(),
            Some(1),
            "a stopped uncommitted navigation must retain the original rollback authority"
        );
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "rollback must restore the capture generation that owned the displayed document"
        );
    }

    #[test]
    fn ambiguous_guarded_press_failure_retains_release_ownership() {
        let (runtime, server) = runtime_rejecting_one_mouse_dispatch();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let mut active_pointer_presses = std::collections::HashMap::new();

        let result = browser.mouse_event_blocking(
            super::BrowserMouseDispatch {
                input_owner: super::BrowserPointerOwner::Legacy,
                event_type: "mousePressed",
                x: 1.0,
                y: 1.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: Some(1),
            },
            &mut active_pointer_presses,
        );

        assert!(result.is_err());
        assert!(
            active_pointer_presses.contains_key("left"),
            "a timed-out press may have reached Chrome and still owns its balancing release"
        );
        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn guarded_press_capture_cannot_be_stolen_by_another_input_client() {
        let (runtime, server) =
            runtime_accepting_mouse_dispatches(vec!["mousePressed", "mouseReleased"]);
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let mut active_pointer_presses = std::collections::HashMap::new();

        for dispatch in [
            super::BrowserMouseDispatch {
                input_owner: super::BrowserPointerOwner::Client(41),
                event_type: "mousePressed",
                x: 1.0,
                y: 1.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: Some(1),
            },
            super::BrowserMouseDispatch {
                input_owner: super::BrowserPointerOwner::Client(42),
                event_type: "mousePressed",
                x: 2.0,
                y: 2.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: Some(1),
            },
            super::BrowserMouseDispatch {
                input_owner: super::BrowserPointerOwner::Client(42),
                event_type: "mouseReleased",
                x: 2.0,
                y: 2.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: Some(1),
            },
        ] {
            browser.mouse_event_blocking(dispatch, &mut active_pointer_presses).unwrap();
        }
        assert_eq!(
            active_pointer_presses.get("left").map(|press| press.input_owner),
            Some(super::BrowserPointerOwner::Client(41)),
            "a competing client must not overwrite or consume the original press capture"
        );

        browser
            .mouse_event_blocking(
                super::BrowserMouseDispatch {
                    input_owner: super::BrowserPointerOwner::Client(41),
                    event_type: "mouseReleased",
                    x: 1.0,
                    y: 1.0,
                    button: Some("left"),
                    click_count: Some(1),
                    frame_seq: Some(1),
                },
                &mut active_pointer_presses,
            )
            .unwrap();
        assert!(active_pointer_presses.is_empty());

        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn ambiguous_guarded_release_failure_gets_one_bounded_retry() {
        let (runtime, server, retry_rx) = runtime_rejecting_then_observing_mouse_retry();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
        let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
        let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
        let mut active_pointer_presses = std::collections::HashMap::from([(
            "left".to_string(),
            super::ActivePointerPress::new(
                super::BrowserPointerOwner::Local,
                capture_generation,
                motion_generation,
                ingress_motion_generation,
                1,
                (1.0, 1.0),
                Some(1),
            ),
        )]);

        let result = browser.mouse_event_blocking(
            super::BrowserMouseDispatch {
                input_owner: super::BrowserPointerOwner::Local,
                event_type: "mouseReleased",
                x: 1.0,
                y: 1.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: Some(1),
            },
            &mut active_pointer_presses,
        );

        assert!(result.is_err());
        assert!(
            active_pointer_presses.contains_key("left"),
            "a timed-out release must remain retryable"
        );
        browser.mark_failed("browser is not responding".to_string());
        assert!(
            browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none(),
            "the not-responding transition must revoke admission for new pointer input"
        );
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "the not-responding transition must preserve an accepted release capture"
        );

        let mut failures =
            super::BrowserWorkerErrorState { active_pointer_presses, ..Default::default() };
        super::release_abandoned_pointer_presses(
            &surface,
            &Weak::new(),
            surface.id,
            &mut failures,
            Instant::now() + Duration::from_secs(1),
        );
        assert!(
            failures.active_pointer_presses.is_empty(),
            "the worker must consume an ambiguous release through one scheduled retry"
        );
        assert!(
            retry_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap(),
            "the balancing release must retain its dispatched coordinates across invalidation"
        );

        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn abandoned_pointer_release_timeout_gets_one_bounded_retry() {
        let (runtime, server, retry_rx) = runtime_rejecting_then_observing_mouse_retry();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
        let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
        let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
        let mut failures = super::BrowserWorkerErrorState::default();
        failures.active_pointer_presses.insert(
            "left".to_string(),
            super::ActivePointerPress::new(
                super::BrowserPointerOwner::Client(41),
                capture_generation,
                motion_generation,
                ingress_motion_generation,
                1,
                (1.0, 1.0),
                Some(1),
            ),
        );
        let now = Instant::now();

        super::release_abandoned_pointer_presses(
            &surface,
            &Weak::new(),
            surface.id,
            &mut failures,
            now,
        );
        let retained_after_timeout = failures.active_pointer_presses.contains_key("left");
        let retry_at = failures
            .active_pointer_presses
            .get("left")
            .and_then(|press| press.release_retry_at)
            .expect("the ambiguous release must schedule one retry");
        super::release_abandoned_pointer_presses(
            &surface,
            &Weak::new(),
            surface.id,
            &mut failures,
            now,
        );
        let retained_before_retry = failures.active_pointer_presses.contains_key("left");
        let retried_without_yielding = retry_rx.recv_timeout(Duration::from_millis(20)).ok();
        super::release_abandoned_pointer_presses(
            &surface,
            &Weak::new(),
            surface.id,
            &mut failures,
            retry_at,
        );
        let consumed_after_retry = failures.active_pointer_presses.is_empty();
        let retry_observed = retried_without_yielding
            .unwrap_or_else(|| retry_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap());

        runtime.shutdown();
        server.join().unwrap();

        assert!(
            retained_after_timeout,
            "the first ambiguous cleanup release must remain owned for one retry"
        );
        assert!(retry_at > now, "the retry must yield the worker before another CDP call");
        assert!(
            retained_before_retry,
            "the retry must remain pending until its deferred lifecycle deadline"
        );
        assert!(
            retried_without_yielding.is_none(),
            "the worker must not perform two potentially long CDP calls back-to-back"
        );
        assert!(consumed_after_retry, "the bounded cleanup retry must consume the press");
        assert!(retry_observed, "cleanup must dispatch one balancing release retry");
    }

    #[test]
    fn captured_release_remains_admitted_during_ambiguous_reconfigure() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let (_, capture_generation, _, _) =
            browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live pointer capture");

        browser.begin_reconfigure_frame_transition();

        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "a geometry barrier must preserve an accepted press's balancing release"
        );
    }

    #[test]
    fn geometry_change_suppresses_captured_motion_and_releases_at_last_authoritative_point() {
        let (runtime, server, events, stop) = runtime_recording_mouse_dispatches();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let mut active_pointer_presses = std::collections::HashMap::new();

        browser
            .mouse_event_blocking(
                super::BrowserMouseDispatch {
                    input_owner: super::BrowserPointerOwner::Local,
                    event_type: "mousePressed",
                    x: 8.0,
                    y: 16.0,
                    button: Some("left"),
                    click_count: Some(1),
                    frame_seq: Some(1),
                },
                &mut active_pointer_presses,
            )
            .unwrap();
        let press = events.recv_timeout(Duration::from_secs(1)).unwrap();

        let queued = browser.reserve_reconfigure(20, 10).expect("changed geometry");
        browser.begin_reconfigure_frame_transition();
        browser.confirm_reconfigure(queued, browser.frame_epoch.advance());
        browser
            .mouse_event_blocking(
                super::BrowserMouseDispatch {
                    input_owner: super::BrowserPointerOwner::Local,
                    event_type: "mouseMoved",
                    x: 80.0,
                    y: 80.0,
                    button: Some("left"),
                    click_count: None,
                    frame_seq: Some(1),
                },
                &mut active_pointer_presses,
            )
            .unwrap();
        let motion = events.recv_timeout(Duration::from_millis(100)).ok();

        browser
            .mouse_event_blocking(
                super::BrowserMouseDispatch {
                    input_owner: super::BrowserPointerOwner::Local,
                    event_type: "mouseReleased",
                    x: 80.0,
                    y: 80.0,
                    button: Some("left"),
                    click_count: Some(1),
                    frame_seq: Some(1),
                },
                &mut active_pointer_presses,
            )
            .unwrap();
        let release = events.recv_timeout(Duration::from_secs(1)).unwrap();
        stop.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();

        assert!(
            motion.is_none(),
            "motion captured under the old geometry must not cross a resize barrier"
        );
        assert_eq!(release["params"]["type"], "mouseReleased");
        assert_eq!(release["params"]["x"], press["params"]["x"]);
        assert_eq!(release["params"]["y"], press["params"]["y"]);
        assert!(
            active_pointer_presses.is_empty(),
            "the balancing release must settle the retained press"
        );
    }

    #[test]
    fn pointer_admission_changes_are_broadcast_to_attach_clients() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let (_snapshot, stream) = browser.attach_frames();

        let invalidation = browser.invalidate_pointer_frame();
        stream
            .notify
            .recv_timeout(Duration::from_secs(1))
            .expect("pointer invalidation must wake attached clients");
        let invalidated = stream
            .slot
            .lock()
            .unwrap()
            .state
            .take()
            .expect("pointer invalidation must publish browser state");
        assert_eq!(
            invalidated.pointer_frame_seq, None,
            "attached clients must stop admitting the retained frame"
        );

        browser.restore_pointer_frame_after_failed_command(invalidation);
        stream
            .notify
            .recv_timeout(Duration::from_secs(1))
            .expect("failed-command rollback must wake attached clients");
        let restored = stream
            .slot
            .lock()
            .unwrap()
            .state
            .take()
            .expect("failed-command rollback must publish browser state");
        assert_eq!(
            restored.pointer_frame_seq,
            Some(1),
            "attached clients must restore admission after a rejected navigation"
        );
    }

    #[test]
    fn ingress_navigation_hides_stale_pointer_authority_from_attach_clients() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let stale_epoch = browser.frame_epoch.current();

        browser.frame_epoch.advance_navigation();
        let (snapshot, stream) = browser.attach_frames();
        browser.store_frame_for_epoch(test_frame(2), stale_epoch);
        stream
            .notify
            .recv_timeout(Duration::from_secs(1))
            .expect("stale queued frame must still update retained pixels");
        let update = stream.slot.lock().unwrap().frame.take().expect("stale retained frame");

        assert_eq!(
            snapshot.pointer_frame_seq, None,
            "an initial attach must not export authority after ingress observes navigation"
        );
        assert_eq!(
            update.pointer_frame_seq, None,
            "a queued old-epoch frame must not regain exported pointer authority"
        );
    }

    #[test]
    fn geometry_pointer_admission_invalidation_is_broadcast_to_attach_clients() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let (_snapshot, stream) = browser.attach_frames();

        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        browser.confirm_reconfigure(queued, browser.frame_epoch.advance());

        stream
            .notify
            .recv_timeout(Duration::from_secs(1))
            .expect("geometry invalidation must wake attached clients");
        let invalidated = stream
            .slot
            .lock()
            .unwrap()
            .state
            .take()
            .expect("geometry invalidation must publish browser state");
        assert_eq!(
            invalidated.pointer_frame_seq, None,
            "attached clients must stop admitting the pre-resize frame"
        );
    }

    #[test]
    fn pointer_capture_survives_repaint_but_not_navigation() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let (_, capture_generation, _, _) =
            browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live press frame");

        browser.store_frame(test_frame(2));
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "ordinary repaint frames must preserve pointer capture"
        );

        let reconfigure = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        browser.confirm_reconfigure(reconfigure, browser.frame_epoch.advance());
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "geometry changes must preserve capture so the page receives its release"
        );

        browser.invalidate_pointer_frame();
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_none(),
            "navigation must revoke pointer capture from the previous document"
        );
    }

    #[test]
    fn failed_navigation_dispatch_restores_the_rendered_frame_admission() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
            let navigate = read_ws_json(&mut ws);
            assert_eq!(navigate["method"], "Page.navigate");
            write_ws_json(
                &mut ws,
                json!({"id": navigate["id"], "error": {"message": "injected failure"}}),
            );
            stop_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some());
        let (_, capture_generation, _, _) =
            browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live press frame");

        assert!(browser.navigate_blocking("https://next.test").is_err());

        let restored = browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some();
        let capture_restored =
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some();
        stop_tx.send(()).unwrap();
        runtime.shutdown();
        server.join().unwrap();
        assert!(restored, "a rejected navigation must leave the rendered frame interactive");
        assert!(capture_restored, "a rejected navigation must restore active capture ownership");
    }

    #[test]
    fn response_level_navigation_failure_clears_frame_epoch_reservation() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
            let navigate = read_ws_json(&mut ws);
            assert_eq!(navigate["method"], "Page.navigate");
            write_ws_json(
                &mut ws,
                json!({"id": navigate["id"], "result": {"errorText": "navigation rejected"}}),
            );
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));

        assert!(browser.navigate_blocking("https://rejected.test").is_err());

        assert_eq!(
            browser.state.lock().unwrap().pending_frame_epoch,
            None,
            "a response-level failure must not poison the next navigation epoch"
        );
        assert_eq!(browser.state.lock().unwrap().pending_navigation_epoch, None);
        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn loaderless_navigation_response_reconciles_the_unchanged_document() {
        const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (post_navigate_delay_tx, post_navigate_delay_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
            let navigate = read_ws_json(&mut ws);
            assert_eq!(navigate["method"], "Page.navigate");
            write_ws_json(
                &mut ws,
                json!({"id": navigate["id"], "result": {"frameId": "main-frame"}}),
            );
            let navigate_response_at = Instant::now();
            for expected in [
                "Page.getFrameTree",
                "Page.stopScreencast",
                "Page.createIsolatedWorld",
                "Runtime.evaluate",
                "Page.startScreencast",
                "Page.getFrameTree",
                "Page.captureScreenshot",
                "Page.getFrameTree",
            ] {
                let request = read_ws_json(&mut ws);
                if expected == "Page.getFrameTree" {
                    post_navigate_delay_tx.send(navigate_response_at.elapsed()).unwrap();
                }
                assert_eq!(request["method"], expected);
                let result = match expected {
                    "Page.getFrameTree" => json!({
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test#same-document"
                            }
                        }
                    }),
                    "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                    "Runtime.evaluate" => {
                        json!({"result": {"type": "number", "value": 10_000.0}})
                    }
                    "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                    _ => json!({}),
                };
                write_ws_json(&mut ws, json!({"id": request["id"], "result": result}));
            }
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));

        let result = browser.navigate_blocking("https://example.test#same-document");
        let post_navigate_delay =
            post_navigate_delay_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let state = browser.state.lock().unwrap();
        let pending_frame_epoch = state.pending_frame_epoch;
        let pending_navigation_epoch = state.pending_navigation_epoch;
        let pointer_frame_seq = state.pointer_frame_seq;
        drop(state);
        runtime.shutdown();
        server.join().unwrap();

        assert!(result.is_ok());
        assert_eq!(
            pending_frame_epoch, None,
            "a loaderless acknowledgment must not leave a cross-document barrier behind"
        );
        assert_eq!(pending_navigation_epoch, None);
        assert_eq!(
            pointer_frame_seq,
            Some(2),
            "the unchanged document must regain authority through freshly captured pixels"
        );
        assert!(
            post_navigate_delay < super::NAVIGATION_COMMIT_WAIT / 2,
            "loaderless same-document navigation waited {post_navigate_delay:?} for an epoch that cannot advance"
        );
    }

    #[test]
    fn loaderless_navigation_retries_snapshot_invalidated_by_same_document_event() {
        const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let seed = read_ws_json(&mut ws);
            assert_eq!(seed["method"], "Page.getFrameTree");
            write_ws_json(
                &mut ws,
                json!({
                    "id": seed["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test"
                            }
                        }
                    }
                }),
            );

            let navigate = read_ws_json(&mut ws);
            assert_eq!(navigate["method"], "Page.navigate");
            write_ws_json(
                &mut ws,
                json!({"id": navigate["id"], "result": {"frameId": "main-frame"}}),
            );

            let first_snapshot = read_ws_json(&mut ws);
            assert_eq!(first_snapshot["method"], "Page.getFrameTree");
            write_ws_json(
                &mut ws,
                json!({
                    "method": "Page.navigatedWithinDocument",
                    "sessionId": "session-1",
                    "params": {
                        "frameId": "main-frame",
                        "url": "https://example.test#same-document"
                    }
                }),
            );
            write_ws_json(
                &mut ws,
                json!({
                    "id": first_snapshot["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test#same-document"
                            }
                        }
                    }
                }),
            );

            let retry = match ws.read() {
                Ok(message @ (Message::Text(_) | Message::Binary(_))) => {
                    Some(serde_json::from_slice::<Value>(&message.into_data()).unwrap())
                }
                Ok(_) | Err(_) => None,
            };
            let Some(retry) = retry else { return false };
            assert_eq!(retry["method"], "Page.getFrameTree");
            write_ws_json(
                &mut ws,
                json!({
                    "id": retry["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test#same-document"
                            }
                        }
                    }
                }),
            );

            for expected in [
                "Page.stopScreencast",
                "Page.createIsolatedWorld",
                "Runtime.evaluate",
                "Page.startScreencast",
                "Page.getFrameTree",
                "Page.captureScreenshot",
                "Page.getFrameTree",
            ] {
                let request = read_ws_json(&mut ws);
                assert_eq!(request["method"], expected);
                let result = match expected {
                    "Page.getFrameTree" => json!({
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test#same-document"
                            }
                        }
                    }),
                    "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                    "Runtime.evaluate" => {
                        json!({"result": {"type": "number", "value": 10_000.0}})
                    }
                    "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                    _ => json!({}),
                };
                write_ws_json(&mut ws, json!({"id": request["id"], "result": result}));
            }
            true
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        runtime.client.seed_main_frame("session-1").unwrap();
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));

        let result = browser.navigate_blocking("https://example.test#same-document");
        let pointer_frame_seq = browser.state.lock().unwrap().pointer_frame_seq;
        runtime.shutdown();
        let retried = server.join().unwrap();

        assert!(
            result.is_ok(),
            "a normal same-document event race must retry its invalidated snapshot: {result:?}"
        );
        assert!(retried, "loaderless reconciliation did not request a fresh snapshot");
        assert_eq!(
            pointer_frame_seq,
            Some(2),
            "verified post-navigation pixels must restore pointer authority"
        );
    }

    #[test]
    fn loaderless_navigation_snapshot_failure_settles_the_transition() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
            let navigate = read_ws_json(&mut ws);
            assert_eq!(navigate["method"], "Page.navigate");
            write_ws_json(
                &mut ws,
                json!({"id": navigate["id"], "result": {"frameId": "main-frame"}}),
            );
            let snapshot = read_ws_json(&mut ws);
            assert_eq!(snapshot["method"], "Page.getFrameTree");
            write_ws_json(
                &mut ws,
                json!({
                    "id": snapshot["id"],
                    "error": {"code": -32000, "message": "snapshot unavailable"}
                }),
            );
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));

        let result = browser.navigate_blocking("https://example.test#same-document");
        let state = browser.state.lock().unwrap();
        let pending_frame_epoch = state.pending_frame_epoch;
        let pending_navigation_epoch = state.pending_navigation_epoch;
        let pending_same_document_navigation = state.pending_same_document_navigation;
        let status = state.status.clone();
        drop(state);
        let retry = browser.begin_targeted_navigation_frame_transition();
        runtime.shutdown();
        server.join().unwrap();

        assert!(result.is_err(), "the failed snapshot must be reported");
        assert_eq!(pending_frame_epoch, None);
        assert_eq!(pending_navigation_epoch, None);
        assert!(!pending_same_document_navigation);
        assert!(
            matches!(status.failure(), Some(super::BrowserFailure::UpdatedPageVerification(_))),
            "the retryable terminal failure must remain visible"
        );
        assert!(
            retry.is_ok(),
            "a transient loaderless snapshot failure must not block later navigation controls"
        );
    }

    #[test]
    fn download_navigation_restores_current_document_pointer_authority() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
            let navigate = read_ws_json(&mut ws);
            assert_eq!(navigate["method"], "Page.navigate");
            write_ws_json(
                &mut ws,
                json!({
                    "id": navigate["id"],
                    "result": {
                        "frameId": "main-frame",
                        "isDownload": true,
                        "errorText": "net::ERR_ABORTED"
                    }
                }),
            );
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let previous_url = browser.url();

        browser.navigate_blocking("https://example.test/download").unwrap();

        let state = browser.state.lock().unwrap();
        assert_eq!(state.pending_frame_epoch, None);
        assert_eq!(state.pending_navigation_epoch, None);
        assert_eq!(
            state.pointer_frame_seq,
            Some(1),
            "a download must leave the unchanged document interactive"
        );
        drop(state);
        assert_eq!(browser.url(), previous_url, "a download must not replace the document URL");
        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn timed_out_navigation_keeps_pointer_admission_blocked() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let invalidation = browser.invalidate_pointer_frame();

        let result: anyhow::Result<()> = browser.restore_pointer_frame_on_command_error(
            invalidation,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        );

        assert!(result.is_err());
        assert_eq!(
            browser.latest_frame_seq(),
            None,
            "an ambiguously delivered navigation must remain fail-closed"
        );
    }

    #[test]
    fn production_navigation_timeout_keeps_pointer_admission_blocked() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let invalidation = browser.begin_navigation_frame_transition().unwrap();
        let expected_epoch = invalidation.expected_frame_epoch;

        let result: anyhow::Result<()> = browser.finish_navigation_command(
            invalidation,
            Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        );

        assert!(result.is_err());
        let state = browser.state.lock().unwrap();
        assert_eq!(
            state.pending_frame_epoch, expected_epoch,
            "an ambiguous production timeout must retain its navigation barrier"
        );
        assert_eq!(state.pending_navigation_epoch, expected_epoch);
        assert_eq!(state.pointer_frame_seq, None);
    }

    #[test]
    fn successful_navigation_without_commit_keeps_pointer_admission_blocked() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let invalidation = browser.begin_navigation_frame_transition().unwrap();
        let expected_epoch = invalidation.expected_frame_epoch;

        let result: anyhow::Result<()> = browser.finish_navigation_command(invalidation, Ok(()));

        assert!(result.is_ok());
        let state = browser.state.lock().unwrap();
        assert_eq!(
            state.pending_frame_epoch, expected_epoch,
            "command acknowledgment must not settle navigation before its authoritative event"
        );
        assert_eq!(state.pending_navigation_epoch, expected_epoch);
        assert_eq!(
            state.pointer_frame_seq, None,
            "the pre-navigation frame must remain non-interactive while commit is unresolved"
        );
    }

    #[test]
    fn failed_reconfigure_restores_frame_admission_and_capture() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let metrics = read_ws_json(&mut ws);
            assert_eq!(metrics["method"], "Emulation.setDeviceMetricsOverride");
            write_ws_json(
                &mut ws,
                json!({"id": metrics["id"], "error": {"message": "injected resize failure"}}),
            );
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        acknowledge_local_presentation(browser, 1);
        let (_, capture_generation, _, _) =
            browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live pointer capture");
        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");

        assert!(browser.reconfigure_reserved_blocking(queued).is_err());

        let state = browser.state.lock().unwrap();
        assert_eq!(
            state.pending_frame_epoch, None,
            "a rejected resize must release its frame-epoch reservation"
        );
        assert_eq!(state.pointer_frame_seq, Some(1));
        drop(state);
        assert!(
            browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
            "a resize failure must preserve ownership of a balancing pointer release"
        );
        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn reconfigure_failure_after_metrics_commit_keeps_pointer_admission_blocked() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let frame_tree = read_ws_json(&mut ws);
            assert_eq!(frame_tree["method"], "Page.getFrameTree");
            write_ws_json(
                &mut ws,
                json!({
                    "id": frame_tree["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test"
                            }
                        }
                    }
                }),
            );

            let metrics = read_ws_json(&mut ws);
            assert_eq!(metrics["method"], "Emulation.setDeviceMetricsOverride");
            write_ws_json(&mut ws, json!({"id": metrics["id"], "result": {}}));

            let stop = read_ws_json(&mut ws);
            assert_eq!(stop["method"], "Page.stopScreencast");
            write_ws_json(&mut ws, json!({"id": stop["id"], "result": {}}));

            let isolated_world = read_ws_json(&mut ws);
            assert_eq!(isolated_world["method"], "Page.createIsolatedWorld");
            write_ws_json(
                &mut ws,
                json!({
                    "id": isolated_world["id"],
                    "result": {"executionContextId": 41}
                }),
            );

            let wall_time = read_ws_json(&mut ws);
            assert_eq!(wall_time["method"], "Runtime.evaluate");
            write_ws_json(
                &mut ws,
                json!({
                    "id": wall_time["id"],
                    "result": {
                        "result": {"type": "number", "value": 10_000.0}
                    }
                }),
            );

            let start = read_ws_json(&mut ws);
            assert_eq!(start["method"], "Page.startScreencast");
            write_ws_json(
                &mut ws,
                json!({"id": start["id"], "error": {"message": "injected capture failure"}}),
            );
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        runtime.client.seed_main_frame("session-1").unwrap();
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");

        assert!(browser.reconfigure_reserved_blocking(queued).is_err());

        let state = browser.state.lock().unwrap();
        assert!(
            state.pending_frame_epoch.is_some(),
            "a post-mutation failure must retain the frame-epoch reservation"
        );
        assert_eq!(
            state.pointer_frame_seq, None,
            "the pre-resize frame must not regain pointer authority after partial reconfiguration"
        );
        drop(state);
        runtime.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn reconfigure_survives_unavailable_screencast_clock_probe() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            ws.get_mut().set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            let frame_tree = read_ws_json(&mut ws);
            assert_eq!(frame_tree["method"], "Page.getFrameTree");
            write_ws_json(
                &mut ws,
                json!({
                    "id": frame_tree["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test"
                            }
                        }
                    }
                }),
            );

            let metrics = read_ws_json(&mut ws);
            assert_eq!(metrics["method"], "Emulation.setDeviceMetricsOverride");
            write_ws_json(&mut ws, json!({"id": metrics["id"], "result": {}}));

            let stop = read_ws_json(&mut ws);
            assert_eq!(stop["method"], "Page.stopScreencast");
            write_ws_json(&mut ws, json!({"id": stop["id"], "result": {}}));

            let isolated_world = read_ws_json(&mut ws);
            assert_eq!(isolated_world["method"], "Page.createIsolatedWorld");
            write_ws_json(
                &mut ws,
                json!({
                    "id": isolated_world["id"],
                    "error": {"message": "scripts unavailable"}
                }),
            );

            let start = read_ws_json(&mut ws);
            assert_eq!(start["method"], "Page.startScreencast");
            write_ws_json(&mut ws, json!({"id": start["id"], "result": {}}));
        });
        let runtime = super::BrowserRuntime::connect_to_endpoint(
            &format!("ws://{addr}/devtools/browser/fake"),
            None,
            BrowserSource::External,
        )
        .unwrap();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
        runtime.client.seed_main_frame("session-1").unwrap();
        *browser.session.lock().unwrap() = Some(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        });
        browser.store_frame(test_frame(1));
        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");

        let result = browser.reconfigure_reserved_blocking(queued);

        runtime.shutdown();
        let server_result = server.join();
        assert!(
            result.is_ok(),
            "an unavailable optional clock probe must not fail browser resize: {result:?}"
        );
        server_result.unwrap();
        assert_eq!(browser.status(), BrowserStatus::Live);
        assert_eq!(browser.size(), (11, 5));
        let state = browser.state.lock().unwrap();
        assert_eq!(state.pending_frame_epoch, None);
        assert_eq!(
            state.pointer_frame_seq, None,
            "pointer input must wait for a frame verified after the resize"
        );
    }

    #[test]
    fn frames_stalled_requires_live_surface_over_threshold() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let now = Instant::now();
        {
            let mut state = browser.state.lock().unwrap();
            state.status = BrowserStatus::Live;
            state.live_since = Some(now - Duration::from_secs(3));
            state.last_frame_at = None;
        }
        assert!(browser.frames_stalled_at(now));

        browser.store_frame(test_frame(1));
        assert!(!browser.frames_stalled_at(Instant::now()));

        browser.mark_failed("nope".to_string());
        {
            let mut state = browser.state.lock().unwrap();
            state.last_frame_at = Some(now - Duration::from_secs(3));
        }
        assert!(!browser.frames_stalled_at(now));
    }

    #[test]
    fn same_size_resize_does_not_reset_stall_state() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let now = Instant::now();
        {
            let mut state = browser.state.lock().unwrap();
            state.status = BrowserStatus::Live;
            state.live_since = Some(now - Duration::from_secs(10));
            state.last_frame_at = Some(now - Duration::from_secs(3));
            state.stall_nudged = true;
        }
        assert!(browser.frames_stalled_at(now));

        assert!(browser.reserve_reconfigure(10, 5).is_none());
        {
            let state = browser.state.lock().unwrap();
            assert_eq!(state.last_frame_at, Some(now - Duration::from_secs(3)));
            assert!(state.stall_nudged);
        }
        assert!(browser.frames_stalled_at(now));

        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        browser.reconfigure_reserved_blocking(queued).unwrap();
        let state = browser.state.lock().unwrap();
        assert_eq!(state.last_frame_at, None);
        assert!(!state.stall_nudged);
        assert!(!super::frames_stalled_locked(&state, Instant::now(), false));
    }

    #[test]
    fn cell_pixel_mismatch_requires_browser_resize() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new())
                .unwrap();
        let browser = surface.as_browser().expect("browser surface");
        assert!(!browser.resize_needed(10, 5));

        *browser.cell_pixels.lock().unwrap() = (9, 16);
        assert!(browser.resize_needed(10, 5));
    }

    #[test]
    fn cell_pixel_change_reports_only_accepted_reconfigure() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new())
                .unwrap();
        let browser = surface.as_browser().expect("browser surface");

        assert!(browser.set_cell_pixel_size(9, 16).unwrap());
        assert!(!browser.set_cell_pixel_size(9, 16).unwrap());
    }

    #[test]
    fn rejected_cell_pixel_enqueue_can_retry_the_same_metrics() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
            assert!(browser.enqueue_test_command(BrowserCommand::Activate));
        }

        let (reported_tx, reported_rx) = mpsc::channel();
        assert!(
            browser
                .set_cell_pixel_size_reporting(
                    9,
                    16,
                    Box::new(move |accepted| reported_tx.send(accepted).unwrap()),
                )
                .is_err()
        );
        assert!(reported_rx.recv_timeout(Duration::from_secs(1)).unwrap().is_none());

        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            match browser.set_cell_pixel_size(9, 16) {
                Ok(true) => break,
                Err(_) if Instant::now() < deadline => thread::yield_now(),
                result => panic!("same cell metrics were not retryable: {result:?}"),
            }
        }

        browser.kill();
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after retry");
    }

    #[test]
    fn full_command_queue_retains_pointer_release_without_blocking_producer() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let (entered, started) = mpsc::channel();
        let (release_worker, held) = mpsc::channel();
        assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
            assert!(browser.enqueue_test_command(BrowserCommand::Activate));
        }

        let queued_surface = surface.clone();
        let (settled_tx, settled_rx) = mpsc::channel();
        let enqueue = thread::spawn(move || {
            let result = queued_surface.browser_mouse_event(
                "mouseReleased",
                1.0,
                1.0,
                Some("left"),
                Some(1),
            );
            settled_tx.send(result).unwrap();
        });
        let settled_while_full = settled_rx.recv_timeout(Duration::from_millis(20)).is_ok();
        assert_eq!(
            browser.command_order.lock().unwrap().retained_releases.len(),
            1,
            "the nonblocking enqueue must retain the release"
        );

        release_worker.send(()).unwrap();
        if !settled_while_full {
            settled_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("release enqueue should settle after the worker drains")
                .unwrap();
        }
        enqueue.join().unwrap();
        browser.kill();
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after release");

        assert!(
            settled_while_full,
            "retaining a release must not block the shared browser input producer"
        );
    }

    #[test]
    fn synthesized_key_press_survives_the_final_core_queue_boundary() {
        let (runtime, server, observed, start) = runtime_recording_key_dispatches();
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        browser
            .mark_live(BrowserSession {
                runtime: runtime.clone(),
                target_id: "target-1".to_string(),
                session_id: "session-1".to_string(),
            })
            .unwrap();
        let (entered, started) = mpsc::channel();
        let (release_worker, held) = mpsc::channel();
        assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY - 1 {
            assert!(browser.enqueue_test_command(BrowserCommand::WakeLatest));
        }

        surface.browser_key_press("j", "KeyJ", 74, 1, None).unwrap();
        start.send(()).unwrap();
        release_worker.send(()).unwrap();

        let event_types = observed.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap();
        browser.kill();
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after release");
        runtime.shutdown();
        server.join().unwrap();
        assert_eq!(
            event_types,
            vec!["keyDown", "keyUp"],
            "the final bounded queue split a synthesized key press"
        );
    }

    #[test]
    fn resize_acceptance_is_reported_by_worker_before_execution() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        let accepted = Arc::new(AtomicBool::new(false));
        let reported = accepted.clone();
        let (completion_tx, completion_rx) = mpsc::sync_channel(1);

        assert!(
            browser
                .resize_reporting_completion(
                    11,
                    5,
                    Box::new(move |reservation_id| {
                        assert!(reservation_id.is_some());
                        reported.store(true, Ordering::Release);
                    }),
                    Some(completion_tx),
                )
                .unwrap()
                .is_some()
        );
        assert!(!accepted.load(Ordering::Acquire));
        assert!(matches!(
            completion_rx.recv_timeout(Duration::from_millis(10)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        let pending =
            browser.pending_resize_completion(11, 5).unwrap().expect("pending resize completion");
        assert!(pending.reservation > 0);
        assert!(matches!(
            pending.completion.recv_timeout(Duration::from_millis(10)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        for _ in 1..MAX_RECONFIGURE_WAITERS_PER_RESERVATION {
            drop(browser.pending_resize_completion(11, 5).unwrap().unwrap());
        }
        let error = browser.pending_resize_completion(11, 5).err().expect("waiter cap error");
        assert!(error.to_string().contains("too many waiters"));
        let (duplicate_tx, duplicate_rx) = mpsc::channel();
        assert!(
            browser
                .resize_reporting_acceptance(
                    11,
                    5,
                    Box::new(move |accepted| duplicate_tx.send(accepted).unwrap()),
                )
                .unwrap()
                .is_none()
        );
        assert!(duplicate_rx.recv_timeout(Duration::from_secs(1)).unwrap().is_none());

        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while !accepted.load(Ordering::Acquire) && Instant::now() < deadline {
            thread::yield_now();
        }
        assert!(accepted.load(Ordering::Acquire));
        assert!(completion_rx.recv_timeout(Duration::from_secs(1)).unwrap().is_ok());
        assert!(pending.completion.recv_timeout(Duration::from_secs(1)).unwrap().is_ok());
        browser.kill();
        done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after release");
    }

    #[test]
    fn pending_browser_resize_suppresses_duplicates_until_reconfigure_completes() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new())
                .unwrap();
        let browser = surface.as_browser().expect("browser surface");
        *browser.cell_pixels.lock().unwrap() = (9, 16);

        let queued = browser.reserve_reconfigure(10, 5).expect("changed geometry");
        assert!(!browser.resize_needed(10, 5));
        assert!(browser.reserve_reconfigure(10, 5).is_none());

        browser.reconfigure_reserved_blocking(queued).unwrap();
        assert!(!browser.resize_needed(10, 5));
        assert!(browser.reserve_reconfigure(10, 5).is_none());
    }

    #[test]
    fn rejected_resize_releases_joined_completion_waiters() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        let pending =
            browser.pending_resize_completion(11, 5).unwrap().expect("pending completion");

        browser.release_reconfigure(queued);

        let error = pending
            .completion
            .recv_timeout(Duration::from_secs(1))
            .unwrap()
            .expect_err("rejected resize completion");
        assert!(error.contains("rejected before execution"));
        assert!(browser.state.lock().unwrap().reconfigure_waiters.is_empty());
    }

    #[test]
    fn browser_resize_failure_retries_are_bounded_and_new_sizes_cancel_the_latch() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");

        for attempt in 1..=3 {
            let queued =
                browser.reserve_reconfigure(11, 5).expect("resize must enter pending state");
            let (recorded_attempt, retry_delay) =
                browser.fail_reconfigure(queued).expect("pending resize failure must be recorded");
            assert_eq!(recorded_attempt, attempt);
            assert_eq!(retry_delay.is_some(), attempt < 3);
            assert!(!browser.resize_needed(11, 5));
            if attempt < 3 {
                browser.state.lock().unwrap().reconfigure_failure.as_mut().unwrap().retry_at =
                    Some(Instant::now() - Duration::from_millis(1));
                assert!(browser.resize_needed(11, 5));
            }
        }

        assert!(!browser.resize_needed(11, 5));
        assert!(browser.resize_needed(12, 5));
        assert!(browser.resize_needed(11, 5));
    }

    #[test]
    fn exhausted_reconfigure_recovery_exposes_a_retryable_terminal_failure() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));

        for attempt in 1..=3 {
            let queued =
                browser.reserve_reconfigure(11, 5).expect("resize must enter pending state");
            browser.begin_reconfigure_frame_transition();
            let (_, retry_delay) =
                browser.fail_reconfigure(queued).expect("resize failure must be recorded");
            if attempt < 3 {
                assert!(retry_delay.is_some());
                browser.state.lock().unwrap().reconfigure_failure.as_mut().unwrap().retry_at =
                    Some(Instant::now() - Duration::from_millis(1));
            }
        }

        assert!(
            matches!(
                browser.status(),
                BrowserStatus::Failed(ref error) if error.contains("reload to retry")
            ),
            "exhausted resize recovery must expose a bounded recovery action"
        );
        assert_eq!(
            browser.state.lock().unwrap().pending_frame_epoch,
            None,
            "terminal resize failure must settle its frame reservation"
        );
        assert!(
            browser.begin_navigation_frame_transition().is_ok(),
            "reload must be able to start after terminal resize failure"
        );
        browser.clear_error();
        assert!(
            browser.resize_needed(11, 5),
            "successful reload dispatch must rearm the failed geometry"
        );
    }

    #[test]
    fn reconfigure_retry_reuses_unsettled_frame_epoch() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
        browser.begin_reconfigure_frame_transition();
        let first_epoch = browser.state.lock().unwrap().pending_frame_epoch.unwrap();
        browser.fail_reconfigure(queued).expect("first failure recorded");
        browser.state.lock().unwrap().reconfigure_failure.as_mut().unwrap().retry_at =
            Some(Instant::now() - Duration::from_millis(1));
        let retry = browser.reserve_reconfigure(11, 5).expect("retry accepted");

        browser.begin_reconfigure_frame_transition();

        assert_eq!(
            browser.state.lock().unwrap().pending_frame_epoch,
            Some(first_epoch),
            "a retry must wait for the same single response barrier"
        );
        browser.fail_reconfigure(retry).expect("retry failure recorded");
    }

    #[test]
    fn attach_frames_are_latest_wins_and_close_detaches() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let (_state, stream) = browser.attach_frames();

        browser.store_frame(test_frame(1));
        browser.store_frame(test_frame(2));
        browser.store_frame(test_frame(3));

        stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
        let frame = stream.slot.lock().unwrap().frame.take().expect("latest frame");
        assert_eq!(frame.frame.seq, 3);
        assert!(stream.notify.try_recv().is_err());

        browser.store_frame(test_frame(4));
        stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
        let frame = stream.slot.lock().unwrap().frame.take().expect("next latest frame");
        assert_eq!(frame.frame.seq, 4);

        browser.kill();
        assert!(stream.notify.recv_timeout(Duration::from_secs(1)).is_err());
    }

    #[test]
    fn pending_attach_frame_inherits_newer_authority_state() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let (_state, stream) = browser.attach_frames();
        browser.store_frame(test_frame(1));
        {
            let mut state = browser.state.lock().unwrap();
            state.status = BrowserStatus::Failed("navigation failed".to_string());
            state.pointer_frame_seq = None;
            browser.mark_state_dirty_locked(&mut state);
        }

        stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
        let update = std::mem::take(&mut *stream.slot.lock().unwrap());
        let frame = update.frame.expect("pending frame");
        assert_eq!(frame.status, BrowserStatus::Failed("navigation failed".to_string()));
        assert_eq!(frame.pointer_frame_seq, None);
    }

    #[test]
    fn pending_attach_state_inherits_newer_frame_authority() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let (_state, stream) = browser.attach_frames();

        assert!(browser.set_title("queued state".to_string()));
        browser.store_frame(test_frame(2));

        stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
        let update = std::mem::take(&mut *stream.slot.lock().unwrap());
        let state = update.state.expect("pending state");
        let frame = update.frame.expect("newer pending frame");
        assert_eq!(
            state.pointer_frame_seq, frame.pointer_frame_seq,
            "a state queued before a newer frame must inherit that frame's pointer authority"
        );
        assert_eq!(frame.frame.seq, 2);
    }

    #[test]
    fn pointer_admission_barriers_order_pending_attach_frames() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));
        let (_snapshot, stream) = browser.attach_frames();

        browser.store_frame(test_frame(2));
        let invalidation = browser.invalidate_pointer_frame();
        stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
        let invalidated = std::mem::take(&mut *stream.slot.lock().unwrap());
        assert!(invalidated.state.is_some(), "invalidation state must supersede the pending frame");
        assert!(
            invalidated.frame.is_none(),
            "a pre-invalidation frame must not be delivered after the barrier"
        );

        browser.restore_pointer_frame_after_failed_command(invalidation);
        stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
        let restored = std::mem::take(&mut *stream.slot.lock().unwrap());
        assert!(restored.state.is_some(), "rollback state must restore pointer admission");
        assert_eq!(
            restored.frame.map(|frame| frame.frame.seq),
            Some(2),
            "rollback must resend the retained frame after discarding it at the barrier"
        );
    }

    #[test]
    fn launched_surfaces_never_report_frame_stalls() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let now = Instant::now();
        {
            let mut state = browser.state.lock().unwrap();
            state.status = BrowserStatus::Live;
            state.source = Some(BrowserSource::Launched);
            state.live_since = Some(now - Duration::from_secs(3));
            state.last_frame_at = None;
        }
        assert!(!browser.frames_stalled_at(now));

        {
            let mut state = browser.state.lock().unwrap();
            state.source = Some(BrowserSource::External);
        }
        assert!(browser.frames_stalled_at(now));
    }

    #[test]
    fn worker_double_timeout_marks_browser_not_responding_without_waiting() {
        let surface = test_surface();
        let mut failures = super::BrowserWorkerErrorState::default();

        super::record_browser_worker_result(
            &surface,
            &Weak::new(),
            surface.id,
            true,
            Err(anyhow::anyhow!("CDP call Input.dispatchMouseEvent timed out")),
            &mut failures,
        );
        assert_ne!(
            surface.as_browser().unwrap().status(),
            BrowserStatus::Failed(super::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
        );

        super::record_browser_worker_result(
            &surface,
            &Weak::new(),
            surface.id,
            true,
            Err(anyhow::anyhow!("CDP call Input.dispatchMouseEvent timed out")),
            &mut failures,
        );
        assert_eq!(
            surface.as_browser().unwrap().status(),
            BrowserStatus::Failed(super::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
        );
    }

    #[test]
    fn normalizes_browser_urls() {
        assert_eq!(normalize_url("example.com"), "https://example.com");
        assert_eq!(normalize_url("example.com:8080"), "https://example.com:8080");
        assert_eq!(normalize_url(" https://example.com "), "https://example.com");
        assert_eq!(normalize_url("https://example.com/a"), "https://example.com/a");
        assert_eq!(normalize_url("about:blank"), "about:blank");
        assert_eq!(normalize_url("file:///tmp/test.html"), "file:///tmp/test.html");
        assert_eq!(normalize_url("mailto:test@example.com"), "mailto:test@example.com");
        assert_eq!(normalize_url("localhost:3000/path"), "http://localhost:3000/path");
        assert_eq!(normalize_url("127.0.0.1/test"), "http://127.0.0.1/test");
        assert_eq!(normalize_url("[::1]:8080"), "http://[::1]:8080");
        assert_eq!(normalize_url("myhost:8080"), "https://www.google.com/search?q=myhost%3A8080");
        assert_eq!(normalize_url("plainwords"), "https://www.google.com/search?q=plainwords");
        assert_eq!(normalize_url("two words?"), "https://www.google.com/search?q=two%20words%3F");
    }

    #[test]
    fn normalization_is_idempotent() {
        for input in ["localhost:3000", "example.com", "two words?", "mailto:x@y.z"] {
            let once = normalize_url(input);
            assert_eq!(normalize_url(&once), once, "not idempotent for {input:?}");
        }
    }
}
