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
use cmux_tui_core::{
    BrowserFrame, BrowserFrameUpdate, BrowserSource, BrowserStatus, ClearHistoryDelivery,
    ClearHistoryFailure, GraphicsStatus, GuardedMouseEncode, MuxEvent, MuxEventBroadcaster,
    MuxEventReceiver, NotificationEvent, NotificationLevel, PairingChallenge, PointerSemanticProbe,
    PointerSnapshotProbe, REMOTE_SESSION_MESSAGE_MAX_BYTES, Rgb, SurfaceId, SurfaceKind,
    TerminalPointerSnapshot,
    platform::transport,
    server::{
        CLEAR_HISTORY_CAPABILITY, CLEAR_HISTORY_KEY_CAPABILITY, CREATION_RECEIPTS_CAPABILITY,
        CREATION_SELECTOR_FALLBACKS_CAPABILITY, GUARDED_BROWSER_POINTER_CAPABILITY,
        ProtocolKeyInput, VIEW_ATTACHMENT_DETACH_CAPABILITY, VIEW_ATTACHMENT_LEASE_CAPABILITY,
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
        self.apply_stream_resize_with_colors(cols, rows, replay, kitty_image_aliases, None, None)
    }

    /// Apply one authoritative replay and its coupled Kitty alias and color
    /// state before the mirror can be observed at the new size.
    fn apply_stream_resize_with_colors(
        &self,
        cols: u16,
        rows: u16,
        replay: Option<&[u8]>,
        kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
        kitty_state: Option<KittyReplayState>,
        colors: Option<&RemoteTerminalColors>,
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
        let (replay, replay_aliases, replay_state) = match replay {
            Some(replay) => (
                replay,
                kitty_image_aliases,
                kitty_state.unwrap_or_else(KittyReplayState::disabled),
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
                )
            }
        };
        let mut fresh = Terminal::new(cols, rows, 10_000, Callbacks::default())?;
        fresh.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
        fresh.apply_vt_replay_parts(replay, replay_aliases, replay_state)?;
        if let Some(colors) = colors {
            apply_terminal_colors(&mut fresh, colors);
        }
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

    fn is_empty(&self) -> bool {
        self.requests.is_empty()
    }

    fn len(&self) -> usize {
        self.requests.len()
    }

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

#[derive(Default)]
enum DisconnectState {
    #[default]
    Active,
    LocalShutdown,
    Remote(String),
}

pub struct RemoteSession {
    interactive_writer: InteractiveWriter,
    /// The first terminal state wins. Local shutdown is kept separate from a
    /// reader failure so closing our own transport does not report a fake
    /// remote diagnostic.
    disconnect_state: Mutex<DisconnectState>,
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
        Self::connect_path(path, true)
    }

    pub fn connect_for_terminal_attach(path: &Path) -> anyhow::Result<Arc<Self>> {
        Self::connect_path(path, false)
    }

    fn connect_path(path: &Path, subscribe: bool) -> anyhow::Result<Arc<Self>> {
        let stream = transport::connect(path).map_err(|e| {
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
            disconnect_state: Mutex::new(DisconnectState::default()),
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
                    self.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            Some("tree-changed") => {
                self.tree_stale.store(true, Ordering::Release);
                self.emit(MuxEvent::TreeChanged);
            }
            Some("agent-changed") => {
                let Some(surface) = surface_id() else { return };
                let Some(state) = value.get("state").and_then(Value::as_str) else { return };
                let Some(source) = value.get("source").and_then(Value::as_str) else { return };
                let Some(updated_at_ms) = value.get("updated_at_ms").and_then(Value::as_u64) else {
                    return;
                };
                let session = value.get("session").and_then(Value::as_str).map(str::to_string);
                let agent = AgentInfo {
                    surface,
                    state: state.to_string(),
                    source: source.to_string(),
                    session,
                    updated_at_ms,
                };
                let event = MuxEvent::AgentChanged {
                    surface,
                    state: Arc::from(agent.state.as_str()),
                    source: Arc::from(agent.source.as_str()),
                    session: agent.session.as_deref().map(Arc::from),
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
                return Err(RemoteRequestError::Transport(error).into());
            }
        };
        if let Err(error) = self.wait_for_ordered_write(sequence) {
            self.pending.lock().unwrap().remove(&id);
            return Err(RemoteRequestError::Transport(error).into());
        }

        if self.shutdown.load(Ordering::Acquire) {
            self.pending.lock().unwrap().remove(&id);
            return Err(RemoteRequestError::Shutdown.into());
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
            return Err(RemoteRequestError::Shutdown.into());
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
                    Err(RemoteRequestError::Shutdown)
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
                    return Err(RemoteRequestError::Shutdown);
                }
                Err(RecvTimeoutError::Disconnected) => return Err(RemoteRequestError::Timeout),
                Err(RecvTimeoutError::Timeout) => {}
            }
            if self.shutdown.load(Ordering::Acquire) {
                return Err(RemoteRequestError::Shutdown);
            }
        }
    }

    /// Write latency-sensitive input in order without waiting for the mux
    /// command acknowledgement. The response reader still drains the reply;
    /// its unknown request id is intentionally ignored. Reliable remote
    /// sessions replay this write after carrier reconnect.
    fn request_no_wait(&self, mut cmd: Value) -> anyhow::Result<()> {
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
            .map_err(RemoteRequestError::Transport)?;
        if self.shutdown.load(Ordering::Acquire) {
            self.wait_for_ordered_write(sequence).map_err(RemoteRequestError::Transport)?;
            return Err(RemoteRequestError::Shutdown.into());
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
        self.begin_shutdown();
        self.interactive_writer.close();
    }

    /// Returns the first reason recorded when the remote reader stopped.
    pub fn transport_disconnect_reason(&self) -> Option<String> {
        match &*self.disconnect_state.lock().unwrap() {
            DisconnectState::Remote(reason) => Some(reason.clone()),
            DisconnectState::Active | DisconnectState::LocalShutdown => None,
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
        disconnect_state: Mutex::new(DisconnectState::default()),
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
mod tests {
    #[cfg(unix)]
    use std::io::{BufRead, Read, Write};
    #[cfg(unix)]
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::{AtomicBool, AtomicU64};
    use std::sync::mpsc::{Receiver, Sender};
    use std::sync::{Condvar, Mutex, Weak};

    use ghostty_vt::{Callbacks, ColorSpec, KeyAction, Mods, RenderState, Terminal};
    use serde_json::json;

    use super::*;

    fn attached_surface(outcome: RemoteSurfaceAttach) -> Arc<RemoteSurface> {
        let RemoteSurfaceAttach::Attached(surface) = outcome else {
            panic!("surface attach did not produce a mirror");
        };
        surface
    }

    #[test]
    fn protocol_12_identity_without_browser_capability_keeps_pty_sessions_compatible() {
        validate_remote_identity(&json!({"app": "cmux-tui", "protocol": 12})).unwrap();
    }

    #[test]
    fn browser_attach_requires_the_guarded_pointer_capability() {
        let unsupported = super::test_session_with_provider_context(None, HashSet::new());
        assert!(!unsupported.supports_browser_attach());

        let supported = super::test_session_with_provider_context(
            None,
            HashSet::from([GUARDED_BROWSER_POINTER_CAPABILITY.to_string()]),
        );
        assert!(supported.supports_browser_attach());
    }

    #[test]
    fn per_surface_client_sizing_requires_protocol_10() {
        const { assert!(SUPPORTED_PROTOCOL_VERSION >= 10) };
    }

    #[test]
    fn protocol_11_identity_is_rejected_before_workspace_loading() {
        let error =
            validate_remote_identity(&json!({"app": "cmux-tui", "protocol": 11})).unwrap_err();
        assert_eq!(
            error.to_string(),
            "unsupported cmux-tui protocol 11; this client requires protocol 12; restart the cmux-tui server"
        );
    }

    #[test]
    fn protocol_12_identity_with_guarded_pointer_capability_is_accepted() {
        validate_remote_identity(&json!({
            "app": "cmux-tui",
            "protocol": 12,
            "capabilities": ["browser-pointer-frame-guard-v1"],
        }))
        .unwrap();
    }

    #[test]
    fn clear_history_requires_its_additive_capability() {
        let without = identity_capabilities(&json!({
            "capabilities": ["attach-initial-size", "workspace-registry-v1"]
        }));
        let error =
            require_capability(&without, CLEAR_HISTORY_CAPABILITY, "clear-history").unwrap_err();
        assert_eq!(
            error.to_string(),
            "remote server does not support clear-history; restart the cmux-tui server"
        );

        let with = identity_capabilities(&json!({
            "capabilities": ["clear-history-v1"]
        }));
        require_capability(&with, CLEAR_HISTORY_CAPABILITY, "clear-history").unwrap();
        let error =
            require_capability(&with, CLEAR_HISTORY_KEY_CAPABILITY, "clear-history").unwrap_err();
        assert_eq!(error.to_string(), CLEAR_HISTORY_UNSUPPORTED_ERROR);

        let with_key_fallback = identity_capabilities(&json!({
            "capabilities": ["clear-history-v1", "clear-history-key-v1"]
        }));
        require_capability(&with_key_fallback, CLEAR_HISTORY_KEY_CAPABILITY, "clear-history")
            .unwrap();
    }

    #[test]
    fn protocol_12_identity_is_accepted() {
        validate_remote_identity(&json!({"app": "cmux-tui", "protocol": 12})).unwrap();
    }

    #[test]
    fn malformed_identity_capabilities_are_rejected() {
        for capabilities in [json!(null), json!("clear-history-v1"), json!(["ok", 1])] {
            assert!(
                validate_remote_identity(&json!({
                    "app": "cmux-tui", "protocol": 12, "capabilities": capabilities,
                }))
                .is_err()
            );
        }
    }

    #[test]
    fn disabled_frame_logging_does_not_format_hot_path_messages() {
        struct FormattingProbe(Arc<AtomicBool>);

        impl std::fmt::Display for FormattingProbe {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                self.0.store(true, Ordering::Relaxed);
                formatter.write_str("formatted")
            }
        }

        let formatted = Arc::new(AtomicBool::new(false));
        let session = super::test_session_with_provider_context(None, HashSet::new());

        session.log_frame(7, format_args!("{}", FormattingProbe(formatted.clone())));

        assert!(!formatted.load(Ordering::Relaxed));
        assert!(session.frame_logs.lock().unwrap().entries.is_empty());
    }

    #[test]
    fn frame_logging_evicts_oldest_entries_to_stay_within_both_limits() {
        let mut logs = RemoteFrameLogs::default();
        for line in ["first", "second", "third"] {
            logs.push_with_limits(7, line.into(), 2, 100);
        }
        assert_eq!(
            logs.entries.iter().map(|entry| entry.line.as_str()).collect::<Vec<_>>(),
            ["second", "third"]
        );

        let mut byte_bounded = RemoteFrameLogs::default();
        byte_bounded.push_with_limits(7, "1234".into(), 10, 8);
        byte_bounded.push_with_limits(7, "5678".into(), 10, 8);
        assert_eq!(byte_bounded.bytes, 5);
        assert_eq!(byte_bounded.entries.front().unwrap().line, "5678");
    }

    #[test]
    fn partial_message_progress_targets_only_its_request_or_attach() {
        assert_eq!(
            remote_progress_target(br#"{"id":41,"ok":true,"data":"partial"#),
            Some(RemoteProgressTarget::Request(41))
        );
        assert_eq!(
            remote_progress_target(br#"{"event":"vt-state","surface":7,"cols":80,"data":"partial"#),
            Some(RemoteProgressTarget::AttachSurface(7))
        );
        assert_eq!(
            remote_progress_target(
                br#"{"event":"browser-state","surface":8,"frame":{"data":"partial"#
            ),
            Some(RemoteProgressTarget::AttachSurface(8))
        );
        assert_eq!(
            remote_progress_target(br#"{"event":"output","surface":7,"id":41,"data":"partial"#),
            None
        );
        assert_eq!(remote_progress_target(br#"{"id":41"#), None);
    }

    #[test]
    fn json_line_reader_rejects_oversized_frames_before_buffering_them() {
        let mut reader = BufReader::with_capacity(4, io::Cursor::new(b"123456789\n".to_vec()));
        let mut largest_progress = 0;
        let error = read_json_line_with_progress_bounded(
            &mut reader,
            &mut |partial| largest_progress = largest_progress.max(partial.len()),
            8,
        )
        .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(error.to_string(), "remote session message exceeds the 8-byte limit");
        assert!(largest_progress <= 8);
    }

    #[test]
    fn json_line_reader_accepts_a_frame_at_the_exact_limit() {
        let mut reader = BufReader::with_capacity(3, io::Cursor::new(b"12345678\n".to_vec()));

        let line =
            read_json_line_with_progress_bounded(&mut reader, &mut |_| {}, 8).unwrap().unwrap();

        assert_eq!(line, "12345678");
    }

    #[test]
    fn json_line_reader_preserves_an_empty_delimited_frame() {
        let mut reader = BufReader::new(io::Cursor::new(b"\n".to_vec()));

        let line =
            read_json_line_with_progress_bounded(&mut reader, &mut |_| {}, 8).unwrap().unwrap();

        assert!(line.is_empty());
    }

    #[test]
    fn browser_frame_parses_image_dimensions_with_legacy_fallback() {
        let frame = parse_browser_frame(&json!({
            "seq": 1,
            "width": 800,
            "height": 600,
            "image_width": 400,
            "image_height": 300,
            "data": "frame",
        }))
        .unwrap()
        .frame;
        assert_eq!((frame.css_width, frame.css_height), (800, 600));
        assert_eq!((frame.image_width, frame.image_height), (400, 300));

        let legacy = parse_browser_frame(&json!({
            "seq": 2,
            "width": 320,
            "height": 200,
            "data": "legacy",
        }))
        .unwrap()
        .frame;
        assert_eq!((legacy.image_width, legacy.image_height), (320, 200));
    }

    #[test]
    fn raw_output_decscusr_authors_cursor_and_daemon_replay_resets_provenance() {
        let (session, surface) = test_unleased_view_surface(7);
        assert!(!surface.cursor_style_authored(), "defaults are never authored");

        // Raw inner-PTY output authors the cursor style.
        let encoded = base64::engine::general_purpose::STANDARD.encode(b"\x1b[5 q");
        session.handle_line(json!({"event": "output", "surface": 7, "data": encoded}));
        assert!(surface.cursor_style_authored());

        // The application resetting to the default clears authorship.
        let encoded = base64::engine::general_purpose::STANDARD.encode(b"\x1b[0 q");
        session.handle_line(json!({"event": "output", "surface": 7, "data": encoded}));
        assert!(!surface.cursor_style_authored());

        // A daemon-built vt-state replay carries resolved state with the
        // session defaults baked in, so it must never count as authored,
        // even when the replay bytes contain DECSCUSR.
        surface.scan_cursor_provenance(b"\x1b[6 q");
        assert!(surface.cursor_style_authored());
        surface
            .apply_stream_resize_with_colors(80, 24, Some(b"\x1b[5 q"), &[], None, None)
            .unwrap();
        assert!(!surface.cursor_style_authored());
    }

    #[test]
    fn resolved_output_colors_do_not_author_cursor_style() {
        let (session, surface) = test_unleased_view_surface(12);

        session.handle_line(json!({
            "event": "output",
            "surface": 12,
            "data": base64::engine::general_purpose::STANDARD.encode(b"prompt"),
            "colors": {
                "fg": "#eeeeee",
                "bg": "#171b2e",
                "cursor": "#ffee00",
                "cursor_style": "bar",
                "cursor_blink": true,
                "palette": {},
            },
        }));

        assert!(
            !surface.cursor_style_authored(),
            "daemon-resolved cursor colors must not be treated as inner-PTY authored"
        );
    }

    #[test]
    fn local_mirror_resize_preserves_cursor_authorship() {
        let (_session, surface) = test_unleased_view_surface(9);
        surface.scan_cursor_provenance(b"\x1b[3 q");
        assert!(surface.cursor_style_authored());
        surface.apply_stream_resize(100, 30, None, &[]).unwrap();
        assert!(
            surface.cursor_style_authored(),
            "a client-side resize replays the same application state"
        );
    }

    #[test]
    fn daemon_replay_restores_inner_mouse_tracking_to_the_mirror() {
        let (_session, surface) = test_unleased_view_surface(11);
        assert!(!surface.term.lock().unwrap().mouse_tracking());
        surface
            .apply_stream_resize_with_colors(80, 24, Some(b"\x1b[?1002h"), &[], None, None)
            .unwrap();
        assert!(
            surface.term.lock().unwrap().mouse_tracking(),
            "reattach replay must restore the inner mouse mode that drives host capture mirroring"
        );
    }

    /// Same contract against the daemon's REAL replay bytes, not a hand-written
    /// DECSET: the terminal host serializes attach state with the bounded
    /// theme-portable formatter, so this pins that its output still carries the
    /// mouse-tracking modes and that they survive the client's replay apply all
    /// the way to the pointer-semantics probe the App's host-capture mirroring
    /// reads.
    #[test]
    fn daemon_theme_portable_replay_restores_mouse_tracking_to_the_attach_probe() {
        let mut host = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
        // btop-shaped inner state: alt screen plus button-motion tracking with
        // SGR and urxvt encodings, entered before any client attached.
        host.vt_write(b"\x1b[?1049h\x1b[?1002h\x1b[?1015h\x1b[?1006h");
        assert!(host.mouse_tracking());
        let replay = host
            .vt_replay_bounded_theme_portable_with_aliases(REMOTE_CONTROL_MESSAGE_MAX_BYTES)
            .unwrap();

        let (_session, surface) = test_unleased_view_surface(12);
        assert!(!surface.term.lock().unwrap().mouse_tracking());
        surface
            .apply_stream_resize_with_colors(
                80,
                24,
                Some(&replay.bytes),
                &replay.kitty_image_aliases,
                Some(replay.kitty_state),
                None,
            )
            .unwrap();
        match surface.try_pointer_semantics() {
            PointerSemanticProbe::Ready(semantics) => assert!(
                semantics.mouse_tracking,
                "the attach probe must observe the replay-restored mouse modes"
            ),
            PointerSemanticProbe::Contended => panic!("uncontended terminal probe blocked"),
        }
    }

    fn forwarded_left_press_bytes(surface: &RemoteSurface) -> Vec<u8> {
        let input = MouseInput {
            action: ghostty_vt::MouseAction::Press,
            button: Some(ghostty_vt::MouseButton::Left),
            mods: Mods::default(),
            position: (35.5, 20.5),
            screen_size: (80, 24),
            cell_size: (1, 1),
            any_button_pressed: true,
        };
        let mut out = Vec::new();
        surface.encode_mouse(input, &mut out).expect("uncontended encoders").unwrap();
        out
    }

    /// Scoped reattach, real daemon serialization: the terminal host encodes
    /// attach state with the bounded theme-portable formatter. When the inner
    /// app (btop) enabled 1002h, 1015h, 1006h with SGR last, a click forwarded
    /// after reattach must still be re-encoded for the inner PTY as SGR, not
    /// urxvt. btop parses only SGR responses, so urxvt means dead clicks.
    #[test]
    fn daemon_replay_keeps_forwarded_clicks_sgr_when_inner_app_set_sgr_last() {
        let mut host = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
        host.vt_write(b"\x1b[?1049h\x1b[?1002h\x1b[?1015h\x1b[?1006h");
        let replay = host
            .vt_replay_bounded_theme_portable_with_aliases(REMOTE_CONTROL_MESSAGE_MAX_BYTES)
            .unwrap();

        let (_session, surface) = test_unleased_view_surface(13);
        surface
            .apply_stream_resize_with_colors(
                80,
                24,
                Some(&replay.bytes),
                &replay.kitty_image_aliases,
                Some(replay.kitty_state),
                None,
            )
            .unwrap();

        assert_eq!(
            forwarded_left_press_bytes(&surface),
            b"\x1b[<0;36;21M",
            "reattach replay flipped the forwarded click encoding away from SGR"
        );
    }

    /// A fixed daemon appends the active selector after its numeric flag dump,
    /// so an application that deliberately selected urxvt last keeps it.
    #[test]
    fn daemon_replay_keeps_a_deliberate_urxvt_choice() {
        let mut host = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
        host.vt_write(b"\x1b[?1002h\x1b[?1006h\x1b[?1015h");
        let replay = host
            .vt_replay_bounded_theme_portable_with_aliases(REMOTE_CONTROL_MESSAGE_MAX_BYTES)
            .unwrap();

        let (_session, surface) = test_unleased_view_surface(15);
        surface
            .apply_stream_resize_with_colors(
                80,
                24,
                Some(&replay.bytes),
                &replay.kitty_image_aliases,
                Some(replay.kitty_state),
                None,
            )
            .unwrap();

        assert_eq!(
            forwarded_left_press_bytes(&surface),
            b"\x1b[32;36;21M",
            "an application that chose urxvt last must keep urxvt after reattach"
        );
    }

    /// Older daemons serialize mouse DECSETs as a numeric flag dump and lose
    /// the original last-set order. Both SGR-last and urxvt-last applications
    /// can produce these bytes, so the client must apply them as written. A
    /// guessed preference would corrupt one of the two valid meanings.
    #[test]
    fn ambiguous_legacy_flag_dump_preserves_replayed_mouse_format() {
        let (_session, surface) = test_unleased_view_surface(14);
        surface
            .apply_stream_resize_with_colors(
                80,
                24,
                Some(b"\x1b[?1002h\x1b[?1006h\x1b[?1015h"),
                &[],
                None,
                None,
            )
            .unwrap();

        assert_eq!(
            forwarded_left_press_bytes(&surface),
            b"\x1b[32;36;21M",
            "ambiguous legacy replay must preserve its last selector instead of guessing SGR"
        );
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

    struct RecordingMessageWriter {
        messages: Arc<Mutex<Vec<String>>>,
    }

    impl RemoteMessageWriter for RecordingMessageWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            assert!(!message.contains(['\r', '\n']), "actor leaked transport framing");
            self.messages.lock().unwrap().push(message.to_string());
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn interactive_actor_sends_complete_messages_without_transport_delimiters() {
        let messages = Arc::new(Mutex::new(Vec::new()));
        let session = test_session(Box::new(RecordingMessageWriter { messages: messages.clone() }));

        session.send_bytes(9, b"x").unwrap();
        session.disconnect_transport();

        let messages = messages.lock().unwrap();
        assert_eq!(messages.len(), 1);
        let request: Value = serde_json::from_str(&messages[0]).unwrap();
        assert_eq!(request["cmd"], "send");
        assert_eq!(request["bytes"], "eA==");
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
            if command == "set-client-info" {
                assert!(
                    request["capabilities"].as_array().is_some_and(|capabilities| {
                        capabilities.iter().any(|capability| {
                            capability.as_str() == Some(GUARDED_BROWSER_POINTER_CAPABILITY)
                        })
                    }),
                    "a client using guarded browser commands must advertise that capability"
                );
            }
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
                    "data": {
                        "app": "cmux-tui",
                        "protocol": SUPPORTED_PROTOCOL_VERSION,
                        "capabilities": ["browser-pointer-frame-guard-v1"],
                    },
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
            Arc::new(NoopTransportAbort),
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
        requests: Option<Sender<Value>>,
    }

    impl RemoteMessageWriter for AcknowledgingWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            if let Some(requests) = self.requests.as_ref() {
                requests.send(request.clone()).map_err(|_| {
                    io::Error::new(io::ErrorKind::BrokenPipe, "request reader exited")
                })?;
            }
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
                .response
                .send(json!({"id": id, "ok": true, "data": null}))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct RecordingAcknowledgingWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
        requests: Arc<Mutex<Vec<Value>>>,
    }

    impl RemoteMessageWriter for RecordingAcknowledgingWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            self.requests.lock().unwrap().push(request.clone());
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
                .response
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
        test_session_with_abort_and_context(
            writer,
            Arc::new(NoopTransportAbort),
            capabilities,
            provider_workspace_authority,
        )
    }

    fn test_session_with_abort_and_context(
        writer: Box<dyn RemoteMessageWriter>,
        abort: Arc<dyn RemoteTransportAbort>,
        capabilities: HashSet<String>,
        provider_workspace_authority: Option<BearerToken>,
    ) -> Arc<RemoteSession> {
        Arc::new(RemoteSession {
            interactive_writer: InteractiveWriter::spawn(writer, abort).unwrap(),
            disconnect_state: Mutex::new(DisconnectState::default()),
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
            provider_workspace_authority,
            provider_workspaces_guarded: AtomicBool::new(false),
        })
    }

    #[derive(Default)]
    struct BlockingWriteState {
        blocked: bool,
        entered: bool,
        aborted: bool,
        fail_on_release: bool,
    }

    #[derive(Clone)]
    struct BlockingWriteControl {
        state: Arc<(Mutex<BlockingWriteState>, Condvar)>,
    }

    impl BlockingWriteControl {
        fn wait_until_entered(&self) {
            let deadline = Instant::now() + Duration::from_secs(1);
            let (state, changed) = &*self.state;
            let mut state = state.lock().unwrap();
            while !state.entered {
                let remaining = deadline.saturating_duration_since(Instant::now());
                assert!(!remaining.is_zero(), "interactive writer never entered the test stream");
                let (next, timeout) = changed.wait_timeout(state, remaining).unwrap();
                state = next;
                assert!(!timeout.timed_out() || state.entered);
            }
        }

        fn release(&self) {
            let (state, changed) = &*self.state;
            let mut state = state.lock().unwrap();
            state.blocked = false;
            drop(state);
            changed.notify_all();
        }

        fn fail(&self) {
            let (state, changed) = &*self.state;
            let mut state = state.lock().unwrap();
            state.fail_on_release = true;
            state.blocked = false;
            drop(state);
            changed.notify_all();
        }
    }

    #[derive(Clone)]
    struct BlockingWriteStream {
        control: BlockingWriteControl,
        output: Arc<Mutex<Vec<u8>>>,
    }

    impl BlockingWriteStream {
        fn new() -> (Self, BlockingWriteControl) {
            let control = BlockingWriteControl {
                state: Arc::new((
                    Mutex::new(BlockingWriteState {
                        blocked: true,
                        entered: false,
                        aborted: false,
                        fail_on_release: false,
                    }),
                    Condvar::new(),
                )),
            };
            (Self { control: control.clone(), output: Arc::new(Mutex::new(Vec::new())) }, control)
        }
    }

    impl RemoteMessageWriter for BlockingWriteStream {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let (state, changed) = &*self.control.state;
            let mut state = state.lock().unwrap();
            state.entered = true;
            changed.notify_all();
            while state.blocked {
                state = changed.wait(state).unwrap();
            }
            if state.aborted {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "test writer aborted"));
            }
            if state.fail_on_release {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "scripted write failure"));
            }
            drop(state);
            let mut output = self.output.lock().unwrap();
            output.extend_from_slice(message.as_bytes());
            output.push(b'\n');
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            self.control.release();
            Ok(())
        }
    }

    struct BlockingWriteAbort {
        control: BlockingWriteControl,
    }

    impl RemoteTransportAbort for BlockingWriteAbort {
        fn abort(&self) -> io::Result<()> {
            let (state, changed) = &*self.control.state;
            let mut state = state.lock().unwrap();
            state.aborted = true;
            state.blocked = false;
            drop(state);
            changed.notify_all();
            Ok(())
        }
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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new(cell_pixels),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
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
                .response
                .send(json!({"id": id, "ok": false, "error": "injected rejection"}))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct CellPixelFanoutWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
        fail_next: bool,
        deferred_failure: bool,
    }

    impl RemoteMessageWriter for CellPixelFanoutWriter {
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
            let data = match request.get("cmd").and_then(Value::as_str) {
                Some("set-cell-pixels") if std::mem::take(&mut self.fail_next) => {
                    json!({
                        "resizes": [],
                        "failures": [{
                            "surface": 7,
                            "error": "injected fan-out failure",
                            "deferred": self.deferred_failure,
                        }],
                    })
                }
                Some("set-cell-pixels") => json!({"resizes": [], "failures": []}),
                Some("attach-surface") => Value::Null,
                command => {
                    return Err(io::Error::other(format!("unexpected test command: {command:?}")));
                }
            };
            response
                .response
                .send(json!({"id": id, "ok": true, "data": data}))
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

    struct AmbiguousCellPixelWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    }

    impl RemoteMessageWriter for AmbiguousCellPixelWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            if request.get("cmd").and_then(Value::as_str) == Some("set-cell-pixels") {
                return Ok(());
            }
            if request.get("cmd").and_then(Value::as_str) != Some("get-cell-pixels") {
                return Err(io::Error::other("unexpected ambiguous cell-pixel test command"));
            }
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
                .response
                .send(json!({
                    "id": id,
                    "ok": true,
                    "data": {
                        "width_px": 10,
                        "height_px": 20,
                        "surfaces": [{
                            "surface": 7,
                            "width_px": 11,
                            "height_px": 22,
                        }],
                    },
                }))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn blocking_test_session(writer: BlockingWriteStream) -> Arc<RemoteSession> {
        let abort = Arc::new(BlockingWriteAbort { control: writer.control.clone() });
        test_session_with_abort_and_context(Box::new(writer), abort, HashSet::new(), None)
    }

    #[test]
    fn clear_history_shortcut_rejects_older_remote_server() {
        let session_slot = Arc::new(Mutex::new(None));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let session = test_session(Box::new(RecordingAcknowledgingWriter {
            session: session_slot.clone(),
            requests: requests.clone(),
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        session.surfaces.lock().unwrap().insert(7, test_remote_pty_surface(7, 80, 24, (8, 16)));
        let fallback = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_L,
            mods: Mods::CTRL,
            unshifted_codepoint: 'l' as u32,
            action: Some(KeyAction::Press),
            ..Default::default()
        };

        let error =
            session.clear_history_or_send_key_classified(7, &fallback).unwrap_err().into_error();

        assert_eq!(error.to_string(), CLEAR_HISTORY_UNSUPPORTED_ERROR);
        assert!(requests.lock().unwrap().is_empty());
    }

    #[test]
    fn clear_history_shortcut_requires_active_surface_support() {
        let session = test_session_with_provider_context(
            Box::new(UnexpectedWriteWriter),
            HashSet::from([
                CLEAR_HISTORY_CAPABILITY.to_string(),
                CLEAR_HISTORY_KEY_CAPABILITY.to_string(),
            ]),
            None,
        );
        session.tree.lock().unwrap().replace(
            parse_tree(&json!({
                "workspaces": [{
                    "id": 1,
                    "active": true,
                    "screens": [{
                        "id": 2,
                        "active": true,
                        "active_pane": 3,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": [{
                            "id": 3,
                            "active_tab": 0,
                            "tabs": [
                                {
                                    "surface": 7,
                                    "supports_clear_history_key_fallback": false
                                },
                                {
                                    "surface": 8,
                                    "supports_clear_history_key_fallback": true
                                }
                            ]
                        }]
                    }]
                }]
            })),
            0,
        );

        assert!(!session.supports_clear_history_key_fallback(7));
        assert!(session.supports_clear_history_key_fallback(8));
        assert!(!session.supports_clear_history_key_fallback(9));
    }

    #[test]
    fn older_remote_server_reports_unencodable_command_shortcut() {
        let session_slot = Arc::new(Mutex::new(None));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let session = test_session(Box::new(RecordingAcknowledgingWriter {
            session: session_slot.clone(),
            requests: requests.clone(),
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        session.surfaces.lock().unwrap().insert(7, test_remote_pty_surface(7, 80, 24, (8, 16)));
        let fallback = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_K,
            mods: Mods::SUPER,
            unshifted_codepoint: 'k' as u32,
            action: Some(KeyAction::Press),
            ..Default::default()
        };

        assert!(session.clear_history_or_send_key_classified(7, &fallback).is_err());
        assert!(requests.lock().unwrap().is_empty());
    }

    #[test]
    fn intermediate_remote_server_keeps_plain_clear_but_rejects_shortcut() {
        let session_slot = Arc::new(Mutex::new(None));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let session = test_session_with_provider_context(
            Box::new(RecordingAcknowledgingWriter {
                session: session_slot.clone(),
                requests: requests.clone(),
            }),
            HashSet::from([CLEAR_HISTORY_CAPABILITY.to_string()]),
            None,
        );
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        session.surfaces.lock().unwrap().insert(7, test_remote_pty_surface(7, 80, 24, (8, 16)));
        let fallback = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_L,
            mods: Mods::CTRL,
            unshifted_codepoint: 'l' as u32,
            action: Some(KeyAction::Press),
            ..Default::default()
        };

        let error =
            session.clear_history_or_send_key_classified(7, &fallback).unwrap_err().into_error();

        assert_eq!(error.to_string(), CLEAR_HISTORY_UNSUPPORTED_ERROR);
        assert!(requests.lock().unwrap().is_empty());
        session.clear_history_classified(7).unwrap();

        let recorded = requests.lock().unwrap();
        assert_eq!(recorded.len(), 1);
        assert_eq!(recorded[0]["cmd"], "clear-history");
        assert_eq!(recorded[0]["surface"], 7);
        assert_eq!(recorded[0]["fallback_key"], Value::Null);
    }

    #[test]
    fn clear_history_transport_failure_is_ambiguous() {
        struct FailingWriter;

        impl RemoteMessageWriter for FailingWriter {
            fn send(&mut self, _message: &str) -> io::Result<()> {
                Err(io::Error::new(io::ErrorKind::BrokenPipe, "socket closed"))
            }

            fn close(&mut self) -> io::Result<()> {
                Ok(())
            }
        }

        let session = test_session_with_provider_context(
            Box::new(FailingWriter),
            HashSet::from([CLEAR_HISTORY_CAPABILITY.to_string()]),
            None,
        );

        let failure = session.clear_history_classified(7).unwrap_err();

        assert_eq!(failure.delivery(), ClearHistoryDelivery::Ambiguous);
    }

    #[test]
    fn clear_history_rejection_preserves_known_not_delivered_delivery() {
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
                    .response
                    .send(json!({
                        "id": id,
                        "ok": false,
                        "error": "active terminal input extends into retained history",
                        "error_delivery": "known-not-delivered",
                    }))
                    .map_err(|_| io::Error::other("remote response receiver was dropped"))
            }

            fn close(&mut self) -> io::Result<()> {
                Ok(())
            }
        }

        let session_slot = Arc::new(Mutex::new(None));
        let session = test_session_with_provider_context(
            Box::new(RejectingWriter { session: session_slot.clone() }),
            HashSet::from([CLEAR_HISTORY_CAPABILITY.to_string()]),
            None,
        );
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));

        let failure = session.clear_history_classified(7).unwrap_err();

        assert_eq!(failure.delivery(), ClearHistoryDelivery::KnownNotDelivered);
    }

    fn acknowledging_provider_session() -> Arc<RemoteSession> {
        let session_slot = Arc::new(Mutex::new(None));
        let session = test_session_with_provider_context(
            Box::new(AcknowledgingWriter { session: session_slot.clone(), requests: None }),
            HashSet::from([
                cmux_tui_core::server::PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY.to_string()
            ]),
            Some(BearerToken::new("acknowledged-provider-workspace-authority").unwrap()),
        );
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        session
    }

    fn recording_acknowledging_session() -> (Arc<RemoteSession>, Receiver<Value>) {
        let session_slot = Arc::new(Mutex::new(None));
        let (requests, received_requests) = channel();
        let session = test_session(Box::new(AcknowledgingWriter {
            session: session_slot.clone(),
            requests: Some(requests),
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        session
            .capabilities
            .lock()
            .unwrap()
            .insert(cmux_tui_core::server::SURFACE_SUBSCRIBE_FILTER_CAPABILITY.to_string());
        (session, received_requests)
    }

    struct EnsureInitialTreeWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
        list_requests: usize,
    }

    struct AgentRefreshWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
        agent_requests: usize,
    }

    impl RemoteMessageWriter for AgentRefreshWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let response = match request.get("cmd").and_then(Value::as_str) {
                Some("list-workspaces") => json!({
                    "id": id,
                    "ok": true,
                    "data": {
                        "workspaces": [{
                            "id": 1,
                            "active": true,
                            "screens": [{
                                "id": 2,
                                "active": true,
                                "active_pane": 3,
                                "layout": {"type": "leaf", "pane": 3},
                                "panes": [{
                                    "id": 3,
                                    "active_tab": 0,
                                    "tabs": [{"surface": 4, "kind": "pty"}],
                                }],
                            }],
                        }],
                    },
                }),
                Some("list-agents") => {
                    self.agent_requests += 1;
                    if self.agent_requests == 1 {
                        json!({
                            "id": id,
                            "ok": true,
                            "data": {
                                "agents": [{
                                    "surface": 4,
                                    "state": "working",
                                    "source": "hook",
                                    "session": "agent-session",
                                    "updated_at_ms": 1,
                                }],
                            },
                        })
                    } else {
                        json!({"id": id, "ok": false, "error": "agent snapshot unavailable"})
                    }
                }
                command => {
                    return Err(io::Error::other(format!(
                        "unexpected agent refresh command {command:?}"
                    )));
                }
            };
            let session = self
                .session
                .lock()
                .unwrap()
                .as_ref()
                .and_then(Weak::upgrade)
                .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
            let pending = session
                .pending
                .lock()
                .unwrap()
                .remove(&id)
                .ok_or_else(|| io::Error::other("remote request was not pending"))?;
            pending
                .response
                .send(response)
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl RemoteMessageWriter for EnsureInitialTreeWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let data = match request.get("cmd").and_then(Value::as_str) {
                Some("list-workspaces") => {
                    self.list_requests += 1;
                    if self.list_requests == 1 {
                        json!({"workspaces": []})
                    } else {
                        json!({
                            "workspaces": [{
                                "id": 1,
                                "active": true,
                                "screens": [{
                                    "id": 2,
                                    "active": true,
                                    "active_pane": 3,
                                    "layout": {"type": "leaf", "pane": 3},
                                    "panes": [{
                                        "id": 3,
                                        "active_tab": 0,
                                        "tabs": [{"surface": 4, "kind": "pty"}],
                                    }],
                                }],
                            }],
                        })
                    }
                }
                Some("list-agents") => json!({"agents": []}),
                Some("new-workspace") => json!({"surface": 4}),
                command => {
                    return Err(io::Error::other(format!(
                        "unexpected ensure-initial command {command:?}"
                    )));
                }
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
            response
                .response
                .send(json!({"id": id, "ok": true, "data": data}))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// A session whose every workspace lost its screens (the outcome of the
    /// startup repair that prunes dead terminals) must get a shell in the
    /// active workspace at attach, not render pure emptiness. The writer
    /// refuses `new-workspace`, so this also pins that startup must not bolt
    /// an extra workspace onto a session that already has four.
    struct BareWorkspacesTreeWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
        created_in: Arc<Mutex<Option<String>>>,
    }

    impl RemoteMessageWriter for BareWorkspacesTreeWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let bare = |key: &str, id: u64, active: bool| json!({"id": id, "key": key, "active": active, "screens": []});
            let populated = json!({
                "id": 5,
                "key": "ws-active",
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "active_tab": 0,
                        "tabs": [{"surface": 4, "kind": "pty"}],
                    }],
                }],
            });
            let data = match request.get("cmd").and_then(Value::as_str) {
                Some("list-workspaces") => {
                    if self.created_in.lock().unwrap().is_some() {
                        json!({"generation": "gen-1", "terminal_revision": 8, "workspaces": [
                            bare("ws-0", 1, false),
                            populated,
                            bare("ws-2", 9, false),
                        ]})
                    } else {
                        json!({"generation": "gen-1", "terminal_revision": 7, "workspaces": [
                            bare("ws-0", 1, false),
                            bare("ws-active", 5, true),
                            bare("ws-2", 9, false),
                        ]})
                    }
                }
                Some("list-agents") => json!({"agents": []}),
                Some("create-terminal") => {
                    let key = request.get("key").and_then(Value::as_str).ok_or_else(|| {
                        io::Error::other("create-terminal omitted the workspace key")
                    })?;
                    if request.get("mutation_id").and_then(Value::as_str).is_none()
                        || request.get("expected_revision").and_then(Value::as_u64) != Some(7)
                        || request.get("expected_generation").and_then(Value::as_str)
                            != Some("gen-1")
                    {
                        return Err(io::Error::other(
                            "bootstrap create arrived without its concurrency guard",
                        ));
                    }
                    *self.created_in.lock().unwrap() = Some(key.to_string());
                    json!({"surface": 4})
                }
                command => {
                    return Err(io::Error::other(format!(
                        "bare-workspace attach must not send {command:?}"
                    )));
                }
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
            response
                .response
                .send(json!({"id": id, "ok": true, "data": data}))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// The losing side of a concurrent bare-session attach: its guarded
    /// create is rejected because the winner already moved the terminal
    /// revision, and the follow-up tree read shows the winner's shell.
    /// Attach must treat that as success, not as a startup failure.
    struct LostBootstrapRaceWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
        list_requests: usize,
    }

    impl RemoteMessageWriter for LostBootstrapRaceWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let populated = json!({
                "id": 5,
                "key": "ws-active",
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "active_tab": 0,
                        "tabs": [{"surface": 4, "kind": "pty"}],
                    }],
                }],
            });
            let response = match request.get("cmd").and_then(Value::as_str) {
                Some("list-workspaces") => {
                    self.list_requests += 1;
                    let data = if self.list_requests <= 2 {
                        json!({"generation": "gen-1", "terminal_revision": 7, "workspaces": [
                            {"id": 5, "key": "ws-active", "active": true, "screens": []},
                        ]})
                    } else {
                        json!({"generation": "gen-1", "terminal_revision": 8, "workspaces": [
                            populated,
                        ]})
                    };
                    json!({"id": id, "ok": true, "data": data})
                }
                Some("list-agents") => json!({"id": id, "ok": true, "data": {"agents": []}}),
                Some("create-terminal") => json!({
                    "id": id,
                    "ok": false,
                    "error": "expected terminal revision 7 does not match 8",
                }),
                command => {
                    return Err(io::Error::other(format!(
                        "lost bootstrap race must not send {command:?}"
                    )));
                }
            };
            let session = self
                .session
                .lock()
                .unwrap()
                .as_ref()
                .and_then(Weak::upgrade)
                .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
            let pending = session
                .pending
                .lock()
                .unwrap()
                .remove(&id)
                .ok_or_else(|| io::Error::other("remote request was not pending"))?;
            pending
                .response
                .send(response)
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn winner_between_snapshots_still_lands_in_the_cache() {
        // The other attach creates the shell between the first tree read and
        // the raw snapshot: no create runs here, and the final refresh must
        // still deliver the winner's tree to this client's cache.
        let session_slot = Arc::new(Mutex::new(None));
        let remote = test_session(Box::new(LostBootstrapRaceWriter {
            session: session_slot.clone(),
            list_requests: 1, // skip one bare read: the snapshot is populated
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
        let session = crate::session::Session::Remote(remote);

        session.ensure_initial(Some((80, 24))).unwrap();

        assert_eq!(
            session.tree().active_surface(),
            Some(4),
            "the stale bare tree survived in the cache"
        );
    }

    #[test]
    fn losing_the_bare_session_bootstrap_race_is_not_a_startup_failure() {
        let session_slot = Arc::new(Mutex::new(None));
        let remote = test_session(Box::new(LostBootstrapRaceWriter {
            session: session_slot.clone(),
            list_requests: 0,
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
        let session = crate::session::Session::Remote(remote);

        session.ensure_initial(Some((80, 24))).unwrap();

        assert_eq!(
            session.tree().active_surface(),
            Some(4),
            "the loser must adopt the winner's shell instead of failing attach"
        );
    }

    /// A daemon too old to report revision metadata cannot enforce the
    /// bootstrap guard, so the client must not send an unguarded create at
    /// all: the writer refuses `create-terminal`, and attach must still
    /// succeed with the session left bare, exactly as before the bootstrap
    /// existed.
    struct UnguardableTreeWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    }

    impl RemoteMessageWriter for UnguardableTreeWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let data = match request.get("cmd").and_then(Value::as_str) {
                Some("list-workspaces") => json!({"workspaces": [
                    {"id": 5, "key": "ws-active", "active": true, "screens": []},
                ]}),
                Some("list-agents") => json!({"agents": []}),
                command => {
                    return Err(io::Error::other(format!(
                        "an unguardable daemon must not receive {command:?}"
                    )));
                }
            };
            let session = self
                .session
                .lock()
                .unwrap()
                .as_ref()
                .and_then(Weak::upgrade)
                .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
            let pending = session
                .pending
                .lock()
                .unwrap()
                .remove(&id)
                .ok_or_else(|| io::Error::other("remote request was not pending"))?;
            pending
                .response
                .send(json!({"id": id, "ok": true, "data": data}))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn bootstrap_stays_home_when_the_daemon_cannot_enforce_its_guard() {
        let session_slot = Arc::new(Mutex::new(None));
        let remote =
            test_session(Box::new(UnguardableTreeWriter { session: session_slot.clone() }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
        let session = crate::session::Session::Remote(remote);

        session.ensure_initial(Some((80, 24))).unwrap();

        assert!(
            session.tree().workspaces().iter().all(|workspace| workspace.screens.is_empty()),
            "an unguarded create must never run"
        );
    }

    #[test]
    fn ensure_initial_creates_a_shell_when_every_restored_workspace_is_bare() {
        let session_slot = Arc::new(Mutex::new(None));
        let created_in = Arc::new(Mutex::new(None));
        let remote = test_session(Box::new(BareWorkspacesTreeWriter {
            session: session_slot.clone(),
            created_in: created_in.clone(),
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
        let session = crate::session::Session::Remote(remote);

        session.ensure_initial(Some((80, 24))).unwrap();

        assert_eq!(
            created_in.lock().unwrap().as_deref(),
            Some("ws-active"),
            "attach did not create a shell in the active bare workspace"
        );
        assert_eq!(
            session.tree().active_surface(),
            Some(4),
            "startup returned before the client could route input to its created terminal"
        );
    }

    #[test]
    fn ensure_initial_populates_remote_cache_after_creating_first_workspace() {
        let session_slot = Arc::new(Mutex::new(None));
        let remote = test_session(Box::new(EnsureInitialTreeWriter {
            session: session_slot.clone(),
            list_requests: 0,
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
        let session = crate::session::Session::Remote(remote);

        session.ensure_initial(Some((80, 24))).unwrap();

        assert_eq!(
            session.tree().active_surface(),
            Some(4),
            "startup returned before the client could route input to its created terminal"
        );
    }

    #[test]
    fn failed_agent_refresh_clears_last_known_agent_rows() {
        let session_slot = Arc::new(Mutex::new(None));
        let remote = test_session(Box::new(AgentRefreshWriter {
            session: session_slot.clone(),
            agent_requests: 0,
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));

        remote.refresh_tree().unwrap();
        assert_eq!(remote.cached_agents().len(), 1);

        remote.refresh_tree().unwrap();

        assert!(remote.cached_agents().is_empty());
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
    fn bounded_json_lines_reject_oversize_and_invalid_utf8() {
        let mut valid = BufReader::with_capacity(2, io::Cursor::new(b"{}\r\nnext\n"));
        assert_eq!(read_bounded_json_line(&mut valid, 8).unwrap().as_deref(), Some("{}"));
        assert_eq!(read_bounded_json_line(&mut valid, 8).unwrap().as_deref(), Some("next"));

        let mut oversized = BufReader::with_capacity(2, io::Cursor::new(b"123456789\n"));
        assert_eq!(
            read_bounded_json_line(&mut oversized, 8).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        let mut oversized_unterminated = BufReader::with_capacity(2, io::Cursor::new(b"123456789"));
        assert_eq!(
            read_bounded_json_line(&mut oversized_unterminated, 8).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        let mut truncated = BufReader::with_capacity(2, io::Cursor::new(b"{}"));
        assert_eq!(read_bounded_json_line(&mut truncated, 8).unwrap().as_deref(), Some("{}"));
        let mut invalid = BufReader::new(io::Cursor::new([0xff, b'\n']));
        assert_eq!(
            read_bounded_json_line(&mut invalid, 8).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn remote_reader_end_reason_distinguishes_eof_from_read_failure() {
        let eof: io::Result<Option<String>> = Ok(None);
        assert_eq!(
            remote_reader_end_reason(&eof).as_deref(),
            Some("the daemon closed the connection")
        );

        let failure = Err(io::Error::new(io::ErrorKind::ConnectionReset, "peer reset"));
        assert_eq!(remote_reader_end_reason(&failure).as_deref(), Some("peer reset"));

        let message = Ok(Some("{}".to_string()));
        assert!(remote_reader_end_reason(&message).is_none());
    }

    #[test]
    fn oversized_remote_reader_message_is_zeroized_before_disconnect() {
        let mut message = "secret remote payload".to_string();
        let reason = remote_reader_message_too_large(&mut message);

        assert_eq!(
            reason,
            format!(
                "remote session message exceeds the \
                 {REMOTE_SESSION_MESSAGE_MAX_BYTES}-byte limit"
            )
        );
        assert!(message.bytes().all(|byte| byte == 0));
    }

    #[test]
    fn json_reader_preserves_non_eof_read_errors() {
        struct FailingReader;

        impl Read for FailingReader {
            fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
                Err(io::Error::new(io::ErrorKind::ConnectionReset, "peer reset"))
            }
        }

        let mut reader = BufReader::new(FailingReader);
        let result = read_json_line_with_progress(&mut reader, &mut |_| {});
        assert_eq!(result.as_ref().unwrap_err().to_string(), "peer reset");
        assert_eq!(remote_reader_end_reason(&result).as_deref(), Some("peer reset"));
    }

    #[test]
    fn remote_terminal_dimensions_are_bounded_by_dimension_and_total_cells() {
        assert_eq!(remote_terminal_size(&json!({})), Some((80, 24)));
        assert_eq!(remote_terminal_size(&json!({"cols": 4096, "rows": 256})), Some((4096, 256)));
        for value in [
            json!({"cols": 0, "rows": 24}),
            json!({"cols": 65_535, "rows": 24}),
            json!({"cols": 4096, "rows": 257}),
            json!({"cols": -1, "rows": 24}),
            json!({"cols": "80", "rows": 24}),
        ] {
            assert_eq!(remote_terminal_size(&value), None, "accepted {value}");
        }
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
    fn transport_disconnect_reason_is_first_writer_wins() {
        let session = test_session(Box::new(CloseTrackingWriter {
            closed: Arc::new(AtomicBool::new(false)),
        }));

        session.disconnect_transport_with_reason(Some("the daemon closed the connection".into()));
        session.disconnect_transport_with_reason(Some("peer reset".into()));

        assert_eq!(
            session.transport_disconnect_reason().as_deref(),
            Some("the daemon closed the connection")
        );
    }

    #[test]
    fn local_shutdown_does_not_preserve_reader_error() {
        let session = test_session(Box::new(CloseTrackingWriter {
            closed: Arc::new(AtomicBool::new(false)),
        }));

        session.disconnect_transport();
        session.disconnect_transport_with_reason(Some("peer reset".into()));

        assert_eq!(session.transport_disconnect_reason(), None);
    }

    #[test]
    fn guarded_pointer_timeout_uses_transport_disconnect_lifecycle() {
        let closed = Arc::new(AtomicBool::new(false));
        let session = test_session(Box::new(CloseTrackingWriter { closed: closed.clone() }));

        assert!(
            session
                .request_guarded_pointer(
                    json!({
                        "cmd": "browser-mouse-guarded",
                        "kind": "down"
                    }),
                    GuardedPointerLifecycle::CaptureMutation
                )
                .unwrap_err()
                .downcast_ref::<RemoteRequestError>()
                .is_some_and(RemoteRequestError::is_timeout)
        );
        assert!(session.shutdown.load(Ordering::Acquire));
        assert!(closed.load(Ordering::Acquire));
    }

    #[test]
    fn guarded_pointer_hover_timeout_preserves_the_transport() {
        let closed = Arc::new(AtomicBool::new(false));
        let session = test_session(Box::new(CloseTrackingWriter { closed: closed.clone() }));

        assert!(
            session
                .request_guarded_pointer(
                    json!({
                        "cmd": "browser-mouse-guarded",
                        "kind": "move"
                    }),
                    GuardedPointerLifecycle::Motion
                )
                .unwrap_err()
                .downcast_ref::<RemoteRequestError>()
                .is_some_and(RemoteRequestError::is_timeout)
        );
        assert!(!session.shutdown.load(Ordering::Acquire));
        assert!(!closed.load(Ordering::Acquire));
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

    #[test]
    fn deferred_surface_initialization_skips_the_unfiltered_subscription() {
        let closed = Arc::new(AtomicBool::new(false));

        let session = RemoteSession::connect_transport_with_initial_subscription(
            scripted_initialization_transport(
                InitializationFailure::SubscribeRejected,
                closed.clone(),
            ),
            false,
        )
        .expect("deferred initialization must not send subscribe");

        assert!(!session.subscription_started.load(Ordering::Acquire));
        assert!(!closed.load(Ordering::Acquire));
    }

    #[cfg(unix)]
    fn socket_test_session(stream: UnixStream) -> Arc<RemoteSession> {
        stream.set_write_timeout(Some(remote_write_timeout())).unwrap();
        test_session(Box::new(JsonLineWriter { inner: Box::new(stream) }))
    }

    #[cfg(unix)]
    #[test]
    fn browser_attach_deadline_advances_while_a_large_initial_frame_is_arriving() {
        let (client, server) = UnixStream::pair().unwrap();
        let (release_tx, release_rx) = channel();
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
            assert_eq!(request["cmd"], "attach-surface");
            let frame = concat!(
                "{\"event\":\"browser-state\",\"surface\":7,",
                "\"cols\":80,\"rows\":24,\"status\":\"live\",",
                "\"frame\":{\"seq\":1,\"width\":800,\"height\":600,\"data\":\"\"}}"
            );
            let first = frame.find(",\"cols\"").unwrap() + 1;
            let second = first + (frame.len() - first) / 2;
            for (index, fragment) in [
                &frame.as_bytes()[..first],
                &frame.as_bytes()[first..second],
                &frame.as_bytes()[second..],
            ]
            .into_iter()
            .enumerate()
            {
                peer.get_mut().write_all(fragment).unwrap();
                peer.get_mut().flush().unwrap();
                if index < 2 {
                    std::thread::sleep(Duration::from_millis(150));
                }
            }
            peer.get_mut().write_all(b"\n").unwrap();
            writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": true, "data": null}))
                .unwrap();
            release_rx.recv().unwrap();
        });
        let session = RemoteSession::connect_stream(Box::new(client)).unwrap();

        let started = Instant::now();
        let surface = attached_surface(
            session.try_ensure_surface_with_kind(7, SurfaceKind::Browser, None).unwrap(),
        );

        assert_eq!(surface.id, 7);
        assert_eq!(surface.kind, SurfaceKind::Browser);
        assert!(
            started.elapsed() > REMOTE_ATTACH_IDLE_TIMEOUT,
            "attach completed before exercising the progress-aware deadline"
        );
        assert!(!session.shutdown.load(Ordering::Acquire));
        release_tx.send(()).unwrap();
        peer.join().unwrap();
    }

    #[test]
    fn attach_deadline_expires_without_progress() {
        let started = Instant::now();
        let idle = Duration::from_millis(10);
        let mut deadline =
            AttachResponseDeadline::new(started, 0, 3, idle, Duration::from_millis(100));

        assert_eq!(deadline.next_wait(started, 0, 3), Some(idle));
        assert_eq!(
            deadline.next_wait(started + Duration::from_millis(9), 0, 3),
            Some(Duration::from_millis(1))
        );
        assert_eq!(deadline.next_wait(started + idle, 0, 3), None);
    }

    #[test]
    fn attach_deadline_extends_from_own_request_progress() {
        let started = Instant::now();
        let idle = Duration::from_millis(10);
        let mut deadline =
            AttachResponseDeadline::new(started, 0, 3, idle, Duration::from_millis(100));

        assert_eq!(deadline.next_wait(started + Duration::from_millis(8), 1, 3), Some(idle));
        assert_eq!(
            deadline.next_wait(started + Duration::from_millis(10), 1, 3),
            Some(Duration::from_millis(8))
        );
        assert_eq!(deadline.next_wait(started + Duration::from_millis(18), 1, 3), None);
    }

    #[test]
    fn queued_attach_deadline_extends_from_connection_progress_until_own_progress() {
        let started = Instant::now();
        let idle = Duration::from_millis(10);
        let mut deadline =
            AttachResponseDeadline::new(started, 0, 3, idle, Duration::from_millis(100));

        assert_eq!(deadline.next_wait(started + idle, 0, 4), Some(idle));
        assert_eq!(deadline.next_wait(started + Duration::from_millis(20), 1, 5), Some(idle));
        assert_eq!(deadline.next_wait(started + Duration::from_millis(30), 1, 6), None);
    }

    #[test]
    fn attach_deadline_hard_maximum_wins_over_progress() {
        let started = Instant::now();
        let idle = Duration::from_millis(10);
        let maximum = Duration::from_millis(25);
        let mut deadline = AttachResponseDeadline::new(started, 0, 3, idle, maximum);

        assert_eq!(deadline.next_wait(started + Duration::from_millis(9), 1, 3), Some(idle));
        assert_eq!(
            deadline.next_wait(started + Duration::from_millis(18), 2, 3),
            Some(Duration::from_millis(7))
        );
        assert_eq!(deadline.next_wait(started + maximum, 3, 3), None);
    }

    #[test]
    fn attach_progress_reverse_index_tracks_only_live_matching_requests() {
        let mut pending = PendingRemoteRequests::default();
        let unrelated_progress = Arc::new(AtomicU64::new(0));
        for id in 0..1_000 {
            pending.insert(
                id,
                PendingRemoteRequest {
                    response: channel().0,
                    progress: unrelated_progress.clone(),
                    attach_surface: Some(8),
                },
            );
        }
        let matching_progress = Arc::new(AtomicU64::new(0));
        pending.insert(
            1_000,
            PendingRemoteRequest {
                response: channel().0,
                progress: matching_progress.clone(),
                attach_surface: Some(7),
            },
        );

        assert!(pending.progress_for_attach_surface(7));
        assert_eq!(matching_progress.load(Ordering::Acquire), 1);
        assert_eq!(unrelated_progress.load(Ordering::Acquire), 0);

        let removed = pending.remove(&1_000).expect("matching request is pending");
        drop(removed);
        assert!(!pending.progress_for_attach_surface(7));
        assert_eq!(matching_progress.load(Ordering::Acquire), 1);
    }

    #[cfg(unix)]
    #[test]
    fn queued_attach_preserves_two_request_wire_order() {
        let (client, server) = UnixStream::pair().unwrap();
        let (first_seen_tx, first_seen_rx) = channel();
        let (both_pending_tx, both_pending_rx) = channel();
        let (release_responses_tx, release_responses_rx) = channel();
        let (release_peer_tx, release_peer_rx) = channel();
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

            let mut first_line = String::new();
            peer.read_line(&mut first_line).unwrap();
            let first: Value = serde_json::from_str(&first_line).unwrap();
            assert_eq!(first["cmd"], "attach-surface");
            assert_eq!(first["surface"], 7);
            first_seen_tx.send(()).unwrap();

            let mut second_line = String::new();
            peer.read_line(&mut second_line).unwrap();
            let second: Value = serde_json::from_str(&second_line).unwrap();
            assert_eq!(second["cmd"], "attach-surface");
            assert_eq!(second["surface"], 8);
            both_pending_tx.send(()).unwrap();
            release_responses_rx.recv().unwrap();

            writeln!(
                peer.get_mut(),
                "{}",
                json!({
                    "event": "vt-state",
                    "surface": 7,
                    "cols": 80,
                    "rows": 24,
                    "data": "",
                })
            )
            .unwrap();
            writeln!(peer.get_mut(), "{}", json!({"id": first["id"], "ok": true, "data": null}))
                .unwrap();

            writeln!(
                peer.get_mut(),
                "{}",
                json!({
                    "event": "vt-state",
                    "surface": 8,
                    "cols": 80,
                    "rows": 24,
                    "data": "",
                })
            )
            .unwrap();
            writeln!(peer.get_mut(), "{}", json!({"id": second["id"], "ok": true, "data": null}))
                .unwrap();
            release_peer_rx.recv().unwrap();
        });
        let session = RemoteSession::connect_stream(Box::new(client)).unwrap();

        let first_session = session.clone();
        let first = std::thread::spawn(move || {
            first_session.try_ensure_surface_with_kind(7, SurfaceKind::Pty, None)
        });
        first_seen_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let second_session = session.clone();
        let second = std::thread::spawn(move || {
            second_session.try_ensure_surface_with_kind(8, SurfaceKind::Pty, None)
        });

        both_pending_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let attach_progress = session.attach_progress.load(Ordering::Acquire);
        session
            .report_read_progress(br#"{"event":"vt-state","surface":7,"cols":80,"data":"partial"#);
        assert_eq!(session.attach_progress.load(Ordering::Acquire), attach_progress + 1);
        {
            let pending = session.pending.lock().unwrap();
            assert_eq!(pending.len(), 2);
            let progress_for = |surface| {
                pending
                    .values()
                    .find(|request| request.attach_surface == Some(surface))
                    .unwrap()
                    .progress
                    .load(Ordering::Acquire)
            };
            assert_eq!(progress_for(7), 1);
            assert_eq!(progress_for(8), 0);
        }
        release_responses_tx.send(()).unwrap();
        assert!(matches!(first.join().unwrap().unwrap(), RemoteSurfaceAttach::Attached(_)));
        assert!(matches!(second.join().unwrap().unwrap(), RemoteSurfaceAttach::Attached(_)));
        assert!(!session.shutdown.load(Ordering::Acquire));
        release_peer_tx.send(()).unwrap();
        peer.join().unwrap();
    }

    #[test]
    fn inflight_attach_does_not_hold_the_cell_pixel_lifecycle() {
        let (session, attach_started_rx, release_attach_tx) = test_session_with_deferred_attach();
        let attaching = session.clone();
        let worker = std::thread::spawn(move || {
            attaching.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24)))
        });
        attach_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let update = session.set_cell_pixel_size(9, 18).unwrap();

        assert!(update.failures.is_empty());
        assert_eq!(*session.cell_pixels.lock().unwrap(), (9, 18));
        assert_eq!(session.surface(7).unwrap().cell_pixel_size(), (9, 18));
        release_attach_tx.send(()).unwrap();
        assert!(matches!(worker.join().unwrap().unwrap(), RemoteSurfaceAttach::Attached(_)));
    }

    #[test]
    fn retired_surface_is_not_resurrected_by_an_inflight_attach() {
        let (session, attach_started_rx, release_attach_tx) = test_session_with_deferred_attach();
        let attaching = session.clone();
        let worker = std::thread::spawn(move || {
            attaching.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24)))
        });
        attach_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        session.retire_surface(7);
        release_attach_tx.send(()).unwrap();

        assert!(matches!(worker.join().unwrap().unwrap(), RemoteSurfaceAttach::Retired));
        assert!(session.surface(7).is_none());
        assert!(session.retired_surfaces.lock().unwrap().contains(&7));
    }

    #[test]
    fn retired_surface_releases_an_inflight_attach_lease() {
        let (session, attach_started_rx, release_attach_tx, requests) =
            test_session_with_deferred_leased_attach();
        let attaching = session.clone();
        let worker = std::thread::spawn(move || {
            attaching.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24)))
        });
        attach_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let attach = requests.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(attach["cmd"], "attach-surface");

        session.retire_surface(7);
        release_attach_tx.send(()).unwrap();

        assert!(matches!(worker.join().unwrap().unwrap(), RemoteSurfaceAttach::Retired));
        let release = requests
            .recv_timeout(Duration::from_secs(1))
            .expect("retired in-flight attach must release its server lease");
        assert_eq!(release["cmd"], "detach-attached-view");
        assert_eq!(release["surface"], 7);
        assert_eq!(release["lease"], "test-view-lease");
    }

    #[test]
    fn surface_exit_during_attach_retires_the_exact_mirror_before_return() {
        let (session, attach_started_rx, release_attach_tx) = test_session_with_deferred_attach();
        let attaching = session.clone();
        let worker = std::thread::spawn(move || {
            attaching.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24)))
        });
        attach_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let mirror = session.surface(7).expect("attach did not stage its local mirror");

        session.drop_surface(7);
        release_attach_tx.send(()).unwrap();

        assert!(matches!(worker.join().unwrap().unwrap(), RemoteSurfaceAttach::Retired));
        assert!(!session.has_surface(7));
        assert!(session.surface_is_exited(7));
        assert!(crate::session::SurfaceHandle::Remote(mirror, session).is_dead());
    }

    #[test]
    fn exited_marker_outlives_every_cached_remote_surface_handle() {
        let session = super::test_session_with_provider_context(None, HashSet::new());
        let surface = test_remote_surface(7);
        session.surfaces.lock().unwrap().insert(7, surface.clone());
        let handle = crate::session::SurfaceHandle::Remote(surface.clone(), session.clone());

        session.drop_surface(7);
        session.prune_exited_surfaces(&HashSet::new());

        assert!(handle.is_dead());
        drop(handle);
        drop(surface);
        session.prune_exited_surfaces(&HashSet::new());
        assert!(!session.surface_is_exited(7));
    }

    #[cfg(unix)]
    #[test]
    fn unrelated_remote_traffic_does_not_extend_attach_idle_deadline() {
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
            assert_eq!(request["cmd"], "attach-surface");
            let traffic_deadline = Instant::now() + REMOTE_ATTACH_IDLE_TIMEOUT * 8;
            while Instant::now() < traffic_deadline {
                if writeln!(peer.get_mut(), "{}", json!({"event": "tree-changed"})).is_err() {
                    break;
                }
                std::thread::sleep(REMOTE_ATTACH_IDLE_TIMEOUT / 4);
            }
        });
        let session = RemoteSession::connect_stream(Box::new(client)).unwrap();

        let started = Instant::now();
        let error = session
            .try_ensure_surface_with_kind(7, SurfaceKind::Pty, None)
            .err()
            .expect("missing attach response must time out");

        assert!(matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Timeout)
        ));
        assert!(
            started.elapsed() < REMOTE_ATTACH_IDLE_TIMEOUT * 3,
            "unrelated traffic extended the attach idle deadline to {:?}",
            started.elapsed()
        );
        peer.join().unwrap();
    }

    #[test]
    fn timed_out_attach_closes_transport_and_removes_local_mirror() {
        let closed = Arc::new(AtomicBool::new(false));
        let session = test_session(Box::new(CloseTrackingWriter { closed: closed.clone() }));

        let error = session
            .try_ensure_surface_with_kind(7, SurfaceKind::Pty, None)
            .err()
            .expect("silent attach must time out");

        assert!(matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Timeout)
        ));
        assert!(!session.has_surface(7));
        assert!(session.pending.lock().unwrap().is_empty());
        assert!(session.shutdown.load(Ordering::Acquire));
        assert!(closed.load(Ordering::Acquire));
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
                    json!({
                        "app": "cmux-tui",
                        "protocol": SUPPORTED_PROTOCOL_VERSION,
                        "capabilities": ["browser-pointer-frame-guard-v1"],
                    })
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
        assert!(
            matches!(
                error.downcast_ref::<RemoteRequestError>(),
                Some(RemoteRequestError::Shutdown)
            ),
            "expected shutdown after EOF canceled the request, got {error:?}"
        );
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(session.shutdown.load(Ordering::Acquire));
        assert!(session.pending.lock().unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn malformed_json_cancels_a_pending_request_and_preserves_decode_reason() {
        let (client, server) = UnixStream::pair().unwrap();
        let (release_tx, release_rx) = channel();
        let peer = std::thread::spawn(move || {
            let mut peer = BufReader::new(server);
            for expected_command in ["identify", "set-client-info", "subscribe"] {
                let mut line = String::new();
                peer.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["cmd"], expected_command);
                let data = if expected_command == "identify" {
                    json!({
                        "app": "cmux-tui",
                        "protocol": SUPPORTED_PROTOCOL_VERSION,
                        "capabilities": ["browser-pointer-frame-guard-v1"],
                    })
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
            assert_eq!(request["cmd"], "wait-for-malformed");
            peer.get_mut().write_all(b"not-json\n").unwrap();
            release_rx.recv().unwrap();
        });
        let session = RemoteSession::connect_stream(Box::new(client)).unwrap();
        let request_session = session.clone();
        let (done_tx, done_rx) = channel();
        let request = std::thread::spawn(move || {
            done_tx.send(request_session.request(json!({"cmd": "wait-for-malformed"}))).unwrap();
        });

        let result = match done_rx.recv_timeout(Duration::from_secs(2)) {
            Ok(result) => result,
            Err(error) => {
                session.begin_shutdown();
                request.join().unwrap();
                release_tx.send(()).unwrap();
                peer.join().unwrap();
                panic!("malformed JSON did not cancel the request promptly: {error}");
            }
        };
        request.join().unwrap();
        release_tx.send(()).unwrap();
        peer.join().unwrap();

        let error = result.unwrap_err();
        assert!(
            matches!(
                error.downcast_ref::<RemoteRequestError>(),
                Some(RemoteRequestError::Shutdown)
            ),
            "expected shutdown after malformed JSON canceled the request, got {error:?}"
        );
        assert!(
            session
                .transport_disconnect_reason()
                .is_some_and(|reason| reason.starts_with("remote JSON decode failed:")),
            "malformed JSON decode reason was not preserved: {:?}",
            session.transport_disconnect_reason()
        );
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

    #[test]
    fn shutdown_send_waits_for_ordered_write_completion() {
        let (stream, control) = BlockingWriteStream::new();
        let output = stream.output.clone();
        let session = blocking_test_session(stream);
        session.begin_shutdown();
        let (wait_started_rx, resume_wait_tx) =
            session.interactive_writer.gate_next_wait_until_written();

        let (finished_tx, finished_rx) = channel();
        let release_session = session.clone();
        let release = std::thread::spawn(move || {
            finished_tx.send(release_session.send_bytes(7, b"release")).unwrap();
        });
        let sequence = wait_started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        control.wait_until_entered();
        assert!(
            matches!(finished_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)),
            "shutdown send returned before its ordered write completed"
        );

        control.release();
        resume_wait_tx.send(()).unwrap();
        let error = finished_rx.recv_timeout(remote_write_timeout() * 2).unwrap().unwrap_err();
        assert!(
            matches!(
                error.downcast_ref::<RemoteRequestError>(),
                Some(RemoteRequestError::Shutdown)
            ),
            "expected shutdown after the ordered write completed, got {error:?}"
        );
        release.join().unwrap();
        let writer_state = session.interactive_writer.shared.state.lock().unwrap();
        assert!(writer_state.last_written_sequence >= sequence);
        drop(writer_state);
        assert!(!output.lock().unwrap().is_empty());
    }

    #[test]
    fn begin_shutdown_waits_for_previously_accepted_input() {
        let (stream, control) = BlockingWriteStream::new();
        let output = stream.output.clone();
        let session = blocking_test_session(stream);
        session.send_bytes(7, b"accepted").unwrap();
        control.wait_until_entered();

        let sequence = session.interactive_writer.last_enqueued_sequence().unwrap().unwrap();
        let (wait_started_rx, resume_wait_tx) =
            session.interactive_writer.gate_next_wait_until_written();

        let (finished_tx, finished_rx) = channel();
        let shutdown_session = session.clone();
        let shutdown = std::thread::spawn(move || {
            shutdown_session.begin_shutdown();
            finished_tx.send(()).unwrap();
        });
        assert_eq!(wait_started_rx.recv_timeout(Duration::from_secs(2)).unwrap(), sequence);
        assert!(
            matches!(finished_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)),
            "shutdown returned before previously accepted input was written"
        );

        control.release();
        resume_wait_tx.send(()).unwrap();
        finished_rx.recv_timeout(remote_write_timeout() * 2).unwrap();
        shutdown.join().unwrap();
        let writer_state = session.interactive_writer.shared.state.lock().unwrap();
        assert!(writer_state.last_written_sequence >= sequence);
        drop(writer_state);
        assert!(!output.lock().unwrap().is_empty());
    }

    #[test]
    fn write_timeout_aborts_the_blocked_writer_and_discards_queued_mutations() {
        let (stream, control) = BlockingWriteStream::new();
        let output = stream.output.clone();
        let session = blocking_test_session(stream);
        session.send_bytes(7, b"blocked").unwrap();
        control.wait_until_entered();
        session.send_bytes(7, b"queued").unwrap();
        let sequence = session.interactive_writer.last_enqueued_sequence().unwrap().unwrap();

        let started = Instant::now();
        let error = session.wait_for_ordered_write(sequence).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < remote_write_timeout() * 5);
        let deadline = Instant::now() + remote_write_timeout();
        loop {
            let state = session.interactive_writer.shared.state.lock().unwrap();
            if state.writer_closed {
                assert!(state.writes.is_empty());
                assert_eq!(state.queued_bytes, 0);
                break;
            }
            drop(state);
            assert!(Instant::now() < deadline, "aborted writer did not exit");
            std::thread::yield_now();
        }
        assert!(control.state.0.lock().unwrap().aborted);
        assert!(output.lock().unwrap().is_empty());
        let error = session.send_bytes(7, b"late").unwrap_err();
        assert!(error.downcast_ref::<RemoteRequestError>().is_some_and(|error| {
            matches!(error, RemoteRequestError::Transport(io_error)
                if io_error.kind() == io::ErrorKind::TimedOut)
        }));
    }

    #[test]
    fn dropping_a_session_aborts_a_blocked_writer() {
        let (stream, control) = BlockingWriteStream::new();
        let session = blocking_test_session(stream);
        session.send_bytes(7, b"blocked").unwrap();
        control.wait_until_entered();

        drop(session);

        let deadline = Instant::now() + remote_write_timeout();
        loop {
            let state = control.state.0.lock().unwrap();
            if state.aborted {
                break;
            }
            drop(state);
            assert!(Instant::now() < deadline, "dropped session did not abort writer");
            std::thread::yield_now();
        }
    }

    #[test]
    fn closing_a_session_aborts_a_writer_that_cannot_drain() {
        let (stream, control) = BlockingWriteStream::new();
        let session = blocking_test_session(stream);
        session.send_bytes(7, b"blocked").unwrap();
        control.wait_until_entered();

        let started = Instant::now();
        session.disconnect_transport();

        assert!(started.elapsed() < remote_write_timeout() * 5);
        let state = control.state.0.lock().unwrap();
        assert!(state.aborted);
        drop(state);
        let state = session.interactive_writer.shared.state.lock().unwrap();
        assert!(state.writer_closed);
        assert!(matches!(
            state.failure,
            Some(ref failure) if failure.kind == io::ErrorKind::TimedOut
        ));
    }

    #[test]
    fn send_failure_wakes_every_waiter_and_discards_the_queue() {
        let (stream, control) = BlockingWriteStream::new();
        let output = stream.output.clone();
        let session = blocking_test_session(stream);
        let first = session.interactive_writer.enqueue("first".into(), true).unwrap();
        control.wait_until_entered();
        let second = session.interactive_writer.enqueue("second".into(), true).unwrap();
        let (finished_tx, finished_rx) = channel();
        let mut waiters = Vec::new();
        for sequence in [first, second] {
            let session = session.clone();
            let finished_tx = finished_tx.clone();
            waiters.push(std::thread::spawn(move || {
                finished_tx
                    .send(
                        session
                            .interactive_writer
                            .wait_until_written(sequence, remote_write_timeout() * 2),
                    )
                    .unwrap();
            }));
        }

        control.fail();
        for _ in 0..2 {
            let error = finished_rx
                .recv_timeout(remote_write_timeout() * 2)
                .expect("write failure did not wake a waiter")
                .unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
        }
        for waiter in waiters {
            waiter.join().unwrap();
        }
        let state = session.interactive_writer.shared.state.lock().unwrap();
        assert!(state.writes.is_empty());
        assert_eq!(state.queued_bytes, 0);
        assert!(state.writer_closed);
        drop(state);
        assert!(output.lock().unwrap().is_empty());
        assert_eq!(session.interactive_write_metrics().write_failures, 1);
    }

    #[cfg(unix)]
    #[test]
    fn keystroke_write_does_not_wait_for_command_response() {
        let (client, server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let (finished_tx, finished_rx) = channel();
        let sender_session = session.clone();
        let sender = std::thread::spawn(move || {
            finished_tx.send(sender_session.send_bytes(9, b"x")).unwrap();
        });

        let mut peer = BufReader::new(server);
        let mut line = String::new();
        peer.read_line(&mut line).unwrap();
        let command: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(command["cmd"], "send");
        assert_eq!(command["surface"], 9);
        assert_eq!(command["bytes"], "eA==");
        assert_eq!(command["no_reply"], true);
        assert!(finished_rx.recv_timeout(Duration::from_millis(100)).unwrap().is_ok());
        sender.join().unwrap();
        assert_eq!(Arc::strong_count(&session), 1);
    }

    #[cfg(unix)]
    #[test]
    fn accepted_interactive_writes_remain_fifo() {
        let (client, server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        session.send_bytes(7, b"release").unwrap();
        session.send_bytes(7, b"press").unwrap();

        let mut peer = BufReader::new(server);
        let mut first = String::new();
        let mut second = String::new();
        peer.read_line(&mut first).unwrap();
        peer.read_line(&mut second).unwrap();
        let first: Value = serde_json::from_str(&first).unwrap();
        let second: Value = serde_json::from_str(&second).unwrap();
        assert_eq!(first["bytes"], "cmVsZWFzZQ==");
        assert_eq!(second["bytes"], "cHJlc3M=");
        assert!(first["id"].as_u64().unwrap() < second["id"].as_u64().unwrap());
        session.begin_shutdown();
        let metrics = session.interactive_write_metrics();
        assert_eq!(metrics.samples, 2);
        assert_eq!(metrics.histogram.iter().map(|bucket| bucket.samples).sum::<u64>(), 2);
        assert!(metrics.p50.is_some());
        assert!(metrics.p95.is_some());
        assert!(metrics.p99.is_some());
    }

    #[test]
    fn control_request_cannot_overtake_accepted_interactive_writes() {
        let (stream, control) = BlockingWriteStream::new();
        let output = stream.output.clone();
        let session = blocking_test_session(stream);
        session.send_bytes(7, b"first").unwrap();
        control.wait_until_entered();
        session.send_bytes(7, b"release").unwrap();

        let request_session = session.clone();
        let request = std::thread::spawn(move || {
            request_session.request(json!({"cmd": "mutation"})).unwrap_err()
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while session.interactive_writer.last_enqueued_sequence().unwrap() != Some(3) {
            assert!(Instant::now() < deadline, "control request was not queued");
            std::thread::yield_now();
        }

        control.release();
        session.begin_shutdown();
        assert!(request.join().unwrap().to_string().contains("canceled for shutdown"));
        let output = String::from_utf8(output.lock().unwrap().clone()).unwrap();
        let commands = output
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(commands.len(), 3);
        assert_eq!(commands[0]["bytes"], "Zmlyc3Q=");
        assert_eq!(commands[1]["bytes"], "cmVsZWFzZQ==");
        assert_eq!(commands[2]["cmd"], "mutation");
    }

    #[test]
    fn interactive_queue_saturation_fails_without_waiting_for_the_writer() {
        let (stream, control) = BlockingWriteStream::new();
        let session = blocking_test_session(stream);
        session.send_bytes(7, b"in-flight").unwrap();
        control.wait_until_entered();
        for _ in 0..INTERACTIVE_WRITE_QUEUE_CAPACITY {
            session.send_bytes(7, b"queued").unwrap();
        }

        let overflow_session = session.clone();
        let (finished_tx, finished_rx) = channel();
        let overflow = std::thread::spawn(move || {
            finished_tx.send(overflow_session.send_bytes(7, b"overflow")).unwrap();
        });
        let error = finished_rx
            .recv_timeout(Duration::from_millis(100))
            .expect("queue rejection waited for the blocked writer")
            .unwrap_err();
        assert!(error.downcast_ref::<RemoteRequestError>().is_some_and(|error| {
            matches!(error, RemoteRequestError::Transport(io_error)
                if io_error.kind() == io::ErrorKind::WouldBlock)
        }));
        let metrics = session.interactive_write_metrics();
        assert_eq!(metrics.backpressure_rejections, 1);
        control.release();
        overflow.join().unwrap();
    }

    #[test]
    fn latency_histogram_reports_fixed_bucket_percentiles() {
        let metrics = InteractiveWriteMetrics::default();
        for latency in [
            Duration::from_micros(10),
            Duration::from_micros(80),
            Duration::from_micros(200),
            Duration::from_micros(900),
            Duration::from_millis(20),
        ] {
            metrics.record_latency(latency);
        }

        let snapshot = metrics.snapshot();
        assert_eq!(snapshot.samples, 5);
        assert_eq!(snapshot.write_failures, 0);
        assert_eq!(snapshot.backpressure_rejections, 0);
        assert_eq!(snapshot.p50, Some(Duration::from_micros(250)));
        assert_eq!(snapshot.p95, Some(Duration::from_millis(25)));
        assert_eq!(snapshot.p99, Some(Duration::from_millis(25)));
        assert_eq!(snapshot.histogram.iter().map(|bucket| bucket.samples).sum::<u64>(), 5);
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

    #[cfg(unix)]
    #[test]
    fn agent_events_update_the_remote_cache_without_invalidating_the_tree() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.tree_stale.store(false, Ordering::Release);

        for (state, updated_at_ms) in [("working", 40), ("blocked", 41)] {
            session.handle_line(json!({
                "event": "agent-changed",
                "surface": 7,
                "state": state,
                "source": "hook",
                "session": "review",
                "updated_at_ms": updated_at_ms,
            }));
        }

        assert!(!session.tree_is_stale());
        assert_eq!(
            session.cached_agents(),
            vec![AgentInfo {
                surface: 7,
                state: "blocked".into(),
                source: "hook".into(),
                session: Some("review".into()),
                updated_at_ms: 41,
            }]
        );
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::AgentChanged {
                surface: 7,
                state,
                updated_at_ms: 41,
                ..
            }) if state.as_ref() == "blocked"
        ));
        assert!(events.try_iter().next().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn surface_exit_drops_cached_agent_before_a_stale_topology_can_restore_it() {
        let tree = || {
            parse_tree(&json!({
                "workspaces": [{
                    "id": 1,
                    "screens": [{
                        "id": 2,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": [{
                            "id": 3,
                            "tabs": [{"surface": 7, "title": "agent terminal"}],
                        }],
                    }],
                }],
            }))
        };
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        session.tree.lock().unwrap().replace(tree(), 0);

        session.handle_line(json!({
            "event": "agent-changed",
            "surface": 7,
            "state": "working",
            "source": "hook",
            "session": "review",
            "updated_at_ms": 41,
        }));
        assert_eq!(session.cached_agents().len(), 1);

        session.handle_line(json!({"event": "surface-exited", "surface": 7}));
        assert!(session.cached_agents().is_empty());

        // A stale topology response can briefly show the exited surface again.
        // A stale agent snapshot must not resurrect the exited agent row.
        let retired_surfaces = session.retired_surfaces.lock().unwrap().clone();
        let mut cache = session.tree.lock().unwrap();
        let title_generation = cache.title_generation();
        cache.replace(tree(), title_generation);
        cache.replace_agents(
            vec![AgentInfo {
                surface: 7,
                state: "working".into(),
                source: "hook".into(),
                session: Some("review".into()),
                updated_at_ms: 41,
            }],
            0,
            &retired_surfaces,
        );
        assert!(cache.agents.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn surface_exit_serializes_agent_updates_after_retirement_marker() {
        let tree = || {
            parse_tree(&json!({
                "workspaces": [{
                    "id": 1,
                    "screens": [{
                        "id": 2,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": [{
                            "id": 3,
                            "tabs": [{"surface": 7, "title": "agent terminal"}],
                        }],
                    }],
                }],
            }))
        };
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        session.tree.lock().unwrap().replace(tree(), 0);
        session.handle_line(json!({
            "event": "agent-changed",
            "surface": 7,
            "state": "working",
            "source": "hook",
            "session": "review",
            "updated_at_ms": 41,
        }));

        let (marker_tx, marker_rx) = channel();
        *session.retire_surface_test_marker.lock().unwrap() = Some(marker_tx);

        // Hold the cache lock. The retirement must publish its marker before
        // waiting for this lock, so a concurrent agent update cannot slip in.
        let tree_guard = session.tree.lock().unwrap();
        let retiring = session.clone();
        let retire_thread = std::thread::spawn(move || {
            retiring.handle_line(json!({"event": "surface-exited", "surface": 7}));
        });
        if marker_rx.recv_timeout(Duration::from_secs(1)).is_err() {
            drop(tree_guard);
            retire_thread.join().unwrap();
            panic!("surface retirement did not publish its marker before cache cleanup");
        }

        let updating = session.clone();
        let update_thread = std::thread::spawn(move || {
            updating.handle_line(json!({
                "event": "agent-changed",
                "surface": 7,
                "state": "needsInput",
                "source": "hook",
                "session": "review",
                "updated_at_ms": 42,
            }));
        });
        drop(tree_guard);
        retire_thread.join().unwrap();
        update_thread.join().unwrap();

        assert!(session.cached_agents().is_empty());
    }

    #[test]
    fn agent_refresh_filters_retired_surfaces_in_one_authoritative_pass() {
        fn agent(surface: SurfaceId) -> AgentInfo {
            AgentInfo {
                surface,
                state: "working".into(),
                source: "hook".into(),
                session: Some("review".into()),
                updated_at_ms: surface,
            }
        }

        let mut cache = RemoteTreeCache::default();
        let agents = (0..4096_u64).map(agent).collect::<Vec<_>>();
        for surface in 0..4096_u64 {
            let agent = agents[surface as usize].clone();
            cache
                .agent_updates
                .insert(surface, AgentUpdate { generation: surface.saturating_add(1), agent });
        }
        let retired = (0..4096_u64).step_by(2).collect::<HashSet<_>>();

        cache.replace_agents(agents, 0, &retired);

        assert_eq!(cache.agents.len(), 2048);
        assert!(cache.agents.iter().all(|agent| !retired.contains(&agent.surface)));
        assert_eq!(cache.agent_updates.len(), 2048);
        assert!(cache.agent_updates.keys().all(|surface| !retired.contains(surface)));
        assert!(cache.agents.iter().all(|agent| cache.agent_updates.contains_key(&agent.surface)));
    }

    #[test]
    fn agent_cache_does_not_keep_permanent_retirement_tombstones() {
        let agent = AgentInfo {
            surface: 7,
            state: "working".into(),
            source: "hook".into(),
            session: Some("review".into()),
            updated_at_ms: 41,
        };
        let mut cache = RemoteTreeCache::default();
        cache.replace_agent(agent.clone());
        cache.remove_agent(agent.surface);

        let retired = HashSet::new();
        cache.update_agent(agent.clone(), &retired);

        assert_eq!(cache.agents, vec![agent]);
        assert_eq!(cache.agent_updates.len(), 1);
    }

    #[test]
    fn surface_event_scope_filters_before_remote_cache_invalidation() {
        let (session, _requests) = recording_acknowledging_session();
        session.tree.lock().unwrap().replace(
            parse_tree(&json!({
                "workspaces": [{
                    "id": 1,
                    "active": true,
                    "screens": [{
                        "id": 2,
                        "active": true,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": [{
                            "id": 3,
                            "tabs": [
                                {"surface": 7, "title": "target"},
                                {"surface": 8, "title": "unrelated"}
                            ]
                        }]
                    }]
                }]
            })),
            0,
        );
        session.scope_events_to_surface(7).unwrap();
        session.tree_stale.store(false, Ordering::Release);
        let events = session.subscribe();

        for event in [
            json!({"event": "title-changed", "surface": 8, "title": "changed"}),
            json!({
                "event": "agent-changed",
                "surface": 8,
                "state": "working",
                "source": "hook",
                "session": null,
                "updated_at_ms": 1,
            }),
            json!({"event": "surface-output", "surface": 8}),
            json!({"event": "surface-exited", "surface": 8}),
            json!({"event": "client-list-invalidated"}),
            json!({"event": "client-attached", "client": 11, "transport": "unix"}),
            json!({"event": "notification", "notification": 12, "surface": 8}),
        ] {
            session.handle_line(event);
        }

        assert!(!session.tree_is_stale());
        assert!(events.try_iter().next().is_none());
        assert!(session.cached_agents().is_empty());
        assert_eq!(session.tree.lock().unwrap().view.surface(8).unwrap().title, "unrelated");

        session.handle_line(json!({"event": "tree-changed"}));
        assert!(session.tree_is_stale());
        assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(MuxEvent::TreeChanged)));
        session.tree_stale.store(false, Ordering::Release);

        session.handle_line(json!({"event": "layout-changed", "screen": 2}));
        assert!(session.tree_is_stale());
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::LayoutChanged(2))
        ));
        session.tree_stale.store(false, Ordering::Release);

        session.handle_line(json!({
            "event": "title-changed",
            "surface": 7,
            "title": "target changed",
        }));
        assert!(!session.tree_is_stale());
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TitleChanged { surface: 7, .. })
        ));

        session.handle_line(json!({
            "event": "agent-changed",
            "surface": 7,
            "state": "working",
            "source": "hook",
            "session": null,
            "updated_at_ms": 2,
        }));
        assert!(!session.tree_is_stale());
        assert_eq!(session.cached_agents()[0].surface, 7);
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::AgentChanged { surface: 7, .. })
        ));

        session.handle_line(json!({"event": "surface-exited", "surface": 7}));
        assert!(session.tree_is_stale());
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::SurfaceExited(7))
        ));
    }

    #[test]
    fn surface_event_scope_registers_a_filtered_server_subscription() {
        let (session, requests) = recording_acknowledging_session();

        session.scope_events_to_surface(7).unwrap();

        let request = requests.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(request.get("cmd").and_then(Value::as_str), Some("subscribe"));
        assert_eq!(request.get("surface").and_then(Value::as_u64), Some(7));
    }

    #[test]
    fn surface_event_scope_retains_events_until_the_first_local_receiver_starts() {
        let (session, _requests) = recording_acknowledging_session();

        session.scope_events_to_surface(7).unwrap();
        session.handle_line(json!({"event": "surface-exited", "surface": 7}));
        let events = session.subscribe();

        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::SurfaceExited(7))
        ));
    }

    #[test]
    fn surface_event_scope_rejects_servers_without_source_filtering() {
        let session = test_session(Box::new(UnexpectedWriteWriter));

        let error = session.scope_events_to_surface(7).unwrap_err();

        assert_eq!(
            error.to_string(),
            "remote server does not support filtered surface subscriptions"
        );
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

        assert!(cache.view.location_index.get().is_none());
        assert!(cache.update_title(4, "server title".to_string()));
        assert!(cache.view.location_index.get().is_none());
        assert_eq!(cache.view.workspaces()[0].screens[0].panes[0].tabs[0].title, "server title");
        assert_eq!(cache.view.workspaces()[1].screens[0].panes[0].tabs[0].title, "other title");
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

        assert_eq!(cache.view.workspaces()[0].screens[0].panes[0].tabs[0].title, "event title");
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

        assert_eq!(cache.view.workspaces()[0].screens[0].panes[0].tabs[0].title, "fresh snapshot");
    }

    #[test]
    fn agent_refresh_does_not_restore_an_update_for_a_removed_surface() {
        let tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "screens": [{
                    "id": 2,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [{"surface": 4, "title": "agent terminal"}],
                    }],
                }],
            }],
        }));
        let mut cache = RemoteTreeCache::default();
        cache.replace(tree, 0);
        let retired = HashSet::new();
        let refresh_generation = cache.agent_generation();
        cache.update_agent(
            AgentInfo {
                surface: 4,
                state: "working".into(),
                source: "hook".into(),
                session: Some("review".into()),
                updated_at_ms: 41,
            },
            &retired,
        );

        let title_generation = cache.title_generation();
        cache.replace(TreeView::default(), title_generation);
        cache.replace_agents(Vec::new(), refresh_generation, &retired);

        assert!(cache.agents.is_empty());
    }

    #[test]
    fn agent_refresh_does_not_resurrect_after_confirmed_omission() {
        let tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "screens": [{
                    "id": 2,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [{"surface": 4, "title": "agent terminal"}],
                    }],
                }],
            }],
        }));
        let mut cache = RemoteTreeCache::default();
        cache.replace(tree.clone(), 0);
        let retired = HashSet::new();

        // The event races the first refresh and is retained while the
        // topology omits the surface.
        let refresh_generation = cache.agent_generation();
        cache.update_agent(
            AgentInfo {
                surface: 4,
                state: "working".into(),
                source: "hook".into(),
                session: Some("review".into()),
                updated_at_ms: 41,
            },
            &retired,
        );
        cache.replace(TreeView::default(), cache.title_generation());
        cache.replace_agents(Vec::new(), refresh_generation, &retired);

        // A later refresh confirms the agent is absent. A stale topology may
        // briefly show the surface again, but the old event must not return.
        let confirmed_generation = cache.agent_generation();
        cache.replace(tree, cache.title_generation());
        cache.replace_agents(Vec::new(), confirmed_generation, &retired);

        assert!(cache.agents.is_empty());
        assert!(cache.agent_updates.is_empty());
    }

    #[test]
    fn agent_refresh_retains_updates_when_topology_temporarily_omits_surface() {
        let tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "screens": [{
                    "id": 2,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [{"surface": 4, "title": "agent terminal"}],
                    }],
                }],
            }],
        }));
        let mut cache = RemoteTreeCache::default();
        cache.replace(tree.clone(), 0);
        let retired = HashSet::new();
        let refresh_generation = cache.agent_generation();
        let update = AgentInfo {
            surface: 4,
            state: "working".into(),
            source: "hook".into(),
            session: Some("review".into()),
            updated_at_ms: 41,
        };
        cache.update_agent(update.clone(), &retired);

        // The tree response can lag the event stream and omit a live surface.
        cache.replace(TreeView::default(), cache.title_generation());
        cache.replace_agents(Vec::new(), refresh_generation, &retired);

        assert_eq!(cache.agent_updates.get(&4).map(|pending| &pending.agent), Some(&update));

        // A later topology response makes the pending event visible again.
        cache.replace(tree, cache.title_generation());
        cache.replace_agents(Vec::new(), refresh_generation, &retired);

        assert_eq!(cache.agents, vec![update]);
    }

    #[test]
    fn browser_state_without_frame_keeps_cached_frame() {
        let surface = RemoteSurface {
            id: 1,
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
            browser: Mutex::new(RemoteBrowserState::default()),
        };

        surface.update_browser_frame(&json!({
            "seq": 9,
            "width": 80,
            "height": 40,
            "data": "Zmlyc3Q=",
        }));
        assert_eq!(
            surface.browser_frame_seq(),
            None,
            "a frame event without explicit authority metadata must fail closed"
        );
        surface.update_browser_state(&json!({
            "url": "https://next.test",
            "title": "next",
            "status": "live",
            "frames_stalled": false,
        }));
        assert_eq!(surface.browser_frame_seq(), None, "missing pointer admission must fail closed");

        surface.update_browser_state(&json!({
            "url": "https://next.test",
            "title": "next",
            "status": "live",
            "frames_stalled": false,
            "pointer_frame_seq": 9,
        }));
        assert_eq!(
            surface.browser_frame_seq(),
            None,
            "state alone must not grant new authority to the cached frame"
        );
        surface.update_browser_frame(&json!({
            "seq": 9,
            "width": 80,
            "height": 40,
            "data": "Zmlyc3Q=",
            "status": "live",
            "pointer_frame_seq": 9,
        }));
        assert_eq!(surface.browser_frame_seq(), Some(9));

        surface.update_browser_state(&json!({
            "url": "https://next.test",
            "title": "next",
            "status": "live",
            "frames_stalled": false,
            "pointer_frame_seq": null,
        }));

        let frame = surface.browser_frame().expect("cached frame");
        assert_eq!(frame.seq, 9);
        assert_eq!(frame.data_b64, "Zmlyc3Q=");
        assert_eq!(
            surface.browser_frame_seq(),
            None,
            "cached display frames must not imply pointer admission"
        );
        assert_eq!(surface.browser_url().as_deref(), Some("https://next.test"));

        surface.update_browser_state(&json!({
            "url": "https://next.test",
            "title": "next",
            "status": "live",
            "frames_stalled": false,
            "pointer_frame_seq": 9,
        }));
        assert_eq!(
            surface.browser_frame_seq(),
            None,
            "restoring cached-frame input requires a paired authoritative frame event"
        );
    }

    #[test]
    fn browser_state_cannot_grant_new_authority_to_cached_pixels() {
        let surface = RemoteSurface {
            id: 1,
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
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        surface.update_browser_frame(&json!({
            "seq": 8,
            "width": 80,
            "height": 40,
            "data": "b2xk",
            "status": "live",
            "pointer_frame_seq": 8,
        }));
        surface.update_browser_state(&json!({
            "url": "https://old.test",
            "title": "same document",
            "status": "live",
            "frames_stalled": false,
            "pointer_frame_seq": 8,
        }));
        assert_eq!(
            surface.browser_frame_seq(),
            Some(8),
            "state may retain authority already paired with the cached pixels"
        );

        surface.update_browser_state(&json!({
            "url": "https://new.test",
            "title": "new document",
            "status": "live",
            "frames_stalled": false,
            "pointer_frame_seq": 9,
        }));
        assert_eq!(surface.browser_frame().map(|frame| frame.seq), Some(8));
        assert_eq!(
            surface.browser_frame_seq(),
            None,
            "state must not authorize old pixels with a token belonging to a delayed frame"
        );

        surface.update_browser_frame(&json!({
            "seq": 9,
            "width": 80,
            "height": 40,
            "data": "bmV3",
            "status": "live",
            "pointer_frame_seq": 9,
        }));
        assert_eq!(surface.browser_frame().map(|frame| frame.seq), Some(9));
        assert_eq!(surface.browser_frame_seq(), Some(9));
    }

    #[test]
    fn browser_pointer_range_does_not_authorize_unacknowledged_presentations() {
        let surface = RemoteSurface {
            id: 1,
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
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        surface.update_browser_frame(&json!({
            "seq": 9,
            "width": 80,
            "height": 40,
            "data": "bmV3",
            "status": "live",
            "pointer_frame_floor_seq": 8,
            "pointer_frame_seq": 9,
        }));

        assert!(
            !surface.browser_accepts_pointer_frame(8),
            "route membership must not imply that the client presented an older frame"
        );
        assert!(
            !surface.browser_accepts_pointer_frame(9),
            "receiving a frame must not acknowledge its presentation"
        );
        assert!(!surface.browser_accepts_pointer_frame(7));
        assert!(!surface.browser_accepts_pointer_frame(10));

        assert!(surface.acknowledge_browser_pointer_frame(8));
        assert!(surface.browser_accepts_pointer_frame(8));
        assert!(!surface.browser_accepts_pointer_frame(9));

        surface.update_browser_frame(&json!({
            "seq": 10,
            "width": 80,
            "height": 40,
            "data": "bmV3ZXN0",
            "status": "live",
            "pointer_frame_floor_seq": 8,
            "pointer_frame_seq": 10,
        }));
        assert!(
            surface.browser_accepts_pointer_frame(8),
            "receiving a repaint must preserve the exact frame still on screen"
        );
        assert!(surface.acknowledge_browser_pointer_frame(10));
        assert!(!surface.browser_accepts_pointer_frame(8));
        assert!(surface.browser_accepts_pointer_frame(10));
        assert!(
            !surface.acknowledge_browser_pointer_frame(9),
            "a delayed acknowledgement must not roll authority backward"
        );
    }

    #[test]
    fn stale_frame_does_not_restore_failed_browser_pointer_admission() {
        let surface = RemoteSurface {
            id: 1,
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
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        surface.update_browser_state(&json!({
            "url": "https://failed.test",
            "title": "browser failed: navigation failed",
            "status": "failed",
            "error": "navigation failed",
            "frames_stalled": false,
            "pointer_frame_seq": null,
        }));

        surface.update_browser_frame(&json!({
            "seq": 9,
            "width": 80,
            "height": 40,
            "data": "c3RhbGU=",
            "status": "failed",
            "error": "navigation failed",
            "pointer_frame_seq": null,
        }));

        assert!(
            matches!(surface.browser_status(), BrowserStatus::Failed(ref error) if error == "navigation failed"),
            "a stale screencast frame must not hide the authoritative navigation failure"
        );
        assert_eq!(
            surface.browser_frame_seq(),
            None,
            "a stale failed-navigation frame must remain pointer-ineligible"
        );
        assert_eq!(
            surface.browser.lock().unwrap().frame.as_ref().map(|frame| frame.frame.seq),
            Some(9),
            "the stale frame may remain cached for a later explicit recovery"
        );

        surface.update_browser_frame(&json!({
            "seq": 10,
            "width": 80,
            "height": 40,
            "data": "ZnJlc2g=",
            "status": "live",
            "error": null,
            "pointer_frame_seq": 10,
        }));
        assert_eq!(surface.browser_status(), BrowserStatus::Live);
        assert_eq!(
            surface.browser_frame_seq(),
            Some(10),
            "explicit live frame metadata must restore pointer admission"
        );
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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
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
            resizing_surface.apply_stream_resize(100, 30, None, &[]).unwrap();
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

        surface.apply_stream_resize(90, 31, None, &[]).unwrap();

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
            Some(RemoteRequestError::Rejected {
                error,
                delivery: None,
                ..
            }) if error == "injected rejection"
        ));
        assert_eq!(*session.cell_pixels.lock().unwrap(), (8, 16));
        assert_eq!(*surface.cell_pixels.lock().unwrap(), (8, 16));
    }

    #[test]
    fn timed_out_cell_pixel_request_preserves_session_and_mirror_geometry() {
        let session = test_session(Box::new(SilentWriter));
        let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
        session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

        let error = session.set_cell_pixel_size(9, 18).err().expect("silent remote must time out");

        assert!(matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Timeout)
        ));
        assert_eq!(*session.cell_pixels.lock().unwrap(), (9, 18));
        assert_eq!(*surface.cell_pixels.lock().unwrap(), (9, 18));
        assert!(session.pending.lock().unwrap().is_empty());
    }

    #[test]
    fn ambiguous_cell_pixel_timeout_does_not_overwrite_the_requested_geometry() {
        let session = test_session(Box::new(SilentWriter));
        let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
        session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

        let error = session.set_cell_pixel_size(9, 18).err().expect("silent remote must time out");

        assert!(matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Timeout)
        ));
        assert_eq!(
            *session.cell_pixels.lock().unwrap(),
            (9, 18),
            "an ambiguous timeout restored a stale global geometry mirror"
        );
        assert_eq!(
            *surface.cell_pixels.lock().unwrap(),
            (9, 18),
            "an ambiguous timeout overwrote geometry that the server may have committed"
        );
    }

    #[test]
    fn ambiguous_cell_pixel_timeout_reconciles_from_an_ordered_server_query() {
        let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
        let session =
            test_session(Box::new(AmbiguousCellPixelWriter { session: session_slot.clone() }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
        session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

        let error = session.set_cell_pixel_size(9, 18).err().expect("first reply must be lost");

        assert!(matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Timeout)
        ));
        assert_eq!(*session.cell_pixels.lock().unwrap(), (10, 20));
        assert_eq!(*surface.cell_pixels.lock().unwrap(), (11, 22));
        assert!(session.pending.lock().unwrap().is_empty());
    }

    #[test]
    fn partial_cell_pixel_fanout_retries_before_publishing_the_remote_default() {
        let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
        let session = test_session(Box::new(CellPixelFanoutWriter {
            session: session_slot.clone(),
            fail_next: true,
            deferred_failure: false,
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
        session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

        let first = session.set_cell_pixel_size(9, 18).unwrap();
        assert_eq!(first.failures, vec![(7, "injected fan-out failure".to_string())]);
        assert_eq!(*session.cell_pixels.lock().unwrap(), (8, 16));
        assert_eq!(*surface.cell_pixels.lock().unwrap(), (8, 16));

        let retried = session.set_cell_pixel_size(9, 18).unwrap();
        assert!(retried.failures.is_empty());
        assert_eq!(*session.cell_pixels.lock().unwrap(), (9, 18));
        assert_eq!(*surface.cell_pixels.lock().unwrap(), (9, 18));
    }

    #[test]
    fn deferred_cell_pixel_failure_preserves_target_for_late_resize() {
        let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
        let session = test_session(Box::new(CellPixelFanoutWriter {
            session: session_slot.clone(),
            fail_next: true,
            deferred_failure: true,
        }));
        *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
        let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
        session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

        let update = session.set_cell_pixel_size(9, 18).unwrap();
        assert_eq!(update.failures, vec![(7, "injected fan-out failure".to_string())]);
        surface.apply_stream_resize(90, 31, None, &[]).unwrap();
        let created = attached_surface(
            session.try_ensure_surface_with_kind(8, SurfaceKind::Pty, Some((80, 24))).unwrap(),
        );

        assert_eq!(
            surface.cell_pixel_size(),
            (9, 18),
            "a late authoritative resize used the geometry from before the deferred request"
        );
        assert_eq!(
            created.cell_pixel_size(),
            (9, 18),
            "a newly discovered surface used the geometry from before the deferred request"
        );
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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        {
            let mut mirror = surface.term.lock().unwrap();
            mirror.vt_write(b"mirror-only\r\nstate\r\n");
        }

        surface.apply_stream_resize(8, 4, Some(&replay), &[]).unwrap();
        let scrollback_rows = {
            let mut mirror = surface.term.lock().unwrap();
            assert_eq!(mirror.plain_text().unwrap(), server_text);
            assert_eq!(mirror.selection_text_absolute((0, 0), (4, 0)).unwrap(), server_oldest);
            mirror.scrollback_rows()
        };

        surface.apply_stream_resize(8, 4, Some(&replay), &[]).unwrap();
        let mut mirror = surface.term.lock().unwrap();
        assert_eq!(mirror.plain_text().unwrap(), server_text);
        assert_eq!(mirror.scrollback_rows(), scrollback_rows);
    }

    #[test]
    fn two_views_of_one_terminal_keep_independent_scroll_offsets() {
        let mut server = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
        for index in 0..20 {
            server.vt_write(format!("shared-{index:02}\r\n").as_bytes());
        }
        let replay = server.vt_replay_bytes().unwrap();
        let first = test_remote_pty_surface(1, 12, 4, (8, 16));
        let second = test_remote_pty_surface(2, 12, 4, (8, 16));
        first.apply_stream_resize(12, 4, Some(&replay), &[]).unwrap();
        second.apply_stream_resize(12, 4, Some(&replay), &[]).unwrap();

        first.term.lock().unwrap().scroll_delta(-5);
        let first_scrollbar = first.term.lock().unwrap().scrollbar().unwrap();
        let second_scrollbar = second.term.lock().unwrap().scrollbar().unwrap();
        assert!(first_scrollbar.scrolled_back());
        assert!(!second_scrollbar.scrolled_back());
        assert_ne!(first_scrollbar.offset, second_scrollbar.offset);
        assert_eq!(
            first.term.lock().unwrap().selection_text_absolute((0, 0), (8, 0)).unwrap(),
            second.term.lock().unwrap().selection_text_absolute((0, 0), (8, 0)).unwrap()
        );
    }

    #[test]
    fn failed_resize_alias_restore_keeps_the_previous_mirror() {
        let surface = test_remote_pty_surface(7, 12, 4, (8, 16));
        surface.term.lock().unwrap().vt_write(b"previous");
        let previous = surface.term.lock().unwrap().plain_text().unwrap();
        let mut authoritative = Terminal::new(8, 4, 100, Callbacks::default()).unwrap();
        authoritative.vt_write(b"replacement");
        let replay = authoritative.vt_replay().unwrap();

        surface
            .apply_stream_resize_with_colors(
                8,
                4,
                Some(&replay.bytes),
                &[ghostty_vt::KittyImageAlias { image_id: 999, image_number: 77 }],
                Some(replay.kitty_state),
                None,
            )
            .unwrap_err();

        let mut mirror = surface.term.lock().unwrap();
        assert_eq!(mirror.cols(), 12);
        assert_eq!(mirror.plain_text().unwrap(), previous);
    }

    #[test]
    fn malformed_resize_alias_sidecar_keeps_the_previous_mirror() {
        let session = test_session(Box::new(SilentWriter));
        let surface = test_remote_pty_surface(7, 12, 4, (8, 16));
        surface.term.lock().unwrap().vt_write(b"previous");
        let previous = surface.term.lock().unwrap().plain_text().unwrap();
        session.surfaces.lock().unwrap().insert(7, surface.clone());
        let mut authoritative = Terminal::new(8, 4, 100, Callbacks::default()).unwrap();
        authoritative.vt_write(b"replacement");
        let replay = authoritative.vt_replay_bytes().unwrap();

        session.handle_line(json!({
            "event": "resized",
            "surface": 7,
            "cols": 8,
            "rows": 4,
            "replay": base64::engine::general_purpose::STANDARD.encode(replay),
            "kitty_image_aliases": [{"image_id": 7}],
        }));

        let mut mirror = surface.term.lock().unwrap();
        assert_eq!(mirror.cols(), 12);
        assert_eq!(mirror.plain_text().unwrap(), previous);
    }

    #[test]
    fn remote_kitty_alias_sidecar_rejects_more_than_the_terminal_host_limit() {
        let aliases = (1..=cmux_tui_core::terminal_host_protocol::MAX_KITTY_IMAGE_ALIASES + 1)
            .map(|image_id| json!({"image_id": image_id, "image_number": image_id}))
            .collect::<Vec<_>>();
        let value = json!({"kitty_image_aliases": aliases});

        assert!(parse_kitty_image_aliases(&value).is_err());
    }

    #[test]
    fn remote_kitty_alias_sidecar_rejects_zero_values() {
        for alias in
            [json!({"image_id": 0, "image_number": 1}), json!({"image_id": 1, "image_number": 0})]
        {
            let value = json!({"kitty_image_aliases": [alias]});
            assert!(parse_kitty_image_aliases(&value).is_err());
        }
    }

    #[test]
    fn remote_kitty_alias_sidecar_rejects_duplicate_image_ids() {
        let value = json!({
            "kitty_image_aliases": [
                {"image_id": 7, "image_number": 41},
                {"image_id": 7, "image_number": 42},
            ],
        });

        assert!(parse_kitty_image_aliases(&value).is_err());
    }

    #[test]
    fn remote_kitty_replay_state_is_bounded_and_strict() {
        let limits = KittyGraphicsLimits::default();
        let valid = json!({
            "kitty_graphics_state": {
                "image_bytes": limits.image_bytes,
                "inflight_bytes": limits.inflight_bytes,
                "images": limits.images,
                "placements": limits.placements,
                "replay_cursor_offset": 9,
                "primary_replay_next_image_id": 41,
                "primary_next_image_id": 42,
                "alternate_replay_next_image_id": 43,
                "alternate_next_image_id": 44,
            }
        });
        assert_eq!(
            parse_kitty_replay_state(&valid).unwrap(),
            KittyReplayState {
                limits,
                replay_cursor_offset: 9,
                replay_next_image_ids: KittyImageIdCursors { primary: 41, alternate: 43 },
                next_image_ids: KittyImageIdCursors { primary: 42, alternate: 44 },
            }
        );
        assert_eq!(parse_kitty_replay_state(&json!({})).unwrap(), KittyReplayState::disabled());

        let mut oversized = valid.clone();
        oversized["kitty_graphics_state"]["image_bytes"] = json!(u64::MAX);
        assert!(parse_kitty_replay_state(&oversized).is_err());
        let mut zero_cursor = valid.clone();
        zero_cursor["kitty_graphics_state"]["alternate_next_image_id"] = json!(0);
        assert!(parse_kitty_replay_state(&zero_cursor).is_err());
        let mut extra = valid;
        extra["kitty_graphics_state"]["future"] = json!(1);
        assert!(parse_kitty_replay_state(&extra).is_err());
    }

    #[test]
    fn resized_event_preserves_the_automatic_kitty_image_id_cursor() {
        let session = test_session(Box::new(SilentWriter));
        let surface = test_remote_pty_surface(7, 12, 4, (8, 16));
        session.surfaces.lock().unwrap().insert(7, surface.clone());
        let mut authoritative = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
        authoritative.vt_write(b"\x1b_Ga=t,t=d,f=24,I=1,s=1,v=1,q=2;/wAA\x1b\\");
        let first_id = authoritative.kitty_graphics_snapshot().unwrap().images[0].id;
        authoritative.vt_write(format!("\x1b_Ga=d,d=I,i={first_id},q=2;\x1b\\").as_bytes());
        let replay = authoritative.vt_replay().unwrap();
        let state = replay.kitty_state;

        session.handle_line(json!({
            "event": "resized",
            "surface": 7,
            "cols": 12,
            "rows": 4,
            "replay": base64::engine::general_purpose::STANDARD.encode(&replay.bytes),
            "kitty_image_aliases": [],
            "kitty_graphics_state": {
                "image_bytes": state.limits.image_bytes,
                "inflight_bytes": state.limits.inflight_bytes,
                "images": state.limits.images,
                "placements": state.limits.placements,
                "replay_cursor_offset": state.replay_cursor_offset,
                "primary_replay_next_image_id": state.replay_next_image_ids.primary,
                "primary_next_image_id": state.next_image_ids.primary,
                "alternate_replay_next_image_id": state.replay_next_image_ids.alternate,
                "alternate_next_image_id": state.next_image_ids.alternate,
            },
        }));

        let next = b"\x1b_Ga=t,t=d,f=24,I=2,s=1,v=1,q=2;AP8A\x1b\\";
        authoritative.vt_write(next);
        surface.term.lock().unwrap().vt_write(next);
        assert_eq!(
            surface.term.lock().unwrap().kitty_graphics_snapshot().unwrap().images[0].id,
            authoritative.kitty_graphics_snapshot().unwrap().images[0].id
        );
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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
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
        let mirror = attached_surface(
            remote
                .try_ensure_surface_with_kind(authoritative.id, SurfaceKind::Pty, Some((20, 4)))
                .unwrap(),
        );

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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
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
    fn graphics_status_event_preserves_localization_fields() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();

        session.handle_line(json!({
            "event": "graphics-status",
            "kind": "kitty-image-budget-update-failed",
            "retry_exhausted": true,
            "summary": "surface 7: offline",
        }));

        assert!(events.try_iter().any(|event| matches!(
            event,
            MuxEvent::GraphicsStatus(
                GraphicsStatus::KittyImageBudgetUpdateFailed {
                    retry_exhausted: true,
                    summary,
                }
            ) if summary.as_ref() == "surface 7: offline"
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
        let rejected = anyhow::Error::new(RemoteRequestError::Rejected {
            error: "no capacity".to_string(),
            code: None,
            delivery: None,
        });
        let timeout = anyhow::Error::new(RemoteRequestError::Timeout);
        let shutdown = anyhow::Error::new(RemoteRequestError::Shutdown);

        assert!(RemoteSession::subscription_recovery_is_retryable(&rejected));
        assert!(!RemoteSession::subscription_recovery_is_retryable(&timeout));
        assert!(!RemoteSession::subscription_recovery_is_retryable(&shutdown));
    }

    fn test_remote_surface(id: SurfaceId) -> Arc<RemoteSurface> {
        Arc::new(RemoteSurface {
            id,
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
        })
    }

    #[cfg(unix)]
    #[test]
    fn surface_exit_event_retires_the_mirror_before_tree_refresh() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.surfaces.lock().unwrap().insert(7, test_remote_surface(7));

        session.handle_line(json!({"event": "surface-exited", "surface": 7}));

        assert!(!session.has_surface(7));
        assert!(session.surface_is_exited(7));
        assert!(session.tree_is_stale());
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::SurfaceExited(7))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn surface_overflow_invalidates_mirror_and_requests_reattach() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.surfaces.lock().unwrap().insert(7, test_remote_surface(7));

        session.handle_line(json!({
            "event": "overflow",
            "scope": "surface",
            "surface": 7,
            "error": "surface stream fell behind",
        }));

        assert!(!session.has_surface(7));
        assert!(!session.retired_surfaces.lock().unwrap().contains(&7));
        let received = events.try_iter().collect::<Vec<_>>();
        assert!(received.iter().any(|event| matches!(event, MuxEvent::SurfaceOutput(7))));
        assert!(received.iter().any(|event| matches!(event, MuxEvent::Status(_))));
    }

    #[test]
    fn overflow_backoff_defers_attach_without_claiming_surface_retirement() {
        let closed = Arc::new(AtomicBool::new(false));
        let session = test_session(Box::new(CloseTrackingWriter { closed }));
        session.surface_overflow_recovery.lock().unwrap().insert(
            7,
            SurfaceOverflowRecovery {
                attempts: 1,
                retry_after: Some(Instant::now() + Duration::from_secs(1)),
                attached_at: None,
                stopped: false,
            },
        );

        let outcome =
            session.try_ensure_surface_with_kind(7, SurfaceKind::Pty, Some((80, 24))).unwrap();

        assert!(matches!(outcome, RemoteSurfaceAttach::Deferred));
        assert!(!session.retired_surfaces.lock().unwrap().contains(&7));
        assert!(!session.has_surface(7));
        assert!(session.pending.lock().unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn duplicate_surface_overflow_does_not_advance_recovery() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.surfaces.lock().unwrap().insert(7, test_remote_surface(7));
        let overflow = json!({
            "event": "overflow",
            "scope": "surface",
            "surface": 7,
            "error": "surface stream fell behind",
        });

        session.handle_line(overflow.clone());
        let _ = events.try_iter().collect::<Vec<_>>();
        session.handle_line(overflow);

        assert_eq!(session.surface_overflow_recovery.lock().unwrap().get(&7).unwrap().attempts, 1);
        assert!(events.try_iter().next().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn fabricated_surface_overflow_does_not_allocate_recovery_state() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();

        session.handle_line(json!({
            "event": "overflow",
            "scope": "surface",
            "surface": 9_999,
            "error": "fabricated",
        }));

        assert!(session.surface_overflow_recovery.lock().unwrap().is_empty());
        assert!(events.try_iter().next().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn zero_surface_overflow_is_ignored_even_if_zero_is_attached() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        session.surfaces.lock().unwrap().insert(0, test_remote_surface(0));

        session.handle_line(json!({
            "event": "overflow",
            "scope": "surface",
            "surface": 0,
            "error": "invalid zero surface",
        }));

        assert!(session.has_surface(0));
        assert!(session.surface_overflow_recovery.lock().unwrap().is_empty());
        assert!(events.try_iter().next().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn surface_overflow_capacity_requires_one_bounded_reconnect() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let events = session.subscribe();
        let maximum = u64::try_from(MAX_SURFACE_OVERFLOW_RECOVERIES).unwrap();
        {
            let mut recoveries = session.surface_overflow_recovery.lock().unwrap();
            for id in 1..=maximum {
                recoveries.insert(
                    id,
                    SurfaceOverflowRecovery {
                        attempts: 1,
                        retry_after: Some(Instant::now() + Duration::from_secs(1)),
                        attached_at: None,
                        stopped: false,
                    },
                );
            }
        }
        let overflow_surface = maximum + 1;
        session
            .surfaces
            .lock()
            .unwrap()
            .insert(overflow_surface, test_remote_surface(overflow_surface));

        session.handle_line(json!({
            "event": "overflow",
            "scope": "surface",
            "surface": overflow_surface,
            "error": "recovery capacity",
        }));

        assert_eq!(
            session.surface_overflow_recovery.lock().unwrap().len(),
            MAX_SURFACE_OVERFLOW_RECOVERIES
        );
        assert!(session.surface_overflow_reconnect_required.load(Ordering::Acquire));
        assert!(!session.can_attach_after_overflow(1));
        assert!(!session.surface_overflow_retry_due());
        let first = events.try_iter().collect::<Vec<_>>();
        assert_eq!(first.iter().filter(|event| matches!(event, MuxEvent::Status(_))).count(), 1);

        let next_surface = overflow_surface + 1;
        session.surfaces.lock().unwrap().insert(next_surface, test_remote_surface(next_surface));
        session.handle_line(json!({
            "event": "overflow",
            "scope": "surface",
            "surface": next_surface,
            "error": "already reconnecting",
        }));
        assert!(
            events.try_iter().all(|event| !matches!(event, MuxEvent::Status(_))),
            "reconnect-required status repeated"
        );
    }

    #[cfg(unix)]
    #[test]
    fn stable_surface_recoveries_are_pruned_before_capacity() {
        let (client, _server) = UnixStream::pair().unwrap();
        let session = socket_test_session(client);
        let maximum = u64::try_from(MAX_SURFACE_OVERFLOW_RECOVERIES).unwrap();
        {
            let mut recoveries = session.surface_overflow_recovery.lock().unwrap();
            for id in 1..=maximum {
                recoveries.insert(
                    id,
                    SurfaceOverflowRecovery {
                        attempts: 3,
                        retry_after: None,
                        attached_at: Some(Instant::now() - SURFACE_OVERFLOW_STABLE),
                        stopped: false,
                    },
                );
            }
        }
        let overflow_surface = maximum + 1;
        session
            .surfaces
            .lock()
            .unwrap()
            .insert(overflow_surface, test_remote_surface(overflow_surface));

        session.handle_line(json!({
            "event": "overflow",
            "scope": "surface",
            "surface": overflow_surface,
            "error": "after stable recovery",
        }));

        assert_eq!(session.surface_overflow_recovery.lock().unwrap().len(), 1);
        assert!(!session.surface_overflow_reconnect_required.load(Ordering::Acquire));
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
            cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
            dirty: AtomicBool::new(false),
            geometry_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            geometry_test_hook: Mutex::new(None),
            content_generation: AtomicU64::new(1),
            reported_size: Mutex::new(None),
            browser: Mutex::new(RemoteBrowserState::default()),
        };
        surface.apply_stream_resize(12, 3, None, &[]).unwrap();
        surface.term.lock().unwrap().vt_write(&stale_replay);
        surface.apply_stream_resize(10, 3, Some(&resize_replay), &[]).unwrap();
        let mut mirror = surface.term.lock().unwrap();
        mirror.vt_write(prompt);

        assert_eq!(mirror.plain_text().unwrap(), server_text);
    }
}
