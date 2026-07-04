use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex, Weak};

use mux_cdp::{
    discover_browser_ws_url, resolve_browser_ws_url, CdpClient, CdpEvent, CdpKeyEvent, Chrome,
    ChromeLaunchOptions,
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
    runtime: Arc<BrowserRuntime>,
    target_id: String,
    session_id: String,
    latest_frame: Mutex<Option<BrowserFrame>>,
    dirty: AtomicBool,
    dead: AtomicBool,
    title: Mutex<String>,
    url: Mutex<String>,
    size: Mutex<(u16, u16)>,
    cell_pixels: Mutex<(u16, u16)>,
    pixels: Mutex<(u32, u32)>,
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

    pub fn spawn_surface(
        self: &Arc<Self>,
        id: SurfaceId,
        url: String,
        mux: Weak<Mux>,
        size: (u16, u16),
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        if self.is_closed() {
            anyhow::bail!("CDP browser connection is closed");
        }

        let normalized_url = normalize_url(&url);
        let target_id = self.client.create_target(&normalized_url)?;
        let session_id = self.client.attach_to_target(&target_id)?;
        let (event_tx, event_rx) = std::sync::mpsc::channel();
        self.register(&target_id, &session_id, event_tx);

        let setup_result = (|| -> anyhow::Result<()> {
            self.client.page_enable(&session_id)?;
            let (cols, rows) = (size.0.max(1), size.1.max(1));
            let (cell_w, cell_h) = (cell_pixels.0.max(1), cell_pixels.1.max(1));
            let pixel_w = cols as u32 * cell_w as u32;
            let pixel_h = rows as u32 * cell_h as u32;
            self.client.set_device_metrics(&session_id, pixel_w, pixel_h)?;
            self.client.start_screencast(&session_id, pixel_w, pixel_h)?;
            Ok(())
        })();
        if let Err(err) = setup_result {
            self.unregister(&target_id, &session_id);
            let _ = self.client.close_target(&target_id);
            return Err(err);
        }

        let (cols, rows) = (size.0.max(1), size.1.max(1));
        let (cell_w, cell_h) = (cell_pixels.0.max(1), cell_pixels.1.max(1));
        let pixel_w = cols as u32 * cell_w as u32;
        let pixel_h = rows as u32 * cell_h as u32;
        let surface = Arc::new(Surface::Browser(BrowserSurface {
            meta: SurfaceMeta { id, name: Mutex::new(None) },
            runtime: self.clone(),
            target_id,
            session_id,
            latest_frame: Mutex::new(None),
            dirty: AtomicBool::new(true),
            dead: AtomicBool::new(false),
            title: Mutex::new(normalized_url.clone()),
            url: Mutex::new(normalized_url),
            size: Mutex::new((cols, rows)),
            cell_pixels: Mutex::new((cell_w, cell_h)),
            pixels: Mutex::new((pixel_w, pixel_h)),
        }));
        start_surface_thread(surface.clone(), event_rx, mux)?;
        Ok(surface)
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

pub(crate) fn spawn(
    id: SurfaceId,
    url: String,
    runtime: Arc<BrowserRuntime>,
    mux: Weak<Mux>,
    size: (u16, u16),
    cell_pixels: (u16, u16),
) -> anyhow::Result<Arc<Surface>> {
    runtime.spawn_surface(id, url, mux, size, cell_pixels)
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
        Some(resolve_chrome_user_data_dir(opts.browser_user_data_dir.as_deref())?)
    };
    let chrome = Chrome::launch_with(ChromeLaunchOptions {
        binary: chrome_binary,
        user_data_dir,
        ephemeral: opts.browser_ephemeral,
    })?;
    let web_socket_url = chrome.web_socket_url().to_string();
    Ok((web_socket_url, Some(chrome), BrowserSource::Launched))
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

fn resolve_chrome_user_data_dir(explicit: Option<&str>) -> anyhow::Result<PathBuf> {
    if let Some(path) = explicit.filter(|s| !s.trim().is_empty()) {
        return Ok(PathBuf::from(path));
    }
    platform::chrome_user_data_dir().ok_or_else(|| {
        anyhow::anyhow!(
            "cannot determine Chrome profile directory; set HOME or browser.user_data_dir"
        )
    })
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
                    *browser.latest_frame.lock().unwrap() = Some(frame);
                    if !browser.dirty.swap(true, Ordering::AcqRel) {
                        if let Some(mux) = mux.upgrade() {
                            mux.emit(MuxEvent::SurfaceOutput(id));
                        }
                    }
                }
                CdpEvent::TargetInfoChanged(info) => {
                    let title = if info.title.is_empty() { info.url.clone() } else { info.title };
                    if !info.url.is_empty() {
                        *browser.url.lock().unwrap() = info.url;
                    }
                    let mut current = browser.title.lock().unwrap();
                    if *current != title {
                        *current = title;
                        drop(current);
                        if let Some(mux) = mux.upgrade() {
                            mux.emit(MuxEvent::TitleChanged(id));
                        }
                    }
                }
                CdpEvent::Closed(_) => {
                    browser.dead.store(true, Ordering::Release);
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
        self.latest_frame.lock().unwrap().clone()
    }

    pub fn title(&self) -> String {
        self.title.lock().unwrap().clone()
    }

    pub fn url(&self) -> String {
        self.url.lock().unwrap().clone()
    }

    pub fn source(&self) -> BrowserSource {
        self.runtime.source()
    }

    pub fn size(&self) -> (u16, u16) {
        *self.size.lock().unwrap()
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
        self.runtime.close_surface(&self.target_id, &self.session_id);
    }

    /// Returns whether the cell grid size actually changed (pixel-only
    /// changes do not count; the CDP work happens either way).
    pub fn resize(&self, cols: u16, rows: u16) -> bool {
        let changed = *self.size.lock().unwrap() != (cols.max(1), rows.max(1));
        if let Err(e) = self.try_resize(cols, rows) {
            eprintln!("cmux-mux: browser resize failed for surface {}: {e}", self.meta.id);
        }
        changed
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
            let mut size = self.size.lock().unwrap();
            let mut pixels = self.pixels.lock().unwrap();
            let unchanged = *size == (cols, rows) && *pixels == (pixel_w, pixel_h);
            *size = (cols, rows);
            *pixels = (pixel_w, pixel_h);
            unchanged
        };
        if unchanged {
            return Ok(());
        }
        self.runtime.client.set_device_metrics(&self.session_id, pixel_w, pixel_h)?;
        let _ = self.runtime.client.stop_screencast(&self.session_id);
        self.runtime.client.start_screencast(&self.session_id, pixel_w, pixel_h)?;
        Ok(())
    }

    pub fn mouse_event(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        self.runtime.client.dispatch_mouse_event(
            &self.session_id,
            event_type,
            x,
            y,
            button,
            click_count,
        )
    }

    pub fn wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        self.runtime.client.dispatch_wheel(&self.session_id, x, y, delta_y)
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
        self.runtime.client.dispatch_key_event(
            &self.session_id,
            CdpKeyEvent { event_type, key, code, windows_virtual_key_code, modifiers, text },
        )
    }

    pub fn insert_text(&self, text: &str) -> anyhow::Result<()> {
        self.runtime.client.insert_text(&self.session_id, text)
    }

    pub fn navigate(&self, url: &str) -> anyhow::Result<()> {
        let normalized = normalize_url(url);
        self.runtime.client.navigate(&self.session_id, &normalized)?;
        *self.url.lock().unwrap() = normalized.clone();
        *self.title.lock().unwrap() = normalized;
        Ok(())
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
