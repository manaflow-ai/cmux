//! Remote session client: JSON-lines control socket plus locally
//! mirrored surface terminals (VT replay + live stream).

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_tui_core::{
    BrowserFrame, BrowserSource, BrowserStatus, DefaultColors, MuxEvent, MuxEventBroadcaster,
    MuxEventReceiver, Rgb, SurfaceId, SurfaceKind, platform::transport,
};
use ghostty_vt::{Callbacks, RenderState, Terminal};
use serde_json::{Value, json};

use super::tree::{TreeView, parse_tree};

const SUPPORTED_PROTOCOL_VERSION: u64 = 7;

#[derive(Debug)]
pub(crate) enum RemoteRequestError {
    Encode(serde_json::Error),
    Transport(std::io::Error),
    Timeout,
    Rejected(String),
    Shutdown,
}

impl RemoteRequestError {
    pub(crate) fn is_transport_failure(&self) -> bool {
        matches!(self, Self::Transport(_))
    }

    pub(crate) fn is_timeout(&self) -> bool {
        matches!(self, Self::Timeout)
    }
}

impl std::fmt::Display for RemoteRequestError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Encode(error) => write!(formatter, "could not encode remote request: {error}"),
            Self::Transport(error) => write!(formatter, "remote transport write failed: {error}"),
            Self::Timeout => write!(formatter, "remote session did not respond"),
            Self::Rejected(error) => write!(formatter, "remote command rejected: {error}"),
            Self::Shutdown => write!(formatter, "remote response wait canceled for shutdown"),
        }
    }
}

impl std::error::Error for RemoteRequestError {}

#[derive(Clone)]
struct RemoteBrowserFrame {
    frame: BrowserFrame,
}

#[derive(Clone)]
struct RemoteBrowserState {
    url: Option<String>,
    title: Option<String>,
    source: Option<BrowserSource>,
    status: BrowserStatus,
    frames_stalled: bool,
    live_since: Option<Instant>,
    last_frame_at: Option<Instant>,
    frame: Option<RemoteBrowserFrame>,
}

impl Default for RemoteBrowserState {
    fn default() -> Self {
        Self {
            url: None,
            title: None,
            source: None,
            status: BrowserStatus::Starting,
            frames_stalled: false,
            live_since: None,
            last_frame_at: None,
            frame: None,
        }
    }
}

#[derive(Default)]
struct RemoteTreeCache {
    view: TreeView,
    surface_tabs: HashMap<SurfaceId, [usize; 4]>,
    title_generation: u64,
    title_updates: HashMap<SurfaceId, TitleUpdate>,
}

struct TitleUpdate {
    generation: u64,
    title: String,
}

impl RemoteTreeCache {
    fn replace(&mut self, view: TreeView, refresh_generation: u64) {
        self.surface_tabs.clear();
        for (workspace_index, workspace) in view.workspaces.iter().enumerate() {
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                for (pane_index, pane) in screen.panes.iter().enumerate() {
                    for (tab_index, tab) in pane.tabs.iter().enumerate() {
                        self.surface_tabs.insert(
                            tab.surface,
                            [workspace_index, screen_index, pane_index, tab_index],
                        );
                    }
                }
            }
        }
        self.view = view;

        // A response snapshot can predate title events received while its
        // request was in flight. Reapply only those later authoritative
        // events; older events are already represented by the response.
        let updates = std::mem::take(&mut self.title_updates);
        for (surface_id, update) in updates {
            if self.surface_tabs.contains_key(&surface_id) {
                if update.generation > refresh_generation {
                    self.update_view_title(surface_id, update.title);
                }
            } else if update.generation > refresh_generation {
                self.title_updates.insert(surface_id, update);
            }
        }
    }

    fn update_title(&mut self, surface_id: SurfaceId, title: String) -> bool {
        self.title_generation = self.title_generation.saturating_add(1);
        self.title_updates.insert(
            surface_id,
            TitleUpdate { generation: self.title_generation, title: title.clone() },
        );
        self.update_view_title(surface_id, title)
    }

    fn update_view_title(&mut self, surface_id: SurfaceId, title: String) -> bool {
        let Some([workspace, screen, pane, tab]) = self.surface_tabs.get(&surface_id).copied()
        else {
            return false;
        };
        let Some(tab) = self
            .view
            .workspaces
            .get_mut(workspace)
            .and_then(|workspace| workspace.screens.get_mut(screen))
            .and_then(|screen| screen.panes.get_mut(pane))
            .and_then(|pane| pane.tabs.get_mut(tab))
        else {
            return false;
        };
        if tab.surface != surface_id {
            return false;
        }
        tab.title = title;
        true
    }

    fn title_generation(&self) -> u64 {
        self.title_generation
    }
}

/// A surface mirrored from a remote session.
pub struct RemoteSurface {
    pub id: SurfaceId,
    pub kind: SurfaceKind,
    pub term: Mutex<Terminal>,
    pub dirty: AtomicBool,
    server_size: Mutex<(u16, u16)>,
    asserted_size: Mutex<Option<(u16, u16)>>,
    browser: Mutex<RemoteBrowserState>,
}

impl RemoteSurface {
    pub(super) fn set_server_size(&self, cols: u16, rows: u16) {
        let (cols, rows) = (cols.max(1), rows.max(1));
        *self.server_size.lock().unwrap() = (cols, rows);
    }

    /// Apply an ordered attach-stream resize marker to the mirror terminal.
    pub(super) fn apply_stream_resize(&self, cols: u16, rows: u16, replay: Option<&[u8]>) {
        let (cols, rows) = (cols.max(1), rows.max(1));
        self.set_server_size(cols, rows);
        let mut term = self.term.lock().unwrap();
        if let Some(replay) = replay
            && let Ok(mut fresh) = Terminal::new(cols, rows, 10_000, Callbacks::default())
        {
            fresh.vt_write(replay);
            *term = fresh;
            return;
        }
        let _ = term.resize(cols, rows, 8, 16);
    }

    pub(super) fn server_size(&self) -> (u16, u16) {
        *self.server_size.lock().unwrap()
    }

    pub(super) fn asserted_size(&self) -> Option<(u16, u16)> {
        *self.asserted_size.lock().unwrap()
    }

    pub(super) fn set_asserted_size(&self, size: (u16, u16)) {
        *self.asserted_size.lock().unwrap() = Some(size);
    }

    pub fn browser_frame(&self) -> Option<BrowserFrame> {
        let browser = self.browser.lock().unwrap();
        if matches!(browser.status, BrowserStatus::Failed(_)) {
            None
        } else {
            browser.frame.as_ref().map(|frame| frame.frame.clone())
        }
    }

    pub fn browser_url(&self) -> Option<String> {
        self.browser.lock().unwrap().url.clone()
    }

    pub fn browser_status(&self) -> BrowserStatus {
        self.browser.lock().unwrap().status.clone()
    }

    pub fn browser_frames_stalled(&self) -> bool {
        let browser = self.browser.lock().unwrap();
        if !matches!(browser.status, BrowserStatus::Live) {
            return false;
        }
        if browser.frames_stalled {
            return true;
        }
        if browser.source == Some(BrowserSource::Launched) {
            return false;
        }
        let Some(since) = browser.last_frame_at.or(browser.live_since) else {
            return false;
        };
        Instant::now().saturating_duration_since(since) > Duration::from_secs(2)
    }

    fn update_browser_source(&self, source: Option<BrowserSource>) {
        self.browser.lock().unwrap().source = source;
    }

    fn update_browser_state(&self, value: &Value) {
        let mut browser = self.browser.lock().unwrap();
        let previous_status = browser.status.clone();
        browser.url = value.get("url").and_then(|v| v.as_str()).map(str::to_string);
        browser.title = value.get("title").and_then(|v| v.as_str()).map(str::to_string);
        browser.status = match value.get("status").and_then(|v| v.as_str()) {
            Some("failed") => BrowserStatus::Failed(
                value.get("error").and_then(|v| v.as_str()).unwrap_or("browser failed").to_string(),
            ),
            Some("live") => BrowserStatus::Live,
            _ => BrowserStatus::Starting,
        };
        browser.frames_stalled =
            value.get("frames_stalled").and_then(|v| v.as_bool()).unwrap_or(false);
        if previous_status != BrowserStatus::Live && browser.status == BrowserStatus::Live {
            browser.live_since = Some(Instant::now());
        }
        if let Some(frame) = value.get("frame").and_then(parse_browser_frame) {
            browser.last_frame_at = Some(Instant::now());
            browser.frame = Some(frame);
        }
    }

    fn update_browser_frame(&self, value: &Value) {
        if let Some(frame) = parse_browser_frame(value) {
            let mut browser = self.browser.lock().unwrap();
            browser.status = BrowserStatus::Live;
            browser.frames_stalled = false;
            browser.live_since.get_or_insert_with(Instant::now);
            browser.last_frame_at = Some(Instant::now());
            browser.frame = Some(frame);
        }
    }
}

pub struct RemoteSession {
    writer: Mutex<Box<dyn transport::Stream>>,
    pending: Mutex<HashMap<u64, Sender<Value>>>,
    next_id: AtomicU64,
    shutdown: AtomicBool,
    surfaces: Mutex<HashMap<SurfaceId, Arc<RemoteSurface>>>,
    exited_surfaces: Mutex<HashSet<SurfaceId>>,
    tree: Mutex<RemoteTreeCache>,
    tree_refresh: Mutex<()>,
    tree_stale: AtomicBool,
    subscribers: MuxEventBroadcaster,
    frame_logs: Mutex<HashMap<SurfaceId, Vec<String>>>,
}

impl RemoteSession {
    pub(super) fn has_surface(&self, id: SurfaceId) -> bool {
        self.surfaces.lock().unwrap().contains_key(&id)
    }

    pub(super) fn surface(&self, id: SurfaceId) -> Option<Arc<RemoteSurface>> {
        self.surfaces.lock().unwrap().get(&id).cloned()
    }

    pub fn connect(path: &Path) -> anyhow::Result<Arc<Self>> {
        let stream = transport::connect(path).map_err(|e| {
            anyhow::anyhow!("cannot connect to session socket {}: {e}", path.display())
        })?;
        let read_half = stream.try_clone_box()?;
        let session = Arc::new(RemoteSession {
            writer: Mutex::new(stream),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            shutdown: AtomicBool::new(false),
            surfaces: Mutex::new(HashMap::new()),
            exited_surfaces: Mutex::new(HashSet::new()),
            tree: Mutex::new(RemoteTreeCache::default()),
            tree_refresh: Mutex::new(()),
            tree_stale: AtomicBool::new(true),
            subscribers: MuxEventBroadcaster::default(),
            frame_logs: Mutex::new(HashMap::new()),
        });

        let reader_session = Arc::downgrade(&session);
        std::thread::Builder::new().name("remote-reader".into()).spawn(move || {
            let reader = BufReader::new(read_half);
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
                let Some(session) = reader_session.upgrade() else { break };
                session.handle_line(value);
            }
            // Connection lost: tell the app to quit.
            if let Some(session) = reader_session.upgrade() {
                session.emit(MuxEvent::Empty);
            }
        })?;

        // Identify (validates the endpoint) and subscribe to events.
        let ident = session.request(json!({"cmd": "identify"}))?;
        if ident.get("app").and_then(|v| v.as_str()) != Some("cmux-tui") {
            anyhow::bail!("socket endpoint is not a cmux-tui session");
        }
        let protocol = ident.get("protocol").and_then(|v| v.as_u64()).unwrap_or(0);
        if protocol != SUPPORTED_PROTOCOL_VERSION {
            anyhow::bail!(
                "unsupported cmux-tui protocol {protocol}; this client requires protocol 7; restart the cmux-tui server"
            );
        }
        session.request(json!({"cmd": "subscribe"}))?;
        Ok(session)
    }

    fn emit(&self, event: MuxEvent) {
        self.subscribers.emit(event);
    }

    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribers.subscribe()
    }

    fn handle_line(self: &Arc<Self>, value: Value) {
        let surface_id = || value.get("surface").and_then(|v| v.as_u64());
        match value.get("event").and_then(|v| v.as_str()) {
            None => {
                // Response: route to the waiting request.
                let Some(id) = value.get("id").and_then(|v| v.as_u64()) else { return };
                if let Some(tx) = self.pending.lock().unwrap().remove(&id) {
                    let _ = tx.send(value);
                }
            }
            Some("vt-state") => {
                let Some(id) = surface_id() else { return };
                let cols = value.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
                let rows = value.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
                let Some(data) = value.get("data").and_then(|v| v.as_str()) else { return };
                let Ok(replay) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    return;
                };
                self.log_frame(
                    id,
                    format!("vt-state cols={cols} rows={rows} bytes={}", replay.len()),
                );
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.apply_stream_resize(cols, rows, None);
                    let mut term = surface.term.lock().unwrap();
                    term.vt_write(&replay);
                    drop(term);
                    surface.dirty.store(true, Ordering::Release);
                }
                self.emit(MuxEvent::SurfaceOutput(id));
            }
            Some("surface-resized") => {
                let Some(id) = surface_id() else { return };
                let cols = value.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
                let rows = value.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
                self.emit(MuxEvent::SurfaceResized { surface: id, cols, rows });
            }
            Some("output") => {
                let Some(id) = surface_id() else { return };
                let Some(data) = value.get("data").and_then(|v| v.as_str()) else { return };
                let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    return;
                };
                self.log_frame(id, format!("output bytes={}", bytes.len()));
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.term.lock().unwrap().vt_write(&bytes);
                    if !surface.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            }
            Some("resized") => {
                let Some(id) = surface_id() else { return };
                let cols = value.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
                let rows = value.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
                let replay = value
                    .get("replay")
                    .or_else(|| value.get("data"))
                    .and_then(|v| v.as_str())
                    .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok());
                self.log_frame(
                    id,
                    format!(
                        "resized cols={cols} rows={rows} bytes={}",
                        replay.as_ref().map(|bytes| bytes.len()).unwrap_or(0)
                    ),
                );
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.apply_stream_resize(cols, rows, replay.as_deref());
                    surface.dirty.store(true, Ordering::Release);
                    self.emit(MuxEvent::SurfaceResized { surface: id, cols, rows });
                    self.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            Some("browser-state") => {
                let Some(id) = surface_id() else { return };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    let cols = value.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
                    let rows = value.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
                    surface.apply_stream_resize(cols, rows, None);
                    surface.update_browser_state(&value);
                    surface.dirty.store(true, Ordering::Release);
                }
                if let Some(title) = value.get("title").and_then(Value::as_str) {
                    self.emit(MuxEvent::TitleChanged { surface: id, title: title.to_string() });
                }
                self.emit(MuxEvent::SurfaceOutput(id));
            }
            Some("frame") => {
                let Some(id) = surface_id() else { return };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.update_browser_frame(&value);
                    if !surface.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            }
            Some("detached") => {
                if let Some(id) = surface_id() {
                    self.surfaces.lock().unwrap().remove(&id);
                    self.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            Some("tree-changed") => {
                self.tree_stale.store(true, Ordering::Release);
                self.emit(MuxEvent::TreeChanged);
            }
            Some("layout-changed") => {
                self.tree_stale.store(true, Ordering::Release);
                if let Some(screen) = value.get("screen").and_then(|v| v.as_u64()) {
                    self.emit(MuxEvent::LayoutChanged(screen));
                } else {
                    self.emit(MuxEvent::TreeChanged);
                }
            }
            Some("surface-exited") => {
                if let Some(id) = surface_id() {
                    self.tree_stale.store(true, Ordering::Release);
                    self.emit(MuxEvent::SurfaceExited(id));
                }
            }
            Some("title-changed") => {
                if let Some(id) = surface_id() {
                    if let Some(title) = value.get("title").and_then(Value::as_str) {
                        let updated = self.tree.lock().unwrap().update_title(id, title.to_string());
                        if !updated {
                            self.tree_stale.store(true, Ordering::Release);
                            self.emit(MuxEvent::TreeChanged);
                        }
                        self.emit(MuxEvent::TitleChanged { surface: id, title: title.to_string() });
                    } else {
                        self.tree_stale.store(true, Ordering::Release);
                        self.emit(MuxEvent::TreeChanged);
                    }
                }
            }
            Some("bell") => {
                if let Some(id) = surface_id() {
                    self.emit(MuxEvent::Bell(id));
                }
            }
            Some("notification") => {
                self.emit(MuxEvent::TreeChanged);
            }
            Some("status") => {
                if let Some(message) = value.get("message").and_then(|v| v.as_str()) {
                    self.emit(MuxEvent::Status(message.to_string()));
                }
            }
            Some("config-reload-requested") => self.emit(MuxEvent::ConfigReloadRequested),
            Some("window-title-requested") => {
                if let Some(title) = value.get("title").and_then(|v| v.as_str()) {
                    self.emit(MuxEvent::WindowTitleRequested(title.to_string()));
                }
            }
            Some("scroll-changed") => {
                if let (Some(surface), Some(offset), Some(at_bottom)) = (
                    surface_id(),
                    value.get("offset").and_then(|v| v.as_u64()),
                    value.get("at_bottom").and_then(|v| v.as_bool()),
                ) {
                    self.emit(MuxEvent::ScrollChanged { surface, offset, at_bottom });
                }
            }
            Some("empty") => self.emit(MuxEvent::Empty),
            Some(_) => {}
        }
    }

    fn log_frame(&self, surface: SurfaceId, line: String) {
        if std::env::var_os("CMUX_MUX_DEBUG_MIRROR_DUMP").is_none() {
            return;
        }
        self.frame_logs.lock().unwrap().entry(surface).or_default().push(line);
    }

    pub fn request(&self, mut cmd: Value) -> anyhow::Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        cmd["id"] = json!(id);
        let mut line = serde_json::to_vec(&cmd)
            .map_err(RemoteRequestError::Encode)
            .map_err(anyhow::Error::new)?;
        line.push(b'\n');

        let (tx, rx) = channel();
        self.pending.lock().unwrap().insert(id, tx);
        if let Err(err) = self.writer.lock().unwrap().write_all(&line) {
            self.pending.lock().unwrap().remove(&id);
            return Err(RemoteRequestError::Transport(err).into());
        }

        if self.shutdown.load(Ordering::Acquire) {
            self.pending.lock().unwrap().remove(&id);
            return Err(RemoteRequestError::Shutdown.into());
        }

        let response = match rx.recv_timeout(Duration::from_secs(10)) {
            Ok(response) => response,
            Err(_) => {
                // Drop the pending entry so a half-open session does not
                // accumulate abandoned senders (and a late response is
                // not delivered to a receiver nobody holds).
                self.pending.lock().unwrap().remove(&id);
                return Err(RemoteRequestError::Timeout.into());
            }
        };
        if response.get("shutdown").and_then(Value::as_bool) == Some(true) {
            return Err(RemoteRequestError::Shutdown.into());
        }
        if response.get("ok").and_then(|v| v.as_bool()) == Some(true) {
            Ok(response.get("data").cloned().unwrap_or(Value::Null))
        } else {
            let error = response.get("error").and_then(|v| v.as_str()).unwrap_or("unknown error");
            Err(RemoteRequestError::Rejected(error.to_string()).into())
        }
    }

    pub fn send_bytes(&self, surface: SurfaceId, bytes: &[u8]) -> anyhow::Result<()> {
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        self.request(json!({"cmd": "send", "surface": surface, "bytes": encoded})).map(|_| ())
    }

    pub fn begin_shutdown(&self) {
        self.shutdown.store(true, Ordering::Release);
        let pending = std::mem::take(&mut *self.pending.lock().unwrap());
        for (_, sender) in pending {
            let _ = sender.send(json!({"shutdown": true}));
        }
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<()> {
        self.request(json!({
            "cmd": "set-cell-pixels",
            "width_px": width_px,
            "height_px": height_px,
        }))
        .map(|_| ())
    }

    pub fn set_default_colors(&self, colors: DefaultColors) -> anyhow::Result<()> {
        if colors.fg.is_none() && colors.bg.is_none() {
            return Ok(());
        }
        let mut cmd = json!({"cmd": "set-default-colors"});
        if let Some(fg) = colors.fg {
            cmd["fg"] = json!(hex_color(fg));
        }
        if let Some(bg) = colors.bg {
            cmd["bg"] = json!(hex_color(bg));
        }
        self.request(cmd).map(|_| ())
    }

    pub fn supports_browser_attach(&self) -> bool {
        true
    }

    /// Mirror for a surface, attaching on first use. When a size is
    /// provided, the caller's immediately following `resize` sends the
    /// server resize after the attach tap is installed, so the resize
    /// marker and any shell WINCH redraw bytes stay ordered in-stream.
    pub fn try_ensure_surface(
        self: &Arc<Self>,
        id: SurfaceId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<Arc<RemoteSurface>>> {
        let kind = {
            let tree = self.tree.lock().unwrap();
            tree.view.surface_kind(id)
        };
        self.try_ensure_surface_with_kind(id, kind, size)
    }

    pub fn ensure_surface_with_kind(
        self: &Arc<Self>,
        id: SurfaceId,
        kind: SurfaceKind,
        size: Option<(u16, u16)>,
    ) -> Option<Arc<RemoteSurface>> {
        self.try_ensure_surface_with_kind(id, kind, size).ok().flatten()
    }

    pub fn try_ensure_surface_with_kind(
        self: &Arc<Self>,
        id: SurfaceId,
        kind: SurfaceKind,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<Arc<RemoteSurface>>> {
        if self.exited_surfaces.lock().unwrap().contains(&id) {
            return Ok(None);
        }
        if let Some(surface) = self.surfaces.lock().unwrap().get(&id) {
            return Ok(Some(surface.clone()));
        }
        let source = {
            let tree = self.tree.lock().unwrap();
            browser_source_from_tree(&tree.view, id)
        };
        let (cols, rows) = size.unwrap_or((80, 24));
        let term = Terminal::new(cols, rows, 10_000, Callbacks::default())?;
        let surface = Arc::new(RemoteSurface {
            id,
            kind,
            term: Mutex::new(term),
            dirty: AtomicBool::new(false),
            server_size: Mutex::new((cols, rows)),
            asserted_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        surface.update_browser_source(source);
        self.surfaces.lock().unwrap().insert(id, surface.clone());
        // The vt-state event that follows fills the mirror.
        if let Err(error) = self.request(json!({"cmd": "attach-surface", "surface": id})) {
            self.surfaces.lock().unwrap().remove(&id);
            return Err(error);
        }
        Ok(Some(surface))
    }

    pub fn drop_surface(&self, id: SurfaceId) {
        self.surfaces.lock().unwrap().remove(&id);
        self.exited_surfaces.lock().unwrap().insert(id);
    }

    pub fn surface_kind(&self, id: SurfaceId) -> SurfaceKind {
        self.tree.lock().unwrap().view.surface_kind(id)
    }

    pub fn cached_tree(&self) -> TreeView {
        self.tree.lock().unwrap().view.clone()
    }

    pub fn refresh_tree(&self) -> anyhow::Result<TreeView> {
        self.refresh_tree_inner(true)
    }

    pub fn refresh_tree_background(&self) -> anyhow::Result<TreeView> {
        self.refresh_tree_inner(false)
    }

    fn refresh_tree_inner(&self, identity_refresh: bool) -> anyhow::Result<TreeView> {
        let _refresh = self.tree_refresh.lock().unwrap();
        if identity_refresh {
            self.tree_stale.store(false, Ordering::Release);
        }
        let refresh_generation = self.tree.lock().unwrap().title_generation();
        let data = match self.request(json!({"cmd": "list-workspaces"})) {
            Ok(data) => data,
            Err(e) => {
                if identity_refresh {
                    // Retry identity refreshes rather than caching a bad tree.
                    self.tree_stale.store(true, Ordering::Release);
                }
                return Err(e);
            }
        };
        let tree = parse_tree(&data);
        self.exited_surfaces.lock().unwrap().retain(|surface_id| {
            tree.workspaces
                .iter()
                .flat_map(|workspace| workspace.screens.iter())
                .flat_map(|screen| screen.panes.iter())
                .flat_map(|pane| pane.tabs.iter())
                .any(|tab| tab.surface == *surface_id)
        });
        let tree = {
            let mut cache = self.tree.lock().unwrap();
            cache.replace(tree, refresh_generation);
            cache.view.clone()
        };
        let surfaces = self.surfaces.lock().unwrap().clone();
        for (id, surface) in surfaces {
            surface.update_browser_source(browser_source_from_tree(&tree, id));
        }
        Ok(tree)
    }

    pub fn invalidate_tree(&self) {
        self.tree_stale.store(true, Ordering::Release);
    }

    pub fn take_tree_stale(&self) -> bool {
        self.tree_stale.swap(false, Ordering::AcqRel)
    }

    pub fn tree_is_stale(&self) -> bool {
        self.tree_stale.load(Ordering::Acquire)
    }
}

impl Drop for RemoteSession {
    fn drop(&mut self) {
        let Ok(dir) = std::env::var("CMUX_MUX_DEBUG_MIRROR_DUMP") else {
            return;
        };
        let _ = fs::create_dir_all(&dir);
        let logs = self.frame_logs.lock().unwrap();
        for surface in self.surfaces.lock().unwrap().values() {
            let path = Path::new(&dir).join(format!("mirror-{}.txt", surface.id));
            let _ = fs::write(path, dump_mirror(surface));
            let frames = Path::new(&dir).join(format!("frames-{}.log", surface.id));
            let text = logs.get(&surface.id).map(|lines| lines.join("\n")).unwrap_or_default();
            let _ = fs::write(frames, format!("{text}\n"));
        }
    }
}

fn dump_mirror(surface: &RemoteSurface) -> String {
    let mut out = String::new();
    let mut term = surface.term.lock().unwrap();
    let cols = term.cols();
    let rows = term.rows();
    let scrollbar = term.scrollbar();
    let offset = scrollbar.map(|sb| sb.offset).unwrap_or(0);
    let total = scrollbar.map(|sb| sb.total).unwrap_or(rows as u64);
    out.push_str(&format!(
        "surface={} kind={:?} cols={} rows={} scrollback_offset={} scrollback_total={}\n",
        surface.id, surface.kind, cols, rows, offset, total
    ));

    let Ok(mut rs) = RenderState::new() else {
        return out;
    };
    if rs.update(&mut term).is_err() {
        return out;
    }
    let _ = rs.walk_rows(|row, _, cells| {
        let mut line = String::new();
        let mut inverse = false;
        for cell in cells {
            if cell.inverse && !inverse {
                line.push('\u{ab}');
                inverse = true;
            } else if !cell.inverse && inverse {
                line.push('\u{bb}');
                inverse = false;
            }
            if cell.text.is_empty() {
                line.push(' ');
            } else {
                line.push_str(&cell.text);
            }
        }
        if inverse {
            line.push('\u{bb}');
        }
        out.push_str(&format!("{row:03}: {line}\n"));
    });
    out
}

fn browser_source_from_tree(tree: &TreeView, id: SurfaceId) -> Option<BrowserSource> {
    tree.workspaces
        .iter()
        .flat_map(|ws| ws.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .find(|tab| tab.surface == id)
        .and_then(|tab| tab.browser_source)
}

fn hex_color(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

fn parse_browser_frame(value: &Value) -> Option<RemoteBrowserFrame> {
    let data_b64 = value.get("data")?.as_str()?.to_string();
    let seq = value.get("seq")?.as_u64()?;
    let width = value.get("width").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    let height = value.get("height").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    Some(RemoteBrowserFrame {
        frame: BrowserFrame {
            session_id: String::new(),
            data_b64,
            css_width: width,
            css_height: height,
            seq,
        },
    })
}

#[cfg(test)]
mod tests {
    use std::io::BufRead;
    #[cfg(unix)]
    use std::os::unix::net::UnixStream;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, AtomicU64};

    use ghostty_vt::{Callbacks, Terminal};
    use serde_json::json;

    use super::*;

    #[cfg(unix)]
    fn socket_test_session(stream: UnixStream) -> Arc<RemoteSession> {
        Arc::new(RemoteSession {
            writer: Mutex::new(Box::new(stream)),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            shutdown: AtomicBool::new(false),
            surfaces: Mutex::new(HashMap::new()),
            exited_surfaces: Mutex::new(HashSet::new()),
            tree: Mutex::new(RemoteTreeCache::default()),
            tree_refresh: Mutex::new(()),
            tree_stale: AtomicBool::new(true),
            subscribers: MuxEventBroadcaster::default(),
            frame_logs: Mutex::new(HashMap::new()),
        })
    }

    #[cfg(unix)]
    #[test]
    fn shutdown_cancels_response_wait_before_ordered_release_write() {
        let (client, server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let waiting_session = session.clone();
        let waiting = std::thread::spawn(move || {
            waiting_session.request(json!({"cmd": "mutation"})).unwrap_err()
        });

        let mut peer = BufReader::new(server);
        let mut first_line = String::new();
        peer.read_line(&mut first_line).unwrap();
        let first: Value = serde_json::from_str(&first_line).unwrap();
        assert_eq!(first["cmd"], "mutation");

        session.begin_shutdown();
        assert!(waiting.join().unwrap().to_string().contains("canceled for shutdown"));

        let release_error = session.send_bytes(7, b"release").unwrap_err();
        assert!(release_error.to_string().contains("canceled for shutdown"));
        let mut release_line = String::new();
        peer.read_line(&mut release_line).unwrap();
        let release: Value = serde_json::from_str(&release_line).unwrap();
        assert_eq!(release["cmd"], "send");
        assert_eq!(release["surface"], 7);
        assert_eq!(release["bytes"], "cmVsZWFzZQ==");
        assert!(release["id"].as_u64().unwrap() > first["id"].as_u64().unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn background_refresh_failure_does_not_mark_identity_stale() {
        let (client, server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        session.tree_stale.store(false, Ordering::Release);
        let refreshing = session.clone();
        let refresh = std::thread::spawn(move || refreshing.refresh_tree_background());

        let mut peer = BufReader::new(server);
        let mut line = String::new();
        peer.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        writeln!(
            peer.get_mut(),
            "{}",
            json!({"id": request["id"], "ok": false, "error": "temporary"})
        )
        .unwrap();

        assert!(refresh.join().unwrap().is_err());
        assert!(!session.tree_is_stale());
    }

    #[test]
    fn indexed_title_update_changes_only_the_addressed_surface() {
        let mut cache = RemoteTreeCache::default();
        cache.replace(
            parse_tree(&json!({
                "workspaces": [
                    {
                        "id": 1,
                        "active": true,
                        "screens": [{
                            "id": 2,
                            "active": true,
                            "layout": {"type": "leaf", "pane": 3},
                            "panes": [{
                                "id": 3,
                                "tabs": [{"surface": 4, "title": "old target"}],
                            }],
                        }],
                    },
                    {
                        "id": 5,
                        "screens": [{
                            "id": 6,
                            "layout": {"type": "leaf", "pane": 7},
                            "panes": [{
                                "id": 7,
                                "tabs": [{"surface": 8, "title": "other title"}],
                            }],
                        }],
                    },
                ],
            })),
            0,
        );

        assert!(cache.update_title(4, "server title".to_string()));
        assert_eq!(cache.view.workspaces[0].screens[0].panes[0].tabs[0].title, "server title");
        assert_eq!(cache.view.workspaces[1].screens[0].panes[0].tabs[0].title, "other title");
        assert!(!cache.update_title(99, "missing".to_string()));
    }

    #[test]
    fn refresh_preserves_title_events_that_arrived_after_it_started() {
        let tree = |title: &str| {
            parse_tree(&json!({
                "workspaces": [{
                    "id": 1,
                    "screens": [{
                        "id": 2,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": [{
                            "id": 3,
                            "tabs": [{"surface": 4, "title": title}],
                        }],
                    }],
                }],
            }))
        };
        let mut cache = RemoteTreeCache::default();
        cache.replace(tree("initial"), 0);

        let refresh_generation = cache.title_generation();
        assert!(cache.update_title(4, "event title".to_string()));
        cache.replace(tree("stale snapshot"), refresh_generation);

        assert_eq!(cache.view.workspaces[0].screens[0].panes[0].tabs[0].title, "event title");
    }

    #[test]
    fn refresh_uses_snapshot_for_title_events_that_predate_it() {
        let tree = |title: &str| {
            parse_tree(&json!({
                "workspaces": [{
                    "id": 1,
                    "screens": [{
                        "id": 2,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": [{
                            "id": 3,
                            "tabs": [{"surface": 4, "title": title}],
                        }],
                    }],
                }],
            }))
        };
        let mut cache = RemoteTreeCache::default();
        cache.replace(tree("initial"), 0);
        assert!(cache.update_title(4, "older event".to_string()));

        let refresh_generation = cache.title_generation();
        cache.replace(tree("fresh snapshot"), refresh_generation);

        assert_eq!(cache.view.workspaces[0].screens[0].panes[0].tabs[0].title, "fresh snapshot");
    }

    #[test]
    fn browser_state_without_frame_keeps_cached_frame() {
        let surface = RemoteSurface {
            id: 1,
            kind: SurfaceKind::Browser,
            term: Mutex::new(Terminal::new(10, 5, 100, Callbacks::default()).unwrap()),
            dirty: AtomicBool::new(false),
            server_size: Mutex::new((10, 5)),
            asserted_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        };

        surface.update_browser_frame(&json!({
            "seq": 9,
            "width": 80,
            "height": 40,
            "data": "Zmlyc3Q=",
        }));
        surface.update_browser_state(&json!({
            "url": "https://next.test",
            "title": "next",
            "status": "live",
            "frames_stalled": false,
        }));

        let frame = surface.browser_frame().expect("cached frame");
        assert_eq!(frame.seq, 9);
        assert_eq!(frame.data_b64, "Zmlyc3Q=");
        assert_eq!(surface.browser_url().as_deref(), Some("https://next.test"));
    }

    #[test]
    fn resize_replay_replaces_mirror_with_server_truth_without_duplication() {
        let mut server = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
        for i in 0..12 {
            server.vt_write(format!("srv{i:02}\r\n").as_bytes());
        }
        server.resize(8, 4, 8, 16).unwrap();
        let server_text = server.plain_text().unwrap();
        let server_oldest = server.selection_text_absolute((0, 0), (4, 0)).unwrap();
        assert_eq!(server_oldest, "srv00");
        let replay = server.vt_replay().unwrap();

        let surface = RemoteSurface {
            id: 1,
            kind: SurfaceKind::Pty,
            term: Mutex::new(Terminal::new(20, 6, 100, Callbacks::default()).unwrap()),
            dirty: AtomicBool::new(false),
            server_size: Mutex::new((20, 6)),
            asserted_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        {
            let mut mirror = surface.term.lock().unwrap();
            mirror.vt_write(b"mirror-only\r\nstate\r\n");
        }

        surface.apply_stream_resize(8, 4, Some(&replay));
        let scrollback_rows = {
            let mut mirror = surface.term.lock().unwrap();
            assert_eq!(mirror.plain_text().unwrap(), server_text);
            assert_eq!(mirror.selection_text_absolute((0, 0), (4, 0)).unwrap(), server_oldest);
            mirror.scrollback_rows()
        };

        surface.apply_stream_resize(8, 4, Some(&replay));
        let mut mirror = surface.term.lock().unwrap();
        assert_eq!(mirror.plain_text().unwrap(), server_text);
        assert_eq!(mirror.scrollback_rows(), scrollback_rows);
    }

    #[cfg(unix)]
    #[test]
    fn resized_event_decodes_protocol_replay_field() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let surface = Arc::new(RemoteSurface {
            id: 7,
            kind: SurfaceKind::Pty,
            term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
            dirty: AtomicBool::new(false),
            server_size: Mutex::new((12, 4)),
            asserted_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        session.surfaces.lock().unwrap().insert(7, surface.clone());

        let mut authoritative = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
        for index in 0..8 {
            authoritative.vt_write(format!("authoritative-{index}\r\n").as_bytes());
        }
        authoritative.resize(8, 4, 8, 16).unwrap();
        let expected = authoritative.plain_text().unwrap();
        let replay = authoritative.vt_replay().unwrap();
        session.handle_line(json!({
            "event": "resized",
            "surface": 7,
            "cols": 8,
            "rows": 4,
            "replay": base64::engine::general_purpose::STANDARD.encode(replay),
        }));

        assert_eq!(*surface.server_size.lock().unwrap(), (8, 4));
        assert_eq!(surface.term.lock().unwrap().plain_text().unwrap(), expected);
    }

    #[test]
    fn ordered_resize_replay_recovers_from_stale_initial_replay() {
        let mut server = Terminal::new(12, 3, 100, Callbacks::default()).unwrap();
        server.vt_write(b"\x1b[7m%\x1b[0m");
        let stale_replay = server.vt_replay().unwrap();

        server.resize(10, 3, 8, 16).unwrap();
        let resize_replay = server.vt_replay().unwrap();
        let prompt = b"\r\x1b[Klawrence";
        server.vt_write(prompt);
        let server_text = server.plain_text().unwrap();
        assert!(server_text.lines().next().unwrap_or_default().contains("lawrence"));

        let surface = RemoteSurface {
            id: 1,
            kind: SurfaceKind::Pty,
            term: Mutex::new(Terminal::new(12, 3, 100, Callbacks::default()).unwrap()),
            dirty: AtomicBool::new(false),
            server_size: Mutex::new((12, 3)),
            asserted_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        surface.apply_stream_resize(12, 3, None);
        surface.term.lock().unwrap().vt_write(&stale_replay);
        surface.apply_stream_resize(10, 3, Some(&resize_replay));
        let mut mirror = surface.term.lock().unwrap();
        mirror.vt_write(prompt);

        assert_eq!(mirror.plain_text().unwrap(), server_text);
    }
}
