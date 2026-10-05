//! Remote session client: JSON-lines control socket plus locally
//! mirrored surface terminals (VT replay + live stream).

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::net::Shutdown;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_tui_core::server::{VIEWPORT_COLUMN_RESIZE_CAPABILITY, VIEWPORT_SPLITS_CAPABILITY};
use cmux_tui_core::sizing_policy::TerminalSizingState;
use cmux_tui_core::{
    BrowserFrame, BrowserFrameUpdate, BrowserSource, BrowserStatus, ClearHistoryDelivery,
    ClearHistoryFailure, GraphicsStatus, GuardedMouseEncode, MuxEvent, MuxEventBroadcaster,
    MuxEventReceiver, NotificationEvent, NotificationLevel, NotificationSource, PairingChallenge,
    PointerSemanticProbe, PointerSnapshotProbe, REMOTE_SESSION_MESSAGE_MAX_BYTES, Rgb, SurfaceId,
    SurfaceKind, TerminalPointerSnapshot,
    platform::transport,
    server::{
        CLEAR_HISTORY_CAPABILITY, CLEAR_HISTORY_KEY_CAPABILITY, CREATION_RECEIPTS_CAPABILITY,
        CREATION_SELECTOR_FALLBACKS_CAPABILITY, GUARDED_BROWSER_POINTER_CAPABILITY,
        ProtocolKeyInput, SHARED_SIZING_CAPABILITY, TERMINAL_PENDING_SEQUENCE_CAPABILITY,
        VIEW_ATTACHMENT_DETACH_CAPABILITY, VIEW_ATTACHMENT_LEASE_CAPABILITY,
    },
};
use cmux_tui_machine_protocol::BearerToken;
use ghostty_vt::{
    Callbacks, CursorShape, KeyInput, KittyGraphicsLimits, KittyImageIdCursors, KittyReplayState,
    MouseEncoders, MouseInput, RenderState, Terminal, TerminalColorOverrides,
    TerminalPointerSemanticSnapshot, parse_color,
};
use serde_json::{Value, json};
use zeroize::{Zeroize, Zeroizing};

use super::cursor_provenance::CursorStyleProvenance;
use super::parse_identity_capabilities;
#[cfg(test)]
use super::tree::parse_tree;
use super::tree::{TreeCapabilities, TreeView, parse_tree_with_capabilities};
use super::{AgentInfo, CLEAR_HISTORY_UNSUPPORTED_ERROR};

const SUPPORTED_PROTOCOL_VERSION: u64 = 12;
const SURFACE_OVERFLOW_RETRY_DELAYS: [Duration; 3] =
    [Duration::from_millis(250), Duration::from_millis(500), Duration::from_secs(1)];
const SURFACE_OVERFLOW_STABLE: Duration = Duration::from_secs(5);
const MAX_SURFACE_OVERFLOW_RECOVERIES: usize = 256;
const INTERACTIVE_WRITE_QUEUE_CAPACITY: usize = 512;
const INTERACTIVE_WRITE_QUEUE_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const REMOTE_CONTROL_MESSAGE_MAX_BYTES: usize = REMOTE_SESSION_MESSAGE_MAX_BYTES;
const REMOTE_FRAME_LOG_MAX_ENTRIES: usize = 16 * 1024;
const REMOTE_FRAME_LOG_MAX_BYTES: usize = 2 * 1024 * 1024;
const REMOTE_TERMINAL_DIMENSION_MAX: u64 = 10_000;
const REMOTE_TERMINAL_CELL_MAX: u64 = 1024 * 1024;
const INTERACTIVE_LATENCY_BUCKET_UPPER_US: [u64; 18] = [
    50,
    100,
    250,
    500,
    1_000,
    2_000,
    5_000,
    10_000,
    25_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_000_000,
    5_000_000,
    30_000_000,
    u64::MAX,
];
#[cfg(not(test))]
fn remote_write_timeout() -> Duration {
    Duration::from_secs(2)
}

#[cfg(test)]
fn remote_write_timeout() -> Duration {
    static TIMEOUT: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
    *TIMEOUT.get_or_init(|| {
        let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
            .ok()
            .and_then(|value| value.parse::<u32>().ok())
            .filter(|scale| *scale > 0)
            .unwrap_or(1);
        Duration::from_millis(100).saturating_mul(scale)
    })
}
#[cfg(not(test))]
const REMOTE_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(test)]
const REMOTE_REQUEST_TIMEOUT: Duration = Duration::from_millis(100);
#[cfg(not(test))]
const REMOTE_ATTACH_IDLE_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(test)]
const REMOTE_ATTACH_IDLE_TIMEOUT: Duration = Duration::from_millis(250);
#[cfg(not(test))]
const REMOTE_ATTACH_MAX_TIMEOUT: Duration = Duration::from_secs(15 * 60);
#[cfg(test)]
const REMOTE_ATTACH_MAX_TIMEOUT: Duration = Duration::from_secs(3);
#[cfg(not(test))]
const GUARDED_POINTER_REQUEST_TIMEOUT: Duration = REMOTE_REQUEST_TIMEOUT;
#[cfg(test)]
const GUARDED_POINTER_REQUEST_TIMEOUT: Duration = Duration::from_millis(100);

fn zeroize_string(value: &mut str) {
    // NUL is valid UTF-8, so the serialized request can be cleared in place
    // immediately after the synchronous transport write finishes.
    value.zeroize();
}

fn parse_graphics_status(value: &Value) -> Option<GraphicsStatus> {
    match value.get("kind").and_then(Value::as_str)? {
        "kitty-image-budget-worker-start-failed" => {
            Some(GraphicsStatus::KittyImageBudgetWorkerStartFailed {
                error: Arc::<str>::from(value.get("error")?.as_str()?),
            })
        }
        "kitty-image-budget-update-failed" => Some(GraphicsStatus::KittyImageBudgetUpdateFailed {
            retry_exhausted: value.get("retry_exhausted")?.as_bool()?,
            summary: Arc::<str>::from(value.get("summary")?.as_str()?),
        }),
        "cell-pixel-update-retries-exhausted" => {
            Some(GraphicsStatus::CellPixelUpdateRetriesExhausted {
                attempts: u8::try_from(value.get("attempts")?.as_u64()?).ok()?,
                remaining: usize::try_from(value.get("remaining")?.as_u64()?).ok()?,
                cell_pixels: (
                    u16::try_from(value.get("cell_width")?.as_u64()?).ok()?,
                    u16::try_from(value.get("cell_height")?.as_u64()?).ok()?,
                ),
            })
        }
        _ => None,
    }
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
    parse_identity_capabilities(ident)
        .map_err(|reason| anyhow::anyhow!("invalid identity capabilities: {reason}"))?;
    Ok(())
}

fn remote_terminal_size(value: &Value) -> Option<(u16, u16)> {
    let dimension = |name: &str, default: u16| match value.get(name) {
        None => Some(default),
        Some(value) => u16::try_from(value.as_u64()?).ok(),
    };
    let cols = dimension("cols", 80)?;
    let rows = dimension("rows", 24)?;
    if cols == 0
        || rows == 0
        || u64::from(cols) > REMOTE_TERMINAL_DIMENSION_MAX
        || u64::from(rows) > REMOTE_TERMINAL_DIMENSION_MAX
        || u64::from(cols).saturating_mul(u64::from(rows)) > REMOTE_TERMINAL_CELL_MAX
    {
        return None;
    }
    Some((cols, rows))
}

fn identity_capabilities(ident: &Value) -> HashSet<String> {
    parse_identity_capabilities(ident).unwrap_or_default()
}

fn require_capability(
    capabilities: &HashSet<String>,
    capability: &str,
    operation: &str,
) -> anyhow::Result<()> {
    if capabilities.contains(capability) {
        Ok(())
    } else if operation == "clear-history" {
        anyhow::bail!(CLEAR_HISTORY_UNSUPPORTED_ERROR)
    } else {
        anyhow::bail!("remote server does not support {operation}; restart the cmux-tui server")
    }
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
    Rejected { error: String, code: Option<String>, delivery: Option<ClearHistoryDelivery> },
    Shutdown,
    DaemonShutdown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum GuardedPointerLifecycle {
    Motion,
    CaptureMutation,
}

impl RemoteRequestError {
    pub(crate) fn is_transport_failure(&self) -> bool {
        matches!(self, Self::Transport(_))
    }

    pub(crate) fn is_timeout(&self) -> bool {
        matches!(self, Self::Timeout)
    }

    pub(crate) fn rejection_code(&self) -> Option<&str> {
        match self {
            Self::Rejected { code, .. } => code.as_deref(),
            _ => None,
        }
    }

    pub(crate) fn rejection_message(&self) -> Option<&str> {
        match self {
            Self::Rejected { error, .. } => Some(error),
            _ => None,
        }
    }
}

impl std::fmt::Display for RemoteRequestError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Encode(error) => write!(formatter, "could not encode remote request: {error}"),
            Self::Transport(error) => write!(formatter, "remote transport write failed: {error}"),
            Self::Timeout => write!(formatter, "remote session did not respond"),
            Self::Rejected { error, .. } => write!(formatter, "remote command rejected: {error}"),
            Self::Shutdown => write!(formatter, "remote response wait canceled for shutdown"),
            Self::DaemonShutdown => write!(formatter, "remote daemon shut down by request"),
        }
    }
}

impl std::error::Error for RemoteRequestError {}
#[derive(Clone)]
struct RemoteBrowserFrame {
    frame: Arc<BrowserFrame>,
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
    pointer_frame_floor_seq: Option<u64>,
    pointer_frame_seq: Option<u64>,
    presented_pointer_frame_seq: Option<u64>,
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
            pointer_frame_floor_seq: None,
            pointer_frame_seq: None,
            presented_pointer_frame_seq: None,
        }
    }
}

#[derive(Default)]
struct RemoteTreeCache {
    view: TreeView,
    agents: Vec<AgentInfo>,
    surface_tabs: HashMap<SurfaceId, [usize; 4]>,
    title_generation: u64,
    title_updates: HashMap<SurfaceId, TitleUpdate>,
    agent_generation: u64,
    agent_updates: HashMap<SurfaceId, AgentUpdate>,
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

struct AgentUpdate {
    generation: u64,
    agent: AgentInfo,
}

impl RemoteTreeCache {
    fn replace(&mut self, view: TreeView, refresh_generation: u64) {
        self.surface_tabs.clear();
        for (workspace_index, workspace) in view.workspaces().iter().enumerate() {
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
        let Some(location) = self.surface_tabs.get(&surface_id).copied() else {
            return false;
        };
        self.view.update_surface_title_at(surface_id, location, &title).is_some()
    }

    fn title_generation(&self) -> u64 {
        self.title_generation
    }

    fn replace_agents(
        &mut self,
        agents: Vec<AgentInfo>,
        refresh_generation: u64,
        retired_surfaces: &HashSet<SurfaceId>,
    ) {
        self.agents =
            agents.into_iter().filter(|agent| !retired_surfaces.contains(&agent.surface)).collect();
        let updates = std::mem::take(&mut self.agent_updates);
        for (surface, update) in updates {
            if retired_surfaces.contains(&surface) {
                continue;
            }
            if self.surface_tabs.contains_key(&surface) {
                // A pending update may have been observed during an earlier
                // refresh whose topology omitted this surface. Reapply it
                // only when it is newer than the current snapshot boundary.
                // An equal-or-older update was already included in the
                // boundary and must not resurrect an agent omitted by the
                // authoritative roster response when a stale topology
                // briefly shows the surface again.
                if update.generation > refresh_generation {
                    self.replace_agent(update.agent);
                }
            } else if update.generation > refresh_generation {
                // The topology response can lag the event stream. Keep a
                // newer event until a later topology confirms the surface is
                // gone instead of dropping it at this refresh boundary.
                self.agent_updates.insert(surface, update);
            }
        }
    }

    fn update_agent(&mut self, agent: AgentInfo, retired_surfaces: &HashSet<SurfaceId>) {
        if retired_surfaces.contains(&agent.surface) {
            return;
        }
        self.agent_generation = self.agent_generation.saturating_add(1);
        self.agent_updates.insert(
            agent.surface,
            AgentUpdate { generation: self.agent_generation, agent: agent.clone() },
        );
        self.replace_agent(agent);
    }

    fn replace_agent(&mut self, agent: AgentInfo) {
        if let Some(existing) = self.agents.iter_mut().find(|item| item.surface == agent.surface) {
            *existing = agent;
        } else {
            self.agents.push(agent);
        }
    }

    fn remove_agent(&mut self, surface: SurfaceId) {
        self.agents.retain(|agent| agent.surface != surface);
        self.agent_updates.remove(&surface);
    }

    fn agent_generation(&self) -> u64 {
        self.agent_generation
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
    cursor_provenance: Mutex<CursorStyleProvenance>,
    pub dirty: AtomicBool,
    geometry_lifecycle: Mutex<()>,
    cell_pixels: Mutex<(u16, u16)>,
    #[cfg(test)]
    geometry_test_hook: Mutex<Option<RemoteGeometryTestHook>>,
    pub(super) content_generation: AtomicU64,
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

    /// Whether the inner application authored the cursor style (DECSCUSR)
    /// through the raw output stream since the last daemon replay.
    pub(super) fn cursor_style_authored(&self) -> bool {
        self.cursor_provenance.lock().unwrap().authored()
    }

    fn scan_cursor_provenance(&self, bytes: &[u8]) {
        self.cursor_provenance.lock().unwrap().scan(bytes);
    }

    #[cfg(test)]
    pub(super) fn test_scan_cursor_provenance(&self, bytes: &[u8]) {
        self.scan_cursor_provenance(bytes);
    }

    pub(super) fn sync_mouse_encoders(&self, terminal: &Terminal) {
        self.mouse_encoders.lock().unwrap().sync_from_terminal(terminal);
    }

    pub(super) fn encode_mouse(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self.mouse_encoders.try_lock() {
            Ok(mut encoders) => Some(encoders.encode(input, output)),
            Err(std::sync::TryLockError::Poisoned(error)) => {
                Some(error.into_inner().encode(input, output))
            }
            Err(std::sync::TryLockError::WouldBlock) => None,
        }
    }

    pub(super) fn encode_mouse_if_semantics(
        &self,
        expected: TerminalPointerSemanticSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> GuardedMouseEncode {
        let term = match self.term.try_lock() {
            Ok(term) => term,
            Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                return GuardedMouseEncode::Contended;
            }
        };
        if term.pointer_semantic_snapshot() != expected {
            return GuardedMouseEncode::SemanticsChanged;
        }
        let mut encoders = match self.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                return GuardedMouseEncode::Contended;
            }
        };
        encoders.sync_from_terminal(&term);
        GuardedMouseEncode::Encoded(encoders.encode(input, output))
    }

    pub(super) fn encode_mouse_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> GuardedMouseEncode {
        let term = match self.term.try_lock() {
            Ok(term) => term,
            Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                return GuardedMouseEncode::Contended;
            }
        };
        if term.pointer_semantic_snapshot() != expected.semantics {
            return GuardedMouseEncode::SemanticsChanged;
        }
        if self.content_generation.load(Ordering::Acquire) != expected.content_generation {
            return GuardedMouseEncode::ContentChanged;
        }
        let mut encoders = match self.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                return GuardedMouseEncode::Contended;
            }
        };
        encoders.sync_from_terminal(&term);
        GuardedMouseEncode::Encoded(encoders.encode(input, output))
    }

    pub(super) fn encode_mouse_release(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
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
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
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

    pub(super) fn encode_mouse_press_pair_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> GuardedMouseEncode {
        let term = match self.term.try_lock() {
            Ok(term) => term,
            Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                return GuardedMouseEncode::Contended;
            }
        };
        if term.pointer_semantic_snapshot() != expected.semantics {
            return GuardedMouseEncode::SemanticsChanged;
        }
        if self.content_generation.load(Ordering::Acquire) != expected.content_generation {
            return GuardedMouseEncode::ContentChanged;
        }
        let mut encoders = match self.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                return GuardedMouseEncode::Contended;
            }
        };
        encoders.sync_from_terminal(&term);
        GuardedMouseEncode::Encoded(encoders.encode_press_pair(
            press,
            release,
            press_output,
            release_output,
        ))
    }

    pub(super) fn reset_mouse_motion_dedupe(&self) {
        self.mouse_encoders.lock().unwrap().reset_motion_dedupe();
    }

    pub(super) fn try_pointer_semantics(&self) -> PointerSemanticProbe {
        match self.term.try_lock() {
            Ok(term) => PointerSemanticProbe::Ready(term.pointer_semantic_snapshot()),
            Err(std::sync::TryLockError::Poisoned(error)) => {
                PointerSemanticProbe::Ready(error.into_inner().pointer_semantic_snapshot())
            }
            Err(std::sync::TryLockError::WouldBlock) => PointerSemanticProbe::Contended,
        }
    }

    pub(super) fn try_pointer_snapshot(&self) -> PointerSnapshotProbe {
        match self.term.try_lock() {
            Ok(term) => PointerSnapshotProbe::Ready(TerminalPointerSnapshot {
                semantics: term.pointer_semantic_snapshot(),
                content_generation: self.content_generation.load(Ordering::Acquire),
            }),
            Err(std::sync::TryLockError::Poisoned(error)) => {
                PointerSnapshotProbe::Ready(TerminalPointerSnapshot {
                    semantics: error.into_inner().pointer_semantic_snapshot(),
                    content_generation: self.content_generation.load(Ordering::Acquire),
                })
            }
            Err(std::sync::TryLockError::WouldBlock) => PointerSnapshotProbe::Contended,
        }
    }

    /// Apply an ordered attach-stream resize marker to the mirror terminal.
    pub(super) fn apply_stream_resize(
        &self,
        cols: u16,
        rows: u16,
        replay: Option<&[u8]>,
        kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
    ) -> ghostty_vt::Result<()> {
        self.apply_stream_resize_with_colors(
            cols,
            rows,
            replay,
            kitty_image_aliases,
            None,
            None,
            &[],
        )
    }

    /// Apply one authoritative replay and its coupled Kitty alias and color
    /// state before the mirror can be observed at the new size.
    /// `pending_sequence` is the daemon parser's incomplete sequence, written
    /// last so the live stream completes it.
    #[allow(clippy::too_many_arguments)]
    fn apply_stream_resize_with_colors(
        &self,
        cols: u16,
        rows: u16,
        replay: Option<&[u8]>,
        kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
        kitty_state: Option<KittyReplayState>,
        colors: Option<&RemoteTerminalColors>,
        pending_sequence: &[u8],
    ) -> ghostty_vt::Result<()> {
        #[cfg(test)]
        self.run_geometry_test_hook(RemoteGeometryTestStep::StreamResizeStarted);
        let _geometry_lifecycle = self.geometry_lifecycle.lock().unwrap();
        let daemon_replay = replay.is_some();
        let (cols, rows) = (cols.max(1), rows.max(1));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        #[cfg(test)]
        self.run_geometry_test_hook(RemoteGeometryTestStep::StreamResizeCommitBoundary);
        let mut term = self.term.lock().unwrap();
        let owned_replay;
        let (replay, replay_aliases, replay_state, pending_sequence) = match replay {
            Some(replay) => (
                replay,
                kitty_image_aliases,
                kitty_state.unwrap_or_else(KittyReplayState::disabled),
                pending_sequence,
            ),
            None => {
                if !kitty_image_aliases.is_empty() || kitty_state.is_some() {
                    return Err(ghostty_vt::Error::NoValue);
                }
                owned_replay = term.vt_replay_bounded(REMOTE_CONTROL_MESSAGE_MAX_BYTES)?;
                (
                    owned_replay.bytes.as_slice(),
                    owned_replay.kitty_image_aliases.as_slice(),
                    owned_replay.kitty_state,
                    owned_replay.pending_sequence.as_slice(),
                )
            }
        };
        let mut fresh = Terminal::new(cols, rows, 10_000, Callbacks::default())?;
        fresh.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
        fresh.apply_vt_replay_parts(replay, replay_aliases, replay_state)?;
        if let Some(colors) = colors {
            apply_terminal_colors(&mut fresh, colors);
        }
        fresh.vt_write(pending_sequence);
        *term = fresh;
        if daemon_replay {
            // Daemon-built replays carry resolved state, not application
            // intent; cursor-style provenance restarts from "not authored".
            self.cursor_provenance.lock().unwrap().reset_for_replay();
        }
        self.sync_mouse_encoders(&term);
        self.content_generation.fetch_add(1, Ordering::AcqRel);
        Ok(())
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
        self.content_generation.fetch_add(1, Ordering::AcqRel);
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

    #[cfg(test)]
    pub fn browser_frame(&self) -> Option<Arc<BrowserFrame>> {
        let browser = self.browser.lock().unwrap();
        if matches!(browser.status, BrowserStatus::Failed(_)) {
            None
        } else {
            browser.frame.as_ref().map(|frame| frame.frame.clone())
        }
    }

    pub fn browser_frame_metadata(&self) -> Option<(u64, u32, u32, Option<u64>)> {
        let browser = self.browser.lock().unwrap();
        if matches!(browser.status, BrowserStatus::Failed(_)) {
            None
        } else {
            browser.frame.as_ref().map(|frame| {
                (
                    frame.frame.seq,
                    frame.frame.css_width,
                    frame.frame.css_height,
                    browser.pointer_frame_seq,
                )
            })
        }
    }

    pub fn browser_frame_update(&self) -> Option<BrowserFrameUpdate> {
        let browser = self.browser.lock().unwrap();
        if matches!(browser.status, BrowserStatus::Failed(_)) {
            return None;
        }
        browser.frame.as_ref().map(|frame| BrowserFrameUpdate {
            frame: (*frame.frame).clone(),
            status: browser.status.clone(),
            pointer_frame_floor_seq: browser.pointer_frame_floor_seq,
            pointer_frame_seq: browser.pointer_frame_seq,
        })
    }

    #[cfg(test)]
    pub fn browser_frame_seq(&self) -> Option<u64> {
        let browser = self.browser.lock().unwrap();
        if matches!(browser.status, BrowserStatus::Failed(_)) {
            None
        } else {
            browser.pointer_frame_seq
        }
    }

    pub fn browser_accepts_pointer_frame(&self, frame_seq: u64) -> bool {
        let browser = self.browser.lock().unwrap();
        matches!(browser.status, BrowserStatus::Live)
            && browser.presented_pointer_frame_seq == Some(frame_seq)
            && pointer_frame_is_in_range(&browser, frame_seq)
    }

    pub fn browser_pointer_frame_is_in_current_route(&self, frame_seq: u64) -> bool {
        let browser = self.browser.lock().unwrap();
        matches!(browser.status, BrowserStatus::Live)
            && pointer_frame_is_in_range(&browser, frame_seq)
    }

    pub fn acknowledge_browser_pointer_frame(&self, frame_seq: u64) -> bool {
        let mut browser = self.browser.lock().unwrap();
        if !matches!(browser.status, BrowserStatus::Live)
            || !pointer_frame_is_in_range(&browser, frame_seq)
            || browser.presented_pointer_frame_seq == Some(frame_seq)
            || browser.presented_pointer_frame_seq.is_some_and(|presented| presented > frame_seq)
        {
            return false;
        }
        browser.presented_pointer_frame_seq = Some(frame_seq);
        true
    }

    pub fn has_browser_frame(&self) -> bool {
        let browser = self.browser.lock().unwrap();
        !matches!(browser.status, BrowserStatus::Failed(_)) && browser.frame.is_some()
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
        browser.status = parse_browser_status(value).unwrap_or(BrowserStatus::Starting);
        browser.frames_stalled =
            value.get("frames_stalled").and_then(|v| v.as_bool()).unwrap_or(false);
        if previous_status != BrowserStatus::Live && browser.status == BrowserStatus::Live {
            browser.live_since = Some(Instant::now());
        }
        let mut received_frame = false;
        if let Some(frame) = value.get("frame").and_then(parse_browser_frame) {
            browser.last_frame_at = Some(Instant::now());
            browser.frame = Some(frame);
            received_frame = true;
        }
        let advertised_pointer_range =
            matches!(browser.status, BrowserStatus::Live).then(|| parse_pointer_frame_range(value));
        let advertised_pointer_range = advertised_pointer_range.flatten();
        let current_pointer_range = browser.pointer_frame_floor_seq.zip(browser.pointer_frame_seq);
        // State-only messages may retain existing authority or revoke it.
        // New authority must arrive atomically with its pixels.
        let accepted_pointer_range =
            if received_frame || advertised_pointer_range == current_pointer_range {
                advertised_pointer_range
            } else {
                None
            };
        (browser.pointer_frame_floor_seq, browser.pointer_frame_seq) = accepted_pointer_range
            .map_or((None, None), |(floor, latest)| (Some(floor), Some(latest)));
        retain_presented_pointer_frame(&mut browser);
    }

    fn update_browser_frame(&self, value: &Value) {
        if let Some(frame) = parse_browser_frame(value) {
            let mut browser = self.browser.lock().unwrap();
            let previous_status = browser.status.clone();
            let status = parse_browser_status(value);
            if let Some(status) = status.clone() {
                browser.status = status;
            }
            browser.frames_stalled = false;
            if previous_status != BrowserStatus::Live && browser.status == BrowserStatus::Live {
                browser.live_since = Some(Instant::now());
            }
            browser.last_frame_at = Some(Instant::now());
            let pointer_range = matches!(status, Some(BrowserStatus::Live))
                .then(|| parse_pointer_frame_range(value))
                .flatten();
            (browser.pointer_frame_floor_seq, browser.pointer_frame_seq) =
                pointer_range.map_or((None, None), |(floor, latest)| (Some(floor), Some(latest)));
            retain_presented_pointer_frame(&mut browser);
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

fn pointer_frame_is_in_range(browser: &RemoteBrowserState, frame_seq: u64) -> bool {
    browser
        .pointer_frame_floor_seq
        .zip(browser.pointer_frame_seq)
        .is_some_and(|(floor, latest)| (floor..=latest).contains(&frame_seq))
}

fn retain_presented_pointer_frame(browser: &mut RemoteBrowserState) {
    if browser
        .presented_pointer_frame_seq
        .is_some_and(|frame_seq| !pointer_frame_is_in_range(browser, frame_seq))
    {
        browser.presented_pointer_frame_seq = None;
    }
}

fn parse_pointer_frame_range(value: &Value) -> Option<(u64, u64)> {
    let latest = value.get("pointer_frame_seq").and_then(Value::as_u64)?;
    let floor = value.get("pointer_frame_floor_seq").and_then(Value::as_u64).unwrap_or(latest);
    (floor <= latest).then_some((floor, latest))
}

#[derive(Default)]
struct SubscriptionRecoveryState {
    generation: u64,
    in_flight: bool,
}

#[derive(Clone, Copy)]
enum RequestDeadline {
    Standard,
    Attach,
    Fixed(Duration),
}

struct AttachResponseDeadline {
    idle_timeout: Duration,
    idle_deadline: Instant,
    maximum_deadline: Instant,
    observed_request_progress: u64,
    observed_attach_progress: u64,
}

impl AttachResponseDeadline {
    fn new(
        started: Instant,
        request_progress: u64,
        attach_progress: u64,
        idle_timeout: Duration,
        maximum_timeout: Duration,
    ) -> Self {
        Self {
            idle_timeout,
            idle_deadline: started + idle_timeout,
            maximum_deadline: started + maximum_timeout,
            observed_request_progress: request_progress,
            observed_attach_progress: attach_progress,
        }
    }

    fn next_wait(
        &mut self,
        now: Instant,
        request_progress: u64,
        attach_progress: u64,
    ) -> Option<Duration> {
        if now >= self.maximum_deadline {
            return None;
        }
        let progressed = if request_progress != self.observed_request_progress {
            self.observed_request_progress = request_progress;
            true
        } else if self.observed_request_progress == 0
            && attach_progress != self.observed_attach_progress
        {
            self.observed_attach_progress = attach_progress;
            true
        } else {
            false
        };
        if progressed {
            self.idle_deadline = now + self.idle_timeout;
        }
        let next_deadline = self.idle_deadline.min(self.maximum_deadline);
        (now < next_deadline).then(|| next_deadline.saturating_duration_since(now))
    }
}

struct PendingRemoteRequest {
    response: Sender<Value>,
    progress: Arc<AtomicU64>,
    attach_surface: Option<SurfaceId>,
}

#[derive(Default)]
struct PendingRemoteRequests {
    requests: HashMap<u64, PendingRemoteRequest>,
    attach_surface_requests: HashMap<SurfaceId, HashSet<u64>>,
}

impl PendingRemoteRequests {
    fn insert(&mut self, id: u64, request: PendingRemoteRequest) {
        if let Some(surface) = request.attach_surface {
            self.attach_surface_requests.entry(surface).or_default().insert(id);
        }
        self.requests.insert(id, request);
    }

    fn get(&self, id: &u64) -> Option<&PendingRemoteRequest> {
        self.requests.get(id)
    }

    fn remove(&mut self, id: &u64) -> Option<PendingRemoteRequest> {
        let request = self.requests.remove(id)?;
        if let Some(surface) = request.attach_surface {
            let mut remove_surface = false;
            if let Some(ids) = self.attach_surface_requests.get_mut(&surface) {
                ids.remove(id);
                remove_surface = ids.is_empty();
            }
            if remove_surface {
                self.attach_surface_requests.remove(&surface);
            }
        }
        Some(request)
    }

    fn progress_for_attach_surface(&self, surface: SurfaceId) -> bool {
        let Some(ids) = self.attach_surface_requests.get(&surface) else { return false };
        let mut progressed = false;
        for id in ids {
            if let Some(request) = self.requests.get(id) {
                request.progress.fetch_add(1, Ordering::Release);
                progressed = true;
            }
        }
        progressed
    }

    #[cfg(test)]
    fn is_empty(&self) -> bool {
        self.requests.is_empty()
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.requests.len()
    }

    #[cfg(test)]
    fn values(&self) -> impl Iterator<Item = &PendingRemoteRequest> {
        self.requests.values()
    }
}

impl IntoIterator for PendingRemoteRequests {
    type Item = (u64, PendingRemoteRequest);
    type IntoIter = std::collections::hash_map::IntoIter<u64, PendingRemoteRequest>;

    fn into_iter(self) -> Self::IntoIter {
        self.requests.into_iter()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RemoteProgressTarget {
    Request(u64),
    AttachSurface(SurfaceId),
}

struct InteractiveWrite {
    message: String,
    enqueued_at: Instant,
    sequence: u64,
    measure_latency: bool,
}

impl Drop for InteractiveWrite {
    fn drop(&mut self) {
        zeroize_string(&mut self.message);
    }
}

#[derive(Clone)]
struct InteractiveWriteFailure {
    kind: io::ErrorKind,
    message: String,
}

impl InteractiveWriteFailure {
    fn from_error(error: &io::Error) -> Self {
        Self { kind: error.kind(), message: error.to_string() }
    }

    fn to_error(&self) -> io::Error {
        io::Error::new(self.kind, self.message.clone())
    }
}

#[derive(Default)]
struct InteractiveWriteQueueState {
    writes: VecDeque<InteractiveWrite>,
    queued_bytes: usize,
    last_enqueued_sequence: u64,
    last_written_sequence: u64,
    closed: bool,
    writer_closed: bool,
    failure: Option<InteractiveWriteFailure>,
}

struct InteractiveWriteMetrics {
    latency_buckets: [AtomicU64; INTERACTIVE_LATENCY_BUCKET_UPPER_US.len()],
    write_failures: AtomicU64,
    backpressure_rejections: AtomicU64,
}

impl Default for InteractiveWriteMetrics {
    fn default() -> Self {
        Self {
            latency_buckets: std::array::from_fn(|_| AtomicU64::new(0)),
            write_failures: AtomicU64::new(0),
            backpressure_rejections: AtomicU64::new(0),
        }
    }
}

impl InteractiveWriteMetrics {
    fn record_latency(&self, latency: Duration) {
        let micros = u64::try_from(latency.as_micros()).unwrap_or(u64::MAX);
        let bucket = INTERACTIVE_LATENCY_BUCKET_UPPER_US
            .partition_point(|upper_bound| *upper_bound < micros)
            .min(self.latency_buckets.len() - 1);
        self.latency_buckets[bucket].fetch_add(1, Ordering::Relaxed);
    }

    fn snapshot(&self) -> InteractiveWriteMetricsSnapshot {
        let histogram = self
            .latency_buckets
            .iter()
            .zip(INTERACTIVE_LATENCY_BUCKET_UPPER_US)
            .map(|(samples, upper_bound_micros)| InteractiveLatencyBucket {
                upper_bound: Duration::from_micros(upper_bound_micros),
                samples: samples.load(Ordering::Relaxed),
            })
            .collect::<Vec<_>>();
        let samples = histogram.iter().map(|bucket| bucket.samples).sum();
        InteractiveWriteMetricsSnapshot {
            p50: latency_percentile(&histogram, samples, 50),
            p95: latency_percentile(&histogram, samples, 95),
            p99: latency_percentile(&histogram, samples, 99),
            histogram,
            samples,
            write_failures: self.write_failures.load(Ordering::Relaxed),
            backpressure_rejections: self.backpressure_rejections.load(Ordering::Relaxed),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InteractiveLatencyBucket {
    pub(crate) upper_bound: Duration,
    pub(crate) samples: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InteractiveWriteMetricsSnapshot {
    pub(crate) histogram: Vec<InteractiveLatencyBucket>,
    pub(crate) samples: u64,
    pub(crate) write_failures: u64,
    pub(crate) backpressure_rejections: u64,
    pub(crate) p50: Option<Duration>,
    pub(crate) p95: Option<Duration>,
    pub(crate) p99: Option<Duration>,
}

fn latency_percentile(
    histogram: &[InteractiveLatencyBucket],
    samples: u64,
    percentile: u64,
) -> Option<Duration> {
    if samples == 0 {
        return None;
    }
    let target = samples.saturating_mul(percentile).div_ceil(100);
    let mut cumulative = 0_u64;
    histogram.iter().find_map(|bucket| {
        cumulative = cumulative.saturating_add(bucket.samples);
        (cumulative >= target).then_some(bucket.upper_bound)
    })
}

struct InteractiveWriterShared {
    state: Mutex<InteractiveWriteQueueState>,
    changed: Condvar,
    metrics: InteractiveWriteMetrics,
    #[cfg(test)]
    wait_until_written_gate: Mutex<Option<InteractiveWaitUntilWrittenGate>>,
}

#[cfg(test)]
struct InteractiveWaitUntilWrittenGate {
    entered: Sender<u64>,
    resume: Receiver<()>,
}

struct InteractiveWriter {
    shared: Arc<InteractiveWriterShared>,
    abort: Arc<dyn RemoteTransportAbort>,
}

impl InteractiveWriter {
    // Control requests use this actor too, then wait for their sequence. This
    // keeps a mutation from overtaking input already accepted from the PTY lane.
    fn spawn(
        writer: Box<dyn RemoteMessageWriter>,
        abort: Arc<dyn RemoteTransportAbort>,
    ) -> io::Result<Self> {
        let shared = Arc::new(InteractiveWriterShared {
            state: Mutex::new(InteractiveWriteQueueState::default()),
            changed: Condvar::new(),
            metrics: InteractiveWriteMetrics::default(),
            #[cfg(test)]
            wait_until_written_gate: Mutex::new(None),
        });
        let worker_shared = shared.clone();
        std::thread::Builder::new()
            .name("remote-input-writer".into())
            .spawn(move || interactive_writer_worker(worker_shared, writer))?;
        Ok(Self { shared, abort })
    }

    fn enqueue(&self, message: String, measure_latency: bool) -> io::Result<u64> {
        let mut write =
            InteractiveWrite { message, enqueued_at: Instant::now(), sequence: 0, measure_latency };
        let message_bytes = write.message.len();
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| io::Error::other("interactive writer queue is poisoned"))?;
        if let Some(failure) = &state.failure {
            return Err(failure.to_error());
        }
        if state.closed {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "interactive writer is closed"));
        }
        if state.writes.len() >= INTERACTIVE_WRITE_QUEUE_CAPACITY
            || message_bytes > INTERACTIVE_WRITE_QUEUE_BYTES.saturating_sub(state.queued_bytes)
        {
            if measure_latency {
                self.shared.metrics.backpressure_rejections.fetch_add(1, Ordering::Relaxed);
            }
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "interactive writer queue is full",
            ));
        }
        let sequence = state
            .last_enqueued_sequence
            .checked_add(1)
            .ok_or_else(|| io::Error::other("interactive writer sequence space is exhausted"))?;
        state.last_enqueued_sequence = sequence;
        state.queued_bytes += message_bytes;
        write.sequence = sequence;
        state.writes.push_back(write);
        drop(state);
        self.shared.changed.notify_one();
        Ok(sequence)
    }

    fn last_enqueued_sequence(&self) -> io::Result<Option<u64>> {
        let state = self
            .shared
            .state
            .lock()
            .map_err(|_| io::Error::other("interactive writer queue is poisoned"))?;
        Ok((state.last_enqueued_sequence != 0).then_some(state.last_enqueued_sequence))
    }

    fn wait_until_written(&self, sequence: u64, timeout: Duration) -> io::Result<()> {
        #[cfg(test)]
        self.await_wait_until_written_gate(sequence);
        let deadline = Instant::now() + timeout;
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| io::Error::other("interactive writer queue is poisoned"))?;
        loop {
            if state.last_written_sequence >= sequence {
                return Ok(());
            }
            if let Some(failure) = &state.failure {
                return Err(failure.to_error());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "ordered remote write did not complete before its deadline",
                ));
            }
            let (next, timeout) = self
                .shared
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(|poison| poison.into_inner());
            state = next;
            if timeout.timed_out()
                && state.last_written_sequence < sequence
                && state.failure.is_none()
            {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "ordered remote write did not complete before its deadline",
                ));
            }
        }
    }

    #[cfg(test)]
    fn gate_next_wait_until_written(&self) -> (Receiver<u64>, Sender<()>) {
        let (entered_tx, entered_rx) = channel();
        let (resume_tx, resume_rx) = channel();
        let previous =
            self.shared.wait_until_written_gate.lock().unwrap().replace(
                InteractiveWaitUntilWrittenGate { entered: entered_tx, resume: resume_rx },
            );
        assert!(previous.is_none(), "interactive write wait gate was already installed");
        (entered_rx, resume_tx)
    }

    #[cfg(test)]
    fn await_wait_until_written_gate(&self, sequence: u64) {
        let gate = self.shared.wait_until_written_gate.lock().unwrap().take();
        if let Some(gate) = gate {
            gate.entered.send(sequence).unwrap();
            gate.resume.recv().unwrap();
        }
    }

    fn metrics(&self) -> InteractiveWriteMetricsSnapshot {
        self.shared.metrics.snapshot()
    }

    fn request_close(&self) {
        let mut state = self.shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
        state.closed = true;
        drop(state);
        self.shared.changed.notify_one();
    }

    fn abort(&self, error: &io::Error) {
        {
            let mut state = self.shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
            state.closed = true;
            state.failure.get_or_insert_with(|| InteractiveWriteFailure::from_error(error));
            state.writes.clear();
            state.queued_bytes = 0;
        }
        self.shared.changed.notify_all();
        let _ = self.abort.abort();
    }

    fn close(&self) {
        self.request_close();
        let deadline = Instant::now() + remote_write_timeout();
        let mut state = self.shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
        while !state.writer_closed {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            let (next, timeout) = self
                .shared
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(|poison| poison.into_inner());
            state = next;
            if timeout.timed_out() {
                break;
            }
        }
        let writer_closed = state.writer_closed;
        drop(state);
        if !writer_closed {
            self.abort(&io::Error::new(
                io::ErrorKind::TimedOut,
                "remote writer did not close before its deadline",
            ));
        }
    }
}

impl Drop for InteractiveWriter {
    fn drop(&mut self) {
        self.request_close();
        let writer_closed =
            self.shared.state.lock().unwrap_or_else(|poison| poison.into_inner()).writer_closed;
        if !writer_closed {
            self.abort(&io::Error::new(
                io::ErrorKind::BrokenPipe,
                "remote writer owner was dropped",
            ));
        }
    }
}

fn interactive_writer_worker(
    shared: Arc<InteractiveWriterShared>,
    mut writer: Box<dyn RemoteMessageWriter>,
) {
    loop {
        let write = {
            let mut state = shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
            while state.writes.is_empty() && !state.closed && state.failure.is_none() {
                state = shared.changed.wait(state).unwrap_or_else(|poison| poison.into_inner());
            }
            let Some(write) = state.writes.pop_front() else {
                drop(state);
                let _ = writer.close();
                let mut state = shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
                state.writer_closed = true;
                drop(state);
                shared.changed.notify_all();
                return;
            };
            state.queued_bytes = state.queued_bytes.saturating_sub(write.message.len());
            write
        };

        let result = writer.send(&write.message);
        match result {
            Ok(()) => {
                if write.measure_latency {
                    shared.metrics.record_latency(write.enqueued_at.elapsed());
                }
                let mut state = shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
                state.last_written_sequence = write.sequence;
                drop(state);
                shared.changed.notify_all();
            }
            Err(error) => {
                if write.measure_latency {
                    shared.metrics.write_failures.fetch_add(1, Ordering::Relaxed);
                }
                let _ = writer.close();
                let mut state = shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
                state.failure.get_or_insert_with(|| InteractiveWriteFailure::from_error(&error));
                state.writes.clear();
                state.queued_bytes = 0;
                state.writer_closed = true;
                drop(state);
                shared.changed.notify_all();
                return;
            }
        }
    }
}

struct RemoteFrameLogEntry {
    surface: SurfaceId,
    line: String,
    charged_bytes: usize,
}

#[derive(Default)]
struct RemoteFrameLogs {
    entries: VecDeque<RemoteFrameLogEntry>,
    bytes: usize,
}

impl RemoteFrameLogs {
    fn push(&mut self, surface: SurfaceId, line: String) {
        self.push_with_limits(
            surface,
            line,
            REMOTE_FRAME_LOG_MAX_ENTRIES,
            REMOTE_FRAME_LOG_MAX_BYTES,
        );
    }

    fn push_with_limits(
        &mut self,
        surface: SurfaceId,
        line: String,
        maximum_entries: usize,
        maximum_bytes: usize,
    ) {
        let charged_bytes = line.len().saturating_add(1);
        if maximum_entries == 0 || charged_bytes > maximum_bytes {
            return;
        }
        while !self.entries.is_empty()
            && (self.entries.len() >= maximum_entries
                || self.bytes.saturating_add(charged_bytes) > maximum_bytes)
        {
            if let Some(evicted) = self.entries.pop_front() {
                self.bytes = self.bytes.saturating_sub(evicted.charged_bytes);
            }
        }
        self.bytes = self.bytes.saturating_add(charged_bytes);
        self.entries.push_back(RemoteFrameLogEntry { surface, line, charged_bytes });
    }
}

#[derive(Default)]
struct ExitedSurfaceState {
    ids: HashSet<SurfaceId>,
    handles: HashMap<SurfaceId, Weak<RemoteSurface>>,
}

#[path = "remote_disconnect.rs"]
mod disconnect;
#[cfg(test)]
#[path = "remote_shutdown_tests.rs"]
mod shutdown_tests;

#[derive(Default)]
enum DisconnectState {
    #[default]
    Active,
    LocalShutdown,
    ExpectedRemoteShutdown,
    Remote(String),
}

pub struct RemoteSession {
    interactive_writer: InteractiveWriter,
    /// The first terminal state wins. Local shutdown is kept separate from a
    /// reader failure so closing our own transport does not report a fake
    /// remote diagnostic.
    disconnect_state: disconnect::DisconnectCell,
    pending: Mutex<PendingRemoteRequests>,
    next_id: AtomicU64,
    attach_progress: AtomicU64,
    shutdown: AtomicBool,
    surfaces: Mutex<HashMap<SurfaceId, Arc<RemoteSurface>>>,
    exited_surfaces: Mutex<ExitedSurfaceState>,
    surface_leases: Mutex<HashMap<SurfaceId, String>>,
    retired_surfaces: Mutex<HashSet<SurfaceId>>,
    #[cfg(test)]
    retire_surface_test_marker: Mutex<Option<Sender<SurfaceId>>>,
    tree: Mutex<RemoteTreeCache>,
    browser_sources: Mutex<HashMap<SurfaceId, BrowserSource>>,
    tree_refresh: Mutex<()>,
    tree_stale: AtomicBool,
    subscription_started: AtomicBool,
    event_surface_filter: AtomicU64,
    subscription_recovery: Mutex<SubscriptionRecoveryState>,
    subscribers: MuxEventBroadcaster,
    primed_subscription: Mutex<Option<MuxEventReceiver>>,
    frame_dump_dir: Option<PathBuf>,
    frame_logs: Mutex<RemoteFrameLogs>,
    surface_overflow_recovery: Mutex<HashMap<SurfaceId, SurfaceOverflowRecovery>>,
    surface_overflow_reconnect_required: AtomicBool,
    cell_pixel_lifecycle: Mutex<()>,
    cell_pixels: Mutex<(u16, u16)>,
    capabilities: Mutex<HashSet<String>>,
    /// Latest `size-state` per terminal (shared-sizing-v1).
    size_states: Mutex<HashMap<SurfaceId, super::SurfaceSizeState>>,
    provider_workspace_authority: Option<BearerToken>,
    provider_workspaces_guarded: AtomicBool,
}

pub(super) enum RemoteSurfaceAttach {
    Attached(Arc<RemoteSurface>),
    Retired,
    Deferred,
}

/// Receive complete JSON protocol messages from one transport.
///
/// Message framing belongs to the transport adapter: Unix sockets and SSH
/// relays use JSON lines, while WebSocket and future Iroh adapters can use
/// their native message boundaries.
pub trait RemoteMessageReader: Send {
    fn receive(&mut self) -> io::Result<Option<String>>;

    fn receive_with_progress(
        &mut self,
        on_progress: &mut dyn FnMut(&[u8]),
    ) -> io::Result<Option<String>> {
        let message = self.receive()?;
        if let Some(message) = message.as_deref() {
            on_progress(message.as_bytes());
        }
        Ok(message)
    }
}

fn decimal_after_prefix(bytes: &[u8], prefix: &[u8]) -> Option<u64> {
    let tail = bytes.strip_prefix(prefix)?;
    let digits = tail.iter().take_while(|byte| byte.is_ascii_digit()).count();
    if digits == 0 || !matches!(tail.get(digits), Some(b',') | Some(b'}')) {
        return None;
    }
    std::str::from_utf8(&tail[..digits]).ok()?.parse().ok()
}

fn remote_progress_target(partial: &[u8]) -> Option<RemoteProgressTarget> {
    decimal_after_prefix(partial, br#"{"id":"#).map(RemoteProgressTarget::Request).or_else(|| {
        [
            br#"{"event":"vt-state","surface":"#.as_slice(),
            br#"{"event":"browser-state","surface":"#.as_slice(),
        ]
        .into_iter()
        .find_map(|prefix| decimal_after_prefix(partial, prefix))
        .map(RemoteProgressTarget::AttachSurface)
    })
}

/// Send complete JSON protocol messages over one transport.
pub trait RemoteMessageWriter: Send {
    fn send(&mut self, message: &str) -> io::Result<()>;
    fn close(&mut self) -> io::Result<()>;
}

/// Independently owned cancellation for a transport whose writer may be
/// blocked. Implementations must be safe to call from a different thread than
/// `RemoteMessageWriter::send`.
pub trait RemoteTransportAbort: Send + Sync {
    fn abort(&self) -> io::Result<()>;
}

/// The independently-owned read and write halves of a remote connection.
/// Split halves support process stdio and async transport pumps without
/// requiring the underlying stream to be cloneable.
pub struct RemoteTransport {
    reader: Box<dyn RemoteMessageReader>,
    writer: Box<dyn RemoteMessageWriter>,
    abort: Arc<dyn RemoteTransportAbort>,
}

impl RemoteTransport {
    pub fn new(
        reader: Box<dyn RemoteMessageReader>,
        writer: Box<dyn RemoteMessageWriter>,
        abort: Arc<dyn RemoteTransportAbort>,
    ) -> Self {
        Self { reader, writer, abort }
    }

    pub fn json_lines(stream: Box<dyn transport::Stream>) -> io::Result<Self> {
        stream.set_write_timeout(Some(remote_write_timeout()))?;
        let read_half = stream.try_clone_box()?;
        let abort_stream = stream.try_clone_box()?;
        Ok(Self {
            reader: Box::new(JsonLineReader { inner: BufReader::new(read_half) }),
            writer: Box::new(JsonLineWriter { inner: stream }),
            abort: Arc::new(StreamTransportAbort { inner: abort_stream }),
        })
    }
}

struct StreamTransportAbort {
    inner: Box<dyn transport::Stream>,
}

impl RemoteTransportAbort for StreamTransportAbort {
    fn abort(&self) -> io::Result<()> {
        self.inner.shutdown(Shutdown::Both)
    }
}

struct JsonLineReader {
    inner: BufReader<Box<dyn transport::Stream>>,
}

pub(crate) fn read_json_line_with_progress<R: BufRead>(
    reader: &mut R,
    on_progress: &mut dyn FnMut(&[u8]),
) -> io::Result<Option<String>> {
    read_json_line_with_progress_bounded(reader, on_progress, REMOTE_SESSION_MESSAGE_MAX_BYTES)
}

fn read_json_line_with_progress_bounded<R: BufRead>(
    reader: &mut R,
    on_progress: &mut dyn FnMut(&[u8]),
    max_message_bytes: usize,
) -> io::Result<Option<String>> {
    let mut bytes = Zeroizing::new(Vec::new());
    let mut complete_line = false;
    loop {
        let (consumed, complete) = {
            let available = reader.fill_buf()?;
            if available.is_empty() {
                break;
            }
            let complete_at = available.iter().position(|byte| *byte == b'\n');
            let payload_bytes = complete_at.unwrap_or(available.len());
            if payload_bytes > max_message_bytes.saturating_sub(bytes.len()) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("remote session message exceeds the {max_message_bytes}-byte limit"),
                ));
            }
            let consumed = complete_at.map_or(available.len(), |index| index + 1);
            bytes.extend_from_slice(&available[..payload_bytes]);
            (consumed, complete_at.is_some())
        };
        reader.consume(consumed);
        on_progress(bytes.as_slice());
        if complete {
            complete_line = true;
            break;
        }
    }

    if bytes.is_empty() && !complete_line {
        return Ok(None);
    }
    if complete_line && bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    decode_json_line(bytes).map(Some)
}

fn remote_reader_end_reason(result: &io::Result<Option<String>>) -> Option<String> {
    match result {
        Ok(Some(_)) => None,
        Ok(None) => Some("the daemon closed the connection".to_string()),
        Err(error) => Some(error.to_string()),
    }
}

fn remote_reader_message_too_large(message: &mut str) -> String {
    let reason = format!(
        "remote session message exceeds the \
         {REMOTE_SESSION_MESSAGE_MAX_BYTES}-byte limit"
    );
    zeroize_string(message);
    reason
}

impl RemoteMessageReader for JsonLineReader {
    fn receive(&mut self) -> io::Result<Option<String>> {
        self.receive_with_progress(&mut |_| {})
    }

    fn receive_with_progress(
        &mut self,
        on_progress: &mut dyn FnMut(&[u8]),
    ) -> io::Result<Option<String>> {
        read_json_line_with_progress(&mut self.inner, on_progress)
    }
}

#[cfg(test)]
pub(crate) fn read_bounded_json_line(
    reader: &mut impl BufRead,
    limit: usize,
) -> io::Result<Option<String>> {
    let mut frame = Zeroizing::new(Vec::new());
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return if frame.is_empty() { Ok(None) } else { decode_json_line(frame).map(Some) };
        }
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            if frame.len().saturating_add(newline) > limit {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("remote JSON line exceeds the {limit}-byte limit"),
                ));
            }
            frame.extend_from_slice(&available[..newline]);
            reader.consume(newline + 1);
            if frame.last() == Some(&b'\r') {
                frame.pop();
            }
            return decode_json_line(frame).map(Some);
        }
        if frame.len().saturating_add(available.len()) > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("remote JSON line exceeds the {limit}-byte limit"),
            ));
        }
        let consumed = available.len();
        frame.extend_from_slice(available);
        reader.consume(consumed);
    }
}

fn decode_json_line(mut frame: Zeroizing<Vec<u8>>) -> io::Result<String> {
    if std::str::from_utf8(&frame).is_err() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "remote JSON line is not valid UTF-8",
        ));
    }
    let bytes = std::mem::take(&mut *frame);
    // SAFETY: the complete frame was validated as UTF-8 immediately above.
    Ok(unsafe { String::from_utf8_unchecked(bytes) })
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

    pub(super) fn attachment_lease(&self, id: SurfaceId) -> Option<String> {
        self.surface_leases.lock().unwrap().get(&id).cloned()
    }

    pub fn connect(path: &Path) -> anyhow::Result<Arc<Self>> {
        Self::connect_path(path, false, true)
    }

    /// Connect to a session socket. A path derived from the session name must
    /// be in this user's private runtime directory and served by this user.
    pub fn connect_session(path: &Path, is_derived: bool) -> anyhow::Result<Arc<Self>> {
        Self::connect_path(path, is_derived, true)
    }

    pub fn connect_session_for_terminal_attach(
        path: &Path,
        is_derived: bool,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_path(path, is_derived, false)
    }

    fn connect_path(path: &Path, is_derived: bool, subscribe: bool) -> anyhow::Result<Arc<Self>> {
        let stream =
            cmux_tui_core::server::connect_session_socket(path, is_derived).map_err(|e| {
                anyhow::anyhow!("cannot connect to session socket {}: {e}", path.display())
            })?;
        if subscribe {
            Self::connect_stream(stream)
        } else {
            Self::connect_stream_with_subscription(stream, false)
        }
    }

    /// Connect over an already-established full-duplex byte stream.
    ///
    /// The cmux protocol is transport-independent JSONL. Keeping stream
    /// establishment outside `RemoteSession` lets clients use a local socket,
    /// an SSH relay, or another authenticated tunnel without teaching the
    /// session and rendering layers about those transports.
    pub fn connect_stream(stream: Box<dyn transport::Stream>) -> anyhow::Result<Arc<Self>> {
        Self::connect_stream_with_subscription(stream, true)
    }

    fn connect_stream_with_subscription(
        stream: Box<dyn transport::Stream>,
        subscribe: bool,
    ) -> anyhow::Result<Arc<Self>> {
        let transport = RemoteTransport::json_lines(stream).map_err(|error| {
            anyhow::anyhow!("cannot configure JSON-lines session transport: {error}")
        })?;
        Self::connect_transport_with_initial_subscription(transport, subscribe)
    }

    pub fn connect_transport(transport: RemoteTransport) -> anyhow::Result<Arc<Self>> {
        Self::connect_transport_with_initial_subscription(transport, true)
    }

    fn connect_transport_with_initial_subscription(
        transport: RemoteTransport,
        subscribe: bool,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_transport_with_provider_authority(transport, None, subscribe)
    }

    pub fn connect_provider_transport(
        transport: RemoteTransport,
        authority: BearerToken,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_transport_with_provider_authority(transport, Some(authority), true)
    }

    fn connect_transport_with_provider_authority(
        transport: RemoteTransport,
        provider_workspace_authority: Option<BearerToken>,
        subscribe: bool,
    ) -> anyhow::Result<Arc<Self>> {
        let RemoteTransport { mut reader, writer, abort } = transport;
        let interactive_writer = InteractiveWriter::spawn(writer, abort)
            .map_err(|error| anyhow::anyhow!("cannot start remote interactive writer: {error}"))?;
        let session = Arc::new(RemoteSession {
            interactive_writer,
            disconnect_state: disconnect::DisconnectCell::default(),
            pending: Mutex::new(PendingRemoteRequests::default()),
            next_id: AtomicU64::new(1),
            attach_progress: AtomicU64::new(0),
            shutdown: AtomicBool::new(false),
            surfaces: Mutex::new(HashMap::new()),
            exited_surfaces: Mutex::new(ExitedSurfaceState::default()),
            surface_leases: Mutex::new(HashMap::new()),
            retired_surfaces: Mutex::new(HashSet::new()),
            #[cfg(test)]
            retire_surface_test_marker: Mutex::new(None),
            tree: Mutex::new(RemoteTreeCache::default()),
            browser_sources: Mutex::new(HashMap::new()),
            tree_refresh: Mutex::new(()),
            tree_stale: AtomicBool::new(true),
            subscription_started: AtomicBool::new(false),
            event_surface_filter: AtomicU64::new(0),
            subscription_recovery: Mutex::new(SubscriptionRecoveryState::default()),
            subscribers: MuxEventBroadcaster::default(),
            primed_subscription: Mutex::new(None),
            frame_dump_dir: std::env::var_os("CMUX_MUX_DEBUG_MIRROR_DUMP").map(PathBuf::from),
            frame_logs: Mutex::new(RemoteFrameLogs::default()),
            surface_overflow_recovery: Mutex::new(HashMap::new()),
            surface_overflow_reconnect_required: AtomicBool::new(false),
            cell_pixel_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            capabilities: Mutex::new(HashSet::new()),
            size_states: Mutex::new(HashMap::new()),
            provider_workspace_authority,
            provider_workspaces_guarded: AtomicBool::new(false),
        });

        let reader_session = Arc::downgrade(&session);
        std::thread::Builder::new().name("remote-reader".into()).spawn(move || {
            let mut report_progress = |partial: &[u8]| {
                if let Some(session) = reader_session.upgrade() {
                    session.report_read_progress(partial);
                }
            };
            let reason = loop {
                let received = reader.receive_with_progress(&mut report_progress);
                if let Some(reason) = remote_reader_end_reason(&received) {
                    break Some(reason);
                }
                let Ok(Some(mut message)) = received else { unreachable!("end reason handled") };
                if message.len() > REMOTE_SESSION_MESSAGE_MAX_BYTES {
                    break Some(remote_reader_message_too_large(&mut message));
                }
                let value = match serde_json::from_str::<Value>(&message) {
                    Ok(value) => value,
                    Err(error) => {
                        let reason = format!("remote JSON decode failed: {error}");
                        zeroize_string(&mut message);
                        break Some(reason);
                    }
                };
                zeroize_string(&mut message);
                let Some(session) = reader_session.upgrade() else { break None };
                session.handle_line(value);
            };
            // Connection lost: retain the reason before telling the app to quit.
            if let Some(session) = reader_session.upgrade() {
                session.disconnect_transport_with_reason(reason);
                session.emit(MuxEvent::Empty);
            }
        })?;

        if let Err(error) = session.initialize(subscribe) {
            session.disconnect_transport();
            return Err(error);
        }
        Ok(session)
    }

    fn initialize(&self, subscribe: bool) -> anyhow::Result<()> {
        // Identify the endpoint and register this connection before any optional subscription.
        let ident = self.request(json!({"cmd": "identify"}))?;
        validate_remote_identity(&ident)?;
        *self.capabilities.lock().unwrap() = identity_capabilities(&ident);
        let mut client_info = json!({"cmd": "set-client-info", "kind": "tui"});
        if let Some(hostname) = local_hostname() {
            client_info["name"] = json!(hostname);
        }
        let mut negotiated = Vec::new();
        if self.supports_capability(GUARDED_BROWSER_POINTER_CAPABILITY) {
            negotiated.push(GUARDED_BROWSER_POINTER_CAPABILITY);
        }
        if self.supports_capability(VIEW_ATTACHMENT_LEASE_CAPABILITY) {
            negotiated.push(VIEW_ATTACHMENT_LEASE_CAPABILITY);
        }
        if self.supports_capability(VIEW_ATTACHMENT_DETACH_CAPABILITY) {
            negotiated.push(VIEW_ATTACHMENT_DETACH_CAPABILITY);
        }
        if self.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
            negotiated.push(CREATION_RECEIPTS_CAPABILITY);
        }
        if self.supports_capability(CREATION_SELECTOR_FALLBACKS_CAPABILITY) {
            negotiated.push(CREATION_SELECTOR_FALLBACKS_CAPABILITY);
        }
        if self.supports_capability(SHARED_SIZING_CAPABILITY) {
            // Join shared sizing as a terminal client named after this host,
            // like the Mac and iPhone (docs/shared-terminal-sizing.md).
            negotiated.push(SHARED_SIZING_CAPABILITY);
            // One cmux-tui install per host, so the host name is also the
            // stable device id that keeps two hosts' priority keys apart.
            let host = local_hostname().unwrap_or_else(|| "cmux-tui".to_string());
            client_info["device_kind"] = json!("tui");
            client_info["device_name"] = json!(host);
            client_info["device_id"] = json!(host);
        }
        // Replays are applied with colors written after them, so the
        // daemon's incomplete sequence must arrive separately.
        if self.supports_capability(TERMINAL_PENDING_SEQUENCE_CAPABILITY) {
            negotiated.push(TERMINAL_PENDING_SEQUENCE_CAPABILITY);
        }
        if !negotiated.is_empty() {
            client_info["capabilities"] = json!(negotiated);
        }
        self.request(client_info)?;
        if subscribe {
            self.prime_local_subscription();
            if let Err(error) = self.request(self.subscription_request()) {
                self.primed_subscription.lock().unwrap().take();
                return Err(error);
            }
            self.subscription_started.store(true, Ordering::Release);
        }
        Ok(())
    }

    /// The latest `size-state` for `surface`.
    pub(super) fn size_state(&self, surface: SurfaceId) -> Option<super::SurfaceSizeState> {
        self.size_states.lock().unwrap().get(&surface).cloned()
    }

    /// Keeps the newest state per terminal; an older generation is ignored.
    /// Returns whether the stored state changed.
    fn store_size_state(
        &self,
        surface: SurfaceId,
        state: TerminalSizingState,
        self_participant: Option<String>,
    ) -> bool {
        let mut states = self.size_states.lock().unwrap();
        if let Some(current) = states.get(&surface)
            && (current.state.generation > state.generation
                || (current.state == state && current.self_participant == self_participant))
        {
            return false;
        }
        states.insert(surface, super::SurfaceSizeState { state, self_participant });
        true
    }

    /// A `shared-sizing-v1` attach answers with this view's participant id
    /// and the current size state, so the terminal has bounds before the
    /// first change event.
    fn adopt_attach_size_state(&self, surface: SurfaceId, response: &Value) {
        let Some(state) = response
            .get("size_state")
            .cloned()
            .and_then(|state| serde_json::from_value::<TerminalSizingState>(state).ok())
        else {
            return;
        };
        let self_participant =
            response.get("participant").and_then(Value::as_str).map(str::to_string);
        if self.store_size_state(surface, state.clone(), self_participant) {
            self.emit(MuxEvent::SizeStateChanged {
                surface,
                runtime: surface,
                state: Arc::new(state),
            });
        }
    }

    pub(super) fn supports_capability(&self, capability: &str) -> bool {
        self.capabilities.lock().unwrap().contains(capability)
    }

    pub fn supports_surface_subscription_filter(&self) -> bool {
        self.supports_capability(cmux_tui_core::server::SURFACE_SUBSCRIBE_FILTER_CAPABILITY)
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
        self.primed_subscription
            .lock()
            .unwrap()
            .take()
            .unwrap_or_else(|| self.subscribers.subscribe())
    }

    fn prime_local_subscription(&self) {
        let receiver = self.subscribers.subscribe();
        let previous = self.primed_subscription.lock().unwrap().replace(receiver);
        debug_assert!(previous.is_none(), "event receiver must be consumed before re-priming");
    }

    /// Limit this connection to events that can affect one attached terminal.
    /// Surface IDs are allocated from one, so zero is the unscoped sentinel.
    pub fn scope_events_to_surface(&self, surface: SurfaceId) -> anyhow::Result<()> {
        debug_assert_ne!(surface, 0);
        if !self.supports_surface_subscription_filter() {
            anyhow::bail!("remote server does not support filtered surface subscriptions");
        }
        if self
            .subscription_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            anyhow::bail!("event subscription already started");
        }
        self.event_surface_filter.store(surface, Ordering::Release);
        self.prime_local_subscription();
        if let Err(error) = self.request(self.subscription_request()) {
            self.primed_subscription.lock().unwrap().take();
            self.event_surface_filter.store(0, Ordering::Release);
            self.subscription_started.store(false, Ordering::Release);
            return Err(error);
        }
        Ok(())
    }

    fn subscription_request(&self) -> Value {
        let surface = self.event_surface_filter.load(Ordering::Acquire);
        if surface == 0 {
            json!({"cmd": "subscribe"})
        } else {
            json!({"cmd": "subscribe", "surface": surface})
        }
    }

    fn accepts_event_in_surface_scope(&self, event: &str, value: &Value) -> bool {
        let target = self.event_surface_filter.load(Ordering::Acquire);
        if target == 0 {
            return true;
        }
        let surface = value.get("surface").and_then(Value::as_u64);
        match event {
            "client-attached"
            | "client-changed"
            | "client-detached"
            | "client-list-invalidated" => false,
            "notification" => surface.is_none_or(|surface| surface == target),
            "overflow" if value.get("scope").and_then(Value::as_str) == Some("surface") => {
                surface == Some(target)
            }
            "vt-state"
            | "surface-output"
            | "surface-resized"
            | "surface-resize-failed"
            | "output"
            | "resized"
            | "colors-changed"
            | "browser-state"
            | "frame"
            | "detached"
            | "surface-exited"
            | "agent-changed"
            | "title-changed"
            | "bell"
            | "size-state"
            | "scroll-changed" => surface == Some(target),
            _ => true,
        }
    }

    fn report_read_progress(&self, partial: &[u8]) {
        let Some(target) = remote_progress_target(partial) else { return };
        let pending = self.pending.lock().unwrap();
        let attach_progressed = match target {
            RemoteProgressTarget::Request(id) => {
                if let Some(request) = pending.get(&id) {
                    request.progress.fetch_add(1, Ordering::Release);
                    request.attach_surface.is_some()
                } else {
                    false
                }
            }
            RemoteProgressTarget::AttachSurface(surface) => {
                pending.progress_for_attach_surface(surface)
            }
        };
        drop(pending);
        if attach_progressed {
            // A JSON-lines transport serializes complete messages. An attach
            // queued behind this progressing snapshot cannot receive its own
            // bytes yet, so its pre-response idle window follows this epoch.
            self.attach_progress.fetch_add(1, Ordering::Release);
        }
    }

    fn handle_line(self: &Arc<Self>, value: Value) {
        let surface_id = || value.get("surface").and_then(|v| v.as_u64());
        let event = value.get("event").and_then(Value::as_str);
        if event.is_some_and(|event| !self.accepts_event_in_surface_scope(event, &value)) {
            return;
        }
        match event {
            None => {
                // Response: route to the waiting request.
                let Some(id) = value.get("id").and_then(|v| v.as_u64()) else { return };
                if let Some(request) = self.pending.lock().unwrap().remove(&id) {
                    let _ = request.response.send(value);
                }
            }
            Some("vt-state") => {
                let Some(id) = surface_id() else { return };
                let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                let Some(data) = value.get("data").and_then(|v| v.as_str()) else { return };
                let Ok(replay) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    return;
                };
                let colors = value.get("colors").and_then(parse_terminal_colors);
                let Ok(pending_sequence) = parse_pending_sequence(&value) else {
                    self.disconnect_transport();
                    return;
                };
                self.log_frame(
                    id,
                    format_args!("vt-state cols={cols} rows={rows} bytes={}", replay.len()),
                );
                let Ok(kitty_image_aliases) = parse_kitty_image_aliases(&value) else {
                    self.disconnect_transport();
                    return;
                };
                let Ok(kitty_state) = parse_kitty_replay_state(&value) else {
                    self.disconnect_transport();
                    return;
                };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    if surface
                        .apply_stream_resize_with_colors(
                            cols,
                            rows,
                            Some(&replay),
                            &kitty_image_aliases,
                            Some(kitty_state),
                            colors.as_ref(),
                            &pending_sequence,
                        )
                        .is_err()
                    {
                        self.disconnect_transport();
                        return;
                    }
                    surface.dirty.store(true, Ordering::Release);
                }
                self.emit(MuxEvent::SurfaceOutput(id));
            }
            Some("surface-resized") => {
                let Some(id) = surface_id() else { return };
                let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                self.emit(MuxEvent::SurfaceResized {
                    surface: id,
                    cols,
                    rows,
                    reservation_id: value.get("reservation_id").and_then(Value::as_u64),
                });
            }
            Some("surface-resize-failed") => {
                let Some(id) = surface_id() else { return };
                let Some((cols, rows)) = remote_terminal_size(&value) else { return };
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
                self.log_frame(id, format_args!("output bytes={}", bytes.len()));
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.scan_cursor_provenance(&bytes);
                    let mut term = surface.term.lock().unwrap();
                    term.vt_write(&bytes);
                    if let Some(colors) = colors.as_ref() {
                        apply_terminal_colors(&mut term, colors);
                    }
                    surface.sync_mouse_encoders(&term);
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                    drop(term);
                    if !surface.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            }
            Some("resized") => {
                let Some(id) = surface_id() else { return };
                let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                let replay = match value.get("replay").or_else(|| value.get("data")) {
                    Some(data) => {
                        let Some(data) = data.as_str() else {
                            self.disconnect_transport();
                            return;
                        };
                        let Ok(replay) = base64::engine::general_purpose::STANDARD.decode(data)
                        else {
                            self.disconnect_transport();
                            return;
                        };
                        Some(replay)
                    }
                    None => None,
                };
                let Ok(kitty_image_aliases) = parse_kitty_image_aliases(&value) else {
                    self.disconnect_transport();
                    return;
                };
                let Ok(kitty_state) = parse_kitty_replay_state(&value) else {
                    self.disconnect_transport();
                    return;
                };
                let colors = value.get("colors").and_then(parse_terminal_colors);
                let Ok(pending_sequence) = parse_pending_sequence(&value) else {
                    self.disconnect_transport();
                    return;
                };
                self.log_frame(
                    id,
                    format_args!(
                        "resized cols={cols} rows={rows} bytes={}",
                        replay.as_ref().map(|bytes| bytes.len()).unwrap_or(0)
                    ),
                );
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    if surface
                        .apply_stream_resize_with_colors(
                            cols,
                            rows,
                            replay.as_deref(),
                            &kitty_image_aliases,
                            Some(kitty_state),
                            colors.as_ref(),
                            &pending_sequence,
                        )
                        .is_err()
                    {
                        self.disconnect_transport();
                        return;
                    }
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
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                    drop(term);
                    if !surface.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            }
            Some("browser-state") => {
                let Some(id) = surface_id() else { return };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                    if surface.apply_stream_resize(cols, rows, None, &[]).is_err() {
                        self.disconnect_transport();
                        return;
                    }
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
                    self.size_states.lock().unwrap().remove(&id);
                    self.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            Some(cmux_tui_core::server::DAEMON_SHUTDOWN_EVENT) => {
                let mut state = self.disconnect_state.lock().unwrap();
                if matches!(&*state, DisconnectState::Active) {
                    *state = DisconnectState::ExpectedRemoteShutdown;
                }
                drop(state);
                self.disconnect_state.notify();
                // Wake every request that was already admitted before the
                // daemon announced its shutdown. The synthetic response is
                // classified with the expected-remote state, so callers get
                // DaemonShutdown instead of a timeout when EOF follows.
                self.begin_shutdown();
                self.emit(MuxEvent::Empty);
            }
            Some("tree-changed") => {
                self.tree_stale.store(true, Ordering::Release);
                self.emit(MuxEvent::TreeChanged);
            }
            Some("size-state") => {
                let Some(surface) = surface_id() else { return };
                let Some(state) = value
                    .get("state")
                    .cloned()
                    .and_then(|state| serde_json::from_value::<TerminalSizingState>(state).ok())
                else {
                    return;
                };
                let self_participant =
                    value.get("self_participant").and_then(Value::as_str).map(str::to_string);
                if !self.store_size_state(surface, state.clone(), self_participant) {
                    return;
                }
                self.emit(MuxEvent::SizeStateChanged {
                    surface,
                    runtime: surface,
                    state: Arc::new(state),
                });
            }
            Some("agent-changed") => {
                let Some(surface) = surface_id() else { return };
                let Some(state) = value.get("state").and_then(Value::as_str) else { return };
                let Some(source) = value.get("source").and_then(Value::as_str) else { return };
                let Some(updated_at_ms) = value.get("updated_at_ms").and_then(Value::as_u64) else {
                    return;
                };
                let session = value.get("session").and_then(Value::as_str).map(str::to_string);
                let agent_adapter = value.get("agent").and_then(Value::as_str).map(str::to_string);
                let agent = AgentInfo {
                    surface,
                    state: state.to_string(),
                    source: source.to_string(),
                    session,
                    agent: agent_adapter,
                    updated_at_ms,
                };
                let event = MuxEvent::AgentChanged {
                    surface,
                    state: Arc::from(agent.state.as_str()),
                    source: Arc::from(agent.source.as_str()),
                    session: agent.session.as_deref().map(Arc::from),
                    agent: agent.agent.as_deref().map(Arc::from),
                    updated_at_ms,
                };
                {
                    let retired_surfaces = self.retired_surfaces.lock().unwrap();
                    if retired_surfaces.contains(&surface) {
                        return;
                    }
                    self.tree.lock().unwrap().update_agent(agent, &retired_surfaces);
                }
                self.emit(event);
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
                    // Retire the mirror immediately. The authoritative tree
                    // refresh may lag this event, but input and reattach must
                    // already fail closed for a known-exited surface.
                    self.drop_surface(id);
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
                    } else if self.invalidate_tree_once() {
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
                    source: value
                        .get("source")
                        .and_then(Value::as_str)
                        .and_then(NotificationSource::parse)
                        .unwrap_or(NotificationSource::Daemon),
                }));
            }
            Some("overflow") => {
                if value.get("scope").and_then(Value::as_str) == Some("surface") {
                    let surface_id = surface_id().filter(|surface_id| *surface_id != 0);
                    if let Some(surface_id) = surface_id {
                        let was_attached =
                            self.surfaces.lock().unwrap().remove(&surface_id).is_some();
                        if !was_attached {
                            return;
                        }
                        let reconnect_was_required =
                            self.surface_overflow_reconnect_required.load(Ordering::Acquire);
                        let (delay, stopped) = self.record_surface_overflow(surface_id);
                        self.emit(MuxEvent::SurfaceOutput(surface_id));
                        let reconnect_required =
                            self.surface_overflow_reconnect_required.load(Ordering::Acquire);
                        if !reconnect_required || !reconnect_was_required {
                            self.emit(MuxEvent::Status(if reconnect_required {
                                "surface overflow recovery capacity was exhausted; detach and reconnect to recover"
                                    .to_string()
                            } else if stopped {
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
            Some("graphics-status") => {
                if let Some(status) = parse_graphics_status(&value) {
                    self.emit(MuxEvent::GraphicsStatus(status));
                }
            }
            Some("machine-usage-changed") => {
                self.emit(MuxEvent::MachineUsageChanged(super::parse_machine_usage(&value)));
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
                    let first = session.request(session.subscription_request());
                    let result = match first {
                        Err(error) if Self::subscription_recovery_is_retryable(&error) => {
                            session.request(session.subscription_request())
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
        matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Rejected { .. })
        )
    }

    fn log_frame(&self, surface: SurfaceId, line: std::fmt::Arguments<'_>) {
        if self.frame_dump_dir.is_none() {
            return;
        }
        self.frame_logs.lock().unwrap().push(surface, line.to_string());
    }

    pub fn request(&self, cmd: Value) -> anyhow::Result<Value> {
        self.request_with_deadline(cmd, RequestDeadline::Standard)
    }

    /// Fire-and-forget command: enqueued in order with interactive traffic,
    /// never awaited. Used for best-effort reporting such as client focus.
    pub(crate) fn notify(&self, cmd: Value) -> anyhow::Result<()> {
        self.request_no_wait(cmd)
    }

    fn request_with_deadline(
        &self,
        mut cmd: Value,
        deadline: RequestDeadline,
    ) -> anyhow::Result<Value> {
        if let Some(error) = self.request_shutdown_error() {
            return Err(error.into());
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let progress = Arc::new(AtomicU64::new(0));
        let attach_progress = matches!(deadline, RequestDeadline::Attach)
            .then(|| self.attach_progress.load(Ordering::Acquire));
        let attach_surface = matches!(deadline, RequestDeadline::Attach)
            .then(|| cmd.get("surface").and_then(Value::as_u64))
            .flatten();
        cmd["id"] = json!(id);
        let message = serde_json::to_string(&cmd)
            .map_err(RemoteRequestError::Encode)
            .map_err(anyhow::Error::new)?;
        if let Some(Value::String(authority)) = cmd.get_mut("authority") {
            zeroize_string(authority);
        }

        let (tx, rx) = channel();
        self.pending.lock().unwrap().insert(
            id,
            PendingRemoteRequest { response: tx, progress: progress.clone(), attach_surface },
        );
        let sequence = match self.interactive_writer.enqueue(message, false) {
            Ok(sequence) => sequence,
            Err(error) => {
                self.pending.lock().unwrap().remove(&id);
                return Err(self.classify_transport_error(error).into());
            }
        };
        if let Err(error) = self.wait_for_ordered_write(sequence) {
            self.pending.lock().unwrap().remove(&id);
            return Err(self.classify_transport_error(error).into());
        }

        if self.shutdown.load(Ordering::Acquire) {
            self.pending.lock().unwrap().remove(&id);
            return Err(self.shutdown_error().into());
        }

        let response = match self.wait_for_response(rx, deadline, progress, attach_progress) {
            Ok(response) => response,
            Err(error) => {
                // Drop the pending entry so a half-open session does not
                // accumulate abandoned senders (and a late response is
                // not delivered to a receiver nobody holds).
                self.pending.lock().unwrap().remove(&id);
                return Err(error.into());
            }
        };
        if response.get("shutdown").and_then(Value::as_bool) == Some(true) {
            return Err(self.shutdown_error().into());
        }
        if response.get("ok").and_then(|v| v.as_bool()) == Some(true) {
            Ok(response.get("data").cloned().unwrap_or(Value::Null))
        } else {
            let error = response.get("error").and_then(|v| v.as_str()).unwrap_or("unknown error");
            let code = response.get("error_code").and_then(Value::as_str).map(ToString::to_string);
            let delivery = match response.get("error_delivery").and_then(Value::as_str) {
                Some("known-not-delivered") => Some(ClearHistoryDelivery::KnownNotDelivered),
                Some("ambiguous") => Some(ClearHistoryDelivery::Ambiguous),
                _ => None,
            };
            if disconnect::is_shutdown_pending_refusal(code.as_deref(), error) {
                self.disconnect_state.wait_while_active(disconnect::SHUTDOWN_PENDING_GRACE);
                if let Some(shutdown) = self.request_shutdown_error() {
                    return Err(shutdown.into());
                }
                disconnect::log_missing_shutdown_notice();
            }
            Err(RemoteRequestError::Rejected { error: error.to_string(), code, delivery }.into())
        }
    }

    fn wait_for_response(
        &self,
        rx: Receiver<Value>,
        deadline: RequestDeadline,
        progress: Arc<AtomicU64>,
        attach_progress: Option<u64>,
    ) -> Result<Value, RemoteRequestError> {
        if let RequestDeadline::Standard | RequestDeadline::Fixed(_) = deadline {
            let timeout = match deadline {
                RequestDeadline::Standard => REMOTE_REQUEST_TIMEOUT,
                RequestDeadline::Fixed(timeout) => timeout,
                RequestDeadline::Attach => unreachable!(),
            };
            return match rx.recv_timeout(timeout) {
                Ok(response) => Ok(response),
                Err(RecvTimeoutError::Timeout) => Err(RemoteRequestError::Timeout),
                Err(RecvTimeoutError::Disconnected) if self.shutdown.load(Ordering::Acquire) => {
                    Err(self.shutdown_error())
                }
                Err(RecvTimeoutError::Disconnected) => Err(RemoteRequestError::Timeout),
            };
        }

        let started = Instant::now();
        let mut deadline = AttachResponseDeadline::new(
            started,
            progress.load(Ordering::Acquire),
            attach_progress.expect("attach response wait requires an attach progress epoch"),
            REMOTE_ATTACH_IDLE_TIMEOUT,
            REMOTE_ATTACH_MAX_TIMEOUT,
        );
        loop {
            let request_progress = progress.load(Ordering::Acquire);
            let attach_progress = self.attach_progress.load(Ordering::Acquire);
            // Capture the deadline origin after the progress snapshots so scheduler
            // preemption cannot consume a newly granted idle window.
            let now = Instant::now();
            let Some(wait) = deadline.next_wait(now, request_progress, attach_progress) else {
                return Err(RemoteRequestError::Timeout);
            };
            match rx.recv_timeout(wait) {
                Ok(response) => return Ok(response),
                Err(RecvTimeoutError::Disconnected) if self.shutdown.load(Ordering::Acquire) => {
                    return Err(self.shutdown_error());
                }
                Err(RecvTimeoutError::Disconnected) => return Err(RemoteRequestError::Timeout),
                Err(RecvTimeoutError::Timeout) => {}
            }
            if self.shutdown.load(Ordering::Acquire) {
                return Err(self.shutdown_error());
            }
        }
    }

    /// Write latency-sensitive input in order without waiting for the mux
    /// command acknowledgement. The response reader still drains the reply;
    /// its unknown request id is intentionally ignored. Reliable remote
    /// sessions replay this write after carrier reconnect.
    fn request_no_wait(&self, mut cmd: Value) -> anyhow::Result<()> {
        if let Some(error) = self.request_shutdown_error() {
            return Err(error.into());
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        cmd["id"] = json!(id);
        // The local remote bridge replaces eligible sends with compact binary
        // MuxInput packets. Direct/older mux servers ignore this hint and keep
        // the existing JSON response behavior.
        cmd["no_reply"] = json!(true);
        let message = serde_json::to_string(&cmd)
            .map_err(RemoteRequestError::Encode)
            .map_err(anyhow::Error::new)?;
        let sequence = self
            .interactive_writer
            .enqueue(message, true)
            .map_err(|error| self.classify_transport_error(error))?;
        if self.shutdown.load(Ordering::Acquire) {
            self.wait_for_ordered_write(sequence)
                .map_err(|error| self.classify_transport_error(error))?;
            return Err(self.shutdown_error().into());
        }
        Ok(())
    }

    pub(super) fn request_guarded_pointer(
        &self,
        cmd: Value,
        lifecycle: GuardedPointerLifecycle,
    ) -> anyhow::Result<Value> {
        let result = self
            .request_with_deadline(cmd, RequestDeadline::Fixed(GUARDED_POINTER_REQUEST_TIMEOUT));
        if lifecycle == GuardedPointerLifecycle::CaptureMutation
            && result
                .as_ref()
                .err()
                .and_then(|error| error.downcast_ref::<RemoteRequestError>())
                .is_some_and(RemoteRequestError::is_timeout)
        {
            // The server may have accepted a press whose reply was lost.
            // Closing the connection removes this client from the server
            // registry and wakes every browser worker to balance its capture.
            self.disconnect_transport();
        }
        result
    }

    pub fn send_bytes(&self, surface: SurfaceId, bytes: &[u8]) -> anyhow::Result<()> {
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        self.request_no_wait(json!({"cmd": "send", "surface": surface, "bytes": encoded}))
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn interactive_write_metrics(&self) -> InteractiveWriteMetricsSnapshot {
        self.interactive_writer.metrics()
    }

    pub fn clear_history_classified(&self, surface: SurfaceId) -> Result<(), ClearHistoryFailure> {
        self.clear_history_request_classified(surface, None)
    }

    pub fn supports_clear_history_key_fallback(&self, surface: SurfaceId) -> bool {
        let server_supports_fallback = {
            let capabilities = self.capabilities.lock().unwrap();
            capabilities.contains(CLEAR_HISTORY_CAPABILITY)
                && capabilities.contains(CLEAR_HISTORY_KEY_CAPABILITY)
        };
        server_supports_fallback
            && self
                .tree
                .lock()
                .unwrap()
                .view
                .surface(surface)
                .is_some_and(|tab| tab.supports_clear_history_key_fallback)
    }

    pub fn clear_history_or_send_key_classified(
        &self,
        surface: SurfaceId,
        fallback_key: &KeyInput,
    ) -> Result<(), ClearHistoryFailure> {
        if self.supports_clear_history_key_fallback(surface) {
            let fallback_key = ProtocolKeyInput::try_from(fallback_key)
                .map_err(ClearHistoryFailure::known_not_delivered)?;
            return self.clear_history_request_classified(surface, Some(fallback_key));
        }

        // Plain clear-history remains available as a dedicated request, but
        // only an atomic-capability server can choose the active screen and
        // encode the fallback from authoritative keyboard modes. A mirrored
        // terminal is never safe for correctness-critical input routing.
        Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
            CLEAR_HISTORY_UNSUPPORTED_ERROR
        )))
    }

    fn clear_history_request_classified(
        &self,
        surface: SurfaceId,
        fallback_key: Option<ProtocolKeyInput>,
    ) -> Result<(), ClearHistoryFailure> {
        require_capability(
            &self.capabilities.lock().unwrap(),
            CLEAR_HISTORY_CAPABILITY,
            "clear-history",
        )
        .map_err(ClearHistoryFailure::known_not_delivered)?;
        self.request(json!({
            "cmd": "clear-history",
            "surface": surface,
            "fallback_key": fallback_key,
        }))
        .map(|_| ())
        .map_err(|error| {
            let known_not_delivered = matches!(
                error.downcast_ref::<RemoteRequestError>(),
                Some(RemoteRequestError::Encode(_))
                    | Some(RemoteRequestError::Rejected {
                        delivery: Some(ClearHistoryDelivery::KnownNotDelivered),
                        ..
                    })
            );
            if known_not_delivered {
                ClearHistoryFailure::known_not_delivered(error)
            } else {
                ClearHistoryFailure::ambiguous(error)
            }
        })
    }

    pub fn is_shut_down(&self) -> bool {
        self.shutdown.load(Ordering::Acquire)
    }

    pub fn daemon_shutdown_requested(&self) -> bool {
        matches!(&*self.disconnect_state.lock().unwrap(), DisconnectState::ExpectedRemoteShutdown)
    }

    fn request_shutdown_error(&self) -> Option<RemoteRequestError> {
        match &*self.disconnect_state.lock().unwrap() {
            DisconnectState::LocalShutdown => Some(RemoteRequestError::Shutdown),
            DisconnectState::ExpectedRemoteShutdown => Some(RemoteRequestError::DaemonShutdown),
            DisconnectState::Active | DisconnectState::Remote(_) => None,
        }
    }

    fn shutdown_error(&self) -> RemoteRequestError {
        self.request_shutdown_error().unwrap_or(RemoteRequestError::Shutdown)
    }

    fn classify_transport_error(&self, error: io::Error) -> RemoteRequestError {
        self.request_shutdown_error().unwrap_or(RemoteRequestError::Transport(error))
    }

    pub fn begin_shutdown(&self) {
        self.shutdown.store(true, Ordering::Release);
        self.provider_workspaces_guarded.store(false, Ordering::Release);
        let pending = std::mem::take(&mut *self.pending.lock().unwrap());
        for (_, request) in pending {
            let _ = request.response.send(json!({"shutdown": true}));
        }
        if let Ok(Some(sequence)) = self.interactive_writer.last_enqueued_sequence() {
            let _ = self.wait_for_ordered_write(sequence);
        }
    }

    fn wait_for_ordered_write(&self, sequence: u64) -> io::Result<()> {
        match self.interactive_writer.wait_until_written(sequence, remote_write_timeout()) {
            Ok(()) => Ok(()),
            Err(error) => {
                if error.kind() == io::ErrorKind::TimedOut {
                    self.interactive_writer.abort(&error);
                }
                Err(error)
            }
        }
    }

    fn disconnect_transport(&self) {
        self.disconnect_transport_with_reason(None);
    }

    pub(super) fn disconnect_transport_with_reason(&self, reason: Option<String>) {
        let mut state = self.disconnect_state.lock().unwrap();
        if matches!(&*state, DisconnectState::Active) {
            *state = match reason {
                Some(reason) => DisconnectState::Remote(reason),
                None => DisconnectState::LocalShutdown,
            };
        }
        drop(state);
        self.disconnect_state.notify();
        self.begin_shutdown();
        self.interactive_writer.close();
    }

    /// Returns the first reason recorded when the remote reader stopped.
    pub fn transport_disconnect_reason(&self) -> Option<String> {
        match &*self.disconnect_state.lock().unwrap() {
            DisconnectState::Remote(reason) => Some(reason.clone()),
            DisconnectState::Active
            | DisconnectState::LocalShutdown
            | DisconnectState::ExpectedRemoteShutdown => None,
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
                let known_not_applied = matches!(
                    error.downcast_ref::<RemoteRequestError>(),
                    Some(RemoteRequestError::Encode(_) | RemoteRequestError::Rejected { .. })
                );
                if known_not_applied {
                    *self.cell_pixels.lock().unwrap() = previous_global;
                    return match Self::restore_cell_pixels(&snapshots) {
                        Ok(()) => Err(error),
                        Err(rollback_error) => Err(anyhow::anyhow!(
                            "{error}; local cell-pixel rollback also failed: {rollback_error}"
                        )),
                    };
                }
                *self.cell_pixels.lock().unwrap() = next;
                let _ = self.reconcile_cell_pixels_from_remote();
                return Err(error);
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
                    failure.get("deferred").and_then(Value::as_bool).unwrap_or(false),
                ))
            })
            .collect::<Vec<_>>();
        let failed_surfaces = failures
            .iter()
            .filter_map(|(surface, _, deferred)| (!deferred).then_some(*surface))
            .collect::<HashSet<_>>();
        let use_target_for_creation =
            failures.is_empty() || failures.iter().all(|(_, _, deferred)| *deferred);
        let failed_snapshots = snapshots
            .iter()
            .filter(|(surface, _)| failed_surfaces.contains(&surface.id))
            .cloned()
            .collect::<Vec<_>>();
        Self::restore_cell_pixels(&failed_snapshots)?;
        if use_target_for_creation {
            *self.cell_pixels.lock().unwrap() = next;
        }
        let failures =
            failures.into_iter().map(|(surface, error, _)| (surface, error)).collect::<Vec<_>>();
        Ok(RemoteCellPixelUpdate { resizes, failures })
    }

    fn reconcile_cell_pixels_from_remote(&self) -> anyhow::Result<()> {
        let response = self.request(json!({"cmd": "get-cell-pixels"}))?;
        let width_px = response
            .get("width_px")
            .and_then(Value::as_u64)
            .and_then(|value| u16::try_from(value).ok())
            .filter(|value| *value > 0)
            .ok_or_else(|| anyhow::anyhow!("remote cell-pixel query omitted width_px"))?;
        let height_px = response
            .get("height_px")
            .and_then(Value::as_u64)
            .and_then(|value| u16::try_from(value).ok())
            .filter(|value| *value > 0)
            .ok_or_else(|| anyhow::anyhow!("remote cell-pixel query omitted height_px"))?;
        let surface_metrics = response
            .get("surfaces")
            .and_then(Value::as_array)
            .ok_or_else(|| anyhow::anyhow!("remote cell-pixel query omitted surfaces"))?
            .iter()
            .map(|surface| {
                let id = surface
                    .get("surface")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| anyhow::anyhow!("remote cell-pixel query omitted surface id"))?;
                let width_px = surface
                    .get("width_px")
                    .and_then(Value::as_u64)
                    .and_then(|value| u16::try_from(value).ok())
                    .filter(|value| *value > 0)
                    .ok_or_else(|| {
                        anyhow::anyhow!("remote cell-pixel query omitted surface width_px")
                    })?;
                let height_px = surface
                    .get("height_px")
                    .and_then(Value::as_u64)
                    .and_then(|value| u16::try_from(value).ok())
                    .filter(|value| *value > 0)
                    .ok_or_else(|| {
                        anyhow::anyhow!("remote cell-pixel query omitted surface height_px")
                    })?;
                Ok((id, (width_px, height_px)))
            })
            .collect::<anyhow::Result<HashMap<_, _>>>()?;
        let surfaces = self.surfaces.lock().unwrap().values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            if let Some(metric) = surface_metrics.get(&surface.id) {
                surface.set_cell_pixel_size(metric.0, metric.1)?;
            }
        }
        *self.cell_pixels.lock().unwrap() = (width_px, height_px);
        Ok(())
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

    pub fn supports_browser_attach(&self) -> bool {
        self.supports_capability(GUARDED_BROWSER_POINTER_CAPABILITY)
    }

    fn record_surface_overflow(&self, id: SurfaceId) -> (Option<Duration>, bool) {
        let now = Instant::now();
        let mut recoveries = self.surface_overflow_recovery.lock().unwrap();
        recoveries.retain(|_, recovery| {
            !recovery.attached_at.is_some_and(|attached| {
                now.saturating_duration_since(attached) >= SURFACE_OVERFLOW_STABLE
            })
        });
        if self.surface_overflow_reconnect_required.load(Ordering::Acquire)
            || (!recoveries.contains_key(&id)
                && recoveries.len() >= MAX_SURFACE_OVERFLOW_RECOVERIES)
        {
            self.surface_overflow_reconnect_required.store(true, Ordering::Release);
            return (None, true);
        }
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
        if self.surface_overflow_reconnect_required.load(Ordering::Acquire) {
            return false;
        }
        self.surface_overflow_recovery.lock().unwrap().get(&id).is_none_or(|recovery| {
            !recovery.stopped
                && recovery.retry_after.is_none_or(|retry_after| Instant::now() >= retry_after)
        })
    }

    pub fn surface_overflow_retry_due(&self) -> bool {
        if self.surface_overflow_reconnect_required.load(Ordering::Acquire) {
            return false;
        }
        self.surface_overflow_recovery.lock().unwrap().values().any(|recovery| {
            !recovery.stopped
                && recovery.retry_after.is_some_and(|retry_after| Instant::now() >= retry_after)
        })
    }

    /// Mirror for a surface, attaching on first use. Servers advertising
    /// initial attach sizing receive the first viewer claim atomically with
    /// the attach, so the initial replay already has its final geometry.
    pub(super) fn try_ensure_surface(
        self: &Arc<Self>,
        id: SurfaceId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RemoteSurfaceAttach> {
        let kind = {
            let tree = self.tree.lock().unwrap();
            tree.view.surface_kind(id)
        };
        self.try_ensure_surface_with_kind(id, kind, size)
    }

    pub(super) fn try_ensure_surface_with_kind(
        self: &Arc<Self>,
        id: SurfaceId,
        kind: SurfaceKind,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RemoteSurfaceAttach> {
        if self.retired_surfaces.lock().unwrap().contains(&id) {
            return Ok(RemoteSurfaceAttach::Retired);
        }
        if !self.can_attach_after_overflow(id) {
            return Ok(RemoteSurfaceAttach::Deferred);
        }
        if let Some(surface) = self.surfaces.lock().unwrap().get(&id) {
            return Ok(RemoteSurfaceAttach::Attached(surface.clone()));
        }
        let source = self.browser_sources.lock().unwrap().get(&id).copied().or_else(|| {
            (kind == SurfaceKind::Browser)
                .then(|| {
                    // Before the first tree refresh, preserve the historical lookup
                    // against the current cache rather than losing browser metadata.
                    let tree = self.tree.lock().unwrap();
                    browser_source_from_tree(&tree.view, id)
                })
                .flatten()
        });
        let (cols, rows) = size.unwrap_or((80, 24));
        let initial_size = size.map(|(cols, rows)| (cols.max(1), rows.max(1))).filter(|_| {
            self.supports_capability(cmux_tui_core::server::ATTACH_INITIAL_SIZE_CAPABILITY)
        });
        let surface = {
            // Coordinate only the local mirror commit with cell-metric
            // updates. The remote attach can stream for minutes and must not
            // retain this lifecycle lock while it waits.
            let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            if self.retired_surfaces.lock().unwrap().contains(&id) {
                return Ok(RemoteSurfaceAttach::Retired);
            }
            if !self.can_attach_after_overflow(id) {
                return Ok(RemoteSurfaceAttach::Deferred);
            }
            if let Some(surface) = self.surfaces.lock().unwrap().get(&id) {
                return Ok(RemoteSurfaceAttach::Attached(surface.clone()));
            }
            let cell_pixels = *self.cell_pixels.lock().unwrap();
            let mut term = Terminal::new(cols, rows, 10_000, Callbacks::default())?;
            term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
            let surface = Arc::new(RemoteSurface {
                id,
                kind,
                term: Mutex::new(term),
                mouse_encoders: Mutex::new(MouseEncoders::new()?),
                cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
                dirty: AtomicBool::new(false),
                geometry_lifecycle: Mutex::new(()),
                cell_pixels: Mutex::new(cell_pixels),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                content_generation: AtomicU64::new(1),
                reported_size: Mutex::new(None),
                browser: Mutex::new(RemoteBrowserState::default()),
            });
            surface.update_browser_source(source);
            self.surfaces.lock().unwrap().insert(id, surface.clone());
            surface
        };
        let mut request = json!({"cmd": "attach-surface", "surface": id});
        if let Some((cols, rows)) = initial_size {
            request["cols"] = json!(cols);
            request["rows"] = json!(rows);
        }
        // The vt-state event that follows fills the mirror.
        let response = match self.request_with_deadline(request, RequestDeadline::Attach) {
            Ok(response) => response,
            Err(error) => {
                {
                    let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
                    let mut surfaces = self.surfaces.lock().unwrap();
                    if surfaces.get(&id).is_some_and(|current| Arc::ptr_eq(current, &surface)) {
                        surfaces.remove(&id);
                    }
                }
                if error
                    .downcast_ref::<RemoteRequestError>()
                    .is_some_and(RemoteRequestError::is_timeout)
                {
                    // The server registers the stream before it queues the attach
                    // response. Closing the connection is the only protocol-level
                    // cancellation that guarantees a timed-out stream is released.
                    self.disconnect_transport();
                }
                return Err(error);
            }
        };
        let attachment_lease = if self.supports_capability(VIEW_ATTACHMENT_LEASE_CAPABILITY) {
            let Some(lease) = response.get("lease").and_then(Value::as_str) else {
                let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
                self.surfaces.lock().unwrap().remove(&id);
                self.disconnect_transport();
                anyhow::bail!(
                    "server advertised {VIEW_ATTACHMENT_LEASE_CAPABILITY} but attach returned no lease"
                );
            };
            Some(lease.to_string())
        } else {
            None
        };
        let superseded = {
            // Retirement can race the remote response. Commit the completed
            // attach only while this exact mirror is still the live entry.
            let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let current = self
                .surfaces
                .lock()
                .unwrap()
                .get(&id)
                .is_some_and(|candidate| Arc::ptr_eq(candidate, &surface));
            if self.retired_surfaces.lock().unwrap().contains(&id) {
                Some(RemoteSurfaceAttach::Retired)
            } else if !current {
                let overflowed = self.surface_overflow_recovery.lock().unwrap().contains_key(&id)
                    || self.surface_overflow_reconnect_required.load(Ordering::Acquire);
                Some(if overflowed {
                    RemoteSurfaceAttach::Deferred
                } else {
                    RemoteSurfaceAttach::Retired
                })
            } else {
                if let Some(lease) = &attachment_lease {
                    self.surface_leases.lock().unwrap().insert(id, lease.clone());
                }
                if let Some(size) = initial_size {
                    surface.set_reported_size(size);
                }
                if let Some(recovery) = self.surface_overflow_recovery.lock().unwrap().get_mut(&id)
                {
                    recovery.attached_at = Some(Instant::now());
                    recovery.retry_after = None;
                }
                None
            }
        };
        if superseded.is_none() {
            self.adopt_attach_size_state(id, &response);
        }
        if let Some(outcome) = superseded {
            if let Some(lease) = attachment_lease
                && self.supports_capability(VIEW_ATTACHMENT_DETACH_CAPABILITY)
            {
                if let Err(error) = self.request(json!({
                    "cmd": "detach-attached-view",
                    "surface": id,
                    "lease": lease,
                })) {
                    // If the targeted release cannot be confirmed, closing the
                    // transport is the remaining cleanup fence for every
                    // server-side attachment owned by this connection.
                    self.disconnect_transport();
                    return Err(anyhow::anyhow!(
                        "could not release superseded view attachment {id}: {error:#}"
                    ));
                }
            } else {
                // Older peers have no lease-addressed detach operation.
                self.disconnect_transport();
            }
            return Ok(outcome);
        }
        Ok(RemoteSurfaceAttach::Attached(surface))
    }

    pub fn retire_surface(&self, id: SurfaceId) {
        let mut retired_surfaces = self.retired_surfaces.lock().unwrap();
        retired_surfaces.insert(id);
        #[cfg(test)]
        if let Some(sender) = self.retire_surface_test_marker.lock().unwrap().clone() {
            let _ = sender.send(id);
        }
        self.tree.lock().unwrap().remove_agent(id);
        drop(retired_surfaces);
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let surface = self.surfaces.lock().unwrap().remove(&id);
        let mut exited = self.exited_surfaces.lock().unwrap();
        exited.ids.insert(id);
        if let Some(surface) = surface {
            exited.handles.insert(id, Arc::downgrade(&surface));
        }
        self.surface_leases.lock().unwrap().remove(&id);
        self.surface_overflow_recovery.lock().unwrap().remove(&id);
    }

    pub fn drop_surface(&self, id: SurfaceId) {
        self.retire_surface(id);
    }

    pub fn surface_is_exited(&self, id: SurfaceId) -> bool {
        self.exited_surfaces.lock().unwrap().ids.contains(&id)
    }

    pub fn surface_kind(&self, id: SurfaceId) -> SurfaceKind {
        self.tree.lock().unwrap().view.surface_kind(id)
    }

    pub fn cached_tree(&self) -> TreeView {
        self.tree.lock().unwrap().view.clone()
    }

    pub fn cached_agents(&self) -> Vec<AgentInfo> {
        self.tree.lock().unwrap().agents.clone()
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
        let (title_refresh_generation, agent_refresh_generation) = {
            let cache = self.tree.lock().unwrap();
            (cache.title_generation(), cache.agent_generation())
        };
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
        let agents = self
            .request(json!({"cmd": "list-agents"}))
            .ok()
            .and_then(|data| {
                data.get("agents")
                    .cloned()
                    .and_then(|agents| serde_json::from_value::<Vec<AgentInfo>>(agents).ok())
            })
            .unwrap_or_default();
        let capabilities = self.capabilities.lock().unwrap();
        let tree = parse_tree_with_capabilities(
            &data,
            TreeCapabilities {
                viewport_splits: capabilities.contains(VIEWPORT_SPLITS_CAPABILITY),
                viewport_column_resize: capabilities.contains(VIEWPORT_COLUMN_RESIZE_CAPABILITY),
            },
        );
        drop(capabilities);
        let raw_surface_ids = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .map(|tab| tab.surface)
            .collect::<HashSet<_>>();
        // The server tree is authoritative. The local surface catalog is a
        // lazy mirror and may be empty during startup or reconnect, so it
        // cannot be used as a negative filter. Remove only explicit retire
        // evidence captured at the detach boundary.
        let retired_surface_ids = self.retired_surfaces.lock().unwrap().clone();
        let mut tree = tree;
        tree.retain_not_retired(&retired_surface_ids);
        let live_surface_ids = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .map(|tab| tab.surface)
            .collect::<HashSet<_>>();
        self.retired_surfaces
            .lock()
            .unwrap()
            .retain(|surface_id| raw_surface_ids.contains(surface_id));
        self.prune_exited_surfaces(&live_surface_ids);
        self.surface_overflow_recovery
            .lock()
            .unwrap()
            .retain(|surface_id, _| live_surface_ids.contains(surface_id));
        let retired_surfaces = self.retired_surfaces.lock().unwrap();
        let tree = {
            let mut cache = self.tree.lock().unwrap();
            tree.retain_not_retired(&retired_surfaces);
            cache.replace(tree, title_refresh_generation);
            cache.replace_agents(agents, agent_refresh_generation, &retired_surfaces);
            cache.view.clone()
        };
        drop(retired_surfaces);
        let browser_sources = browser_sources_from_tree(&tree);
        *self.browser_sources.lock().unwrap() = browser_sources.clone();
        let surfaces = self.surfaces.lock().unwrap().clone();
        for (id, surface) in surfaces {
            surface.update_browser_source(browser_sources.get(&id).copied());
        }
        Ok(tree)
    }

    fn prune_exited_surfaces(&self, live_surface_ids: &HashSet<SurfaceId>) {
        let mut exited = self.exited_surfaces.lock().unwrap();
        let retained_handles = exited
            .handles
            .iter()
            .filter_map(|(&id, surface)| (surface.strong_count() > 0).then_some(id))
            .collect::<HashSet<_>>();
        exited.ids.retain(|id| live_surface_ids.contains(id) || retained_handles.contains(id));
        let retained_ids = exited.ids.clone();
        exited
            .handles
            .retain(|id, surface| retained_ids.contains(id) && surface.strong_count() > 0);
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
        let Some(dir) = self.frame_dump_dir.as_deref() else {
            return;
        };
        let _ = fs::create_dir_all(dir);
        let logs = self.frame_logs.lock().unwrap();
        let mut entries_by_surface: HashMap<SurfaceId, Vec<&str>> = HashMap::new();
        for entry in &logs.entries {
            entries_by_surface.entry(entry.surface).or_default().push(&entry.line);
        }
        for surface in self.surfaces.lock().unwrap().values() {
            let path = dir.join(format!("mirror-{}.txt", surface.id));
            let _ = fs::write(path, dump_mirror(surface));
            let frames = dir.join(format!("frames-{}.log", surface.id));
            if let Ok(file) = fs::File::create(frames) {
                let mut writer = io::BufWriter::new(file);
                for line in entries_by_surface.get(&surface.id).into_iter().flatten() {
                    let _ = writeln!(writer, "{line}");
                }
            }
        }
    }
}

fn parse_kitty_image_aliases(
    value: &Value,
) -> Result<Vec<ghostty_vt::KittyImageAlias>, &'static str> {
    let Some(aliases) = value.get("kitty_image_aliases") else {
        return Ok(Vec::new());
    };
    let aliases = aliases.as_array().ok_or("kitty_image_aliases must be an array")?;
    if aliases.len() > cmux_tui_core::terminal_host_protocol::MAX_KITTY_IMAGE_ALIASES {
        return Err("kitty_image_aliases has too many entries");
    }
    let aliases = aliases
        .iter()
        .map(|alias| {
            let image_id = alias
                .get("image_id")
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())
                .ok_or("kitty image alias has an invalid image_id")?;
            let image_number = alias
                .get("image_number")
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())
                .ok_or("kitty image alias has an invalid image_number")?;
            Ok(ghostty_vt::KittyImageAlias { image_id, image_number })
        })
        .collect::<Result<Vec<_>, &'static str>>()?;
    cmux_tui_core::terminal_host_runtime::validate_kitty_image_aliases(&aliases)
        .map_err(|_| "kitty_image_aliases violates terminal-host invariants")?;
    Ok(aliases)
}

/// Decodes the optional `pending` field of `vt-state` and `resized`: the
/// incomplete sequence the daemon's parser is inside. Absent from older
/// daemons and whenever the parser is at a boundary.
fn parse_pending_sequence(value: &Value) -> Result<Vec<u8>, ()> {
    match value.get("pending") {
        None => Ok(Vec::new()),
        Some(Value::String(data)) => {
            base64::engine::general_purpose::STANDARD.decode(data).map_err(|_| ())
        }
        Some(_) => Err(()),
    }
}

fn parse_kitty_replay_state(value: &Value) -> Result<KittyReplayState, &'static str> {
    let Some(state) = value.get("kitty_graphics_state") else {
        return Ok(KittyReplayState::disabled());
    };
    let state = state.as_object().ok_or("kitty_graphics_state must be an object")?;
    if state.len() != 9 {
        return Err("kitty_graphics_state has unexpected fields");
    }
    let u64_field = |name| {
        state.get(name).and_then(Value::as_u64).ok_or("kitty_graphics_state has an invalid limit")
    };
    let u32_field = |name| {
        state
            .get(name)
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .ok_or("kitty_graphics_state has an invalid image ID cursor")
    };
    KittyReplayState {
        limits: KittyGraphicsLimits {
            image_bytes: u64_field("image_bytes")?,
            inflight_bytes: u64_field("inflight_bytes")?,
            images: u64_field("images")?,
            placements: u64_field("placements")?,
        },
        replay_cursor_offset: u32_field("replay_cursor_offset")?,
        replay_next_image_ids: KittyImageIdCursors {
            primary: u32_field("primary_replay_next_image_id")?,
            alternate: u32_field("alternate_replay_next_image_id")?,
        },
        next_image_ids: KittyImageIdCursors {
            primary: u32_field("primary_next_image_id")?,
            alternate: u32_field("alternate_next_image_id")?,
        },
    }
    .validate()
    .map_err(|_| "kitty_graphics_state violates terminal limits")
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

fn browser_sources_from_tree(tree: &TreeView) -> HashMap<SurfaceId, BrowserSource> {
    tree.workspaces()
        .iter()
        .flat_map(|ws| ws.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .filter_map(|tab| tab.browser_source.map(|source| (tab.surface, source)))
        .collect()
}

fn browser_source_from_tree(tree: &TreeView, id: SurfaceId) -> Option<BrowserSource> {
    tree.workspaces()
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

fn parse_browser_frame(value: &Value) -> Option<RemoteBrowserFrame> {
    let data_b64 = value.get("data")?.as_str()?.to_string();
    let seq = value.get("seq")?.as_u64()?;
    let width = value
        .get("width")
        .and_then(Value::as_u64)
        .and_then(|width| u32::try_from(width).ok())
        .unwrap_or(0);
    let height = value
        .get("height")
        .and_then(Value::as_u64)
        .and_then(|height| u32::try_from(height).ok())
        .unwrap_or(0);
    let image_width = value
        .get("image_width")
        .and_then(Value::as_u64)
        .and_then(|width| u32::try_from(width).ok())
        .filter(|width| *width > 0)
        .unwrap_or(width);
    let image_height = value
        .get("image_height")
        .and_then(Value::as_u64)
        .and_then(|height| u32::try_from(height).ok())
        .filter(|height| *height > 0)
        .unwrap_or(height);
    Some(RemoteBrowserFrame {
        frame: Arc::new(BrowserFrame {
            session_id: String::new(),
            data_b64,
            css_width: width,
            css_height: height,
            image_width,
            image_height,
            seq,
        }),
    })
}

fn parse_browser_status(value: &Value) -> Option<BrowserStatus> {
    match value.get("status")?.as_str()? {
        "failed" => Some(BrowserStatus::Failed(
            value.get("error").and_then(Value::as_str).unwrap_or("browser failed").to_string(),
        )),
        "live" => Some(BrowserStatus::Live),
        "starting" => Some(BrowserStatus::Starting),
        _ => Some(BrowserStatus::Starting),
    }
}

#[cfg(test)]
struct NoopTransportAbort;

#[cfg(test)]
impl RemoteTransportAbort for NoopTransportAbort {
    fn abort(&self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
fn test_session_with_writer(
    writer: Box<dyn RemoteMessageWriter>,
    provider_workspace_authority: Option<BearerToken>,
    capabilities: HashSet<String>,
) -> Arc<RemoteSession> {
    Arc::new(RemoteSession {
        interactive_writer: InteractiveWriter::spawn(writer, Arc::new(NoopTransportAbort)).unwrap(),
        disconnect_state: disconnect::DisconnectCell::default(),
        pending: Mutex::new(PendingRemoteRequests::default()),
        next_id: AtomicU64::new(1),
        attach_progress: AtomicU64::new(0),
        shutdown: AtomicBool::new(false),
        surfaces: Mutex::new(HashMap::new()),
        exited_surfaces: Mutex::new(ExitedSurfaceState::default()),
        surface_leases: Mutex::new(HashMap::new()),
        retired_surfaces: Mutex::new(HashSet::new()),
        retire_surface_test_marker: Mutex::new(None),
        tree: Mutex::new(RemoteTreeCache::default()),
        browser_sources: Mutex::new(HashMap::new()),
        tree_refresh: Mutex::new(()),
        tree_stale: AtomicBool::new(true),
        subscription_started: AtomicBool::new(false),
        event_surface_filter: AtomicU64::new(0),
        subscription_recovery: Mutex::new(SubscriptionRecoveryState::default()),
        subscribers: MuxEventBroadcaster::default(),
        primed_subscription: Mutex::new(None),
        frame_dump_dir: None,
        frame_logs: Mutex::new(RemoteFrameLogs::default()),
        surface_overflow_recovery: Mutex::new(HashMap::new()),
        surface_overflow_reconnect_required: AtomicBool::new(false),
        cell_pixel_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        capabilities: Mutex::new(capabilities),
        size_states: Mutex::new(HashMap::new()),
        provider_workspace_authority,
        provider_workspaces_guarded: AtomicBool::new(false),
    })
}

#[cfg(test)]
struct DeferredAttachTestWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    attach_started: std::sync::mpsc::SyncSender<()>,
    release_attach: Option<Receiver<()>>,
    first_resize_failure: Option<(std::sync::mpsc::SyncSender<()>, Receiver<()>)>,
    attach_lease: Option<String>,
    requests: Option<Sender<Value>>,
}

#[cfg(test)]
impl RemoteMessageWriter for DeferredAttachTestWriter {
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
            .cloned()
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        if let Some(requests) = &self.requests {
            requests.send(request.clone()).map_err(io::Error::other)?;
        }
        if request.get("cmd").and_then(Value::as_str) == Some("attach-surface") {
            self.attach_started.send(()).map_err(io::Error::other)?;
            let release = self
                .release_attach
                .take()
                .ok_or_else(|| io::Error::other("attach release already consumed"))?;
            let lease = self.attach_lease.clone();
            std::thread::spawn(move || {
                let _ = release.recv();
                let Some(session) = session.upgrade() else { return };
                let Some(response) = session.pending.lock().unwrap().remove(&id) else {
                    return;
                };
                let data = lease.map_or(Value::Null, |lease| json!({"lease": lease}));
                let _ = response.response.send(json!({"id": id, "ok": true, "data": data}));
            });
            return Ok(());
        }
        let reject_resize = if request.get("cmd").and_then(Value::as_str) == Some("resize-surface")
        {
            if let Some((started, release)) = self.first_resize_failure.take() {
                started.send(()).map_err(io::Error::other)?;
                release.recv().map_err(io::Error::other)?;
                true
            } else {
                false
            }
        } else {
            false
        };
        let session =
            session.upgrade().ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let pending_response = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        let data = if request.get("cmd").and_then(Value::as_str) == Some("set-cell-pixels") {
            json!({"resizes": [], "failures": []})
        } else {
            Value::Null
        };
        let response = if reject_resize {
            json!({"id": id, "ok": false, "error": "scripted promoted resize failure"})
        } else {
            json!({"id": id, "ok": true, "data": data})
        };
        pending_response
            .response
            .send(response)
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
pub(super) fn test_session_with_deferred_attach() -> (Arc<RemoteSession>, Receiver<()>, Sender<()>)
{
    test_session_with_deferred_attach_control(None, HashSet::new())
}

#[cfg(test)]
pub(super) fn test_session_with_missing_surface_attach(surface: SurfaceId) -> Arc<RemoteSession> {
    struct MissingSurfaceAttachWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
        surface: SurfaceId,
    }

    impl RemoteMessageWriter for MissingSurfaceAttachWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request = serde_json::from_str::<Value>(message).map_err(io::Error::other)?;
            let Some(id) = request.get("id").and_then(Value::as_u64) else {
                return Ok(());
            };
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
            let payload = if request.get("cmd").and_then(Value::as_str) == Some("attach-surface") {
                json!({"id": id, "ok": false, "error": format!("unknown surface {}", self.surface)})
            } else {
                json!({"id": id, "ok": true, "data": null})
            };
            response
                .response
                .send(payload)
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    let session_slot = Arc::new(Mutex::new(None));
    let session = test_session_with_writer(
        Box::new(MissingSurfaceAttachWriter { session: session_slot.clone(), surface }),
        None,
        HashSet::new(),
    );
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    session.tree_stale.store(false, Ordering::Release);
    session
}

#[cfg(test)]
pub(super) fn test_session_with_deferred_sized_attach()
-> (Arc<RemoteSession>, Receiver<()>, Sender<()>) {
    test_session_with_deferred_attach_control(
        None,
        HashSet::from([cmux_tui_core::server::ATTACH_INITIAL_SIZE_CAPABILITY.to_string()]),
    )
}

#[cfg(test)]
fn test_session_with_deferred_attach_control(
    first_resize_failure: Option<(std::sync::mpsc::SyncSender<()>, Receiver<()>)>,
    capabilities: HashSet<String>,
) -> (Arc<RemoteSession>, Receiver<()>, Sender<()>) {
    let session_slot = Arc::new(Mutex::new(None));
    let (attach_started_tx, attach_started_rx) = std::sync::mpsc::sync_channel(1);
    let (release_attach_tx, release_attach_rx) = channel();
    let session = test_session_with_writer(
        Box::new(DeferredAttachTestWriter {
            session: session_slot.clone(),
            attach_started: attach_started_tx,
            release_attach: Some(release_attach_rx),
            first_resize_failure,
            attach_lease: capabilities
                .contains(VIEW_ATTACHMENT_LEASE_CAPABILITY)
                .then(|| "test-view-lease".to_string()),
            requests: None,
        }),
        None,
        capabilities,
    );
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    session.tree_stale.store(false, Ordering::Release);
    (session, attach_started_rx, release_attach_tx)
}

#[cfg(test)]
fn test_session_with_deferred_leased_attach()
-> (Arc<RemoteSession>, Receiver<()>, Sender<()>, Receiver<Value>) {
    let session_slot = Arc::new(Mutex::new(None));
    let (attach_started_tx, attach_started_rx) = std::sync::mpsc::sync_channel(1);
    let (release_attach_tx, release_attach_rx) = channel();
    let (request_tx, request_rx) = channel();
    let session = test_session_with_writer(
        Box::new(DeferredAttachTestWriter {
            session: session_slot.clone(),
            attach_started: attach_started_tx,
            release_attach: Some(release_attach_rx),
            first_resize_failure: None,
            attach_lease: Some("test-view-lease".to_string()),
            requests: Some(request_tx),
        }),
        None,
        HashSet::from([
            VIEW_ATTACHMENT_LEASE_CAPABILITY.to_string(),
            VIEW_ATTACHMENT_DETACH_CAPABILITY.to_string(),
        ]),
    );
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    session.tree_stale.store(false, Ordering::Release);
    (session, attach_started_rx, release_attach_tx, request_rx)
}

#[cfg(test)]
pub(super) struct DeferredAttachResizeFailureFixture {
    pub session: Arc<RemoteSession>,
    pub attach_started: Receiver<()>,
    pub release_attach: Sender<()>,
    pub resize_started: Receiver<()>,
    pub release_resize: Sender<()>,
}

#[cfg(test)]
pub(super) fn test_session_with_deferred_attach_and_first_resize_failure()
-> DeferredAttachResizeFailureFixture {
    let (resize_started_tx, resize_started_rx) = std::sync::mpsc::sync_channel(1);
    let (release_resize_tx, release_resize_rx) = channel();
    let (session, attach_started, release_attach) = test_session_with_deferred_attach_control(
        Some((resize_started_tx, release_resize_rx)),
        HashSet::new(),
    );
    DeferredAttachResizeFailureFixture {
        session,
        attach_started,
        release_attach,
        resize_started: resize_started_rx,
        release_resize: release_resize_tx,
    }
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

    test_session_with_writer(Box::new(NoopWriter), provider_workspace_authority, capabilities)
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
pub(super) fn test_session_with_view_attachment_leases() -> Arc<RemoteSession> {
    test_session_with_provider_context(
        None,
        HashSet::from([VIEW_ATTACHMENT_LEASE_CAPABILITY.to_string()]),
    )
}

#[cfg(test)]
pub(super) fn test_unleased_view_surface(
    surface_id: SurfaceId,
) -> (Arc<RemoteSession>, Arc<RemoteSurface>) {
    let session = test_session_with_view_attachment_leases();
    let surface = Arc::new(RemoteSurface {
        id: surface_id,
        kind: SurfaceKind::Pty,
        term: Mutex::new(Terminal::new(80, 24, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    });
    session.surfaces.lock().unwrap().insert(surface_id, surface.clone());
    (session, surface)
}

#[cfg(test)]
pub(super) fn test_session_with_live_browser(
    surface_id: SurfaceId,
    frame_seq: u64,
) -> Arc<RemoteSession> {
    test_session_with_browser_pointer_range(surface_id, frame_seq, frame_seq)
}

#[cfg(test)]
pub(super) fn test_session_with_browser_pointer_range(
    surface_id: SurfaceId,
    pointer_frame_floor_seq: u64,
    frame_seq: u64,
) -> Arc<RemoteSession> {
    let session = test_session_with_provider_context(None, HashSet::new());
    let frame = BrowserFrame {
        session_id: "test-browser-session".to_string(),
        data_b64: "AAAA".to_string(),
        css_width: 80,
        css_height: 48,
        image_width: 80,
        image_height: 48,
        seq: frame_seq,
    };
    let surface = Arc::new(RemoteSurface {
        id: surface_id,
        kind: SurfaceKind::Browser,
        term: Mutex::new(Terminal::new(10, 5, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState {
            url: Some("https://example.test".to_string()),
            title: Some("example".to_string()),
            status: BrowserStatus::Live,
            live_since: Some(Instant::now()),
            last_frame_at: Some(Instant::now()),
            frame: Some(RemoteBrowserFrame { frame: Arc::new(frame) }),
            pointer_frame_floor_seq: Some(pointer_frame_floor_seq),
            pointer_frame_seq: Some(frame_seq),
            presented_pointer_frame_seq: Some(pointer_frame_floor_seq),
            ..RemoteBrowserState::default()
        }),
    });
    session.surfaces.lock().unwrap().insert(surface_id, surface);
    session
}

#[cfg(test)]
pub(super) fn test_session_with_provider_authority_without_guard() -> Arc<RemoteSession> {
    test_session_with_provider_context(
        Some(BearerToken::new("test-provider-workspace-authority").unwrap()),
        HashSet::new(),
    )
}

#[cfg(test)]
pub(super) fn test_session_with_blocked_attach_transport_failure(
    reached: Arc<std::sync::Barrier>,
    release: Arc<std::sync::Barrier>,
) -> Arc<RemoteSession> {
    struct BlockedAttachFailureWriter {
        reached: Arc<std::sync::Barrier>,
        release: Arc<std::sync::Barrier>,
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    }

    impl RemoteMessageWriter for BlockedAttachFailureWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request = serde_json::from_str::<Value>(message).map_err(io::Error::other)?;
            if request.get("cmd").and_then(Value::as_str) == Some("attach-surface") {
                self.reached.wait();
                self.release.wait();
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "socket closed"));
            }
            let Some(id) = request.get("id").and_then(Value::as_u64) else { return Ok(()) };
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
                .response
                .send(json!({"id": id, "ok": true, "data": null}))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    let session_ref = Arc::new(Mutex::new(None));
    let session = test_session_with_writer(
        Box::new(BlockedAttachFailureWriter { reached, release, session: session_ref.clone() }),
        None,
        HashSet::from([
            cmux_tui_core::server::PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY.to_string()
        ]),
    );
    *session_ref.lock().unwrap() = Some(Arc::downgrade(&session));
    session
}

#[cfg(test)]
mod tests;
