//! Remote session client: JSON-lines control socket plus locally
//! mirrored surface terminals (VT replay + live stream).

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::net::Shutdown;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_tui_core::{
    BrowserFrame, BrowserSource, BrowserStatus, DefaultColors, MuxEvent, MuxEventBroadcaster,
    MuxEventReceiver, NotificationEvent, NotificationLevel, PairingChallenge, Rgb, SurfaceId,
    SurfaceKind, platform::transport,
};
use cmux_tui_machine_protocol::BearerToken;
use ghostty_vt::{
    Callbacks, CursorShape, MouseEncoders, MouseInput, RenderState, Terminal,
    TerminalColorOverrides, parse_color,
};
use serde_json::{Value, json};
use zeroize::Zeroize;

use super::tree::{TreeView, parse_tree};

const SUPPORTED_PROTOCOL_VERSION: u64 = 9;
const SURFACE_OVERFLOW_RETRY_DELAYS: [Duration; 3] =
    [Duration::from_millis(250), Duration::from_millis(500), Duration::from_secs(1)];
const SURFACE_OVERFLOW_STABLE: Duration = Duration::from_secs(5);
#[cfg(not(test))]
const REMOTE_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
#[cfg(test)]
const REMOTE_WRITE_TIMEOUT: Duration = Duration::from_millis(100);
#[cfg(not(test))]
const REMOTE_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(test)]
const REMOTE_REQUEST_TIMEOUT: Duration = Duration::from_millis(100);

fn zeroize_string(value: &mut str) {
    // NUL is valid UTF-8, so the serialized request can be cleared in place
    // immediately after the synchronous transport write finishes.
    value.zeroize();
}

fn validate_remote_identity(ident: &Value) -> anyhow::Result<()> {
    if ident.get("app").and_then(Value::as_str) != Some("cmux-tui") {
        anyhow::bail!("socket endpoint is not a cmux-tui session");
    }
    let protocol = ident.get("protocol").and_then(Value::as_u64).unwrap_or(0);
    if protocol != SUPPORTED_PROTOCOL_VERSION {
        anyhow::bail!(
            "unsupported cmux-tui protocol {protocol}; this client requires protocol {SUPPORTED_PROTOCOL_VERSION}; restart the cmux-tui server"
        );
    }
    Ok(())
}

pub(crate) type RemoteResizeReservation = (SurfaceId, (u16, u16), Option<u64>);

pub(crate) struct RemoteCellPixelUpdate {
    pub resizes: Vec<RemoteResizeReservation>,
    pub failures: Vec<(SurfaceId, String)>,
}

#[derive(Debug)]
pub(crate) enum RemoteRequestError {
    Encode(serde_json::Error),
    Transport(io::Error),
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

#[derive(Clone, Copy)]
struct SurfaceOverflowRecovery {
    attempts: u8,
    retry_after: Option<Instant>,
    attached_at: Option<Instant>,
    stopped: bool,
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

#[cfg(test)]
type RemoteGeometryTestHook = Arc<dyn Fn(RemoteGeometryTestStep) + Send + Sync>;

/// A surface mirrored from a remote session.
pub struct RemoteSurface {
    pub id: SurfaceId,
    pub kind: SurfaceKind,
    pub term: Mutex<Terminal>,
    mouse_encoders: Mutex<MouseEncoders>,
    pub dirty: AtomicBool,
    geometry_lifecycle: Mutex<()>,
    cell_pixels: Mutex<(u16, u16)>,
    #[cfg(test)]
    geometry_test_hook: Mutex<Option<RemoteGeometryTestHook>>,
    reported_size: Mutex<Option<(u16, u16)>>,
    browser: Mutex<RemoteBrowserState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RemoteTerminalColors {
    fg: Option<Rgb>,
    bg: Option<Rgb>,
    cursor: Option<Rgb>,
    cursor_style: Option<CursorShape>,
    cursor_blink: Option<bool>,
    palette: [Option<Rgb>; 256],
}

impl RemoteSurface {
    #[cfg(test)]
    fn run_geometry_test_hook(&self, step: RemoteGeometryTestStep) {
        let hook = self.geometry_test_hook.lock().unwrap().clone();
        if let Some(hook) = hook {
            hook(step);
        }
    }

    pub(super) fn sync_mouse_encoders(&self, terminal: &Terminal) {
        self.mouse_encoders.lock().unwrap().sync_from_terminal(terminal);
    }

    pub(super) fn encode_mouse(
        &self,
        input: MouseInput,
        output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self.mouse_encoders.try_lock() {
            Ok(mut encoders) => Some(encoders.encode(input, output)),
            Err(std::sync::TryLockError::Poisoned(error)) => {
                Some(error.into_inner().encode(input, output))
            }
            Err(std::sync::TryLockError::WouldBlock) => None,
        }
    }

    pub(super) fn encode_mouse_release(
        &self,
        input: MouseInput,
        output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self.mouse_encoders.try_lock() {
            Ok(mut encoders) => Some(encoders.encode_release(input, output)),
            Err(std::sync::TryLockError::Poisoned(error)) => {
                Some(error.into_inner().encode_release(input, output))
            }
            Err(std::sync::TryLockError::WouldBlock) => None,
        }
    }

    pub(super) fn encode_mouse_press_pair(
        &self,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut Vec<u8>,
        release_output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self.mouse_encoders.try_lock() {
            Ok(mut encoders) => {
                Some(encoders.encode_press_pair(press, release, press_output, release_output))
            }
            Err(std::sync::TryLockError::Poisoned(error)) => Some(
                error.into_inner().encode_press_pair(press, release, press_output, release_output),
            ),
            Err(std::sync::TryLockError::WouldBlock) => None,
        }
    }

    pub(super) fn reset_mouse_motion_dedupe(&self) {
        self.mouse_encoders.lock().unwrap().reset_motion_dedupe();
    }

    /// Apply an ordered attach-stream resize marker to the mirror terminal.
    pub(super) fn apply_stream_resize(
        &self,
        cols: u16,
        rows: u16,
        replay: Option<&[u8]>,
        kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
    ) {
        self.apply_stream_resize_with_colors(cols, rows, replay, kitty_image_aliases, None);
    }

    /// Apply one authoritative replay and its coupled Kitty alias and color
    /// state before the mirror can be observed at the new size.
    fn apply_stream_resize_with_colors(
        &self,
        cols: u16,
        rows: u16,
        replay: Option<&[u8]>,
        kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
        colors: Option<&RemoteTerminalColors>,
    ) {
        #[cfg(test)]
        self.run_geometry_test_hook(RemoteGeometryTestStep::StreamResizeStarted);
        let _geometry_lifecycle = self.geometry_lifecycle.lock().unwrap();
        let (cols, rows) = (cols.max(1), rows.max(1));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        #[cfg(test)]
        self.run_geometry_test_hook(RemoteGeometryTestStep::StreamResizeCommitBoundary);
        let mut term = self.term.lock().unwrap();
        if let Some(replay) = replay
            && let Ok(mut fresh) = Terminal::new(cols, rows, 10_000, Callbacks::default())
        {
            let _ = fresh.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1));
            fresh.vt_write(replay);
            let _ = fresh.restore_kitty_image_aliases(kitty_image_aliases);
            if let Some(colors) = colors {
                apply_terminal_colors(&mut fresh, colors);
            }
            *term = fresh;
            self.sync_mouse_encoders(&term);
            return;
        }
        let _ = term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1));
        let _ = term.restore_kitty_image_aliases(kitty_image_aliases);
        if let Some(colors) = colors {
            apply_terminal_colors(&mut term, colors);
        }
        self.sync_mouse_encoders(&term);
    }

    fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> ghostty_vt::Result<bool> {
        #[cfg(test)]
        self.run_geometry_test_hook(RemoteGeometryTestStep::CellPixelStarted);
        let _geometry_lifecycle = self.geometry_lifecycle.lock().unwrap();
        let next = (width_px.max(1), height_px.max(1));
        if *self.cell_pixels.lock().unwrap() == next {
            return Ok(false);
        }
        if self.kind == SurfaceKind::Pty {
            let mut term = self.term.lock().unwrap();
            let size = (term.cols(), term.rows());
            term.resize(size.0, size.1, u32::from(next.0), u32::from(next.1))?;
            *self.cell_pixels.lock().unwrap() = next;
        } else {
            *self.cell_pixels.lock().unwrap() = next;
        }
        #[cfg(test)]
        self.run_geometry_test_hook(RemoteGeometryTestStep::CellPixelCommitBoundary);
        Ok(true)
    }

    fn cell_pixel_size(&self) -> (u16, u16) {
        let _geometry_lifecycle = self.geometry_lifecycle.lock().unwrap();
        *self.cell_pixels.lock().unwrap()
    }

    pub(super) fn reported_size(&self) -> Option<(u16, u16)> {
        *self.reported_size.lock().unwrap()
    }

    pub(super) fn set_reported_size(&self, size: (u16, u16)) {
        *self.reported_size.lock().unwrap() = Some(size);
    }

    pub(super) fn clear_reported_size_if(&self, size: (u16, u16)) {
        let mut reported = self.reported_size.lock().unwrap();
        if *reported == Some(size) {
            *reported = None;
        }
    }

    pub(super) fn clear_reported_size(&self) {
        *self.reported_size.lock().unwrap() = None;
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

#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RemoteGeometryTestStep {
    StreamResizeStarted,
    StreamResizeCommitBoundary,
    CellPixelStarted,
    CellPixelCommitBoundary,
}

#[derive(Default)]
struct SubscriptionRecoveryState {
    generation: u64,
    in_flight: bool,
}

pub struct RemoteSession {
    writer: Mutex<Box<dyn RemoteMessageWriter>>,
    pending: Mutex<HashMap<u64, Sender<Value>>>,
    next_id: AtomicU64,
    shutdown: AtomicBool,
    surfaces: Mutex<HashMap<SurfaceId, Arc<RemoteSurface>>>,
    exited_surfaces: Mutex<HashSet<SurfaceId>>,
    tree: Mutex<RemoteTreeCache>,
    tree_refresh: Mutex<()>,
    tree_stale: AtomicBool,
    subscription_recovery: Mutex<SubscriptionRecoveryState>,
    subscribers: MuxEventBroadcaster,
    frame_logs: Mutex<HashMap<SurfaceId, Vec<String>>>,
    surface_overflow_recovery: Mutex<HashMap<SurfaceId, SurfaceOverflowRecovery>>,
    cell_pixel_lifecycle: Mutex<()>,
    cell_pixels: Mutex<(u16, u16)>,
    capabilities: Mutex<HashSet<String>>,
    provider_workspace_authority: Option<BearerToken>,
    provider_workspaces_guarded: AtomicBool,
}

/// Receive complete JSON protocol messages from one transport.
///
/// Message framing belongs to the transport adapter: Unix sockets and SSH
/// relays use JSON lines, while WebSocket and future Iroh adapters can use
/// their native message boundaries.
pub trait RemoteMessageReader: Send {
    fn receive(&mut self) -> io::Result<Option<String>>;
}

/// Send complete JSON protocol messages over one transport.
pub trait RemoteMessageWriter: Send {
    fn send(&mut self, message: &str) -> io::Result<()>;
    fn close(&mut self) -> io::Result<()>;
}

/// The independently-owned read and write halves of a remote connection.
/// Split halves support process stdio and async transport pumps without
/// requiring the underlying stream to be cloneable.
pub struct RemoteTransport {
    reader: Box<dyn RemoteMessageReader>,
    writer: Box<dyn RemoteMessageWriter>,
}

impl RemoteTransport {
    pub fn new(reader: Box<dyn RemoteMessageReader>, writer: Box<dyn RemoteMessageWriter>) -> Self {
        Self { reader, writer }
    }

    pub fn json_lines(stream: Box<dyn transport::Stream>) -> io::Result<Self> {
        stream.set_write_timeout(Some(REMOTE_WRITE_TIMEOUT))?;
        let read_half = stream.try_clone_box()?;
        Ok(Self {
            reader: Box::new(JsonLineReader { inner: BufReader::new(read_half) }),
            writer: Box::new(JsonLineWriter { inner: stream }),
        })
    }
}

struct JsonLineReader {
    inner: BufReader<Box<dyn transport::Stream>>,
}

impl RemoteMessageReader for JsonLineReader {
    fn receive(&mut self) -> io::Result<Option<String>> {
        let mut message = String::new();
        if self.inner.read_line(&mut message)? == 0 {
            return Ok(None);
        }
        if message.ends_with('\n') {
            message.pop();
            if message.ends_with('\r') {
                message.pop();
            }
        }
        Ok(Some(message))
    }
}

struct JsonLineWriter {
    inner: Box<dyn transport::Stream>,
}

impl RemoteMessageWriter for JsonLineWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        self.inner.write_all(message.as_bytes())?;
        self.inner.write_all(b"\n")
    }

    fn close(&mut self) -> io::Result<()> {
        self.inner.shutdown(Shutdown::Both)
    }
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
        Self::connect_stream(stream)
    }

    /// Connect over an already-established full-duplex byte stream.
    ///
    /// The cmux protocol is transport-independent JSONL. Keeping stream
    /// establishment outside `RemoteSession` lets clients use a local socket,
    /// an SSH relay, or another authenticated tunnel without teaching the
    /// session and rendering layers about those transports.
    pub fn connect_stream(stream: Box<dyn transport::Stream>) -> anyhow::Result<Arc<Self>> {
        let transport = RemoteTransport::json_lines(stream).map_err(|error| {
            anyhow::anyhow!("cannot configure JSON-lines session transport: {error}")
        })?;
        Self::connect_transport(transport)
    }

    pub fn connect_transport(transport: RemoteTransport) -> anyhow::Result<Arc<Self>> {
        Self::connect_transport_with_provider_authority(transport, None)
    }

    pub fn connect_provider_transport(
        transport: RemoteTransport,
        authority: BearerToken,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_transport_with_provider_authority(transport, Some(authority))
    }

    fn connect_transport_with_provider_authority(
        transport: RemoteTransport,
        provider_workspace_authority: Option<BearerToken>,
    ) -> anyhow::Result<Arc<Self>> {
        let RemoteTransport { mut reader, writer } = transport;
        let session = Arc::new(RemoteSession {
            writer: Mutex::new(writer),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            shutdown: AtomicBool::new(false),
            surfaces: Mutex::new(HashMap::new()),
            exited_surfaces: Mutex::new(HashSet::new()),
            tree: Mutex::new(RemoteTreeCache::default()),
            tree_refresh: Mutex::new(()),
            tree_stale: AtomicBool::new(true),
            subscription_recovery: Mutex::new(SubscriptionRecoveryState::default()),
            subscribers: MuxEventBroadcaster::default(),
            frame_logs: Mutex::new(HashMap::new()),
            surface_overflow_recovery: Mutex::new(HashMap::new()),
            cell_pixel_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            capabilities: Mutex::new(HashSet::new()),
            provider_workspace_authority,
            provider_workspaces_guarded: AtomicBool::new(false),
        });

        let reader_session = Arc::downgrade(&session);
        std::thread::Builder::new().name("remote-reader".into()).spawn(move || {
            while let Ok(Some(message)) = reader.receive() {
                let Ok(value) = serde_json::from_str::<Value>(&message) else { continue };
                let Some(session) = reader_session.upgrade() else { break };
                session.handle_line(value);
            }
            // Connection lost: tell the app to quit.
            if let Some(session) = reader_session.upgrade() {
                session.disconnect_transport();
                session.emit(MuxEvent::Empty);
            }
        })?;

        if let Err(error) = session.initialize() {
            session.disconnect_transport();
            return Err(error);
        }
        Ok(session)
    }

    fn initialize(&self) -> anyhow::Result<()> {
        // Identify (validates the endpoint) and subscribe to events.
        let ident = self.request(json!({"cmd": "identify"}))?;
        validate_remote_identity(&ident)?;
        *self.capabilities.lock().unwrap() = ident
            .get("capabilities")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect();
        let mut client_info = json!({"cmd": "set-client-info", "kind": "tui"});
        if let Some(hostname) = local_hostname() {
            client_info["name"] = json!(hostname);
        }
        self.request(client_info)?;
        self.request(json!({"cmd": "subscribe"}))?;
        Ok(())
    }

    pub(super) fn supports_capability(&self, capability: &str) -> bool {
        self.capabilities.lock().unwrap().contains(capability)
    }

    pub(super) fn provider_workspace_authority(&self) -> Option<&BearerToken> {
        self.provider_workspace_authority.as_ref()
    }

    pub(super) fn confirm_provider_workspace_guard(&self) -> anyhow::Result<()> {
        if self.shutdown.load(Ordering::Acquire) {
            return Err(RemoteRequestError::Shutdown.into());
        }
        self.provider_workspaces_guarded.store(true, Ordering::Release);
        if self.shutdown.load(Ordering::Acquire) {
            self.provider_workspaces_guarded.store(false, Ordering::Release);
            return Err(RemoteRequestError::Shutdown.into());
        }
        Ok(())
    }

    pub(super) fn provider_workspaces_are_guarded(&self) -> bool {
        self.provider_workspaces_guarded.load(Ordering::Acquire)
    }

    fn emit(&self, event: MuxEvent) {
        self.subscribers.emit(event);
    }

    fn invalidate_tree_once(&self) -> bool {
        !self.tree_stale.swap(true, Ordering::AcqRel)
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
                let colors = value.get("colors").and_then(parse_terminal_colors);
                self.log_frame(
                    id,
                    format!("vt-state cols={cols} rows={rows} bytes={}", replay.len()),
                );
                let kitty_image_aliases = parse_kitty_image_aliases(&value);
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.apply_stream_resize_with_colors(
                        cols,
                        rows,
                        Some(&replay),
                        &kitty_image_aliases,
                        colors.as_ref(),
                    );
                    surface.dirty.store(true, Ordering::Release);
                }
                self.emit(MuxEvent::SurfaceOutput(id));
            }
            Some("surface-resized") => {
                let Some(id) = surface_id() else { return };
                let cols = value.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
                let rows = value.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
                self.emit(MuxEvent::SurfaceResized {
                    surface: id,
                    cols,
                    rows,
                    reservation_id: value.get("reservation_id").and_then(Value::as_u64),
                });
            }
            Some("surface-resize-failed") => {
                let Some(id) = surface_id() else { return };
                let cols = value.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
                let rows = value.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
                let error =
                    value.get("error").and_then(Value::as_str).unwrap_or("browser resize failed");
                let retry_after_ms = value.get("retry_after_ms").and_then(Value::as_u64);
                let reservation_id = value.get("reservation_id").and_then(Value::as_u64);
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.clear_reported_size_if((cols.max(1), rows.max(1)));
                }
                self.emit(MuxEvent::SurfaceResizeFailed {
                    surface: id,
                    cols,
                    rows,
                    error: Arc::<str>::from(error),
                    retry_after_ms,
                    reservation_id,
                });
            }
            Some("output") => {
                let Some(id) = surface_id() else { return };
                let Some(data) = value.get("data").and_then(|v| v.as_str()) else { return };
                let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    return;
                };
                let colors = value.get("colors").and_then(parse_terminal_colors);
                self.log_frame(id, format!("output bytes={}", bytes.len()));
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    let mut term = surface.term.lock().unwrap();
                    term.vt_write(&bytes);
                    if let Some(colors) = colors.as_ref() {
                        apply_terminal_colors(&mut term, colors);
                    }
                    surface.sync_mouse_encoders(&term);
                    drop(term);
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
                let kitty_image_aliases = parse_kitty_image_aliases(&value);
                let colors = value.get("colors").and_then(parse_terminal_colors);
                self.log_frame(
                    id,
                    format!(
                        "resized cols={cols} rows={rows} bytes={}",
                        replay.as_ref().map(|bytes| bytes.len()).unwrap_or(0)
                    ),
                );
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.apply_stream_resize_with_colors(
                        cols,
                        rows,
                        replay.as_deref(),
                        &kitty_image_aliases,
                        colors.as_ref(),
                    );
                    surface.dirty.store(true, Ordering::Release);
                    self.emit(MuxEvent::SurfaceResized {
                        surface: id,
                        cols,
                        rows,
                        reservation_id: None,
                    });
                    self.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            Some("colors-changed") => {
                let Some(id) = surface_id() else { return };
                let Some(colors) = parse_terminal_colors(&value) else { return };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    let mut term = surface.term.lock().unwrap();
                    apply_terminal_colors(&mut term, &colors);
                    surface.sync_mouse_encoders(&term);
                    drop(term);
                    if !surface.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            }
            Some("browser-state") => {
                let Some(id) = surface_id() else { return };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    let cols = value.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
                    let rows = value.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
                    surface.apply_stream_resize(cols, rows, None, &[]);
                    surface.update_browser_state(&value);
                    surface.dirty.store(true, Ordering::Release);
                }
                if let Some(title) = value.get("title").and_then(Value::as_str) {
                    self.emit(MuxEvent::TitleChanged {
                        surface: id,
                        title: Arc::<str>::from(title),
                    });
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
                    self.surface_overflow_recovery.lock().unwrap().remove(&id);
                    self.tree_stale.store(true, Ordering::Release);
                    self.emit(MuxEvent::SurfaceExited(id));
                }
            }
            Some("title-changed") => {
                if let Some(id) = surface_id() {
                    if let Some(title) = value.get("title").and_then(Value::as_str) {
                        let updated = self.tree.lock().unwrap().update_title(id, title.to_string());
                        if !updated && self.invalidate_tree_once() {
                            self.emit(MuxEvent::TreeChanged);
                        }
                        self.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: Arc::<str>::from(title),
                        });
                    } else {
                        if self.invalidate_tree_once() {
                            self.emit(MuxEvent::TreeChanged);
                        }
                    }
                }
            }
            Some("bell") => {
                if let Some(id) = surface_id() {
                    self.emit(MuxEvent::Bell(id));
                }
            }
            Some("notification") => {
                let Some(notification) = value.get("notification").and_then(Value::as_u64) else {
                    return;
                };
                let level = match value.get("level").and_then(Value::as_str) {
                    Some("warning") => NotificationLevel::Warning,
                    Some("error") => NotificationLevel::Error,
                    _ => NotificationLevel::Info,
                };
                self.emit(MuxEvent::Notification(NotificationEvent {
                    notification,
                    title: value
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    body: value.get("body").and_then(Value::as_str).unwrap_or_default().to_string(),
                    level,
                    surface: surface_id(),
                }));
            }
            Some("overflow") => {
                if value.get("scope").and_then(Value::as_str) == Some("surface") {
                    let surface_id = surface_id();
                    if let Some(surface_id) = surface_id {
                        self.surfaces.lock().unwrap().remove(&surface_id);
                        let (delay, stopped) = self.record_surface_overflow(surface_id);
                        self.emit(MuxEvent::SurfaceOutput(surface_id));
                        self.emit(MuxEvent::Status(if stopped {
                            format!(
                                "surface {surface_id} event stream repeatedly overflowed; detach and reconnect to recover"
                            )
                        } else {
                            format!(
                                "surface {surface_id} event stream overflowed; retrying in {} ms",
                                delay.unwrap_or_default().as_millis()
                            )
                        }));
                    }
                    return;
                }
                self.tree_stale.store(true, Ordering::Release);
                self.start_subscription_recovery();
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
            Some("client-attached") => {
                let Some(client) = value.get("client").and_then(Value::as_u64) else {
                    return;
                };
                self.emit(MuxEvent::ClientAttached {
                    client,
                    transport: value
                        .get("transport")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    name: value.get("name").and_then(Value::as_str).map(str::to_string),
                    kind: value.get("kind").and_then(Value::as_str).map(str::to_string),
                });
            }
            Some("client-changed") => {
                let Some(client) = value.get("client").and_then(Value::as_u64) else {
                    return;
                };
                self.emit(MuxEvent::ClientChanged {
                    client,
                    name: value.get("name").and_then(Value::as_str).map(str::to_string),
                    kind: value.get("kind").and_then(Value::as_str).map(str::to_string),
                });
            }
            Some("client-detached") => {
                if let Some(client) = value.get("client").and_then(Value::as_u64) {
                    self.emit(MuxEvent::ClientDetached(client));
                }
            }
            Some("client-list-invalidated") => self.emit(MuxEvent::ClientListInvalidated),
            Some("pairing-requested") => {
                let challenge = PairingChallenge {
                    id: value.get("request").and_then(Value::as_u64).unwrap_or_default(),
                    code: value.get("code").and_then(Value::as_str).unwrap_or_default().to_string(),
                    peer: value.get("peer").and_then(Value::as_str).unwrap_or_default().to_string(),
                    expires_in: value.get("expires_in").and_then(Value::as_u64).unwrap_or_default(),
                };
                if challenge.id != 0 && !challenge.code.is_empty() {
                    self.emit(MuxEvent::PairingRequested(challenge));
                }
            }
            Some("pairing-resolved") => {
                if let Some(request) = value.get("request").and_then(Value::as_u64) {
                    self.emit(MuxEvent::PairingResolved { request });
                }
            }
            Some("empty") => self.emit(MuxEvent::Empty),
            Some(_) => {}
        }
    }

    fn start_subscription_recovery(self: &Arc<Self>) {
        {
            let mut recovery = self.subscription_recovery.lock().unwrap();
            recovery.generation = recovery.generation.wrapping_add(1).max(1);
            if recovery.in_flight {
                return;
            }
            recovery.in_flight = true;
        }
        self.emit(MuxEvent::Status("event subscription overflowed; resubscribing".to_string()));
        let session = self.clone();
        let spawn =
            std::thread::Builder::new().name("remote-resubscribe".into()).spawn(move || {
                loop {
                    let recovery_generation =
                        session.subscription_recovery.lock().unwrap().generation;
                    let first = session.request(json!({"cmd": "subscribe"}));
                    let result = match first {
                        Err(error) if Self::subscription_recovery_is_retryable(&error) => {
                            session.request(json!({"cmd": "subscribe"}))
                        }
                        result => result,
                    };
                    let mut recovery = session.subscription_recovery.lock().unwrap();
                    if recovery.generation != recovery_generation {
                        drop(recovery);
                        continue;
                    }
                    match result {
                        Ok(_) => {
                            session.emit(MuxEvent::Status(
                                "event subscription overflowed; resubscribed".to_string(),
                            ));
                            session.emit(MuxEvent::TreeChanged);
                            session.emit(MuxEvent::ClientListInvalidated);
                        }
                        Err(error) => {
                            session.emit(MuxEvent::Status(format!(
                                "event subscription overflowed; resubscribe failed: {error}"
                            )));
                            session.emit(MuxEvent::Empty);
                        }
                    }
                    recovery.in_flight = false;
                    return;
                }
            });
        if let Err(error) = spawn {
            let mut recovery = self.subscription_recovery.lock().unwrap();
            self.emit(MuxEvent::Status(format!(
                "event subscription overflowed; resubscribe failed: {error}"
            )));
            self.emit(MuxEvent::Empty);
            recovery.in_flight = false;
        }
    }

    fn subscription_recovery_is_retryable(error: &anyhow::Error) -> bool {
        matches!(error.downcast_ref::<RemoteRequestError>(), Some(RemoteRequestError::Rejected(_)))
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
        let mut message = serde_json::to_string(&cmd)
            .map_err(RemoteRequestError::Encode)
            .map_err(anyhow::Error::new)?;
        if let Some(Value::String(authority)) = cmd.get_mut("authority") {
            zeroize_string(authority);
        }

        let (tx, rx) = channel();
        self.pending.lock().unwrap().insert(id, tx);
        let mut writer = self.writer.lock().unwrap();
        let send_result = writer.send(&message);
        zeroize_string(&mut message);
        if let Err(err) = send_result {
            let _ = writer.close();
            drop(writer);
            self.pending.lock().unwrap().remove(&id);
            return Err(RemoteRequestError::Transport(err).into());
        }
        drop(writer);

        if self.shutdown.load(Ordering::Acquire) {
            self.pending.lock().unwrap().remove(&id);
            return Err(RemoteRequestError::Shutdown.into());
        }

        let response = match rx.recv_timeout(REMOTE_REQUEST_TIMEOUT) {
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
        self.provider_workspaces_guarded.store(false, Ordering::Release);
        let pending = std::mem::take(&mut *self.pending.lock().unwrap());
        for (_, sender) in pending {
            let _ = sender.send(json!({"shutdown": true}));
        }
    }

    fn disconnect_transport(&self) {
        self.begin_shutdown();
        if let Ok(mut writer) = self.writer.lock() {
            let _ = writer.close();
        }
    }

    pub fn set_cell_pixel_size(
        &self,
        width_px: u16,
        height_px: u16,
    ) -> anyhow::Result<RemoteCellPixelUpdate> {
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let next = (width_px.max(1), height_px.max(1));
        let previous_global = *self.cell_pixels.lock().unwrap();
        let surfaces = self.surfaces.lock().unwrap().values().cloned().collect::<Vec<_>>();
        let snapshots = surfaces
            .iter()
            .map(|surface| (surface.clone(), surface.cell_pixel_size()))
            .collect::<Vec<_>>();
        for (index, surface) in surfaces.iter().enumerate() {
            if let Err(error) = surface.set_cell_pixel_size(next.0, next.1) {
                let rollback = Self::restore_cell_pixels(&snapshots[..index]);
                return match rollback {
                    Ok(()) => Err(anyhow::anyhow!(
                        "could not update cell pixels for remote mirror {}: {error}",
                        surface.id
                    )),
                    Err(rollback_error) => Err(anyhow::anyhow!(
                        "could not update cell pixels for remote mirror {}: {error}; \
                         local rollback also failed: {rollback_error}",
                        surface.id
                    )),
                };
            }
        }
        let response = match self.request(json!({
            "cmd": "set-cell-pixels",
            "width_px": next.0,
            "height_px": next.1,
        })) {
            Ok(response) => response,
            Err(error) => {
                *self.cell_pixels.lock().unwrap() = previous_global;
                return match Self::restore_cell_pixels(&snapshots) {
                    Ok(()) => Err(error),
                    Err(rollback_error) => Err(anyhow::anyhow!(
                        "{error}; local cell-pixel rollback also failed: {rollback_error}"
                    )),
                };
            }
        };
        let resizes = response
            .get("resizes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|resize| {
                Some((
                    resize.get("surface")?.as_u64()?,
                    (
                        u16::try_from(resize.get("cols")?.as_u64()?).ok()?,
                        u16::try_from(resize.get("rows")?.as_u64()?).ok()?,
                    ),
                    resize.get("reservation_id").and_then(Value::as_u64),
                ))
            })
            .collect::<Vec<_>>();
        let failures = response
            .get("failures")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|failure| {
                Some((
                    failure.get("surface")?.as_u64()?,
                    failure.get("error")?.as_str()?.to_string(),
                ))
            })
            .collect::<Vec<_>>();
        let failed_surfaces = failures.iter().map(|(surface, _)| *surface).collect::<HashSet<_>>();
        let failed_snapshots = snapshots
            .iter()
            .filter(|(surface, _)| failed_surfaces.contains(&surface.id))
            .cloned()
            .collect::<Vec<_>>();
        Self::restore_cell_pixels(&failed_snapshots)?;
        *self.cell_pixels.lock().unwrap() = next;
        Ok(RemoteCellPixelUpdate { resizes, failures })
    }

    fn restore_cell_pixels(snapshots: &[(Arc<RemoteSurface>, (u16, u16))]) -> anyhow::Result<()> {
        let mut failures = Vec::new();
        for (surface, previous) in snapshots {
            if let Err(error) = surface.set_cell_pixel_size(previous.0, previous.1) {
                failures.push(format!("surface {}: {error}", surface.id));
            }
        }
        if failures.is_empty() { Ok(()) } else { anyhow::bail!("{}", failures.join("; ")) }
    }

    pub fn set_default_colors(&self, colors: DefaultColors) -> anyhow::Result<()> {
        let palette = colors
            .palette
            .into_iter()
            .enumerate()
            .filter_map(|(index, color)| {
                color.map(|color| (index.to_string(), Value::String(hex_color(color))))
            })
            .collect::<serde_json::Map<String, Value>>();
        let mut cmd = json!({
            "cmd": "set-default-colors",
            "complete": true,
            "palette": palette,
        });
        if let Some(fg) = colors.fg {
            cmd["fg"] = json!(hex_color(fg));
        }
        if let Some(bg) = colors.bg {
            cmd["bg"] = json!(hex_color(bg));
        }
        if let Some(cursor) = colors.cursor {
            cmd["cursor"] = json!(hex_color(cursor));
        }
        if let Some(selection_bg) = colors.selection_bg {
            cmd["selection_bg"] = json!(hex_color(selection_bg));
        }
        if let Some(selection_fg) = colors.selection_fg {
            cmd["selection_fg"] = json!(hex_color(selection_fg));
        }
        if let Some(cursor_style) = colors.cursor_style {
            cmd["cursor_style"] = json!(match cursor_style {
                CursorShape::Block | CursorShape::BlockHollow => "block",
                CursorShape::Underline => "underline",
                CursorShape::Bar => "bar",
            });
        }
        if let Some(cursor_blink) = colors.cursor_blink {
            cmd["cursor_blink"] = json!(cursor_blink);
        }
        self.request(cmd).map(|_| ())
    }

    pub fn supports_browser_attach(&self) -> bool {
        true
    }

    fn record_surface_overflow(&self, id: SurfaceId) -> (Option<Duration>, bool) {
        let now = Instant::now();
        let mut recoveries = self.surface_overflow_recovery.lock().unwrap();
        let recovery = recoveries.entry(id).or_insert(SurfaceOverflowRecovery {
            attempts: 0,
            retry_after: None,
            attached_at: None,
            stopped: false,
        });
        if recovery
            .attached_at
            .is_some_and(|attached| now.duration_since(attached) >= SURFACE_OVERFLOW_STABLE)
        {
            recovery.attempts = 0;
        }
        recovery.attached_at = None;
        let delay = SURFACE_OVERFLOW_RETRY_DELAYS.get(usize::from(recovery.attempts)).copied();
        recovery.attempts = recovery.attempts.saturating_add(1);
        recovery.stopped = delay.is_none();
        recovery.retry_after = delay.map(|delay| now + delay);
        (delay, recovery.stopped)
    }

    pub fn can_attach_after_overflow(&self, id: SurfaceId) -> bool {
        self.surface_overflow_recovery.lock().unwrap().get(&id).is_none_or(|recovery| {
            !recovery.stopped
                && recovery.retry_after.is_none_or(|retry_after| Instant::now() >= retry_after)
        })
    }

    pub fn surface_overflow_retry_due(&self) -> bool {
        self.surface_overflow_recovery.lock().unwrap().values().any(|recovery| {
            !recovery.stopped
                && recovery.retry_after.is_some_and(|retry_after| Instant::now() >= retry_after)
        })
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

    pub fn try_ensure_surface_with_kind(
        self: &Arc<Self>,
        id: SurfaceId,
        kind: SurfaceKind,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<Arc<RemoteSurface>>> {
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        if self.exited_surfaces.lock().unwrap().contains(&id) {
            return Ok(None);
        }
        if !self.can_attach_after_overflow(id) {
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
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let mut term = Terminal::new(cols, rows, 10_000, Callbacks::default())?;
        term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
        let surface = Arc::new(RemoteSurface {
            id,
            kind,
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(MouseEncoders::new()?),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new(cell_pixels),
            #[cfg(test)]
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        surface.update_browser_source(source);
        self.surfaces.lock().unwrap().insert(id, surface.clone());
        // The vt-state event that follows fills the mirror.
        if let Err(error) = self.request(json!({"cmd": "attach-surface", "surface": id})) {
            self.surfaces.lock().unwrap().remove(&id);
            return Err(error);
        }
        if let Some(recovery) = self.surface_overflow_recovery.lock().unwrap().get_mut(&id) {
            recovery.attached_at = Some(Instant::now());
            recovery.retry_after = None;
        }
        Ok(Some(surface))
    }

    pub fn drop_surface(&self, id: SurfaceId) {
        self.surfaces.lock().unwrap().remove(&id);
        self.surface_overflow_recovery.lock().unwrap().remove(&id);
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

fn local_hostname() -> Option<String> {
    for name in ["HOSTNAME", "COMPUTERNAME"] {
        if let Some(value) = std::env::var_os(name).and_then(|value| value.into_string().ok())
            && !value.is_empty()
        {
            return Some(value);
        }
    }

    #[cfg(unix)]
    {
        use std::ffi::CStr;

        let mut buffer = [0 as libc::c_char; 256];
        if unsafe { libc::gethostname(buffer.as_mut_ptr(), buffer.len() - 1) } == 0 {
            let hostname =
                unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_string_lossy().into_owned();
            if !hostname.is_empty() {
                return Some(hostname);
            }
        }
    }

    None
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

fn parse_kitty_image_aliases(value: &Value) -> Vec<ghostty_vt::KittyImageAlias> {
    value
        .get("kitty_image_aliases")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|alias| {
            let image_id = u32::try_from(alias.get("image_id")?.as_u64()?).ok()?;
            let image_number = u32::try_from(alias.get("image_number")?.as_u64()?).ok()?;
            Some(ghostty_vt::KittyImageAlias { image_id, image_number })
        })
        .collect()
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

fn parse_terminal_colors(value: &Value) -> Option<RemoteTerminalColors> {
    value.as_object()?;
    let color = |key: &str| value.get(key).and_then(Value::as_str).and_then(parse_color);
    let cursor_style = match value.get("cursor_style").and_then(Value::as_str) {
        Some("bar") => Some(CursorShape::Bar),
        Some("underline") => Some(CursorShape::Underline),
        Some("block") => Some(CursorShape::Block),
        _ => None,
    };
    let mut palette = [None; 256];
    if let Some(entries) = value.get("palette").and_then(Value::as_object) {
        for (index, color) in entries {
            let Some(index) = index.parse::<u8>().ok() else { continue };
            let Some(color) = color.as_str().and_then(parse_color) else { continue };
            palette[index as usize] = Some(color);
        }
    }
    Some(RemoteTerminalColors {
        fg: color("fg"),
        bg: color("bg"),
        cursor: color("cursor"),
        cursor_style,
        cursor_blink: value.get("cursor_blink").and_then(Value::as_bool),
        palette,
    })
}

fn apply_terminal_colors(terminal: &mut Terminal, colors: &RemoteTerminalColors) {
    // Colors and vt-state carry the complete resolved special-color tuple.
    // Replace (rather than sparsely merge) it so a later null clears an
    // earlier frontend default just as it does on the authoritative surface.
    terminal.replace_default_colors(colors.fg, colors.bg, colors.cursor);
    terminal.set_default_cursor(colors.cursor_style, colors.cursor_blink);
    if let (Some(style), Some(blink)) = (colors.cursor_style, colors.cursor_blink) {
        // Resolved v2 cursor metadata is authoritative for the active screen.
        // Reset an application-authored DECSCUSR first, then apply the exact
        // source pair. Legacy v1 events omit the pair and leave raw VT cursor
        // state untouched.
        let value = match (style, blink) {
            (CursorShape::Block | CursorShape::BlockHollow, true) => 1,
            (CursorShape::Block | CursorShape::BlockHollow, false) => 2,
            (CursorShape::Underline, true) => 3,
            (CursorShape::Underline, false) => 4,
            (CursorShape::Bar, true) => 5,
            (CursorShape::Bar, false) => 6,
        };
        terminal.vt_write(format!("\x1b[0 q\x1b[{value} q").as_bytes());
    }

    // Replay intentionally omits application-authored palette OSCs so each
    // frontend can retain its own defaults. Reapply only the sparse OSC 4
    // state carried beside the replay. Keeping these as authored overrides
    // (rather than host defaults) makes RenderState resolve indexed cells to
    // the source surface's RGB while unmentioned indices still inherit the
    // receiving terminal's palette.
    let previous = terminal.color_overrides();
    let mut next = previous.clone();
    next.palette = colors.palette;
    let delta = terminal_palette_override_delta(&previous, &next);
    terminal.vt_write(&delta);
}

fn terminal_palette_override_delta(
    previous: &TerminalColorOverrides,
    next: &TerminalColorOverrides,
) -> Vec<u8> {
    let mut output = Vec::new();
    for index in 0..256 {
        if previous.palette[index] == next.palette[index] {
            continue;
        }
        match next.palette[index] {
            Some(color) => output.extend_from_slice(
                format!("\x1b]4;{index};rgb:{:02x}/{:02x}/{:02x}\x1b\\", color.r, color.g, color.b)
                    .as_bytes(),
            ),
            None => output.extend_from_slice(format!("\x1b]104;{index}\x1b\\").as_bytes()),
        }
    }
    output
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
fn test_session_with_provider_context(
    provider_workspace_authority: Option<BearerToken>,
    capabilities: HashSet<String>,
) -> Arc<RemoteSession> {
    struct NoopWriter;

    impl RemoteMessageWriter for NoopWriter {
        fn send(&mut self, _message: &str) -> io::Result<()> {
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    Arc::new(RemoteSession {
        writer: Mutex::new(Box::new(NoopWriter)),
        pending: Mutex::new(HashMap::new()),
        next_id: AtomicU64::new(1),
        shutdown: AtomicBool::new(false),
        surfaces: Mutex::new(HashMap::new()),
        exited_surfaces: Mutex::new(HashSet::new()),
        tree: Mutex::new(RemoteTreeCache::default()),
        tree_refresh: Mutex::new(()),
        tree_stale: AtomicBool::new(true),
        subscription_recovery: Mutex::new(SubscriptionRecoveryState::default()),
        subscribers: MuxEventBroadcaster::default(),
        frame_logs: Mutex::new(HashMap::new()),
        surface_overflow_recovery: Mutex::new(HashMap::new()),
        cell_pixel_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        capabilities: Mutex::new(capabilities),
        provider_workspace_authority,
        provider_workspaces_guarded: AtomicBool::new(false),
    })
}

#[cfg(test)]
pub(super) fn test_session_without_provider_authority() -> Arc<RemoteSession> {
    test_session_with_provider_context(
        None,
        HashSet::from([
            cmux_tui_core::server::PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY.to_string()
        ]),
    )
}

#[cfg(test)]
pub(super) fn test_session_with_provider_authority_without_guard() -> Arc<RemoteSession> {
    test_session_with_provider_context(
        Some(BearerToken::new("test-provider-workspace-authority").unwrap()),
        HashSet::new(),
    )
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::io::{BufRead, Read, Write};
    #[cfg(unix)]
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::{AtomicBool, AtomicU64};
    use std::sync::mpsc::{Receiver, Sender};
    use std::sync::{Mutex, Weak};

    use ghostty_vt::{Callbacks, ColorSpec, RenderState, Terminal};
    use serde_json::json;

    use super::*;

    #[test]
    fn stack_layouts_require_protocol_9() {
        assert_eq!(SUPPORTED_PROTOCOL_VERSION, 9);
    }

    #[test]
    fn protocol_8_identity_is_rejected_before_workspace_loading() {
        let error =
            validate_remote_identity(&json!({"app": "cmux-tui", "protocol": 8})).unwrap_err();
        assert_eq!(
            error.to_string(),
            "unsupported cmux-tui protocol 8; this client requires protocol 9; restart the cmux-tui server"
        );
    }

    #[test]
    fn protocol_9_identity_is_accepted() {
        validate_remote_identity(&json!({"app": "cmux-tui", "protocol": 9})).unwrap();
    }

    #[test]
    fn resolved_cursor_colors_force_the_active_screen_across_alt_screen_modes() {
        for mode in [47, 1047, 1049] {
            let mut terminal = Terminal::new(12, 3, 100, Callbacks::default()).unwrap();
            terminal.vt_write(b"\x1b[5 q");
            terminal.vt_write(format!("\x1b[?{mode}h\x1b[4 q").as_bytes());
            assert_eq!(
                terminal.effective_cursor_visual().unwrap(),
                (CursorShape::Underline, false)
            );

            let colors = RemoteTerminalColors {
                fg: None,
                bg: None,
                cursor: None,
                cursor_style: Some(CursorShape::Bar),
                cursor_blink: Some(false),
                palette: [None; 256],
            };
            apply_terminal_colors(&mut terminal, &colors);
            assert_eq!(
                terminal.effective_cursor_visual().unwrap(),
                (CursorShape::Bar, false),
                "resolved cursor did not replace the active screen for mode {mode}"
            );

            terminal.vt_write(format!("\x1b[?{mode}l").as_bytes());
            let primary_colors = RemoteTerminalColors {
                cursor_style: Some(CursorShape::Underline),
                cursor_blink: Some(true),
                ..colors
            };
            apply_terminal_colors(&mut terminal, &primary_colors);
            assert_eq!(
                terminal.effective_cursor_visual().unwrap(),
                (CursorShape::Underline, true),
                "resolved cursor did not replace the restored primary screen for mode {mode}"
            );
        }
    }

    #[test]
    fn legacy_cursor_absence_preserves_raw_decscusr_and_mode_12() {
        let mut terminal = Terminal::new(12, 3, 100, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[3 q\x1b[?12l");
        let legacy = RemoteTerminalColors {
            fg: None,
            bg: None,
            cursor: None,
            cursor_style: None,
            cursor_blink: None,
            palette: [None; 256],
        };

        apply_terminal_colors(&mut terminal, &legacy);
        assert_eq!(terminal.effective_cursor_visual().unwrap(), (CursorShape::Underline, false));
    }

    #[cfg(unix)]
    #[test]
    fn json_line_reader_returns_complete_messages_without_delimiters() {
        let (client, mut server) = UnixStream::pair().unwrap();
        server.write_all(b"{\"fragmented\":").unwrap();
        server.write_all(b"true}\n{\"crlf\":true}\r\n{\"final\":true}").unwrap();
        server.shutdown(Shutdown::Write).unwrap();

        let mut reader = JsonLineReader { inner: BufReader::new(Box::new(client)) };
        assert_eq!(reader.receive().unwrap().as_deref(), Some("{\"fragmented\":true}"));
        assert_eq!(reader.receive().unwrap().as_deref(), Some("{\"crlf\":true}"));
        assert_eq!(reader.receive().unwrap().as_deref(), Some("{\"final\":true}"));
        assert_eq!(reader.receive().unwrap(), None);
    }

    #[cfg(unix)]
    #[test]
    fn json_line_writer_appends_exactly_one_delimiter_per_message() {
        let (client, mut server) = UnixStream::pair().unwrap();
        let mut writer = JsonLineWriter { inner: Box::new(client) };

        writer.send("{\"first\":1}").unwrap();
        writer.send("{\"second\":2}").unwrap();
        writer.close().unwrap();

        let mut bytes = String::new();
        server.read_to_string(&mut bytes).unwrap();
        assert_eq!(bytes, "{\"first\":1}\n{\"second\":2}\n");
    }

    struct CloseTrackingWriter {
        closed: Arc<AtomicBool>,
    }

    impl RemoteMessageWriter for CloseTrackingWriter {
        fn send(&mut self, _message: &str) -> io::Result<()> {
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            self.closed.store(true, Ordering::Release);
            Ok(())
        }
    }

    #[derive(Clone, Copy, Debug)]
    enum InitializationFailure {
        IdentifyRejected,
        WrongApp,
        WrongProtocol,
        ClientInfoRejected,
        SubscribeRejected,
    }

    struct ScriptedInitializationReader {
        responses: Receiver<String>,
    }

    impl RemoteMessageReader for ScriptedInitializationReader {
        fn receive(&mut self) -> io::Result<Option<String>> {
            Ok(self.responses.recv().ok())
        }
    }

    struct ScriptedInitializationWriter {
        responses: Sender<String>,
        failure: InitializationFailure,
        closed: Arc<AtomicBool>,
    }

    impl RemoteMessageWriter for ScriptedInitializationWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let command = request
                .get("cmd")
                .and_then(Value::as_str)
                .ok_or_else(|| io::Error::other("remote request omitted its command"))?;
            let response = match (self.failure, command) {
                (InitializationFailure::IdentifyRejected, "identify") => {
                    json!({"id": id, "ok": false, "error": "identify rejected"})
                }
                (InitializationFailure::WrongApp, "identify") => json!({
                    "id": id,
                    "ok": true,
                    "data": {"app": "not-cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION},
                }),
                (InitializationFailure::WrongProtocol, "identify") => json!({
                    "id": id,
                    "ok": true,
                    "data": {"app": "cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION - 1},
                }),
                (InitializationFailure::ClientInfoRejected, "set-client-info") => {
                    json!({"id": id, "ok": false, "error": "client info rejected"})
                }
                (InitializationFailure::SubscribeRejected, "subscribe") => {
                    json!({"id": id, "ok": false, "error": "subscribe rejected"})
                }
                (_, "identify") => json!({
                    "id": id,
                    "ok": true,
                    "data": {"app": "cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION},
                }),
                (_, "set-client-info" | "subscribe") => {
                    json!({"id": id, "ok": true, "data": null})
                }
                (_, command) => {
                    return Err(io::Error::other(format!(
                        "unexpected initialization command: {command}"
                    )));
                }
            };
            self.responses
                .send(response.to_string())
                .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "reader exited"))
        }

        fn close(&mut self) -> io::Result<()> {
            self.closed.store(true, Ordering::Release);
            Ok(())
        }
    }

    fn scripted_initialization_transport(
        failure: InitializationFailure,
        closed: Arc<AtomicBool>,
    ) -> RemoteTransport {
        let (responses, received_responses) = channel();
        RemoteTransport::new(
            Box::new(ScriptedInitializationReader { responses: received_responses }),
            Box::new(ScriptedInitializationWriter { responses, failure, closed }),
        )
    }

    struct UnexpectedWriteWriter;

    impl RemoteMessageWriter for UnexpectedWriteWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            panic!("unexpected remote write: {message}")
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct AcknowledgingWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    }

    impl RemoteMessageWriter for AcknowledgingWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let session = self
                .session
                .lock()
                .unwrap()
                .as_ref()
                .and_then(Weak::upgrade)
                .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
            let response = session
                .pending
                .lock()
                .unwrap()
                .remove(&id)
                .ok_or_else(|| io::Error::other("remote request was not pending"))?;
            response
                .send(json!({"id": id, "ok": true, "data": null}))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn test_session_with_provider_context(
        writer: Box<dyn RemoteMessageWriter>,
        capabilities: HashSet<String>,
        provider_workspace_authority: Option<BearerToken>,
    ) -> Arc<RemoteSession> {
        Arc::new(RemoteSession {
            writer: Mutex::new(writer),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            shutdown: AtomicBool::new(false),
            surfaces: Mutex::new(HashMap::new()),
            exited_surfaces: Mutex::new(HashSet::new()),
            tree: Mutex::new(RemoteTreeCache::default()),
            tree_refresh: Mutex::new(()),
            tree_stale: AtomicBool::new(true),
            subscription_recovery: Mutex::new(SubscriptionRecoveryState::default()),
            subscribers: MuxEventBroadcaster::default(),
            frame_logs: Mutex::new(HashMap::new()),
            surface_overflow_recovery: Mutex::new(HashMap::new()),
            cell_pixel_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            capabilities: Mutex::new(capabilities),
            provider_workspace_authority,
            provider_workspaces_guarded: AtomicBool::new(false),
        })
    }

    fn test_session(writer: Box<dyn RemoteMessageWriter>) -> Arc<RemoteSession> {
        test_session_with_provider_context(writer, HashSet::new(), None)
    }

    fn test_remote_pty_surface(
        id: SurfaceId,
        cols: u16,
        rows: u16,
        cell_pixels: (u16, u16),
    ) -> Arc<RemoteSurface> {
        let mut term = Terminal::new(cols, rows, 100, Callbacks::default()).unwrap();
        term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1)).unwrap();
        Arc::new(RemoteSurface {
            id,
            kind: SurfaceKind::Pty,
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new(cell_pixels),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        })
    }

    struct RejectingWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    }

    impl RemoteMessageWriter for RejectingWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let session = self
                .session
                .lock()
                .unwrap()
                .as_ref()
                .and_then(Weak::upgrade)
                .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
            let response = session
                .pending
                .lock()
                .unwrap()
                .remove(&id)
                .ok_or_else(|| io::Error::other("remote request was not pending"))?;
            response
                .send(json!({"id": id, "ok": false, "error": "injected rejection"}))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct SilentWriter;

    impl RemoteMessageWriter for SilentWriter {
        fn send(&mut self, _message: &str) -> io::Result<()> {
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn acknowledging_provider_session() -> Arc<RemoteSession> {
        let session_slot = Arc::new(Mutex::new(None));
        let session = test_session_with_provider_context(
            Box::new(AcknowledgingWriter { session: session_slot.clone() }),
            HashSet::from([
                cmux_tui_core::server::PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY.to_string()
            ]),
            Some(BearerToken::new("acknowledged-provider-workspace-authority").unwrap()),
        );
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        session
    }

    #[test]
    fn provider_guard_fails_before_writing_to_an_older_remote_server() {
        let session =
            crate::session::Session::Remote(test_session(Box::new(UnexpectedWriteWriter)));

        let error = session.mark_workspaces_provider_managed().unwrap_err();

        assert_eq!(
            error.to_string(),
            "remote cmux server cannot guard provider-managed workspaces; upgrade the server before attaching"
        );
    }

    #[test]
    fn provider_guard_state_changes_only_after_the_remote_acknowledges() {
        let session = crate::session::Session::Remote(acknowledging_provider_session());

        assert!(!session.workspaces_are_provider_managed());
        session.mark_workspaces_provider_managed().unwrap();
        assert!(session.workspaces_are_provider_managed());
    }

    #[test]
    fn transport_disconnect_closes_the_transport_writer() {
        let closed = Arc::new(AtomicBool::new(false));
        let session = test_session(Box::new(CloseTrackingWriter { closed: closed.clone() }));

        session.disconnect_transport();

        assert!(session.shutdown.load(Ordering::Acquire));
        assert!(closed.load(Ordering::Acquire));
    }

    #[test]
    fn initialization_failures_after_reader_spawn_close_the_transport() {
        for (failure, expected_error) in [
            (InitializationFailure::IdentifyRejected, "identify rejected"),
            (InitializationFailure::WrongApp, "socket endpoint is not a cmux-tui session"),
            (InitializationFailure::WrongProtocol, "unsupported cmux-tui protocol"),
            (InitializationFailure::ClientInfoRejected, "client info rejected"),
            (InitializationFailure::SubscribeRejected, "subscribe rejected"),
        ] {
            let closed = Arc::new(AtomicBool::new(false));
            let result = RemoteSession::connect_transport(scripted_initialization_transport(
                failure,
                closed.clone(),
            ));

            let error = result.err().expect("scripted initialization should fail");
            assert!(
                error.to_string().contains(expected_error),
                "{failure:?} returned unexpected error: {error}"
            );
            assert!(closed.load(Ordering::Acquire), "{failure:?} did not close its transport");
        }
    }

    #[cfg(unix)]
    fn socket_test_session(stream: UnixStream) -> Arc<RemoteSession> {
        stream.set_write_timeout(Some(REMOTE_WRITE_TIMEOUT)).unwrap();
        test_session(Box::new(JsonLineWriter { inner: Box::new(stream) }))
    }

    #[cfg(unix)]
    #[test]
    fn eof_cancels_a_pending_request_without_waiting_for_the_request_timeout() {
        let (client, server) = UnixStream::pair().unwrap();
        let peer = std::thread::spawn(move || {
            let mut peer = BufReader::new(server);
            for expected_command in ["identify", "set-client-info", "subscribe"] {
                let mut line = String::new();
                peer.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["cmd"], expected_command);
                let data = if expected_command == "identify" {
                    json!({"app": "cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION})
                } else {
                    Value::Null
                };
                writeln!(
                    peer.get_mut(),
                    "{}",
                    json!({"id": request["id"], "ok": true, "data": data})
                )
                .unwrap();
            }

            let mut line = String::new();
            peer.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], "wait-for-eof");
            // Dropping the peer produces EOF while this request is pending.
        });
        let session = RemoteSession::connect_stream(Box::new(client)).unwrap();
        let request_session = session.clone();
        let (done_tx, done_rx) = channel();
        let started = Instant::now();
        let request = std::thread::spawn(move || {
            done_tx.send(request_session.request(json!({"cmd": "wait-for-eof"}))).unwrap();
        });

        let result = match done_rx.recv_timeout(Duration::from_secs(2)) {
            Ok(result) => result,
            Err(error) => {
                session.begin_shutdown();
                request.join().unwrap();
                panic!("EOF did not cancel the request promptly: {error}");
            }
        };
        request.join().unwrap();
        peer.join().unwrap();

        let error = result.unwrap_err();
        assert!(matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Shutdown)
        ));
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(session.shutdown.load(Ordering::Acquire));
        assert!(session.pending.lock().unwrap().is_empty());
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
    fn stalled_remote_write_times_out_and_closes_the_transport() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let payload = vec![b'x'; 4 * 1024 * 1024];

        let error = session.send_bytes(7, &payload).unwrap_err();

        assert!(error.downcast_ref::<RemoteRequestError>().is_some_and(|error| {
            matches!(error, RemoteRequestError::Transport(io_error) if matches!(
                io_error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
            ))
        }));
        assert!(session.pending.lock().unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn repeated_surface_overflow_stops_until_reconnect() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);

        for _ in 0..SURFACE_OVERFLOW_RETRY_DELAYS.len() {
            let (delay, stopped) = session.record_surface_overflow(7);
            assert!(delay.is_some());
            assert!(!stopped);
            let mut recoveries = session.surface_overflow_recovery.lock().unwrap();
            let recovery = recoveries.get_mut(&7).unwrap();
            recovery.retry_after = Some(Instant::now() - Duration::from_millis(1));
            recovery.attached_at = Some(Instant::now());
            drop(recoveries);
            assert!(session.can_attach_after_overflow(7));
        }

        let (delay, stopped) = session.record_surface_overflow(7);
        assert!(delay.is_none());
        assert!(stopped);
        assert!(!session.can_attach_after_overflow(7));

        let mut recoveries = session.surface_overflow_recovery.lock().unwrap();
        let recovery = recoveries.get_mut(&7).unwrap();
        recovery.attached_at = Some(Instant::now() - SURFACE_OVERFLOW_STABLE);
        drop(recoveries);
        let (delay, stopped) = session.record_surface_overflow(7);
        assert_eq!(delay, Some(SURFACE_OVERFLOW_RETRY_DELAYS[0]));
        assert!(!stopped);
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

    #[cfg(unix)]
    #[test]
    fn unknown_surface_title_churn_emits_one_tree_invalidation_per_stale_transition() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.tree_stale.store(false, Ordering::Release);

        for index in 0..1_000 {
            session.handle_line(json!({
                "event": "title-changed",
                "surface": 77,
                "title": format!("unknown-{index}"),
            }));
        }

        let received = events.try_iter().collect::<Vec<_>>();
        assert_eq!(
            received.iter().filter(|event| matches!(event, MuxEvent::TreeChanged)).count(),
            1
        );
        assert!(
            received
                .iter()
                .any(|event| matches!(event, MuxEvent::TitleChanged { surface: 77, .. }))
        );

        assert!(session.take_tree_stale());
        session.handle_line(json!({
            "event": "title-changed",
            "surface": 77,
            "title": "after-refresh",
        }));
        assert!(events.try_iter().any(|event| matches!(event, MuxEvent::TreeChanged)));
    }

    #[cfg(unix)]
    #[test]
    fn client_presence_events_reach_remote_tui_subscribers() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();

        session.handle_line(json!({
            "event": "client-attached",
            "client": 7,
            "transport": "unix",
            "name": "small",
            "kind": "tui",
        }));
        session.handle_line(json!({
            "event": "client-changed",
            "client": 7,
            "name": "small",
            "kind": "tui",
        }));
        session.handle_line(json!({"event": "client-detached", "client": 7}));

        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientAttached { client: 7, .. })
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: 7, .. })
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientDetached(7))
        ));
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
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
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

    #[cfg(unix)]
    #[test]
    fn initial_attach_resolves_sparse_source_palette_before_rendering() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let surface = Arc::new(RemoteSurface {
            id: 7,
            kind: SurfaceKind::Pty,
            term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        session.surfaces.lock().unwrap().insert(7, surface.clone());

        session.handle_line(json!({
            "event": "vt-state",
            "surface": 7,
            "cols": 12,
            "rows": 4,
            "data": base64::engine::general_purpose::STANDARD.encode(b"\x1b[31mX"),
            "colors": {
                "fg": "#eeeeee",
                "bg": "#101010",
                "cursor": "#eeeeee",
                "cursor_style": "block",
                "cursor_blink": true,
                "palette": {"1": "#ff3562"},
            },
        }));

        let mut terminal = surface.term.lock().unwrap();
        assert_eq!(terminal.color_overrides().palette[1], Some(Rgb { r: 0xff, g: 0x35, b: 0x62 }));
        let mut render = RenderState::new().unwrap();
        render.update(&mut terminal).unwrap();
        assert!(render.palette_overridden(1));
        assert_eq!(render.palette_color(1), Rgb { r: 0xff, g: 0x35, b: 0x62 });
        let frame = render.build_frame().unwrap();
        let cell = &frame.styled_row(0).unwrap()[0];
        assert_eq!(cell.fg, ColorSpec::Palette(1));
        assert_eq!(cell.resolved_fg, Some(Rgb { r: 0xff, g: 0x35, b: 0x62 }));
    }

    #[cfg(unix)]
    #[test]
    fn colors_changed_replaces_complete_sparse_palette_state() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let surface = Arc::new(RemoteSurface {
            id: 7,
            kind: SurfaceKind::Pty,
            term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        {
            let mut terminal = surface.term.lock().unwrap();
            terminal.replace_default_colors(
                Some(Rgb { r: 0xaa, g: 0xbb, b: 0xcc }),
                Some(Rgb { r: 0x11, g: 0x22, b: 0x33 }),
                Some(Rgb { r: 0xdd, g: 0xee, b: 0xff }),
            );
            terminal.vt_write(b"\x1b]4;1;rgb:ff/35/62\x1b\\");
        }
        session.surfaces.lock().unwrap().insert(7, surface.clone());

        session.handle_line(json!({
            "event": "colors-changed",
            "surface": 7,
            "palette": {"196": "#010203"},
        }));

        let terminal = surface.term.lock().unwrap();
        assert_eq!(terminal.effective_colors(), (None, None, None));
        let palette = terminal.color_overrides().palette;
        assert_eq!(palette[1], None);
        assert_eq!(palette[196], Some(Rgb { r: 1, g: 2, b: 3 }));
        assert!(surface.dirty.load(Ordering::Acquire));
    }

    #[cfg(unix)]
    #[test]
    fn reused_render_state_observes_complete_special_color_reset() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let surface = Arc::new(RemoteSurface {
            id: 7,
            kind: SurfaceKind::Pty,
            term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        session.surfaces.lock().unwrap().insert(7, surface.clone());

        session.handle_line(json!({
            "event": "vt-state",
            "surface": 7,
            "cols": 12,
            "rows": 4,
            "data": base64::engine::general_purpose::STANDARD.encode(b"prompt"),
            "colors": {
                "fg": "#fdfff1",
                "bg": "#272822",
                "cursor": "#c0c1b5",
                "cursor_style": "bar",
                "cursor_blink": true,
                "palette": {},
            },
        }));

        let mut render = RenderState::new().unwrap();
        {
            let mut terminal = surface.term.lock().unwrap();
            render.update(&mut terminal).unwrap();
            let frame = render.build_frame().unwrap();
            assert_eq!(frame.default_colors.0, Rgb { r: 0x27, g: 0x28, b: 0x22 });
        }

        session.handle_line(json!({
            "event": "output",
            "surface": 7,
            "data": base64::engine::general_purpose::STANDARD
                .encode(
                    b"\x1b]4;1;#112233\x1b\\\x1b]10;#eeeeee\x1b\\\x1b]11;#171b2e\x1b\\\x1b]12;#ffee00\x1b\\"
                ),
            "colors": {
                "fg": "#eeeeee",
                "bg": "#171b2e",
                "cursor": "#ffee00",
                "cursor_style": "bar",
                "cursor_blink": true,
                "palette": {"1": "#112233"},
            },
        }));
        {
            let mut terminal = surface.term.lock().unwrap();
            render.update(&mut terminal).unwrap();
            let frame = render.build_frame().unwrap();
            assert_eq!(frame.default_colors.0, Rgb { r: 0x17, g: 0x1b, b: 0x2e });
        }

        session.handle_line(json!({
            "event": "output",
            "surface": 7,
            "data": base64::engine::general_purpose::STANDARD
                .encode(b"\x1b]104\x1b\\\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\"),
            "colors": {
                "fg": "#fdfff1",
                "bg": "#272822",
                "cursor": "#c0c1b5",
                "cursor_style": "bar",
                "cursor_blink": true,
                "palette": {},
            },
        }));
        {
            let mut terminal = surface.term.lock().unwrap();
            assert_eq!(
                terminal.effective_colors(),
                (
                    Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }),
                    Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }),
                    Some(Rgb { r: 0xc0, g: 0xc1, b: 0xb5 }),
                )
            );
            let overrides = terminal.color_overrides();
            assert_eq!(overrides.foreground, None);
            assert_eq!(overrides.background, None);
            assert_eq!(overrides.cursor, None);
            assert_eq!(overrides.palette[1], None);
            render.update(&mut terminal).unwrap();
            let frame = render.build_frame().unwrap();
            assert_eq!(
                frame.default_colors,
                (Rgb { r: 0x27, g: 0x28, b: 0x22 }, Rgb { r: 0xfd, g: 0xff, b: 0xf1 },)
            );
            assert_eq!(frame.cursor_color, Some(Rgb { r: 0xc0, g: 0xc1, b: 0xb5 }));
            let cell = &frame.styled_row(0).unwrap()[0];
            assert_eq!(cell.fg, ColorSpec::Default);
            assert_eq!(cell.bg, ColorSpec::Default);
        }
    }

    #[test]
    fn remote_surface_resize_and_cell_pixel_update_are_one_geometry_transaction() {
        let surface = test_remote_pty_surface(1, 80, 24, (8, 16));
        let (resize_entered_tx, resize_entered_rx) = channel();
        let (release_resize_tx, release_resize_rx) = channel();
        let (cell_started_tx, cell_started_rx) = channel();
        let release_resize_rx = Arc::new(Mutex::new(release_resize_rx));
        *surface.geometry_test_hook.lock().unwrap() = Some(Arc::new({
            move |step| match step {
                RemoteGeometryTestStep::StreamResizeCommitBoundary => {
                    resize_entered_tx.send(()).unwrap();
                    release_resize_rx.lock().unwrap().recv().unwrap();
                }
                RemoteGeometryTestStep::CellPixelStarted => {
                    cell_started_tx.send(()).unwrap();
                }
                _ => {}
            }
        }));

        let resizing_surface = surface.clone();
        let resizing = std::thread::spawn(move || {
            resizing_surface.apply_stream_resize(100, 30, None, &[]);
        });
        resize_entered_rx.recv().unwrap();

        let updating_surface = surface.clone();
        let (cell_done_tx, cell_done_rx) = channel();
        let updating = std::thread::spawn(move || {
            updating_surface.set_cell_pixel_size(9, 18).unwrap();
            cell_done_tx.send(()).unwrap();
        });
        cell_started_rx.recv().unwrap();
        let cell_completed_while_resize_was_uncommitted =
            cell_done_rx.recv_timeout(Duration::from_millis(100)).is_ok();

        release_resize_tx.send(()).unwrap();
        resizing.join().unwrap();
        updating.join().unwrap();

        assert!(
            !cell_completed_while_resize_was_uncommitted,
            "cell pixels committed while the ordered stream resize was paused"
        );
        assert_eq!(*surface.cell_pixels.lock().unwrap(), (9, 18));
        let term = surface.term.lock().unwrap();
        assert_eq!((term.cols(), term.rows()), (100, 30));
    }

    #[test]
    fn stream_resize_without_pixel_dimensions_preserves_last_cell_measurement() {
        let surface = test_remote_pty_surface(1, 80, 24, (8, 16));
        surface.set_cell_pixel_size(11, 19).unwrap();

        surface.apply_stream_resize(90, 31, None, &[]);

        assert_eq!(*surface.cell_pixels.lock().unwrap(), (11, 19));
        let term = surface.term.lock().unwrap();
        assert_eq!((term.cols(), term.rows()), (90, 31));
    }

    #[test]
    fn rejected_cell_pixel_request_rolls_back_session_and_mirror_geometry() {
        let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
        let session = test_session(Box::new(RejectingWriter { session: session_slot.clone() }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
        session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

        let error = session.set_cell_pixel_size(9, 18).err().expect("injected rejection must fail");

        assert!(matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Rejected(message)) if message == "injected rejection"
        ));
        assert_eq!(*session.cell_pixels.lock().unwrap(), (8, 16));
        assert_eq!(*surface.cell_pixels.lock().unwrap(), (8, 16));
    }

    #[test]
    fn timed_out_cell_pixel_request_rolls_back_session_and_mirror_geometry() {
        let session = test_session(Box::new(SilentWriter));
        let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
        session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

        let error = session.set_cell_pixel_size(9, 18).err().expect("silent remote must time out");

        assert!(matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Timeout)
        ));
        assert_eq!(*session.cell_pixels.lock().unwrap(), (8, 16));
        assert_eq!(*surface.cell_pixels.lock().unwrap(), (8, 16));
        assert!(session.pending.lock().unwrap().is_empty());
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
        let replay = server.vt_replay_bytes().unwrap();

        let surface = RemoteSurface {
            id: 1,
            kind: SurfaceKind::Pty,
            term: Mutex::new(Terminal::new(20, 6, 100, Callbacks::default()).unwrap()),
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        {
            let mut mirror = surface.term.lock().unwrap();
            mirror.vt_write(b"mirror-only\r\nstate\r\n");
        }

        surface.apply_stream_resize(8, 4, Some(&replay), &[]);
        let scrollback_rows = {
            let mut mirror = surface.term.lock().unwrap();
            assert_eq!(mirror.plain_text().unwrap(), server_text);
            assert_eq!(mirror.selection_text_absolute((0, 0), (4, 0)).unwrap(), server_oldest);
            mirror.scrollback_rows()
        };

        surface.apply_stream_resize(8, 4, Some(&replay), &[]);
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
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        session.surfaces.lock().unwrap().insert(7, surface.clone());

        let mut authoritative = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
        for index in 0..8 {
            authoritative.vt_write(format!("authoritative-{index}\r\n").as_bytes());
        }
        authoritative.resize(8, 4, 8, 16).unwrap();
        let expected = authoritative.plain_text().unwrap();
        let replay = authoritative.vt_replay_bytes().unwrap();
        session.handle_line(json!({
            "event": "resized",
            "surface": 7,
            "cols": 8,
            "rows": 4,
            "replay": base64::engine::general_purpose::STANDARD.encode(replay),
        }));

        assert_eq!(surface.term.lock().unwrap().plain_text().unwrap(), expected);
    }

    #[cfg(unix)]
    #[test]
    fn real_server_attach_and_resize_preserve_kitty_number_aliases() {
        let mux = cmux_tui_core::Mux::new(
            format!("remote-kitty-aliases-{}", std::process::id()),
            cmux_tui_core::SurfaceOptions {
                command: Some(vec!["/bin/cat".to_string()]),
                ..Default::default()
            },
        );
        let authoritative = mux.new_workspace(None, Some((20, 4))).unwrap();
        authoritative
            .try_with_terminal(|terminal| {
                terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,I=77,s=1,v=1,q=2;/wAA\x1b\\");
            })
            .unwrap();
        let image_id = authoritative
            .try_with_terminal(|terminal| terminal.kitty_graphics_snapshot().unwrap().images[0].id)
            .unwrap();

        let socket = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
        let remote = RemoteSession::connect(&socket).unwrap();
        let mirror = remote
            .try_ensure_surface_with_kind(authoritative.id, SurfaceKind::Pty, Some((20, 4)))
            .unwrap()
            .unwrap();

        let wait_for = |mut predicate: Box<dyn FnMut() -> bool>| {
            let deadline = Instant::now() + Duration::from_secs(5);
            while !predicate() {
                assert!(Instant::now() < deadline, "remote mirror did not converge");
                std::thread::sleep(Duration::from_millis(10));
            }
        };
        wait_for(Box::new({
            let mirror = mirror.clone();
            move || {
                mirror
                    .term
                    .lock()
                    .unwrap()
                    .kitty_graphics_snapshot()
                    .unwrap()
                    .image(image_id)
                    .is_some_and(|image| image.number == 77)
            }
        }));

        mux.resize_surface(authoritative.id, 21, 4).unwrap();
        wait_for(Box::new({
            let mirror = mirror.clone();
            move || {
                let terminal = mirror.term.lock().unwrap();
                terminal.cols() == 21
                    && terminal
                        .kitty_graphics_snapshot()
                        .unwrap()
                        .image(image_id)
                        .is_some_and(|image| image.number == 77)
            }
        }));

        authoritative.write_bytes(b"\x1b_Ga=p,I=77,p=12,c=1,r=1,q=2;\x1b\\\n").unwrap();
        wait_for(Box::new({
            move || {
                mirror
                    .term
                    .lock()
                    .unwrap()
                    .kitty_graphics_snapshot()
                    .unwrap()
                    .placements
                    .iter()
                    .any(|placement| placement.image_id == image_id && placement.placement_id == 12)
            }
        }));

        remote.begin_shutdown();
        let _ = mux.close_surface(authoritative.id);
        cmux_tui_core::server::cleanup(&socket);
    }

    #[cfg(unix)]
    #[test]
    fn surface_resized_event_is_forwarded_without_changing_reported_size() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        let surface = Arc::new(RemoteSurface {
            id: 7,
            kind: SurfaceKind::Browser,
            term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(Some((12, 4))),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        session.surfaces.lock().unwrap().insert(7, surface.clone());

        session.handle_line(json!({
            "event": "surface-resized",
            "surface": 7,
            "cols": 90,
            "rows": 31,
        }));

        assert_eq!(surface.reported_size(), Some((12, 4)));
        assert!(events.try_iter().any(|event| matches!(
            event,
            MuxEvent::SurfaceResized { surface: 7, cols: 90, rows: 31, .. }
        )));
    }

    #[cfg(unix)]
    #[test]
    fn surface_resize_failure_releases_remote_browser_report() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        let surface = Arc::new(RemoteSurface {
            id: 7,
            kind: SurfaceKind::Browser,
            term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(Some((90, 31))),
            browser: Mutex::new(RemoteBrowserState::default()),
        });
        session.surfaces.lock().unwrap().insert(7, surface.clone());

        session.handle_line(json!({
            "event": "surface-resize-failed",
            "surface": 7,
            "cols": 90,
            "rows": 31,
            "error": "device metrics rejected",
            "retry_after_ms": 250,
        }));

        assert_eq!(surface.reported_size(), None);
        assert!(events.try_iter().any(|event| matches!(
            event,
            MuxEvent::SurfaceResizeFailed {
                surface: 7,
                cols: 90,
                rows: 31,
                retry_after_ms: Some(250),
                ..
            }
        )));
    }

    #[cfg(unix)]
    #[test]
    fn notification_event_preserves_payload_without_invalidating_tree() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.tree_stale.store(false, Ordering::Release);

        session.handle_line(json!({
            "event": "notification",
            "notification": 42,
            "title": "Build",
            "body": "finished",
            "level": "warning",
            "surface": 7,
        }));

        assert!(!session.tree_is_stale());
        assert!(events.try_iter().any(|event| {
            matches!(
                event,
                MuxEvent::Notification(notification)
                    if notification.notification == 42
                        && notification.title == "Build"
                        && notification.body == "finished"
                        && notification.level == NotificationLevel::Warning
                        && notification.surface == Some(7)
            )
        }));
    }

    #[cfg(unix)]
    #[test]
    fn subscription_overflow_resubscribes_and_invalidates_authoritative_snapshots() {
        let (client, server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.tree_stale.store(false, Ordering::Release);

        session.handle_line(json!({
            "event": "overflow",
            "error": "subscriber fell behind",
        }));

        let mut line = String::new();
        BufReader::new(server).read_line(&mut line).unwrap();
        let command: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(command.get("cmd").and_then(Value::as_str), Some("subscribe"));
        session.handle_line(json!({"id": command["id"], "ok": true, "data": {}}));
        assert!(session.tree_is_stale());
        let mut saw_status = false;
        let mut saw_tree = false;
        let mut saw_clients = false;
        while !saw_tree || !saw_clients {
            match events.recv_timeout(Duration::from_secs(1)).unwrap() {
                MuxEvent::Status(_) => saw_status = true,
                MuxEvent::TreeChanged => saw_tree = true,
                MuxEvent::ClientListInvalidated => saw_clients = true,
                _ => {}
            }
        }
        assert!(saw_status);
    }

    #[cfg(unix)]
    #[test]
    fn subscription_overflow_during_recovery_forces_another_resubscribe() {
        let (client, server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        let mut server = BufReader::new(server);

        session.handle_line(json!({"event": "overflow", "error": "first stream overflow"}));
        let mut line = String::new();
        server.read_line(&mut line).unwrap();
        let first: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(first.get("cmd").and_then(Value::as_str), Some("subscribe"));

        session.handle_line(json!({"event": "overflow", "error": "replacement overflow"}));
        session.handle_line(json!({"id": first["id"], "ok": true, "data": {}}));

        line.clear();
        server.read_line(&mut line).unwrap();
        let second: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(second.get("cmd").and_then(Value::as_str), Some("subscribe"));
        assert_ne!(second["id"], first["id"]);
        session.handle_line(json!({"id": second["id"], "ok": true, "data": {}}));

        loop {
            if matches!(
                events.recv_timeout(Duration::from_secs(1)).unwrap(),
                MuxEvent::ClientListInvalidated
            ) {
                break;
            }
        }
        let recovery = session.subscription_recovery.lock().unwrap();
        assert!(!recovery.in_flight);
        assert_eq!(recovery.generation, 2);
    }

    #[cfg(unix)]
    #[test]
    fn rejected_subscription_recovery_retries_then_closes_session() {
        let (client, server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();

        session.handle_line(json!({"event": "overflow", "error": "subscriber fell behind"}));

        let mut line = String::new();
        let mut server = BufReader::new(server);
        server.read_line(&mut line).unwrap();
        let command: Value = serde_json::from_str(&line).unwrap();
        session.handle_line(json!({
            "id": command["id"],
            "ok": false,
            "error": "replacement rejected",
        }));

        line.clear();
        server.read_line(&mut line).unwrap();
        let retry: Value = serde_json::from_str(&line).unwrap();
        session.handle_line(json!({
            "id": retry["id"],
            "ok": false,
            "error": "replacement rejected again",
        }));

        loop {
            if matches!(events.recv_timeout(Duration::from_secs(1)).unwrap(), MuxEvent::Empty) {
                break;
            }
        }
        assert!(!session.subscription_recovery.lock().unwrap().in_flight);
    }

    #[test]
    fn subscription_recovery_retries_only_explicit_rejection() {
        let rejected = anyhow::Error::new(RemoteRequestError::Rejected("no capacity".to_string()));
        let timeout = anyhow::Error::new(RemoteRequestError::Timeout);
        let shutdown = anyhow::Error::new(RemoteRequestError::Shutdown);

        assert!(RemoteSession::subscription_recovery_is_retryable(&rejected));
        assert!(!RemoteSession::subscription_recovery_is_retryable(&timeout));
        assert!(!RemoteSession::subscription_recovery_is_retryable(&shutdown));
    }

    #[cfg(unix)]
    #[test]
    fn surface_overflow_invalidates_mirror_and_requests_reattach() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.surfaces.lock().unwrap().insert(
            7,
            Arc::new(RemoteSurface {
                id: 7,
                kind: SurfaceKind::Pty,
                term: Mutex::new(Terminal::new(80, 24, 100, Callbacks::default()).unwrap()),
                mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
                dirty: AtomicBool::new(false),
                geometry_lifecycle: Mutex::new(()),
                cell_pixels: Mutex::new((8, 16)),
                geometry_test_hook: Mutex::new(None),
                reported_size: Mutex::new(None),
                browser: Mutex::new(RemoteBrowserState::default()),
            }),
        );

        session.handle_line(json!({
            "event": "overflow",
            "scope": "surface",
            "surface": 7,
            "error": "surface stream fell behind",
        }));

        assert!(!session.has_surface(7));
        assert!(!session.exited_surfaces.lock().unwrap().contains(&7));
        let received = events.try_iter().collect::<Vec<_>>();
        assert!(received.iter().any(|event| matches!(event, MuxEvent::SurfaceOutput(7))));
        assert!(received.iter().any(|event| matches!(event, MuxEvent::Status(_))));
    }

    #[test]
    fn ordered_resize_replay_recovers_from_stale_initial_replay() {
        let mut server = Terminal::new(12, 3, 100, Callbacks::default()).unwrap();
        server.vt_write(b"\x1b[7m%\x1b[0m");
        let stale_replay = server.vt_replay_bytes().unwrap();

        server.resize(10, 3, 8, 16).unwrap();
        let resize_replay = server.vt_replay_bytes().unwrap();
        let prompt = b"\r\x1b[Klawrence";
        server.vt_write(prompt);
        let server_text = server.plain_text().unwrap();
        assert!(server_text.lines().next().unwrap_or_default().contains("lawrence"));

        let surface = RemoteSurface {
            id: 1,
            kind: SurfaceKind::Pty,
            term: Mutex::new(Terminal::new(12, 3, 100, Callbacks::default()).unwrap()),
            mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        surface.apply_stream_resize(12, 3, None, &[]);
        surface.term.lock().unwrap().vt_write(&stale_replay);
        surface.apply_stream_resize(10, 3, Some(&resize_replay), &[]);
        let mut mirror = surface.term.lock().unwrap();
        mirror.vt_write(prompt);

        assert_eq!(mirror.plain_text().unwrap(), server_text);
    }
}
