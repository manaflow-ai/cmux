//! Frontend-facing session abstraction.
//!
//! The TUI runs against either an in-process mux (`Session::Local`) or a
//! remote one over the control socket (`Session::Remote`). Remote panes
//! are mirrored locally: the server sends a VT replay of each pane's
//! state followed by the live pty stream, and the client feeds both into
//! its own ghostty terminal. Rendering, key encoding, and mode queries
//! then work identically in both cases.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine;
use ghostty_vt::{Callbacks, RenderState, Terminal};
use mux_core::{Mux, MuxEvent, Node, Pane, PaneId, SplitDir};
use serde_json::{json, Value};

#[derive(Clone, Default)]
pub struct TreeView {
    pub workspaces: Vec<WorkspaceView>,
    pub active_workspace: usize,
}

#[derive(Clone)]
pub struct WorkspaceView {
    pub name: String,
    pub tabs: Vec<TabView>,
    pub active_tab: usize,
}

#[derive(Clone)]
pub struct TabView {
    pub layout: Node,
    pub active_pane: PaneId,
    /// Title of the tab's active pane (for the status bar).
    pub title: String,
}

impl TreeView {
    pub fn active_tab(&self) -> Option<&TabView> {
        let ws = self.workspaces.get(self.active_workspace)?;
        ws.tabs.get(ws.active_tab)
    }
}

pub enum Session {
    Local(Arc<Mux>),
    Remote(Arc<RemoteSession>),
}

#[derive(Clone)]
pub enum PaneHandle {
    Local(Arc<Pane>),
    Remote(Arc<RemotePane>, Arc<RemoteSession>),
}

impl Session {
    /// Make sure the session has at least one workspace to show.
    pub fn ensure_initial(&self) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.new_workspace(None)?;
                Ok(())
            }
            Session::Remote(remote) => {
                if remote.tree()?.workspaces.is_empty() {
                    remote.request(json!({"cmd": "new-workspace"}))?;
                }
                Ok(())
            }
        }
    }

    pub fn events(&self) -> Receiver<MuxEvent> {
        match self {
            Session::Local(mux) => mux.subscribe(),
            Session::Remote(remote) => remote.subscribe(),
        }
    }

    pub fn tree(&self) -> TreeView {
        match self {
            Session::Local(mux) => mux.with_state(|workspaces, active_ws, panes| TreeView {
                active_workspace: active_ws,
                workspaces: workspaces
                    .iter()
                    .map(|ws| WorkspaceView {
                        name: ws.name.clone(),
                        active_tab: ws.active_tab,
                        tabs: ws
                            .tabs
                            .iter()
                            .map(|tab| TabView {
                                layout: tab.root.clone(),
                                active_pane: tab.active_pane,
                                title: panes
                                    .get(&tab.active_pane)
                                    .map(|p| p.title())
                                    .unwrap_or_default(),
                            })
                            .collect(),
                    })
                    .collect(),
            }),
            Session::Remote(remote) => remote.tree().unwrap_or_default(),
        }
    }

    pub fn pane(&self, id: PaneId) -> Option<PaneHandle> {
        match self {
            Session::Local(mux) => mux.pane(id).map(PaneHandle::Local),
            Session::Remote(remote) => remote
                .ensure_pane(id)
                .map(|pane| PaneHandle::Remote(pane, remote.clone())),
        }
    }

    pub fn new_tab(&self) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.new_tab(None, None).map(|_| ()),
            Session::Remote(remote) => remote.request(json!({"cmd": "new-tab"})).map(|_| ()),
        }
    }

    pub fn new_workspace(&self) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.new_workspace(None).map(|_| ()),
            Session::Remote(remote) => remote.request(json!({"cmd": "new-workspace"})).map(|_| ()),
        }
    }

    pub fn split(&self, pane: PaneId, dir: SplitDir) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.split(pane, dir).map(|_| ()),
            Session::Remote(remote) => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                remote.request(json!({"cmd": "split", "pane": pane, "dir": dir})).map(|_| ())
            }
        }
    }

    pub fn close_pane(&self, pane: PaneId) {
        match self {
            Session::Local(mux) => mux.close_pane(pane),
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "kill-pane", "pane": pane}));
            }
        }
    }

    /// Remove an exited pane from the tree. The remote server reaps its
    /// own dead panes; the client only drops its mirror.
    pub fn reap_pane(&self, pane: PaneId) {
        match self {
            Session::Local(mux) => mux.close_pane(pane),
            Session::Remote(remote) => remote.drop_pane(pane),
        }
    }

    pub fn focus_pane(&self, pane: PaneId) {
        match self {
            Session::Local(mux) => {
                mux.focus_pane(pane);
            }
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "focus-pane", "pane": pane}));
            }
        }
    }

    pub fn select_tab(&self, index: Option<usize>, delta: Option<isize>) {
        match self {
            Session::Local(mux) => mux.select_tab(index, delta),
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "select-tab", "index": index, "delta": delta}));
            }
        }
    }

    pub fn select_workspace(&self, index: Option<usize>, delta: Option<isize>) {
        match self {
            Session::Local(mux) => mux.select_workspace(index, delta),
            Session::Remote(remote) => {
                let _ = remote
                    .request(json!({"cmd": "select-workspace", "index": index, "delta": delta}));
            }
        }
    }
}

impl PaneHandle {
    pub fn write_bytes(&self, bytes: &[u8]) {
        match self {
            PaneHandle::Local(pane) => {
                let _ = pane.write_bytes(bytes);
            }
            PaneHandle::Remote(pane, session) => {
                let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
                let _ = session.request(json!({"cmd": "send", "pane": pane.id, "bytes": encoded}));
            }
        }
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        match self {
            PaneHandle::Local(pane) => pane.resize(cols, rows),
            PaneHandle::Remote(pane, session) => {
                if pane.set_size(cols, rows) {
                    let _ = session.request(
                        json!({"cmd": "resize-pane", "pane": pane.id, "cols": cols, "rows": rows}),
                    );
                }
            }
        }
    }

    pub fn take_dirty(&self) -> bool {
        match self {
            PaneHandle::Local(pane) => pane.take_dirty(),
            PaneHandle::Remote(pane, _) => pane.dirty.swap(false, Ordering::AcqRel),
        }
    }

    pub fn snapshot(&self, rs: &mut RenderState) -> ghostty_vt::Result<()> {
        match self {
            PaneHandle::Local(pane) => pane.snapshot(rs),
            PaneHandle::Remote(pane, _) => rs.update(&mut pane.term.lock().unwrap()),
        }
    }

    /// Run `f` against the pane's terminal state (the mirror, for remote
    /// panes — modes and keyboard state replay there too).
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> R {
        match self {
            PaneHandle::Local(pane) => pane.with_terminal(f),
            PaneHandle::Remote(pane, _) => f(&mut pane.term.lock().unwrap()),
        }
    }
}

/// A pane mirrored from a remote session.
pub struct RemotePane {
    pub id: PaneId,
    pub term: Mutex<Terminal>,
    pub dirty: AtomicBool,
    size: Mutex<(u16, u16)>,
}

impl RemotePane {
    /// Returns true when the size actually changed.
    fn set_size(&self, cols: u16, rows: u16) -> bool {
        let mut size = self.size.lock().unwrap();
        if *size == (cols, rows) {
            return false;
        }
        *size = (cols, rows);
        let _ = self.term.lock().unwrap().resize(cols, rows, 8, 16);
        true
    }
}

pub struct RemoteSession {
    writer: Mutex<UnixStream>,
    pending: Mutex<HashMap<u64, Sender<Value>>>,
    next_id: AtomicU64,
    panes: Mutex<HashMap<PaneId, Arc<RemotePane>>>,
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
            panes: Mutex::new(HashMap::new()),
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
        match value.get("event").and_then(|v| v.as_str()) {
            None => {
                // Response: route to the waiting request.
                let Some(id) = value.get("id").and_then(|v| v.as_u64()) else { return };
                if let Some(tx) = self.pending.lock().unwrap().remove(&id) {
                    let _ = tx.send(value);
                }
            }
            Some("vt-state") => {
                let Some(pane_id) = value.get("pane").and_then(|v| v.as_u64()) else { return };
                let cols = value.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
                let rows = value.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
                let Some(data) = value.get("data").and_then(|v| v.as_str()) else { return };
                let Ok(replay) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    return;
                };
                if let Some(pane) = self.panes.lock().unwrap().get(&pane_id).cloned() {
                    pane.set_size(cols, rows);
                    let mut term = pane.term.lock().unwrap();
                    term.vt_write(&replay);
                    drop(term);
                    pane.dirty.store(true, Ordering::Release);
                }
                self.emit(MuxEvent::PaneOutput(pane_id));
            }
            Some("output") => {
                let Some(pane_id) = value.get("pane").and_then(|v| v.as_u64()) else { return };
                let Some(data) = value.get("data").and_then(|v| v.as_str()) else { return };
                let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    return;
                };
                if let Some(pane) = self.panes.lock().unwrap().get(&pane_id).cloned() {
                    pane.term.lock().unwrap().vt_write(&bytes);
                    if !pane.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::PaneOutput(pane_id));
                    }
                }
            }
            Some("tree-changed") => {
                self.tree_stale.store(true, Ordering::Release);
                self.emit(MuxEvent::TreeChanged);
            }
            Some("pane-exited") => {
                if let Some(pane_id) = value.get("pane").and_then(|v| v.as_u64()) {
                    self.tree_stale.store(true, Ordering::Release);
                    self.emit(MuxEvent::PaneExited(pane_id));
                }
            }
            Some("title-changed") => {
                if let Some(pane_id) = value.get("pane").and_then(|v| v.as_u64()) {
                    self.tree_stale.store(true, Ordering::Release);
                    self.emit(MuxEvent::TitleChanged(pane_id));
                }
            }
            Some("bell") => {
                if let Some(pane_id) = value.get("pane").and_then(|v| v.as_u64()) {
                    self.emit(MuxEvent::Bell(pane_id));
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
            let error = response
                .get("error")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error");
            anyhow::bail!("{error}")
        }
    }

    /// Mirror for a pane, attaching on first use.
    pub fn ensure_pane(self: &Arc<Self>, id: PaneId) -> Option<Arc<RemotePane>> {
        if let Some(pane) = self.panes.lock().unwrap().get(&id) {
            return Some(pane.clone());
        }
        let term = Terminal::new(80, 24, 10_000, Callbacks::default()).ok()?;
        let pane = Arc::new(RemotePane {
            id,
            term: Mutex::new(term),
            dirty: AtomicBool::new(false),
            size: Mutex::new((80, 24)),
        });
        self.panes.lock().unwrap().insert(id, pane.clone());
        // The vt-state event that follows fills the mirror.
        if self.request(json!({"cmd": "attach-pane", "pane": id})).is_err() {
            self.panes.lock().unwrap().remove(&id);
            return None;
        }
        Some(pane)
    }

    pub fn drop_pane(&self, id: PaneId) {
        self.panes.lock().unwrap().remove(&id);
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

fn parse_layout(value: &Value) -> Option<Node> {
    match value.get("type")?.as_str()? {
        "leaf" => Some(Node::Leaf(value.get("pane")?.as_u64()?)),
        "split" => {
            let dir = match value.get("dir")?.as_str()? {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                _ => return None,
            };
            Some(Node::Split {
                dir,
                ratio: value.get("ratio")?.as_f64()? as f32,
                a: Box::new(parse_layout(value.get("a")?)?),
                b: Box::new(parse_layout(value.get("b")?)?),
            })
        }
        _ => None,
    }
}

fn parse_tree(data: &Value) -> TreeView {
    let mut tree = TreeView::default();
    let Some(workspaces) = data.get("workspaces").and_then(|v| v.as_array()) else {
        return tree;
    };
    for (i, ws) in workspaces.iter().enumerate() {
        if ws.get("active").and_then(|v| v.as_bool()) == Some(true) {
            tree.active_workspace = i;
        }
        let mut view = WorkspaceView {
            name: ws
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            tabs: Vec::new(),
            active_tab: 0,
        };
        if let Some(tabs) = ws.get("tabs").and_then(|v| v.as_array()) {
            for (t, tab) in tabs.iter().enumerate() {
                if tab.get("active").and_then(|v| v.as_bool()) == Some(true) {
                    view.active_tab = t;
                }
                let Some(layout) = tab.get("layout").and_then(parse_layout) else { continue };
                let active_pane = tab.get("active_pane").and_then(|v| v.as_u64()).unwrap_or(0);
                let title = tab
                    .get("panes")
                    .and_then(|v| v.as_array())
                    .and_then(|panes| {
                        panes.iter().find(|p| {
                            p.get("id").and_then(|v| v.as_u64()) == Some(active_pane)
                        })
                    })
                    .and_then(|p| p.get("title"))
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                view.tabs.push(TabView { layout, active_pane, title });
            }
        }
        tree.workspaces.push(view);
    }
    tree
}
