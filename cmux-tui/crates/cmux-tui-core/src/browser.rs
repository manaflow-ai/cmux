use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use cmux_tui_cdp::{
    CDP_EVENT_QUEUE_CAPACITY, CdpClient, CdpEvent, CdpKeyEvent, Chrome, ChromeLaunchOptions,
    TargetCreated, discover_browser_ws_url, resolve_browser_ws_url,
};

use crate::platform;
use crate::surface::{Surface, SurfaceMeta, SurfaceOptions};
use crate::{Mux, MuxEvent, SurfaceId};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowserSource {
    External,
    Launched,
}

impl BrowserSource {
    pub fn as_str(self) -> &'static str {
        match self {
            BrowserSource::External => "external",
            BrowserSource::Launched => "launched",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserFrame {
    pub session_id: String,
    pub data_b64: String,
    pub css_width: u32,
    pub css_height: u32,
    pub seq: u64,
}

pub struct BrowserFrameStream {
    pub slot: Arc<Mutex<BrowserAttachUpdate>>,
    pub notify: Receiver<()>,
}

pub(crate) type BrowserResizeOutcome = Result<(), Arc<str>>;
pub(crate) type BrowserResizeWaiter = SyncSender<BrowserResizeOutcome>;

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
    pub frame: Option<BrowserFrame>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrowserStatus {
    Starting,
    Live,
    Failed(String),
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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserAttachState {
    pub url: String,
    pub title: String,
    pub cols: u16,
    pub rows: u16,
    pub status: BrowserStatus,
    pub frame: Option<BrowserFrame>,
    pub frames_stalled: bool,
}

#[derive(Clone)]
struct BrowserSession {
    runtime: Arc<BrowserRuntime>,
    target_id: String,
    session_id: String,
}

struct BrowserState {
    latest_frame: Option<BrowserFrame>,
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

enum BrowserCommand {
    WakeLatest,
    Mouse {
        event_type: String,
        x: f64,
        y: f64,
        button: Option<String>,
        click_count: Option<u32>,
    },
    Wheel {
        x: f64,
        y: f64,
        delta_y: f64,
    },
    Key {
        event_type: String,
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

impl BrowserCommand {
    fn is_input(&self) -> bool {
        matches!(
            self,
            BrowserCommand::Mouse { .. }
                | BrowserCommand::Wheel { .. }
                | BrowserCommand::Key { .. }
                | BrowserCommand::InsertText(_)
        )
    }

    fn is_mouse_move(&self) -> bool {
        matches!(self, BrowserCommand::Mouse { event_type, .. } if event_type == "mouseMoved")
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
}

pub struct BrowserRuntime {
    client: CdpClient,
    chrome: Option<Chrome>,
    source: BrowserSource,
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
    session: Mutex<Option<BrowserSession>>,
    state: Mutex<BrowserState>,
    dirty: AtomicBool,
    dead: AtomicBool,
    cell_pixels: Mutex<(u16, u16)>,
    capture_options: BrowserCaptureOptions,
    command_tx: Mutex<Option<SyncSender<BrowserCommand>>>,
    latest_nav: Arc<Mutex<Option<BrowserCommand>>>,
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
const MAX_RECONFIGURE_WAITERS_PER_RESERVATION: usize = 64;
const BROWSER_NOT_RESPONDING_MESSAGE: &str = "browser is not responding";
const BROWSER_RECONFIGURE_RETRY_DELAYS: [Duration; 2] =
    [Duration::from_millis(250), Duration::from_millis(500)];

impl BrowserRuntime {
    pub fn connect(opts: &SurfaceOptions) -> anyhow::Result<Arc<Self>> {
        let (web_socket_url, chrome, source) = runtime_endpoint(opts)?;
        Self::connect_to_endpoint(&web_socket_url, chrome, source)
    }

    fn connect_to_endpoint(
        web_socket_url: &str,
        chrome: Option<Chrome>,
        source: BrowserSource,
    ) -> anyhow::Result<Arc<Self>> {
        let (event_tx, event_rx) = sync_channel(CDP_EVENT_QUEUE_CAPACITY);
        let client = CdpClient::connect(web_socket_url, event_tx)?;
        let stealth_user_agent = if source == BrowserSource::Launched {
            client.browser_version().ok().and_then(|ua| clean_headless_user_agent(&ua))
        } else {
            None
        };
        let runtime = Arc::new(BrowserRuntime {
            client,
            chrome,
            source,
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
            BrowserBootstrap::Create { url } => {
                let normalized_url = normalize_url(&url);
                let target_id = self.client.create_target(&normalized_url)?;
                (target_id, normalized_url)
            }
            BrowserBootstrap::ExistingTarget { target_id, url } => (target_id, normalize_url(&url)),
        };
        let session_id = self.client.attach_to_target(&target_id)?;
        let events = self.register(&target_id, &session_id);

        let setup_result =
            self.setup_attached_surface(&surface, &target_id, &session_id, &normalized_url);
        if let Err(err) = setup_result {
            self.unregister(&target_id, &session_id);
            let _ = self.client.close_target(&target_id);
            return Err(err);
        }

        start_surface_thread(surface, events, mux, Arc::downgrade(self))?;
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
        if let Some(user_agent) = self.stealth_user_agent.as_deref() {
            let _ = self.client.set_user_agent(session_id, user_agent);
        }
        self.client.page_enable(session_id)?;
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
            route.close("browser runtime closed".to_string());
            return route;
        }
        routes.by_session.insert(session_id.to_string(), route.clone());
        routes.by_target.insert(target_id.to_string(), route.clone());
        route
    }

    fn unregister(&self, target_id: &str, session_id: &str) {
        let route = {
            let mut routes = self.routes.lock().unwrap();
            let by_session = routes.by_session.remove(session_id);
            let by_target = routes.by_target.remove(target_id);
            by_session.or(by_target)
        };
        if let Some(route) = route {
            route.close("browser surface closed".to_string());
        }
    }

    fn remove_route(&self, route: &Arc<SurfaceRoute>) {
        let mut routes = self.routes.lock().unwrap();
        routes.by_session.retain(|_, candidate| !Arc::ptr_eq(candidate, route));
        routes.by_target.retain(|_, candidate| !Arc::ptr_eq(candidate, route));
    }

    fn close_surface_detached(&self, target_id: &str, session_id: &str) {
        self.unregister(target_id, session_id);
        if !self.is_closed() {
            let _ = self.client.close_target_detached(target_id);
        }
    }

    pub fn shutdown(&self) {
        close_browser_runtime(self, "browser runtime shut down".to_string());
        let _ = self.client.flush_outbound(Duration::from_secs(1));
        if let Some(chrome) = &self.chrome {
            chrome.kill();
        }
    }
}

pub(crate) enum BrowserBootstrap {
    Create { url: String },
    ExistingTarget { target_id: String, url: String },
}

pub(crate) fn new_surface(
    id: SurfaceId,
    url: String,
    size: (u16, u16),
    cell_pixels: (u16, u16),
    opts: &SurfaceOptions,
    mux: Weak<Mux>,
) -> Arc<Surface> {
    let normalized_url = normalize_url(&url);
    let (cols, rows) = (size.0.max(1), size.1.max(1));
    let (cell_w, cell_h) = (cell_pixels.0.max(1), cell_pixels.1.max(1));
    let pixel_w = cols as u32 * cell_w as u32;
    let pixel_h = rows as u32 * cell_h as u32;
    let capture_options = BrowserCaptureOptions::from_options(opts);
    let capture_scale = capture_scale_for(pixel_w, pixel_h, capture_options);
    let capture_pixels = scaled_pixels(pixel_w, pixel_h, capture_scale);
    let (command_tx, command_rx) = sync_channel(BROWSER_COMMAND_QUEUE_CAPACITY);
    let latest_nav = Arc::new(Mutex::new(None));
    #[cfg(test)]
    let (worker_done_tx, worker_done_rx) = std::sync::mpsc::channel();
    #[cfg(test)]
    let worker_done_tx = Some(worker_done_tx);
    #[cfg(not(test))]
    let worker_done_tx = None;
    let surface = Arc::new(Surface::Browser(BrowserSurface {
        meta: SurfaceMeta { id, name: Mutex::new(None), selection: Mutex::new(None) },
        session: Mutex::new(None),
        state: Mutex::new(BrowserState {
            latest_frame: None,
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
            source: None,
            next_frame_seq: 1,
            live_since: None,
            last_frame_at: None,
            stall_nudged: false,
            not_responding_reported: false,
        }),
        dirty: AtomicBool::new(true),
        dead: AtomicBool::new(false),
        cell_pixels: Mutex::new((cell_w, cell_h)),
        capture_options,
        command_tx: Mutex::new(Some(command_tx)),
        latest_nav: latest_nav.clone(),
        #[cfg(test)]
        worker_done: Mutex::new(Some(worker_done_rx)),
    }));
    start_browser_worker(surface.clone(), command_rx, latest_nav, mux, worker_done_tx);
    surface
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
    if opts.browser_discover {
        let ports = if opts.browser_discover_ports.is_empty() {
            &[9222][..]
        } else {
            opts.browser_discover_ports.as_slice()
        };
        if let Some(url) = discover_browser_ws_url(ports) {
            return Ok((url, None, BrowserSource::External));
        }
    }

    if std::env::var_os("CMUX_MUX_CDP_DEBUG").is_some() {
        eprintln!(
            "cdp: no external endpoint (discover={}); launching chrome",
            opts.browser_discover
        );
    }
    let chrome_binary = resolve_chrome_binary(opts.chrome_binary.as_deref())?;
    let user_data_dir = if opts.browser_ephemeral {
        None
    } else {
        Some(resolve_chrome_user_data_dir(
            opts.browser_user_data_dir.as_deref(),
            &opts.browser_session_name,
        )?)
    };
    let chrome = Chrome::launch_with(&ChromeLaunchOptions {
        binary: chrome_binary,
        mode: opts.browser_mode,
        user_data_dir,
        ephemeral: opts.browser_ephemeral,
    })?;
    let web_socket_url = chrome.web_socket_url().to_string();
    Ok((web_socket_url, Some(chrome), BrowserSource::Launched))
}

fn clean_headless_user_agent(user_agent: &str) -> Option<String> {
    user_agent.contains("HeadlessChrome").then(|| user_agent.replace("HeadlessChrome", "Chrome"))
}

fn resolve_chrome_binary(explicit: Option<&str>) -> anyhow::Result<PathBuf> {
    if let Some(path) = explicit.filter(|s| !s.trim().is_empty()) {
        let path = PathBuf::from(path);
        if platform::is_executable_file(&path) {
            return Ok(path);
        }
        anyhow::bail!(
            "configured browser.chrome_binary does not point to an executable file: {}",
            path.display()
        );
    }

    for path in platform::chrome_candidates() {
        if platform::is_executable_file(&path) {
            return Ok(path);
        }
    }

    let config_hint = platform::config_path()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| "cmux-tui.json".to_string());
    anyhow::bail!("no Chrome/Chromium binary found; set browser.chrome_binary in {config_hint}")
}

fn resolve_chrome_user_data_dir(
    explicit: Option<&str>,
    session_name: &str,
) -> anyhow::Result<PathBuf> {
    if let Some(path) = explicit.filter(|s| !s.trim().is_empty()) {
        return Ok(PathBuf::from(path));
    }
    let base = platform::chrome_user_data_dir().ok_or_else(|| {
        anyhow::anyhow!(
            "cannot determine Chrome profile directory; set HOME or browser.user_data_dir"
        )
    })?;
    Ok(base.join(sanitize_session_name(session_name)))
}

fn sanitize_session_name(name: &str) -> String {
    let mut out = String::new();
    for ch in name.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_') {
            out.push(ch);
        } else {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() { "default".to_string() } else { trimmed.to_string() }
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
            close_browser_runtime(&runtime, "CDP event channel closed".to_string());
        }
    })?;
    Ok(())
}

fn close_browser_runtime(runtime: &BrowserRuntime, reason: String) {
    let senders = {
        let mut routes = runtime.routes.lock().unwrap();
        runtime.closed.store(true, Ordering::Release);
        let senders = routes.by_session.values().cloned().collect::<Vec<_>>();
        routes.by_session.clear();
        routes.by_target.clear();
        senders
    };
    for tx in senders {
        tx.close(reason.clone());
    }
}

fn start_surface_thread(
    surface: Arc<Surface>,
    events: Arc<SurfaceRoute>,
    mux: Weak<Mux>,
    runtime: Weak<BrowserRuntime>,
) -> anyhow::Result<()> {
    let id = surface.id;
    std::thread::Builder::new().name(format!("browser-surface-{id}-events")).spawn(move || {
        while let Some(event) = events.recv() {
            let Surface::Browser(browser) = surface.as_ref() else { break };
            match event {
                CdpEvent::ScreencastFrame(frame) => {
                    let frame = BrowserFrame {
                        session_id: frame.session_id,
                        data_b64: frame.data_b64,
                        css_width: frame.css_width,
                        css_height: frame.css_height,
                        seq: 0,
                    };
                    browser.store_frame(frame);
                    if !browser.dirty.swap(true, Ordering::AcqRel)
                        && let Some(mux) = mux.upgrade()
                    {
                        mux.emit(MuxEvent::SurfaceOutput(id));
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
                CdpEvent::Other { method, params, .. } if method == "Page.frameNavigated" => {
                    handle_frame_navigated(browser, params);
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
                CdpEvent::Closed(_) => {
                    browser.kill();
                    if let Some(mux) = mux.upgrade() {
                        mux.surface_exited(id);
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
    rx: Receiver<BrowserCommand>,
    latest_nav: Arc<Mutex<Option<BrowserCommand>>>,
    mux: Weak<Mux>,
    done_tx: Option<Sender<()>>,
) {
    let id = surface.id;
    let _ =
        std::thread::Builder::new().name(format!("browser-surface-{id}-worker")).spawn(move || {
            let mut failures = BrowserWorkerErrorState::default();
            while let Ok(first) = rx.recv() {
                let mut batch = vec![first];
                while let Ok(next) = rx.try_recv() {
                    batch.push(next);
                }
                coalesce_worker_mouse_moves(&mut batch);
                for command in batch {
                    if matches!(command, BrowserCommand::WakeLatest) {
                        if let Some(command) = take_latest_worker_commands(&latest_nav) {
                            run_browser_worker_command(&surface, command, &mux, id, &mut failures);
                        }
                    } else {
                        run_browser_worker_command(&surface, command, &mux, id, &mut failures);
                    }
                }
                if let Some(command) = take_latest_worker_commands(&latest_nav) {
                    run_browser_worker_command(&surface, command, &mux, id, &mut failures);
                }
            }
            if let Some(done_tx) = done_tx {
                let _ = done_tx.send(());
            }
        });
}

fn take_latest_worker_commands(
    latest_nav: &Arc<Mutex<Option<BrowserCommand>>>,
) -> Option<BrowserCommand> {
    latest_nav.lock().unwrap().take()
}

fn coalesce_worker_mouse_moves(batch: &mut Vec<BrowserCommand>) {
    let mut index = 0;
    while index + 1 < batch.len() {
        if batch[index].is_mouse_move() && batch[index + 1].is_mouse_move() {
            batch.remove(index);
        } else {
            index += 1;
        }
    }
}

fn run_browser_worker_command(
    surface: &Surface,
    mut command: BrowserCommand,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
) {
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
    let result = {
        let Some(browser) = surface.as_browser() else {
            return;
        };
        match command {
            BrowserCommand::WakeLatest => Ok(()),
            BrowserCommand::Mouse { event_type, x, y, button, click_count } => {
                browser.mouse_event_blocking(&event_type, x, y, button.as_deref(), click_count)
            }
            BrowserCommand::Wheel { x, y, delta_y } => browser.wheel_blocking(x, y, delta_y),
            BrowserCommand::Key {
                event_type,
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text,
            } => browser.key_event_blocking(
                &event_type,
                &key,
                &code,
                windows_virtual_key_code,
                modifiers,
                text.as_deref(),
            ),
            BrowserCommand::InsertText(text) => browser.insert_text_blocking(&text),
            BrowserCommand::Navigate(url) => browser.navigate_blocking(&url),
            BrowserCommand::Back => browser.back_blocking(),
            BrowserCommand::Forward => browser.forward_blocking(),
            BrowserCommand::Reload => browser.reload_blocking(),
            BrowserCommand::Activate => browser.activate_blocking(),
            BrowserCommand::Reconfigure { queued, .. } => {
                browser.reconfigure_reserved_blocking(queued)
            }
            #[cfg(test)]
            BrowserCommand::Hold { entered, release } => {
                let _ = entered.send(());
                release.recv().map_err(anyhow::Error::msg)
            }
        }
    };
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
    result: anyhow::Result<()>,
    failures: &mut BrowserWorkerErrorState,
) {
    match result {
        Ok(()) => {
            failures.consecutive_timeouts = 0;
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
                            browser.mark_failed(BROWSER_NOT_RESPONDING_MESSAGE.to_string());
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
    pub fn latest_frame(&self) -> Option<BrowserFrame> {
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            None
        } else {
            state.latest_frame.clone()
        }
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

    fn reconfigure_reserved_blocking(&self, queued: QueuedBrowserGeometry) -> anyhow::Result<()> {
        self.reconfigure_blocking(
            queued.geometry.capture_pixels.0,
            queued.geometry.capture_pixels.1,
        )?;
        self.confirm_reconfigure(queued);
        Ok(())
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
        self.set_cell_pixel_size_reporting(width_px, height_px, Box::new(|_| {}))
            .map(|reservation_id| reservation_id.is_some())
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

    fn confirm_reconfigure(&self, queued: QueuedBrowserGeometry) {
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
            state.page_viewport = None;
            state.live_since = Some(Instant::now());
            state.last_frame_at = None;
            state.stall_nudged = false;
        }
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

    fn reconfigure_blocking(&self, width: u32, height: u32) -> anyhow::Result<()> {
        let Some(session) = self.live_session()? else { return Ok(()) };
        session.runtime.client.set_device_metrics(&session.session_id, width, height)?;
        let _ = session.runtime.client.stop_screencast(&session.session_id);
        session.runtime.client.start_screencast(&session.session_id, width, height)?;
        Ok(())
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
        let snapshot = browser_attach_state_locked(&state, Instant::now(), self.is_dead(), true);
        if !self.is_dead() {
            state.taps.push(BrowserFrameTap { slot: slot.clone(), notify: tx });
        }
        (snapshot, BrowserFrameStream { slot, notify: rx })
    }

    fn store_frame(&self, mut frame: BrowserFrame) {
        let mut state = self.state.lock().unwrap();
        // Screencast frames keep streaming the previous page after a
        // failed navigation; they must not mask that failure. A fresh
        // frame does prove Chrome recovered from the worker's
        // not-responding state, so clear only that class here.
        let clears_not_responding = matches!(
            state.status,
            BrowserStatus::Failed(ref error) if error == BROWSER_NOT_RESPONDING_MESSAGE
        );
        if !matches!(state.status, BrowserStatus::Failed(_)) || clears_not_responding {
            state.status = BrowserStatus::Live;
            if clears_not_responding {
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
                Self::mark_state_dirty_locked(&mut state);
            }
        }
        frame.seq = state.next_frame_seq;
        state.next_frame_seq = state.next_frame_seq.saturating_add(1);
        state.last_frame_at = Some(Instant::now());
        state.stall_nudged = false;
        state.page_viewport = Some((frame.css_width.max(1), frame.css_height.max(1)));
        state.latest_frame = Some(frame.clone());
        state.taps.retain(|tap| {
            tap.slot.lock().unwrap().frame = Some(frame.clone());
            match tap.notify.try_send(()) {
                Ok(()) | Err(TrySendError::Full(())) => true,
                Err(TrySendError::Disconnected(())) => false,
            }
        });
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
        }
        let now = Instant::now();
        state.live_since = Some(now);
        state.last_frame_at = None;
        state.stall_nudged = false;
        Self::mark_state_dirty_locked(&mut state);
        Ok(())
    }

    pub fn mark_failed(&self, message: String) {
        let mut state = self.state.lock().unwrap();
        state.status = BrowserStatus::Failed(message.clone());
        state.title = format!("browser failed: {message}");
        state.stall_nudged = false;
        Self::mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }

    fn clear_error(&self) {
        let mut state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            state.status = BrowserStatus::Live;
            Self::mark_state_dirty_locked(&mut state);
        }
    }

    fn set_title(&self, title: String) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.title == title {
            return false;
        }
        state.title = title;
        Self::mark_state_dirty_locked(&mut state);
        true
    }

    fn set_url(&self, url: String) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.url != url {
            state.url = url;
            Self::mark_state_dirty_locked(&mut state);
            return true;
        }
        false
    }

    fn set_url_title(&self, url: String, title: String) {
        let mut state = self.state.lock().unwrap();
        state.url = url;
        state.title = title;
        state.status = BrowserStatus::Live;
        state.stall_nudged = false;
        Self::mark_state_dirty_locked(&mut state);
    }

    fn mark_state_dirty_locked(state: &mut BrowserState) {
        let snapshot = browser_attach_state_locked(state, Instant::now(), false, false);
        state.taps.retain(|tap| {
            tap.slot.lock().unwrap().state = Some(snapshot.clone());
            match tap.notify.try_send(()) {
                Ok(()) | Err(TrySendError::Full(())) => true,
                Err(TrySendError::Disconnected(())) => false,
            }
        });
    }

    fn live_session(&self) -> anyhow::Result<Option<BrowserSession>> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        if let Some(session) = self.session.lock().unwrap().clone() {
            return Ok(Some(session));
        }
        match self.status() {
            BrowserStatus::Starting => Ok(None),
            BrowserStatus::Live => Ok(None),
            BrowserStatus::Failed(error) => anyhow::bail!("browser failed: {error}"),
        }
    }

    fn require_live_session(&self) -> anyhow::Result<BrowserSession> {
        self.live_session()?.ok_or_else(|| anyhow::anyhow!("browser is still starting"))
    }

    fn frames_stalled_at(&self, now: Instant) -> bool {
        let state = self.state.lock().unwrap();
        frames_stalled_locked(&state, now, self.is_dead())
    }

    fn scale_input_point(&self, x: f64, y: f64) -> (f64, f64) {
        let state = self.state.lock().unwrap();
        let (pane_width, pane_height) = state.pane_pixels;
        let (page_width, page_height) = state.page_viewport.unwrap_or(state.capture_pixels);
        let page_width = page_width.max(1);
        let page_height = page_height.max(1);
        let x = x / f64::from(pane_width.max(1)) * f64::from(page_width);
        let y = y / f64::from(pane_height.max(1)) * f64::from(page_height);
        (x.clamp(0.0, f64::from(page_width)), y.clamp(0.0, f64::from(page_height)))
    }

    fn scale_delta(&self, delta: f64) -> f64 {
        let state = self.state.lock().unwrap();
        if let Some((_, page_height)) = state.page_viewport {
            delta * f64::from(page_height.max(1)) / f64::from(state.pane_pixels.1.max(1))
        } else {
            delta * state.capture_scale
        }
    }

    fn maybe_nudge_stalled_external(&self, session: &BrowserSession) {
        if session.runtime.source() != BrowserSource::External {
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
        match tx.try_send(command) {
            Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
            Err(TrySendError::Disconnected(_)) => anyhow::bail!("browser command worker is closed"),
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
        match tx.try_send(command) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => {
                anyhow::bail!("browser command queue is full; browser may be unresponsive")
            }
            Err(TrySendError::Disconnected(_)) => anyhow::bail!("browser command worker is closed"),
        }
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
        match tx.try_send(command) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(command)) => {
                if let Some(queued) = reject_reconfigure(command) {
                    self.release_reconfigure(queued);
                }
                anyhow::bail!("browser command queue is full; browser may be unresponsive")
            }
            Err(TrySendError::Disconnected(command)) => {
                if let Some(queued) = reject_reconfigure(command) {
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
        *self.latest_nav.lock().unwrap() = Some(command);
        self.wake_worker()
    }

    fn wake_worker(&self) -> anyhow::Result<()> {
        let tx = self.command_sender()?;
        match tx.try_send(BrowserCommand::WakeLatest) {
            Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
            Err(TrySendError::Disconnected(_)) => anyhow::bail!("browser command worker is closed"),
        }
    }

    fn command_sender(&self) -> anyhow::Result<SyncSender<BrowserCommand>> {
        self.command_tx
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| anyhow::anyhow!("browser command worker is closed"))
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
        self.enqueue_bounded(BrowserCommand::Mouse {
            event_type: event_type.to_string(),
            x,
            y,
            button: button.map(ToOwned::to_owned),
            click_count,
        })
    }

    fn mouse_event_blocking(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        if event_type == "mousePressed" {
            self.maybe_nudge_stalled_external(&session);
        }
        let (x, y) = self.scale_input_point(x, y);
        session.runtime.client.dispatch_mouse_event(
            &session.session_id,
            event_type,
            x,
            y,
            button,
            click_count,
        )
    }

    pub fn wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        self.enqueue_bounded(BrowserCommand::Wheel { x, y, delta_y })
    }

    fn wheel_blocking(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        let (x, y) = self.scale_input_point(x, y);
        let delta_y = self.scale_delta(delta_y);
        session.runtime.client.dispatch_wheel(&session.session_id, x, y, delta_y)
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

    pub fn insert_text(&self, text: &str) -> anyhow::Result<()> {
        self.enqueue_bounded(BrowserCommand::InsertText(text.to_string()))
    }

    fn insert_text_blocking(&self, text: &str) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        session.runtime.client.insert_text(&session.session_id, text)
    }

    pub fn navigate(&self, url: &str) -> anyhow::Result<()> {
        self.enqueue_latest_nav(BrowserCommand::Navigate(url.to_string()))
    }

    fn navigate_blocking(&self, url: &str) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        let normalized = normalize_url(url);
        if let Some(error) = session.runtime.client.navigate(&session.session_id, &normalized)? {
            self.mark_failed(error.clone());
            anyhow::bail!("browser failed: {error}");
        }
        self.set_url_title(normalized.clone(), normalized);
        self.dirty.store(true, Ordering::Release);
        Ok(())
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

    fn navigate_history_blocking(&self, delta: isize) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        let history = session.runtime.client.navigation_history(&session.session_id)?;
        let next = history.current_index as isize + delta;
        if next < 0 || next as usize >= history.entries.len() {
            anyhow::bail!(
                "browser has no {} history entry",
                if delta < 0 { "back" } else { "forward" }
            );
        }
        let entry = &history.entries[next as usize];
        session.runtime.client.navigate_to_history_entry(&session.session_id, entry.id)?;
        self.clear_error();
        Ok(())
    }

    pub fn reload(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Reload)
    }

    fn reload_blocking(&self) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        session.runtime.client.reload(&session.session_id)?;
        self.clear_error();
        Ok(())
    }

    pub fn activate(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Activate)
    }

    fn activate_blocking(&self) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        session.runtime.client.activate_target(&session.target_id, &session.session_id)
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
) -> BrowserAttachState {
    BrowserAttachState {
        url: state.url.clone(),
        title: state.title.clone(),
        cols: state.size.0,
        rows: state.size.1,
        status: state.status.clone(),
        frame: include_frame.then(|| state.latest_frame.clone()).flatten(),
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

fn handle_frame_navigated(browser: &BrowserSurface, params: serde_json::Value) {
    let Some(frame) = params.get("frame") else {
        return;
    };
    if frame.get("parentId").is_some() {
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
    browser.clear_error();
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
    if created.opener_id.as_deref() != Some(session.target_id.as_str()) {
        return;
    }
    let Some(mux) = mux.upgrade() else {
        let _ = session.runtime.client.close_target(&created.target_id);
        return;
    };
    if !mux.adopt_browser_target(
        opener_surface,
        created.target_id.clone(),
        if created.url.is_empty() { "about:blank".to_string() } else { created.url.clone() },
        session.runtime.clone(),
    ) {
        let _ = session.runtime.client.close_target(&created.target_id);
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
        BROWSER_COMMAND_QUEUE_CAPACITY, BrowserCaptureOptions, BrowserCommand, BrowserFrame,
        BrowserSession, BrowserSource, BrowserStatus, MAX_RECONFIGURE_WAITERS_PER_RESERVATION,
        capture_scale_for, new_surface, normalize_url, runtime_endpoint, scaled_pixels,
        start_surface_thread, take_latest_worker_commands,
    };
    use crate::{Mux, MuxEvent, Surface, SurfaceOptions};
    use serde_json::{Value, json};
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex, Weak, mpsc};
    use std::thread;
    use std::time::{Duration, Instant};
    use tungstenite::{Message, accept};

    fn test_frame(seq: u64) -> BrowserFrame {
        BrowserFrame {
            session_id: "session-test".to_string(),
            data_b64: "AAAA".to_string(),
            css_width: 80,
            css_height: 48,
            seq,
        }
    }

    fn serve_json_version_until_stopped(
        listener: TcpListener,
        ready_tx: mpsc::Sender<()>,
        stop_rx: mpsc::Receiver<()>,
    ) {
        listener.set_nonblocking(true).unwrap();
        ready_tx.send(()).unwrap();
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    // Accepted sockets inherit the listener's O_NONBLOCK on
                    // macOS; reads must block until the request arrives.
                    stream.set_nonblocking(false).unwrap();
                    serve_json_version(&mut stream);
                }
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    match stop_rx.recv_timeout(Duration::from_millis(10)) {
                        Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                    }
                }
                Err(err) => panic!("failed to accept fake browser discovery connection: {err}"),
            }
        }
    }

    fn serve_json_version(stream: &mut TcpStream) {
        stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut request = Vec::new();
        let mut buf = [0u8; 512];
        while !request.windows(4).any(|window| window == b"\r\n\r\n") {
            match stream.read(&mut buf) {
                Ok(0) => return,
                Ok(n) => request.extend_from_slice(&buf[..n]),
                Err(err)
                    if matches!(
                        err.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return;
                }
                Err(err) => panic!("failed to read fake browser discovery request: {err}"),
            }
        }
        let body = r#"{"webSocketDebuggerUrl":"ws://127.0.0.1:9/devtools/browser/fake"}"#;
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let _ = stream.write_all(response.as_bytes());
        let _ = stream.flush();
    }

    fn runtime_endpoint_until_discovered(
        opts: &SurfaceOptions,
        deadline: Duration,
    ) -> anyhow::Result<(String, Option<cmux_tui_cdp::Chrome>, BrowserSource)> {
        let start = Instant::now();
        let mut last_err = None;
        while start.elapsed() < deadline {
            match runtime_endpoint(opts) {
                Ok(endpoint) => return Ok(endpoint),
                Err(err) => last_err = Some(err),
            }
            thread::yield_now();
        }
        runtime_endpoint(opts).map_err(|err| last_err.unwrap_or(err))
    }

    fn test_surface() -> Arc<Surface> {
        let opts = SurfaceOptions::default();
        new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new())
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

        // Clearing the error restores the retained frame.
        browser.clear_error();
        assert_eq!(browser.status(), BrowserStatus::Live);
        assert_eq!(browser.latest_frame().map(|frame| frame.seq), Some(2));
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
                        "Page.enable"
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
            new_surface(11, "https://one.test".into(), (10, 5), (8, 16), &opts, Weak::new());
        runtime
            .setup_attached_surface(&first, "target-1", "session-1", "https://one.test")
            .unwrap();
        let second =
            new_surface(12, "https://two.test".into(), (10, 5), (8, 16), &opts, Weak::new());
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
                        "Page.enable"
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
        assert!(!route.deliver(cmux_tui_cdp::CdpEvent::Other {
            method: "Page.frameNavigated".to_string(),
            params: Value::Null,
            session_id: Some("session-1".to_string()),
        }));
        assert!(!route.deliver(target("new")));

        assert!(matches!(route.try_recv().unwrap(), cmux_tui_cdp::CdpEvent::Other { .. }));
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
                ack_id: index,
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
            ack_id: 1,
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
                ack_id: 1,
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
            cleanup_route.close("test cleanup".to_string());
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
        start_surface_thread(surface.clone(), route.clone(), Weak::new(), Arc::downgrade(&runtime))
            .unwrap();

        route.close("CDP surface event queue overflow".to_string());
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
                        "Page.enable"
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
    fn latest_navigation_slot_drains_once() {
        let latest_nav =
            Arc::new(Mutex::new(Some(BrowserCommand::Navigate("https://next.test".to_string()))));

        let command = take_latest_worker_commands(&latest_nav).expect("pending navigation");
        match &command {
            BrowserCommand::Navigate(url) => assert_eq!(url, "https://next.test"),
            _ => panic!("nav command was lost"),
        }
        assert!(latest_nav.lock().unwrap().is_none());
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
        );
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let events = mux.subscribe();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        browser
            .command_sender()
            .unwrap()
            .send(BrowserCommand::Hold { entered, release: held })
            .unwrap();
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
        browser.mark_failed(super::BROWSER_NOT_RESPONDING_MESSAGE.to_string());
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
    }

    #[test]
    fn browser_discovery_is_explicit_opt_in() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let (ready_tx, ready_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();
        let server =
            thread::spawn(move || serve_json_version_until_stopped(listener, ready_tx, stop_rx));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let opts = SurfaceOptions {
            chrome_binary: Some("/definitely/missing/cmux-test-chrome".to_string()),
            browser_discover_ports: vec![port],
            ..Default::default()
        };
        let explicit_opts = SurfaceOptions {
            cdp_url: Some("ws://127.0.0.1:9/devtools/browser/explicit".to_string()),
            ..opts.clone()
        };
        let (url, chrome, source) = runtime_endpoint(&explicit_opts).unwrap();
        assert_eq!(url, "ws://127.0.0.1:9/devtools/browser/explicit");
        assert!(chrome.is_none());
        assert_eq!(source, BrowserSource::External);

        let err = match runtime_endpoint(&opts) {
            Ok((url, _, source)) => {
                panic!("default config should launch, not discover; got {source:?} {url}")
            }
            Err(err) => err,
        };
        assert!(err.to_string().contains("configured browser.chrome_binary"));

        let discover_opts = SurfaceOptions { browser_discover: true, ..opts };
        let (url, chrome, source) =
            runtime_endpoint_until_discovered(&discover_opts, Duration::from_secs(2))
                .unwrap_or_else(|err| {
                    panic!("browser discovery did not find fake endpoint within 2s: {err:#}")
                });
        assert_eq!(url, "ws://127.0.0.1:9/devtools/browser/fake");
        assert!(chrome.is_none());
        assert_eq!(source, BrowserSource::External);
        stop_tx.send(()).unwrap();
        server.join().unwrap();
    }

    #[test]
    fn input_mapping_uses_latest_frame_viewport() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new());
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
            new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new());
        let browser = surface.as_browser().expect("browser surface");

        assert_eq!(browser.scale_input_point(2380.0, 1274.0), (966.5, 517.5));
        let expected_scale = browser.state.lock().unwrap().capture_scale;
        assert!((browser.scale_delta(100.0) - 100.0 * expected_scale).abs() < f64::EPSILON);
    }

    #[test]
    fn input_mapping_uses_new_capture_geometry_while_waiting_for_resized_frame() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new());
        let browser = surface.as_browser().expect("browser surface");

        let mut frame = test_frame(1);
        frame.css_width = 2320;
        frame.css_height = 1363;
        browser.store_frame(frame);

        let queued = browser.reserve_reconfigure(400, 100).expect("changed geometry");
        browser.confirm_reconfigure(queued);

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
            new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new());
        let browser = surface.as_browser().expect("browser surface");
        assert!(!browser.resize_needed(10, 5));

        *browser.cell_pixels.lock().unwrap() = (9, 16);
        assert!(browser.resize_needed(10, 5));
    }

    #[test]
    fn cell_pixel_change_reports_only_accepted_reconfigure() {
        let opts = SurfaceOptions::default();
        let surface =
            new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new());
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
        browser
            .command_sender()
            .unwrap()
            .send(BrowserCommand::Hold { entered, release: held })
            .unwrap();
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        let sender = browser.command_sender().unwrap();
        for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
            sender.try_send(BrowserCommand::Activate).unwrap();
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

        drop(sender);
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
    fn resize_acceptance_is_reported_by_worker_before_execution() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        browser
            .command_sender()
            .unwrap()
            .send(BrowserCommand::Hold { entered, release: held })
            .unwrap();
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
            new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new());
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
    fn attach_frames_are_latest_wins_and_close_detaches() {
        let surface = test_surface();
        let browser = surface.as_browser().expect("browser surface");
        let (_state, stream) = browser.attach_frames();

        browser.store_frame(test_frame(1));
        browser.store_frame(test_frame(2));
        browser.store_frame(test_frame(3));

        stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
        let frame = stream.slot.lock().unwrap().frame.take().expect("latest frame");
        assert_eq!(frame.seq, 3);
        assert!(stream.notify.try_recv().is_err());

        browser.store_frame(test_frame(4));
        stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
        let frame = stream.slot.lock().unwrap().frame.take().expect("next latest frame");
        assert_eq!(frame.seq, 4);

        browser.kill();
        assert!(stream.notify.recv_timeout(Duration::from_secs(1)).is_err());
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
