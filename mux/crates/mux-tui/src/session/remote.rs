//! Remote session client: JSON-lines control socket plus locally
//! mirrored surface terminals (VT replay + live stream).

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine;
use ghostty_vt::{Callbacks, Terminal};
use mux_core::{DefaultColors, MuxEvent, Rgb, SurfaceId, SurfaceKind};
use serde_json::{json, Value};

use super::tree::{parse_tree, TreeView};

const SUPPORTED_PROTOCOL_VERSIONS: &[u64] = &[4, 5];

/// A surface mirrored from a remote session.
pub struct RemoteSurface {
    pub id: SurfaceId,
    pub term: Mutex<Terminal>,
    pub dirty: AtomicBool,
    server_size: Mutex<(u16, u16)>,
    asserted_size: Mutex<Option<(u16, u16)>>,
}

impl RemoteSurface {
    /// Apply the server's authoritative size to the mirror terminal.
    /// Returns true when the local mirror geometry actually changed.
    pub(super) fn set_server_size(&self, cols: u16, rows: u16) -> bool {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let mut size = self.server_size.lock().unwrap();
        if *size == (cols, rows) {
            return false;
        }
        *size = (cols, rows);
        let _ = self.term.lock().unwrap().resize(cols, rows, 8, 16);
        true
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
}

pub struct RemoteSession {
    writer: Mutex<UnixStream>,
    pending: Mutex<HashMap<u64, Sender<Value>>>,
    next_id: AtomicU64,
    surfaces: Mutex<HashMap<SurfaceId, Arc<RemoteSurface>>>,
    tree: Mutex<TreeView>,
    tree_stale: AtomicBool,
    subscribers: Mutex<Vec<Sender<MuxEvent>>>,
}

impl RemoteSession {
    pub fn connect(path: &Path) -> anyhow::Result<Arc<Self>> {
        let stream = UnixStream::connect(path).map_err(|e| {
            anyhow::anyhow!("cannot connect to session socket {}: {e}", path.display())
        })?;
        let read_half = stream.try_clone()?;
        let session = Arc::new(RemoteSession {
            writer: Mutex::new(stream),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            surfaces: Mutex::new(HashMap::new()),
            tree: Mutex::new(TreeView::default()),
            tree_stale: AtomicBool::new(true),
            subscribers: Mutex::new(Vec::new()),
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
                "unsupported cmux-mux protocol {protocol}; this client supports protocols 4 and 5"
            );
        }
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
                    surface.set_server_size(cols, rows);
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
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.set_server_size(cols, rows);
                    surface.dirty.store(true, Ordering::Release);
                    self.emit(MuxEvent::SurfaceOutput(id));
                }
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
            Some("empty") => self.emit(MuxEvent::Empty),
            Some(_) => {}
        }
    }

    pub fn request(&self, mut cmd: Value) -> anyhow::Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        cmd["id"] = json!(id);
        let (tx, rx) = channel();
        self.pending.lock().unwrap().insert(id, tx);

        let mut line = serde_json::to_vec(&cmd)?;
        line.push(b'\n');
        {
            let mut writer = self.writer.lock().unwrap();
            writer.write_all(&line)?;
        }

        let response = rx
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| anyhow::anyhow!("session did not respond"))?;
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
        let (cols, rows) = size.unwrap_or((80, 24));
        if size.is_some() {
            let _ = self.request(
                json!({"cmd": "resize-surface", "surface": id, "cols": cols, "rows": rows}),
            );
        }
        let term = Terminal::new(cols, rows, 10_000, Callbacks::default()).ok()?;
        let surface = Arc::new(RemoteSurface {
            id,
            term: Mutex::new(term),
            dirty: AtomicBool::new(false),
            server_size: Mutex::new((cols, rows)),
            asserted_size: Mutex::new(size.map(|_| (cols, rows))),
        });
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
        Ok(tree)
    }
}

fn hex_color(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}
