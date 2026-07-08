use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, Sender, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use mux_cdp::{
    discover_browser_ws_url, resolve_browser_ws_url, CdpClient, CdpEvent, CdpKeyEvent, Chrome,
    ChromeLaunchOptions, TargetCreated,
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
    not_responding_reported: bool,
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
        width: u32,
        height: u32,
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
    command_tx: Mutex<Option<SyncSender<BrowserCommand>>>,
    latest_reconfigure: Arc<Mutex<Option<BrowserCommand>>>,
    latest_nav: Arc<Mutex<Option<BrowserCommand>>>,
    #[cfg(test)]
    worker_done: Mutex<Option<Receiver<()>>>,
}

#[derive(Debug, Clone, Copy)]
struct BrowserCaptureOptions {
    max_capture_megapixels: f64,
    fixed_capture_scale: Option<f64>,
}

const DEFAULT_CAPTURE_MEGAPIXELS: f64 = 2.0;
const STALL_THRESHOLD: Duration = Duration::from_secs(2);
const BROWSER_COMMAND_QUEUE_CAPACITY: usize = 64;
const BROWSER_NOT_RESPONDING_MESSAGE: &str = "browser is not responding";

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
        let (event_tx, event_rx) = std::sync::mpsc::channel();
        let client = CdpClient::connect(web_socket_url, event_tx)?;
        client.set_discover_targets(true)?;
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

    fn close_surface_detached(&self, target_id: &str, session_id: &str) {
        self.unregister(target_id, session_id);
        if !self.is_closed() {
            let _ = self.client.close_target_detached(target_id);
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
    let latest_reconfigure = Arc::new(Mutex::new(None));
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
        latest_reconfigure: latest_reconfigure.clone(),
        latest_nav: latest_nav.clone(),
        #[cfg(test)]
        worker_done: Mutex::new(Some(worker_done_rx)),
    }));
    start_browser_worker(
        surface.clone(),
        command_rx,
        latest_reconfigure,
        latest_nav,
        mux,
        worker_done_tx,
    );
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
    let chrome_binary = resolve_chrome_binary(opts.chrome_binary.as_deref())?;
    let user_data_dir = if opts.browser_ephemeral {
        None
    } else {
        Some(resolve_chrome_user_data_dir(
            opts.browser_user_data_dir.as_deref(),
            &opts.browser_session_name,
        )?)
    };
    let chrome = Chrome::launch_with(ChromeLaunchOptions {
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
        .unwrap_or_else(|| "mux.json".to_string());
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
    if trimmed.is_empty() {
        "default".to_string()
    } else {
        trimmed.to_string()
    }
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

fn start_browser_worker(
    surface: Arc<Surface>,
    rx: Receiver<BrowserCommand>,
    latest_reconfigure: Arc<Mutex<Option<BrowserCommand>>>,
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
                        for command in take_latest_worker_commands(&latest_reconfigure, &latest_nav)
                        {
                            run_browser_worker_command(&surface, command, &mux, id, &mut failures);
                        }
                    } else {
                        run_browser_worker_command(&surface, command, &mux, id, &mut failures);
                    }
                }
                for command in take_latest_worker_commands(&latest_reconfigure, &latest_nav) {
                    run_browser_worker_command(&surface, command, &mux, id, &mut failures);
                }
            }
            if let Some(done_tx) = done_tx {
                let _ = done_tx.send(());
            }
        });
}

fn take_latest_worker_commands(
    latest_reconfigure: &Arc<Mutex<Option<BrowserCommand>>>,
    latest_nav: &Arc<Mutex<Option<BrowserCommand>>>,
) -> Vec<BrowserCommand> {
    let reconfigure = latest_reconfigure.lock().unwrap().take();
    let nav = latest_nav.lock().unwrap().take();
    reconfigure.into_iter().chain(nav).collect()
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
    command: BrowserCommand,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
) {
    let is_input = command.is_input();
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
            BrowserCommand::Reconfigure { width, height } => {
                browser.reconfigure_blocking(width, height)
            }
        }
    };
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
        mux.emit(MuxEvent::TitleChanged(id));
        mux.emit(MuxEvent::SurfaceOutput(id));
    }
}

fn emit_browser_failure(mux: &Weak<Mux>, id: SurfaceId, message: String) {
    if let Some(mux) = mux.upgrade() {
        mux.emit(MuxEvent::Status(message));
        mux.emit(MuxEvent::TitleChanged(id));
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

    pub fn resize(&self, cols: u16, rows: u16) {
        let Some((width, height)) = self.update_resize_state(cols, rows) else {
            return;
        };
        if let Err(e) =
            self.enqueue_latest_reconfigure(BrowserCommand::Reconfigure { width, height })
        {
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

    fn update_resize_state(&self, cols: u16, rows: u16) -> Option<(u32, u32)> {
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
            return None;
        }
        Some((capture_w, capture_h))
    }

    fn reconfigure_blocking(&self, width: u32, height: u32) -> anyhow::Result<()> {
        let Some(session) = self.live_session()? else { return Ok(()) };
        session.runtime.client.set_device_metrics(&session.session_id, width, height)?;
        let _ = session.runtime.client.stop_screencast(&session.session_id);
        session.runtime.client.start_screencast(&session.session_id, width, height)?;
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

    fn mark_dead(&self) {
        self.dead.store(true, Ordering::Release);
        self.close_taps();
        let _ = self.session.lock().unwrap().take();
        self.close_command_sender();
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

    fn enqueue_latest_reconfigure(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        *self.latest_reconfigure.lock().unwrap() = Some(command);
        self.wake_worker()
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
        capture_scale_for, new_surface, normalize_url, runtime_endpoint, scaled_pixels,
        take_latest_worker_commands, BrowserCaptureOptions, BrowserCommand, BrowserFrame,
        BrowserSource, BrowserStatus,
    };
    use crate::{Mux, Surface, SurfaceOptions};
    use serde_json::{json, Value};
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{mpsc, Arc, Mutex, Weak};
    use std::thread;
    use std::time::{Duration, Instant};
    use tungstenite::{accept, Message};

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
    ) -> anyhow::Result<(String, Option<mux_cdp::Chrome>, BrowserSource)> {
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
        ws.send(Message::Text(value.to_string())).unwrap();
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
    fn latest_reconfigure_and_nav_slots_do_not_clobber_each_other() {
        let latest_reconfigure =
            Arc::new(Mutex::new(Some(BrowserCommand::Reconfigure { width: 111, height: 222 })));
        let latest_nav =
            Arc::new(Mutex::new(Some(BrowserCommand::Navigate("https://next.test".to_string()))));

        let commands = take_latest_worker_commands(&latest_reconfigure, &latest_nav);
        assert_eq!(commands.len(), 2);
        match &commands[0] {
            BrowserCommand::Reconfigure { width, height } => {
                assert_eq!((*width, *height), (111, 222));
            }
            _ => panic!("reconfigure must drain before nav"),
        }
        match &commands[1] {
            BrowserCommand::Navigate(url) => assert_eq!(url, "https://next.test"),
            _ => panic!("nav command was lost"),
        }
        assert!(latest_reconfigure.lock().unwrap().is_none());
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
            crate::MuxEvent::Status(message) if message == "CDP call Page.navigate timed out"
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
            crate::MuxEvent::Status(message) if message == super::BROWSER_NOT_RESPONDING_MESSAGE
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
            crate::MuxEvent::Status(message) if message == super::BROWSER_NOT_RESPONDING_MESSAGE
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
            crate::MuxEvent::Status(message) if message == super::BROWSER_NOT_RESPONDING_MESSAGE
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
