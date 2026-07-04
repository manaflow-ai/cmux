use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, Weak};

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
}

#[derive(Clone)]
struct BrowserSession {
    runtime: Arc<BrowserRuntime>,
    target_id: String,
    session_id: String,
}

struct BrowserState {
    latest_frame: Option<BrowserFrame>,
    // Bounded attach frame taps. Broadcast uses try_send while holding
    // this same state lock; a stalled client is dropped instead of
    // blocking the CDP event path or building an unbounded queue.
    taps: Vec<SyncSender<BrowserFrame>>,
    title: String,
    url: String,
    size: (u16, u16),
    pixels: (u32, u32),
    status: BrowserStatus,
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
}

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
) -> Arc<Surface> {
    let normalized_url = normalize_url(&url);
    let (cols, rows) = (size.0.max(1), size.1.max(1));
    let (cell_w, cell_h) = (cell_pixels.0.max(1), cell_pixels.1.max(1));
    let pixel_w = cols as u32 * cell_w as u32;
    let pixel_h = rows as u32 * cell_h as u32;
    Arc::new(Surface::Browser(BrowserSurface {
        meta: SurfaceMeta { id, name: Mutex::new(None) },
        session: Mutex::new(None),
        state: Mutex::new(BrowserState {
            latest_frame: None,
            taps: Vec::new(),
            title: normalized_url.clone(),
            url: normalized_url,
            size: (cols, rows),
            pixels: (pixel_w, pixel_h),
            status: BrowserStatus::Starting,
        }),
        dirty: AtomicBool::new(true),
        dead: AtomicBool::new(false),
        cell_pixels: Mutex::new((cell_w, cell_h)),
    }))
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
                        seq: frame.seq,
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
                    if !info.url.is_empty() {
                        browser.set_url(info.url);
                    }
                    if browser.set_title(title) {
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

    pub fn source(&self) -> Option<BrowserSource> {
        self.session.lock().unwrap().as_ref().map(|session| session.runtime.source())
    }

    pub fn size(&self) -> (u16, u16) {
        self.state.lock().unwrap().size
    }

    fn pixel_size(&self) -> (u32, u32) {
        self.state.lock().unwrap().pixels
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
        let unchanged = {
            let mut state = self.state.lock().unwrap();
            let unchanged = state.size == (cols, rows) && state.pixels == (pixel_w, pixel_h);
            state.size = (cols, rows);
            state.pixels = (pixel_w, pixel_h);
            unchanged
        };
        if unchanged {
            return Ok(());
        }
        let Some(session) = self.live_session()? else { return Ok(()) };
        session.runtime.client.set_device_metrics(&session.session_id, pixel_w, pixel_h)?;
        let _ = session.runtime.client.stop_screencast(&session.session_id);
        session.runtime.client.start_screencast(&session.session_id, pixel_w, pixel_h)?;
        Ok(())
    }

    pub fn attach_frames(&self) -> (BrowserAttachState, Receiver<BrowserFrame>) {
        let (tx, rx) = std::sync::mpsc::sync_channel(2);
        let mut state = self.state.lock().unwrap();
        let snapshot = BrowserAttachState {
            url: state.url.clone(),
            title: state.title.clone(),
            cols: state.size.0,
            rows: state.size.1,
            status: state.status.clone(),
            frame: state.latest_frame.clone(),
        };
        if !self.is_dead() {
            state.taps.push(tx);
        }
        (snapshot, rx)
    }

    fn store_frame(&self, frame: BrowserFrame) {
        let mut state = self.state.lock().unwrap();
        state.status = BrowserStatus::Live;
        state.latest_frame = Some(frame.clone());
        state.taps.retain(|tap| match tap.try_send(frame.clone()) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => false,
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
        if !matches!(state.status, BrowserStatus::Failed(_)) {
            state.status = BrowserStatus::Live;
        }
        Ok(())
    }

    pub fn mark_failed(&self, message: String) {
        let mut state = self.state.lock().unwrap();
        state.status = BrowserStatus::Failed(message.clone());
        state.title = format!("browser failed: {message}");
        self.dirty.store(true, Ordering::Release);
    }

    fn clear_error(&self) {
        let mut state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            state.status = BrowserStatus::Live;
        }
    }

    fn set_title(&self, title: String) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.title == title {
            return false;
        }
        state.title = title;
        true
    }

    fn set_url(&self, url: String) {
        self.state.lock().unwrap().url = url;
    }

    fn set_url_title(&self, url: String, title: String) {
        let mut state = self.state.lock().unwrap();
        state.url = url;
        state.title = title;
        state.status = BrowserStatus::Live;
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

    pub fn mouse_event(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
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
        session.runtime.client.dispatch_key_event(
            &session.session_id,
            CdpKeyEvent { event_type, key, code, windows_virtual_key_code, modifiers, text },
        )
    }

    pub fn insert_text(&self, text: &str) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
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

    fn handle_javascript_dialog(&self, accept: bool) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        session.runtime.client.handle_javascript_dialog(&session.session_id, accept)
    }
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

pub(crate) fn normalize_url(input: &str) -> String {
    let trimmed = input.trim();
    if trimmed.contains("://")
        || trimmed.starts_with("about:")
        || trimmed.starts_with("file:")
        || trimmed.starts_with("data:")
        || trimmed.starts_with("chrome:")
        || trimmed.starts_with("devtools:")
    {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_url;

    #[test]
    fn normalizes_browser_urls() {
        assert_eq!(normalize_url("example.com"), "https://example.com");
        assert_eq!(normalize_url(" https://example.com "), "https://example.com");
        assert_eq!(normalize_url("about:blank"), "about:blank");
        assert_eq!(normalize_url("file:///tmp/test.html"), "file:///tmp/test.html");
    }
}
