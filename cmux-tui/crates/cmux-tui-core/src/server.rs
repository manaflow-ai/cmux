//! Control protocol server over Unix JSON-lines and WebSocket text frames.
//!
//! This is the attach surface for external frontends (the cmux app, the
//! bundled `cmux-tui attach` client, scripts). Unix uses one JSON message
//! per line and WebSocket uses one JSON message per text frame. Two commands
//! additionally turn the connection full-duplex:
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
//! {"id":1,"ok":true,"data":{"app":"cmux-tui","session":"main",...}}
//! ```

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use base64::Engine;
use ghostty_vt::{
    Dirty, KeyEncoder, StyledRun, UnderlineStyle, key_input_from_chord, rows_to_runs,
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::protocol::{Role, WebSocketConfig};
use tungstenite::{Message, WebSocket, accept_with_config};

use crate::model::{Screen, State, Workspace};
use crate::mux::clamp_terminal_size;
use crate::platform::{self, transport};
use crate::surface::AttachLifecycle;
use crate::{
    AgentRecord, AgentSource, AgentState, AttachFrame, DefaultColors, Direction, LayoutLeafSpec,
    LayoutSpec, Mux, MuxEvent, Node, NotificationLevel, PairingDecision, PaneId, RenderAttachFrame,
    Rgb, ScreenId, SidebarPluginStatus, SplitDir, SplitId, SurfaceId, SurfaceKind,
    SurfaceNotification, SurfaceRenderFrame, TerminalColors, TreeDelta, TreeDeltaKind, WorkspaceId,
    ZoomMode, assign_short_ids,
};

const ATTACH_INITIAL_SIZE_CAPABILITY: &str = "attach-initial-size";
const WORKSPACE_REGISTRY_CAPABILITY: &str = "workspace-registry-v1";
const INITIAL_BROWSER_RESIZE_TIMEOUT: Duration = Duration::from_secs(10);
pub const STABLE_SPLIT_IDS_PROTOCOL_VERSION: u32 = 8;
pub const STACK_LAYOUT_PROTOCOL_VERSION: u32 = 9;
pub const PROTOCOL_VERSION: u32 = STACK_LAYOUT_PROTOCOL_VERSION;

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
    SetClientInfo {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        kind: Option<String>,
    },
    ListClients,
    SetClientSizing {
        #[serde(default)]
        client: Option<u64>,
        enabled: bool,
        #[serde(default)]
        exclusive: bool,
    },
    PairingResponse {
        request: u64,
        approve: bool,
    },
    DetachClient {
        client: u64,
    },
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
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    Send {
        surface: SurfaceId,
        #[serde(default)]
        text: Option<String>,
        /// Base64-encoded raw bytes, written verbatim to the pty.
        #[serde(default)]
        bytes: Option<String>,
        #[serde(default)]
        paste: bool,
    },
    ReadScreen {
        surface: SurfaceId,
    },
    ReadScrollback {
        surface: SurfaceId,
        start: u32,
        count: u32,
    },
    SidebarPlugin {
        cols: u16,
        rows: u16,
        #[serde(default)]
        relaunch: bool,
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
    /// Create a registry entry without implicitly spawning a terminal.
    CreateWorkspace {
        #[serde(default)]
        name: Option<String>,
        /// Optional frontend-generated stable key. When absent, the mux
        /// generates a UUIDv4 key and returns it.
        #[serde(default)]
        key: Option<String>,
        /// Compare-and-swap guard for the ordered registry.
        #[serde(default)]
        expected_revision: Option<u64>,
    },
    /// Create a terminal inside an existing workspace selected by stable key
    /// or legacy numeric id.
    CreateTerminal {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
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
    NewPane {
        pane: PaneId,
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
    SetSplitRatio {
        split: SplitId,
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
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        index: usize,
        #[serde(default)]
        expected_revision: Option<u64>,
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
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        #[serde(default)]
        expected_revision: Option<u64>,
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
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        name: String,
        #[serde(default)]
        expected_revision: Option<u64>,
    },
    ResizeSurface {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    },
    /// Stop this client from contributing a size for a surface while
    /// retaining its attach stream for cached rendering.
    ReleaseSurfaceSize {
        surface: SurfaceId,
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
    Subscribe {
        #[serde(default)]
        tree_events: Option<String>,
    },
    /// Stream a surface: vt-state event followed by live output events.
    AttachSurface {
        surface: SurfaceId,
        #[serde(default)]
        mode: Option<String>,
        /// Optional initial viewer size. Supplying this pair makes the attach
        /// stream a sizing participant immediately, before its first frame is
        /// rendered.
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
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
    Stack {
        panes: Vec<PaneId>,
        expanded: PaneId,
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

const STREAM_DISCONNECT_POLL: Duration = Duration::from_millis(100);
const STREAM_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
#[cfg(not(test))]
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_SERVER_CONNECTIONS: usize = 64;
const WEBSOCKET_AUTH_MAX_BYTES: usize = 4 * 1024;
const WEBSOCKET_MESSAGE_MAX_BYTES: usize = 4 * 1024 * 1024;
const OUTBOUND_CAPACITY: usize = 256;
const OUTBOUND_CONTROL_RESERVE: usize = 256;
const OUTBOUND_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
const OUTBOUND_CONTROL_BYTE_RESERVE: usize = 16 * 1024 * 1024;
const CLIENT_DETACH_WRITE_TIMEOUT: Duration = Duration::from_millis(100);

#[derive(Clone)]
struct OutboundStream {
    id: u64,
    open: Arc<AtomicBool>,
    terminal_enqueued: Arc<AtomicBool>,
    overflow_text: Arc<str>,
}

impl OutboundStream {
    fn new(id: u64, overflow_text: String) -> Self {
        Self {
            id,
            open: Arc::new(AtomicBool::new(true)),
            terminal_enqueued: Arc::new(AtomicBool::new(false)),
            overflow_text: overflow_text.into(),
        }
    }

    fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire)
    }

    fn close(&self) {
        self.open.store(false, Ordering::Release);
    }
}

trait MessageSink: Send + Sync {
    fn send_initial(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_stream(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_control(&self, value: &Value) -> std::io::Result<()>;
    fn send_terminal(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()>;
    fn set_write_timeout(&self, _timeout: Option<Duration>) -> std::io::Result<()> {
        Ok(())
    }
    fn is_open(&self) -> bool;
    fn close(&self);
}

/// Transport-independent writer shared by command responses and event streams.
#[derive(Clone)]
struct MessageWriter {
    sink: Arc<dyn MessageSink>,
    open: Arc<AtomicBool>,
    next_stream_id: Arc<AtomicU64>,
}

impl MessageWriter {
    fn new(sink: impl MessageSink + 'static) -> Self {
        Self {
            sink: Arc::new(sink),
            open: Arc::new(AtomicBool::new(true)),
            next_stream_id: Arc::new(AtomicU64::new(1)),
        }
    }

    fn start_stream(&self, overflow: &Value) -> std::io::Result<OutboundStream> {
        Ok(OutboundStream::new(
            self.next_stream_id.fetch_add(1, Ordering::Relaxed),
            serde_json::to_string(overflow)?,
        ))
    }

    fn send_stream(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_stream(value, stream);
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn send_initial(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_initial(value, stream);
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn send_terminal(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_terminal(value, stream);
        if result.is_err() {
            self.close();
        }
        result
    }

    fn send_control(&self, value: &Value) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_control(value);
        if result.is_err() {
            self.close();
        }
        result
    }

    fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire) && self.sink.is_open()
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.sink.set_write_timeout(timeout)
    }

    fn close(&self) {
        if self.open.swap(false, Ordering::AcqRel) {
            self.sink.close();
        }
    }
}

#[derive(Default)]
struct BoundedOutbound {
    state: Mutex<BoundedOutboundState>,
    changed: Condvar,
}

#[derive(Default)]
struct BoundedOutboundState {
    initial: VecDeque<RegularOutbound>,
    control: VecDeque<String>,
    regular: VecDeque<RegularOutbound>,
    control_bytes: usize,
    regular_bytes: usize,
    closed: bool,
}

struct RegularOutbound {
    text: String,
    stream: OutboundStream,
}

struct ConnectionPermit(Arc<AtomicU64>);

impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn claim_connection(active: &Arc<AtomicU64>) -> Option<ConnectionPermit> {
    active
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < MAX_SERVER_CONNECTIONS as u64).then_some(count + 1)
        })
        .ok()
        .map(|_| ConnectionPermit(active.clone()))
}

impl BoundedOutbound {
    fn push_regular(&self, text: String, stream: &OutboundStream) -> std::io::Result<()> {
        self.push_regular_with_priority(text, stream, false)
    }

    fn push_initial(&self, text: String, stream: &OutboundStream) -> std::io::Result<()> {
        self.push_regular_with_priority(text, stream, true)
    }

    fn push_regular_with_priority(
        &self,
        text: String,
        stream: &OutboundStream,
        initial: bool,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        if !stream.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
        }
        let bytes = text.len();
        if bytes > OUTBOUND_BYTE_CAPACITY {
            Self::terminate_stream_locked(&mut state, stream)?;
            self.changed.notify_one();
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound queue overflowed",
            ));
        }
        loop {
            let byte_full = bytes > OUTBOUND_BYTE_CAPACITY.saturating_sub(state.regular_bytes);
            let count_full = state.initial.len() + state.regular.len() >= OUTBOUND_CAPACITY;
            if !byte_full && !count_full {
                break;
            }
            let Some(victim) = Self::largest_stream(&state, byte_full) else {
                Self::terminate_stream_locked(&mut state, stream)?;
                self.changed.notify_one();
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            };
            let incoming_terminated = victim.id == stream.id;
            Self::terminate_stream_locked(&mut state, &victim)?;
            if incoming_terminated {
                self.changed.notify_one();
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            }
        }
        state.regular_bytes += bytes;
        let message = RegularOutbound { text, stream: stream.clone() };
        if initial {
            state.initial.push_back(message);
        } else {
            state.regular.push_back(message);
        }
        self.changed.notify_one();
        Ok(())
    }

    fn push_control(&self, text: String) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        Self::push_control_locked(&mut state, text)?;
        self.changed.notify_one();
        Ok(())
    }

    fn push_terminal(&self, text: String, stream: &OutboundStream) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        stream.close();
        Self::purge_stream_locked(&mut state, stream.id);
        if stream.terminal_enqueued.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        Self::push_control_locked(&mut state, text)?;
        self.changed.notify_one();
        Ok(())
    }

    fn terminate_stream_locked(
        state: &mut BoundedOutboundState,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        stream.close();
        Self::purge_stream_locked(state, stream.id);
        if stream.terminal_enqueued.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        if let Err(error) = Self::push_control_locked(state, stream.overflow_text.to_string()) {
            state.closed = true;
            return Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                format!("could not report stream overflow: {error}"),
            ));
        }
        Ok(())
    }

    fn purge_stream_locked(state: &mut BoundedOutboundState, stream_id: u64) {
        let mut removed_bytes = 0;
        state.initial.retain(|message| {
            if message.stream.id == stream_id {
                removed_bytes += message.text.len();
                false
            } else {
                true
            }
        });
        state.regular.retain(|message| {
            if message.stream.id == stream_id {
                removed_bytes += message.text.len();
                false
            } else {
                true
            }
        });
        state.regular_bytes -= removed_bytes;
    }

    fn largest_stream(state: &BoundedOutboundState, by_bytes: bool) -> Option<OutboundStream> {
        let mut usage = HashMap::<u64, (usize, usize, OutboundStream)>::new();
        for message in state.initial.iter().chain(&state.regular) {
            let entry =
                usage.entry(message.stream.id).or_insert_with(|| (0, 0, message.stream.clone()));
            entry.0 += 1;
            entry.1 += message.text.len();
        }
        usage
            .into_values()
            .max_by_key(|(messages, bytes, _)| if by_bytes { *bytes } else { *messages })
            .map(|(_, _, stream)| stream)
    }

    fn push_control_locked(state: &mut BoundedOutboundState, text: String) -> std::io::Result<()> {
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let bytes = text.len();
        if state.control.len() >= OUTBOUND_CONTROL_RESERVE
            || bytes > OUTBOUND_CONTROL_BYTE_RESERVE.saturating_sub(state.control_bytes)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound control reserve overflowed",
            ));
        }
        state.control_bytes += bytes;
        state.control.push_back(text);
        Ok(())
    }

    #[cfg(test)]
    fn try_pop(&self) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        Self::pop_locked(&mut state)
    }

    fn recv(&self) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(text) = Self::pop_locked(&mut state) {
                return Some(text);
            }
            if state.closed {
                return None;
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    fn pop_locked(state: &mut BoundedOutboundState) -> Option<String> {
        if let Some(message) = state.initial.pop_front() {
            state.regular_bytes -= message.text.len();
            return Some(message.text);
        }
        if let Some(text) = state.control.pop_front() {
            state.control_bytes -= text.len();
            return Some(text);
        }
        let message = state.regular.pop_front()?;
        state.regular_bytes -= message.text.len();
        Some(message.text)
    }

    fn is_open(&self) -> bool {
        !self.state.lock().unwrap().closed
    }

    fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.changed.notify_all();
    }
}

struct QueuedSink {
    outbound: Arc<BoundedOutbound>,
    control: Option<SinkControl>,
}

enum SinkControl {
    Unix(Box<dyn transport::Stream>),
    WebSocket(TcpStream),
}

/// Cloned TCP streams share one write boundary so independent Tungstenite
/// reader and writer contexts cannot interleave frame bytes. Reads remain
/// fully blocking and are interrupted by shutting down a clone.
struct SynchronizedTcpStream {
    stream: TcpStream,
    write_lock: Arc<Mutex<()>>,
}

impl SynchronizedTcpStream {
    fn new(stream: TcpStream) -> Self {
        Self { stream, write_lock: Arc::new(Mutex::new(())) }
    }

    fn try_clone(&self) -> std::io::Result<Self> {
        Ok(Self { stream: self.stream.try_clone()?, write_lock: self.write_lock.clone() })
    }

    fn try_clone_raw(&self) -> std::io::Result<TcpStream> {
        self.stream.try_clone()
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_write_timeout(timeout)
    }
}

impl Read for SynchronizedTcpStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.stream.read(buf)
    }
}

impl Write for SynchronizedTcpStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _guard = self.write_lock.lock().unwrap();
        self.stream.write_all(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let _guard = self.write_lock.lock().unwrap();
        self.stream.flush()
    }
}

impl SinkControl {
    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        match self {
            Self::Unix(stream) => stream.set_write_timeout(timeout),
            Self::WebSocket(stream) => stream.set_write_timeout(timeout),
        }
    }
}

impl MessageSink for QueuedSink {
    fn send_initial(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        let text = serde_json::to_string(value)?;
        self.outbound.push_initial(text, stream)
    }

    fn send_stream(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        let text = serde_json::to_string(value)?;
        self.outbound.push_regular(text, stream)
    }

    fn send_control(&self, value: &Value) -> std::io::Result<()> {
        let text = serde_json::to_string(value)?;
        self.outbound.push_control(text)
    }

    fn send_terminal(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        let text = serde_json::to_string(value)?;
        self.outbound.push_terminal(text, stream)
    }

    fn is_open(&self) -> bool {
        self.outbound.is_open()
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.control.as_ref().map_or(Ok(()), |control| control.set_write_timeout(timeout))
    }

    fn close(&self) {
        self.outbound.close();
    }
}

/// First-attach announcement payload: (transport, name, kind).
type ClientAnnouncement = (String, Option<String>, Option<String>);
/// Size-report update payload: (changed, name, kind, previous size).
pub(crate) type ClientSizeUpdate = (bool, Option<String>, Option<String>, Option<(u16, u16)>);

#[derive(Clone, Copy)]
enum ClientTransport {
    Unix,
    WebSocket,
}

impl ClientTransport {
    fn as_str(self) -> &'static str {
        match self {
            Self::Unix => "unix",
            Self::WebSocket => "ws",
        }
    }
}

#[derive(Default)]
struct AttachedSurface {
    streams: BTreeMap<u64, OutboundStream>,
    pending_streams: BTreeMap<u64, OutboundStream>,
    size_rollbacks: BTreeMap<u64, crate::mux::ClientSizeRollback>,
    size: Option<(u16, u16)>,
    committed_size: Option<(u16, u16)>,
    current_report_order: Option<u64>,
}

struct DetachedSurface {
    final_stream: bool,
    rollback: Option<crate::mux::ClientSizeRollback>,
}

struct ClientRecord {
    transport: ClientTransport,
    connected_at: Instant,
    name: Option<String>,
    kind: Option<String>,
    attached: BTreeMap<SurfaceId, AttachedSurface>,
    announced_attached: bool,
    writer: MessageWriter,
}

pub(crate) struct ClientRegistry {
    next_id: AtomicU64,
    clients: Mutex<BTreeMap<u64, ClientRecord>>,
}

impl ClientRegistry {
    pub(crate) fn new() -> Self {
        Self { next_id: AtomicU64::new(1), clients: Mutex::new(BTreeMap::new()) }
    }

    fn register(&self, transport: ClientTransport, writer: MessageWriter) -> u64 {
        let client = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.clients.lock().unwrap().insert(
            client,
            ClientRecord {
                transport,
                connected_at: Instant::now(),
                name: None,
                kind: None,
                attached: BTreeMap::new(),
                announced_attached: false,
                writer,
            },
        );
        client
    }

    fn is_unix(&self, client: u64) -> bool {
        self.clients
            .lock()
            .unwrap()
            .get(&client)
            .is_some_and(|record| matches!(record.transport, ClientTransport::Unix))
    }

    fn set_info(
        &self,
        client: u64,
        name: Option<String>,
        kind: Option<String>,
    ) -> anyhow::Result<(Option<String>, Option<String>)> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if let Some(name) = name {
            record.name = Some(clamp_client_label(name));
        }
        if let Some(kind) = kind {
            record.kind = Some(clamp_client_label(kind));
        }
        Ok((record.name.clone(), record.kind.clone()))
    }

    pub(crate) fn list_json(&self, requesting_client: u64) -> Value {
        let clients = self.clients.lock().unwrap();
        json!(
            clients
                .iter()
                .map(|(client, record)| {
                    json!({
                        "client": client,
                        "transport": record.transport.as_str(),
                        "name": record.name,
                        "kind": record.kind,
                        "connected_seconds": record.connected_at.elapsed().as_secs(),
                        "attached": record.attached.iter().filter_map(|(surface, attached)| {
                            (!attached.streams.is_empty()).then_some(*surface)
                        }).collect::<Vec<_>>(),
                        "sizes": record.attached.iter().filter_map(|(surface, attached)| {
                            if attached.streams.is_empty() {
                                return None;
                            }
                            Some(match attached.committed_size {
                                Some((cols, rows)) => json!({
                                    "surface": surface,
                                    "cols": cols,
                                    "rows": rows,
                                }),
                                None => json!({
                                    "surface": surface,
                                    "cols": null,
                                    "rows": null,
                                }),
                            })
                        }).collect::<Vec<_>>(),
                        "self": *client == requesting_client,
                    })
                })
                .collect::<Vec<_>>()
        )
    }

    fn attach_surface(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: OutboundStream,
    ) -> anyhow::Result<()> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        record.attached.entry(surface).or_default().pending_streams.insert(stream.id, stream);
        Ok(())
    }

    fn commit_surface(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: u64,
        rollback: Option<crate::mux::ClientSizeRollback>,
    ) -> anyhow::Result<()> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let attached = record
            .attached
            .get_mut(&surface)
            .ok_or_else(|| anyhow::anyhow!("client {client} has no pending surface {surface}"))?;
        let outbound = attached.pending_streams.remove(&stream).ok_or_else(|| {
            anyhow::anyhow!("client {client} has no pending stream {stream} for surface {surface}")
        })?;
        attached.streams.insert(stream, outbound);
        if let Some(rollback) = rollback {
            attached.size_rollbacks.insert(stream, rollback);
        }
        attached.committed_size = attached.size;
        Ok(())
    }

    fn announce_attached(&self, client: u64) -> anyhow::Result<Option<ClientAnnouncement>> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if record.announced_attached {
            return Ok(None);
        }
        anyhow::ensure!(
            record.attached.values().any(|attached| !attached.streams.is_empty()),
            "client {client} has no attached surfaces"
        );
        record.announced_attached = true;
        Ok(Some((record.transport.as_str().to_string(), record.name.clone(), record.kind.clone())))
    }

    fn detach_surface(&self, client: u64, surface: SurfaceId, stream: u64) -> DetachedSurface {
        let mut clients = self.clients.lock().unwrap();
        let Some(record) = clients.get_mut(&client) else {
            return DetachedSurface { final_stream: false, rollback: None };
        };
        let Some(attached) = record.attached.get_mut(&surface) else {
            return DetachedSurface { final_stream: false, rollback: None };
        };
        attached.streams.remove(&stream);
        attached.pending_streams.remove(&stream);
        let rollback = attached.size_rollbacks.remove(&stream);
        if let Some(removed) = rollback {
            for remaining in attached.size_rollbacks.values_mut() {
                if remaining.previous_report_order == Some(removed.applied_report_order) {
                    remaining.previous_size = removed.previous_size;
                    remaining.previous_report_order = removed.previous_report_order;
                    remaining.previous_geometry = removed.previous_geometry;
                }
            }
        }
        if attached.streams.is_empty() && attached.pending_streams.is_empty() {
            record.attached.remove(&surface);
            return DetachedSurface { final_stream: true, rollback };
        }
        let rollback = rollback.filter(|rollback| {
            attached.current_report_order == Some(rollback.applied_report_order)
        });
        DetachedSurface { final_stream: false, rollback }
    }

    pub(crate) fn record_size(
        &self,
        client: u64,
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<Option<ClientSizeUpdate>> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some(attached) = record.attached.get_mut(&surface) else { return Ok(None) };
        let previous = attached.size;
        let changed = previous != Some((cols, rows));
        attached.size = Some((cols, rows));
        if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
            attached.committed_size = attached.size;
        }
        Ok(Some((changed, record.name.clone(), record.kind.clone(), previous)))
    }

    pub(crate) fn set_report_order(&self, client: u64, surface: SurfaceId, report_order: u64) {
        if let Some(attached) = self
            .clients
            .lock()
            .unwrap()
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.current_report_order = Some(report_order);
        }
    }

    pub(crate) fn restore_size(&self, client: u64, surface: SurfaceId, size: Option<(u16, u16)>) {
        if let Some(attached) = self
            .clients
            .lock()
            .unwrap()
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.size = size;
            if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
                attached.committed_size = size;
            }
        }
    }

    pub(crate) fn restore_size_and_report_order(
        &self,
        client: u64,
        surface: SurfaceId,
        size: Option<(u16, u16)>,
        report_order: Option<u64>,
    ) {
        self.restore_size(client, surface, size);
        if let Some(attached) = self
            .clients
            .lock()
            .unwrap()
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.current_report_order = report_order;
        }
    }

    fn clear_size(
        &self,
        client: u64,
        surface: SurfaceId,
    ) -> Option<(bool, Option<String>, Option<String>)> {
        let mut clients = self.clients.lock().unwrap();
        let record = clients.get_mut(&client)?;
        let attached = record.attached.get_mut(&surface)?;
        let changed = attached.size.take().is_some();
        attached.committed_size = None;
        attached.current_report_order = None;
        Some((changed, record.name.clone(), record.kind.clone()))
    }

    fn remove(&self, client: u64) -> Option<ClientRecord> {
        self.clients.lock().unwrap().remove(&client)
    }

    pub(crate) fn contains(&self, client: u64) -> bool {
        self.clients.lock().unwrap().contains_key(&client)
    }

    pub(crate) fn client_ids(&self) -> HashSet<u64> {
        self.clients.lock().unwrap().keys().copied().collect()
    }

    pub(crate) fn client_info(&self, client: u64) -> Option<(Option<String>, Option<String>)> {
        self.clients
            .lock()
            .unwrap()
            .get(&client)
            .map(|record| (record.name.clone(), record.kind.clone()))
    }

    pub(crate) fn attached_client_ids(&self) -> HashSet<u64> {
        self.clients
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(client, record)| (!record.attached.is_empty()).then_some(*client))
            .collect()
    }
}

fn clamp_client_label(value: String) -> String {
    sanitize_window_title(&value).chars().take(64).collect()
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
    let active_connections = Arc::new(AtomicU64::new(0));

    std::thread::Builder::new().name("mux-server".into()).spawn(move || {
        loop {
            let Ok(stream) = listener.accept() else { continue };
            let Some(permit) = claim_connection(&active_connections) else { continue };
            let mux = mux.clone();
            let _ = std::thread::Builder::new().name("mux-conn".into()).spawn(move || {
                let _permit = permit;
                handle_connection(mux, stream);
            });
        }
    })?;
    Ok(path)
}

/// A running opt-in WebSocket listener. Dropping it stops accepts and closes clients.
pub struct WebSocketServer {
    local_addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    connections: Arc<Mutex<HashMap<u64, TcpStream>>>,
    thread: Option<JoinHandle<()>>,
}

impl WebSocketServer {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }
}

impl Drop for WebSocketServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        for stream in self.connections.lock().unwrap().values() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Ok(stream) = TcpStream::connect(self.local_addr) {
            let _ = stream.set_nodelay(true);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Bind an opt-in WebSocket listener using one JSON message per text frame.
pub fn serve_websocket(
    mux: Arc<Mux>,
    addr: SocketAddr,
    token: Option<String>,
    allow_insecure_bind: bool,
) -> anyhow::Result<WebSocketServer> {
    // WebSocket has no TLS here. Remote deployments must explicitly opt in and
    // should put cmux-tui behind a TLS-terminating reverse proxy.
    if !addr.ip().is_loopback() && !allow_insecure_bind {
        anyhow::bail!("refusing non-loopback WebSocket bind {addr} without --ws-insecure-bind");
    }
    let token = token.filter(|value| !value.trim().is_empty());
    if let Some(token_value) = token.as_ref() {
        let auth_message_bytes =
            serde_json::to_vec(&json!({"auth": {"token": token_value}}))?.len();
        if auth_message_bytes > WEBSOCKET_AUTH_MAX_BYTES {
            anyhow::bail!(
                "WebSocket token produces a {auth_message_bytes}-byte auth message; maximum is {WEBSOCKET_AUTH_MAX_BYTES} bytes"
            );
        }
    }
    let listener = TcpListener::bind(addr)?;
    let local_addr = listener.local_addr()?;
    let shutdown = Arc::new(AtomicBool::new(false));
    let connections = Arc::new(Mutex::new(HashMap::new()));
    let next_connection = Arc::new(AtomicU64::new(1));
    let active_connections = Arc::new(AtomicU64::new(0));
    let thread_shutdown = shutdown.clone();
    let thread_connections = connections.clone();
    let thread = std::thread::Builder::new().name("mux-ws-server".into()).spawn(move || {
        while !thread_shutdown.load(Ordering::Acquire) {
            let (stream, peer) = match listener.accept() {
                Ok(connection) => connection,
                Err(_) => {
                    if thread_shutdown.load(Ordering::Acquire) {
                        break;
                    }
                    // Accept errors can persist (for example, after resource exhaustion).
                    // A short backoff prevents a hot retry loop while still recovering promptly.
                    std::thread::sleep(STREAM_DISCONNECT_POLL);
                    continue;
                }
            };
            if stream.set_nodelay(true).is_err() {
                continue;
            }
            if thread_shutdown.load(Ordering::Acquire) {
                break;
            }
            let Some(permit) = claim_connection(&active_connections) else { continue };
            let id = next_connection.fetch_add(1, Ordering::Relaxed);
            if let Ok(tracked) = stream.try_clone() {
                thread_connections.lock().unwrap().insert(id, tracked);
            }
            let mux = mux.clone();
            let token = token.clone();
            let connections = thread_connections.clone();
            let cleanup_connections = thread_connections.clone();
            if std::thread::Builder::new()
                .name("mux-ws-conn".into())
                .spawn(move || {
                    let _permit = permit;
                    handle_websocket_connection(mux, stream, peer, token.as_deref());
                    connections.lock().unwrap().remove(&id);
                })
                .is_err()
            {
                cleanup_connections.lock().unwrap().remove(&id);
            }
        }
    })?;
    Ok(WebSocketServer { local_addr, shutdown, connections, thread: Some(thread) })
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
    let Ok(mut write_half) = stream.try_clone_box() else { return };
    let Ok(control) = write_half.try_clone_box() else { return };
    if write_half.set_write_timeout(Some(STREAM_WRITE_TIMEOUT)).is_err() {
        return;
    }
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink {
        outbound: outbound.clone(),
        control: Some(SinkControl::Unix(control)),
    });
    let writer_outbound = outbound;
    let Ok(writer_thread) =
        std::thread::Builder::new().name("mux-line-out".into()).spawn(move || {
            while let Some(text) = writer_outbound.recv() {
                if write_half.write_all(text.as_bytes()).is_err()
                    || write_half.write_all(b"\n").is_err()
                {
                    writer_outbound.close();
                    let _ = write_half.shutdown(Shutdown::Both);
                    break;
                }
            }
            let _ = write_half.shutdown(Shutdown::Both);
        })
    else {
        writer.close();
        return;
    };
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        if !handle_message(&mux, client, &line, &writer) {
            break;
        }
    }
    disconnect_client(&mux, client, false);
    let _ = writer_thread.join();
}

fn handle_websocket_connection(
    mux: Arc<Mux>,
    stream: TcpStream,
    peer: SocketAddr,
    token: Option<&str>,
) {
    let stream = SynchronizedTcpStream::new(stream);
    if stream.set_read_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
        || stream.set_write_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
    {
        return;
    }
    let auth_config = WebSocketConfig::default()
        .read_buffer_size(4 * 1024)
        .write_buffer_size(4 * 1024)
        .max_write_buffer_size(WEBSOCKET_MESSAGE_MAX_BYTES)
        .max_message_size(Some(WEBSOCKET_AUTH_MAX_BYTES))
        .max_frame_size(Some(WEBSOCKET_AUTH_MAX_BYTES));
    let Ok(mut websocket) = accept_with_config(stream, Some(auth_config)) else { return };

    if !authenticate_websocket(&mux, &mut websocket, peer, token) {
        let frame = CloseFrame { code: CloseCode::Policy, reason: "authentication failed".into() };
        let _ = websocket.close(Some(frame));
        let _ = websocket.flush();
        return;
    }
    websocket.set_config(|config| {
        config.max_message_size = Some(WEBSOCKET_MESSAGE_MAX_BYTES);
        config.max_frame_size = Some(WEBSOCKET_MESSAGE_MAX_BYTES);
    });
    let _ = websocket.get_mut().set_read_timeout(None);
    let _ = websocket.get_mut().set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let Ok(writer_stream) = websocket.get_ref().try_clone() else { return };
    let Ok(writer_shutdown) = writer_stream.try_clone_raw() else { return };
    let Ok(control) = writer_stream.try_clone_raw() else { return };
    let _ = writer_stream.set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink {
        outbound: outbound.clone(),
        control: Some(SinkControl::WebSocket(control)),
    });
    let writer_outbound = outbound;
    let Ok(writer_thread) =
        std::thread::Builder::new().name("mux-ws-out".into()).spawn(move || {
            let mut websocket = WebSocket::from_raw_socket(writer_stream, Role::Server, None);
            while let Some(text) = writer_outbound.recv() {
                if websocket.send(Message::Text(text.into())).is_err() {
                    writer_outbound.close();
                    break;
                }
            }
            let _ = websocket.close(None);
            let _ = websocket.flush();
            let _ = writer_shutdown.shutdown(Shutdown::Both);
        })
    else {
        writer.close();
        return;
    };
    let client = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());

    loop {
        if !writer.is_open() {
            break;
        }

        let incoming = websocket.read();
        match incoming {
            Ok(Message::Text(text)) => {
                if !handle_message(&mux, client, &text, &writer) {
                    break;
                }
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                let _ = websocket.flush();
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => break,
            Err(_) => break,
        }
    }
    disconnect_client(&mux, client, false);
    let _ = writer_thread.join();
    let _ = websocket.close(None);
}

fn authenticate_websocket(
    mux: &Arc<Mux>,
    websocket: &mut WebSocket<SynchronizedTcpStream>,
    peer: SocketAddr,
    configured_token: Option<&str>,
) -> bool {
    let Ok(Message::Text(text)) = websocket.read() else { return false };
    if let Some(provided) = auth_token(&text) {
        return configured_token
            .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.as_bytes()))
            || mux.authenticate_pairing_credential(&provided);
    }
    if !pairing_request(&text) {
        return false;
    }

    let (challenge, decision) = match mux.begin_pairing(peer.ip()) {
        Ok(pairing) => pairing,
        Err(error) => {
            let _ = websocket.send(Message::Text(
                json!({"pairing_error": {"code": error.code(), "message": error.to_string()}})
                    .to_string()
                    .into(),
            ));
            return false;
        }
    };
    if websocket
        .send(Message::Text(
            json!({"pairing": {
                "id": challenge.id,
                "code": challenge.code,
                "peer": challenge.peer,
                "expires_in": challenge.expires_in,
            }})
            .to_string()
            .into(),
        ))
        .is_err()
    {
        mux.cancel_pairing(challenge.id);
        return false;
    }

    match decision.recv_timeout(Duration::from_secs(challenge.expires_in)) {
        Ok(PairingDecision::Approved { credential }) => websocket
            .send(Message::Text(json!({"paired": {"credential": credential}}).to_string().into()))
            .is_ok(),
        Ok(PairingDecision::Denied) | Err(_) => {
            mux.cancel_pairing(challenge.id);
            false
        }
    }
}

fn disconnect_client(mux: &Mux, client: u64, send_detached: bool) -> bool {
    let record = {
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        let Some(record) = mux.control_clients.remove(client) else { return false };
        mux.remove_size_client(client);
        record
    };
    if send_detached {
        let _ = record.writer.set_write_timeout(Some(CLIENT_DETACH_WRITE_TIMEOUT));
        for (surface, attached) in &record.attached {
            for stream in attached.streams.values() {
                let _ = record
                    .writer
                    .send_terminal(&json!({"event": "detached", "surface": surface}), stream);
            }
        }
    }
    record.writer.close();
    mux.emit(MuxEvent::ClientDetached(client));
    true
}

pub fn detach_control_client(mux: &Mux, client: u64) -> bool {
    disconnect_client(mux, client, true)
}

fn handle_message(mux: &Arc<Mux>, client: u64, message: &str, writer: &MessageWriter) -> bool {
    let mut detach_self = false;
    let response = match serde_json::from_str::<Request>(message) {
        Ok(req) => {
            let id = req.id.clone();
            detach_self =
                matches!(&req.cmd, Command::DetachClient { client: target } if *target == client);
            match handle_command(mux, client, req.cmd, writer) {
                Ok(data) => Response { id, ok: true, data: Some(data), error: None },
                Err(e) => Response { id, ok: false, data: None, error: Some(e.to_string()) },
            }
        }
        Err(e) => {
            Response { id: None, ok: false, data: None, error: Some(format!("bad request: {e}")) }
        }
    };
    let response_ok = response.ok;
    let sent =
        serde_json::to_value(&response).is_ok_and(|value| writer.send_control(&value).is_ok());
    if detach_self && response_ok && sent {
        disconnect_client(mux, client, true);
        return false;
    }
    sent
}

fn auth_token(message: &str) -> Option<String> {
    let value: Value = serde_json::from_str(message).ok()?;
    let object = value.as_object()?;
    if object.len() != 1 {
        return None;
    }
    let auth = object.get("auth")?.as_object()?;
    if auth.len() != 1 {
        return None;
    }
    auth.get("token")?.as_str().map(str::to_string)
}

fn pairing_request(message: &str) -> bool {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return false };
    let Some(object) = value.as_object() else { return false };
    if object.len() != 1 {
        return false;
    }
    let Some(pair) = object.get("pair").and_then(Value::as_object) else { return false };
    pair.len() == 1 && pair.get("request").and_then(Value::as_bool) == Some(true)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut difference = a.len() ^ b.len();
    let length = a.len().max(b.len());
    for index in 0..length {
        difference |=
            usize::from(a.get(index).copied().unwrap_or(0) ^ b.get(index).copied().unwrap_or(0));
    }
    difference == 0
}

fn node_json(node: &Node, active_pane: PaneId) -> Value {
    match node {
        Node::Leaf(id) => json!({ "type": "leaf", "pane": id }),
        Node::Split { id, dir, ratio, a, b } => json!({
            "type": "split",
            "split": id,
            "dir": match dir { SplitDir::Right => "right", SplitDir::Down => "down" },
            "ratio": ratio,
            "a": node_json(a, active_pane),
            "b": node_json(b, active_pane),
        }),
        Node::Stack { panes, expanded } => json!({
            "type": "stack",
            "panes": panes.as_slice(),
            "expanded": if panes.contains(&active_pane) {
                active_pane
            } else {
                *expanded
            },
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
        LayoutRequest::Stack { panes, expanded } => {
            if panes.is_empty() {
                anyhow::bail!("stack must contain at least one pane");
            }
            let Some(expanded_index) = panes.iter().position(|pane| *pane == expanded) else {
                anyhow::bail!("stack expanded pane must be a member");
            };
            Ok(LayoutSpec::Stack { pane_count: panes.len(), expanded_index })
        }
    }
}

fn parse_split_dir(dir: &str) -> anyhow::Result<SplitDir> {
    match dir {
        "right" => Ok(SplitDir::Right),
        "down" => Ok(SplitDir::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"right\" or \"down\")"),
    }
}

fn optional_surface_size(cols: Option<u16>, rows: Option<u16>) -> Option<(u16, u16)> {
    cols.zip(rows).map(|(cols, rows)| (cols.max(1), rows.max(1)))
}

fn paired_surface_size(
    command: &str,
    cols: Option<u16>,
    rows: Option<u16>,
) -> anyhow::Result<Option<(u16, u16)>> {
    match (cols, rows) {
        (Some(cols), Some(rows)) => Ok(Some((cols.max(1), rows.max(1)))),
        (None, None) => Ok(None),
        _ => anyhow::bail!("{command} cols and rows must be supplied together"),
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
        "layout": node_json(&screen.root, screen.active_pane),
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
        "focused_at": pane.focused_at,
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
        "layout": node_json(&screen.root, screen.active_pane),
        "panes": pane_ids.iter().map(|id| pane_json(state, *id, short_ids, notifications)).collect::<Vec<_>>(),
    })
}

fn workspaces_json(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let short_ids = tree_short_ids(state);
    json!({
        "workspace_revision": state.workspace_revision,
        "pane_revision": state.pane_revision,
        "workspaces": state.workspaces.iter().enumerate().map(|(index, workspace)| {
            workspace_json(state, workspace, index, &short_ids, notifications)
        }).collect::<Vec<_>>(),
    })
}

fn tree_short_ids(state: &State) -> HashMap<u64, String> {
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
    assign_short_ids(ids)
}

fn workspace_json(
    state: &State,
    workspace: &Workspace,
    index: usize,
    short_ids: &HashMap<u64, String>,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    json!({
        "id": workspace.id,
        "key": workspace.key,
        "short_id": short_ids.get(&workspace.id).cloned().unwrap_or_default(),
        "name": workspace.name,
        "active": index == state.active_workspace,
        "screens": workspace.screens.iter().enumerate().map(|(screen_index, screen)| {
            screen_json(
                state,
                screen,
                screen_index == workspace.active_screen,
                short_ids,
                notifications,
            )
        }).collect::<Vec<_>>(),
    })
}

pub(crate) fn tree_entity_json(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    kind: TreeDeltaKind,
    id: u64,
) -> Option<Value> {
    if matches!(
        kind,
        TreeDeltaKind::WorkspaceAdded
            | TreeDeltaKind::WorkspaceClosed
            | TreeDeltaKind::WorkspaceRenamed
            | TreeDeltaKind::WorkspaceMoved
    ) {
        let short_ids = tree_short_ids(state);
        let index = state.workspace_index(id)?;
        let workspace = state.workspaces.get(index)?;
        return Some(workspace_json(state, workspace, index, &short_ids, notifications));
    }
    let tree = workspaces_json(state, notifications);
    let workspaces = tree.get("workspaces")?.as_array()?;
    match kind {
        TreeDeltaKind::WorkspaceAdded
        | TreeDeltaKind::WorkspaceClosed
        | TreeDeltaKind::WorkspaceRenamed
        | TreeDeltaKind::WorkspaceMoved => unreachable!("workspace deltas returned above"),
        TreeDeltaKind::ScreenAdded | TreeDeltaKind::ScreenClosed | TreeDeltaKind::ScreenRenamed => {
            workspaces
                .iter()
                .flat_map(|workspace| {
                    workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
                })
                .find(|screen| screen.get("id").and_then(Value::as_u64) == Some(id))
                .cloned()
        }
        TreeDeltaKind::PaneAdded | TreeDeltaKind::PaneClosed => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
            .find(|pane| pane.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::TabAdded | TreeDeltaKind::TabClosed | TreeDeltaKind::TabRenamed => {
            workspaces
                .iter()
                .flat_map(|workspace| {
                    workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
                })
                .flat_map(|screen| {
                    screen.get("panes").and_then(Value::as_array).into_iter().flatten()
                })
                .flat_map(|pane| pane.get("tabs").and_then(Value::as_array).into_iter().flatten())
                .find(|tab| tab.get("surface").and_then(Value::as_u64) == Some(id))
                .cloned()
        }
    }
}

fn tree_delta_json(delta: &TreeDelta) -> Value {
    let mut value = json!({
        "event": delta.kind.as_str(),
        "workspace": delta.workspace,
        "entity": delta.entity,
    });
    if let Some(screen) = delta.screen {
        value["screen"] = json!(screen);
    }
    if let Some(pane) = delta.pane {
        value["pane"] = json!(pane);
    }
    if let Some(surface) = delta.surface {
        value["surface"] = json!(surface);
    }
    if let Some(index) = delta.index {
        value["index"] = json!(index);
    }
    if let Some(revision) = delta.workspace_revision {
        value["workspace_revision"] = json!(revision);
    }
    value
}

fn ids_json(state: &State, kind: Option<&str>) -> anyhow::Result<Value> {
    let allowed = ["workspace", "screen", "pane", "surface"];
    if let Some(kind) = kind
        && !allowed.contains(&kind)
    {
        anyhow::bail!("bad kind {kind}");
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

fn resolve_workspace(
    mux: &Mux,
    id: Option<WorkspaceId>,
    key: Option<&str>,
) -> anyhow::Result<(WorkspaceId, String)> {
    mux.with_state(|state| {
        let by_id = id.and_then(|id| state.workspace_by_id(id));
        let by_key = key.and_then(|key| state.workspace_by_key(key));
        let workspace = match (id, key, by_id, by_key) {
            (None, None, _, _) => anyhow::bail!("workspace or key is required"),
            (Some(id), None, Some(workspace), _) if workspace.id == id => workspace,
            (Some(id), None, None, _) => anyhow::bail!("unknown workspace {id}"),
            (None, Some(key), _, Some(workspace)) if workspace.key == key => workspace,
            (None, Some(key), _, None) => anyhow::bail!("unknown workspace key {key}"),
            (Some(_), Some(_), Some(by_id), Some(by_key)) if by_id.id == by_key.id => by_id,
            (Some(_), Some(_), _, _) => {
                anyhow::bail!("workspace id and key do not identify the same workspace")
            }
            _ => unreachable!("workspace selector cases are exhaustive"),
        };
        Ok((workspace.id, workspace.key.clone()))
    })
}

fn sidebar_plugin_status_json(status: SidebarPluginStatus) -> Value {
    let retry_after_ms = status.retry_after.map(|duration| duration.as_millis() as u64);
    json!({
        "surface": status.surface,
        "error": status.error,
        "retry_after_ms": retry_after_ms,
    })
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

fn color_hex(color: Option<Rgb>) -> Option<String> {
    color.map(|color| format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b))
}

fn terminal_colors_json(colors: TerminalColors) -> Value {
    let cursor_style = colors.cursor_style.map(|style| match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    });
    let palette = colors
        .palette
        .into_iter()
        .enumerate()
        .filter_map(|(index, color)| {
            color_hex(color).map(|color| (index.to_string(), Value::String(color)))
        })
        .collect::<serde_json::Map<String, Value>>();
    json!({
        "fg": color_hex(colors.fg),
        "bg": color_hex(colors.bg),
        "cursor": color_hex(colors.cursor),
        "selection_bg": color_hex(colors.selection_bg),
        "selection_fg": color_hex(colors.selection_fg),
        "palette": palette,
        "cursor_style": cursor_style,
        "cursor_blink": colors.cursor_blink,
    })
}

fn rgb_hex(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

fn styled_run_json(run: &StyledRun) -> Value {
    let underline = run.underline.map(|style| match style {
        UnderlineStyle::Single => "single",
        UnderlineStyle::Double => "double",
        UnderlineStyle::Curly => "curly",
        UnderlineStyle::Dotted => "dotted",
        UnderlineStyle::Dashed => "dashed",
    });
    let mut value = json!({
        "text": run.text,
        "fg": run.fg.map(rgb_hex),
        "bg": run.bg.map(rgb_hex),
        "attrs": run.attrs,
    });
    if let Some(underline) = underline {
        value["underline"] = json!(underline);
    }
    if let Some(width_hint) = run.width_hint {
        value["width_hint"] = json!(width_hint);
    }
    value
}

fn render_rows_json(frame: &SurfaceRenderFrame, rows: impl IntoIterator<Item = u16>) -> Vec<Value> {
    rows.into_iter()
        .filter_map(|row| {
            frame.frame.row_runs(row).map(|runs| {
                json!({
                    "row": row,
                    "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                })
            })
        })
        .collect()
}

fn render_cursor_json(frame: &SurfaceRenderFrame) -> Value {
    let (style, blink) = frame.frame.cursor_visual;
    let style = match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    };
    let (x, y, visible) =
        frame.frame.cursor.map(|cursor| (cursor.x, cursor.y, true)).unwrap_or((0, 0, false));
    json!({
        "x": x,
        "y": y,
        "style": style,
        "blink": blink,
        "visible": visible,
        "color": frame.frame.cursor_color.map(rgb_hex),
    })
}

fn render_state_json(surface: SurfaceId, frame: &SurfaceRenderFrame) -> Value {
    let (cols, rows) = frame.frame.size;
    json!({
        "event": "render-state",
        "surface": surface,
        "size": { "cols": cols, "rows": rows },
        "cursor": render_cursor_json(frame),
        "default_fg": rgb_hex(frame.frame.default_colors.1),
        "default_bg": rgb_hex(frame.frame.default_colors.0),
        "scrollback_rows": frame.scrollback_rows,
        "rows": render_rows_json(frame, 0..rows),
    })
}

struct RenderClientState {
    size: (u16, u16),
    default_colors: (Rgb, Rgb),
    scrollback_rows: u32,
}

impl RenderClientState {
    fn new(frame: &SurfaceRenderFrame) -> Self {
        Self {
            size: frame.frame.size,
            default_colors: frame.frame.default_colors,
            scrollback_rows: frame.scrollback_rows,
        }
    }

    fn delta_json(&mut self, surface: SurfaceId, frame: &SurfaceRenderFrame) -> Value {
        let size_changed = self.size != frame.frame.size;
        let foreground_changed = self.default_colors.1 != frame.frame.default_colors.1;
        let background_changed = self.default_colors.0 != frame.frame.default_colors.0;
        let scrollback_changed = self.scrollback_rows != frame.scrollback_rows;
        let full = size_changed
            || foreground_changed
            || background_changed
            || frame.frame.dirty == Dirty::Full;
        let rows = if full {
            render_rows_json(frame, 0..frame.frame.size.1)
        } else {
            render_rows_json(frame, frame.frame.dirty_rows.iter().copied())
        };
        let mut value = json!({
            "event": "render-delta",
            "surface": surface,
            "cursor": render_cursor_json(frame),
            "full": full,
            "rows": rows,
        });
        if size_changed {
            value["size"] = json!({ "cols": frame.frame.size.0, "rows": frame.frame.size.1 });
        }
        if foreground_changed {
            value["default_fg"] = json!(rgb_hex(frame.frame.default_colors.1));
        }
        if background_changed {
            value["default_bg"] = json!(rgb_hex(frame.frame.default_colors.0));
        }
        if scrollback_changed {
            value["scrollback_rows"] = json!(frame.scrollback_rows);
        }
        self.size = frame.frame.size;
        self.default_colors = frame.frame.default_colors;
        self.scrollback_rows = frame.scrollback_rows;
        value
    }
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
    writer: MessageWriter,
    lifecycle: AttachLifecycle,
    outbound_stream: OutboundStream,
) -> std::io::Result<()> {
    let events = mux.subscribe_attached_surface(surface_id);
    std::thread::Builder::new()
        .name("mux-attach-notifications".into())
        .spawn(move || {
            while writer.is_open() && outbound_stream.is_open() && !lifecycle.is_canceled() {
                let event = match events.recv_timeout(STREAM_DISCONNECT_POLL) {
                    Ok(event) => event,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
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
                if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                    handle_attach_send_error(&lifecycle, &error);
                    break;
                }
            }
            if events.overflowed() {
                lifecycle.mark_overflow();
            }
            report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
        })
        .map(|_| ())
}

fn report_attach_overflow(
    writer: &MessageWriter,
    surface_id: SurfaceId,
    lifecycle: &AttachLifecycle,
    outbound_stream: &OutboundStream,
) {
    if lifecycle.claim_overflow_report() {
        let _ = writer.send_terminal(&attach_overflow_json(surface_id), outbound_stream);
    }
}

fn handle_attach_send_error(lifecycle: &AttachLifecycle, error: &std::io::Error) {
    if error.kind() == std::io::ErrorKind::WouldBlock {
        lifecycle.mark_overflow();
    } else {
        lifecycle.cancel();
    }
}

struct MarkedClientAttach {
    size_rollback: Option<crate::mux::ClientSizeRollback>,
    client_changed: Option<(Option<String>, Option<String>)>,
    resize_reservation: Option<u64>,
    resize_completion: Option<std::sync::mpsc::Receiver<Result<(), Arc<str>>>>,
}

fn mark_client_attached(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
) -> anyhow::Result<MarkedClientAttach> {
    mux.control_clients.attach_surface(client, surface, stream.clone())?;
    if let Some((cols, rows)) = initial_size {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let is_browser = mux.surface(surface).is_some_and(|surface| surface.as_browser().is_some());
        let (completion_tx, completion_rx) = std::sync::mpsc::sync_channel(1);
        let resize = mux
            .resize_surface_for_control_client_with_completion(
                surface,
                client,
                cols,
                rows,
                is_browser.then_some(completion_tx),
            )
            .inspect_err(|_| {
                cleanup_failed_attach(mux, client, surface, stream.id);
            })?;
        let Some((changed, name, kind, _)) = resize.attached else {
            cleanup_failed_attach(mux, client, surface, stream.id);
            anyhow::bail!("client {client} is not attached to surface {surface}");
        };
        let mut resize_reservation = resize.reservation_id;
        let mut resize_completion = is_browser.then_some(completion_rx);
        let effective_size = resize.effective_size;
        let rollback = resize.rollback;
        if resize_reservation.is_none()
            && let Some((effective_cols, effective_rows)) = effective_size
        {
            let Some(attached_surface) = mux.surface(surface) else {
                rollback_failed_attach(mux, client, surface, stream.id, Some(rollback));
                anyhow::bail!("surface {surface} disappeared while sizing before attach");
            };
            match attached_surface.pending_resize_completion(effective_cols, effective_rows) {
                Ok(Some(pending)) => {
                    resize_reservation = Some(pending.reservation);
                    resize_completion = Some(pending.completion);
                }
                Ok(None) => {}
                Err(error) => {
                    rollback_failed_attach(mux, client, surface, stream.id, Some(rollback));
                    return Err(error);
                }
            }
        }
        return Ok(MarkedClientAttach {
            size_rollback: Some(rollback),
            client_changed: changed.then_some((name, kind)),
            resize_reservation,
            resize_completion,
        });
    }
    Ok(MarkedClientAttach {
        size_rollback: None,
        client_changed: None,
        resize_reservation: None,
        resize_completion: None,
    })
}

fn wait_for_initial_browser_resize(
    completion: &std::sync::mpsc::Receiver<Result<(), Arc<str>>>,
    surface: SurfaceId,
    reservation: u64,
) -> anyhow::Result<()> {
    match completion.recv_timeout(INITIAL_BROWSER_RESIZE_TIMEOUT) {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => {
            anyhow::bail!(
                "failed to size browser surface {surface} before attach (reservation {reservation}): {error}"
            )
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            anyhow::bail!("timed out sizing browser surface {surface} before attach");
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            anyhow::bail!(
                "browser resize completion disconnected before attach (surface {surface}, reservation {reservation})"
            )
        }
    }
}

fn announce_client_attached(mux: &Mux, client: u64) -> anyhow::Result<bool> {
    if let Some((transport, name, kind)) = mux.control_clients.announce_attached(client)? {
        mux.emit(MuxEvent::ClientAttached { client, transport, name, kind });
        return Ok(true);
    }
    Ok(false)
}

fn commit_client_attach(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    changed: Option<(Option<String>, Option<String>)>,
    rollback: Option<crate::mux::ClientSizeRollback>,
) -> anyhow::Result<()> {
    mux.control_clients.commit_surface(client, surface, stream, rollback)?;
    let newly_announced = announce_client_attached(mux, client)?;
    if !newly_announced && let Some((name, kind)) = changed {
        mux.emit(MuxEvent::ClientChanged { client, name, kind });
    }
    Ok(())
}

struct AttachWorkerCommit {
    start: std::sync::mpsc::SyncSender<()>,
    lifecycle: AttachLifecycle,
    changed: Option<(Option<String>, Option<String>)>,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
}

fn commit_client_attach_and_start_worker(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    worker: AttachWorkerCommit,
) -> anyhow::Result<()> {
    if let Err(error) =
        commit_client_attach(mux, client, surface, stream, worker.changed, worker.size_rollback)
    {
        worker.lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, worker.size_rollback);
        return Err(error);
    }
    if worker.start.send(()).is_err() {
        worker.lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, worker.size_rollback);
        anyhow::bail!("attach output worker exited before stream {stream} was committed");
    }
    Ok(())
}

fn cleanup_failed_attach(mux: &Mux, client: u64, surface: SurfaceId, stream: u64) {
    if mux.control_clients.detach_surface(client, surface, stream).final_stream {
        mux.remove_surface_size_client(surface, client);
    }
}

fn rollback_failed_attach(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
) {
    let detached = mux.control_clients.detach_surface(client, surface, stream);
    if let Some(size_rollback) = detached.rollback.or(size_rollback) {
        mux.rollback_surface_size_client(surface, client, size_rollback);
    }
    if detached.final_stream {
        mux.remove_surface_size_client(surface, client);
    }
}

fn detach_committed_attach(mux: &Mux, client: u64, surface: SurfaceId, stream: u64) {
    let detached = mux.control_clients.detach_surface(client, surface, stream);
    if detached.final_stream {
        mux.remove_surface_size_client(surface, client);
    } else if let Some(rollback) = detached.rollback {
        mux.rollback_surface_size_client(surface, client, rollback);
    }
}

fn handle_command(
    mux: &Arc<Mux>,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    match cmd {
        Command::Identify => Ok(json!({
            "app": "cmux-tui",
            "version": env!("CARGO_PKG_VERSION"),
            "build_commit": stamped_build_commit(),
            "ghostty_commit": stamped_ghostty_commit(),
            "protocol": PROTOCOL_VERSION,
            "capabilities": [ATTACH_INITIAL_SIZE_CAPABILITY, WORKSPACE_REGISTRY_CAPABILITY],
            "session": mux.session,
            "pid": std::process::id(),
        })),
        Command::Ping => Ok(json!({
            "ok": true,
            "version": env!("CARGO_PKG_VERSION"),
            "build_commit": stamped_build_commit(),
            "ghostty_commit": stamped_ghostty_commit(),
            "protocol": PROTOCOL_VERSION,
        })),
        Command::SetClientInfo { name, kind } => {
            let (name, kind) = mux.control_clients.set_info(client, name, kind)?;
            mux.emit(MuxEvent::ClientChanged { client, name, kind });
            Ok(json!({}))
        }
        Command::ListClients => Ok(mux.control_clients_json(client)),
        Command::SetClientSizing { client: target, enabled, exclusive } => {
            if exclusive && !enabled {
                anyhow::bail!("exclusive client sizing must be enabled");
            }
            if let Some(target) = target {
                if exclusive {
                    mux.use_only_client_size(target)
                        .ok_or_else(|| anyhow::anyhow!("unknown client {target}"))?;
                } else {
                    mux.set_client_size_participation(target, enabled)
                        .ok_or_else(|| anyhow::anyhow!("unknown client {target}"))?;
                }
            } else if enabled {
                mux.use_all_client_sizes();
            } else {
                anyhow::bail!("client is required when disabling sizing");
            }
            Ok(json!({}))
        }
        Command::PairingResponse { request, approve } => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("pairing decisions require a trusted local connection");
            }
            if !mux.respond_pairing(request, approve) {
                anyhow::bail!("unknown or expired pairing request {request}");
            }
            Ok(json!({}))
        }
        Command::DetachClient { client: target } => {
            if target == client {
                if !mux.control_clients.contains(target) {
                    anyhow::bail!("unknown client {target}");
                }
            } else if !disconnect_client(mux, target, true) {
                anyhow::bail!("unknown client {target}");
            }
            Ok(json!({}))
        }
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
        Command::ApplyLayout { workspace, name, layout, cols, rows } => {
            let layout = layout_request_to_spec(layout)?;
            let applied =
                mux.apply_layout(workspace, name, &layout, optional_surface_size(cols, rows))?;
            Ok(json!({
                "screen": applied.screen,
                "panes": applied.panes.iter().map(|pane| {
                    json!({ "pane": pane.pane, "surface": pane.surface })
                }).collect::<Vec<_>>(),
            }))
        }
        Command::Send { surface, text, bytes, paste } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            if paste {
                let mut payload = text.unwrap_or_default().into_bytes();
                if let Some(b64) = bytes {
                    payload.extend(base64::engine::general_purpose::STANDARD.decode(b64)?);
                }
                surface.write_paste(&payload)?;
            } else {
                if let Some(text) = text {
                    surface.write_bytes(text.as_bytes())?;
                }
                if let Some(b64) = bytes {
                    let raw = base64::engine::general_purpose::STANDARD.decode(b64)?;
                    surface.write_bytes(&raw)?;
                }
            }
            Ok(json!({}))
        }
        Command::ReadScreen { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let text = surface.try_with_terminal(|t| t.viewport_text())??;
            Ok(json!({ "text": text }))
        }
        Command::ReadScrollback { surface, start, count } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let count = u16::try_from(count).map_err(|_| anyhow::anyhow!("count out of range"))?;
            let (start, total, rows) = surface.try_with_terminal(|term| {
                let total = term.history_rows();
                let start = start.min(total);
                term.styled_history_rows(start, count).map(|rows| (start, total, rows))
            })??;
            let runs = rows_to_runs(&rows);
            let rows = runs
                .iter()
                .enumerate()
                .map(|(row, runs)| {
                    json!({
                        "row": row as u16,
                        "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({ "rows": rows, "start": start, "total": total }))
        }
        Command::SidebarPlugin { cols, rows, relaunch } => {
            Ok(sidebar_plugin_status_json(mux.ensure_sidebar_plugin(cols, rows, relaunch)))
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
            let deadline = start + Duration::from_millis(timeout_ms);
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
            let placement = mux.run_command_surface(
                argv,
                pane,
                new_workspace,
                cwd,
                name,
                optional_surface_size(cols, rows),
            )?;
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
                t.vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
                    .map(|replay| (t.cols(), t.rows(), replay))
            })??;
            Ok(json!({
                "cols": cols,
                "rows": rows,
                "data": base64::engine::general_purpose::STANDARD.encode(replay),
            }))
        }
        Command::NewTab { pane, cwd, cols, rows } => {
            let surface = mux.new_tab(pane, cwd, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::NewBrowserTab { url, pane, cols, rows } => {
            let surface = mux.new_browser_tab(url, pane, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::SetCellPixels { width_px, height_px } => {
            let update = mux.set_cell_pixel_size(width_px, height_px);
            let resizes = update
                .resizes
                .into_iter()
                .map(|(surface, (cols, rows), reservation_id)| {
                    json!({
                        "surface": surface,
                        "cols": cols,
                        "rows": rows,
                        "reservation_id": reservation_id,
                    })
                })
                .collect::<Vec<_>>();
            let failures = update
                .failures
                .into_iter()
                .map(|failure| {
                    json!({
                        "surface": failure.surface,
                        "error": failure.error,
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"resizes": resizes, "failures": failures}))
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
            let surface = mux.new_workspace(name, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::CreateWorkspace { name, key, expected_revision } => {
            let placement = mux.create_empty_workspace(name, key, expected_revision)?;
            Ok(json!({
                "workspace": placement.workspace,
                "key": placement.key,
                "index": placement.index,
                "workspace_revision": placement.revision,
            }))
        }
        Command::CreateTerminal { workspace, key, argv, command, cwd, name, cols, rows } => {
            if argv.is_some() && command.is_some() {
                anyhow::bail!("argv and command are mutually exclusive");
            }
            let argv = match (argv, command) {
                (Some(argv), None) if !argv.is_empty() => Some(argv),
                (None, Some(command)) if !command.is_empty() => {
                    Some(vec![platform::default_shell(), "-lc".to_string(), command])
                }
                (None, None) => None,
                _ => anyhow::bail!("argv or command must be non-empty when provided"),
            };
            let (workspace, key) = resolve_workspace(mux, workspace, key.as_deref())?;
            let size = paired_surface_size("create-terminal", cols, rows)?;
            let placement = mux.create_terminal_in_workspace(workspace, argv, cwd, name, size)?;
            Ok(json!({
                "surface": placement.surface,
                "pane": placement.pane,
                "screen": placement.screen,
                "workspace": placement.workspace,
                "key": key,
            }))
        }
        Command::NewScreen { workspace, cols, rows } => {
            let surface = mux.new_screen(workspace, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::NewPane { pane, cols, rows } => {
            let surface = mux.new_pane(pane, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::Split { pane, dir, cols, rows } => {
            let dir = parse_split_dir(&dir)?;
            let surface = mux.split(pane, dir, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::SetRatio { pane, dir, ratio } => {
            let dir = parse_split_dir(&dir)?;
            if !mux.set_ratio(pane, dir, ratio) {
                anyhow::bail!("unknown pane/split {pane}");
            }
            Ok(json!({}))
        }
        Command::SetSplitRatio { split, ratio } => {
            if !mux.set_split_ratio(split, ratio) {
                anyhow::bail!("unknown split {split}");
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
        Command::MoveWorkspace { workspace, key, index, expected_revision } => {
            let Some((workspace, key, revision, _)) = mux.move_workspace_selector_at_revision(
                workspace,
                key.as_deref(),
                index,
                expected_revision,
            )?
            else {
                anyhow::bail!("unknown workspace selector");
            };
            Ok(json!({"workspace": workspace, "key": key, "workspace_revision": revision}))
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
                ..current
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
        Command::CloseWorkspace { workspace, key, expected_revision } => {
            let Some((workspace, key, revision)) = mux.close_workspace_selector_at_revision(
                workspace,
                key.as_deref(),
                expected_revision,
            )?
            else {
                anyhow::bail!("unknown workspace selector");
            };
            Ok(json!({"workspace": workspace, "key": key, "workspace_revision": revision}))
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
        Command::RenameWorkspace { workspace, key, name, expected_revision } => {
            let Some((workspace, key, revision)) = mux.rename_workspace_selector_at_revision(
                workspace,
                key.as_deref(),
                name,
                expected_revision,
            )?
            else {
                anyhow::bail!("unknown workspace selector");
            };
            Ok(json!({"workspace": workspace, "key": key, "workspace_revision": revision}))
        }
        Command::ResizeSurface { surface, cols, rows } => {
            let (cols, rows) = clamp_terminal_size(cols, rows);
            // Every live control connection participates through the same
            // client-size reducer. An unattached one-shot resize is removed
            // when its connection closes, so it cannot bypass visible viewers.
            // Recording and reducing happen under the sizing lock so a
            // concurrent detach cannot finish cleanup before this lease exists.
            let resize = mux
                .resize_surface_for_control_client_with_reservation(surface, client, cols, rows)?;
            if let Some((true, name, kind, _)) = resize.attached {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok(json!({
                "accepted": resize.accepted,
                "reservation_id": resize.reservation_id,
            }))
        }
        Command::ReleaseSurfaceSize { surface } => {
            let attached = mux.control_clients.clear_size(client, surface);
            let had_report = mux.client_surface_size(surface, client).is_some();
            if had_report {
                mux.remove_surface_size_client(surface, client);
            }
            let attached_changed = attached.as_ref().is_some_and(|(changed, _, _)| *changed);
            if attached_changed || (attached.is_none() && had_report) {
                let (name, kind) = attached
                    .map(|(_, name, kind)| (name, kind))
                    .or_else(|| mux.control_clients.client_info(client))
                    .unwrap_or((None, None));
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
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
        Command::Subscribe { tree_events } => {
            let tree_deltas = match tree_events.as_deref().unwrap_or("coarse") {
                "coarse" => false,
                "deltas" => true,
                other => anyhow::bail!("bad request: unsupported tree_events {other:?}"),
            };
            let events = mux.subscribe();
            let trusted_pairing_client = mux.control_clients.is_unix(client);
            let pending_pairings =
                if trusted_pairing_client { mux.pending_pairings() } else { Vec::new() };
            let writer = writer.clone();
            let outbound_stream = writer.start_stream(&subscription_overflow_json())?;
            std::thread::Builder::new().name("mux-events-out".into()).spawn(move || {
                let mut transport_overflow = false;
                for challenge in pending_pairings {
                    let value = json!({
                        "event": "pairing-requested",
                        "request": challenge.id,
                        "code": challenge.code,
                        "peer": challenge.peer,
                        "expires_in": challenge.expires_in,
                    });
                    if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                        transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                        break;
                    }
                }
                while writer.is_open() && outbound_stream.is_open() {
                    let event = match events.recv_timeout(STREAM_DISCONNECT_POLL) {
                        Ok(event) => event,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    let value = match &event {
                        MuxEvent::PairingRequested(_) | MuxEvent::PairingResolved { .. }
                            if !trusted_pairing_client =>
                        {
                            continue;
                        }
                        MuxEvent::PairingRequested(challenge) => json!({
                            "event": "pairing-requested",
                            "request": challenge.id,
                            "code": challenge.code,
                            "peer": challenge.peer,
                            "expires_in": challenge.expires_in,
                        }),
                        MuxEvent::PairingResolved { request } => json!({
                            "event": "pairing-resolved",
                            "request": request,
                        }),
                        MuxEvent::TreeDelta(delta) if tree_deltas => tree_delta_json(delta),
                        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
                        MuxEvent::TreeSelectionChanged if tree_deltas => {
                            json!({"event": "tree-changed"})
                        }
                        MuxEvent::TreeSelectionChanged => continue,
                        _ => subscribed_event_json(&event),
                    };
                    if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                        transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                        break;
                    }
                }
                if events.overflowed() || transport_overflow {
                    let _ = writer.send_terminal(&subscription_overflow_json(), &outbound_stream);
                }
            })?;
            Ok(json!({}))
        }
        Command::AttachSurface { surface: surface_id, mode, cols, rows } => {
            let initial_size = match (cols, rows) {
                (Some(cols), Some(rows)) => Some((cols, rows)),
                (None, None) => None,
                _ => anyhow::bail!("attach-surface cols and rows must be supplied together"),
            };
            let surface = get_surface(mux, surface_id)?;
            let lifecycle = AttachLifecycle::default();
            let outbound_stream = writer.start_stream(&attach_overflow_json(surface_id))?;
            let render_mode = match mode.as_deref().unwrap_or("bytes") {
                "bytes" => false,
                "render" => true,
                other => anyhow::bail!("bad attach mode {other}"),
            };
            if render_mode {
                require_pty(&surface)?;
                let MarkedClientAttach { size_rollback, client_changed, .. } =
                    mark_client_attached(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.clone(),
                        initial_size,
                    )?;
                let attach = match surface.attach_render_stream() {
                    Ok(attach) => attach,
                    Err(error) => {
                        rollback_failed_attach(
                            mux,
                            client,
                            surface_id,
                            outbound_stream.id,
                            size_rollback,
                        );
                        return Err(error.into());
                    }
                };
                if let Err(error) = writer
                    .send_initial(&render_state_json(surface_id, &attach.initial), &outbound_stream)
                {
                    handle_attach_send_error(&lifecycle, &error);
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                let worker_writer = writer.clone();
                let worker_mux = mux.clone();
                let worker_lifecycle = lifecycle.clone();
                let worker_stream = outbound_stream.clone();
                let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
                let spawned = std::thread::Builder::new()
                    .name("mux-render-attach-out".into())
                    .spawn(move || {
                        let writer = worker_writer;
                        let mux = worker_mux;
                        let lifecycle = worker_lifecycle;
                        let outbound_stream = worker_stream;
                        if worker_committed.recv().is_err() {
                            return;
                        }
                        let mut state = RenderClientState::new(&attach.initial);
                        while writer.is_open()
                            && outbound_stream.is_open()
                            && !lifecycle.is_canceled()
                        {
                            let value = match attach.stream.recv_timeout(STREAM_DISCONNECT_POLL) {
                                Ok(RenderAttachFrame::Frame(frame)) => {
                                    state.delta_json(surface_id, &frame)
                                }
                                Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                                    json!({
                                        "event": "scroll-changed",
                                        "surface": surface_id,
                                        "offset": offset,
                                        "at_bottom": at_bottom,
                                    })
                                }
                                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                            };
                            if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                                handle_attach_send_error(&lifecycle, &error);
                                break;
                            }
                        }
                        if writer.is_open() && !lifecycle.overflowed() {
                            let _ = writer.send_stream(
                                &json!({"event": "detached", "surface": surface_id}),
                                &outbound_stream,
                            );
                        }
                        report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                        detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                    });
                if let Err(error) = spawned {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                commit_client_attach_and_start_worker(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.id,
                    AttachWorkerCommit {
                        start: worker_start,
                        lifecycle,
                        changed: client_changed,
                        size_rollback,
                    },
                )?;
                return Ok(json!({}));
            }
            if surface.kind() == SurfaceKind::Browser {
                let MarkedClientAttach {
                    size_rollback,
                    client_changed,
                    resize_reservation,
                    resize_completion,
                } = mark_client_attached(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.clone(),
                    initial_size,
                )?;
                if let Some(reservation) = resize_reservation
                    && let Err(error) = wait_for_initial_browser_resize(
                        resize_completion
                            .as_ref()
                            .expect("sized browser attach has a completion receiver"),
                        surface_id,
                        reservation,
                    )
                {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error);
                }
                let (state, frames) = match surface.attach_frames() {
                    Ok(attach) => attach,
                    Err(error) => {
                        lifecycle.cancel();
                        rollback_failed_attach(
                            mux,
                            client,
                            surface_id,
                            outbound_stream.id,
                            size_rollback,
                        );
                        return Err(error);
                    }
                };
                if let Err(error) = writer
                    .send_initial(&browser_state_json(surface_id, &state, true), &outbound_stream)
                {
                    handle_attach_send_error(&lifecycle, &error);
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                if let Err(error) = spawn_attach_notification_stream(
                    mux.clone(),
                    surface_id,
                    writer.clone(),
                    lifecycle.clone(),
                    outbound_stream.clone(),
                ) {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                let worker_writer = writer.clone();
                let worker_mux = mux.clone();
                let worker_lifecycle = lifecycle.clone();
                let worker_stream = outbound_stream.clone();
                let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
                let spawned =
                    std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                        let writer = worker_writer;
                        let mux = worker_mux;
                        let lifecycle = worker_lifecycle;
                        let outbound_stream = worker_stream;
                        if worker_committed.recv().is_err() {
                            return;
                        }
                        while writer.is_open()
                            && outbound_stream.is_open()
                            && !lifecycle.is_canceled()
                        {
                            match frames.notify.recv_timeout(STREAM_DISCONNECT_POLL) {
                                Ok(()) => {}
                                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                    lifecycle.cancel();
                                    if writer.is_open() {
                                        let _ = writer.send_stream(
                                            &json!({"event": "detached", "surface": surface_id}),
                                            &outbound_stream,
                                        );
                                    }
                                    break;
                                }
                            }
                            let update = std::mem::take(&mut *frames.slot.lock().unwrap());
                            if let Some(state) = update.state {
                                let value = browser_state_json(surface_id, &state, false);
                                if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                                    handle_attach_send_error(&lifecycle, &error);
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
                                if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                                    handle_attach_send_error(&lifecycle, &error);
                                    break;
                                }
                            }
                        }
                        report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                        detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                    });
                if let Err(error) = spawned {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                commit_client_attach_and_start_worker(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.id,
                    AttachWorkerCommit {
                        start: worker_start,
                        lifecycle,
                        changed: client_changed,
                        size_rollback,
                    },
                )?;
                return Ok(json!({}));
            }
            let MarkedClientAttach { size_rollback, client_changed, .. } = mark_client_attached(
                mux,
                client,
                surface_id,
                outbound_stream.clone(),
                initial_size,
            )?;
            let attach = match surface.attach_stream_with_lifecycle(lifecycle.clone()) {
                Ok(attach) => attach,
                Err(error) => {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
            };
            if let Err(error) = writer.send_initial(
                &json!({
                    "event": "vt-state",
                    "surface": surface_id,
                    "cols": attach.cols,
                    "rows": attach.rows,
                    "data": base64::engine::general_purpose::STANDARD.encode(attach.replay),
                    "colors": terminal_colors_json(attach.colors),
                }),
                &outbound_stream,
            ) {
                handle_attach_send_error(&lifecycle, &error);
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            if let Err(error) = spawn_attach_notification_stream(
                mux.clone(),
                surface_id,
                writer.clone(),
                lifecycle.clone(),
                outbound_stream.clone(),
            ) {
                lifecycle.cancel();
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            let worker_writer = writer.clone();
            let worker_mux = mux.clone();
            let worker_stream = outbound_stream.clone();
            let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
            let spawned =
                std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                    let writer = worker_writer;
                    let mux = worker_mux;
                    let outbound_stream = worker_stream;
                    if worker_committed.recv().is_err() {
                        return;
                    }
                    while writer.is_open()
                        && outbound_stream.is_open()
                        && !attach.lifecycle.is_canceled()
                    {
                        let frame = match attach.stream.recv_timeout(STREAM_DISCONNECT_POLL) {
                            Ok(frame) => frame,
                            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                attach.lifecycle.cancel();
                                if writer.is_open() {
                                    let _ = writer.send_stream(
                                        &json!({"event": "detached", "surface": surface_id}),
                                        &outbound_stream,
                                    );
                                }
                                break;
                            }
                        };
                        let value = match frame {
                            AttachFrame::Output(chunk) => json!({
                                "event": "output",
                                "surface": surface_id,
                                "data": base64::engine::general_purpose::STANDARD.encode(chunk),
                            }),
                            AttachFrame::Resized { cols, rows, replay, colors } => {
                                json!({
                                    "event": "resized",
                                    "surface": surface_id,
                                    "cols": cols,
                                    "rows": rows,
                                    "replay": base64::engine::general_purpose::STANDARD.encode(replay),
                                    "colors": terminal_colors_json(*colors),
                                })
                            }
                            AttachFrame::ColorsChanged(colors) => {
                                let mut value = terminal_colors_json(*colors);
                                value["event"] = json!("colors-changed");
                                value["surface"] = json!(surface_id);
                                value
                            }
                        };
                        if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                            handle_attach_send_error(&attach.lifecycle, &error);
                            break;
                        }
                    }
                    report_attach_overflow(
                        &writer,
                        surface_id,
                        &attach.lifecycle,
                        &outbound_stream,
                    );
                    detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                });
            if let Err(error) = spawned {
                lifecycle.cancel();
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            commit_client_attach_and_start_worker(
                mux,
                client,
                surface_id,
                outbound_stream.id,
                AttachWorkerCommit {
                    start: worker_start,
                    lifecycle,
                    changed: client_changed,
                    size_rollback,
                },
            )?;
            Ok(json!({}))
        }
    }
}

fn stamped_build_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_BUILD_COMMIT")
        .or(option_env!("CMUX_MUX_BUILD_COMMIT"))
        .filter(|commit| !commit.is_empty())
}

fn stamped_ghostty_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_GHOSTTY_COMMIT").filter(|commit| !commit.is_empty())
}

fn subscribed_event_json(event: &MuxEvent) -> Value {
    match event {
        MuxEvent::SurfaceOutput(id) => json!({"event": "surface-output", "surface": id}),
        MuxEvent::SurfaceResized { surface, cols, rows, reservation_id } => json!({
            "event": "surface-resized",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceResizeFailed {
            surface,
            cols,
            rows,
            error,
            retry_after_ms,
            reservation_id,
        } => json!({
            "event": "surface-resize-failed",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "error": error.as_ref(),
            "retry_after_ms": retry_after_ms,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceExited(id) => json!({"event": "surface-exited", "surface": id}),
        MuxEvent::TitleChanged { surface, title } => {
            json!({"event": "title-changed", "surface": surface, "title": title.as_ref()})
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
        MuxEvent::Status(message) => json!({"event": "status", "message": message}),
        MuxEvent::ConfigReloadRequested => json!({"event": "config-reload-requested"}),
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
        MuxEvent::TreeSelectionChanged => json!({"event": "tree-changed"}),
        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
        MuxEvent::LayoutChanged(screen) => json!({"event": "layout-changed", "screen": screen}),
        MuxEvent::ClientAttached { client, transport, name, kind } => json!({
            "event": "client-attached",
            "client": client,
            "transport": transport,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientChanged { client, name, kind } => json!({
            "event": "client-changed",
            "client": client,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientDetached(client) => {
            json!({"event": "client-detached", "client": client})
        }
        MuxEvent::ClientListInvalidated => json!({"event": "client-list-invalidated"}),
        MuxEvent::PairingRequested(challenge) => json!({
            "event": "pairing-requested",
            "request": challenge.id,
            "code": challenge.code,
            "peer": challenge.peer,
            "expires_in": challenge.expires_in,
        }),
        MuxEvent::PairingResolved { request } => {
            json!({"event": "pairing-resolved", "request": request})
        }
        MuxEvent::Empty => json!({"event": "empty"}),
    }
}

fn subscription_overflow_json() -> Value {
    json!({
        "event": "overflow",
        "error": "subscriber fell behind; resubscribe to continue receiving events",
    })
}

fn attach_overflow_json(surface: SurfaceId) -> Value {
    json!({
        "event": "overflow",
        "scope": "surface",
        "surface": surface,
        "error": "surface stream fell behind; reattach the surface",
    })
}

/// Remove the socket file (call on clean shutdown).
pub fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SurfaceOptions;
    use std::sync::mpsc::TryRecvError;
    use std::time::Duration;

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("test", SurfaceOptions::default())
    }

    fn test_writer() -> MessageWriter {
        MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        })
    }

    #[test]
    fn stack_json_uses_the_stored_expansion_while_focus_is_elsewhere() {
        let stack = Node::stack_with_expanded(vec![1, 2, 3], 2).unwrap();

        assert_eq!(node_json(&stack, 1)["expanded"], 1);
        assert_eq!(node_json(&stack, 9)["expanded"], 2);
    }

    #[test]
    fn exported_stack_layout_is_accepted_as_an_apply_request() {
        let request = serde_json::from_value::<LayoutRequest>(json!({
            "type": "stack",
            "panes": [3, 4, 5],
            "expanded": 4
        }));

        let spec = layout_request_to_spec(request.unwrap()).unwrap();
        assert!(matches!(spec, LayoutSpec::Stack { pane_count: 3, expanded_index: 1 }));
    }

    #[test]
    fn swapping_across_a_stack_boundary_keeps_exported_expansion_valid() {
        let mut root = Node::Split {
            id: 10,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::stack_with_expanded(vec![2, 3], 2).unwrap()),
        };

        assert!(root.swap_leaves(1, 2));
        let exported = node_json(&root, 2);
        assert_eq!(exported["b"]["panes"], json!([1, 3]));
        assert_eq!(exported["b"]["expanded"], 1);
    }

    #[test]
    fn swapping_within_a_stack_keeps_the_same_pane_expanded() {
        let mut stack = Node::stack_with_expanded(vec![1, 2, 3], 2).unwrap();

        assert!(stack.swap_leaves(2, 3));
        let exported = node_json(&stack, 9);
        assert_eq!(exported["panes"], json!([1, 3, 2]));
        assert_eq!(exported["expanded"], 2);
    }

    #[test]
    fn bounded_writer_reserves_a_control_lane_for_responses_and_overflow() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let backlog = writer.start_stream(&json!({"event": "overflow"})).unwrap();

        for sequence in 0..OUTBOUND_CAPACITY - 1 {
            writer
                .send_stream(&json!({"event": "output", "sequence": sequence}), &backlog)
                .unwrap();
        }

        let failed_stream = writer.start_stream(&subscription_overflow_json()).unwrap();
        writer.send_control(&json!({"id": 42, "ok": true, "data": {}})).unwrap();
        writer.send_terminal(&subscription_overflow_json(), &failed_stream).unwrap();
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 42);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        let drained = (0..OUTBOUND_CAPACITY - 1)
            .map(|_| outbound.try_pop().expect("accepted output"))
            .collect::<Vec<_>>();
        assert!(drained[0].contains("\"sequence\":0"));
        assert!(writer.is_open());
    }

    #[test]
    fn initial_stream_state_precedes_its_response_and_overflows_only_its_stream() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();

        writer.send_initial(&json!({"event": "vt-state", "surface": 7}), &stream).unwrap();
        writer.send_control(&json!({"id": 1, "ok": true})).unwrap();
        let initial: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(initial["event"], "vt-state");
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 1);

        let oversized = writer.start_stream(&attach_overflow_json(8)).unwrap();
        let error = writer
            .send_initial(
                &json!({"event": "vt-state", "data": "x".repeat(OUTBOUND_BYTE_CAPACITY)}),
                &oversized,
            )
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
        let overflow: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(overflow["event"], "overflow");
        assert_eq!(overflow["surface"], 8);
        assert!(writer.is_open());
    }

    #[test]
    fn server_connection_permits_enforce_and_release_the_cap() {
        let active = Arc::new(AtomicU64::new(MAX_SERVER_CONNECTIONS as u64));
        assert!(claim_connection(&active).is_none());
        active.store(MAX_SERVER_CONNECTIONS as u64 - 1, Ordering::Release);
        let permit = claim_connection(&active).expect("last connection slot");
        assert_eq!(active.load(Ordering::Acquire), MAX_SERVER_CONNECTIONS as u64);
        drop(permit);
        assert_eq!(active.load(Ordering::Acquire), MAX_SERVER_CONNECTIONS as u64 - 1);
    }

    #[test]
    fn shutting_down_a_writer_clone_unblocks_the_reader() {
        let path = std::env::temp_dir().join(format!(
            "cmux-tui-shutdown-{}-{}.sock",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = std::fs::remove_file(&path);
        let listener = transport::listen(&path).unwrap();
        let _client = transport::connect(&path).unwrap();
        let mut reader = listener.accept().unwrap();
        let writer = reader.try_clone_box().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let read_thread = std::thread::spawn(move || {
            let mut byte = [0_u8; 1];
            done.send(reader.read(&mut byte)).unwrap();
        });

        writer.shutdown(Shutdown::Both).unwrap();
        assert_eq!(finished.recv_timeout(Duration::from_secs(1)).unwrap().unwrap(), 0);
        read_thread.join().unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn stalled_websocket_handshake_times_out() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, peer) = listener.accept().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let handler = std::thread::spawn(move || {
            handle_websocket_connection(test_mux(), server, peer, None);
            done.send(()).unwrap();
        });

        finished
            .recv_timeout(Duration::from_secs(1))
            .expect("stalled handshake must not occupy a connection slot indefinitely");
        drop(client);
        handler.join().unwrap();
    }

    #[test]
    fn stalled_websocket_authentication_times_out() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client_stream = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, peer) = listener.accept().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let handler = std::thread::spawn(move || {
            handle_websocket_connection(test_mux(), server, peer, Some("secret"));
            done.send(()).unwrap();
        });
        let (client, _) = tungstenite::client("ws://localhost/", client_stream).unwrap();

        finished
            .recv_timeout(Duration::from_secs(1))
            .expect("stalled authentication must not occupy a connection slot indefinitely");
        drop(client);
        handler.join().unwrap();
    }

    #[test]
    fn global_pressure_terminates_the_stream_occupying_the_backlog() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let noisy = writer.start_stream(&json!({"event": "overflow", "stream": "noisy"})).unwrap();
        let quiet = writer.start_stream(&json!({"event": "overflow", "stream": "quiet"})).unwrap();

        for sequence in 0..OUTBOUND_CAPACITY {
            writer.send_stream(&json!({"event": "output", "sequence": sequence}), &noisy).unwrap();
        }
        writer.send_stream(&json!({"event": "tree-changed"}), &quiet).unwrap();

        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["stream"], "noisy");
        let quiet_event: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(quiet_event["event"], "tree-changed");
        assert_eq!(outbound.try_pop(), None);
        assert_eq!(
            writer.send_stream(&json!({"event": "late"}), &noisy).unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
        assert!(quiet.is_open());
        assert!(writer.is_open());
    }

    #[test]
    fn bounded_writer_rejects_payloads_beyond_each_byte_budget() {
        let outbound = BoundedOutbound::default();
        let stream = OutboundStream::new(1, r#"{"event":"overflow"}"#.to_string());

        let regular =
            outbound.push_regular("x".repeat(OUTBOUND_BYTE_CAPACITY + 1), &stream).unwrap_err();
        assert_eq!(regular.kind(), std::io::ErrorKind::WouldBlock);
        let control =
            outbound.push_control("x".repeat(OUTBOUND_CONTROL_BYTE_RESERVE + 1)).unwrap_err();
        assert_eq!(control.kind(), std::io::ErrorKind::WouldBlock);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        assert_eq!(outbound.try_pop(), None);
    }

    #[test]
    fn terminal_overflow_purges_only_its_stream_and_rejects_late_frames() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stale = writer.start_stream(&subscription_overflow_json()).unwrap();
        let unrelated = writer.start_stream(&subscription_overflow_json()).unwrap();

        writer.send_stream(&json!({"event": "output", "stream": "stale"}), &stale).unwrap();
        writer.send_stream(&json!({"event": "output", "stream": "unrelated"}), &unrelated).unwrap();
        writer.send_terminal(&subscription_overflow_json(), &stale).unwrap();

        let late = writer.send_stream(&json!({"event": "output", "stream": "late"}), &stale);
        assert_eq!(late.unwrap_err().kind(), std::io::ErrorKind::BrokenPipe);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        let remaining: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(remaining["stream"], "unrelated");
        assert_eq!(outbound.try_pop(), None);
        assert!(writer.is_open());
    }

    #[test]
    fn client_detach_purges_attach_backlog_before_terminal_event() {
        let mux = Mux::new("detach-order-test", SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(41)).unwrap();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        mux.control_clients.attach_surface(client, 41, stream.clone()).unwrap();
        mux.control_clients.commit_surface(client, 41, stream.id, None).unwrap();
        writer.send_initial(&json!({"event": "vt-state", "surface": 41}), &stream).unwrap();
        writer.send_stream(&json!({"event": "output", "surface": 41}), &stream).unwrap();

        assert!(disconnect_client(&mux, client, true));

        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal, json!({"event": "detached", "surface": 41}));
        assert_eq!(outbound.try_pop(), None);
    }

    #[test]
    fn self_detach_responds_before_closing_and_releases_the_size_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let events = mux.subscribe();
        mux.resize_surface_for_client(surface.id, client, 80, 24).unwrap();

        assert!(!handle_message(
            &mux,
            client,
            &json!({"id": 9, "cmd": "detach-client", "client": client}).to_string(),
            &writer,
        ));

        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 9);
        assert_eq!(response["ok"], true);
        assert_eq!(mux.client_surface_size(surface.id, client), None);
        assert!(mux.control_clients_json(client).as_array().unwrap().is_empty());
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientDetached(id)) if id == client
        )));
        assert!(mux.surface(surface.id).is_some(), "the session must survive its last viewer");
    }

    #[test]
    fn peer_detach_is_id_stable_and_does_not_disconnect_the_initiator() {
        let mux = test_mux();
        let initiator_writer = test_writer();
        let target_writer = test_writer();
        let initiator =
            mux.control_clients.register(ClientTransport::Unix, initiator_writer.clone());
        let target = mux.control_clients.register(ClientTransport::Unix, target_writer);

        handle_command(
            &mux,
            initiator,
            Command::DetachClient { client: target },
            &initiator_writer,
        )
        .unwrap();

        let listed =
            handle_command(&mux, initiator, Command::ListClients, &initiator_writer).unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0]["client"], initiator);
        let error = handle_command(
            &mux,
            initiator,
            Command::DetachClient { client: target },
            &initiator_writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains(&format!("unknown client {target}")));
    }

    #[test]
    fn remote_client_cannot_detach_synthetic_local_client_zero() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        let error =
            handle_command(&mux, client, Command::DetachClient { client: 0 }, &writer).unwrap_err();

        assert!(error.to_string().contains("unknown client 0"));
        assert!(
            mux.control_clients_json(client)
                .as_array()
                .unwrap()
                .iter()
                .any(|info| { info["client"] == client })
        );
    }

    #[test]
    fn closing_bounded_writer_wakes_a_waiting_drain() {
        let outbound = Arc::new(BoundedOutbound::default());
        let waiting = outbound.clone();
        let drain = std::thread::spawn(move || waiting.recv());

        outbound.close();

        assert_eq!(drain.join().unwrap(), None);
    }

    #[test]
    fn websocket_overflow_marks_attach_lifecycle() {
        let lifecycle = AttachLifecycle::default();
        let error = std::io::Error::new(std::io::ErrorKind::WouldBlock, "queue full");

        handle_attach_send_error(&lifecycle, &error);

        assert!(lifecycle.is_canceled());
        assert!(lifecycle.overflowed());
    }

    #[test]
    fn identify_and_ping_return_build_metadata() {
        let mux = test_mux();
        let identity = handle_command(&mux, 0, Command::Identify, &test_writer()).unwrap();
        assert_eq!(identity["app"].as_str(), Some("cmux-tui"));
        assert_eq!(identity["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
        assert_eq!(identity["protocol"].as_u64(), Some(PROTOCOL_VERSION as u64));
        assert_eq!(identity["build_commit"].as_str(), stamped_build_commit());
        assert_eq!(identity["ghostty_commit"].as_str(), stamped_ghostty_commit());

        let data = handle_command(&mux, 0, Command::Ping, &test_writer()).unwrap();
        assert_eq!(data["ok"].as_bool(), Some(true));
        assert_eq!(data["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
        assert_eq!(data["build_commit"].as_str(), stamped_build_commit());
        assert_eq!(data["ghostty_commit"].as_str(), stamped_ghostty_commit());
        assert_eq!(data["protocol"].as_u64(), Some(PROTOCOL_VERSION as u64));
        assert_eq!(STABLE_SPLIT_IDS_PROTOCOL_VERSION, 8);
        assert_eq!(STACK_LAYOUT_PROTOCOL_VERSION, 9);
        assert_eq!(PROTOCOL_VERSION, 9);
    }

    #[test]
    fn split_ids_serialize_stably_and_both_ratio_commands_work() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.split(first_pane, SplitDir::Right, None).unwrap();
        let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());

        let before = handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        let split = before["workspaces"][0]["screens"][0]["layout"]["split"]
            .as_u64()
            .expect("protocol v8 split id");

        let request: Request = serde_json::from_value(json!({
            "id": 1,
            "cmd": "set-split-ratio",
            "split": split,
            "ratio": 0.7
        }))
        .unwrap();
        handle_command(&mux, 0, request.cmd, &test_writer()).unwrap();
        let after_exact = handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        assert_eq!(after_exact["workspaces"][0]["screens"][0]["layout"]["split"], split);
        let exact_ratio = after_exact["workspaces"][0]["screens"][0]["layout"]["ratio"]
            .as_f64()
            .expect("split ratio");
        assert!((exact_ratio - 0.7).abs() < 1e-6);

        let legacy: Request = serde_json::from_value(json!({
            "id": 2,
            "cmd": "set-ratio",
            "pane": second_pane,
            "dir": "right",
            "ratio": 0.3
        }))
        .unwrap();
        handle_command(&mux, 0, legacy.cmd, &test_writer()).unwrap();
        let after_legacy =
            handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        assert_eq!(after_legacy["workspaces"][0]["screens"][0]["layout"]["split"], split);
        let legacy_ratio = after_legacy["workspaces"][0]["screens"][0]["layout"]["ratio"]
            .as_f64()
            .expect("split ratio");
        assert!((legacy_ratio - 0.3).abs() < 1e-6);

        let unknown: Request = serde_json::from_value(json!({
            "cmd": "set-split-ratio",
            "split": 999999,
            "ratio": 0.5
        }))
        .unwrap();
        assert_eq!(
            handle_command(&mux, 0, unknown.cmd, &test_writer()).unwrap_err().to_string(),
            "unknown split 999999"
        );
    }

    #[test]
    fn create_terminal_rejects_partial_dimensions() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(None, None, None).unwrap().workspace;

        for (cols, rows) in [(Some(80), None), (None, Some(24))] {
            let error = handle_command(
                &mux,
                0,
                Command::CreateTerminal {
                    workspace: Some(workspace),
                    key: None,
                    argv: None,
                    command: None,
                    cwd: None,
                    name: None,
                    cols,
                    rows,
                },
                &test_writer(),
            )
            .unwrap_err();

            assert_eq!(
                error.to_string(),
                "create-terminal cols and rows must be supplied together"
            );
        }
    }

    #[test]
    fn attached_client_resizes_preserve_smallest_grid_and_independent_reports() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

        let first_writer = test_writer();
        let first_stream = first_writer.start_stream(&attach_overflow_json(surface.id)).unwrap();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        mux.control_clients.attach_surface(first, surface.id, first_stream.clone()).unwrap();
        mux.control_clients.commit_surface(first, surface.id, first_stream.id, None).unwrap();

        let second_writer = test_writer();
        let second_stream = second_writer.start_stream(&attach_overflow_json(surface.id)).unwrap();
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        mux.control_clients.attach_surface(second, surface.id, second_stream.clone()).unwrap();
        mux.control_clients.commit_surface(second, surface.id, second_stream.id, None).unwrap();

        let first_result = handle_command(
            &mux,
            first,
            Command::ResizeSurface { surface: surface.id, cols: 100, rows: 30 },
            &first_writer,
        )
        .unwrap();
        assert_eq!(first_result["accepted"].as_bool(), Some(true));
        assert_eq!(surface.size(), (100, 30));

        let second_result = handle_command(
            &mux,
            second,
            Command::ResizeSurface { surface: surface.id, cols: 132, rows: 44 },
            &second_writer,
        )
        .unwrap();
        assert_eq!(second_result["accepted"].as_bool(), Some(false));
        assert_eq!(surface.size(), (100, 30));

        let clients = mux.control_clients.list_json(first);
        let clients = clients.as_array().unwrap();
        let recorded_size = |client: u64| {
            let record =
                clients.iter().find(|record| record["client"].as_u64() == Some(client)).unwrap();
            let size = record["sizes"].as_array().unwrap().first().unwrap();
            (size["cols"].as_u64().unwrap(), size["rows"].as_u64().unwrap())
        };
        assert_eq!(recorded_size(first), (100, 30));
        assert_eq!(recorded_size(second), (132, 44));
    }

    #[test]
    fn client_info_is_sanitized_recallable_and_clamped_to_64_characters() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let events = mux.subscribe();

        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("\u{1b}]0;evil\u{07}name".to_string()),
                kind: Some("web".to_string()),
            },
            &writer,
        )
        .unwrap();
        let data = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(data[0]["name"], " ]0;evil name");

        handle_command(
            &mux,
            client,
            Command::SetClientInfo { name: Some("n".repeat(80)), kind: None },
            &writer,
        )
        .unwrap();
        handle_command(
            &mux,
            client,
            Command::SetClientInfo { name: None, kind: Some("tui".to_string()) },
            &writer,
        )
        .unwrap();

        let data = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        let listed = &data[0];
        assert_eq!(listed["name"].as_str().unwrap().chars().count(), 64);
        assert_eq!(listed["kind"], "tui");
        assert_eq!(listed["self"], true);
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "web"
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "web"
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "tui"
        ));
    }

    #[test]
    fn client_sizing_command_updates_list_clients() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["size_participating"], true);

        handle_command(
            &mux,
            client,
            Command::SetClientSizing { client: Some(client), enabled: false, exclusive: false },
            &writer,
        )
        .unwrap();
        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["size_participating"], false);
    }

    #[test]
    fn client_sizing_command_applies_exclusive_and_all_modes_atomically() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let first_writer = test_writer();
        let second_writer = test_writer();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        for (client, writer, size) in
            [(first, &first_writer, (120, 40)), (second, &second_writer, (80, 30))]
        {
            let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
            mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
            handle_command(
                &mux,
                client,
                Command::ResizeSurface { surface: surface.id, cols: size.0, rows: size.1 },
                writer,
            )
            .unwrap();
        }
        assert_eq!(surface.size(), (80, 30));

        handle_command(
            &mux,
            first,
            Command::SetClientSizing { client: Some(first), enabled: true, exclusive: true },
            &first_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (120, 40));
        assert!(mux.client_size_participates(first));
        assert!(!mux.client_size_participates(second));

        handle_command(
            &mux,
            first,
            Command::SetClientSizing { client: None, enabled: true, exclusive: false },
            &first_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (80, 30));
        assert!(mux.client_size_participates(first));
        assert!(mux.client_size_participates(second));
    }

    #[test]
    fn releasing_surface_size_keeps_attach_but_removes_visibility_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
        let events = mux.subscribe();

        handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: 80, rows: 24 },
            &writer,
        )
        .unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), Some((80, 24)));
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, .. }) if id == client
        )));

        handle_command(&mux, client, Command::ReleaseSurfaceSize { surface: surface.id }, &writer)
            .unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), None);
        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["attached"], json!([surface.id]));
        assert_eq!(listed[0]["sizes"][0]["cols"], Value::Null);
        assert_eq!(listed[0]["sizes"][0]["rows"], Value::Null);
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, .. }) if id == client
        )));
    }

    #[test]
    fn attached_unreported_client_suppresses_global_ignore_size_fallback() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 100, rows: 40 },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing { client: Some(reporter), enabled: false, exclusive: false },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();

        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (100, 40));

        handle_command(
            &mux,
            blocker,
            Command::SetClientSizing { client: Some(blocker), enabled: false, exclusive: false },
            &blocker_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (70, 20));
    }

    #[test]
    fn final_stream_detach_restores_excluded_report_fallback() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing { client: Some(reporter), enabled: false, exclusive: false },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();
        mux.resize_surface(surface.id, 100, 40).unwrap();

        assert!(
            mux.control_clients.detach_surface(blocker, surface.id, blocker_stream_id).final_stream
        );
        mux.remove_surface_size_client(surface.id, blocker);

        assert_eq!(surface.size(), (70, 20));
        assert!(!mux.control_clients.attached_client_ids().contains(&blocker));
    }

    #[test]
    fn final_stream_detach_restores_excluded_reports_on_other_surfaces() {
        let mux = test_mux();
        let blocker_surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let reported_surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, reported_surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: reported_surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing { client: Some(reporter), enabled: false, exclusive: false },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        mux.control_clients.attach_surface(blocker, blocker_surface.id, blocker_stream).unwrap();
        mux.resize_surface(reported_surface.id, 100, 40).unwrap();

        assert!(
            mux.control_clients
                .detach_surface(blocker, blocker_surface.id, blocker_stream_id)
                .final_stream
        );
        mux.remove_surface_size_client(blocker_surface.id, blocker);

        assert_eq!(reported_surface.size(), (70, 20));
    }

    #[test]
    fn failed_reducer_resize_restores_registry_size() {
        let mux = test_mux();
        let missing_surface = 99_999;
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, missing_surface, stream).unwrap();
        mux.control_clients.commit_surface(client, missing_surface, stream_id, None).unwrap();

        assert!(mux
            .resize_surface_for_control_client_with_reservation(
                missing_surface,
                client,
                70,
                20,
            )
            .is_err());

        let clients = mux.control_clients.list_json(client);
        assert_eq!(clients[0]["sizes"][0]["surface"], missing_surface);
        assert_eq!(clients[0]["sizes"][0]["cols"], Value::Null);
        assert_eq!(clients[0]["sizes"][0]["rows"], Value::Null);
    }

    #[test]
    fn failed_attach_rollback_does_not_restore_disconnected_client_size() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        let resize = mux
            .resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20)
            .unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));

        assert!(disconnect_client(&mux, client, false));
        mux.rollback_surface_size_client(surface.id, client, resize.rollback);

        assert_eq!(mux.client_surface_size(surface.id, client), None);
        assert!(!mux.control_clients.contains(client));
    }

    #[test]
    fn rejected_attach_rollback_keeps_registry_at_actual_size() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
        let changed = mux
            .resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20)
            .unwrap();
        assert_eq!(surface.size(), (70, 20));

        let removed = mux.remove_surface_runtime_for_test(surface.id).unwrap();
        mux.rollback_surface_size_client(surface.id, client, changed.rollback);

        assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));
        let clients = mux.control_clients.list_json(client);
        assert_eq!(clients[0]["sizes"][0]["cols"], 70);
        assert_eq!(clients[0]["sizes"][0]["rows"], 20);
        removed.kill();
    }

    #[test]
    fn unrelated_attach_does_not_cancel_failed_surface_rollback_repair() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let unrelated_surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
        let changed = mux
            .resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20)
            .unwrap();
        assert_eq!(surface.size(), (70, 20));

        let unrelated_writer = test_writer();
        let unrelated_client =
            mux.control_clients.register(ClientTransport::Unix, unrelated_writer.clone());
        let unrelated_stream = unrelated_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.set_client_rollback_before_wait(Some(Arc::new({
            let hook_mux = mux.clone();
            move || {
                hook_mux
                    .control_clients
                    .attach_surface(
                        unrelated_client,
                        unrelated_surface.id,
                        unrelated_stream.clone(),
                    )
                    .unwrap();
            }
        })));
        let removed = mux.remove_surface_runtime_for_test(surface.id).unwrap();

        mux.rollback_surface_size_client(surface.id, client, changed.rollback);
        mux.set_client_rollback_before_wait(None);

        assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));
        let clients = mux.control_clients.list_json(client);
        let client =
            clients.as_array().unwrap().iter().find(|entry| entry["self"] == true).unwrap();
        assert_eq!(client["sizes"][0]["cols"], 70);
        assert_eq!(client["sizes"][0]["rows"], 20);
        removed.kill();
    }

    #[test]
    fn disconnect_cleanup_wins_over_a_waiting_stale_sizing_action() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();

        let lifecycle = mux.lock_client_sizing_lifecycle();
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
        let action_mux = mux.clone();
        let action = std::thread::spawn(move || {
            ready_tx.send(()).unwrap();
            action_mux.set_client_size_participation(client, false)
        });
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let removed = mux.control_clients.remove(client).expect("registered client");
        mux.remove_size_client(client);
        drop(removed);
        drop(lifecycle);

        assert_eq!(action.join().unwrap(), None);
        assert!(!mux.control_clients.contains(client));
    }

    #[test]
    fn detached_client_cannot_fall_through_to_direct_resize() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        assert!(disconnect_client(&mux, client, false));

        let error = handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &writer,
        )
        .unwrap_err();

        assert!(error.to_string().contains(&format!("unknown client {client}")));
        assert_eq!(surface.size(), (100, 40));
    }

    #[test]
    fn unattached_live_resize_still_obeys_visible_client_minimum() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let viewer_writer = test_writer();
        let viewer = mux.control_clients.register(ClientTransport::Unix, viewer_writer.clone());
        let stream = viewer_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(viewer, surface.id, stream).unwrap();
        handle_command(
            &mux,
            viewer,
            Command::ResizeSurface { surface: surface.id, cols: 100, rows: 40 },
            &viewer_writer,
        )
        .unwrap();

        let control_writer = test_writer();
        let control = mux.control_clients.register(ClientTransport::Unix, control_writer.clone());
        handle_command(
            &mux,
            control,
            Command::ResizeSurface { surface: surface.id, cols: 120, rows: 50 },
            &control_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (100, 40));

        handle_command(
            &mux,
            control,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &control_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (70, 20));

        assert!(disconnect_client(&mux, control, false));
        assert_eq!(surface.size(), (100, 40));
    }

    #[test]
    fn exclusive_sizing_excludes_clients_that_attach_later() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let target_writer = test_writer();
        let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
        let target_stream = target_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(target, surface.id, target_stream).unwrap();
        handle_command(
            &mux,
            target,
            Command::ResizeSurface { surface: surface.id, cols: 120, rows: 40 },
            &target_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            target,
            Command::SetClientSizing { client: Some(target), enabled: true, exclusive: true },
            &target_writer,
        )
        .unwrap();

        let later_writer = test_writer();
        let later = mux.control_clients.register(ClientTransport::Unix, later_writer.clone());
        let later_stream = later_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(later, surface.id, later_stream).unwrap();
        handle_command(
            &mux,
            later,
            Command::ResizeSurface { surface: surface.id, cols: 60, rows: 20 },
            &later_writer,
        )
        .unwrap();

        assert_eq!(surface.size(), (120, 40));
        assert!(!mux.client_size_participates(later));
        let clients = mux.control_clients_json(target);
        assert_eq!(
            clients.as_array().unwrap().iter().find(|client| client["client"] == later).unwrap()["size_participating"],
            false
        );
    }

    #[test]
    fn ignored_report_does_not_replace_unsized_creation_default() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();

        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing { client: Some(reporter), enabled: false, exclusive: false },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 60, rows: 20 },
            &reporter_writer,
        )
        .unwrap();

        assert_eq!(surface.size(), (100, 40));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (100, 40));
    }

    #[test]
    fn attach_initial_sizes_share_the_smallest_viewer_grid() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let first_writer = test_writer();
        let second_writer = test_writer();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        let first_stream = first_writer.start_stream(&json!({"event": "test"})).unwrap();
        let second_stream = second_writer.start_stream(&json!({"event": "test"})).unwrap();

        mark_client_attached(&mux, first, surface.id, first_stream.clone(), Some((100, 30)))
            .unwrap();
        mark_client_attached(&mux, second, surface.id, second_stream.clone(), Some((80, 35)))
            .unwrap();

        assert_eq!(mux.client_surface_size(surface.id, first), Some((100, 30)));
        assert_eq!(mux.client_surface_size(surface.id, second), Some((80, 35)));
        assert_eq!(surface.size(), (80, 30));

        cleanup_failed_attach(&mux, first, surface.id, first_stream.id);
        assert_eq!(mux.client_surface_size(surface.id, first), None);
        assert_eq!(surface.size(), (80, 35));

        cleanup_failed_attach(&mux, second, surface.id, second_stream.id);
        assert_eq!(mux.client_surface_size(surface.id, second), None);
        assert!(mux.surface(surface.id).is_some());
    }

    #[test]
    fn secondary_attach_detach_restores_the_surviving_stream_size() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let first_stream = writer.start_stream(&json!({"event": "first"})).unwrap();
        let second_stream = writer.start_stream(&json!({"event": "second"})).unwrap();

        let first =
            mark_client_attached(&mux, client, surface.id, first_stream.clone(), Some((100, 30)))
                .unwrap();
        commit_client_attach(
            &mux,
            client,
            surface.id,
            first_stream.id,
            first.client_changed,
            first.size_rollback,
        )
        .unwrap();
        let second =
            mark_client_attached(&mux, client, surface.id, second_stream.clone(), Some((80, 24)))
                .unwrap();
        commit_client_attach(
            &mux,
            client,
            surface.id,
            second_stream.id,
            second.client_changed,
            second.size_rollback,
        )
        .unwrap();
        assert_eq!(surface.size(), (80, 24));

        detach_committed_attach(&mux, client, surface.id, second_stream.id);

        assert_eq!(mux.client_surface_size(surface.id, client), Some((100, 30)));
        assert_eq!(surface.size(), (100, 30));
        let listed = mux.control_clients.list_json(client);
        assert_eq!(listed[0]["sizes"][0]["cols"].as_u64(), Some(100));
        assert_eq!(listed[0]["sizes"][0]["rows"].as_u64(), Some(30));

        detach_committed_attach(&mux, client, surface.id, first_stream.id);
    }

    #[test]
    fn failed_attach_cleanup_releases_stream_and_size_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();

        mux.control_clients.attach_surface(client, surface.id, stream.clone()).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
        cleanup_failed_attach(&mux, client, surface.id, stream.id);

        assert!(!mux.control_clients.attached_client_ids().contains(&client));
        assert_eq!(mux.client_surface_size(surface.id, client), None);
    }

    #[test]
    fn failed_first_attach_restores_pre_attach_surface_geometry() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();

        let marked =
            mark_client_attached(&mux, client, surface.id, stream.clone(), Some((80, 24))).unwrap();
        assert_eq!(surface.size(), (80, 24));

        rollback_failed_attach(&mux, client, surface.id, stream.id, marked.size_rollback);

        assert_eq!(surface.size(), (120, 40));
        assert_eq!(mux.client_surface_size(surface.id, client), None);
        assert!(!mux.control_clients.attached_client_ids().contains(&client));
    }

    #[test]
    fn attach_rollback_wait_does_not_hold_global_sizing_locks() {
        let mux = test_mux();
        let failed_surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let unrelated_surface = mux.new_workspace(None, Some((100, 30))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, failed_surface.id, stream).unwrap();
        let resize = mux
            .resize_surface_for_control_client_with_reservation(failed_surface.id, client, 80, 24)
            .unwrap();

        let entered = Arc::new(std::sync::Barrier::new(2));
        let resume = Arc::new(std::sync::Barrier::new(2));
        mux.set_client_rollback_before_wait(Some(Arc::new({
            let entered = entered.clone();
            let resume = resume.clone();
            move || {
                entered.wait();
                resume.wait();
            }
        })));
        let rollback_mux = mux.clone();
        let rollback = std::thread::spawn(move || {
            rollback_mux.rollback_surface_size_client(failed_surface.id, client, resize.rollback);
        });
        entered.wait();

        let (resized_tx, resized_rx) = std::sync::mpsc::sync_channel(1);
        let resize_mux = mux.clone();
        let unrelated = unrelated_surface.id;
        let resize_thread = std::thread::spawn(move || {
            resized_tx
                .send(resize_mux.resize_surface_for_client(unrelated, 9_999, 70, 20))
                .unwrap();
        });
        assert!(resized_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap());

        resume.wait();
        rollback.join().unwrap();
        resize_thread.join().unwrap();
        mux.set_client_rollback_before_wait(None);
    }

    #[test]
    fn failed_secondary_attach_preserves_surviving_stream_size_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let first = writer.start_stream(&json!({"event": "test"})).unwrap();
        let failed = writer.start_stream(&json!({"event": "test"})).unwrap();

        mark_client_attached(&mux, client, surface.id, first, Some((80, 24))).unwrap();
        let rollback =
            mark_client_attached(&mux, client, surface.id, failed.clone(), Some((60, 20))).unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), Some((60, 20)));
        assert_eq!(surface.size(), (60, 20));
        rollback_failed_attach(&mux, client, surface.id, failed.id, rollback.size_rollback);

        assert!(mux.control_clients.attached_client_ids().contains(&client));
        assert_eq!(mux.client_surface_size(surface.id, client), Some((80, 24)));
        assert_eq!(surface.size(), (80, 24));
    }

    #[test]
    fn failed_attach_setup_does_not_announce_or_suppress_retry() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let events = mux.subscribe();
        let failed_stream = writer.start_stream(&json!({"event": "test"})).unwrap();

        assert!(
            mark_client_attached(&mux, client, surface.id + 10_000, failed_stream, Some((80, 24)),)
                .is_err()
        );
        assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::ClientAttached { .. })));
        assert!(!mux.control_clients.attached_client_ids().contains(&client));

        let retry_stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let retry_stream_id = retry_stream.id;
        mark_client_attached(&mux, client, surface.id, retry_stream, Some((80, 24))).unwrap();
        let staged = mux.control_clients.list_json(client);
        assert_eq!(staged[0]["attached"], json!([]));
        assert_eq!(staged[0]["sizes"], json!([]));
        assert!(!events.try_iter().any(|event| matches!(
            event,
            MuxEvent::ClientAttached { .. } | MuxEvent::ClientChanged { .. }
        )));
        commit_client_attach(&mux, client, surface.id, retry_stream_id, None, None).unwrap();

        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientAttached { client: attached, .. }) if attached == client
        ));
    }

    #[test]
    fn attach_worker_cleanup_starts_after_stream_commit() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        let surface_id = surface.id;
        let marked = mark_client_attached(&mux, client, surface_id, stream, None).unwrap();
        let lifecycle = AttachLifecycle::default();
        let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
        let (observed_tx, observed_rx) = std::sync::mpsc::sync_channel(1);
        let worker_mux = mux.clone();
        let worker = std::thread::spawn(move || {
            worker_committed.recv().unwrap();
            let clients = worker_mux.control_clients.list_json(client);
            let attached = clients[0]["attached"]
                .as_array()
                .is_some_and(|surfaces| surfaces.contains(&json!(surface_id)));
            observed_tx.send(attached).unwrap();
            cleanup_failed_attach(&worker_mux, client, surface_id, stream_id);
        });

        commit_client_attach_and_start_worker(
            &mux,
            client,
            surface_id,
            stream_id,
            AttachWorkerCommit {
                start: worker_start,
                lifecycle,
                changed: marked.client_changed,
                size_rollback: marked.size_rollback,
            },
        )
        .unwrap();

        assert!(observed_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        worker.join().unwrap();
    }

    #[test]
    fn stale_workspace_selectors_report_revision_conflicts_before_lookup() {
        let mux = test_mux();
        let workspace = mux
            .create_empty_workspace(Some("stale".into()), Some("stable-key".into()), None)
            .unwrap();
        mux.close_workspace_at_revision(workspace.workspace, Some(1)).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        for command in [
            Command::CloseWorkspace {
                workspace: None,
                key: Some("stable-key".into()),
                expected_revision: Some(1),
            },
            Command::RenameWorkspace {
                workspace: None,
                key: Some("stable-key".into()),
                name: "renamed".into(),
                expected_revision: Some(1),
            },
            Command::MoveWorkspace {
                workspace: None,
                key: Some("stable-key".into()),
                index: 0,
                expected_revision: Some(1),
            },
        ] {
            let error = handle_command(&mux, client, command, &writer).unwrap_err();
            assert_eq!(error.to_string(), "workspace revision conflict: expected 1, current 2");
        }
    }

    #[test]
    fn identify_advertises_additive_capabilities() {
        let mux = test_mux();
        let identity = handle_command(&mux, 0, Command::Identify, &test_writer()).unwrap();

        let capabilities = identity["capabilities"].as_array().expect("capabilities");
        for expected in ["attach-initial-size", "workspace-registry-v1"] {
            assert!(capabilities.iter().any(|value| value.as_str() == Some(expected)));
        }
    }

    #[test]
    fn reload_config_returns_path_and_emits_request() {
        let mux = test_mux();
        let events = mux.subscribe();
        let data = handle_command(&mux, 0, Command::ReloadConfig, &test_writer()).unwrap();
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
            0,
            Command::SetWindowTitle { title: "hello".to_string() },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(data, json!({}));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::WindowTitleRequested(title)) if title == "hello"
        ));

        handle_command(&mux, 0, Command::ClearWindowTitle, &test_writer()).unwrap();
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
    fn title_changed_event_includes_authoritative_surface_title() {
        let mux = Mux::new(
            "title-event-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "printf '\\033]2;server title\\007'; exec cat".to_string(),
                ]),
                ..SurfaceOptions::default()
            },
        );
        let events = mux.subscribe();
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
        loop {
            match events.recv_timeout(Duration::from_secs(1)).unwrap() {
                MuxEvent::TitleChanged { surface: id, title }
                    if id == surface.id && title.as_ref() == "server title" =>
                {
                    break;
                }
                _ => {}
            }
        }

        assert_eq!(surface.title(), "server title");
        assert_eq!(
            subscribed_event_json(&MuxEvent::TitleChanged {
                surface: surface.id,
                title: Arc::<str>::from("server title"),
            }),
            json!({
                "event": "title-changed",
                "surface": surface.id,
                "title": "server title",
            })
        );
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
            0,
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
            0,
            Command::ScrollSurface { surface: surface.id, delta: 0 },
            &test_writer(),
        )
        .unwrap();
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    }
}
