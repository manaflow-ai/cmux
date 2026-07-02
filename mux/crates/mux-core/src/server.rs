//! Control socket: a JSON-lines protocol over a unix domain socket.
//!
//! This is the attach surface for external frontends (the cmux app, the
//! bundled CLI, scripts). One request per line, one JSON response per
//! line. Example:
//!
//! ```text
//! {"id":1,"cmd":"identify"}
//! {"id":1,"ok":true,"data":{"app":"cmux-mux","session":"main",...}}
//! ```

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{Mux, PaneId, SplitDir, WorkspaceId};

pub const PROTOCOL_VERSION: u32 = 1;

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

/// Bind the socket and serve connections on background threads.
///
/// Returns the bound path. The listener thread holds only a `Weak`-like
/// `Arc` clone; dropping the returned guard does not stop it (the process
/// exits with the mux).
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
    let mut writer = std::io::BufWriter::new(write_half);
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Request>(&line) {
            Ok(req) => {
                let id = req.id.clone();
                match handle_command(&mux, req.cmd) {
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
        let Ok(mut bytes) = serde_json::to_vec(&response) else { break };
        bytes.push(b'\n');
        if writer.write_all(&bytes).is_err() || writer.flush().is_err() {
            break;
        }
    }
}

fn handle_command(mux: &Arc<Mux>, cmd: Command) -> anyhow::Result<Value> {
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
    }
}

/// Remove the socket file (call on clean shutdown).
pub fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
}
