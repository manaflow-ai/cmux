//! Control socket: a JSON-lines protocol over the platform transport.
//!
//! This is the attach surface for external frontends (the cmux app, the
//! bundled `cmux-mux attach` client, scripts). One JSON request per line;
//! every request gets one JSON response line. Two commands additionally
//! turn the connection full-duplex:
//!
//! - `subscribe` — the server pushes `{"event":...}` lines (tree-changed,
//!   surface-output, surface-exited, title-changed, bell) interleaved
//!   with responses.
//! - `attach-surface` — PTYs receive `{"event":"vt-state"}` with a
//!   base64 VT replay followed by live `{"event":"output"}` pty bytes.
//!   Browsers receive `{"event":"browser-state"}` with optional latest
//!   frame followed by live `{"event":"frame"}` PNG payloads.
//!
//! ```text
//! {"id":1,"cmd":"identify"}
//! {"id":1,"ok":true,"data":{"app":"cmux-mux","session":"main",...}}
//! ```

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use base64::Engine;
use ghostty_vt::{KeyEncoder, key_input_from_chord};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::model::{Screen, State};
use crate::platform::{self, transport};
use crate::{
    AgentRecord, AgentSource, AgentState, AttachFrame, DefaultColors, Direction, LayoutLeafSpec,
    LayoutSpec, Mux, MuxEvent, Node, NotificationLevel, PaneId, Rgb, ScreenId, SplitDir, SurfaceId,
    SurfaceKind, SurfaceNotification, WorkspaceId, ZoomMode, assign_short_ids,
};

pub const PROTOCOL_VERSION: u32 = 6;

/// Default socket path for a session.
pub fn default_socket_path(session: &str) -> PathBuf {
    platform::runtime_dir().join(format!("{session}.sock"))
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
    Ping,
    ReloadConfig,
    SetWindowTitle {
        title: String,
    },
    ClearWindowTitle,
    ListWorkspaces,
    ExportLayout {
        #[serde(default)]
        screen: Option<ScreenId>,
    },
    ApplyLayout {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        name: Option<String>,
        layout: LayoutRequest,
    },
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
    WaitFor {
        surface: SurfaceId,
        pattern: String,
        #[serde(alias = "timeout_ms")]
        timeout_ms: u64,
    },
    Run {
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        new_workspace: bool,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    SendKey {
        surface: SurfaceId,
        keys: Vec<String>,
    },
    Copy {
        surface: SurfaceId,
        mode: String,
    },
    Ids {
        #[serde(default)]
        kind: Option<String>,
    },
    Notify {
        title: String,
        body: String,
        #[serde(default)]
        level: Option<String>,
        #[serde(default)]
        surface: Option<SurfaceId>,
    },
    ListAgents {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        state: Option<String>,
    },
    ReportAgent {
        surface: SurfaceId,
        state: String,
        source: String,
        #[serde(default)]
        session: Option<String>,
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
    NewBrowserTab {
        url: String,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    SetCellPixels {
        #[serde(alias = "width_px")]
        width_px: u16,
        #[serde(alias = "height_px")]
        height_px: u16,
    },
    BrowserMouse {
        surface: SurfaceId,
        kind: String,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(default)]
        button: Option<String>,
        #[serde(default, alias = "click_count")]
        click_count: Option<u32>,
    },
    BrowserWheel {
        surface: SurfaceId,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(alias = "delta_y_px")]
        delta_y_px: f64,
    },
    BrowserKey {
        surface: SurfaceId,
        kind: String,
        key: String,
        code: String,
        #[serde(alias = "windows_virtual_key_code")]
        windows_virtual_key_code: u32,
        modifiers: u32,
        #[serde(default)]
        text: Option<String>,
    },
    BrowserInsertText {
        surface: SurfaceId,
        text: String,
    },
    BrowserNavigate {
        surface: SurfaceId,
        url: String,
    },
    BrowserBack {
        surface: SurfaceId,
    },
    BrowserForward {
        surface: SurfaceId,
    },
    BrowserReload {
        surface: SurfaceId,
    },
    BrowserActivate {
        surface: SurfaceId,
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
    SetRatio {
        pane: PaneId,
        /// "right" or "down"
        dir: String,
        ratio: f32,
    },
    PaneNeighbor {
        pane: PaneId,
        dir: String,
    },
    FocusDirection {
        #[serde(default)]
        pane: Option<PaneId>,
        dir: String,
    },
    SwapPane {
        pane: PaneId,
        #[serde(default)]
        dir: Option<String>,
        #[serde(default)]
        target: Option<PaneId>,
    },
    ZoomPane {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        mode: Option<String>,
    },
    ProcessInfo {
        surface: SurfaceId,
    },
    MoveTab {
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
    },
    MoveWorkspace {
        workspace: WorkspaceId,
        index: usize,
    },
    SetDefaultColors {
        #[serde(default)]
        fg: Option<String>,
        #[serde(default)]
        bg: Option<String>,
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
    RenameSurface {
        surface: SurfaceId,
        /// Empty clears the name (falls back to the generated tab label).
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

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum LayoutRequest {
    Leaf {
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        command: Option<Vec<String>>,
    },
    Split {
        dir: String,
        ratio: f32,
        a: Box<LayoutRequest>,
        b: Box<LayoutRequest>,
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
struct LineWriter(Arc<Mutex<Box<dyn transport::Stream>>>);

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
        platform::restrict_directory(dir)?;
    }
    // Refuse to clobber a live socket; remove a stale one.
    if path.exists() {
        match transport::connect(&path) {
            Ok(_) => anyhow::bail!(
                "session socket {} is already in use (another instance running?)",
                path.display()
            ),
            Err(_) => std::fs::remove_file(&path)?,
        }
    }
    let listener = transport::listen(&path)?;
    platform::restrict_file(&path)?;

    std::thread::Builder::new().name("mux-server".into()).spawn(move || {
        loop {
            let Ok(stream) = listener.accept() else { continue };
            let mux = mux.clone();
            let _ = std::thread::Builder::new()
                .name("mux-conn".into())
                .spawn(move || handle_connection(mux, stream));
        }
    })?;
    Ok(path)
}

pub fn window_title_osc(title: &str) -> Vec<u8> {
    let title = sanitize_window_title(title);
    format!("\x1b]0;{title}\x07\x1b]2;{title}\x07").into_bytes()
}

fn sanitize_window_title(title: &str) -> String {
    title
        .chars()
        .map(|ch| match ch {
            '\u{00}'..='\u{1f}' | '\u{7f}' => ' ',
            _ => ch,
        })
        .collect()
}

fn handle_connection(mux: Arc<Mux>, stream: Box<dyn transport::Stream>) {
    let Ok(write_half) = stream.try_clone_box() else { return };
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

fn layout_request_to_spec(layout: LayoutRequest) -> anyhow::Result<LayoutSpec> {
    match layout {
        LayoutRequest::Leaf { cwd, command } => {
            Ok(LayoutSpec::Leaf(LayoutLeafSpec { cwd, command }))
        }
        LayoutRequest::Split { dir, ratio, a, b } => Ok(LayoutSpec::Split {
            dir: parse_split_dir(&dir)?,
            ratio,
            a: Box::new(layout_request_to_spec(*a)?),
            b: Box::new(layout_request_to_spec(*b)?),
        }),
    }
}

fn parse_split_dir(dir: &str) -> anyhow::Result<SplitDir> {
    match dir {
        "right" => Ok(SplitDir::Right),
        "down" => Ok(SplitDir::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"right\" or \"down\")"),
    }
}

fn parse_direction(dir: &str) -> anyhow::Result<Direction> {
    match dir {
        "left" => Ok(Direction::Left),
        "right" => Ok(Direction::Right),
        "up" => Ok(Direction::Up),
        "down" => Ok(Direction::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"left\", \"right\", \"up\", or \"down\")"),
    }
}

fn parse_zoom_mode(mode: Option<String>) -> anyhow::Result<ZoomMode> {
    match mode.as_deref().unwrap_or("toggle") {
        "toggle" => Ok(ZoomMode::Toggle),
        "on" => Ok(ZoomMode::On),
        "off" => Ok(ZoomMode::Off),
        other => anyhow::bail!("bad mode {other:?} (want \"toggle\", \"on\", or \"off\")"),
    }
}

fn export_layout_json(state: &State, screen_id: Option<ScreenId>) -> anyhow::Result<Value> {
    let screen = match screen_id {
        Some(id) => state
            .workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .find(|screen| screen.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown screen {id}"))?,
        None => state
            .workspaces
            .get(state.active_workspace)
            .and_then(|ws| ws.active_screen_ref())
            .ok_or_else(|| anyhow::anyhow!("no active screen"))?,
    };
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    Ok(json!({
        "layout": node_json(&screen.root),
        "panes": pane_ids.iter().map(|pane_id| {
            let surfaces = state
                .panes
                .get(pane_id)
                .map(|pane| pane.tabs.clone())
                .unwrap_or_default();
            json!({ "pane": pane_id, "surfaces": surfaces })
        }).collect::<Vec<_>>(),
    }))
}

fn pane_json(
    state: &State,
    id: PaneId,
    short_ids: &HashMap<u64, String>,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let Some(pane) = state.panes.get(&id) else {
        return json!({ "id": id, "dead": true });
    };
    json!({
        "id": id,
        "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
        "name": pane.name,
        "active_tab": pane.active_tab,
        "tabs": pane.tabs.iter().map(|sid| {
            let surface = state.surfaces.get(sid);
            json!({
                "surface": sid,
                "short_id": short_ids.get(sid).cloned().unwrap_or_default(),
                "kind": surface.map(|s| s.kind().as_str()).unwrap_or("pty"),
                "browser_source": surface.and_then(|s| s.browser_source().map(|source| source.as_str())),
                "browser_status": surface.and_then(|s| s.browser_status().map(|status| status.as_str())),
                "browser_error": surface.and_then(|s| s.browser_status().and_then(|status| status.error())),
                "browser_frames_stalled": surface.and_then(|s| s.browser_frames_stalled()),
                "notification": notifications.get(sid).copied().map(|n| {
                    json!({
                        "notification": n.notification,
                        "unread": n.unread,
                        "level": n.level.as_str(),
                    })
                }),
                "name": surface.and_then(|s| s.name()),
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

fn screen_json(
    state: &State,
    screen: &Screen,
    active: bool,
    short_ids: &HashMap<u64, String>,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    json!({
        "id": screen.id,
        "short_id": short_ids.get(&screen.id).cloned().unwrap_or_default(),
        "name": screen.name,
        "active": active,
        "active_pane": screen.active_pane,
        "zoomed_pane": screen.zoomed_pane,
        "layout": node_json(&screen.root),
        "panes": pane_ids.iter().map(|id| pane_json(state, *id, short_ids, notifications)).collect::<Vec<_>>(),
    })
}

fn workspaces_json(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let ids = state
        .workspaces
        .iter()
        .flat_map(|ws| {
            let mut ids = vec![ws.id];
            for screen in &ws.screens {
                ids.push(screen.id);
                screen.root.pane_ids(&mut ids);
            }
            ids
        })
        .chain(state.surfaces.keys().copied());
    let short_ids = assign_short_ids(ids);
    json!({
        "workspaces": state.workspaces.iter().enumerate().map(|(i, ws)| {
            json!({
                "id": ws.id,
                "short_id": short_ids.get(&ws.id).cloned().unwrap_or_default(),
                "name": ws.name,
                "active": i == state.active_workspace,
                "screens": ws.screens.iter().enumerate().map(|(s, screen)| {
                    screen_json(state, screen, s == ws.active_screen, &short_ids, notifications)
                }).collect::<Vec<_>>(),
            })
        }).collect::<Vec<_>>(),
    })
}

fn ids_json(state: &State, kind: Option<&str>) -> anyhow::Result<Value> {
    let allowed = ["workspace", "screen", "pane", "surface"];
    if let Some(kind) = kind {
        if !allowed.contains(&kind) {
            anyhow::bail!("bad kind {kind}");
        }
    }
    let mut raw = Vec::new();
    for ws in &state.workspaces {
        raw.push(("workspace", ws.id));
        for screen in &ws.screens {
            raw.push(("screen", screen.id));
            let mut panes = Vec::new();
            screen.root.pane_ids(&mut panes);
            for pane in panes {
                raw.push(("pane", pane));
            }
        }
    }
    raw.extend(state.surfaces.keys().copied().map(|id| ("surface", id)));
    let short_ids = assign_short_ids(raw.iter().map(|(_, id)| *id));
    Ok(json!({
        "ids": raw
            .into_iter()
            .filter(|(item_kind, _)| kind.is_none_or(|kind| kind == *item_kind))
            .map(|(kind, id)| json!({
                "kind": kind,
                "id": id,
                "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
            }))
            .collect::<Vec<_>>()
    }))
}

fn get_surface(mux: &Mux, id: SurfaceId) -> anyhow::Result<Arc<crate::Surface>> {
    mux.surface(id).ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))
}

fn require_pty(surface: &crate::Surface) -> anyhow::Result<()> {
    if surface.kind() == SurfaceKind::Pty {
        Ok(())
    } else {
        anyhow::bail!("browser surface does not support PTY/VT socket commands")
    }
}

fn require_browser(surface: &crate::Surface) -> anyhow::Result<()> {
    if surface.kind() == SurfaceKind::Browser {
        Ok(())
    } else {
        anyhow::bail!("PTY surface is not a browser surface")
    }
}

fn parse_notification_level(level: &str) -> anyhow::Result<NotificationLevel> {
    match level {
        "info" => Ok(NotificationLevel::Info),
        "warning" => Ok(NotificationLevel::Warning),
        "error" => Ok(NotificationLevel::Error),
        other => anyhow::bail!("bad level {other}"),
    }
}

fn parse_agent_state(state: &str) -> anyhow::Result<AgentState> {
    match state {
        "working" => Ok(AgentState::Working),
        "blocked" => Ok(AgentState::Blocked),
        "idle" => Ok(AgentState::Idle),
        "done" => Ok(AgentState::Done),
        "unknown" => Ok(AgentState::Unknown),
        other => anyhow::bail!("bad state {other}"),
    }
}

fn parse_agent_source(source: &str) -> anyhow::Result<AgentSource> {
    match source {
        "socket" => Ok(AgentSource::Socket),
        "hook" => Ok(AgentSource::Hook),
        other => anyhow::bail!("bad source {other}"),
    }
}

fn agent_json(record: &AgentRecord) -> Value {
    json!({
        "surface": record.surface,
        "state": record.state.as_str(),
        "source": record.source.as_str(),
        "session": record.session,
        "updated_at_ms": record.updated_at_ms,
    })
}

fn parse_hex_color(value: &str) -> anyhow::Result<Rgb> {
    let bytes = value.as_bytes();
    if bytes.len() != 7 || bytes[0] != b'#' {
        anyhow::bail!("bad color {value:?} (want \"#rrggbb\")");
    }
    let nibble = |b: u8| -> anyhow::Result<u8> {
        match b {
            b'0'..=b'9' => Ok(b - b'0'),
            b'a'..=b'f' => Ok(b - b'a' + 10),
            b'A'..=b'F' => Ok(b - b'A' + 10),
            _ => anyhow::bail!("bad color {value:?} (want \"#rrggbb\")"),
        }
    };
    let hex = |idx: usize| -> anyhow::Result<u8> {
        Ok((nibble(bytes[idx])? << 4) | nibble(bytes[idx + 1])?)
    };
    Ok(Rgb { r: hex(1)?, g: hex(3)?, b: hex(5)? })
}

fn browser_state_json(
    surface: SurfaceId,
    state: &crate::BrowserAttachState,
    include_frame: bool,
) -> Value {
    let mut value = json!({
        "event": "browser-state",
        "surface": surface,
        "cols": state.cols,
        "rows": state.rows,
        "url": state.url,
        "title": state.title,
        "status": state.status.as_str(),
        "error": state.status.error(),
        "frames_stalled": state.frames_stalled,
    });
    if include_frame {
        value["frame"] = match state.frame.as_ref() {
            Some(frame) => json!({
                "seq": frame.seq,
                "width": frame.css_width,
                "height": frame.css_height,
                "data": frame.data_b64,
            }),
            None => Value::Null,
        };
    }
    value
}

fn spawn_attach_notification_stream(
    mux: Arc<Mux>,
    surface_id: SurfaceId,
    writer: LineWriter,
) -> std::io::Result<()> {
    let events = mux.subscribe();
    std::thread::Builder::new()
        .name("mux-attach-notifications".into())
        .spawn(move || {
            while let Ok(event) = events.recv() {
                let value = match event {
                    MuxEvent::Notification(notification)
                        if notification.surface == Some(surface_id) =>
                    {
                        json!({
                            "event": "notification",
                            "notification": notification.notification,
                            "title": notification.title,
                            "body": notification.body,
                            "level": notification.level.as_str(),
                            "surface": notification.surface,
                        })
                    }
                    MuxEvent::ScrollChanged { surface, offset, at_bottom }
                        if surface == surface_id =>
                    {
                        json!({
                            "event": "scroll-changed",
                            "surface": surface,
                            "offset": offset,
                            "at_bottom": at_bottom,
                        })
                    }
                    _ => continue,
                };
                if writer.send(&value).is_err() {
                    break;
                }
            }
        })
        .map(|_| ())
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
        Command::Ping => Ok(json!({
            "ok": true,
            "version": env!("CARGO_PKG_VERSION"),
            "protocol": PROTOCOL_VERSION,
        })),
        Command::ReloadConfig => {
            mux.emit(MuxEvent::ConfigReloadRequested);
            Ok(json!({
                "reloaded": true,
                "path": platform::config_path().map(|path| path.display().to_string()),
            }))
        }
        Command::SetWindowTitle { title } => {
            mux.emit(MuxEvent::WindowTitleRequested(title));
            Ok(json!({}))
        }
        Command::ClearWindowTitle => {
            mux.emit(MuxEvent::WindowTitleRequested(String::new()));
            Ok(json!({}))
        }
        Command::ListWorkspaces => {
            let notifications = mux.surface_notifications();
            Ok(mux.with_state(|state| workspaces_json(state, &notifications)))
        }
        Command::ExportLayout { screen } => {
            mux.with_state(|state| export_layout_json(state, screen))
        }
        Command::ApplyLayout { workspace, name, layout } => {
            let layout = layout_request_to_spec(layout)?;
            let applied = mux.apply_layout(workspace, name, &layout)?;
            Ok(json!({
                "screen": applied.screen,
                "panes": applied.panes.iter().map(|pane| {
                    json!({ "pane": pane.pane, "surface": pane.surface })
                }).collect::<Vec<_>>(),
            }))
        }
        Command::Send { surface, text, bytes } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
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
            require_pty(&surface)?;
            let text = surface.try_with_terminal(|t| t.viewport_text())??;
            Ok(json!({ "text": text }))
        }
        Command::WaitFor { surface, pattern, timeout_ms } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let regex = Regex::new(&pattern).map_err(|err| anyhow::anyhow!("bad regex: {err}"))?;
            let start = Instant::now();
            let check = || -> anyhow::Result<Option<String>> {
                let text = surface.try_with_terminal(|t| t.viewport_text())??;
                Ok(regex.is_match(&text).then_some(text))
            };
            if timeout_ms == 0 {
                if let Some(text) = check()? {
                    return Ok(json!({
                        "matched": true,
                        "text": text,
                        "elapsed_ms": start.elapsed().as_millis() as u64,
                    }));
                }
                anyhow::bail!("timeout waiting for pattern");
            }
            let deadline = start + std::time::Duration::from_millis(timeout_ms);
            let attach = surface.attach_stream()?;
            if let Some(text) = check()? {
                return Ok(json!({
                    "matched": true,
                    "text": text,
                    "elapsed_ms": start.elapsed().as_millis() as u64,
                }));
            }
            loop {
                let now = Instant::now();
                if now >= deadline {
                    anyhow::bail!("timeout waiting for pattern");
                }
                let remaining = deadline.saturating_duration_since(now);
                match attach.stream.recv_timeout(remaining) {
                    Ok(_) => {
                        if let Some(text) = check()? {
                            return Ok(json!({
                                "matched": true,
                                "text": text,
                                "elapsed_ms": start.elapsed().as_millis() as u64,
                            }));
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        anyhow::bail!("timeout waiting for pattern");
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                        anyhow::bail!("timeout waiting for pattern");
                    }
                }
            }
        }
        Command::Run { argv, command, cwd, pane, new_workspace, name, cols, rows } => {
            if argv.is_some() && command.is_some() {
                anyhow::bail!("argv and command are mutually exclusive");
            }
            let argv = match (argv, command) {
                (Some(argv), None) if !argv.is_empty() => argv,
                (None, Some(command)) if !command.is_empty() => {
                    vec![platform::default_shell(), "-lc".to_string(), command]
                }
                _ => anyhow::bail!("argv or command is required"),
            };
            if new_workspace && pane.is_some() {
                anyhow::bail!("pane and new_workspace are mutually exclusive");
            }
            let placement =
                mux.run_command_surface(argv, pane, new_workspace, cwd, name, cols.zip(rows))?;
            Ok(json!({
                "surface": placement.surface,
                "pane": placement.pane,
                "screen": placement.screen,
                "workspace": placement.workspace,
            }))
        }
        Command::SendKey { surface, keys } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)
                .map_err(|_| anyhow::anyhow!("surface does not support key input"))?;
            if keys.is_empty() {
                anyhow::bail!("bad request: keys must be non-empty");
            }
            let mut encoder = KeyEncoder::new()?;
            let mut encoded = Vec::new();
            surface.scroll_to_bottom()?;
            surface.try_with_terminal(|term| {
                encoder.sync_from_terminal(term);
                for key in &keys {
                    let Some(input) = key_input_from_chord(key) else {
                        return Err(anyhow::anyhow!("unknown key {key}"));
                    };
                    encoder.encode(&input, &mut encoded).map_err(anyhow::Error::from)?;
                }
                Ok::<(), anyhow::Error>(())
            })??;
            surface.write_bytes(&encoded)?;
            Ok(json!({}))
        }
        Command::Copy { surface, mode } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let text = match mode.as_str() {
                "screen" => surface.try_with_terminal(|t| t.viewport_text())??,
                "scrollback" => surface.try_with_terminal(|t| t.plain_text())??,
                "selection" => {
                    surface.selection_text().ok_or_else(|| anyhow::anyhow!("no selection"))?
                }
                other => anyhow::bail!("bad mode {other}"),
            };
            Ok(json!({ "text": text, "mode": mode }))
        }
        Command::Ids { kind } => mux.with_state(|state| ids_json(state, kind.as_deref())),
        Command::Notify { title, body, level, surface } => {
            if title.is_empty() {
                anyhow::bail!("title is required");
            }
            let level = parse_notification_level(level.as_deref().unwrap_or("info"))?;
            if let Some(surface) = surface {
                get_surface(mux, surface)?;
            }
            let notification = mux.post_notification(title, body, level, surface);
            Ok(json!({ "notification": notification }))
        }
        Command::ListAgents { surface, state } => {
            if let Some(surface) = surface {
                get_surface(mux, surface)?;
            }
            let state = match state {
                Some(state) => Some(parse_agent_state(&state)?),
                None => None,
            };
            let agents = mux.list_agents(surface, state).iter().map(agent_json).collect::<Vec<_>>();
            Ok(json!({ "agents": agents }))
        }
        Command::ReportAgent { surface, state, source, session } => {
            get_surface(mux, surface)?;
            let state = parse_agent_state(&state)?;
            let source = parse_agent_source(&source)?;
            let record = mux.report_agent(surface, state, source, session);
            Ok(json!({
                "surface": record.surface,
                "state": record.state.as_str(),
                "source": record.source.as_str(),
                "session": record.session,
            }))
        }
        Command::VtState { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let (cols, rows, replay) = surface.try_with_terminal(|t| {
                t.vt_replay().map(|replay| (t.cols(), t.rows(), replay))
            })??;
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
        Command::NewBrowserTab { url, pane, cols, rows } => {
            let surface = mux.new_browser_tab(url, pane, cols.zip(rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::SetCellPixels { width_px, height_px } => {
            mux.set_cell_pixel_size(width_px, height_px);
            Ok(json!({}))
        }
        Command::BrowserMouse { surface, kind, x_px, y_px, button, click_count } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            let event_type = match kind.as_str() {
                "down" => "mousePressed",
                "up" => "mouseReleased",
                "move" => "mouseMoved",
                other => anyhow::bail!("bad browser mouse kind {other:?}"),
            };
            surface.browser_mouse_event(event_type, x_px, y_px, button.as_deref(), click_count)?;
            Ok(json!({}))
        }
        Command::BrowserWheel { surface, x_px, y_px, delta_y_px } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_wheel(x_px, y_px, delta_y_px)?;
            Ok(json!({}))
        }
        Command::BrowserKey {
            surface,
            kind,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            let event_type = match kind.as_str() {
                "down" => "keyDown",
                "up" => "keyUp",
                other => anyhow::bail!("bad browser key kind {other:?}"),
            };
            surface.browser_key_event(
                event_type,
                &key,
                &code,
                windows_virtual_key_code,
                modifiers,
                text.as_deref(),
            )?;
            Ok(json!({}))
        }
        Command::BrowserInsertText { surface, text } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_insert_text(&text)?;
            Ok(json!({}))
        }
        Command::BrowserNavigate { surface, url } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_navigate(&url)?;
            Ok(json!({}))
        }
        Command::BrowserBack { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_back()?;
            Ok(json!({}))
        }
        Command::BrowserForward { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_forward()?;
            Ok(json!({}))
        }
        Command::BrowserReload { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_reload()?;
            Ok(json!({}))
        }
        Command::BrowserActivate { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_activate()?;
            Ok(json!({}))
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
            let dir = parse_split_dir(&dir)?;
            let surface = mux.split(pane, dir, cols.zip(rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::SetRatio { pane, dir, ratio } => {
            let dir = parse_split_dir(&dir)?;
            if !mux.set_ratio(pane, dir, ratio) {
                anyhow::bail!("unknown pane/split {pane}");
            }
            Ok(json!({}))
        }
        Command::PaneNeighbor { pane, dir } => {
            let dir = parse_direction(&dir)?;
            let pane = mux.pane_neighbor(pane, dir)?;
            Ok(json!({ "pane": pane }))
        }
        Command::FocusDirection { pane, dir } => {
            let dir = parse_direction(&dir)?;
            let pane = mux.focus_direction(pane, dir)?;
            Ok(json!({ "pane": pane }))
        }
        Command::SwapPane { pane, dir, target } => {
            let target = match (dir, target) {
                (Some(_), Some(_)) => anyhow::bail!("use only one of dir or target"),
                (Some(dir), None) => {
                    let dir = parse_direction(&dir)?;
                    mux.pane_neighbor(pane, dir)?.ok_or_else(|| anyhow::anyhow!("no neighbor"))?
                }
                (None, Some(target)) => target,
                (None, None) => anyhow::bail!("one of dir or target is required"),
            };
            if !mux.swap_panes(pane, target) {
                anyhow::bail!("unknown pane/target");
            }
            Ok(json!({}))
        }
        Command::ZoomPane { pane, mode } => {
            let mode = parse_zoom_mode(mode)?;
            let state = mux.zoom_pane(pane, mode)?;
            Ok(json!({
                "pane": state.pane,
                "zoomed": state.zoomed,
                "zoomed_pane": state.zoomed_pane,
            }))
        }
        Command::ProcessInfo { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            Ok(json!({
                "pid": surface.process_id(),
                "command": surface.spawn_command(),
                "cwd": surface.pwd().or_else(|| surface.spawn_cwd()),
            }))
        }
        Command::MoveTab { surface, pane, index } => {
            let valid = mux.with_state(|state| {
                state.surfaces.contains_key(&surface)
                    && state.panes.contains_key(&pane)
                    && state.pane_of(surface).is_some()
            });
            if !valid {
                anyhow::bail!("unknown surface/pane");
            }
            mux.move_tab(surface, pane, index);
            Ok(json!({}))
        }
        Command::MoveWorkspace { workspace, index } => {
            if !mux.with_state(|state| state.workspaces.iter().any(|ws| ws.id == workspace)) {
                anyhow::bail!("unknown workspace");
            }
            mux.move_workspace(workspace, index);
            Ok(json!({}))
        }
        Command::SetDefaultColors { fg, bg } => {
            let current = mux.default_colors();
            let colors = DefaultColors {
                fg: match fg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => current.fg,
                },
                bg: match bg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => current.bg,
                },
            };
            mux.set_default_colors(colors);
            Ok(json!({}))
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
        Command::RenameSurface { surface, name } => {
            if !mux.rename_surface(surface, name) {
                anyhow::bail!("unknown surface {surface}");
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
            mux.resize_surface(surface, cols, rows)?;
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
            require_pty(&surface)?;
            surface.scroll_delta(delta)?;
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
                        MuxEvent::SurfaceResized { surface, cols, rows } => {
                            json!({
                                "event": "surface-resized",
                                "surface": surface,
                                "cols": cols,
                                "rows": rows,
                            })
                        }
                        MuxEvent::SurfaceExited(id) => {
                            json!({"event": "surface-exited", "surface": id})
                        }
                        MuxEvent::TitleChanged(id) => {
                            json!({"event": "title-changed", "surface": id})
                        }
                        MuxEvent::Bell(id) => json!({"event": "bell", "surface": id}),
                        MuxEvent::Notification(notification) => json!({
                            "event": "notification",
                            "notification": notification.notification,
                            "title": notification.title,
                            "body": notification.body,
                            "level": notification.level.as_str(),
                            "surface": notification.surface,
                        }),
                        MuxEvent::Status(message) => {
                            json!({"event": "status", "message": message})
                        }
                        MuxEvent::ConfigReloadRequested => {
                            json!({"event": "config-reload-requested"})
                        }
                        MuxEvent::WindowTitleRequested(title) => {
                            json!({"event": "window-title-requested", "title": title})
                        }
                        MuxEvent::ScrollChanged { surface, offset, at_bottom } => json!({
                            "event": "scroll-changed",
                            "surface": surface,
                            "offset": offset,
                            "at_bottom": at_bottom,
                        }),
                        MuxEvent::TreeChanged => json!({"event": "tree-changed"}),
                        MuxEvent::LayoutChanged(screen) => {
                            json!({"event": "layout-changed", "screen": screen})
                        }
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
            spawn_attach_notification_stream(mux.clone(), surface_id, writer.clone())?;
            if surface.kind() == SurfaceKind::Browser {
                let (state, frames) = surface.attach_frames()?;
                writer.send(&browser_state_json(surface_id, &state, true))?;
                let writer = writer.clone();
                std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                    while frames.notify.recv().is_ok() {
                        let update = std::mem::take(&mut *frames.slot.lock().unwrap());
                        if let Some(state) = update.state {
                            if writer.send(&browser_state_json(surface_id, &state, false)).is_err()
                            {
                                break;
                            }
                        }
                        if let Some(frame) = update.frame {
                            let value = json!({
                                "event": "frame",
                                "surface": surface_id,
                                "seq": frame.seq,
                                "width": frame.css_width,
                                "height": frame.css_height,
                                "data": frame.data_b64,
                            });
                            if writer.send(&value).is_err() {
                                break;
                            }
                        }
                    }
                    let _ = writer.send(&json!({"event": "detached", "surface": surface_id}));
                })?;
                return Ok(json!({}));
            }
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
                while let Ok(frame) = attach.stream.recv() {
                    let value = match frame {
                        AttachFrame::Output(chunk) => json!({
                            "event": "output",
                            "surface": surface_id,
                            "data": base64::engine::general_purpose::STANDARD.encode(chunk),
                        }),
                        AttachFrame::Resized { cols, rows, replay } => json!({
                            "event": "resized",
                            "surface": surface_id,
                            "cols": cols,
                            "rows": rows,
                            "data": base64::engine::general_purpose::STANDARD.encode(replay),
                        }),
                    };
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SurfaceOptions;
    use std::io::{Read, Write};
    use std::sync::mpsc::TryRecvError;
    use std::time::Duration;

    struct NullStream;

    impl Read for NullStream {
        fn read(&mut self, _buf: &mut [u8]) -> std::io::Result<usize> {
            Ok(0)
        }
    }

    impl Write for NullStream {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for NullStream {
        fn try_clone_box(&self) -> std::io::Result<Box<dyn transport::Stream>> {
            Ok(Box::new(NullStream))
        }

        fn set_read_timeout(&self, _timeout: Option<Duration>) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("test", SurfaceOptions::default())
    }

    fn test_writer() -> LineWriter {
        LineWriter(Arc::new(Mutex::new(Box::new(NullStream) as Box<dyn transport::Stream>)))
    }

    #[test]
    fn ping_returns_version_and_protocol() {
        let mux = test_mux();
        let data = handle_command(&mux, Command::Ping, &test_writer()).unwrap();
        assert_eq!(data["ok"].as_bool(), Some(true));
        assert_eq!(data["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
        assert_eq!(data["protocol"].as_u64(), Some(PROTOCOL_VERSION as u64));
    }

    #[test]
    fn reload_config_returns_path_and_emits_request() {
        let mux = test_mux();
        let events = mux.subscribe();
        let data = handle_command(&mux, Command::ReloadConfig, &test_writer()).unwrap();
        assert_eq!(data["reloaded"].as_bool(), Some(true));
        assert!(data.get("path").is_some());
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ConfigReloadRequested)
        ));
    }

    #[test]
    fn window_title_commands_emit_requests() {
        let mux = test_mux();
        let events = mux.subscribe();

        let data = handle_command(
            &mux,
            Command::SetWindowTitle { title: "hello".to_string() },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(data, json!({}));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::WindowTitleRequested(title)) if title == "hello"
        ));

        handle_command(&mux, Command::ClearWindowTitle, &test_writer()).unwrap();
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::WindowTitleRequested(title)) if title.is_empty()
        ));
    }

    #[test]
    fn window_title_osc_uses_osc_0_and_2_and_strips_controls() {
        assert_eq!(window_title_osc("hello").as_slice(), b"\x1b]0;hello\x07\x1b]2;hello\x07");
        assert_eq!(window_title_osc("a\x1bb\x07c").as_slice(), b"\x1b]0;a b c\x07\x1b]2;a b c\x07");
    }

    #[test]
    fn scroll_surface_emits_one_scroll_changed_event() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
        surface
            .try_with_terminal(|term| {
                for i in 0..20 {
                    term.vt_write(format!("line{i}\r\n").as_bytes());
                }
            })
            .unwrap();
        let events = mux.subscribe();

        handle_command(
            &mux,
            Command::ScrollSurface { surface: surface.id, delta: -5 },
            &test_writer(),
        )
        .unwrap();

        let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            event,
            MuxEvent::ScrollChanged { surface: id, offset, at_bottom: false }
                if id == surface.id && offset > 0
        ));
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));

        handle_command(
            &mux,
            Command::ScrollSurface { surface: surface.id, delta: 0 },
            &test_writer(),
        )
        .unwrap();
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    }
}
