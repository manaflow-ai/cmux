//! Remote session client: JSON-lines control socket plus locally
//! mirrored surface terminals (VT replay + live stream).

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use ghostty_vt::{Callbacks, Terminal};
use mux_core::{
    platform::transport, BrowserFrame, BrowserSource, BrowserStatus, DefaultColors, MuxEvent, Rgb,
    SurfaceId, SurfaceKind,
};
use serde_json::{json, Value};

use super::tree::{parse_tree, TreeView};

const SUPPORTED_PROTOCOL_VERSIONS: &[u64] = &[4, 5, 6];
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

/// A surface mirrored from a remote session.
pub struct RemoteSurface {
    pub id: SurfaceId,
    pub kind: SurfaceKind,
    pub term: Mutex<Terminal>,
    pub dirty: AtomicBool,
    size: Mutex<(u16, u16)>,
    browser: Mutex<RemoteBrowserState>,
}

impl RemoteSurface {
    /// Returns true when the size actually changed.
    pub(super) fn set_size(&self, cols: u16, rows: u16) -> bool {
        let mut size = self.size.lock().unwrap();
        if *size == (cols, rows) {
            return false;
        }
        *size = (cols, rows);
        let _ = self.term.lock().unwrap().resize(cols, rows, 8, 16);
        true
    }

    pub(super) fn apply_stream_resize(&self, cols: u16, rows: u16, replay: Option<&[u8]>) {
        let (cols, rows) = (cols.max(1), rows.max(1));
        *self.size.lock().unwrap() = (cols, rows);
        let mut term = self.term.lock().unwrap();
        if let Some(replay) = replay {
            if let Ok(mut fresh) = Terminal::new(cols, rows, 10_000, Callbacks::default()) {
                fresh.vt_write(replay);
                *term = fresh;
                return;
            }
        }
        let _ = term.resize(cols, rows, 8, 16);
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
    surfaces: Mutex<HashMap<SurfaceId, Arc<RemoteSurface>>>,
    tree: Mutex<TreeView>,
    tree_stale: AtomicBool,
    subscribers: Mutex<Vec<Sender<MuxEvent>>>,
    protocol: AtomicU64,
}

impl RemoteSession {
    pub fn connect(path: &Path) -> anyhow::Result<Arc<Self>> {
        let stream = transport::connect(path).map_err(|e| {
            anyhow::anyhow!("cannot connect to session socket {}: {e}", path.display())
        })?;
        let read_half = stream.try_clone_box()?;
        let session = Arc::new(RemoteSession {
            writer: Mutex::new(stream),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            surfaces: Mutex::new(HashMap::new()),
            tree: Mutex::new(TreeView::default()),
            tree_stale: AtomicBool::new(true),
            subscribers: Mutex::new(Vec::new()),
            protocol: AtomicU64::new(0),
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
        if ident.get("app").and_then(|v| v.as_str()) != Some("cmux-mux") {
            anyhow::bail!("socket endpoint is not a cmux-mux session");
        }
        let protocol = ident.get("protocol").and_then(|v| v.as_u64()).unwrap_or(0);
        if !SUPPORTED_PROTOCOL_VERSIONS.contains(&protocol) {
            anyhow::bail!(
                "unsupported cmux-mux protocol {protocol}; this client supports protocols 4, 5, and 6"
            );
        }
        session.protocol.store(protocol, Ordering::Release);
        session.request(json!({"cmd": "subscribe"}))?;
        Ok(session)
    }

    fn emit(&self, event: MuxEvent) {
        let mut subs = self.subscribers.lock().unwrap();
        subs.retain(|tx| tx.send(event.clone()).is_ok());
    }

    pub fn subscribe(&self) -> Receiver<MuxEvent> {
        let (tx, rx) = channel();
        self.subscribers.lock().unwrap().push(tx);
        rx
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
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.set_size(cols, rows);
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
                    .get("data")
                    .and_then(|v| v.as_str())
                    .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok());
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
                    surface.set_size(cols, rows);
                    surface.update_browser_state(&value);
                    surface.dirty.store(true, Ordering::Release);
                }
                self.emit(MuxEvent::TitleChanged(id));
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
            Some("surface-exited") => {
                if let Some(id) = surface_id() {
                    self.tree_stale.store(true, Ordering::Release);
                    self.emit(MuxEvent::SurfaceExited(id));
                }
            }
            Some("title-changed") => {
                if let Some(id) = surface_id() {
                    self.tree_stale.store(true, Ordering::Release);
                    self.emit(MuxEvent::TitleChanged(id));
                }
            }
            Some("bell") => {
                if let Some(id) = surface_id() {
                    self.emit(MuxEvent::Bell(id));
                }
            }
            Some("status") => {
                if let Some(message) = value.get("message").and_then(|v| v.as_str()) {
                    self.emit(MuxEvent::Status(message.to_string()));
                }
            }
            Some("empty") => self.emit(MuxEvent::Empty),
            Some(_) => {}
        }
    }

    pub fn request(&self, mut cmd: Value) -> anyhow::Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        cmd["id"] = json!(id);
        let mut line = serde_json::to_vec(&cmd)?;
        line.push(b'\n');

        let (tx, rx) = channel();
        self.pending.lock().unwrap().insert(id, tx);
        if let Err(err) = self.writer.lock().unwrap().write_all(&line) {
            self.pending.lock().unwrap().remove(&id);
            return Err(err.into());
        }

        let response = match rx.recv_timeout(Duration::from_secs(10)) {
            Ok(response) => response,
            Err(_) => {
                // Drop the pending entry so a half-open session does not
                // accumulate abandoned senders (and a late response is
                // not delivered to a receiver nobody holds).
                self.pending.lock().unwrap().remove(&id);
                anyhow::bail!("session did not respond")
            }
        };
        if response.get("ok").and_then(|v| v.as_bool()) == Some(true) {
            Ok(response.get("data").cloned().unwrap_or(Value::Null))
        } else {
            let error = response.get("error").and_then(|v| v.as_str()).unwrap_or("unknown error");
            anyhow::bail!("{error}")
        }
    }

    pub fn send_bytes(&self, surface: SurfaceId, bytes: &[u8]) {
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        let _ = self.request(json!({"cmd": "send", "surface": surface, "bytes": encoded}));
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) {
        let _ = self.request(json!({
            "cmd": "set-cell-pixels",
            "width_px": width_px,
            "height_px": height_px,
        }));
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
        self.protocol.load(Ordering::Acquire) >= 6
    }

    /// Mirror for a surface, attaching on first use. `size` is the cell
    /// size the frontend will render at: the server surface is resized
    /// BEFORE the replay is taken, so the shell's resize redraw happens
    /// once server-side and the replay arrives at final geometry (no
    /// mirror reflow, no repeated prompt repaint).
    pub fn ensure_surface(
        self: &Arc<Self>,
        id: SurfaceId,
        size: Option<(u16, u16)>,
    ) -> Option<Arc<RemoteSurface>> {
        if let Some(surface) = self.surfaces.lock().unwrap().get(&id) {
            return Some(surface.clone());
        }
        let (kind, source) = {
            let tree = self.tree.lock().unwrap();
            (tree.surface_kind(id), browser_source_from_tree(&tree, id))
        };
        let (cols, rows) = size.unwrap_or((80, 24));
        if size.is_some() {
            let _ = self.request(
                json!({"cmd": "resize-surface", "surface": id, "cols": cols, "rows": rows}),
            );
        }
        let term = Terminal::new(cols, rows, 10_000, Callbacks::default()).ok()?;
        let surface = Arc::new(RemoteSurface {
            id,
            kind,
            term: Mutex::new(term),
            dirty: AtomicBool::new(false),
            size: Mutex::new((cols, rows)),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        surface.update_browser_source(source);
        self.surfaces.lock().unwrap().insert(id, surface.clone());
        // The vt-state event that follows fills the mirror.
        if self.request(json!({"cmd": "attach-surface", "surface": id})).is_err() {
            self.surfaces.lock().unwrap().remove(&id);
            return None;
        }
        Some(surface)
    }

    pub fn drop_surface(&self, id: SurfaceId) {
        self.surfaces.lock().unwrap().remove(&id);
    }

    pub fn surface_kind(&self, id: SurfaceId) -> SurfaceKind {
        self.tree.lock().unwrap().surface_kind(id)
    }

    pub fn tree(&self) -> anyhow::Result<TreeView> {
        if !self.tree_stale.swap(false, Ordering::AcqRel) {
            return Ok(self.tree.lock().unwrap().clone());
        }
        let data = match self.request(json!({"cmd": "list-workspaces"})) {
            Ok(data) => data,
            Err(e) => {
                // Retry next frame rather than caching a bad tree.
                self.tree_stale.store(true, Ordering::Release);
                return Err(e);
            }
        };
        let tree = parse_tree(&data);
        *self.tree.lock().unwrap() = tree.clone();
        let surfaces = self.surfaces.lock().unwrap().clone();
        for (id, surface) in surfaces {
            surface.update_browser_source(browser_source_from_tree(&tree, id));
        }
        Ok(tree)
    }
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
    use std::sync::atomic::AtomicBool;
    use std::sync::Mutex;

    use ghostty_vt::{Callbacks, Terminal};
    use serde_json::json;

    use super::*;

    #[test]
    fn browser_state_without_frame_keeps_cached_frame() {
        let surface = RemoteSurface {
            id: 1,
            kind: SurfaceKind::Browser,
            term: Mutex::new(Terminal::new(10, 5, 100, Callbacks::default()).unwrap()),
            dirty: AtomicBool::new(false),
            size: Mutex::new((10, 5)),
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
}
