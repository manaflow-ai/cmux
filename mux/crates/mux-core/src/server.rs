//! Control socket: a JSON-lines protocol over a unix domain socket.
//!
//! This is the attach surface for external frontends (the cmux app, the
//! bundled `cmux-mux attach` client, scripts). One JSON request per line;
//! every request gets one JSON response line. Two commands additionally
//! turn the connection full-duplex:
//!
//! - `subscribe` — the server pushes `{"event":...}` lines (tree-changed,
//!   pane-output, pane-exited, title-changed, bell) interleaved with
//!   responses.
//! - `attach-pane` — the server sends `{"event":"vt-state"}` with a
//!   base64 VT replay of the pane's current state, then a live
//!   `{"event":"output"}` stream of every subsequent pty byte. Replaying
//!   state then stream into a fresh terminal reproduces the pane exactly.
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

use crate::{Mux, MuxEvent, Node, PaneId, SplitDir, WorkspaceId};

pub const PROTOCOL_VERSION: u32 = 2;

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
        pane: PaneId,
        #[serde(default)]
        text: Option<String>,
        /// Base64-encoded raw bytes, written verbatim to the pty.
        #[serde(default)]
        bytes: Option<String>,
    },
    ReadScreen {
        pane: PaneId,
    },
    /// One-shot VT replay of the pane's current state (base64).
    VtState {
        pane: PaneId,
    },
    NewTab {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        cwd: Option<String>,
    },
    NewWorkspace {
        #[serde(default)]
        name: Option<String>,
    },
    Split {
        pane: PaneId,
        /// "right" or "down"
        dir: String,
    },
    KillPane {
        pane: PaneId,
    },
    ResizePane {
        pane: PaneId,
        cols: u16,
        rows: u16,
    },
    FocusPane {
        pane: PaneId,
    },
    SelectTab {
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
    /// Stream a pane: vt-state event followed by live output events.
    AttachPane {
        pane: PaneId,
    },
    /// Scroll a pane's viewport by a row delta (negative is up).
    ScrollPane {
        pane: PaneId,
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

fn handle_command(mux: &Arc<Mux>, cmd: Command, writer: &LineWriter) -> anyhow::Result<Value> {
    match cmd {
        Command::Identify => Ok(json!({
            "app": "cmux-mux",
            "version": env!("CARGO_PKG_VERSION"),
            "protocol": PROTOCOL_VERSION,
            "session": mux.session,
            "pid": std::process::id(),
        })),
        Command::ListWorkspaces => Ok(mux.with_state(|workspaces, active_ws, panes| {
            json!({
                "workspaces": workspaces.iter().enumerate().map(|(i, ws)| {
                    json!({
                        "id": ws.id,
                        "name": ws.name,
                        "active": i == active_ws,
                        "tabs": ws.tabs.iter().enumerate().map(|(t, tab)| {
                            let mut ids = Vec::new();
                            tab.root.pane_ids(&mut ids);
                            json!({
                                "id": tab.id,
                                "active": t == ws.active_tab,
                                "active_pane": tab.active_pane,
                                "layout": node_json(&tab.root),
                                "panes": ids.iter().map(|id| {
                                    let pane = panes.get(id).cloned();
                                    json!({
                                        "id": id,
                                        "title": pane.as_ref().map(|p| p.title()).unwrap_or_default(),
                                        "size": pane.as_ref().map(|p| {
                                            let (c, r) = p.size();
                                            json!({"cols": c, "rows": r})
                                        }),
                                        "dead": pane.map(|p| p.is_dead()).unwrap_or(true),
                                    })
                                }).collect::<Vec<_>>(),
                            })
                        }).collect::<Vec<_>>(),
                    })
                }).collect::<Vec<_>>(),
            })
        })),
        Command::Send { pane, text, bytes } => {
            let pane = mux.pane(pane).ok_or_else(|| anyhow::anyhow!("unknown pane {pane}"))?;
            if let Some(text) = text {
                pane.write_bytes(text.as_bytes())?;
            }
            if let Some(b64) = bytes {
                let raw = base64::engine::general_purpose::STANDARD.decode(b64)?;
                pane.write_bytes(&raw)?;
            }
            Ok(json!({}))
        }
        Command::ReadScreen { pane } => {
            let pane = mux.pane(pane).ok_or_else(|| anyhow::anyhow!("unknown pane {pane}"))?;
            let text = pane.with_terminal(|t| t.plain_text())?;
            Ok(json!({ "text": text }))
        }
        Command::VtState { pane } => {
            let pane = mux.pane(pane).ok_or_else(|| anyhow::anyhow!("unknown pane {pane}"))?;
            let (cols, rows, replay) = pane.with_terminal(|t| {
                t.vt_replay().map(|replay| (t.cols(), t.rows(), replay))
            })?;
            Ok(json!({
                "cols": cols,
                "rows": rows,
                "data": base64::engine::general_purpose::STANDARD.encode(replay),
            }))
        }
        Command::NewTab { workspace, cwd } => {
            let pane = mux.new_tab(workspace, cwd)?;
            Ok(json!({ "pane": pane.id }))
        }
        Command::NewWorkspace { name } => {
            let pane = mux.new_workspace(name)?;
            Ok(json!({ "pane": pane.id }))
        }
        Command::Split { pane, dir } => {
            let dir = match dir.as_str() {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                other => anyhow::bail!("bad dir {other:?} (want \"right\" or \"down\")"),
            };
            let new_pane = mux.split(pane, dir)?;
            Ok(json!({ "pane": new_pane.id }))
        }
        Command::KillPane { pane } => {
            if mux.pane(pane).is_none() {
                anyhow::bail!("unknown pane {pane}");
            }
            mux.close_pane(pane);
            Ok(json!({}))
        }
        Command::ResizePane { pane, cols, rows } => {
            let pane = mux.pane(pane).ok_or_else(|| anyhow::anyhow!("unknown pane {pane}"))?;
            pane.resize(cols, rows);
            Ok(json!({}))
        }
        Command::FocusPane { pane } => {
            if !mux.focus_pane(pane) {
                anyhow::bail!("unknown pane {pane}");
            }
            Ok(json!({}))
        }
        Command::SelectTab { index, delta } => {
            mux.select_tab(index, delta);
            Ok(json!({}))
        }
        Command::SelectWorkspace { index, delta } => {
            mux.select_workspace(index, delta);
            Ok(json!({}))
        }
        Command::ScrollPane { pane, delta } => {
            let pane = mux.pane(pane).ok_or_else(|| anyhow::anyhow!("unknown pane {pane}"))?;
            pane.with_terminal(|t| t.scroll_delta(delta));
            Ok(json!({}))
        }
        Command::Subscribe => {
            let events = mux.subscribe();
            let writer = writer.clone();
            std::thread::Builder::new().name("mux-events-out".into()).spawn(move || {
                while let Ok(event) = events.recv() {
                    let value = match &event {
                        MuxEvent::PaneOutput(id) => json!({"event": "pane-output", "pane": id}),
                        MuxEvent::PaneExited(id) => json!({"event": "pane-exited", "pane": id}),
                        MuxEvent::TitleChanged(id) => json!({"event": "title-changed", "pane": id}),
                        MuxEvent::Bell(id) => json!({"event": "bell", "pane": id}),
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
        Command::AttachPane { pane: pane_id } => {
            let pane = mux
                .pane(pane_id)
                .ok_or_else(|| anyhow::anyhow!("unknown pane {pane_id}"))?;
            let (cols, rows, replay, stream) = pane.attach_stream()?;
            writer.send(&json!({
                "event": "vt-state",
                "pane": pane_id,
                "cols": cols,
                "rows": rows,
                "data": base64::engine::general_purpose::STANDARD.encode(replay),
            }))?;
            let writer = writer.clone();
            std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                while let Ok(chunk) = stream.recv() {
                    let value = json!({
                        "event": "output",
                        "pane": pane_id,
                        "data": base64::engine::general_purpose::STANDARD.encode(chunk),
                    });
                    if writer.send(&value).is_err() {
                        break;
                    }
                }
                // Pane gone (or reader stopped): signal end of stream.
                let _ = writer.send(&json!({"event": "detached", "pane": pane_id}));
            })?;
            Ok(json!({}))
        }
    }
}

/// Remove the socket file (call on clean shutdown).
pub fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
}
