use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use mux_cdp::{
    discover_browser_ws_url, resolve_browser_ws_url, CdpClient, CdpEvent, CdpKeyEvent, Chrome,
    ChromeLaunchOptions, TargetCreated,
};

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
    page_viewport: Option<(u32, u32)>,
    status: BrowserStatus,
    source: Option<BrowserSource>,
    next_frame_seq: u64,
    live_since: Option<Instant>,
    last_frame_at: Option<Instant>,
    stall_nudged: bool,
}

pub struct BrowserRuntime {
    client: CdpClient,
    chrome: Option<Chrome>,
    source: BrowserSource,
    routes: Mutex<Routes>,
    closed: AtomicBool,
}

#[derive(Default)]
struct Routes {
    by_session: HashMap<String, Sender<CdpEvent>>,
    by_target: HashMap<String, Sender<CdpEvent>>,
}

pub struct BrowserSurface {
    pub(crate) meta: SurfaceMeta,
    session: Mutex<Option<BrowserSession>>,
    state: Mutex<BrowserState>,
    dirty: AtomicBool,
    dead: AtomicBool,
    cell_pixels: Mutex<(u16, u16)>,
    capture_options: BrowserCaptureOptions,
}

#[derive(Debug, Clone, Copy)]
struct BrowserCaptureOptions {
    max_capture_megapixels: f64,
    fixed_capture_scale: Option<f64>,
}

const DEFAULT_CAPTURE_MEGAPIXELS: f64 = 2.0;
const STALL_THRESHOLD: Duration = Duration::from_secs(2);

impl BrowserRuntime {
    pub fn connect(opts: &SurfaceOptions) -> anyhow::Result<Arc<Self>> {
        let (web_socket_url, chrome, source) = runtime_endpoint(opts)?;
        let (event_tx, event_rx) = std::sync::mpsc::channel();
        let client = CdpClient::connect(&web_socket_url, event_tx)?;
        client.set_discover_targets(true)?;
        let runtime = Arc::new(BrowserRuntime {
            client,
            chrome,
            source,
            routes: Mutex::new(Routes::default()),
            closed: AtomicBool::new(false),
        });
        start_router(runtime.clone(), event_rx)?;
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
        let (event_tx, event_rx) = std::sync::mpsc::channel();
        self.register(&target_id, &session_id, event_tx);

        let setup_result =
            self.setup_attached_surface(&surface, &target_id, &session_id, &normalized_url);
        if let Err(err) = setup_result {
            self.unregister(&target_id, &session_id);
            let _ = self.client.close_target(&target_id);
            return Err(err);
        }

        start_surface_thread(surface, event_rx, mux, Arc::downgrade(self))?;
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

    fn register(&self, target_id: &str, session_id: &str, tx: Sender<CdpEvent>) {
        let mut routes = self.routes.lock().unwrap();
        routes.by_session.insert(session_id.to_string(), tx.clone());
        routes.by_target.insert(target_id.to_string(), tx);
    }

    fn unregister(&self, target_id: &str, session_id: &str) {
        let mut routes = self.routes.lock().unwrap();
        routes.by_session.remove(session_id);
        routes.by_target.remove(target_id);
    }

    fn close_surface(&self, target_id: &str, session_id: &str) {
        self.unregister(target_id, session_id);
        if !self.is_closed() {
            let _ = self.client.close_target(target_id);
        }
    }

    pub fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
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
) -> Arc<Surface> {
    let normalized_url = normalize_url(&url);
    let (cols, rows) = (size.0.max(1), size.1.max(1));
    let (cell_w, cell_h) = (cell_pixels.0.max(1), cell_pixels.1.max(1));
    let pixel_w = cols as u32 * cell_w as u32;
    let pixel_h = rows as u32 * cell_h as u32;
    let capture_options = BrowserCaptureOptions::from_options(opts);
    let capture_scale = capture_scale_for(pixel_w, pixel_h, capture_options);
    let capture_pixels = scaled_pixels(pixel_w, pixel_h, capture_scale);
    Arc::new(Surface::Browser(BrowserSurface {
        meta: SurfaceMeta { id, name: Mutex::new(None) },
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
            page_viewport: None,
            status: BrowserStatus::Starting,
            source: None,
            next_frame_seq: 1,
            live_since: None,
            last_frame_at: None,
            stall_nudged: false,
        }),
        dirty: AtomicBool::new(true),
        dead: AtomicBool::new(false),
        cell_pixels: Mutex::new((cell_w, cell_h)),
        capture_options,
    }))
}

impl BrowserCaptureOptions {
    fn from_options(opts: &SurfaceOptions) -> Self {
        let max_capture_megapixels = if opts.browser_max_capture_megapixels.is_finite()
            && opts.browser_max_capture_megapixels > 0.0
        {
            opts.browser_max_capture_megapixels
        } else {
            DEFAULT_CAPTURE_MEGAPIXELS
        };
        let fixed_capture_scale = opts
            .browser_capture_scale
            .filter(|scale| scale.is_finite() && *scale > 0.0 && *scale <= 1.0);
        BrowserCaptureOptions { max_capture_megapixels, fixed_capture_scale }
    }
}

fn capture_scale_for(pane_px_w: u32, pane_px_h: u32, opts: BrowserCaptureOptions) -> f64 {
    if let Some(scale) = opts.fixed_capture_scale {
        return scale;
    }
    let area = f64::from(pane_px_w.max(1)) * f64::from(pane_px_h.max(1));
    let budget = opts.max_capture_megapixels.max(f64::MIN_POSITIVE) * 1_000_000.0;
    if area <= budget {
        1.0
    } else {
        (budget / area).sqrt().clamp(f64::MIN_POSITIVE, 1.0)
    }
}

fn scaled_pixels(pane_px_w: u32, pane_px_h: u32, scale: f64) -> (u32, u32) {
    let width = (f64::from(pane_px_w.max(1)) * scale).round().max(1.0) as u32;
    let height = (f64::from(pane_px_h.max(1)) * scale).round().max(1.0) as u32;
    (width, height)
}

fn runtime_endpoint(
    opts: &SurfaceOptions,
) -> anyhow::Result<(String, Option<Chrome>, BrowserSource)> {
    if let Ok(url) = std::env::var("CMUX_MUX_CDP_URL") {
        if !url.trim().is_empty() {
            return Ok((resolve_browser_ws_url(&url)?, None, BrowserSource::External));
        }
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
    let chrome = Chrome::launch_with(ChromeLaunchOptions {
        binary: opts.chrome_binary.clone(),
        user_data_dir: opts.browser_user_data_dir.as_deref().map(PathBuf::from),
        session_name: opts.browser_session_name.clone(),
        ephemeral: opts.browser_ephemeral,
    })?;
    let web_socket_url = chrome.web_socket_url().to_string();
    Ok((web_socket_url, Some(chrome), BrowserSource::Launched))
}

fn start_router(runtime: Arc<BrowserRuntime>, events: Receiver<CdpEvent>) -> anyhow::Result<()> {
    std::thread::Builder::new().name("browser-runtime-events".into()).spawn(move || {
        while let Ok(event) = events.recv() {
            match event {
                CdpEvent::ScreencastFrame(frame) => {
                    let tx = {
                        runtime.routes.lock().unwrap().by_session.get(&frame.session_id).cloned()
                    };
                    if let Some(tx) = tx {
                        let _ = tx.send(CdpEvent::ScreencastFrame(frame));
                    }
                }
                CdpEvent::TargetCreated(created) => {
                    let tx = created.opener_id.as_ref().and_then(|opener_id| {
                        runtime.routes.lock().unwrap().by_target.get(opener_id).cloned()
                    });
                    if let Some(tx) = tx {
                        let _ = tx.send(CdpEvent::TargetCreated(created));
                    }
                }
                CdpEvent::TargetInfoChanged(info) => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_target.get(&info.target_id).cloned() };
                    if let Some(tx) = tx {
                        let _ = tx.send(CdpEvent::TargetInfoChanged(info));
                    }
                }
                CdpEvent::Other { method, params, session_id: Some(session_id) } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx {
                        let _ = tx.send(CdpEvent::Other {
                            method,
                            params,
                            session_id: Some(session_id),
                        });
                    }
                }
                CdpEvent::Closed(reason) => {
                    runtime.closed.store(true, Ordering::Release);
                    let senders = {
                        let mut routes = runtime.routes.lock().unwrap();
                        let senders = routes.by_session.values().cloned().collect::<Vec<_>>();
                        routes.by_session.clear();
                        routes.by_target.clear();
                        senders
                    };
                    for tx in senders {
                        let _ = tx.send(CdpEvent::Closed(reason.clone()));
                    }
                    break;
                }
                CdpEvent::Other { .. } => {}
            }
        }
    })?;
    Ok(())
}

fn start_surface_thread(
    surface: Arc<Surface>,
    events: Receiver<CdpEvent>,
    mux: Weak<Mux>,
    runtime: Weak<BrowserRuntime>,
) -> anyhow::Result<()> {
    let id = surface.id;
    std::thread::Builder::new().name(format!("browser-surface-{id}-events")).spawn(move || {
        while let Ok(event) = events.recv() {
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
                    if !browser.dirty.swap(true, Ordering::AcqRel) {
                        if let Some(mux) = mux.upgrade() {
                            mux.emit(MuxEvent::SurfaceOutput(id));
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
                    if url_changed || title_changed {
                        if let Some(mux) = mux.upgrade() {
                            mux.emit(MuxEvent::TitleChanged(id));
                        }
                    }
                }
                CdpEvent::Other { method, params, .. } if method == "Page.frameNavigated" => {
                    handle_frame_navigated(browser, params);
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::TitleChanged(id));
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
                    browser.mark_dead();
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

    pub fn kill(&self) {
        if self.dead.swap(true, Ordering::AcqRel) {
            return;
        }
        self.close_taps();
        if let Some(session) = self.session.lock().unwrap().take() {
            session.runtime.close_surface(&session.target_id, &session.session_id);
        }
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        if let Err(e) = self.try_resize(cols, rows) {
            eprintln!("cmux-mux: browser resize failed for surface {}: {e}", self.meta.id);
        }
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) {
        {
            let mut cell = self.cell_pixels.lock().unwrap();
            let next = (width_px.max(1), height_px.max(1));
            if *cell == next {
                return;
            }
            *cell = next;
        }
        let (cols, rows) = self.size();
        self.resize(cols, rows);
    }

    fn try_resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let cell = *self.cell_pixels.lock().unwrap();
        let pixel_w = cols as u32 * cell.0.max(1) as u32;
        let pixel_h = rows as u32 * cell.1.max(1) as u32;
        let (unchanged, capture_w, capture_h) = {
            let mut state = self.state.lock().unwrap();
            let capture_scale = capture_scale_for(pixel_w, pixel_h, self.capture_options);
            let capture_pixels = scaled_pixels(pixel_w, pixel_h, capture_scale);
            let unchanged = state.size == (cols, rows)
                && state.pane_pixels == (pixel_w, pixel_h)
                && state.capture_pixels == capture_pixels;
            state.size = (cols, rows);
            state.pane_pixels = (pixel_w, pixel_h);
            state.capture_pixels = capture_pixels;
            state.capture_scale = capture_scale;
            if !unchanged {
                state.live_since = Some(Instant::now());
                state.last_frame_at = None;
                state.stall_nudged = false;
            }
            (unchanged, capture_pixels.0, capture_pixels.1)
        };
        if unchanged {
            return Ok(());
        }
        let Some(session) = self.live_session()? else { return Ok(()) };
        session.runtime.client.set_device_metrics(&session.session_id, capture_w, capture_h)?;
        let _ = session.runtime.client.stop_screencast(&session.session_id);
        session.runtime.client.start_screencast(&session.session_id, capture_w, capture_h)?;
        Ok(())
    }

    pub fn attach_frames(&self) -> (BrowserAttachState, BrowserFrameStream) {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
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
        // failed navigation; they must not clear the Failed status. A
        // successful navigate/reload clears it (set_url_title,
        // clear_error), same as mark_live.
        if !matches!(state.status, BrowserStatus::Failed(_)) {
            state.status = BrowserStatus::Live;
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

    fn mark_dead(&self) {
        self.dead.store(true, Ordering::Release);
        self.close_taps();
        let _ = self.session.lock().unwrap().take();
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

    pub fn mouse_event(
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
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        session.runtime.client.dispatch_key_event(
            &session.session_id,
            CdpKeyEvent { event_type, key, code, windows_virtual_key_code, modifiers, text },
        )
    }

    pub fn insert_text(&self, text: &str) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        session.runtime.client.insert_text(&session.session_id, text)
    }

    pub fn navigate(&self, url: &str) -> anyhow::Result<()> {
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
        self.navigate_history(-1)
    }

    pub fn forward(&self) -> anyhow::Result<()> {
        self.navigate_history(1)
    }

    fn navigate_history(&self, delta: isize) -> anyhow::Result<()> {
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
        let session = self.require_live_session()?;
        session.runtime.client.reload(&session.session_id)?;
        self.clear_error();
        Ok(())
    }

    pub fn activate(&self) -> anyhow::Result<()> {
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
        capture_scale_for, new_surface, normalize_url, runtime_endpoint, scaled_pixels,
        BrowserCaptureOptions, BrowserFrame, BrowserSource, BrowserStatus,
    };
    use crate::SurfaceOptions;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;
    use std::thread;
    use std::time::{Duration, Instant};

    fn test_frame(seq: u64) -> BrowserFrame {
        BrowserFrame {
            session_id: "session-test".to_string(),
            data_b64: "AAAA".to_string(),
            css_width: 80,
            css_height: 48,
            seq,
        }
    }

    #[test]
    fn frames_do_not_clear_failed_status() {
        let opts = SurfaceOptions::default();
        let surface = new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts);
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
    }

    #[test]
    fn browser_discovery_is_explicit_opt_in() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let (ready_tx, ready_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            ready_tx.send(()).unwrap();
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 512];
            let _ = stream.read(&mut request).unwrap();
            let body = r#"{"webSocketDebuggerUrl":"ws://127.0.0.1:9/devtools/browser/fake"}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        });
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let opts = SurfaceOptions {
            chrome_binary: Some("/definitely/missing/cmux-test-chrome".to_string()),
            browser_discover_ports: vec![port],
            ..Default::default()
        };
        let err = match runtime_endpoint(&opts) {
            Ok((url, _, source)) => {
                panic!("default config should launch, not discover; got {source:?} {url}")
            }
            Err(err) => err,
        };
        assert!(err.to_string().contains("configured browser.chrome_binary"));

        let discover_opts = SurfaceOptions { browser_discover: true, ..opts };
        let (url, chrome, source) = runtime_endpoint(&discover_opts).unwrap();
        assert_eq!(url, "ws://127.0.0.1:9/devtools/browser/fake");
        assert!(chrome.is_none());
        assert_eq!(source, BrowserSource::External);
        server.join().unwrap();
    }

    #[test]
    fn input_mapping_uses_latest_frame_viewport() {
        let opts = SurfaceOptions::default();
        let surface = new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts);
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
        let surface = new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts);
        let browser = surface.as_browser().expect("browser surface");

        assert_eq!(browser.scale_input_point(2380.0, 1274.0), (966.5, 517.5));
        let expected_scale = browser.state.lock().unwrap().capture_scale;
        assert!((browser.scale_delta(100.0) - 100.0 * expected_scale).abs() < f64::EPSILON);
    }

    #[test]
    fn input_mapping_clamps_to_page_viewport() {
        let opts = SurfaceOptions::default();
        let surface = new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts);
        let browser = surface.as_browser().expect("browser surface");
        browser.store_frame(test_frame(1));

        assert_eq!(browser.scale_input_point(-5.0, 999.0), (0.0, 48.0));
    }

    #[test]
    fn frames_stalled_requires_live_surface_over_threshold() {
        let opts = SurfaceOptions::default();
        let surface = new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts);
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
        let opts = SurfaceOptions::default();
        let surface = new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts);
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

        browser.resize(10, 5);
        {
            let state = browser.state.lock().unwrap();
            assert_eq!(state.last_frame_at, Some(now - Duration::from_secs(3)));
            assert!(state.stall_nudged);
        }
        assert!(browser.frames_stalled_at(now));

        browser.resize(11, 5);
        let state = browser.state.lock().unwrap();
        assert_eq!(state.last_frame_at, None);
        assert!(!state.stall_nudged);
        assert!(!super::frames_stalled_locked(&state, Instant::now(), false));
    }

    #[test]
    fn attach_frames_are_latest_wins_and_close_detaches() {
        let opts = SurfaceOptions::default();
        let surface = new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts);
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
        let opts = SurfaceOptions::default();
        let surface = new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts);
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
