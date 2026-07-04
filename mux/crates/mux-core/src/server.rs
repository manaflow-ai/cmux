//! Control socket: a JSON-lines protocol over a unix domain socket.
//!
//! This is the attach surface for external frontends (the cmux app, the
//! bundled `cmux-mux attach` client, scripts). One JSON request per line;
//! every request gets one JSON response line. Two commands additionally
//! turn the connection full-duplex:
//!
//! - `subscribe` — the server pushes `{"event":...}` lines (tree-changed,
//!   surface-output, surface-exited, title-changed, bell) interleaved
//!   with responses.
//! - `attach-surface` — the server sends `{"event":"vt-state"}` with a
//!   base64 VT replay of the surface's current state, then a live
//!   `{"event":"output"}` stream of every subsequent pty byte. Replaying
//!   state then stream into a fresh terminal reproduces the surface
//!   exactly.
//!
//! ```text
//! {"id":1,"cmd":"identify"}
//! {"id":1,"ok":true,"data":{"app":"cmux-mux","session":"main",...}}
//! ```

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::model::{Screen, State};
use crate::{Mux, MuxEvent, Node, PaneId, ScreenId, SplitDir, SurfaceId, WorkspaceId};

pub const PROTOCOL_VERSION: u32 = 4;

/// Default socket path for a session: `$TMPDIR/cmux-mux-<uid>/<session>.sock`.
pub fn default_socket_path(session: &str) -> PathBuf {
    let uid = unsafe { libc::getuid() };
    let dir = std::env::temp_dir().join(format!("cmux-mux-{uid}"));
    dir.join(format!("{session}.sock"))
}

#[derive(Deserialize)]
struct Request {
    id: Option<Value>,
    #[serde(flatten)]
    cmd: Command,
}

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
enum Command {
    Identify,
    ListWorkspaces,
    Send {
        surface: SurfaceId,
        #[serde(default)]
        text: Option<String>,
        /// Base64-encoded raw bytes, written verbatim to the pty.
        #[serde(default)]
        bytes: Option<String>,
    },
    ReadScreen {
        surface: SurfaceId,
    },
    /// One-shot VT replay of the surface's current state (base64).
    VtState {
        surface: SurfaceId,
    },
    /// New tab in a pane (default: the active pane).
    NewTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cwd: Option<String>,
        /// Expected content size in cells (spawn-at-size avoids shell
        /// redraw artifacts).
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    NewWorkspace {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    /// New screen in a workspace (default: the active one).
    NewScreen {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    Split {
        pane: PaneId,
        /// "right" or "down"
        dir: String,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    /// Close one tab.
    CloseSurface {
        surface: SurfaceId,
    },
    /// Close a pane and all its tabs.
    ClosePane {
        pane: PaneId,
    },
    CloseScreen {
        screen: ScreenId,
    },
    CloseWorkspace {
        workspace: WorkspaceId,
    },
    RenamePane {
        pane: PaneId,
        /// Empty clears the name (falls back to the tab title).
        name: String,
    },
    RenameScreen {
        screen: ScreenId,
        /// Empty clears the name (falls back to the screen number).
        name: String,
    },
    RenameWorkspace {
        workspace: WorkspaceId,
        name: String,
    },
    ResizeSurface {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    },
    FocusPane {
        pane: PaneId,
    },
    /// Select a tab within a pane (default: the active pane).
    SelectTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    /// Select a screen within the active workspace.
    SelectScreen {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    SelectWorkspace {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    /// Stream mux events on this connection.
    Subscribe,
    /// Stream a surface: vt-state event followed by live output events.
    AttachSurface {
        surface: SurfaceId,
    },
    /// Scroll a surface's viewport by a row delta (negative is up).
    ScrollSurface {
        surface: SurfaceId,
        delta: isize,
    },
}

#[derive(Serialize)]
struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<Value>,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

/// Line-oriented shared writer: responses and event streams interleave
/// whole lines.
#[derive(Clone)]
struct LineWriter(Arc<Mutex<UnixStream>>);

impl LineWriter {
    fn send(&self, value: &Value) -> std::io::Result<()> {
        let mut bytes = serde_json::to_vec(value)?;
        bytes.push(b'\n');
        let mut stream = self.0.lock().unwrap();
        stream.write_all(&bytes)
    }
}

/// Bind the socket and serve connections on background threads.
pub fn serve(mux: Arc<Mux>, path: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    let path = path.unwrap_or_else(|| default_socket_path(&mux.session));
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    // Refuse to clobber a live socket; remove a stale one.
    if path.exists() {
        match UnixStream::connect(&path) {
            Ok(_) => anyhow::bail!(
                "session socket {} is already in use (another instance running?)",
                path.display()
            ),
            Err(_) => std::fs::remove_file(&path)?,
        }
    }
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;

    std::thread::Builder::new().name("mux-server".into()).spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { continue };
            let mux = mux.clone();
            let _ = std::thread::Builder::new()
                .name("mux-conn".into())
                .spawn(move || handle_connection(mux, stream));
        }
    })?;
    Ok(path)
}

fn handle_connection(mux: Arc<Mux>, stream: UnixStream) {
    let Ok(write_half) = stream.try_clone() else { return };
    let writer = LineWriter(Arc::new(Mutex::new(write_half)));
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Request>(&line) {
            Ok(req) => {
                let id = req.id.clone();
                match handle_command(&mux, req.cmd, &writer) {
                    Ok(data) => Response { id, ok: true, data: Some(data), error: None },
                    Err(e) => Response { id, ok: false, data: None, error: Some(e.to_string()) },
                }
            }
            Err(e) => Response {
                id: None,
                ok: false,
                data: None,
                error: Some(format!("bad request: {e}")),
            },
        };
        let Ok(value) = serde_json::to_value(&response) else { break };
        if writer.send(&value).is_err() {
            break;
        }
    }
}

fn node_json(node: &Node) -> Value {
    match node {
        Node::Leaf(id) => json!({ "type": "leaf", "pane": id }),
        Node::Split { dir, ratio, a, b } => json!({
            "type": "split",
            "dir": match dir { SplitDir::Right => "right", SplitDir::Down => "down" },
            "ratio": ratio,
            "a": node_json(a),
            "b": node_json(b),
        }),
    }
}

fn pane_json(state: &State, id: PaneId) -> Value {
    let Some(pane) = state.panes.get(&id) else {
        return json!({ "id": id, "dead": true });
    };
    json!({
        "id": id,
        "name": pane.name,
        "active_tab": pane.active_tab,
        "tabs": pane.tabs.iter().map(|sid| {
            let surface = state.surfaces.get(sid);
            json!({
                "surface": sid,
                "title": surface.map(|s| s.title()).unwrap_or_default(),
                "size": surface.map(|s| {
                    let (c, r) = s.size();
                    json!({"cols": c, "rows": r})
                }),
                "dead": surface.map(|s| s.is_dead()).unwrap_or(true),
            })
        }).collect::<Vec<_>>(),
    })
}

fn screen_json(state: &State, screen: &Screen, active: bool) -> Value {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    json!({
        "id": screen.id,
        "name": screen.name,
        "active": active,
        "active_pane": screen.active_pane,
        "layout": node_json(&screen.root),
        "panes": pane_ids.iter().map(|id| pane_json(state, *id)).collect::<Vec<_>>(),
    })
}

fn workspaces_json(state: &State) -> Value {
    json!({
        "workspaces": state.workspaces.iter().enumerate().map(|(i, ws)| {
            json!({
                "id": ws.id,
                "name": ws.name,
                "active": i == state.active_workspace,
                "screens": ws.screens.iter().enumerate().map(|(s, screen)| {
                    screen_json(state, screen, s == ws.active_screen)
                }).collect::<Vec<_>>(),
            })
        }).collect::<Vec<_>>(),
    })
}

fn get_surface(mux: &Mux, id: SurfaceId) -> anyhow::Result<Arc<crate::Surface>> {
    mux.surface(id).ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))
}

fn handle_command(mux: &Arc<Mux>, cmd: Command, writer: &LineWriter) -> anyhow::Result<Value> {
    match cmd {
        Command::Identify => Ok(json!({
            "app": "cmux-mux",
            "version": env!("CARGO_PKG_VERSION"),
            "protocol": PROTOCOL_VERSION,
            "session": mux.session,
            "pid": std::process::id(),
        })),
        Command::ListWorkspaces => Ok(mux.with_state(workspaces_json)),
        Command::Send { surface, text, bytes } => {
            let surface = get_surface(mux, surface)?;
            if let Some(text) = text {
                surface.write_bytes(text.as_bytes())?;
            }
            if let Some(b64) = bytes {
                let raw = base64::engine::general_purpose::STANDARD.decode(b64)?;
                surface.write_bytes(&raw)?;
            }
            Ok(json!({}))
        }
        Command::ReadScreen { surface } => {
            let surface = get_surface(mux, surface)?;
            let text = surface.with_terminal(|t| t.plain_text())?;
            Ok(json!({ "text": text }))
        }
        Command::VtState { surface } => {
            let surface = get_surface(mux, surface)?;
            let (cols, rows, replay) = surface
                .with_terminal(|t| t.vt_replay().map(|replay| (t.cols(), t.rows(), replay)))?;
            Ok(json!({
                "cols": cols,
                "rows": rows,
                "data": base64::engine::general_purpose::STANDARD.encode(replay),
            }))
        }
        Command::NewTab { pane, cwd, cols, rows } => {
            let surface = mux.new_tab(pane, cwd, cols.zip(rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::NewWorkspace { name, cols, rows } => {
            let surface = mux.new_workspace(name, cols.zip(rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::NewScreen { workspace, cols, rows } => {
            let surface = mux.new_screen(workspace, cols.zip(rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::Split { pane, dir, cols, rows } => {
            let dir = match dir.as_str() {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                other => anyhow::bail!("bad dir {other:?} (want \"right\" or \"down\")"),
            };
            let surface = mux.split(pane, dir, cols.zip(rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::CloseSurface { surface } => {
            get_surface(mux, surface)?;
            mux.close_surface(surface);
            Ok(json!({}))
        }
        Command::ClosePane { pane } => {
            if !mux.with_state(|s| s.panes.contains_key(&pane)) {
                anyhow::bail!("unknown pane {pane}");
            }
            mux.close_pane(pane);
            Ok(json!({}))
        }
        Command::CloseScreen { screen } => {
            if !mux.close_screen(screen) {
                anyhow::bail!("unknown screen {screen}");
            }
            Ok(json!({}))
        }
        Command::CloseWorkspace { workspace } => {
            if !mux.close_workspace(workspace) {
                anyhow::bail!("unknown workspace {workspace}");
            }
            Ok(json!({}))
        }
        Command::RenamePane { pane, name } => {
            if !mux.rename_pane(pane, name) {
                anyhow::bail!("unknown pane {pane}");
            }
            Ok(json!({}))
        }
        Command::RenameScreen { screen, name } => {
            if !mux.rename_screen(screen, name) {
                anyhow::bail!("unknown screen {screen}");
            }
            Ok(json!({}))
        }
        Command::RenameWorkspace { workspace, name } => {
            if !mux.rename_workspace(workspace, name) {
                anyhow::bail!("unknown workspace {workspace}");
            }
            Ok(json!({}))
        }
        Command::ResizeSurface { surface, cols, rows } => {
            let surface = get_surface(mux, surface)?;
            surface.resize(cols, rows);
            Ok(json!({}))
        }
        Command::FocusPane { pane } => {
            if !mux.focus_pane(pane) {
                anyhow::bail!("unknown pane {pane}");
            }
            Ok(json!({}))
        }
        Command::SelectTab { pane, index, delta } => {
            mux.select_tab(pane, index, delta);
            Ok(json!({}))
        }
        Command::SelectScreen { index, delta } => {
            mux.select_screen(index, delta);
            Ok(json!({}))
        }
        Command::SelectWorkspace { index, delta } => {
            mux.select_workspace(index, delta);
            Ok(json!({}))
        }
        Command::ScrollSurface { surface, delta } => {
            let surface = get_surface(mux, surface)?;
            surface.with_terminal(|t| t.scroll_delta(delta));
            Ok(json!({}))
        }
        Command::Subscribe => {
            let events = mux.subscribe();
            let writer = writer.clone();
            std::thread::Builder::new().name("mux-events-out".into()).spawn(move || {
                while let Ok(event) = events.recv() {
                    let value = match &event {
                        MuxEvent::SurfaceOutput(id) => {
                            json!({"event": "surface-output", "surface": id})
                        }
                        MuxEvent::SurfaceExited(id) => {
                            json!({"event": "surface-exited", "surface": id})
                        }
                        MuxEvent::TitleChanged(id) => {
                            json!({"event": "title-changed", "surface": id})
                        }
                        MuxEvent::Bell(id) => json!({"event": "bell", "surface": id}),
                        MuxEvent::TreeChanged => json!({"event": "tree-changed"}),
                        MuxEvent::Empty => json!({"event": "empty"}),
                    };
                    if writer.send(&value).is_err() {
                        break;
                    }
                }
            })?;
            Ok(json!({}))
        }
        Command::AttachSurface { surface: surface_id } => {
            let surface = get_surface(mux, surface_id)?;
            let attach = surface.attach_stream()?;
            writer.send(&json!({
                "event": "vt-state",
                "surface": surface_id,
                "cols": attach.cols,
                "rows": attach.rows,
                "data": base64::engine::general_purpose::STANDARD.encode(attach.replay),
            }))?;
            let writer = writer.clone();
            std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                while let Ok(chunk) = attach.stream.recv() {
                    let value = json!({
                        "event": "output",
                        "surface": surface_id,
                        "data": base64::engine::general_purpose::STANDARD.encode(chunk),
                    });
                    if writer.send(&value).is_err() {
                        break;
                    }
                }
                // Surface gone (or reader stopped): signal end of stream.
                let _ = writer.send(&json!({"event": "detached", "surface": surface_id}));
            })?;
            Ok(json!({}))
        }
    }
}

/// Remove the socket file (call on clean shutdown).
pub fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
}
