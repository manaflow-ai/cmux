//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard, RwLock, RwLockReadGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::browser::{self, BrowserBootstrap, BrowserPresentationMode, BrowserRuntime};
use crate::event_bus::{MuxEventBroadcaster, MuxEventReceiver};
use crate::frontend_native_browser::{
    FrontendNativeBrowserClaimReceipt, FrontendNativeBrowserOwner, FrontendNativeBrowserRegistry,
    FrontendNativeBrowserSourceReceipt,
};
use crate::identity::EntityIdentityAllocator;
use crate::layout::{Rect, layout_screen};
use crate::model::{ChangeState, Node, Pane, Screen, State, Workspace};
use crate::pairing::PairingBroker;
use crate::presentation::PresentationRegistry;
use crate::projection_state::ProjectionStateRegistry;
use crate::remote_tmux_producer::{
    ExternalTerminalProvenance, RemoteTmuxProducerClaimReceipt, RemoteTmuxProducerOwner,
    RemoteTmuxProducerRegistry, RemoteTmuxProducerSource, RemoteTmuxProducerSourceUpdateReceipt,
};
use crate::renderer_control::{
    RendererColorSpace, RendererControlDirection, RendererControlEncoder, RendererControlMessage,
    RendererFrameRelease, RendererPixelFormat, RendererPresentationAttachment,
    RendererPresentationReady, RendererPresentationRemoval, RendererSemanticScene,
};
use crate::renderer_supervisor::{
    RendererSupervisor, RendererSupervisorConfig, RendererSupervisorError, RendererSupervisorEvent,
    RendererWorkerState, RendererWorkerStatus,
};
use crate::semantic_scene::{
    SemanticSceneAttachmentOptions, SemanticSceneCaptureOptions, SemanticSceneControl,
    SemanticSceneEvent, SemanticSceneFrame, SemanticScenePreedit,
    SemanticScenePresentationIdentity, SemanticSceneReceiver,
};
use crate::state_store::{
    DurableSession, MAX_PERSISTED_IDEMPOTENCY_RESULTS, MAX_PERSISTED_TOMBSTONES,
    PersistedEntityKind, PersistedIdempotencyResult, PersistedLaunchRecipe, PersistedNode,
    PersistedPane, PersistedScreen, PersistedSessionState, PersistedSplitDirection,
    PersistedSurface, PersistedSurfaceKind, PersistedTombstone, PersistedWorkspace, StateStore,
};
use crate::surface::{
    DefaultColors, ExternalTerminalClaimReceipt, ExternalTerminalOutputReceipt,
    ExternalTerminalOwner, InputAuthorityPermit, Surface, SurfaceOptions,
    TerminalLaunchCompletionPhase,
};
use crate::terminal_activity::{
    LEGACY_TERMINAL_ACTIVITY_READER_UUID, NotificationLevel, TerminalActivityFact,
    TerminalActivityReadReceipt, TerminalActivitySnapshot, TerminalActivityState,
};
use crate::terminal_authority::{
    TerminalAuthorityRegistry, TerminalLease, TerminalLeaseClaim, TerminalLeaseKind,
};
use crate::topology::{TopologyJournal, topology_json};
use crate::{
    DaemonInstanceId, PairingChallenge, PairingDecision, PairingError, PaneId, PaneUuid, ScreenId,
    ScreenUuid, SessionId, SplitDir, SurfaceId, SurfaceUuid, TopologyLimits, TopologyOperation,
    TopologyResume, TopologySnapshot, TopologyTargets, WorkspaceId, WorkspaceUuid,
};

pub type SurfaceResizeReporter = Arc<dyn Fn(SurfaceId, (u16, u16), Option<u64>) + Send + Sync>;

const TERMINAL_DIMENSION_MAX: u16 = 10_000;
const TERMINAL_INITIAL_INPUT_DEADLINE: Duration = Duration::from_secs(30);

fn terminal_initial_input_deadline() -> Duration {
    #[cfg(test)]
    if let Ok(milliseconds) = std::env::var("CMUX_TEST_TERMINAL_INITIAL_INPUT_DEADLINE_MS")
        && let Ok(milliseconds) = milliseconds.parse::<u64>()
    {
        return Duration::from_millis(milliseconds.max(1));
    }
    TERMINAL_INITIAL_INPUT_DEADLINE
}

pub(crate) fn clamp_terminal_size(cols: u16, rows: u16) -> (u16, u16) {
    (cols.clamp(1, TERMINAL_DIMENSION_MAX), rows.clamp(1, TERMINAL_DIMENSION_MAX))
}

#[derive(Debug, Default)]
pub struct CellPixelUpdate {
    pub resizes: Vec<(SurfaceId, (u16, u16), u64)>,
    pub failures: Vec<CellPixelUpdateFailure>,
}

#[derive(Debug)]
pub struct CellPixelUpdateFailure {
    pub surface: SurfaceId,
    pub error: String,
}

/// Events pushed to subscribed frontends.
#[derive(Debug, Clone)]
pub enum MuxEvent {
    /// New output arrived in a surface (coalesced; cleared when rendered).
    SurfaceOutput(SurfaceId),
    /// A surface's runtime changed size.
    SurfaceResized {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        reservation_id: Option<u64>,
    },
    /// An asynchronous browser resize failed after queue acceptance.
    SurfaceResizeFailed {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        error: Arc<str>,
        retry_after_ms: Option<u64>,
        reservation_id: Option<u64>,
    },
    /// A surface's child exited. The mux removes ordinary surfaces before
    /// delivery; wait-after-command surfaces remain until explicit close.
    SurfaceExited(SurfaceId),
    TitleChanged {
        surface: SurfaceId,
        title: Arc<str>,
    },
    Bell(SurfaceId),
    Notification(NotificationEvent),
    /// One canonical persisted terminal activity fact.
    TerminalActivity(TerminalActivityFact),
    /// One canonical persisted per-reader read receipt.
    TerminalActivityReceipt(TerminalActivityReadReceipt),
    Status(String),
    /// One per-workspace renderer process changed lifetime or readiness.
    RendererWorkerChanged {
        workspace_uuid: WorkspaceUuid,
        prior_renderer_epoch: u64,
        prior_process_id: Option<u32>,
        status: Option<RendererWorkerStatus>,
        reason: Option<Arc<str>>,
    },
    RendererPresentationReady {
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
        process_id: u32,
        effective_user_id: u32,
        metrics: RendererPresentationReady,
    },
    /// Presentation-owned theme configuration must be rebuilt before another
    /// renderer frame is considered current.
    RendererConfigInvalidated {
        revision: u64,
        reason: Arc<str>,
        default_colors: DefaultColors,
    },
    /// A frontend should reload its local mux configuration and redraw.
    ConfigReloadRequested,
    /// A frontend should set its host terminal window title. Empty clears it.
    WindowTitleRequested(String),
    /// A PTY surface viewport moved within its scrollback.
    ScrollChanged {
        surface: SurfaceId,
        offset: u64,
        at_bottom: bool,
    },
    /// The workspace/screen/pane/tab tree changed (from any frontend or
    /// the control socket).
    TreeChanged,
    /// One protocol-v7 lifecycle mutation. Coarse subscribers project this
    /// back to the legacy `tree-changed` event.
    TreeDelta(TreeDelta),
    /// A screen's pane geometry changed. Clients should re-fetch layout.
    LayoutChanged(ScreenId),
    /// A control connection attached its first surface.
    ClientAttached {
        client: u64,
        transport: String,
        name: Option<String>,
        kind: Option<String>,
    },
    /// A control connection updated its display metadata.
    ClientChanged {
        client: u64,
        name: Option<String>,
        kind: Option<String>,
    },
    /// A control connection ended.
    ClientDetached(u64),
    /// A recovered event subscription may have missed client lifecycle
    /// events, so consumers must reload the authoritative client list.
    ClientListInvalidated,
    /// An unauthenticated browser is waiting for a trusted TUI decision.
    PairingRequested(PairingChallenge),
    /// A pairing request was approved, denied, disconnected, or expired.
    PairingResolved {
        request: u64,
    },
    /// Every workspace is gone.
    Empty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TreeDeltaKind {
    WorkspaceAdded,
    WorkspaceClosed,
    WorkspaceRenamed,
    ScreenAdded,
    ScreenClosed,
    ScreenRenamed,
    PaneAdded,
    PaneClosed,
    TabAdded,
    TabClosed,
    TabRenamed,
}

impl TreeDeltaKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WorkspaceAdded => "workspace-added",
            Self::WorkspaceClosed => "workspace-closed",
            Self::WorkspaceRenamed => "workspace-renamed",
            Self::ScreenAdded => "screen-added",
            Self::ScreenClosed => "screen-closed",
            Self::ScreenRenamed => "screen-renamed",
            Self::PaneAdded => "pane-added",
            Self::PaneClosed => "pane-closed",
            Self::TabAdded => "tab-added",
            Self::TabClosed => "tab-closed",
            Self::TabRenamed => "tab-renamed",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TreeDelta {
    pub kind: TreeDeltaKind,
    pub workspace: WorkspaceId,
    pub screen: Option<ScreenId>,
    pub pane: Option<PaneId>,
    pub surface: Option<SurfaceId>,
    pub index: Option<usize>,
    pub entity: Value,
}

#[derive(Debug, Clone)]
pub struct NotificationEvent {
    pub notification: u64,
    pub title: String,
    pub body: String,
    pub level: NotificationLevel,
    pub surface: Option<SurfaceId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Working,
    Blocked,
    Idle,
    Done,
    Unknown,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentState::Working => "working",
            AgentState::Blocked => "blocked",
            AgentState::Idle => "idle",
            AgentState::Done => "done",
            AgentState::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone)]
pub struct LayoutLeafSpec {
    pub cwd: Option<String>,
    pub command: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub enum LayoutSpec {
    Leaf(LayoutLeafSpec),
    Split { dir: SplitDir, ratio: f32, a: Box<LayoutSpec>, b: Box<LayoutSpec> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoomMode {
    Toggle,
    On,
    Off,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    fn delta(self) -> (i32, i32) {
        match self {
            Direction::Left => (-1, 0),
            Direction::Right => (1, 0),
            Direction::Up => (0, -1),
            Direction::Down => (0, 1),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentSource {
    Detected,
    Socket,
    Hook,
}

impl AgentSource {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentSource::Detected => "detected",
            AgentSource::Socket => "socket",
            AgentSource::Hook => "hook",
        }
    }
}

#[derive(Debug, Clone)]
pub struct AgentRecord {
    pub surface: SurfaceId,
    pub state: AgentState,
    pub source: AgentSource,
    pub session: Option<String>,
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct SurfaceNotification {
    pub notification: u64,
    pub level: NotificationLevel,
    pub unread: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct RunPlacement {
    pub surface: SurfaceId,
    pub pane: PaneId,
    pub screen: ScreenId,
    pub workspace: WorkspaceId,
}

#[derive(Clone)]
pub(crate) struct EnsureTerminalRequest {
    pub workspace_uuid: WorkspaceUuid,
    pub surface_uuid: SurfaceUuid,
    pub cwd: Option<String>,
    pub argv: Option<Vec<String>>,
    pub env: Vec<(String, String)>,
    pub initial_input: Option<String>,
    pub wait_after_command: bool,
    pub cols: u16,
    pub rows: u16,
}

const MAX_ENSURE_TERMINAL_BATCH_SIZE: usize = 1_024;
const MAX_ENSURE_TERMINAL_INITIAL_INPUT_BYTES: usize = 1024 * 1024;
const MAX_TERMINAL_LAUNCH_ARGUMENTS: usize = 1_024;
const MAX_TERMINAL_LAUNCH_ENVIRONMENT: usize = 1_024;
const MAX_TERMINAL_LAUNCH_STRING_BYTES: usize = 64 * 1024;
const MAX_TERMINAL_LAUNCH_CWD_BYTES: usize = 16 * 1024;
const MAX_TERMINAL_LAUNCH_ENVIRONMENT_NAME_BYTES: usize = 4 * 1024;
const MAX_TERMINAL_LAUNCH_AGGREGATE_BYTES: usize = 2 * 1024 * 1024;
const TERMINAL_INITIAL_INPUT_CANONICAL_LINE_MAX_BYTES: usize = 512;

fn validate_terminal_initial_input(label: &str, input: &str) -> anyhow::Result<()> {
    let mut line_bytes = 0;
    for byte in input.bytes() {
        line_bytes += 1;
        if line_bytes > TERMINAL_INITIAL_INPUT_CANONICAL_LINE_MAX_BYTES {
            anyhow::bail!(
                "{label} contains a line longer than the canonical-safe maximum of \
                 {TERMINAL_INITIAL_INPUT_CANONICAL_LINE_MAX_BYTES} bytes including newline"
            );
        }
        if byte == b'\n' {
            line_bytes = 0;
        }
    }
    Ok(())
}

fn validate_ensure_terminal_request(request: &EnsureTerminalRequest) -> anyhow::Result<()> {
    if request.workspace_uuid.as_uuid().is_nil() || request.surface_uuid.as_uuid().is_nil() {
        anyhow::bail!("ensure-terminal UUIDs must be nonzero");
    }
    if request.cols == 0 || request.rows == 0 {
        anyhow::bail!("ensure-terminal columns and rows must be nonzero");
    }
    if request.argv.as_ref().is_some_and(Vec::is_empty) {
        anyhow::bail!("ensure-terminal argv must be non-empty when supplied");
    }
    if request.env.iter().any(|(name, value)| {
        name.is_empty()
            || name.contains(['=', '\0'])
            || value.contains('\0')
            || crate::launch_gate::is_reserved_environment_name(name)
    }) {
        anyhow::bail!("ensure-terminal environment contains an invalid name or value");
    }
    if request
        .initial_input
        .as_ref()
        .is_some_and(|input| input.len() > MAX_ENSURE_TERMINAL_INITIAL_INPUT_BYTES)
    {
        anyhow::bail!(
            "ensure-terminal initial_input exceeds {MAX_ENSURE_TERMINAL_INITIAL_INPUT_BYTES} bytes"
        );
    }
    if let Some(initial_input) = request.initial_input.as_deref() {
        validate_terminal_initial_input("ensure-terminal initial_input", initial_input)?;
    }
    Ok(())
}

fn validate_terminal_launch_request(request: &TerminalLaunchRequest) -> anyhow::Result<()> {
    if request.argv.is_some() && request.command.is_some() {
        anyhow::bail!("terminal launch argv and command are mutually exclusive");
    }
    if request.argv.as_ref().is_some_and(Vec::is_empty) {
        anyhow::bail!("terminal launch argv must be non-empty when supplied");
    }
    if request.command.as_ref().is_some_and(|command| command.is_empty()) {
        anyhow::bail!("terminal launch command must be non-empty when supplied");
    }
    if request.argv.as_ref().is_some_and(|argv| argv.len() > MAX_TERMINAL_LAUNCH_ARGUMENTS) {
        anyhow::bail!("terminal launch argv exceeds {MAX_TERMINAL_LAUNCH_ARGUMENTS} arguments");
    }
    if request.env.len() > MAX_TERMINAL_LAUNCH_ENVIRONMENT {
        anyhow::bail!(
            "terminal launch environment exceeds {MAX_TERMINAL_LAUNCH_ENVIRONMENT} entries"
        );
    }
    if let Some(cwd) = &request.cwd {
        validate_terminal_launch_text("cwd", cwd, MAX_TERMINAL_LAUNCH_CWD_BYTES)?;
    }
    if let Some(command) = &request.command {
        validate_terminal_launch_text("command", command, MAX_TERMINAL_LAUNCH_STRING_BYTES)?;
    }
    if let Some(argv) = &request.argv {
        for argument in argv {
            validate_terminal_launch_text(
                "argv entry",
                argument,
                MAX_TERMINAL_LAUNCH_STRING_BYTES,
            )?;
        }
    }
    for (name, value) in &request.env {
        if !valid_terminal_environment_name(name) {
            anyhow::bail!("terminal launch environment contains an invalid name");
        }
        if crate::launch_gate::is_reserved_environment_name(name) {
            anyhow::bail!("terminal launch environment contains a reserved launch-gate name");
        }
        validate_terminal_launch_text(
            "environment name",
            name,
            MAX_TERMINAL_LAUNCH_ENVIRONMENT_NAME_BYTES,
        )?;
        validate_terminal_launch_text(
            "environment value",
            value,
            MAX_TERMINAL_LAUNCH_STRING_BYTES,
        )?;
    }
    if request
        .initial_input
        .as_ref()
        .is_some_and(|input| input.len() > MAX_ENSURE_TERMINAL_INITIAL_INPUT_BYTES)
    {
        anyhow::bail!(
            "terminal launch initial_input exceeds {MAX_ENSURE_TERMINAL_INITIAL_INPUT_BYTES} bytes"
        );
    }
    if let Some(initial_input) = request.initial_input.as_deref() {
        validate_terminal_initial_input("terminal launch initial_input", initial_input)?;
    }
    let aggregate_bytes = request.cwd.as_ref().map_or(0, String::len)
        + request.command.as_ref().map_or(0, String::len)
        + request.argv.as_ref().map_or(0, |argv| argv.iter().map(String::len).sum())
        + request.env.iter().map(|(name, value)| name.len() + value.len()).sum::<usize>()
        + request.initial_input.as_ref().map_or(0, String::len);
    if aggregate_bytes > MAX_TERMINAL_LAUNCH_AGGREGATE_BYTES {
        anyhow::bail!(
            "terminal launch payload exceeds {MAX_TERMINAL_LAUNCH_AGGREGATE_BYTES} bytes"
        );
    }
    Ok(())
}

fn validate_terminal_launch_text(
    field: &str,
    value: &str,
    maximum_bytes: usize,
) -> anyhow::Result<()> {
    if value.contains('\0') {
        anyhow::bail!("terminal launch {field} contains NUL");
    }
    if value.len() > maximum_bytes {
        anyhow::bail!("terminal launch {field} exceeds {maximum_bytes} bytes");
    }
    Ok(())
}

fn validate_browser_url(url: &str) -> anyhow::Result<()> {
    if url.is_empty() {
        anyhow::bail!("browser URL must not be empty");
    }
    validate_terminal_launch_text("browser URL", url, MAX_TERMINAL_LAUNCH_STRING_BYTES)
}

fn valid_terminal_environment_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    matches!(bytes.next(), Some(b'A'..=b'Z' | b'a'..=b'z' | b'_'))
        && bytes.all(|byte| matches!(byte, b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_'))
}

fn canonical_payload_digest<T: Serialize>(operation: &str, payload: &T) -> anyhow::Result<String> {
    let encoded = serde_json::to_vec(&(operation, payload))?;
    let bytes = Sha256::digest(encoded);
    let mut result = String::with_capacity(bytes.len() * 2);
    use std::fmt::Write as _;
    for byte in bytes {
        write!(&mut result, "{byte:02x}").expect("writing into String cannot fail");
    }
    Ok(result)
}

fn canonical_split_direction(dir: SplitDir) -> &'static str {
    match dir {
        SplitDir::Right => "right",
        SplitDir::Down => "down",
    }
}

fn canonical_digest_from_key(key: &str) -> Option<&str> {
    let mut components = key.rsplit(':');
    let _request_id = components.next()?;
    let digest = components.next()?;
    (key.starts_with("canonical:") && digest.len() == 64).then_some(digest)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct EnsureTerminalPlacement {
    pub created: bool,
    pub workspace: WorkspaceId,
    pub workspace_uuid: WorkspaceUuid,
    pub screen: ScreenId,
    pub screen_uuid: ScreenUuid,
    pub pane: PaneId,
    pub pane_uuid: PaneUuid,
    pub surface: SurfaceId,
    pub surface_uuid: SurfaceUuid,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub(crate) struct TerminalLaunchRequest {
    pub cwd: Option<String>,
    pub argv: Option<Vec<String>>,
    pub command: Option<String>,
    pub env: Vec<(String, String)>,
    pub initial_input: Option<String>,
    pub wait_after_command: bool,
}

enum PreparedTerminalGate {
    Real(crate::launch_gate::TerminalLaunchGate),
    #[cfg(test)]
    Test,
}

struct PreparedTerminalLaunch {
    surface: Arc<Surface>,
    launch: Option<PersistedLaunchRecipe>,
    gate: Option<PreparedTerminalGate>,
    input_authority: Option<InputAuthorityPermit>,
    initial_input: Vec<u8>,
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TerminalLaunchAtomicityPhase {
    BeforeFsync,
    AfterFsync,
    BeforeRelease,
    AfterRelease,
    AfterInitialInput,
}

#[cfg(test)]
type TerminalLaunchAtomicityProbe = Arc<dyn Fn(TerminalLaunchAtomicityPhase) + Send + Sync>;

/// Fences one canonical topology mutation to an exact daemon snapshot and
/// supplies the durable key used to replay retries without applying twice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CanonicalMutationExpectation {
    pub daemon_instance_id: DaemonInstanceId,
    pub session_id: SessionId,
    pub expected_revision: u64,
    pub request_id: uuid::Uuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CanonicalMutationReceipt {
    pub request_id: uuid::Uuid,
    pub daemon_instance_id: DaemonInstanceId,
    pub session_id: SessionId,
    pub base_revision: u64,
    pub revision: u64,
    pub replayed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CanonicalSurfacePlacement {
    pub receipt: CanonicalMutationReceipt,
    pub workspace: WorkspaceId,
    pub workspace_uuid: WorkspaceUuid,
    pub screen: ScreenId,
    pub screen_uuid: ScreenUuid,
    pub pane: PaneId,
    pub pane_uuid: PaneUuid,
    pub surface: SurfaceId,
    pub surface_uuid: SurfaceUuid,
}

enum CanonicalMutationStart {
    Fresh { key: String },
    Replay { receipt: CanonicalMutationReceipt, result: PersistedIdempotencyResult },
}

#[derive(Debug, Clone, Copy)]
struct EnsureTerminalWorkspaceLocation {
    workspace: WorkspaceId,
    screen: ScreenId,
    screen_uuid: ScreenUuid,
    pane: PaneId,
    pane_uuid: PaneUuid,
    new_workspace: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ReparentTerminalPlacement {
    pub moved: bool,
    pub workspace: WorkspaceId,
    pub workspace_uuid: WorkspaceUuid,
    pub screen: ScreenId,
    pub screen_uuid: ScreenUuid,
    pub pane: PaneId,
    pub pane_uuid: PaneUuid,
    pub surface: SurfaceId,
    pub surface_uuid: SurfaceUuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppliedPane {
    pub pane: PaneId,
    pub surface: SurfaceId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedLayout {
    pub screen: ScreenId,
    pub panes: Vec<AppliedPane>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZoomState {
    pub pane: PaneId,
    pub zoomed: bool,
    pub zoomed_pane: Option<PaneId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarPluginOptions {
    pub command: Vec<String>,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SidebarPluginStatus {
    pub surface: Option<SurfaceId>,
    pub error: Option<String>,
    pub retry_after: Option<Duration>,
}

#[derive(Debug, Default)]
struct SidebarPluginRuntime {
    options: Option<SidebarPluginOptions>,
    surface: Option<SurfaceId>,
    last_error: Option<String>,
    failures: u32,
    retry_at: Option<Instant>,
}

enum BrowserSurfaceAttach {
    MissingPane,
    Attached(Option<TreeDelta>),
}

type ClientSurfaceSizes = HashMap<SurfaceId, HashMap<u64, (u16, u16)>>;
type SurfaceResizeAcceptance = (bool, Option<u64>);
type AppliedClientSize = (SurfaceResizeAcceptance, Option<(u16, u16)>);

#[derive(Default)]
struct LatestClientSize {
    size: Option<(u16, u16)>,
    from_report: bool,
}

#[derive(Default)]
struct ClientSizingState {
    surfaces: ClientSurfaceSizes,
    report_order: HashMap<(SurfaceId, u64), u64>,
    next_report_order: u64,
    excluded_clients: HashSet<u64>,
    exclusive_client: Option<u64>,
}

impl ClientSizingState {
    fn client_participates(&self, client: u64) -> bool {
        self.exclusive_client.map_or_else(
            || !self.excluded_clients.contains(&client),
            |exclusive| exclusive == client,
        )
    }

    fn uses_excluded_fallback(&self, attached_clients: &HashSet<u64>) -> bool {
        let attached_participates =
            attached_clients.iter().any(|client| self.client_participates(*client));
        let reporter_participates = self
            .surfaces
            .values()
            .any(|viewers| viewers.keys().any(|client| self.client_participates(*client)));
        !attached_participates && !reporter_participates
    }

    fn effective_size(&self, surface: SurfaceId, use_excluded: bool) -> Option<(u16, u16)> {
        self.surfaces
            .get(&surface)?
            .iter()
            .filter(|(client, _)| use_excluded || self.client_participates(**client))
            .map(|(_, size)| *size)
            .reduce(|smallest, size| (smallest.0.min(size.0), smallest.1.min(size.1)))
    }

    fn effective_sizes(
        &self,
        surfaces: impl IntoIterator<Item = SurfaceId>,
        use_excluded: bool,
    ) -> Vec<(SurfaceId, (u16, u16))> {
        let mut effective = surfaces
            .into_iter()
            .filter_map(|surface| {
                self.effective_size(surface, use_excluded).map(|size| (surface, size))
            })
            .collect::<Vec<_>>();
        effective.sort_unstable_by_key(|(surface, _)| *surface);
        effective
    }

    fn latest_effective_size(&self, attached_clients: &HashSet<u64>) -> Option<(u16, u16)> {
        let use_excluded = self.uses_excluded_fallback(attached_clients);
        let surface = self
            .report_order
            .iter()
            .filter(|((surface, client), _)| {
                self.surfaces.get(surface).is_some_and(|viewers| viewers.contains_key(client))
                    && (use_excluded || self.client_participates(*client))
            })
            .max_by_key(|(_, order)| *order)
            .map(|((surface, _), _)| *surface)?;
        self.effective_size(surface, use_excluded)
    }
}

#[derive(Clone, Copy)]
enum CloseTreeTarget {
    Surface(SurfaceId),
    Pane(PaneId),
    Screen(ScreenId),
    Workspace(WorkspaceId),
}

struct ClosedTree {
    surface_ids: Vec<SurfaceId>,
    removed: Vec<Arc<Surface>>,
    changed_screens: Vec<ScreenId>,
    empty: bool,
    delta: Option<TreeDelta>,
}

#[cfg(test)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct CanonicalTopologyIndexBuildCounts {
    workspace_visits: usize,
    screen_visits: usize,
    pane_visits: usize,
    surface_visits: usize,
    tab_visits: usize,
}

#[derive(Default)]
struct CanonicalTopologyIndex {
    workspace_index_by_uuid: HashMap<WorkspaceUuid, usize>,
    screen_location_by_pane: HashMap<PaneId, (usize, usize)>,
    pane_by_surface: HashMap<SurfaceId, PaneId>,
    surface_id_by_uuid: HashMap<SurfaceUuid, SurfaceId>,
    #[cfg(test)]
    build_counts: CanonicalTopologyIndexBuildCounts,
}

impl CanonicalTopologyIndex {
    fn build(state: &State) -> anyhow::Result<Self> {
        let mut index = Self::default();
        let mut workspace_ids = HashSet::new();
        let mut screen_ids = HashSet::new();
        let mut screen_uuids = HashSet::new();
        let mut pane_uuids = HashSet::new();

        for (workspace_index, workspace) in state.workspaces.iter().enumerate() {
            #[cfg(test)]
            {
                index.build_counts.workspace_visits += 1;
            }
            if !workspace_ids.insert(workspace.id)
                || index.workspace_index_by_uuid.insert(workspace.uuid, workspace_index).is_some()
            {
                anyhow::bail!("canonical topology contains a duplicate workspace identity");
            }
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                #[cfg(test)]
                {
                    index.build_counts.screen_visits += 1;
                }
                if !screen_ids.insert(screen.id) || !screen_uuids.insert(screen.uuid) {
                    anyhow::bail!("canonical topology contains a duplicate screen identity");
                }
                let mut pane_ids = Vec::new();
                screen.root.pane_ids(&mut pane_ids);
                for pane_id in pane_ids {
                    if !state.panes.contains_key(&pane_id) {
                        anyhow::bail!("canonical screen references missing pane {pane_id}");
                    }
                    if index
                        .screen_location_by_pane
                        .insert(pane_id, (workspace_index, screen_index))
                        .is_some()
                    {
                        anyhow::bail!("canonical pane {pane_id} appears in multiple screens");
                    }
                }
            }
        }

        for (pane_id, pane) in &state.panes {
            #[cfg(test)]
            {
                index.build_counts.pane_visits += 1;
            }
            if *pane_id != pane.id || !pane_uuids.insert(pane.uuid) {
                anyhow::bail!("canonical topology contains a duplicate pane identity");
            }
            for surface_id in &pane.tabs {
                #[cfg(test)]
                {
                    index.build_counts.tab_visits += 1;
                }
                if !state.surfaces.contains_key(surface_id) {
                    anyhow::bail!("canonical pane references missing surface {surface_id}");
                }
                if index.pane_by_surface.insert(*surface_id, *pane_id).is_some() {
                    anyhow::bail!("canonical surface {surface_id} appears in multiple panes");
                }
            }
        }

        for (surface_id, surface) in &state.surfaces {
            #[cfg(test)]
            {
                index.build_counts.surface_visits += 1;
            }
            if *surface_id != surface.id
                || index.surface_id_by_uuid.insert(surface.uuid, *surface_id).is_some()
            {
                anyhow::bail!("canonical topology contains a duplicate surface identity");
            }
        }
        Ok(index)
    }
}

struct CanonicalState {
    value: State,
    topology_index: CanonicalTopologyIndex,
    /// Protocol-v7 revision for the complete legacy `list-workspaces` tree,
    /// including global focus, selection, and zoom state.
    legacy_topology_revision: u64,
    topology: TopologyJournal,
    launch_recipes: HashMap<SurfaceUuid, PersistedLaunchRecipe>,
    tombstones: VecDeque<PersistedTombstone>,
    idempotency_results: VecDeque<PersistedIdempotencyResult>,
    terminal_activity: TerminalActivityState,
    durable: Option<DurableSession>,
    #[cfg(test)]
    topology_commit_count: u64,
    #[cfg(test)]
    topology_replacement_serialization_count: u64,
    #[cfg(test)]
    persisted_snapshot_count: u64,
    #[cfg(test)]
    topology_index_rebuild_count: u64,
    #[cfg(test)]
    terminal_launch_atomicity_probe: Option<TerminalLaunchAtomicityProbe>,
}

impl CanonicalState {
    fn new(
        value: State,
        daemon_instance_id: DaemonInstanceId,
        session_id: SessionId,
        limits: TopologyLimits,
        topology_revision: u64,
    ) -> Self {
        let topology_index = CanonicalTopologyIndex::build(&value)
            .expect("initial canonical topology must have valid lookup indexes");
        Self {
            value,
            topology_index,
            legacy_topology_revision: 0,
            topology: if topology_revision == 0 {
                TopologyJournal::new(daemon_instance_id, session_id, limits)
            } else {
                TopologyJournal::new_at_revision(
                    daemon_instance_id,
                    session_id,
                    limits,
                    topology_revision,
                )
            },
            launch_recipes: HashMap::new(),
            tombstones: VecDeque::new(),
            idempotency_results: VecDeque::new(),
            terminal_activity: TerminalActivityState::default(),
            durable: None,
            #[cfg(test)]
            topology_commit_count: 0,
            #[cfg(test)]
            topology_replacement_serialization_count: 0,
            #[cfg(test)]
            persisted_snapshot_count: 0,
            #[cfg(test)]
            topology_index_rebuild_count: 1,
            #[cfg(test)]
            terminal_launch_atomicity_probe: None,
        }
    }

    fn rebuild_topology_index(&mut self) -> anyhow::Result<()> {
        self.topology_index = CanonicalTopologyIndex::build(&self.value)?;
        #[cfg(test)]
        {
            self.topology_index_rebuild_count += 1;
        }
        Ok(())
    }

    fn indexed_workspace_index_by_uuid(&self, uuid: WorkspaceUuid) -> Option<usize> {
        self.topology_index.workspace_index_by_uuid.get(&uuid).copied()
    }

    fn indexed_surface_id_by_uuid(&self, uuid: SurfaceUuid) -> Option<SurfaceId> {
        self.topology_index.surface_id_by_uuid.get(&uuid).copied()
    }

    fn indexed_pane_of(&self, surface: SurfaceId) -> Option<PaneId> {
        self.topology_index.pane_by_surface.get(&surface).copied()
    }

    fn indexed_screen_of(&self, pane: PaneId) -> Option<(usize, usize)> {
        self.topology_index.screen_location_by_pane.get(&pane).copied()
    }

    fn commit_legacy_topology(&mut self) -> u64 {
        self.legacy_topology_revision = self
            .legacy_topology_revision
            .checked_add(1)
            .expect("legacy topology revision exhausted");
        self.persist(self.topology.revision(), format!("legacy:{}", uuid::Uuid::new_v4()), None);
        self.legacy_topology_revision
    }

    /// Commit state, revision, retained history, and live delivery as one
    /// transaction while the canonical state mutex is held.
    fn commit_topology(
        &mut self,
        operation: TopologyOperation,
        targets: TopologyTargets,
    ) -> Arc<crate::TopologyDelta> {
        self.commit_topology_with_idempotency(
            operation,
            targets,
            format!("topology:{}", uuid::Uuid::new_v4()),
        )
    }

    /// Shared durable seam for a future protocol transaction carrying a
    /// caller-supplied idempotency key. Existing command handlers still call
    /// `commit_topology`, which mints a unique internal key.
    fn commit_topology_with_idempotency(
        &mut self,
        operation: TopologyOperation,
        targets: TopologyTargets,
        key: String,
    ) -> Arc<crate::TopologyDelta> {
        self.rebuild_topology_index()
            .expect("committed canonical topology must have valid lookup indexes");
        #[cfg(test)]
        {
            self.topology_commit_count += 1;
        }
        let live_terminals = self
            .value
            .surfaces
            .values()
            .filter(|surface| surface.kind() == crate::SurfaceKind::Pty)
            .map(|surface| surface.uuid)
            .collect::<BTreeSet<_>>();
        self.launch_recipes.retain(|uuid, _| live_terminals.contains(uuid));
        self.legacy_topology_revision = self
            .legacy_topology_revision
            .checked_add(1)
            .expect("legacy topology revision exhausted");
        let revision =
            self.topology.revision().checked_add(1).expect("canonical topology revision exhausted");
        self.retain_deleted_targets(operation, &targets, revision);
        let result = PersistedIdempotencyResult {
            key: key.clone(),
            payload_digest: canonical_digest_from_key(&key).unwrap_or_default().to_string(),
            committed_topology_revision: revision,
            workspaces: targets.workspaces.clone(),
            screens: targets.screens.clone(),
            panes: targets.panes.clone(),
            surfaces: targets.surfaces.clone(),
        };
        self.idempotency_results.push_back(result.clone());
        while self.idempotency_results.len() > MAX_PERSISTED_IDEMPOTENCY_RESULTS {
            self.idempotency_results.pop_front();
        }
        self.persist(revision, key, Some(result));
        #[cfg(test)]
        {
            self.topology_replacement_serialization_count += 1;
        }
        let replacement = topology_json(&self.value);
        self.topology.commit(replacement, operation, targets)
    }

    fn persist(
        &mut self,
        topology_revision: u64,
        idempotency_key: String,
        result: Option<PersistedIdempotencyResult>,
    ) {
        if self.durable.is_none() {
            return;
        }
        #[cfg(test)]
        {
            self.persisted_snapshot_count += 1;
        }
        let snapshot = self
            .persisted_snapshot(topology_revision)
            .expect("canonical state must remain persistable after a committed mutation");
        #[cfg(test)]
        if let Some(probe) = &self.terminal_launch_atomicity_probe {
            probe(TerminalLaunchAtomicityPhase::BeforeFsync);
        }
        self.durable
            .as_mut()
            .expect("durable session checked above")
            .append(snapshot, idempotency_key, result)
            .unwrap_or_else(|error| {
                // Mutation handlers run on detached connection threads. A
                // panic would only poison the mutex while leaving a live
                // socket and daemon lock behind, so fail the whole process
                // before any handler can acknowledge undurable state.
                eprintln!("cmux-tui: fatal canonical persistence failure: {error}");
                std::process::abort();
            });
        #[cfg(test)]
        if let Some(probe) = &self.terminal_launch_atomicity_probe {
            probe(TerminalLaunchAtomicityPhase::AfterFsync);
        }
    }

    fn retain_deleted_targets(
        &mut self,
        operation: TopologyOperation,
        targets: &TopologyTargets,
        revision: u64,
    ) {
        if !matches!(
            operation,
            TopologyOperation::SurfaceClosed
                | TopologyOperation::PaneClosed
                | TopologyOperation::ScreenClosed
                | TopologyOperation::WorkspaceClosed
        ) {
            return;
        }
        let mut deleted = Vec::new();
        for uuid in &targets.workspaces {
            if self.value.workspace_id_by_uuid(*uuid).is_none() {
                deleted.push((PersistedEntityKind::Workspace, uuid.as_uuid()));
            }
        }
        for uuid in &targets.screens {
            if self.value.screen_id_by_uuid(*uuid).is_none() {
                deleted.push((PersistedEntityKind::Screen, uuid.as_uuid()));
            }
        }
        for uuid in &targets.panes {
            if self.value.pane_id_by_uuid(*uuid).is_none() {
                deleted.push((PersistedEntityKind::Pane, uuid.as_uuid()));
            }
        }
        for uuid in &targets.surfaces {
            if self.value.surface_id_by_uuid(*uuid).is_none() {
                deleted.push((PersistedEntityKind::Surface, uuid.as_uuid()));
            }
        }
        for (kind, uuid) in deleted {
            self.tombstones.retain(|existing| existing.kind != kind || existing.uuid != uuid);
            self.tombstones.push_back(PersistedTombstone {
                kind,
                uuid,
                removed_at_topology_revision: revision,
            });
        }
        while self.tombstones.len() > MAX_PERSISTED_TOMBSTONES {
            self.tombstones.pop_front();
        }
    }

    fn persisted_snapshot(&self, topology_revision: u64) -> anyhow::Result<PersistedSessionState> {
        persisted_snapshot(self, topology_revision)
    }

    fn persist_terminal_activity(&mut self, key: &str) {
        self.persist(
            self.topology.revision(),
            format!("terminal-activity:{key}:{}", uuid::Uuid::new_v4()),
            None,
        );
    }

    fn discard_surface_runtime(&mut self, id: SurfaceId) -> Option<Arc<Surface>> {
        let removed = self.value.surfaces.remove(&id);
        if let Some(surface) = &removed {
            self.launch_recipes.remove(&surface.uuid);
            if self.topology_index.surface_id_by_uuid.get(&surface.uuid) == Some(&id) {
                self.topology_index.surface_id_by_uuid.remove(&surface.uuid);
            }
            self.topology_index.pane_by_surface.remove(&id);
        }
        removed
    }
}

fn persisted_snapshot(
    canonical: &CanonicalState,
    topology_revision: u64,
) -> anyhow::Result<PersistedSessionState> {
    let state = &canonical.value;
    let active_workspace = if state.workspaces.is_empty() {
        None
    } else {
        Some(
            state
                .workspaces
                .get(state.active_workspace)
                .ok_or_else(|| anyhow::anyhow!("active workspace index is outside topology"))?
                .uuid,
        )
    };
    let mut pane_order = Vec::new();
    let mut seen_panes = BTreeSet::new();
    let mut workspaces = Vec::with_capacity(state.workspaces.len());
    for workspace in &state.workspaces {
        if workspace.screens.is_empty() || workspace.active_screen >= workspace.screens.len() {
            anyhow::bail!("workspace {} has an invalid active screen", workspace.uuid);
        }
        let mut screens = Vec::with_capacity(workspace.screens.len());
        for screen in &workspace.screens {
            collect_persisted_pane_order(&screen.root, state, &mut pane_order, &mut seen_panes)?;
            let active_pane = state
                .panes
                .get(&screen.active_pane)
                .ok_or_else(|| anyhow::anyhow!("screen {} has a missing active pane", screen.uuid))?
                .uuid;
            let zoomed_pane = screen
                .zoomed_pane
                .map(|pane| {
                    state.panes.get(&pane).map(|pane| pane.uuid).ok_or_else(|| {
                        anyhow::anyhow!("screen {} has a missing zoom pane", screen.uuid)
                    })
                })
                .transpose()?;
            screens.push(PersistedScreen {
                uuid: screen.uuid,
                name: screen.name.clone(),
                root: persisted_node(&screen.root, state)?,
                active_pane,
                zoomed_pane,
            });
        }
        workspaces.push(PersistedWorkspace {
            uuid: workspace.uuid,
            name: workspace.name.clone(),
            screens,
            active_screen: workspace.active_screen,
        });
    }

    let mut panes = Vec::with_capacity(pane_order.len());
    let mut surface_order = Vec::new();
    let mut seen_surfaces = BTreeSet::new();
    for pane_id in pane_order {
        let pane = state
            .panes
            .get(&pane_id)
            .ok_or_else(|| anyhow::anyhow!("split tree references missing pane {pane_id}"))?;
        if pane.tabs.is_empty() || pane.active_tab >= pane.tabs.len() {
            anyhow::bail!("pane {} has an invalid active tab", pane.uuid);
        }
        let tabs = pane
            .tabs
            .iter()
            .map(|surface_id| {
                let surface = state.surfaces.get(surface_id).ok_or_else(|| {
                    anyhow::anyhow!("pane {} references missing surface", pane.uuid)
                })?;
                if !seen_surfaces.insert(surface.uuid) {
                    anyhow::bail!("surface {} appears in more than one tab slot", surface.uuid);
                }
                surface_order.push(*surface_id);
                Ok(surface.uuid)
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        panes.push(PersistedPane {
            uuid: pane.uuid,
            name: pane.name.clone(),
            tabs,
            active_tab: pane.active_tab,
            active_at: pane.active_at,
        });
    }

    let mut surfaces = Vec::with_capacity(surface_order.len());
    for surface_id in surface_order {
        let surface = state
            .surfaces
            .get(&surface_id)
            .ok_or_else(|| anyhow::anyhow!("ordered surface disappeared during snapshot"))?;
        let kind = match surface.kind() {
            crate::SurfaceKind::Pty if surface.is_external_terminal() => {
                let (cols, rows, scrollback, no_reflow) = surface
                    .external_terminal_recipe()
                    .expect("external terminal reports its durable recipe");
                PersistedSurfaceKind::ExternalTerminal {
                    cols,
                    rows,
                    scrollback,
                    no_reflow,
                    provenance: surface.external_terminal_provenance(),
                }
            }
            crate::SurfaceKind::Pty => PersistedSurfaceKind::Terminal {
                launch: canonical.launch_recipes.get(&surface.uuid).cloned().ok_or_else(|| {
                    anyhow::anyhow!("terminal {} has no durable launch recipe", surface.uuid)
                })?,
            },
            crate::SurfaceKind::Browser => PersistedSurfaceKind::Browser {
                presentation: match surface
                    .as_browser()
                    .expect("browser kind has browser runtime")
                    .presentation_mode()
                {
                    BrowserPresentationMode::DaemonRendered => {
                        crate::state_store::PersistedBrowserPresentationMode::DaemonRendered
                    }
                    BrowserPresentationMode::FrontendNative => {
                        crate::state_store::PersistedBrowserPresentationMode::FrontendNative
                    }
                },
            },
        };
        surfaces.push(PersistedSurface { uuid: surface.uuid, name: surface.name(), kind });
    }

    Ok(PersistedSessionState {
        session_id: canonical.topology.session_id(),
        topology_revision,
        active_workspace,
        workspaces,
        panes,
        surfaces,
        tombstones: canonical.tombstones.iter().cloned().collect(),
        idempotency_results: canonical.idempotency_results.iter().cloned().collect(),
        activity_sequence: canonical.terminal_activity.latest_sequence(),
        activity_facts: canonical.terminal_activity.persisted_facts(),
        activity_receipts: canonical.terminal_activity.persisted_receipts(),
    })
}

fn collect_persisted_pane_order(
    node: &Node,
    state: &State,
    order: &mut Vec<PaneId>,
    seen: &mut BTreeSet<PaneUuid>,
) -> anyhow::Result<()> {
    match node {
        Node::Leaf(pane_id) => {
            let pane = state
                .panes
                .get(pane_id)
                .ok_or_else(|| anyhow::anyhow!("split tree references missing pane {pane_id}"))?;
            if !seen.insert(pane.uuid) {
                anyhow::bail!("pane {} appears more than once in split trees", pane.uuid);
            }
            order.push(*pane_id);
        }
        Node::Split { a, b, .. } => {
            collect_persisted_pane_order(a, state, order, seen)?;
            collect_persisted_pane_order(b, state, order, seen)?;
        }
    }
    Ok(())
}

fn persisted_node(node: &Node, state: &State) -> anyhow::Result<PersistedNode> {
    match node {
        Node::Leaf(pane_id) => Ok(PersistedNode::Leaf {
            pane_uuid: state
                .panes
                .get(pane_id)
                .ok_or_else(|| anyhow::anyhow!("split tree references missing pane {pane_id}"))?
                .uuid,
        }),
        Node::Split { dir, ratio, a, b } => Ok(PersistedNode::Split {
            direction: match dir {
                SplitDir::Right => PersistedSplitDirection::Horizontal,
                SplitDir::Down => PersistedSplitDirection::Vertical,
            },
            ratio: *ratio,
            first: Box::new(persisted_node(a, state)?),
            second: Box::new(persisted_node(b, state)?),
        }),
    }
}

fn restored_node(
    node: &PersistedNode,
    pane_ids: &BTreeMap<PaneUuid, PaneId>,
) -> anyhow::Result<Node> {
    match node {
        PersistedNode::Leaf { pane_uuid } => {
            Ok(Node::Leaf(pane_ids.get(pane_uuid).copied().ok_or_else(|| {
                anyhow::anyhow!("split tree references unknown pane {pane_uuid}")
            })?))
        }
        PersistedNode::Split { direction, ratio, first, second } => Ok(Node::Split {
            dir: match direction {
                PersistedSplitDirection::Horizontal => SplitDir::Right,
                PersistedSplitDirection::Vertical => SplitDir::Down,
            },
            ratio: *ratio,
            a: Box::new(restored_node(first, pane_ids)?),
            b: Box::new(restored_node(second, pane_ids)?),
        }),
    }
}

impl Deref for CanonicalState {
    type Target = State;

    fn deref(&self) -> &Self::Target {
        &self.value
    }
}

impl DerefMut for CanonicalState {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.value
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalSnapshot<T> {
    pub topology_revision: u64,
    pub state: T,
}

#[derive(Clone)]
pub(crate) struct RendererPresentationConfiguration {
    pub width: u32,
    pub height: u32,
    pub backing_scale_factor: f64,
    pub columns: u16,
    pub rows: u16,
    pub pixel_format: RendererPixelFormat,
    pub color_space: RendererColorSpace,
    pub frame_endpoint_service: String,
    pub frame_endpoint_capability: Vec<u8>,
    pub resolved_config_revision: u64,
    pub resolved_config: Vec<u8>,
    pub focused: bool,
    pub cursor_blink_visible: bool,
    pub preedit: Option<RendererPreedit>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RendererPreedit {
    pub text: String,
    pub selection_start_utf16: u32,
    pub selection_length_utf16: u32,
    pub caret_utf16: u32,
}

impl RendererPreedit {
    fn semantic(&self) -> SemanticScenePreedit {
        SemanticScenePreedit {
            text: Arc::<str>::from(self.text.clone()),
            selection_start_utf16: self.selection_start_utf16,
            selection_length_utf16: self.selection_length_utf16,
            caret_utf16: self.caret_utf16,
        }
    }
}

pub(crate) struct RendererPresentationReceipt {
    pub daemon_instance_id: DaemonInstanceId,
    pub worker: RendererWorkerStatus,
    pub terminal_id: SurfaceUuid,
    pub terminal_epoch: u64,
    pub presentation_id: crate::PresentationId,
    pub canonical_presentation_generation: u64,
    pub renderer_presentation_generation: u64,
    pub minimum_content_sequence: u64,
    pub width: u32,
    pub height: u32,
    pub backing_scale_factor: f64,
    pub columns: u16,
    pub rows: u16,
    pub pixel_format: RendererPixelFormat,
    pub color_space: RendererColorSpace,
}

struct RendererSceneBinding {
    control: SemanticSceneControl,
    canceled: Arc<AtomicBool>,
    renderer_epoch: u64,
}

struct RendererPresentationRuntime {
    client: u64,
    workspace_uuid: WorkspaceUuid,
    surface: Arc<Surface>,
    attachment: RendererPresentationAttachment,
    capture: SemanticSceneCaptureOptions,
    preedit: Mutex<Option<RendererPreedit>>,
    scene: Mutex<RendererSceneBinding>,
    bound_renderer_epoch: Mutex<u64>,
}

impl RendererPresentationRuntime {
    /// Linearizes the configure path with an asynchronous WorkerReady event.
    /// Exactly one caller may bind a presentation to a given worker epoch.
    fn claim_renderer_epoch(&self, renderer_epoch: u64) -> Option<MutexGuard<'_, u64>> {
        claim_new_renderer_epoch(&self.bound_renderer_epoch, renderer_epoch)
    }
}

fn claim_new_renderer_epoch(
    bound_renderer_epoch: &Mutex<u64>,
    renderer_epoch: u64,
) -> Option<MutexGuard<'_, u64>> {
    if renderer_epoch == 0 {
        return None;
    }
    let mut current = bound_renderer_epoch.lock().unwrap();
    if *current >= renderer_epoch {
        return None;
    }
    *current = renderer_epoch;
    Some(current)
}

#[derive(Default)]
struct RendererPresentationWorkspaceIndex {
    presentation_ids: BTreeMap<WorkspaceUuid, BTreeSet<crate::PresentationId>>,
    #[cfg(test)]
    rehydration_presentation_visits: usize,
}

impl RendererPresentationWorkspaceIndex {
    fn insert(&mut self, workspace_uuid: WorkspaceUuid, presentation_id: crate::PresentationId) {
        self.presentation_ids.entry(workspace_uuid).or_default().insert(presentation_id);
    }

    fn remove(&mut self, workspace_uuid: WorkspaceUuid, presentation_id: crate::PresentationId) {
        let remove_workspace =
            self.presentation_ids.get_mut(&workspace_uuid).is_some_and(|presentations| {
                presentations.remove(&presentation_id);
                presentations.is_empty()
            });
        if remove_workspace {
            self.presentation_ids.remove(&workspace_uuid);
        }
    }

    fn get(&self, workspace_uuid: WorkspaceUuid) -> Option<&BTreeSet<crate::PresentationId>> {
        self.presentation_ids.get(&workspace_uuid)
    }

    fn presentation_ids_for_rehydration(
        &mut self,
        workspace_uuid: WorkspaceUuid,
    ) -> Vec<crate::PresentationId> {
        let presentation_ids = self
            .presentation_ids
            .get(&workspace_uuid)
            .into_iter()
            .flatten()
            .copied()
            .collect::<Vec<_>>();
        #[cfg(test)]
        {
            self.rehydration_presentation_visits += presentation_ids.len();
        }
        presentation_ids
    }

    fn clear(&mut self) {
        self.presentation_ids.clear();
    }
}

#[derive(Default)]
struct RendererPresentationRuntimes {
    by_id: BTreeMap<crate::PresentationId, Arc<RendererPresentationRuntime>>,
    by_workspace: RendererPresentationWorkspaceIndex,
}

impl RendererPresentationRuntimes {
    fn insert(
        &mut self,
        presentation_id: crate::PresentationId,
        runtime: Arc<RendererPresentationRuntime>,
    ) -> Option<Arc<RendererPresentationRuntime>> {
        let previous = self.by_id.insert(presentation_id, runtime.clone());
        if let Some(previous) = &previous {
            self.by_workspace.remove(previous.workspace_uuid, presentation_id);
        }
        self.by_workspace.insert(runtime.workspace_uuid, presentation_id);
        self.debug_assert_consistent();
        previous
    }

    fn get(
        &self,
        presentation_id: &crate::PresentationId,
    ) -> Option<&Arc<RendererPresentationRuntime>> {
        self.by_id.get(presentation_id)
    }

    fn remove(
        &mut self,
        presentation_id: &crate::PresentationId,
    ) -> Option<Arc<RendererPresentationRuntime>> {
        let runtime = self.by_id.remove(presentation_id)?;
        self.by_workspace.remove(runtime.workspace_uuid, *presentation_id);
        self.debug_assert_consistent();
        Some(runtime)
    }

    fn remove_if_current(
        &mut self,
        presentation_id: crate::PresentationId,
        runtime: &Arc<RendererPresentationRuntime>,
    ) -> Option<Arc<RendererPresentationRuntime>> {
        if !self.by_id.get(&presentation_id).is_some_and(|current| Arc::ptr_eq(current, runtime)) {
            return None;
        }
        self.remove(&presentation_id)
    }

    fn runtimes_for_workspace(
        &mut self,
        workspace_uuid: WorkspaceUuid,
    ) -> Vec<Arc<RendererPresentationRuntime>> {
        self.by_workspace
            .presentation_ids_for_rehydration(workspace_uuid)
            .into_iter()
            .filter_map(|presentation_id| self.by_id.get(&presentation_id).cloned())
            .collect()
    }

    fn take_all(&mut self) -> Vec<Arc<RendererPresentationRuntime>> {
        self.by_workspace.clear();
        std::mem::take(&mut self.by_id).into_values().collect()
    }

    fn iter(
        &self,
    ) -> impl Iterator<Item = (&crate::PresentationId, &Arc<RendererPresentationRuntime>)> {
        self.by_id.iter()
    }

    fn debug_assert_consistent(&self) {
        debug_assert_eq!(
            self.by_id.len(),
            self.by_workspace.presentation_ids.values().map(BTreeSet::len).sum::<usize>()
        );
        debug_assert!(self.by_id.iter().all(|(presentation_id, runtime)| {
            self.by_workspace
                .get(runtime.workspace_uuid)
                .is_some_and(|presentations| presentations.contains(presentation_id))
        }));
    }
}

const MAX_RENDERER_RELEASE_ROUTES: usize = 8_192;
const RENDERER_SCENE_PUMP_POLL: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct RendererReleaseRouteKey {
    presentation_id: crate::PresentationId,
    presentation_generation: u64,
    renderer_epoch: u64,
}

#[derive(Debug, Clone, Copy)]
struct RendererReleaseRoute {
    client: u64,
    workspace_uuid: WorkspaceUuid,
    terminal_id: SurfaceUuid,
    terminal_epoch: u64,
}

#[derive(Default)]
struct RendererReleaseRoutes {
    values: BTreeMap<RendererReleaseRouteKey, RendererReleaseRoute>,
    insertion_order: VecDeque<RendererReleaseRouteKey>,
}

impl RendererReleaseRoutes {
    fn insert(&mut self, key: RendererReleaseRouteKey, route: RendererReleaseRoute) {
        if self.values.insert(key, route).is_none() {
            self.insertion_order.push_back(key);
        }
        while self.values.len() > MAX_RENDERER_RELEASE_ROUTES {
            if let Some(retired) = self.insertion_order.pop_front() {
                self.values.remove(&retired);
            }
        }
    }
}

fn presentation_id_from_uuid(value: uuid::Uuid) -> crate::PresentationId {
    value.to_string().parse().expect("wire UUID is a valid presentation identity")
}

fn surface_uuid_from_uuid(value: uuid::Uuid) -> SurfaceUuid {
    value.to_string().parse().expect("wire UUID is a valid surface identity")
}

fn renderer_semantic_scene(frame: &SemanticSceneFrame) -> RendererSemanticScene {
    RendererSemanticScene {
        terminal_id: frame.terminal.terminal_id.as_uuid(),
        terminal_epoch: frame.terminal.runtime_epoch,
        presentation_id: frame.presentation.presentation_id.as_uuid(),
        presentation_generation: frame.presentation.generation,
        canonical_sequence: frame.content_sequence,
        presentation_sequence: frame.presentation_sequence,
        bytes: frame.as_bytes().to_vec(),
    }
}

fn resolved_custom_shader_count(config: &[u8]) -> anyhow::Result<u32> {
    let text = std::str::from_utf8(config)
        .map_err(|error| anyhow::anyhow!("resolved renderer config is not UTF-8: {error}"))?;
    let count = text
        .lines()
        .filter(|line| {
            line.split_once('=').is_some_and(|(key, value)| {
                key.trim() == "custom-shader" && !value.trim().is_empty()
            })
        })
        .count();
    u32::try_from(count)
        .map_err(|_| anyhow::anyhow!("resolved renderer config has too many custom shaders"))
}

fn ensure_terminal_placement_for_surface(
    state: &CanonicalState,
    workspace_uuid: WorkspaceUuid,
    surface_uuid: SurfaceUuid,
    created: bool,
) -> anyhow::Result<Option<EnsureTerminalPlacement>> {
    let Some(surface_id) = state.indexed_surface_id_by_uuid(surface_uuid) else {
        return Ok(None);
    };
    let surface = state
        .surfaces
        .get(&surface_id)
        .ok_or_else(|| anyhow::anyhow!("ensure-terminal surface runtime is missing"))?;
    if surface.semantic_scene_terminal_identity().is_none() {
        anyhow::bail!("ensure-terminal surface UUID belongs to a browser");
    }
    let pane_id = state
        .indexed_pane_of(surface_id)
        .ok_or_else(|| anyhow::anyhow!("ensure-terminal surface is outside canonical topology"))?;
    let pane = state
        .panes
        .get(&pane_id)
        .ok_or_else(|| anyhow::anyhow!("ensure-terminal pane is missing"))?;
    let (workspace_index, screen_index) = state
        .indexed_screen_of(pane_id)
        .ok_or_else(|| anyhow::anyhow!("ensure-terminal pane is outside canonical topology"))?;
    let workspace = &state.workspaces[workspace_index];
    if workspace.uuid != workspace_uuid {
        anyhow::bail!(
            "ensure-terminal surface UUID belongs to workspace {}, not {}",
            workspace.uuid,
            workspace_uuid
        );
    }
    let screen = &workspace.screens[screen_index];
    Ok(Some(EnsureTerminalPlacement {
        created,
        workspace: workspace.id,
        workspace_uuid: workspace.uuid,
        screen: screen.id,
        screen_uuid: screen.uuid,
        pane: pane.id,
        pane_uuid: pane.uuid,
        surface: surface.id,
        surface_uuid: surface.uuid,
    }))
}

fn canonical_surface_placement_for_uuid(
    state: &CanonicalState,
    surface_uuid: SurfaceUuid,
    receipt: CanonicalMutationReceipt,
) -> anyhow::Result<CanonicalSurfacePlacement> {
    let surface = state
        .indexed_surface_id_by_uuid(surface_uuid)
        .ok_or_else(|| anyhow::anyhow!("canonical mutation result surface is no longer live"))?;
    let pane = state
        .indexed_pane_of(surface)
        .ok_or_else(|| anyhow::anyhow!("canonical mutation result surface has no pane"))?;
    let pane_uuid = state
        .panes
        .get(&pane)
        .map(|pane| pane.uuid)
        .ok_or_else(|| anyhow::anyhow!("canonical mutation result pane is missing"))?;
    let (workspace_index, screen_index) = state
        .indexed_screen_of(pane)
        .ok_or_else(|| anyhow::anyhow!("canonical mutation result pane has no screen"))?;
    let workspace = &state.workspaces[workspace_index];
    let screen = &workspace.screens[screen_index];
    Ok(CanonicalSurfacePlacement {
        receipt,
        workspace: workspace.id,
        workspace_uuid: workspace.uuid,
        screen: screen.id,
        screen_uuid: screen.uuid,
        pane,
        pane_uuid,
        surface,
        surface_uuid,
    })
}

fn ensure_terminal_workspace_location(
    state: &CanonicalState,
    workspace_uuid: WorkspaceUuid,
) -> anyhow::Result<Option<EnsureTerminalWorkspaceLocation>> {
    let Some(workspace_index) = state.indexed_workspace_index_by_uuid(workspace_uuid) else {
        return Ok(None);
    };
    let workspace = &state.workspaces[workspace_index];
    let screen = workspace
        .screens
        .get(workspace.active_screen)
        .ok_or_else(|| anyhow::anyhow!("ensure-terminal workspace has no active screen"))?;
    let pane = state
        .panes
        .get(&screen.active_pane)
        .ok_or_else(|| anyhow::anyhow!("ensure-terminal active pane is missing"))?;
    Ok(Some(EnsureTerminalWorkspaceLocation {
        workspace: workspace.id,
        screen: screen.id,
        screen_uuid: screen.uuid,
        pane: pane.id,
        pane_uuid: pane.uuid,
        new_workspace: false,
    }))
}

/// The multiplexer. Shared by frontends and the control socket server.
pub struct Mux {
    state: Mutex<CanonicalState>,
    subscribers: MuxEventBroadcaster,
    entity_ids: EntityIdentityAllocator,
    next_notification_id: AtomicU64,
    next_active_at: AtomicU64,
    surface_options: Mutex<SurfaceOptions>,
    latest_client_size: Mutex<LatestClientSize>,
    terminal_control_lifecycle: RwLock<()>,
    client_sizing_lifecycle: Mutex<()>,
    client_sizing: Mutex<ClientSizingState>,
    #[cfg(test)]
    client_resize_before_apply: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    browser_runtime: Mutex<Option<Arc<BrowserRuntime>>>,
    frontend_native_browsers: FrontendNativeBrowserRegistry,
    remote_tmux_producers: RemoteTmuxProducerRegistry,
    cell_pixels: Mutex<(u16, u16)>,
    default_colors: Mutex<(u64, DefaultColors)>,
    sidebar_plugin: Mutex<SidebarPluginRuntime>,
    agent_records: Mutex<HashMap<SurfaceId, AgentRecord>>,
    pub(crate) control_clients: crate::server::ClientRegistry,
    pub(crate) presentations: PresentationRegistry,
    pub(crate) projection_states: ProjectionStateRegistry,
    pub(crate) terminal_authority: TerminalAuthorityRegistry,
    renderer_supervisor: Mutex<Option<Arc<RendererSupervisor>>>,
    renderer_presentations: Mutex<RendererPresentationRuntimes>,
    renderer_presentation_generations: Mutex<BTreeMap<crate::PresentationId, u64>>,
    renderer_release_routes: Mutex<RendererReleaseRoutes>,
    ensure_terminal_lock: Mutex<()>,
    pairing: PairingBroker,
    #[cfg(test)]
    test_surface_runtime: bool,
    #[cfg(test)]
    test_surface_registered_barriers:
        Mutex<Option<(Arc<std::sync::Barrier>, Arc<std::sync::Barrier>)>>,
    #[cfg(test)]
    ensure_terminal_initial_writes: AtomicU64,
    #[cfg(test)]
    terminal_launch_gate_releases: AtomicU64,
    #[cfg(test)]
    ensure_terminal_batch_fail_spawn_at: AtomicU64,
    #[cfg(test)]
    ensure_terminal_batch_before_publish: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    canonical_split_tab_fail_after_split: AtomicBool,
    #[cfg(test)]
    canonical_browser_fail_before_commit: AtomicBool,
    pub session: String,
    pub daemon_instance_id: DaemonInstanceId,
    pub session_id: SessionId,
}

impl Mux {
    pub fn new(session: impl Into<String>, surface_options: SurfaceOptions) -> Arc<Self> {
        Self::new_with_session_id(session, surface_options, SessionId::new())
    }

    /// Construct a mux for a known persistent session identity. Persistence
    /// loaders can reuse `session_id`; every constructed mux still receives a
    /// fresh daemon instance identity.
    pub fn new_with_session_id(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        session_id: SessionId,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(session, surface_options, session_id, false)
    }

    /// Recover one canonical session under a daemon-lifetime state-store lock.
    /// Persisted terminals are respawned from redacted launch recipes with
    /// their stable UUIDs, fresh operating-system PIDs, and fresh runtime
    /// epochs. No old PID is serialized or reported as live.
    pub fn recover_from_state_store(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        store: &StateStore,
    ) -> anyhow::Result<Arc<Self>> {
        Self::recover_from_state_store_with_runtime(session, surface_options, store, false)
    }

    fn recover_from_state_store_with_runtime(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        store: &StateStore,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> anyhow::Result<Arc<Self>> {
        let session = session.into();
        let opened = store.open_session(&session)?;
        let snapshot = opened.snapshot;
        let mux = Self::new_with_test_surface_runtime_limits_and_revision(
            session,
            surface_options,
            snapshot.session_id,
            test_surface_runtime,
            TopologyLimits::default(),
            snapshot.topology_revision,
        );
        // Restored children can exit before their pane attachments are
        // published. Install the journal writer first so the final reap after
        // attachment durably records that closure.
        mux.state.lock().unwrap().durable = Some(opened.durable);
        mux.restore_persisted_state(snapshot)?;
        Ok(mux)
    }

    #[cfg(test)]
    fn recover_from_state_store_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        store: &StateStore,
    ) -> anyhow::Result<Arc<Self>> {
        Self::recover_from_state_store_with_runtime(session, surface_options, store, true)
    }

    fn new_with_test_surface_runtime(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        session_id: SessionId,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime_and_limits(
            session,
            surface_options,
            session_id,
            test_surface_runtime,
            TopologyLimits::default(),
        )
    }

    fn new_with_test_surface_runtime_and_limits(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        session_id: SessionId,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
        topology_limits: TopologyLimits,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime_limits_and_revision(
            session,
            surface_options,
            session_id,
            test_surface_runtime,
            topology_limits,
            0,
        )
    }

    fn new_with_test_surface_runtime_limits_and_revision(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        session_id: SessionId,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
        topology_limits: TopologyLimits,
        topology_revision: u64,
    ) -> Arc<Self> {
        let session = session.into();
        let mut surface_options = surface_options;
        surface_options.browser_session_name = session.clone();
        let daemon_instance_id = DaemonInstanceId::new();
        Arc::new(Mux {
            state: Mutex::new(CanonicalState::new(
                State {
                    workspaces: Vec::new(),
                    active_workspace: 0,
                    panes: HashMap::new(),
                    surfaces: HashMap::new(),
                },
                daemon_instance_id,
                session_id,
                topology_limits,
                topology_revision,
            )),
            subscribers: MuxEventBroadcaster::default(),
            entity_ids: EntityIdentityAllocator::new(),
            next_notification_id: AtomicU64::new(1),
            next_active_at: AtomicU64::new(1),
            surface_options: Mutex::new(surface_options),
            latest_client_size: Mutex::new(LatestClientSize::default()),
            terminal_control_lifecycle: RwLock::new(()),
            client_sizing_lifecycle: Mutex::new(()),
            client_sizing: Mutex::new(ClientSizingState::default()),
            #[cfg(test)]
            client_resize_before_apply: Mutex::new(None),
            browser_runtime: Mutex::new(None),
            frontend_native_browsers: FrontendNativeBrowserRegistry::new(),
            remote_tmux_producers: RemoteTmuxProducerRegistry::new(),
            cell_pixels: Mutex::new((8, 16)),
            default_colors: Mutex::new((0, DefaultColors::default())),
            sidebar_plugin: Mutex::new(SidebarPluginRuntime::default()),
            agent_records: Mutex::new(HashMap::new()),
            control_clients: crate::server::ClientRegistry::new(),
            presentations: PresentationRegistry::new(),
            projection_states: ProjectionStateRegistry::new(),
            terminal_authority: TerminalAuthorityRegistry::new(),
            renderer_supervisor: Mutex::new(None),
            renderer_presentations: Mutex::new(RendererPresentationRuntimes::default()),
            renderer_presentation_generations: Mutex::new(BTreeMap::new()),
            renderer_release_routes: Mutex::new(RendererReleaseRoutes::default()),
            ensure_terminal_lock: Mutex::new(()),
            pairing: PairingBroker::new(),
            #[cfg(test)]
            test_surface_runtime,
            #[cfg(test)]
            test_surface_registered_barriers: Mutex::new(None),
            #[cfg(test)]
            ensure_terminal_initial_writes: AtomicU64::new(0),
            #[cfg(test)]
            terminal_launch_gate_releases: AtomicU64::new(0),
            #[cfg(test)]
            ensure_terminal_batch_fail_spawn_at: AtomicU64::new(0),
            #[cfg(test)]
            ensure_terminal_batch_before_publish: Mutex::new(None),
            #[cfg(test)]
            canonical_split_tab_fail_after_split: AtomicBool::new(false),
            #[cfg(test)]
            canonical_browser_fail_before_commit: AtomicBool::new(false),
            session,
            daemon_instance_id,
            session_id,
        })
    }

    fn restore_persisted_state(
        self: &Arc<Self>,
        snapshot: PersistedSessionState,
    ) -> anyhow::Result<()> {
        if snapshot.session_id != self.session_id {
            anyhow::bail!("persisted session identity changed during recovery");
        }

        let mut surface_ids = BTreeMap::new();
        let mut spawned = Vec::with_capacity(snapshot.surfaces.len());
        for persisted in &snapshot.surfaces {
            let (id, _) = self.entity_ids.surface();
            let (surface, recovery_notice) = match &persisted.kind {
                PersistedSurfaceKind::Terminal { launch } => {
                    self.restore_persisted_terminal(id, persisted.uuid, launch)?
                }
                PersistedSurfaceKind::ExternalTerminal {
                    cols,
                    rows,
                    scrollback,
                    no_reflow,
                    provenance,
                } => {
                    let mut opts = self.surface_options.lock().unwrap().clone();
                    opts.cols = (*cols).max(1);
                    opts.rows = (*rows).max(1);
                    opts.scrollback = *scrollback;
                    let surface = Surface::spawn_external_with_uuid_and_provenance(
                        id,
                        persisted.uuid,
                        opts,
                        *no_reflow,
                        *provenance,
                        Arc::downgrade(self),
                    )?;
                    if let Some(provenance) = provenance {
                        self.remote_tmux_producers.ensure_surface(
                            *provenance,
                            persisted.uuid,
                            None,
                        )?;
                    }
                    self.state.lock().unwrap().surfaces.insert(id, surface.clone());
                    (surface, None)
                }
                PersistedSurfaceKind::Browser { presentation } => {
                    let opts = self.surface_options.lock().unwrap().clone();
                    let cell_pixels = *self.cell_pixels.lock().unwrap();
                    let surface = match presentation {
                        crate::state_store::PersistedBrowserPresentationMode::DaemonRendered => {
                            browser::new_surface_with_uuid(
                                id,
                                persisted.uuid,
                                "about:blank".to_string(),
                                (opts.cols.max(1), opts.rows.max(1)),
                                cell_pixels,
                                &opts,
                                Arc::downgrade(self),
                            )
                        }
                        crate::state_store::PersistedBrowserPresentationMode::FrontendNative => {
                            self.frontend_native_browsers
                                .ensure_surface_seed(persisted.uuid, None)?;
                            browser::new_frontend_native_surface_with_uuid(
                                id,
                                persisted.uuid,
                                (opts.cols.max(1), opts.rows.max(1)),
                                cell_pixels,
                                &opts,
                            )
                        }
                    };
                    self.state.lock().unwrap().surfaces.insert(id, surface.clone());
                    (surface, None)
                }
            };
            surface.set_name(
                persisted
                    .name
                    .clone()
                    .or_else(|| recovery_notice.map(|_| "Recovered terminal".to_string())),
            );
            if let Some(notice) = recovery_notice {
                surface.inject_terminal_output(notice.as_bytes())?;
            }
            if surface_ids.insert(persisted.uuid, id).is_some() {
                anyhow::bail!("duplicate persisted surface UUID {}", persisted.uuid);
            }
            spawned.push(surface);
        }

        let mut panes = HashMap::with_capacity(snapshot.panes.len());
        let mut pane_ids = BTreeMap::new();
        let mut next_active_at = 1u64;
        for persisted in &snapshot.panes {
            let (id, _) = self.entity_ids.pane();
            let tabs = persisted
                .tabs
                .iter()
                .map(|uuid| {
                    surface_ids
                        .get(uuid)
                        .copied()
                        .ok_or_else(|| anyhow::anyhow!("pane references unknown surface {uuid}"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            if tabs.is_empty() || persisted.active_tab >= tabs.len() {
                anyhow::bail!("persisted pane {} has an invalid active tab", persisted.uuid);
            }
            next_active_at = next_active_at.max(persisted.active_at.saturating_add(1));
            panes.insert(
                id,
                Pane {
                    id,
                    uuid: persisted.uuid,
                    name: persisted.name.clone(),
                    tabs,
                    active_tab: persisted.active_tab,
                    active_at: persisted.active_at,
                },
            );
            if pane_ids.insert(persisted.uuid, id).is_some() {
                anyhow::bail!("duplicate persisted pane UUID {}", persisted.uuid);
            }
        }

        let mut workspaces = Vec::with_capacity(snapshot.workspaces.len());
        for persisted_workspace in &snapshot.workspaces {
            let (workspace_id, _) = self.entity_ids.workspace();
            let mut screens = Vec::with_capacity(persisted_workspace.screens.len());
            for persisted_screen in &persisted_workspace.screens {
                let (screen_id, _) = self.entity_ids.screen();
                let active_pane =
                    pane_ids.get(&persisted_screen.active_pane).copied().ok_or_else(|| {
                        anyhow::anyhow!(
                            "screen {} references unknown active pane {}",
                            persisted_screen.uuid,
                            persisted_screen.active_pane
                        )
                    })?;
                let zoomed_pane = persisted_screen
                    .zoomed_pane
                    .map(|uuid| {
                        pane_ids.get(&uuid).copied().ok_or_else(|| {
                            anyhow::anyhow!(
                                "screen {} references unknown zoom pane {uuid}",
                                persisted_screen.uuid
                            )
                        })
                    })
                    .transpose()?;
                screens.push(Screen {
                    id: screen_id,
                    uuid: persisted_screen.uuid,
                    name: persisted_screen.name.clone(),
                    root: restored_node(&persisted_screen.root, &pane_ids)?,
                    active_pane,
                    zoomed_pane,
                });
            }
            if screens.is_empty() || persisted_workspace.active_screen >= screens.len() {
                anyhow::bail!(
                    "persisted workspace {} has an invalid active screen",
                    persisted_workspace.uuid
                );
            }
            workspaces.push(Workspace {
                id: workspace_id,
                uuid: persisted_workspace.uuid,
                name: persisted_workspace.name.clone(),
                screens,
                active_screen: persisted_workspace.active_screen,
            });
        }
        let active_workspace = match snapshot.active_workspace {
            Some(uuid) => workspaces
                .iter()
                .position(|workspace| workspace.uuid == uuid)
                .ok_or_else(|| anyhow::anyhow!("active workspace {uuid} is missing"))?,
            None if workspaces.is_empty() => 0,
            None => anyhow::bail!("nonempty persisted topology has no active workspace"),
        };

        let next_notification_id = snapshot
            .activity_facts
            .iter()
            .map(|fact| fact.notification)
            .max()
            .unwrap_or(0)
            .saturating_add(1)
            .max(1);
        let terminal_activity = TerminalActivityState::restore(
            snapshot.activity_sequence,
            snapshot.activity_facts,
            snapshot.activity_receipts,
        )?;
        let restored_surfaces = {
            let mut state = self.state.lock().unwrap();
            let restored_surfaces = std::mem::take(&mut state.value.surfaces);
            state.value =
                State { workspaces, active_workspace, panes, surfaces: restored_surfaces.clone() };
            state.rebuild_topology_index()?;
            state.tombstones = snapshot.tombstones.into();
            state.idempotency_results = snapshot.idempotency_results.into();
            state.terminal_activity = terminal_activity;
            restored_surfaces
        };
        self.next_notification_id.store(next_notification_id, Ordering::Relaxed);
        self.next_active_at.store(next_active_at, Ordering::Relaxed);
        for surface in spawned {
            if restored_surfaces.contains_key(&surface.id) {
                self.reap_if_dead(&surface);
            }
        }
        Ok(())
    }

    fn restore_persisted_terminal(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        launch: &PersistedLaunchRecipe,
    ) -> anyhow::Result<(Arc<Surface>, Option<&'static str>)> {
        const CWD_NOTICE: &str = concat!(
            "cmux recovery: saved working directory was unavailable; ",
            "restarted the saved command from your home directory.\r\n"
        );
        const COMMAND_NOTICE: &str = concat!(
            "cmux recovery: saved command could not be started; ",
            "opened your default shell in your home directory.\r\n"
        );

        let native_home = || {
            crate::platform::native_home_dir()
                .map(|path| path.to_string_lossy().into_owned())
                .ok_or_else(|| anyhow::anyhow!("native home directory is unavailable for recovery"))
        };
        let cwd_unavailable =
            launch.cwd.as_deref().is_some_and(|cwd| !std::path::Path::new(cwd).is_dir());
        let original_cwd = if cwd_unavailable { Some(native_home()?) } else { launch.cwd.clone() };
        let spawn_saved = |cwd| {
            self.restore_already_durable_surface_with_allocated_identity(
                id,
                uuid,
                cwd,
                Some(launch.argv.clone()),
                launch.environment_pairs(),
                Some(launch.wait_after_command),
                Some((launch.cols, launch.rows)),
                Some(launch.scrollback),
            )
        };
        let mut original = spawn_saved(original_cwd);
        let cwd_disappeared_during_spawn = !cwd_unavailable
            && launch.cwd.as_deref().is_some_and(|cwd| !std::path::Path::new(cwd).is_dir());
        if original.is_err() && cwd_disappeared_during_spawn {
            original = spawn_saved(Some(native_home()?));
        }
        let (surface, recovery_notice) = match original {
            Ok(surface) => {
                (surface, (cwd_unavailable || cwd_disappeared_during_spawn).then_some(CWD_NOTICE))
            }
            Err(_) => {
                let surface = self
                    .restore_already_durable_surface_with_allocated_identity(
                        id,
                        uuid,
                        Some(native_home()?),
                        Some(vec![crate::platform::default_shell()]),
                        launch.environment_pairs(),
                        Some(launch.wait_after_command),
                        Some((launch.cols, launch.rows)),
                        Some(launch.scrollback),
                    )
                    .map_err(|_| {
                        anyhow::anyhow!("failed to start a recovery shell for terminal {uuid}")
                    })?;
                (surface, Some(COMMAND_NOTICE))
            }
        };

        // A fallback changes only this runtime. Keep the user's original
        // recipe so a later daemon restart can retry it unchanged.
        self.state.lock().unwrap().launch_recipes.insert(uuid, launch.clone());
        Ok((surface, recovery_notice))
    }

    #[cfg(test)]
    pub(crate) fn new_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(session, surface_options, SessionId::new(), true)
    }

    #[cfg(test)]
    pub(crate) fn new_for_test_with_topology_limits(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        topology_limits: TopologyLimits,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime_and_limits(
            session,
            surface_options,
            SessionId::new(),
            true,
            topology_limits,
        )
    }

    fn next_active_at(&self) -> u64 {
        self.next_active_at.fetch_add(1, Ordering::Relaxed)
    }

    fn next_notification_id(&self) -> anyhow::Result<u64> {
        self.next_notification_id
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |next| next.checked_add(1))
            .map_err(|_| anyhow::anyhow!("notification id sequence exhausted"))
    }

    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribers.subscribe()
    }

    pub fn subscribe_attached_surface(&self, surface: SurfaceId) -> MuxEventReceiver {
        self.subscribers.subscribe_attached_surface(surface)
    }

    pub fn subscribe_terminal_activity(&self) -> MuxEventReceiver {
        self.subscribers.subscribe_terminal_activity()
    }

    pub fn emit(&self, event: MuxEvent) {
        self.subscribers.emit(event);
    }

    pub(crate) fn lock_client_sizing_lifecycle(&self) -> MutexGuard<'_, ()> {
        self.client_sizing_lifecycle.lock().unwrap()
    }

    pub fn begin_pairing(
        &self,
        peer: std::net::IpAddr,
    ) -> Result<(PairingChallenge, Receiver<PairingDecision>), PairingError> {
        let result = self.pairing.begin(peer)?;
        self.emit(MuxEvent::PairingRequested(result.0.clone()));
        Ok(result)
    }

    pub fn respond_pairing(&self, id: u64, approve: bool) -> bool {
        let responded = self.pairing.respond(id, approve);
        if responded {
            self.emit(MuxEvent::PairingResolved { request: id });
        }
        responded
    }

    pub fn cancel_pairing(&self, id: u64) {
        if self.pairing.cancel(id) {
            self.emit(MuxEvent::PairingResolved { request: id });
        }
    }

    pub fn authenticate_pairing_credential(&self, credential: &str) -> bool {
        self.pairing.authenticate(credential)
    }

    pub fn pending_pairings(&self) -> Vec<PairingChallenge> {
        self.pairing.pending()
    }

    fn prepare_surface_for_launch(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        launch: &TerminalLaunchRequest,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<PreparedTerminalLaunch> {
        validate_terminal_launch_request(launch)?;
        let command = match (&launch.argv, &launch.command) {
            (Some(argv), None) => Some(argv.clone()),
            (None, Some(command)) => {
                Some(vec![crate::platform::default_shell(), "-lc".to_string(), command.clone()])
            }
            (None, None) => None,
            (Some(_), Some(_)) => unreachable!("launch validation rejects two command forms"),
        };
        self.prepare_surface_with_allocated_identity(
            id,
            uuid,
            launch.cwd.clone(),
            command,
            launch.env.clone(),
            Some(launch.wait_after_command),
            size,
            None,
            launch.initial_input.clone(),
        )
    }

    /// Finish a topology-visible terminal launch after its journal record is
    /// durable. Any failure is process-fatal: returning an error would invite
    /// a retry after some startup bytes may already have crossed the PTY.
    fn complete_committed_terminal_launch(self: &Arc<Self>, mut prepared: PreparedTerminalLaunch) {
        let gate = prepared.gate.take().expect("prepared terminal retains its launch gate");
        let input_authority =
            prepared.input_authority.take().expect("prepared terminal retains input authority");
        let had_initial_input = !prepared.initial_input.is_empty();
        let phase = self.terminal_launch_completion_probe(had_initial_input);
        let result = match gate {
            PreparedTerminalGate::Real(gate) => prepared.surface.complete_gated_launch(
                input_authority,
                gate,
                std::mem::take(&mut prepared.initial_input),
                terminal_initial_input_deadline(),
                phase,
            ),
            #[cfg(test)]
            PreparedTerminalGate::Test => {
                if let Some(phase) = &phase {
                    phase(TerminalLaunchCompletionPhase::BeforeRelease);
                }
                if let Some(phase) = &phase {
                    phase(TerminalLaunchCompletionPhase::AfterRelease);
                }
                if let Some(phase) = &phase {
                    phase(TerminalLaunchCompletionPhase::AfterInitialInput);
                }
                drop(input_authority);
                Ok(())
            }
        };
        if let Err(error) = result {
            eprintln!(
                "cmux-tui: fatal terminal launch completion failure after durable commit: {error}"
            );
            std::process::abort();
        }
    }

    fn terminal_launch_completion_probe(
        self: &Arc<Self>,
        had_initial_input: bool,
    ) -> Option<Arc<dyn Fn(TerminalLaunchCompletionPhase) + Send + Sync>> {
        #[cfg(test)]
        {
            let mux = Arc::downgrade(self);
            let probe = self.state.lock().unwrap().terminal_launch_atomicity_probe.clone();
            return Some(Arc::new(move |phase| {
                let Some(mux) = mux.upgrade() else { return };
                let phase = match phase {
                    TerminalLaunchCompletionPhase::BeforeRelease => {
                        TerminalLaunchAtomicityPhase::BeforeRelease
                    }
                    TerminalLaunchCompletionPhase::AfterRelease => {
                        mux.terminal_launch_gate_releases.fetch_add(1, Ordering::Relaxed);
                        TerminalLaunchAtomicityPhase::AfterRelease
                    }
                    TerminalLaunchCompletionPhase::AfterInitialInput => {
                        if had_initial_input {
                            mux.ensure_terminal_initial_writes.fetch_add(1, Ordering::Relaxed);
                        }
                        TerminalLaunchAtomicityPhase::AfterInitialInput
                    }
                };
                if let Some(probe) = &probe {
                    probe(phase);
                }
            }));
        }
        #[cfg(not(test))]
        {
            let _ = had_initial_input;
            None
        }
    }

    /// Recreate one terminal whose topology and launch recipe were fsynced by
    /// an earlier daemon. New topology mutations must use
    /// `prepare_surface_with_allocated_identity` instead.
    fn restore_already_durable_surface_with_allocated_identity(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        extra_env: Vec<(String, String)>,
        wait_after_command: Option<bool>,
        size: Option<(u16, u16)>,
        scrollback: Option<usize>,
    ) -> anyhow::Result<Arc<Surface>> {
        let (surface, launch) = self.create_already_durable_surface_with_allocated_identity(
            id,
            uuid,
            cwd,
            command,
            extra_env,
            wait_after_command,
            size,
            scrollback,
        )?;
        let mut state = self.state.lock().unwrap();
        state.launch_recipes.insert(uuid, launch);
        state.surfaces.insert(id, surface.clone());
        drop(state);
        #[cfg(test)]
        if let Some((registered, resume)) =
            self.test_surface_registered_barriers.lock().unwrap().take()
        {
            registered.wait();
            resume.wait();
        }
        Ok(surface)
    }

    /// Spawn one terminal without publishing it into canonical state. Batch
    /// materialization uses this seam so a partial spawn failure cannot leak
    /// runtimes or an incomplete topology to readers.
    fn create_already_durable_surface_with_allocated_identity(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        extra_env: Vec<(String, String)>,
        wait_after_command: Option<bool>,
        size: Option<(u16, u16)>,
        scrollback: Option<usize>,
    ) -> anyhow::Result<(Arc<Surface>, PersistedLaunchRecipe)> {
        let (surface, launch, gate, input_authority) = self
            .create_surface_with_allocated_identity_mode(
                id,
                uuid,
                cwd,
                command,
                extra_env,
                wait_after_command,
                size,
                scrollback,
                false,
            )?;
        debug_assert!(gate.is_none());
        debug_assert!(input_authority.is_none());
        Ok((surface, launch))
    }

    #[allow(clippy::too_many_arguments)]
    fn prepare_surface_with_allocated_identity(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        extra_env: Vec<(String, String)>,
        wait_after_command: Option<bool>,
        size: Option<(u16, u16)>,
        scrollback: Option<usize>,
        initial_input: Option<String>,
    ) -> anyhow::Result<PreparedTerminalLaunch> {
        let (surface, launch, gate, input_authority) = self
            .create_surface_with_allocated_identity_mode(
                id,
                uuid,
                cwd,
                command,
                extra_env,
                wait_after_command,
                size,
                scrollback,
                true,
            )?;
        Ok(PreparedTerminalLaunch {
            surface,
            launch: Some(launch),
            gate,
            input_authority,
            initial_input: initial_input
                .filter(|input| !input.is_empty())
                .unwrap_or_default()
                .into_bytes(),
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn create_surface_with_allocated_identity_mode(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        extra_env: Vec<(String, String)>,
        wait_after_command: Option<bool>,
        size: Option<(u16, u16)>,
        scrollback: Option<usize>,
        gated: bool,
    ) -> anyhow::Result<(
        Arc<Surface>,
        PersistedLaunchRecipe,
        Option<PreparedTerminalGate>,
        Option<InputAuthorityPermit>,
    )> {
        let mut opts = self.surface_options.lock().unwrap().clone();
        if cwd.is_some() {
            opts.cwd = cwd;
        }
        if command.is_some() {
            opts.command = command;
        }
        let mut persisted_environment = extra_env.clone();
        opts.extra_env.extend(extra_env);
        if let Some(wait_after_command) = wait_after_command {
            opts.wait_after_command = wait_after_command;
        }
        if let Some(scrollback) = scrollback {
            opts.scrollback = scrollback;
        }
        let persisted_term = opts.term.clone();
        let persisted_scrollback = opts.scrollback;
        // Spawn at the latest client-owned size: starting at the default
        // 80x24 and resizing a frame later makes shells emit artifacts
        // (e.g. zsh's reverse-video %% partial-line marker).
        let (cols, rows) = self.resolve_client_size(size, (opts.cols, opts.rows));
        opts.cols = cols;
        opts.rows = rows;
        #[cfg(test)]
        let (surface, gate) = if self.test_surface_runtime {
            (
                Surface::spawn_for_test_with_uuid(id, uuid, opts, Arc::downgrade(self))?,
                gated.then_some(PreparedTerminalGate::Test),
            )
        } else if gated {
            let (surface, gate) = Surface::prepare_with_uuid(id, uuid, opts, Arc::downgrade(self))?;
            (surface, Some(PreparedTerminalGate::Real(gate)))
        } else {
            (Surface::spawn_with_uuid(id, uuid, opts, Arc::downgrade(self))?, None)
        };
        #[cfg(not(test))]
        let (surface, gate) = if gated {
            let (surface, gate) = Surface::prepare_with_uuid(id, uuid, opts, Arc::downgrade(self))?;
            (surface, Some(PreparedTerminalGate::Real(gate)))
        } else {
            (Surface::spawn_with_uuid(id, uuid, opts, Arc::downgrade(self))?, None)
        };
        let input_authority = gated.then(|| surface.reserve_input_authority()).transpose()?;
        let launch = PersistedLaunchRecipe::sanitized(
            surface.spawn_argv().ok_or_else(|| anyhow::anyhow!("spawned terminal has no argv"))?,
            surface.spawn_cwd(),
            {
                if !persisted_environment.iter().any(|(name, _)| name == "TERM") {
                    persisted_environment.push(("TERM".to_string(), persisted_term));
                }
                persisted_environment
            },
            surface.size().0,
            surface.size().1,
            persisted_scrollback,
            surface.wait_after_command(),
        );
        Ok((surface, launch, gate, input_authority))
    }

    fn spawn_sidebar_plugin_surface(
        self: &Arc<Self>,
        options: &SidebarPluginOptions,
        size: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        // The sidebar plugin is an ephemeral TUI helper. It has no durable
        // topology identity or launch recipe, so there is no commit to gate.
        if options.command.is_empty() {
            anyhow::bail!("sidebar plugin command is empty");
        }
        let (id, uuid) = self.entity_ids.surface();
        let mut opts = self.surface_options.lock().unwrap().clone();
        opts.command = Some(options.command.clone());
        opts.cwd = options.cwd.clone();
        opts.cols = size.0.max(1);
        opts.rows = size.1.max(1);
        opts.extra_env.push(("CMUX_SIDEBAR".to_string(), "1".to_string()));
        #[cfg(test)]
        let surface = if self.test_surface_runtime {
            Surface::spawn_for_test_with_uuid(id, uuid, opts, Arc::downgrade(self))?
        } else {
            Surface::spawn_with_uuid(id, uuid, opts, Arc::downgrade(self))?
        };
        #[cfg(not(test))]
        let surface = Surface::spawn_with_uuid(id, uuid, opts, Arc::downgrade(self))?;
        self.state.lock().unwrap().surfaces.insert(id, surface.clone());
        Ok(surface)
    }

    fn spawn_browser_surface(
        self: &Arc<Self>,
        url: String,
        size: Option<(u16, u16)>,
    ) -> Arc<Surface> {
        let (id, uuid) = self.entity_ids.surface();
        let surface = self.create_browser_surface_with_uuid(id, uuid, url.clone(), size);
        self.state.lock().unwrap().surfaces.insert(id, surface.clone());
        self.start_browser_bootstrap(surface.clone(), BrowserBootstrap::Create { url }, None);
        surface
    }

    /// Constructs a browser runtime without publishing it into canonical
    /// topology or starting asynchronous CDP work. Canonical mutations use
    /// this seam so failed revision/durability checks cannot leak a surface.
    fn create_browser_surface_with_uuid(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        url: String,
        size: Option<(u16, u16)>,
    ) -> Arc<Surface> {
        self.create_browser_surface_with_presentation(
            id,
            uuid,
            url,
            size,
            BrowserPresentationMode::DaemonRendered,
        )
    }

    fn create_browser_surface_with_presentation(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        url: String,
        size: Option<(u16, u16)>,
        presentation: BrowserPresentationMode,
    ) -> Arc<Surface> {
        let opts = self.surface_options.lock().unwrap().clone();
        let size = self.resolve_client_size(size, (opts.cols, opts.rows));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        match presentation {
            BrowserPresentationMode::DaemonRendered => browser::new_surface_with_uuid(
                id,
                uuid,
                url,
                size,
                cell_pixels,
                &opts,
                Arc::downgrade(self),
            ),
            BrowserPresentationMode::FrontendNative => {
                browser::new_frontend_native_surface_with_uuid(id, uuid, size, cell_pixels, &opts)
            }
        }
    }

    fn create_external_terminal_with_uuid(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        size: (u16, u16),
        no_reflow: bool,
    ) -> anyhow::Result<Arc<Surface>> {
        self.create_external_terminal_with_provenance(id, uuid, size, no_reflow, None)
    }

    fn create_external_terminal_with_provenance(
        self: &Arc<Self>,
        id: SurfaceId,
        uuid: SurfaceUuid,
        size: (u16, u16),
        no_reflow: bool,
        provenance: Option<ExternalTerminalProvenance>,
    ) -> anyhow::Result<Arc<Surface>> {
        let mut opts = self.surface_options.lock().unwrap().clone();
        let (cols, rows) = self.resolve_client_size(Some(size), (opts.cols, opts.rows));
        opts.cols = cols;
        opts.rows = rows;
        Surface::spawn_external_with_uuid_and_provenance(
            id,
            uuid,
            opts,
            no_reflow,
            provenance,
            Arc::downgrade(self),
        )
    }

    fn resolve_client_size(
        &self,
        requested: Option<(u16, u16)>,
        default: (u16, u16),
    ) -> (u16, u16) {
        let mut latest = self.latest_client_size.lock().unwrap();
        if let Some((cols, rows)) = requested {
            let size = clamp_terminal_size(cols, rows);
            latest.size = Some(size);
            latest.from_report = false;
            return size;
        }
        latest.size.unwrap_or_else(|| clamp_terminal_size(default.0, default.1))
    }

    /// Record a genuine client-chosen size (protocol resize-surface, sized
    /// creation, or the local TUI sizing a pane) as the default for future
    /// unsized surface creation.
    pub fn record_client_size(&self, cols: u16, rows: u16) -> (u16, u16) {
        let size = clamp_terminal_size(cols, rows);
        let mut latest = self.latest_client_size.lock().unwrap();
        latest.size = Some(size);
        latest.from_report = true;
        size
    }

    /// Execute one legacy terminal mutation while excluding the one-way v9
    /// lease migration. The closure may write to the PTY, so this lifecycle
    /// lock is intentionally separate from canonical state and sizing locks.
    pub fn with_legacy_terminal_control<R>(
        &self,
        surface: &Surface,
        operation: impl FnOnce() -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        self.terminal_authority.require_legacy(surface.uuid)?;
        operation()
    }

    /// Keep canonical terminal retirement from invalidating an accepted v9
    /// operation before its receipt is committed. Readers can execute across
    /// independent terminals concurrently; migration and close take the
    /// exclusive side of this fence.
    pub(crate) fn read_terminal_control_lifecycle(&self) -> RwLockReadGuard<'_, ()> {
        self.terminal_control_lifecycle.read().unwrap()
    }

    /// Atomically migrate a terminal out of legacy shared control and acquire
    /// one connection/presentation-bound v9 input or geometry lease.
    pub(crate) fn acquire_terminal_lease(
        &self,
        surface: SurfaceId,
        kind: TerminalLeaseKind,
        claim: TerminalLeaseClaim,
        ttl_ms: u64,
    ) -> anyhow::Result<TerminalLease> {
        let _lifecycle = self.terminal_control_lifecycle.write().unwrap();
        let surface_runtime =
            self.surface(surface).ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        // Take the sizing reducer lock before changing authority mode. Every
        // legacy report/removal applies its resulting PTY resize while holding
        // this lock, so migration cannot overtake an already-computed legacy
        // resize and let it land after the terminal becomes leased.
        let mut sizing = self.client_sizing.lock().unwrap();
        let lease = self.terminal_authority.acquire(surface_runtime.uuid, kind, claim, ttl_ms)?;
        if lease.migrated_from_legacy {
            // A leased presentation is the sole geometry authority. Remove
            // every old `(surface, client)` report before releasing the
            // migration fence so a later v8 detach cannot reapply a stale
            // smallest-viewer result.
            sizing.surfaces.remove(&surface);
            sizing.report_order.retain(|(reported_surface, _), _| *reported_surface != surface);
            let changed_clients = self.control_clients.clear_surface_sizes(surface);
            let attached_clients = self.control_clients.attached_client_ids();
            self.reconcile_latest_client_size(&sizing, &attached_clients);
            drop(sizing);
            self.emit_client_sizing_changes(changed_clients);
        } else {
            drop(sizing);
        }
        Ok(lease)
    }

    fn reconcile_latest_client_size(
        &self,
        sizing: &ClientSizingState,
        attached_clients: &HashSet<u64>,
    ) {
        let mut latest = self.latest_client_size.lock().unwrap();
        if let Some(size) = sizing.latest_effective_size(attached_clients) {
            latest.size = Some(size);
            latest.from_report = true;
        } else if latest.from_report {
            latest.size = None;
            latest.from_report = false;
        }
    }

    /// Record one viewer's available grid and resize the shared surface to
    /// the smallest rows and columns reported by all current viewers.
    pub fn resize_surface_for_client(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<bool> {
        self.resize_surface_for_client_with_reservation(id, client, cols, rows)
            .map(|(accepted, _)| accepted)
    }

    pub fn resize_surface_for_client_with_reservation(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<(bool, Option<u64>)> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        let surface = self.surface(id).ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))?;
        self.terminal_authority.require_legacy(surface.uuid)?;
        let requested = clamp_terminal_size(cols, rows);
        // Serialize the report and its application. Otherwise an older
        // effective size can reach the PTY after a newer shared minimum.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids();
        let result = self.resize_surface_for_client_locked(
            &mut sizing,
            &attached_clients,
            id,
            client,
            requested,
        )?;
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
        Ok(result.0)
    }

    pub(crate) fn resize_surface_for_control_client_with_reservation(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<(bool, Option<u64>, Option<crate::server::ClientSizeUpdate>)> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        let surface = self.surface(id).ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))?;
        self.terminal_authority.require_legacy(surface.uuid)?;
        let requested = clamp_terminal_size(cols, rows);
        // Keep registration, report insertion, and reducer insertion in one
        // critical section. Disconnect and final stream detach remove their
        // leases through this same sizing lock after dropping the registry lock.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached = self.control_clients.record_size(client, id, requested.0, requested.1)?;
        let attached_clients = self.control_clients.attached_client_ids();
        let result = self.resize_surface_for_client_locked(
            &mut sizing,
            &attached_clients,
            id,
            client,
            requested,
        );
        if result.is_err()
            && let Some((_, _, _, previous)) = attached.as_ref()
        {
            self.control_clients.restore_size(client, id, *previous);
        }
        let result = result?;
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
        Ok((result.0.0, result.0.1, attached))
    }

    fn resize_surface_for_client_locked(
        &self,
        sizing: &mut ClientSizingState,
        attached_clients: &HashSet<u64>,
        id: SurfaceId,
        client: u64,
        requested: (u16, u16),
    ) -> anyhow::Result<AppliedClientSize> {
        if sizing.exclusive_client.is_some_and(|exclusive| exclusive != client) {
            sizing.excluded_clients.insert(client);
        }
        sizing.next_report_order = sizing.next_report_order.wrapping_add(1).max(1);
        let report_order = sizing.next_report_order;
        let previous_order = sizing.report_order.insert((id, client), report_order);
        let previous = {
            let viewers = sizing.surfaces.entry(id).or_default();
            viewers.insert(client, requested)
        };
        let use_excluded = sizing.uses_excluded_fallback(attached_clients);
        let effective = sizing.effective_size(id, use_excluded);
        let Some(effective) = effective else {
            return Ok(((false, None), None));
        };
        #[cfg(test)]
        let before_apply = self.client_resize_before_apply.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_apply {
            hook();
        }
        match self.resize_surface_with_reservation(id, effective.0, effective.1) {
            Ok(changed) => Ok((changed, Some(effective))),
            Err(error) => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    if let Some(previous) = previous {
                        viewers.insert(client, previous);
                    } else {
                        viewers.remove(&client);
                    }
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
                if let Some(previous_order) = previous_order {
                    sizing.report_order.insert((id, client), previous_order);
                } else {
                    sizing.report_order.remove(&(id, client));
                }
                Err(error)
            }
        }
    }

    pub fn remove_surface_size_client(&self, id: SurfaceId, client: u64) {
        // Removal participates in the same ordering as size reports.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids();
        let fallback_before = sizing.uses_excluded_fallback(&attached_clients);
        let removed = {
            let removed = sizing
                .surfaces
                .get_mut(&id)
                .is_some_and(|viewers| viewers.remove(&client).is_some());
            if sizing.surfaces.get(&id).is_some_and(HashMap::is_empty) {
                sizing.surfaces.remove(&id);
            }
            removed
        };
        sizing.report_order.remove(&(id, client));
        let fallback_after = sizing.uses_excluded_fallback(&attached_clients);
        // A final unreported attachment can be the only thing suppressing
        // excluded-report fallback. Reconcile all reports even though that
        // attachment had no lease of its own to remove.
        if !removed && !fallback_after {
            return;
        }
        let fallback_changed = fallback_before != fallback_after;
        let affected = if fallback_changed || fallback_after {
            sizing.surfaces.keys().copied().collect::<Vec<_>>()
        } else {
            vec![id]
        };
        let effective = sizing.effective_sizes(affected, fallback_after);
        #[cfg(test)]
        let before_apply = self.client_resize_before_apply.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_apply {
            hook();
        }
        for (surface, (cols, rows)) in effective {
            let _ = self.resize_surface(surface, cols, rows);
        }
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
    }

    pub fn remove_size_client(&self, client: u64) {
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids();
        let fallback_before = sizing.uses_excluded_fallback(&attached_clients);
        let mut affected = Vec::new();
        for (surface, viewers) in &mut sizing.surfaces {
            if viewers.remove(&client).is_some() {
                affected.push(*surface);
            }
        }
        sizing.surfaces.retain(|_, viewers| !viewers.is_empty());
        sizing.report_order.retain(|(_, reporter), _| *reporter != client);
        let restored_exclusive = sizing.exclusive_client == Some(client);
        if restored_exclusive {
            sizing.exclusive_client = None;
            sizing.excluded_clients.clear();
        } else {
            sizing.excluded_clients.remove(&client);
        }
        let fallback_after = sizing.uses_excluded_fallback(&attached_clients);
        if restored_exclusive || fallback_before != fallback_after || fallback_after {
            affected.extend(sizing.surfaces.keys().copied());
        }
        affected.sort_unstable();
        affected.dedup();
        let effective = sizing.effective_sizes(affected, fallback_after);
        for (surface, (cols, rows)) in effective {
            let _ = self.resize_surface(surface, cols, rows);
        }
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
    }

    pub fn client_surface_size(&self, id: SurfaceId, client: u64) -> Option<(u16, u16)> {
        self.client_sizing
            .lock()
            .unwrap()
            .surfaces
            .get(&id)
            .and_then(|viewers| viewers.get(&client).copied())
    }

    fn emit_client_sizing_changes(&self, clients: impl IntoIterator<Item = u64>) {
        for client in clients {
            let (name, kind) = self.control_clients.client_info(client).unwrap_or((None, None));
            self.emit(MuxEvent::ClientChanged { client, name, kind });
        }
    }

    /// Include or exclude one live client's reported dimensions from the
    /// tmux-style shared minimum. Validation, mutation, and disconnect cleanup
    /// share one lifecycle lock so a stale menu action cannot retain a dead ID.
    pub fn set_client_size_participation(&self, client: u64, participating: bool) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let mut sizing = self.client_sizing.lock().unwrap();
        let known = self.control_clients.contains(client)
            || sizing.surfaces.values().any(|viewers| viewers.contains_key(&client));
        if !known {
            return None;
        }
        let attached_clients = self.control_clients.attached_client_ids();
        let changed = if participating {
            sizing.excluded_clients.remove(&client)
        } else {
            sizing.excluded_clients.insert(client)
        };
        if !changed {
            return Some(false);
        }
        sizing.exclusive_client = None;
        let affected = sizing.surfaces.keys().copied().collect::<Vec<_>>();
        let use_excluded = sizing.uses_excluded_fallback(&attached_clients);
        let effective = sizing.effective_sizes(affected, use_excluded);
        for (surface, (cols, rows)) in &effective {
            let _ = self.resize_surface(*surface, *cols, *rows);
        }
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
        self.emit_client_sizing_changes([client]);
        Some(true)
    }

    /// Atomically make one client the only sizing participant. This avoids
    /// transient intermediate grids while a menu action updates many clients.
    pub fn use_only_client_size(&self, target: u64) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids();
        let mut known_clients = self.control_clients.client_ids();
        for viewers in sizing.surfaces.values() {
            known_clients.extend(viewers.keys().copied());
        }
        let target_is_connected = self.control_clients.contains(target);
        let target_is_reporting =
            sizing.surfaces.values().any(|viewers| viewers.contains_key(&target));
        if !target_is_connected && !target_is_reporting {
            return None;
        }
        let excluded = known_clients
            .iter()
            .copied()
            .filter(|client| *client != target)
            .collect::<HashSet<_>>();
        if sizing.excluded_clients == excluded && sizing.exclusive_client == Some(target) {
            return Some(false);
        }
        sizing.excluded_clients = excluded;
        sizing.exclusive_client = Some(target);
        let affected = sizing.surfaces.keys().copied().collect::<Vec<_>>();
        let use_excluded = sizing.uses_excluded_fallback(&attached_clients);
        let effective = sizing.effective_sizes(affected, use_excluded);
        for (surface, (cols, rows)) in &effective {
            let _ = self.resize_surface(*surface, *cols, *rows);
        }
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
        self.emit_client_sizing_changes(known_clients);
        Some(true)
    }

    /// Atomically restore every connected or reporting client to sizing.
    pub fn use_all_client_sizes(&self) -> bool {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids();
        if sizing.excluded_clients.is_empty() && sizing.exclusive_client.is_none() {
            return false;
        }
        let mut known_clients = self.control_clients.client_ids();
        for viewers in sizing.surfaces.values() {
            known_clients.extend(viewers.keys().copied());
        }
        sizing.excluded_clients.clear();
        sizing.exclusive_client = None;
        let affected = sizing.surfaces.keys().copied().collect::<Vec<_>>();
        let effective = sizing.effective_sizes(affected, false);
        debug_assert!(!sizing.uses_excluded_fallback(&attached_clients) || effective.is_empty());
        for (surface, (cols, rows)) in &effective {
            let _ = self.resize_surface(*surface, *cols, *rows);
        }
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
        self.emit_client_sizing_changes(known_clients);
        true
    }

    pub fn client_size_participates(&self, client: u64) -> bool {
        self.client_sizing.lock().unwrap().client_participates(client)
    }

    pub fn control_clients_json(&self, requesting_client: u64) -> Value {
        let mut clients = self.control_clients.list_json(requesting_client);
        if let Some(clients) = clients.as_array_mut() {
            for info in clients {
                let id = info.get("client").and_then(Value::as_u64).unwrap_or_default();
                info["size_participating"] = serde_json::json!(self.client_size_participates(id));
            }
        }
        let sizing = self.client_sizing.lock().unwrap();
        let local_sizes = sizing
            .surfaces
            .iter()
            .filter_map(|(surface, viewers)| {
                viewers.get(&0).map(|(cols, rows)| {
                    serde_json::json!({
                        "surface": surface,
                        "cols": cols,
                        "rows": rows,
                    })
                })
            })
            .collect::<Vec<_>>();
        if !local_sizes.is_empty()
            && let Some(clients) = clients.as_array_mut()
        {
            clients.insert(
                0,
                serde_json::json!({
                    "client": 0,
                    "transport": "local",
                    "name": "This TUI",
                    "kind": "tui",
                    "connected_seconds": 0,
                    "attached": local_sizes.iter().filter_map(|size| size.get("surface")).cloned().collect::<Vec<_>>(),
                    "sizes": local_sizes,
                    "self": requesting_client == 0,
                    "size_participating": !sizing.excluded_clients.contains(&0),
                }),
            );
        }
        clients
    }

    #[cfg(test)]
    fn set_client_resize_before_apply(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.client_resize_before_apply.lock().unwrap() = hook;
    }

    fn browser_runtime(&self) -> anyhow::Result<Arc<BrowserRuntime>> {
        let mut runtime = self.browser_runtime.lock().unwrap();
        if let Some(existing) = runtime.as_ref().filter(|existing| !existing.is_closed()) {
            return Ok(existing.clone());
        }
        let opts = self.surface_options.lock().unwrap().clone();
        let created = BrowserRuntime::connect(&opts)?;
        *runtime = Some(created.clone());
        Ok(created)
    }

    fn start_browser_bootstrap(
        self: &Arc<Self>,
        surface: Arc<Surface>,
        bootstrap: BrowserBootstrap,
        runtime: Option<Arc<BrowserRuntime>>,
    ) {
        let mux = self.clone();
        let id = surface.id;
        let _ = std::thread::Builder::new().name(format!("browser-surface-{id}-bootstrap")).spawn(
            move || {
                let result = (|| -> anyhow::Result<()> {
                    let runtime = match runtime {
                        Some(runtime) => runtime,
                        None => mux.browser_runtime()?,
                    };
                    runtime.bootstrap_surface_sync(surface.clone(), bootstrap, Arc::downgrade(&mux))
                })();
                if let Err(err) = result {
                    if let Surface::Browser(browser) = surface.as_ref() {
                        browser.mark_failed(err.to_string());
                    }
                    mux.emit(MuxEvent::Status(format!("browser failed: {err}")));
                    mux.emit(MuxEvent::TitleChanged { surface: id, title: surface.title().into() });
                    mux.emit(MuxEvent::SurfaceOutput(id));
                }
            },
        );
    }

    /// A fresh single-tab pane wrapping `surface`.
    fn make_pane(&self, surface: SurfaceId) -> (PaneId, Pane) {
        let (id, uuid) = self.entity_ids.pane();
        (
            id,
            Pane {
                id,
                uuid,
                name: None,
                tabs: vec![surface],
                active_tab: 0,
                active_at: self.next_active_at(),
            },
        )
    }

    pub fn surface(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().surfaces.get(&id).cloned()
    }

    /// Run `f` with the session state.
    ///
    /// The state lock is held for the duration of `f`; do not call back
    /// into `Mux` methods that take it (`surface()`, `close_pane()`, ...).
    pub fn with_state<R>(&self, f: impl FnOnce(&State) -> R) -> R {
        f(&self.state.lock().unwrap().value)
    }

    /// Read a derived legacy tree snapshot and its protocol-v7 revision under
    /// one mutex acquisition. This revision includes presentation-like global
    /// selection and zoom fields that are intentionally absent from v8's
    /// structural topology journal.
    pub fn with_state_snapshot<R>(&self, f: impl FnOnce(&State) -> R) -> CanonicalSnapshot<R> {
        let canonical = self.state.lock().unwrap();
        CanonicalSnapshot {
            topology_revision: canonical.legacy_topology_revision,
            state: f(&canonical.value),
        }
    }

    /// Protocol-v7 revision for the complete legacy workspace tree.
    pub fn topology_revision(&self) -> u64 {
        self.state.lock().unwrap().legacy_topology_revision
    }

    /// Protocol-v8 structural revision used by topology snapshots and resume.
    pub fn canonical_topology_revision(&self) -> u64 {
        self.state.lock().unwrap().topology.revision()
    }

    /// Look up the stable result of a retained caller idempotency key. The
    /// server transaction lane can use this before invoking a mutation; key
    /// plumbing into protocol commands remains intentionally separate.
    pub(crate) fn durable_idempotency_result(
        &self,
        key: &str,
    ) -> Option<PersistedIdempotencyResult> {
        self.state
            .lock()
            .unwrap()
            .idempotency_results
            .iter()
            .find(|result| result.key == key)
            .cloned()
    }

    fn canonical_mutation_start(
        &self,
        state: &CanonicalState,
        expectation: CanonicalMutationExpectation,
        operation: &str,
        payload_digest: &str,
    ) -> anyhow::Result<CanonicalMutationStart> {
        if expectation.request_id.is_nil() {
            anyhow::bail!("canonical mutation request_id must be nonzero");
        }
        if expectation.daemon_instance_id != self.daemon_instance_id
            || expectation.session_id != self.session_id
        {
            anyhow::bail!(
                "canonical mutation authority changed: expected daemon {} session {}, current daemon {} session {}",
                expectation.daemon_instance_id,
                expectation.session_id,
                self.daemon_instance_id,
                self.session_id
            );
        }
        if payload_digest.len() != 64
            || !payload_digest.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            anyhow::bail!("canonical mutation payload digest is invalid");
        }
        let key = format!("canonical:{operation}:{payload_digest}:{}", expectation.request_id);
        if let Some(result) = state.idempotency_results.iter().find(|result| result.key == key) {
            if result.payload_digest != payload_digest {
                anyhow::bail!("canonical mutation retained payload digest is inconsistent");
            }
            let revision = result.committed_topology_revision;
            return Ok(CanonicalMutationStart::Replay {
                receipt: CanonicalMutationReceipt {
                    request_id: expectation.request_id,
                    daemon_instance_id: self.daemon_instance_id,
                    session_id: self.session_id,
                    base_revision: revision.saturating_sub(1),
                    revision,
                    replayed: true,
                },
                result: result.clone(),
            });
        }
        let request_suffix = format!(":{}", expectation.request_id);
        if let Some(previous) = state.idempotency_results.iter().find(|result| {
            result.key.starts_with("canonical:") && result.key.ends_with(&request_suffix)
        }) {
            let same_operation = previous.key.strip_prefix("canonical:").is_some_and(|suffix| {
                suffix.starts_with(operation)
                    && suffix.as_bytes().get(operation.len()) == Some(&b':')
            });
            if same_operation {
                anyhow::bail!("canonical mutation request_id payload changed");
            }
            anyhow::bail!("canonical mutation request_id was already used by another operation");
        }
        let revision = state.topology.revision();
        if revision != expectation.expected_revision {
            anyhow::bail!(
                "canonical mutation revision changed: expected {}, current {}",
                expectation.expected_revision,
                revision
            );
        }
        Ok(CanonicalMutationStart::Fresh { key })
    }

    fn commit_canonical_mutation(
        &self,
        state: &mut CanonicalState,
        operation: TopologyOperation,
        targets: TopologyTargets,
        key: String,
    ) -> CanonicalMutationReceipt {
        let request_id = key
            .rsplit(':')
            .next()
            .and_then(|value| value.parse().ok())
            .expect("canonical idempotency key ends in request UUID");
        let delta = state.commit_topology_with_idempotency(operation, targets, key);
        CanonicalMutationReceipt {
            request_id,
            daemon_instance_id: self.daemon_instance_id,
            session_id: self.session_id,
            base_revision: delta.base_revision,
            revision: delta.revision,
            replayed: false,
        }
    }

    /// Capture both public revisions atomically for identity and liveness
    /// responses.
    pub fn topology_revisions(&self) -> (u64, u64) {
        let canonical = self.state.lock().unwrap();
        (canonical.legacy_topology_revision, canonical.topology.revision())
    }

    #[cfg(test)]
    fn topology_size_computations(&self) -> usize {
        self.state.lock().unwrap().topology.size_computations()
    }

    #[cfg(test)]
    pub(crate) fn topology_subscriber_slots(&self) -> usize {
        self.state.lock().unwrap().topology.subscriber_slots()
    }

    pub fn topology_snapshot(&self) -> TopologySnapshot {
        let canonical = self.state.lock().unwrap();
        canonical.topology.snapshot(&canonical.value)
    }

    pub fn subscribe_topology(
        &self,
        daemon_instance_id: DaemonInstanceId,
        session_id: SessionId,
        revision: u64,
    ) -> TopologyResume {
        self.state.lock().unwrap().topology.subscribe(daemon_instance_id, session_id, revision)
    }

    pub fn surface_count(&self) -> usize {
        self.state.lock().unwrap().surfaces.len()
    }

    pub fn surface_notification(&self, surface: SurfaceId) -> Option<SurfaceNotification> {
        self.surface_notifications_for_reader(LEGACY_TERMINAL_ACTIVITY_READER_UUID).remove(&surface)
    }

    pub fn surface_notifications(&self) -> HashMap<SurfaceId, SurfaceNotification> {
        self.surface_notifications_for_reader(LEGACY_TERMINAL_ACTIVITY_READER_UUID)
    }

    pub(crate) fn surface_notifications_for_reader(
        &self,
        reader_uuid: uuid::Uuid,
    ) -> HashMap<SurfaceId, SurfaceNotification> {
        let state = self.state.lock().unwrap();
        state
            .surfaces
            .iter()
            .filter_map(|(surface_id, surface)| {
                let fact = state.terminal_activity.fact(surface.uuid)?;
                state.terminal_activity.is_unread(reader_uuid, surface.uuid).then_some((
                    *surface_id,
                    SurfaceNotification {
                        notification: fact.notification,
                        level: fact.level,
                        unread: true,
                    },
                ))
            })
            .collect()
    }

    pub fn clear_surface_notification(&self, surface: SurfaceId) -> bool {
        let cleared = self.mark_legacy_surface_seen(Some(surface));
        if cleared {
            self.emit(MuxEvent::TreeChanged);
        }
        cleared
    }

    fn active_surface_in_state(state: &State) -> Option<SurfaceId> {
        let pane = state.active_pane()?;
        state.panes.get(&pane)?.active_surface()
    }

    pub fn active_surface(&self) -> Option<SurfaceId> {
        self.with_state(Self::active_surface_in_state)
    }

    fn clear_viewed_notification(&self, surface: Option<SurfaceId>) {
        let _ = self.mark_legacy_surface_seen(surface);
    }

    fn mark_legacy_surface_seen(&self, surface: Option<SurfaceId>) -> bool {
        let Some(surface) = surface else { return false };
        let mut state = self.state.lock().unwrap();
        let Some(surface_uuid) = state.surfaces.get(&surface).map(|surface| surface.uuid) else {
            return false;
        };
        let changed = state
            .terminal_activity
            .mark_latest_seen(LEGACY_TERMINAL_ACTIVITY_READER_UUID, surface_uuid)
            .unwrap_or_else(|error| {
                eprintln!("cmux-tui: legacy activity receipt rejected: {error}");
                None
            })
            .is_some_and(|(_, changed)| changed);
        if changed {
            state.persist_terminal_activity("legacy-seen");
        }
        changed
    }

    pub fn post_notification(
        &self,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
    ) -> anyhow::Result<u64> {
        let id = self.next_notification_id()?;
        let mut has_activity = false;
        if let Some(surface) = surface {
            let mut state = self.state.lock().unwrap();
            let surface_uuid = state
                .surfaces
                .get(&surface)
                .map(|surface| surface.uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
            let fact = state.terminal_activity.record_notification(surface_uuid, id, level)?;
            if Self::active_surface_in_state(&state) == Some(surface) {
                state.terminal_activity.mark_seen(
                    LEGACY_TERMINAL_ACTIVITY_READER_UUID,
                    surface_uuid,
                    fact.sequence,
                )?;
            }
            state.persist_terminal_activity("notification");
            // Publish while the canonical lock still establishes mutation
            // order. A later receipt can never overtake its activity fact.
            self.emit(MuxEvent::TerminalActivity(fact));
            has_activity = true;
        }
        self.emit(MuxEvent::Notification(NotificationEvent {
            notification: id,
            title,
            body,
            level,
            surface: surface.clone(),
        }));
        if has_activity {
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(id)
    }

    pub fn terminal_activity_snapshot(
        &self,
        reader_uuid: uuid::Uuid,
    ) -> anyhow::Result<TerminalActivitySnapshot> {
        if reader_uuid.is_nil() {
            anyhow::bail!("terminal activity reader must be a non-nil UUID");
        }
        Ok(self.state.lock().unwrap().terminal_activity.snapshot(reader_uuid))
    }

    pub fn mark_terminal_seen(
        &self,
        reader_uuid: uuid::Uuid,
        surface_uuid: SurfaceUuid,
        activity_sequence: u64,
    ) -> anyhow::Result<TerminalActivityReadReceipt> {
        let receipt = {
            let mut state = self.state.lock().unwrap();
            if state.indexed_surface_id_by_uuid(surface_uuid).is_none() {
                anyhow::bail!("unknown surface UUID {surface_uuid}");
            }
            let (receipt, changed) =
                state.terminal_activity.mark_seen(reader_uuid, surface_uuid, activity_sequence)?;
            if changed {
                state.persist_terminal_activity("seen");
                // Keep receipt delivery ordered behind the persisted fact and
                // any earlier receipt serialized by this same state lock.
                self.emit(MuxEvent::TerminalActivityReceipt(receipt));
            }
            receipt
        };
        Ok(receipt)
    }

    pub fn report_agent(
        &self,
        surface: SurfaceId,
        state: AgentState,
        source: AgentSource,
        session: Option<String>,
    ) -> AgentRecord {
        let mut records = self.agent_records.lock().unwrap();
        if let Some(existing) = records.get(&surface)
            && existing.source == AgentSource::Hook
            && source == AgentSource::Socket
        {
            return existing.clone();
        }
        let record = AgentRecord { surface, state, source, session, updated_at_ms: now_ms() };
        records.insert(surface, record.clone());
        record
    }

    /// Drop per-surface metadata for a surface that has left the tree.
    /// `SurfaceId` is monotonic, so without this every closed tab would
    /// leak an entry forever and `list-agents` would keep reporting dead
    /// surfaces as live agents.
    fn purge_surface_side_tables(&self, surface: SurfaceId) {
        self.agent_records.lock().unwrap().remove(&surface);
        let mut sizing = self.client_sizing.lock().unwrap();
        sizing.surfaces.remove(&surface);
        sizing.report_order.retain(|(reported_surface, _), _| *reported_surface != surface);
        let attached_clients = self.control_clients.attached_client_ids();
        self.reconcile_latest_client_size(&sizing, &attached_clients);
    }

    pub fn list_agents(
        &self,
        surface: Option<SurfaceId>,
        state: Option<AgentState>,
    ) -> Vec<AgentRecord> {
        let mut records = self.agent_records.lock().unwrap().values().cloned().collect::<Vec<_>>();
        records.sort_by_key(|record| record.surface);
        records
            .into_iter()
            .filter(|record| surface.is_none_or(|surface| record.surface == surface))
            .filter(|record| state.is_none_or(|state| record.state == state))
            .collect()
    }

    pub fn shutdown(&self) {
        for runtime in self.renderer_presentations.lock().unwrap().take_all() {
            let scene = runtime.scene.lock().unwrap();
            scene.canceled.store(true, Ordering::Release);
            scene.control.detach();
        }
        self.renderer_supervisor.lock().unwrap().take();
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            surface.kill();
        }
        if let Some(runtime) = self.browser_runtime.lock().unwrap().take() {
            runtime.shutdown();
        }
    }

    /// Install the process owner before accepting presentation commands.
    /// cmuxd retains this handle so Swift app restarts do not affect workers.
    pub fn install_renderer_supervisor(
        self: &Arc<Self>,
        config: RendererSupervisorConfig,
    ) -> anyhow::Result<()> {
        let mut slot = self.renderer_supervisor.lock().unwrap();
        if slot.is_some() {
            anyhow::bail!("renderer supervisor is already installed");
        }
        let supervisor = Arc::new(RendererSupervisor::start(config)?);
        let mux = Arc::downgrade(self);
        supervisor.set_event_handler(Arc::new(move |event| {
            let Some(mux) = mux.upgrade() else { return };
            let _ = std::thread::Builder::new()
                .name("cmux-renderer-event".to_owned())
                .spawn(move || mux.handle_renderer_supervisor_event(event));
        }));
        *slot = Some(supervisor);
        Ok(())
    }

    pub(crate) fn set_renderer_presentation_workspace(
        &self,
        presentation_id: crate::PresentationId,
        workspace_uuid: Option<WorkspaceUuid>,
    ) -> Result<(), RendererSupervisorError> {
        let supervisor = self.renderer_supervisor.lock().unwrap().clone();
        match supervisor {
            Some(supervisor) => {
                supervisor.set_presentation_workspace(presentation_id, workspace_uuid)
            }
            None => Ok(()),
        }
    }

    pub(crate) fn remove_renderer_presentation(
        &self,
        presentation_id: crate::PresentationId,
    ) -> Result<(), RendererSupervisorError> {
        self.invalidate_renderer_presentation(presentation_id);
        self.renderer_presentation_generations.lock().unwrap().remove(&presentation_id);
        let supervisor = self.renderer_supervisor.lock().unwrap().clone();
        match supervisor {
            Some(supervisor) => supervisor.remove_presentation(presentation_id),
            None => Ok(()),
        }
    }

    pub fn renderer_worker_statuses(&self) -> Vec<RendererWorkerStatus> {
        self.renderer_supervisor
            .lock()
            .unwrap()
            .as_ref()
            .map(|supervisor| supervisor.statuses())
            .unwrap_or_default()
    }

    pub fn renderer_worker_status(
        &self,
        workspace_uuid: WorkspaceUuid,
    ) -> Result<Option<RendererWorkerStatus>, RendererSupervisorError> {
        let supervisor = self.renderer_supervisor.lock().unwrap().clone();
        match supervisor {
            Some(supervisor) => supervisor.workspace_status(workspace_uuid),
            None => Ok(None),
        }
    }

    pub(crate) fn configure_renderer_presentation(
        self: &Arc<Self>,
        client: u64,
        presentation_id: crate::PresentationId,
        expected_generation: u64,
        configuration: RendererPresentationConfiguration,
    ) -> anyhow::Result<RendererPresentationReceipt> {
        if configuration.columns == 0 || configuration.rows == 0 {
            anyhow::bail!("renderer terminal columns and rows must be nonzero");
        }
        let presentation = self.presentations.get_for_client(client, presentation_id)?;
        if presentation.generation != expected_generation {
            anyhow::bail!(
                "stale presentation generation {expected_generation}; current generation is {}",
                presentation.generation
            );
        }
        let (workspace_uuid, surface_id, surface) = {
            let state = self.state.lock().unwrap();
            let workspace_id = presentation
                .view
                .workspace
                .ok_or_else(|| anyhow::anyhow!("renderer presentation requires a workspace"))?;
            let surface_id = presentation
                .view
                .tab
                .ok_or_else(|| anyhow::anyhow!("renderer presentation requires a surface"))?;
            let pane_id = state
                .indexed_pane_of(surface_id)
                .ok_or_else(|| anyhow::anyhow!("renderer surface is outside canonical topology"))?;
            let (workspace_index, _) = state
                .indexed_screen_of(pane_id)
                .ok_or_else(|| anyhow::anyhow!("renderer pane is outside canonical topology"))?;
            let workspace = &state.workspaces[workspace_index];
            if workspace.id != workspace_id
                || presentation.view.workspace_uuid != Some(workspace.uuid)
                || presentation.view.surface_uuid != state.surface_uuid(surface_id)
            {
                anyhow::bail!("renderer surface is outside its presentation workspace");
            }
            let surface = state
                .surfaces
                .get(&surface_id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("unknown renderer surface {surface_id}"))?;
            Ok::<_, anyhow::Error>((workspace.uuid, surface_id, surface))
        }?;
        let terminal = surface
            .semantic_scene_terminal_identity()
            .ok_or_else(|| anyhow::anyhow!("browser surfaces have no terminal renderer"))?;

        let supervisor = self
            .renderer_supervisor
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| anyhow::anyhow!("renderer supervisor is not installed"))?;
        supervisor.set_presentation_workspace(presentation_id, Some(workspace_uuid))?;
        let worker = supervisor
            .workspace_status(workspace_uuid)?
            .ok_or_else(|| anyhow::anyhow!("renderer worker was not created"))?;

        self.apply_renderer_configuration_size(
            surface_id,
            client,
            configuration.columns,
            configuration.rows,
        )?;
        let (columns, rows) = surface.size();
        let renderer_generation = {
            let generations = self.renderer_presentation_generations.lock().unwrap();
            match generations.get(&presentation_id).copied() {
                Some(previous) => previous
                    .checked_add(1)
                    .ok_or_else(|| anyhow::anyhow!("renderer presentation generation exhausted"))?
                    .max(presentation.generation),
                None => presentation.generation.max(1),
            }
        };
        let attachment = RendererPresentationAttachment {
            terminal_id: terminal.terminal_id.as_uuid(),
            terminal_epoch: terminal.runtime_epoch,
            presentation_id: presentation_id.as_uuid(),
            presentation_generation: renderer_generation,
            width: configuration.width,
            height: configuration.height,
            backing_scale_factor: configuration.backing_scale_factor,
            pixel_format: configuration.pixel_format,
            color_space: configuration.color_space,
            frame_endpoint_service: configuration.frame_endpoint_service.clone(),
            frame_endpoint_capability: configuration.frame_endpoint_capability.clone(),
            resolved_config_revision: configuration.resolved_config_revision,
            resolved_config: configuration.resolved_config.clone(),
        };
        let mut validator = RendererControlEncoder::new(RendererControlDirection::DaemonToWorker);
        validator.encode(RendererControlMessage::UpsertPresentation(attachment.clone()))?;

        let custom_shader_count = resolved_custom_shader_count(&configuration.resolved_config)?;
        let capture = SemanticSceneCaptureOptions {
            focused: configuration.focused,
            cursor_blink_visible: configuration.cursor_blink_visible,
            custom_shader_count,
            ..SemanticSceneCaptureOptions::default()
        };
        let mut scene_options = SemanticSceneAttachmentOptions::new(
            terminal,
            SemanticScenePresentationIdentity { presentation_id, generation: renderer_generation },
        );
        scene_options.capture = capture;
        scene_options.preedit = configuration.preedit.as_ref().map(RendererPreedit::semantic);
        let scene_attachment = surface.attach_semantic_scene(scene_options)?;
        let minimum_content_sequence = scene_attachment.initial.content_sequence;
        let initial = renderer_semantic_scene(&scene_attachment.initial);
        let canceled = Arc::new(AtomicBool::new(false));
        let runtime = Arc::new(RendererPresentationRuntime {
            client,
            workspace_uuid,
            surface: surface.clone(),
            attachment: attachment.clone(),
            capture,
            preedit: Mutex::new(configuration.preedit),
            scene: Mutex::new(RendererSceneBinding {
                control: scene_attachment.control,
                canceled: canceled.clone(),
                renderer_epoch: worker.renderer_epoch,
            }),
            bound_renderer_epoch: Mutex::new(0),
        });

        // Recheck connection ownership after the potentially expensive full
        // capture so a racing disconnect cannot install an orphan runtime.
        let current = self.presentations.get_for_client(client, presentation_id)?;
        if current.generation != presentation.generation {
            anyhow::bail!("presentation changed while its renderer was attaching");
        }
        let previous =
            self.renderer_presentations.lock().unwrap().insert(presentation_id, runtime.clone());
        let focus_changed = previous.as_ref().map_or(configuration.focused, |previous| {
            previous.capture.focused != configuration.focused
        });
        if focus_changed {
            surface.terminal_accessibility_focus_changed();
        }
        self.renderer_presentation_generations
            .lock()
            .unwrap()
            .insert(presentation_id, renderer_generation);
        if let Some(previous) = previous {
            self.retire_renderer_runtime(&previous);
        }
        // Re-read worker state only after publishing the runtime. WorkerReady
        // may race anywhere in this interval, but claim_renderer_epoch makes
        // either this path or rehydrate_renderer_workspace the sole binder for
        // the observed epoch. A Ready event that ran before insertion is
        // recovered by this exact coordinator snapshot.
        let worker = match supervisor.workspace_status(workspace_uuid) {
            Ok(Some(worker)) => worker,
            Ok(None) => {
                self.remove_renderer_runtime_if_current(&runtime);
                anyhow::bail!("renderer worker disappeared while attaching");
            }
            Err(error) => {
                self.remove_renderer_runtime_if_current(&runtime);
                return Err(error.into());
            }
        };
        if worker.state == RendererWorkerState::Ready {
            if let Some(_epoch_claim) = runtime.claim_renderer_epoch(worker.renderer_epoch) {
                runtime.scene.lock().unwrap().renderer_epoch = worker.renderer_epoch;
                self.remember_renderer_release_route(&runtime, worker.renderer_epoch);
                if let Err(error) = supervisor.send_if_epoch(
                    workspace_uuid,
                    worker.renderer_epoch,
                    vec![
                        RendererControlMessage::UpsertPresentation(attachment),
                        RendererControlMessage::SemanticScene(initial),
                    ],
                ) {
                    self.remove_renderer_runtime_if_current(&runtime);
                    return Err(error.into());
                }
            }
        }
        self.spawn_renderer_scene_pump(runtime, scene_attachment.events, canceled);

        Ok(RendererPresentationReceipt {
            daemon_instance_id: self.daemon_instance_id,
            worker,
            terminal_id: terminal.terminal_id,
            terminal_epoch: terminal.runtime_epoch,
            presentation_id,
            canonical_presentation_generation: presentation.generation,
            renderer_presentation_generation: renderer_generation,
            minimum_content_sequence,
            width: configuration.width,
            height: configuration.height,
            backing_scale_factor: configuration.backing_scale_factor,
            columns,
            rows,
            pixel_format: configuration.pixel_format,
            color_space: configuration.color_space,
        })
    }

    pub(crate) fn terminal_accessibility_snapshot(
        &self,
        client: u64,
        presentation_id: crate::PresentationId,
        expected_generation: u64,
        expected_content_sequence: u64,
    ) -> anyhow::Result<crate::TerminalAccessibilitySnapshot> {
        let presentation = self.presentations.get_for_client(client, presentation_id)?;
        if presentation.generation != expected_generation {
            anyhow::bail!(
                "stale presentation generation {expected_generation}; current generation is {}",
                presentation.generation
            );
        }
        let surface_uuid = presentation
            .view
            .surface_uuid
            .ok_or_else(|| anyhow::anyhow!("accessibility presentation requires a terminal"))?;
        let surface = self.with_state(|state| {
            let surface_id = state
                .surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface_uuid}"))?;
            state
                .surfaces
                .get(&surface_id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface_uuid}"))
        })?;
        let runtime = self
            .renderer_presentations
            .lock()
            .unwrap()
            .get(&presentation_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("accessibility presentation is not rendered"))?;
        if runtime.client != client || runtime.surface.uuid != surface_uuid {
            anyhow::bail!("accessibility presentation authority changed");
        }
        surface.terminal_accessibility_snapshot_at(
            presentation_id,
            presentation.generation,
            runtime.capture.focused,
            expected_content_sequence,
        )
    }

    pub(crate) fn activate_terminal_accessibility_link(
        &self,
        client: u64,
        presentation_id: crate::PresentationId,
        expected_generation: u64,
        terminal_revision: u64,
        content_revision: u64,
        viewport_revision: u64,
        link_id: &str,
    ) -> anyhow::Result<String> {
        let presentation = self.presentations.get_for_client(client, presentation_id)?;
        if presentation.generation != expected_generation {
            anyhow::bail!(
                "stale presentation generation {expected_generation}; current generation is {}",
                presentation.generation
            );
        }
        let surface_uuid = presentation
            .view
            .surface_uuid
            .ok_or_else(|| anyhow::anyhow!("accessibility presentation requires a terminal"))?;
        let surface = self.with_state(|state| {
            let surface_id = state
                .surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface_uuid}"))?;
            state
                .surfaces
                .get(&surface_id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface_uuid}"))
        })?;
        let runtime = self
            .renderer_presentations
            .lock()
            .unwrap()
            .get(&presentation_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("accessibility presentation is not rendered"))?;
        if runtime.client != client || runtime.surface.uuid != surface_uuid {
            anyhow::bail!("accessibility presentation authority changed");
        }
        surface.activate_terminal_accessibility_link(
            presentation_id,
            presentation.generation,
            runtime.capture.focused,
            terminal_revision,
            content_revision,
            viewport_revision,
            link_id,
        )
    }

    pub(crate) fn terminal_hyperlink_at_viewport_cell(
        &self,
        client: u64,
        presentation_id: crate::PresentationId,
        expected_generation: u64,
        expected_content_sequence: u64,
        column: u16,
        row: u16,
    ) -> anyhow::Result<crate::surface::TerminalHyperlinkHit> {
        let presentation = self.presentations.get_for_client(client, presentation_id)?;
        if presentation.generation != expected_generation {
            anyhow::bail!(
                "stale presentation generation {expected_generation}; current generation is {}",
                presentation.generation
            );
        }
        let surface_uuid = presentation
            .view
            .surface_uuid
            .ok_or_else(|| anyhow::anyhow!("hyperlink presentation requires a terminal"))?;
        let surface = self.with_state(|state| {
            let surface_id = state
                .surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface_uuid}"))?;
            state
                .surfaces
                .get(&surface_id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface_uuid}"))
        })?;
        let runtime = self
            .renderer_presentations
            .lock()
            .unwrap()
            .get(&presentation_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("hyperlink presentation is not rendered"))?;
        if runtime.client != client || runtime.surface.uuid != surface_uuid {
            anyhow::bail!("hyperlink presentation authority changed");
        }
        surface.terminal_hyperlink_at_viewport_cell(
            presentation_id,
            presentation.generation,
            runtime.capture.focused,
            expected_content_sequence,
            column,
            row,
        )
    }

    /// Protocol v9 sends geometry only after acquiring terminal control. A
    /// renderer configuration makes the presentation visible, but does not
    /// itself authorize a PTY resize. Protocol v8 retains the legacy
    /// smallest-viewer report exactly as before.
    pub(crate) fn apply_renderer_configuration_size(
        &self,
        surface: SurfaceId,
        client: u64,
        columns: u16,
        rows: u16,
    ) -> anyhow::Result<()> {
        if self.control_clients.negotiated_protocol(client)? < 9 {
            self.resize_surface_for_client(surface, client, columns, rows)?;
        }
        Ok(())
    }

    pub(crate) fn set_renderer_preedit(
        &self,
        client: u64,
        presentation_id: crate::PresentationId,
        renderer_generation: u64,
        preedit: Option<RendererPreedit>,
    ) -> anyhow::Result<()> {
        let runtime = self
            .renderer_presentations
            .lock()
            .unwrap()
            .get(&presentation_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("renderer presentation is not attached"))?;
        if runtime.client != client {
            anyhow::bail!("presentation {presentation_id} is owned by another client");
        }
        if runtime.attachment.presentation_generation != renderer_generation {
            anyhow::bail!(
                "stale renderer presentation generation {renderer_generation}; current generation is {}",
                runtime.attachment.presentation_generation
            );
        }
        *runtime.preedit.lock().unwrap() = preedit.clone();
        runtime
            .scene
            .lock()
            .unwrap()
            .control
            .set_preedit_state(preedit.as_ref().map(RendererPreedit::semantic));
        Ok(())
    }

    pub(crate) fn detach_renderer_presentation(
        &self,
        client: u64,
        presentation_id: crate::PresentationId,
        expected_generation: u64,
    ) -> anyhow::Result<()> {
        let presentation = self.presentations.get_for_client(client, presentation_id)?;
        if presentation.generation != expected_generation {
            anyhow::bail!(
                "stale presentation generation {expected_generation}; current generation is {}",
                presentation.generation
            );
        }
        let runtime = self.renderer_presentations.lock().unwrap().get(&presentation_id).cloned();
        if let Some(runtime) = runtime {
            if runtime.client != client {
                anyhow::bail!("presentation {presentation_id} is owned by another client");
            }
            self.remove_renderer_runtime_if_current(&runtime);
        }
        Ok(())
    }

    pub(crate) fn release_renderer_frame(
        &self,
        client: u64,
        release: RendererFrameRelease,
    ) -> anyhow::Result<bool> {
        if release.daemon_instance_id != self.daemon_instance_id.as_uuid() {
            anyhow::bail!("renderer frame release daemon identity is stale");
        }
        let presentation_id = presentation_id_from_uuid(release.presentation_id);
        let key = RendererReleaseRouteKey {
            presentation_id,
            presentation_generation: release.presentation_generation,
            renderer_epoch: release.renderer_epoch,
        };
        let route = self
            .renderer_release_routes
            .lock()
            .unwrap()
            .values
            .get(&key)
            .copied()
            .ok_or_else(|| anyhow::anyhow!("unknown or expired renderer frame lease"))?;
        if route.client != client
            || route.terminal_id.as_uuid() != release.terminal_id
            || route.terminal_epoch != release.terminal_epoch
        {
            anyhow::bail!("renderer frame release fence mismatch");
        }
        let supervisor = self
            .renderer_supervisor
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| anyhow::anyhow!("renderer supervisor is not installed"))?;
        let Some(status) = supervisor.workspace_status(route.workspace_uuid)? else {
            return Ok(false);
        };
        if status.renderer_epoch != release.renderer_epoch
            || status.state != RendererWorkerState::Ready
        {
            return Ok(false);
        }
        supervisor.send_if_epoch(
            route.workspace_uuid,
            release.renderer_epoch,
            vec![RendererControlMessage::FrameRelease(release)],
        )?;
        Ok(true)
    }

    pub(crate) fn invalidate_renderer_presentation(&self, presentation_id: crate::PresentationId) {
        if let Some(runtime) = self.renderer_presentations.lock().unwrap().remove(&presentation_id)
        {
            self.retire_renderer_runtime(&runtime);
        }
    }

    fn retire_renderer_runtime(&self, runtime: &RendererPresentationRuntime) {
        let scene = runtime.scene.lock().unwrap();
        scene.canceled.store(true, Ordering::Release);
        scene.control.detach();
        if let Some(supervisor) = self.renderer_supervisor.lock().unwrap().clone() {
            let _ = supervisor.send_if_epoch(
                runtime.workspace_uuid,
                scene.renderer_epoch,
                vec![RendererControlMessage::RemovePresentation(RendererPresentationRemoval {
                    terminal_id: runtime.attachment.terminal_id,
                    terminal_epoch: runtime.attachment.terminal_epoch,
                    presentation_id: runtime.attachment.presentation_id,
                    presentation_generation: runtime.attachment.presentation_generation,
                })],
            );
        }
    }

    fn remove_renderer_runtime_if_current(&self, runtime: &Arc<RendererPresentationRuntime>) {
        let removed = {
            let mut runtimes = self.renderer_presentations.lock().unwrap();
            runtimes.remove_if_current(
                presentation_id_from_uuid(runtime.attachment.presentation_id),
                runtime,
            )
        };
        if let Some(removed) = removed {
            self.retire_renderer_runtime(&removed);
        }
    }

    fn remember_renderer_release_route(
        &self,
        runtime: &RendererPresentationRuntime,
        renderer_epoch: u64,
    ) {
        self.renderer_release_routes.lock().unwrap().insert(
            RendererReleaseRouteKey {
                presentation_id: presentation_id_from_uuid(runtime.attachment.presentation_id),
                presentation_generation: runtime.attachment.presentation_generation,
                renderer_epoch,
            },
            RendererReleaseRoute {
                client: runtime.client,
                workspace_uuid: runtime.workspace_uuid,
                terminal_id: surface_uuid_from_uuid(runtime.attachment.terminal_id),
                terminal_epoch: runtime.attachment.terminal_epoch,
            },
        );
    }

    fn spawn_renderer_scene_pump(
        self: &Arc<Self>,
        runtime: Arc<RendererPresentationRuntime>,
        events: SemanticSceneReceiver,
        canceled: Arc<AtomicBool>,
    ) {
        let mux = Arc::downgrade(self);
        let _ =
            std::thread::Builder::new().name("cmux-renderer-scene".to_owned()).spawn(move || {
                while !canceled.load(Ordering::Acquire) {
                    match events.recv_timeout(RENDERER_SCENE_PUMP_POLL) {
                        Ok(SemanticSceneEvent::Scene(frame)) => {
                            let Some(mux) = mux.upgrade() else { break };
                            if !mux.forward_renderer_scene(&runtime, frame) {
                                break;
                            }
                        }
                        Ok(SemanticSceneEvent::Failed(_)) | Err(RecvTimeoutError::Disconnected) => {
                            if let Some(mux) = mux.upgrade() {
                                mux.remove_renderer_runtime_if_current(&runtime);
                            }
                            break;
                        }
                        Err(RecvTimeoutError::Timeout) => {}
                    }
                }
            });
    }

    fn forward_renderer_scene(
        &self,
        runtime: &Arc<RendererPresentationRuntime>,
        frame: SemanticSceneFrame,
    ) -> bool {
        let presentation_id = presentation_id_from_uuid(runtime.attachment.presentation_id);
        if !self
            .renderer_presentations
            .lock()
            .unwrap()
            .get(&presentation_id)
            .is_some_and(|current| Arc::ptr_eq(current, runtime))
            || frame.terminal.terminal_id.as_uuid() != runtime.attachment.terminal_id
            || frame.terminal.runtime_epoch != runtime.attachment.terminal_epoch
            || frame.presentation.presentation_id != presentation_id
            || frame.presentation.generation != runtime.attachment.presentation_generation
        {
            return false;
        }
        let renderer_epoch = runtime.scene.lock().unwrap().renderer_epoch;
        let Some(supervisor) = self.renderer_supervisor.lock().unwrap().clone() else {
            return false;
        };
        if supervisor
            .send_if_epoch(
                runtime.workspace_uuid,
                renderer_epoch,
                vec![RendererControlMessage::SemanticScene(renderer_semantic_scene(&frame))],
            )
            .is_err()
        {
            self.remove_renderer_runtime_if_current(runtime);
            return false;
        }
        true
    }

    fn handle_renderer_supervisor_event(self: &Arc<Self>, event: RendererSupervisorEvent) {
        match event {
            RendererSupervisorEvent::WorkerReady {
                workspace_uuid,
                renderer_epoch,
                process_id,
                ..
            } => {
                let status = self.renderer_worker_status(workspace_uuid).ok().flatten();
                self.emit(MuxEvent::RendererWorkerChanged {
                    workspace_uuid,
                    prior_renderer_epoch: renderer_epoch,
                    prior_process_id: Some(process_id),
                    status,
                    reason: None,
                });
                self.rehydrate_renderer_workspace(workspace_uuid, renderer_epoch);
            }
            RendererSupervisorEvent::NeedsFullScene { workspace_uuid, renderer_epoch, request } => {
                let presentation_id = presentation_id_from_uuid(request.presentation_id);
                let runtime =
                    self.renderer_presentations.lock().unwrap().get(&presentation_id).cloned();
                let Some(runtime) = runtime else { return };
                let scene = runtime.scene.lock().unwrap();
                if runtime.workspace_uuid == workspace_uuid
                    && scene.renderer_epoch == renderer_epoch
                    && runtime.attachment.terminal_id == request.terminal_id
                    && runtime.attachment.terminal_epoch == request.terminal_epoch
                    && runtime.attachment.presentation_generation == request.presentation_generation
                {
                    scene.control.request_full_scene();
                }
            }
            RendererSupervisorEvent::WorkerUnavailable {
                workspace_uuid,
                renderer_epoch,
                process_id,
                reason,
            } => {
                let status = self.renderer_worker_status(workspace_uuid).ok().flatten();
                self.emit(MuxEvent::RendererWorkerChanged {
                    workspace_uuid,
                    prior_renderer_epoch: renderer_epoch,
                    prior_process_id: process_id,
                    status,
                    reason: Some(reason.into()),
                });
            }
            RendererSupervisorEvent::PresentationReady {
                workspace_uuid,
                renderer_epoch,
                process_id,
                metrics,
            } => {
                let presentation_id = presentation_id_from_uuid(metrics.presentation_id);
                let runtime =
                    self.renderer_presentations.lock().unwrap().get(&presentation_id).cloned();
                let Some(runtime) = runtime else { return };
                if runtime.workspace_uuid != workspace_uuid
                    || runtime.attachment.terminal_id != metrics.terminal_id
                    || runtime.attachment.terminal_epoch != metrics.terminal_epoch
                    || runtime.attachment.presentation_generation != metrics.presentation_generation
                    || runtime.scene.lock().unwrap().renderer_epoch != renderer_epoch
                {
                    return;
                }
                let Some(status) =
                    self.renderer_worker_status(workspace_uuid).ok().flatten().filter(|status| {
                        status.renderer_epoch == renderer_epoch
                            && status.state == RendererWorkerState::Ready
                            && status.pid == Some(process_id)
                    })
                else {
                    return;
                };
                let Some(effective_user_id) = status.effective_user_id else { return };
                self.emit(MuxEvent::RendererPresentationReady {
                    workspace_uuid,
                    renderer_epoch,
                    process_id,
                    effective_user_id,
                    metrics,
                });
            }
        }
    }

    fn rehydrate_renderer_workspace(
        self: &Arc<Self>,
        workspace_uuid: WorkspaceUuid,
        renderer_epoch: u64,
    ) {
        let runtimes =
            self.renderer_presentations.lock().unwrap().runtimes_for_workspace(workspace_uuid);
        for runtime in runtimes {
            let Some(_epoch_claim) = runtime.claim_renderer_epoch(renderer_epoch) else { continue };
            let terminal = runtime.surface.semantic_scene_terminal_identity();
            let Some(terminal) = terminal else {
                self.remove_renderer_runtime_if_current(&runtime);
                continue;
            };
            let mut options = SemanticSceneAttachmentOptions::new(
                terminal,
                SemanticScenePresentationIdentity {
                    presentation_id: presentation_id_from_uuid(runtime.attachment.presentation_id),
                    generation: runtime.attachment.presentation_generation,
                },
            );
            options.capture = runtime.capture;
            options.preedit =
                runtime.preedit.lock().unwrap().as_ref().map(RendererPreedit::semantic);
            let Ok(attachment) = runtime.surface.attach_semantic_scene(options) else {
                self.remove_renderer_runtime_if_current(&runtime);
                continue;
            };
            if !self
                .renderer_presentations
                .lock()
                .unwrap()
                .get(&presentation_id_from_uuid(runtime.attachment.presentation_id))
                .is_some_and(|current| Arc::ptr_eq(current, &runtime))
            {
                attachment.control.detach();
                continue;
            }
            let initial = renderer_semantic_scene(&attachment.initial);
            let canceled = Arc::new(AtomicBool::new(false));
            {
                let mut scene = runtime.scene.lock().unwrap();
                scene.canceled.store(true, Ordering::Release);
                scene.control.detach();
                *scene = RendererSceneBinding {
                    control: attachment.control,
                    canceled: canceled.clone(),
                    renderer_epoch,
                };
            }
            self.remember_renderer_release_route(&runtime, renderer_epoch);
            let Some(supervisor) = self.renderer_supervisor.lock().unwrap().clone() else {
                return;
            };
            if supervisor
                .send_if_epoch(
                    workspace_uuid,
                    renderer_epoch,
                    vec![
                        RendererControlMessage::UpsertPresentation(runtime.attachment.clone()),
                        RendererControlMessage::SemanticScene(initial),
                    ],
                )
                .is_err()
            {
                self.remove_renderer_runtime_if_current(&runtime);
                continue;
            }
            self.spawn_renderer_scene_pump(runtime.clone(), attachment.events, canceled);
        }
    }

    fn reconcile_renderer_workspaces(&self) {
        let live = self.with_state(|state| {
            state.workspaces.iter().map(|workspace| workspace.uuid).collect::<BTreeSet<_>>()
        });
        let retired = self
            .renderer_presentations
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(presentation, runtime)| {
                (!live.contains(&runtime.workspace_uuid)).then_some(*presentation)
            })
            .collect::<Vec<_>>();
        for presentation in retired {
            self.invalidate_renderer_presentation(presentation);
        }
        if let Some(supervisor) = self.renderer_supervisor.lock().unwrap().clone() {
            let _ = supervisor.retain_workspaces(live);
        }
    }

    pub fn send_renderer_control(
        &self,
        workspace_uuid: WorkspaceUuid,
        message: RendererControlMessage,
    ) -> Result<(), RendererSupervisorError> {
        self.renderer_supervisor
            .lock()
            .unwrap()
            .as_ref()
            .ok_or(RendererSupervisorError::UnknownWorkspace(workspace_uuid))?
            .send(workspace_uuid, message)
    }

    /// Update options used for future surface/browser launches.
    pub fn update_surface_options(&self, update: impl FnOnce(&mut SurfaceOptions)) {
        let mut options = self.surface_options.lock().unwrap();
        update(&mut options);
        options.browser_session_name = self.session.clone();
    }

    pub fn configure_sidebar_plugin(&self, options: Option<SidebarPluginOptions>) {
        let old_surface = {
            let mut runtime = self.sidebar_plugin.lock().unwrap();
            if runtime.options == options {
                return;
            }
            runtime.options = options;
            runtime.last_error = None;
            runtime.failures = 0;
            runtime.retry_at = None;
            runtime.surface.take()
        };
        if let Some(surface) =
            old_surface.and_then(|id| self.state.lock().unwrap().discard_surface_runtime(id))
        {
            surface.kill();
            self.emit(MuxEvent::SurfaceExited(surface.id));
        }
    }

    pub fn ensure_sidebar_plugin(
        self: &Arc<Self>,
        cols: u16,
        rows: u16,
        relaunch: bool,
    ) -> SidebarPluginStatus {
        let now = Instant::now();
        let size = (cols.max(1), rows.max(1));
        let spawn_options = {
            let mut runtime = self.sidebar_plugin.lock().unwrap();
            let Some(options) = runtime.options.clone() else {
                return SidebarPluginStatus { surface: None, error: None, retry_after: None };
            };
            if let Some(surface_id) = runtime.surface {
                if let Some(surface) = self.surface(surface_id).filter(|surface| !surface.is_dead())
                {
                    drop(runtime);
                    let _ = self.resize_surface(surface_id, size.0, size.1);
                    drop(surface);
                    return SidebarPluginStatus {
                        surface: Some(surface_id),
                        error: None,
                        retry_after: None,
                    };
                }
                runtime.surface = None;
            }
            if let Some(error) = runtime.last_error.clone() {
                let retry_after = runtime.retry_at.and_then(|retry_at| {
                    (retry_at > now).then_some(retry_at.saturating_duration_since(now))
                });
                if !relaunch || retry_after.is_some() {
                    return SidebarPluginStatus { surface: None, error: Some(error), retry_after };
                }
            }
            options
        };
        match self.spawn_sidebar_plugin_surface(&spawn_options, size) {
            Ok(surface) => {
                let surface_id = surface.id;
                {
                    let mut runtime = self.sidebar_plugin.lock().unwrap();
                    runtime.surface = Some(surface_id);
                    runtime.last_error = None;
                    runtime.failures = 0;
                    runtime.retry_at = None;
                }
                self.reap_if_dead(&surface);
                SidebarPluginStatus { surface: Some(surface_id), error: None, retry_after: None }
            }
            Err(err) => {
                let mut runtime = self.sidebar_plugin.lock().unwrap();
                runtime.surface = None;
                runtime.failures = runtime.failures.saturating_add(1);
                let delay = sidebar_retry_delay(runtime.failures);
                let message = format!("sidebar plugin failed to start: {err}");
                runtime.last_error = Some(message.clone());
                runtime.retry_at = Some(now + delay);
                SidebarPluginStatus {
                    surface: None,
                    error: Some(message),
                    retry_after: Some(delay),
                }
            }
        }
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> CellPixelUpdate {
        self.set_cell_pixel_size_reporting(width_px, height_px, Arc::new(|_, _, _| {}))
    }

    pub fn set_cell_pixel_size_reporting(
        &self,
        width_px: u16,
        height_px: u16,
        report: SurfaceResizeReporter,
    ) -> CellPixelUpdate {
        let next = (width_px.max(1), height_px.max(1));
        // This is the desired global metric used for new browser surfaces.
        // Existing surfaces still check their settled geometry on every call,
        // so a rejected queue submission can be retried with the same value.
        *self.cell_pixels.lock().unwrap() = next;
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        let mut update = CellPixelUpdate::default();
        for surface in surfaces {
            let id = surface.id;
            let size = surface.size();
            let callback = report.clone();
            match surface.set_cell_pixel_size_reporting(
                next.0,
                next.1,
                Box::new(move |accepted| callback(id, size, accepted)),
            ) {
                Ok(Some(reservation_id)) => update.resizes.push((id, size, reservation_id)),
                Ok(None) => {}
                Err(error) => update
                    .failures
                    .push(CellPixelUpdateFailure { surface: id, error: error.to_string() }),
            }
        }
        update
    }

    pub fn default_colors(&self) -> DefaultColors {
        self.default_colors.lock().unwrap().1
    }

    pub fn default_colors_snapshot(&self) -> (u64, DefaultColors) {
        *self.default_colors.lock().unwrap()
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        let revision = {
            let mut current = self.default_colors.lock().unwrap();
            if current.1 == colors {
                return;
            }
            current.0 = current.0.checked_add(1).expect("default colors revision exhausted");
            current.1 = colors;
            current.0
        };
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit(MuxEvent::SurfaceOutput(surface.id));
        }
        self.emit(MuxEvent::RendererConfigInvalidated {
            revision,
            reason: Arc::<str>::from("default-colors-changed"),
            default_colors: colors,
        });
    }

    /// Resize a surface and broadcast the final clamped size when it actually
    /// changes. Browser workers broadcast after their asynchronous CDP work.
    pub fn resize_surface(&self, id: SurfaceId, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_surface_with_reservation(id, cols, rows).map(|(accepted, _)| accepted)
    }

    pub fn resize_surface_with_reservation(
        &self,
        id: SurfaceId,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<(bool, Option<u64>)> {
        let Some(surface) = self.surface(id) else {
            anyhow::bail!("unknown surface {id}");
        };
        // Not recorded as a client size here: internal resizes (e.g. the
        // sidebar plugin surface tracking the TUI rect every frame) also land
        // in this method and must not become the default for new surfaces.
        // Client interactions record explicitly at the protocol/TUI layers.
        let (cols, rows) = clamp_terminal_size(cols, rows);
        if surface.as_browser().is_some() {
            let reservation_id =
                surface.resize_reporting_acceptance(cols, rows, Box::new(|_| {}))?;
            return Ok((reservation_id.is_some(), reservation_id));
        }
        if !surface.resize(cols, rows)? {
            return Ok((false, None));
        }
        let (cols, rows) = surface.size();
        self.emit(MuxEvent::SurfaceResized { surface: id, cols, rows, reservation_id: None });
        Ok((true, None))
    }

    /// Atomically resolve or create one app-owned terminal identity. The
    /// creation lock spans the existence check, PTY spawn, topology commit,
    /// and one-time initial input, so concurrent/reconnected callers can
    /// never spawn duplicates or replay startup text.
    pub(crate) fn ensure_terminal(
        self: &Arc<Self>,
        request: EnsureTerminalRequest,
    ) -> anyhow::Result<EnsureTerminalPlacement> {
        validate_ensure_terminal_request(&request)?;

        let _creation = self.ensure_terminal_lock.lock().unwrap();
        {
            let state = self.state.lock().unwrap();
            if state.tombstones.iter().any(|tombstone| {
                (tombstone.kind == PersistedEntityKind::Surface
                    && tombstone.uuid == request.surface_uuid.as_uuid())
                    || (tombstone.kind == PersistedEntityKind::Workspace
                        && tombstone.uuid == request.workspace_uuid.as_uuid())
            }) {
                anyhow::bail!(
                    "ensure-terminal identity is tombstoned and cannot be recreated: workspace {}, surface {}",
                    request.workspace_uuid,
                    request.surface_uuid
                );
            }
        }
        if let Some(existing) = {
            let state = self.state.lock().unwrap();
            ensure_terminal_placement_for_surface(
                &state,
                request.workspace_uuid,
                request.surface_uuid,
                false,
            )
        }? {
            return Ok(existing);
        }

        let (surface_id, _) = self.entity_ids.surface();
        let mut prepared = self.prepare_surface_with_allocated_identity(
            surface_id,
            request.surface_uuid,
            request.cwd.clone(),
            request.argv.clone(),
            request.env.clone(),
            Some(request.wait_after_command),
            Some((request.cols, request.rows)),
            None,
            request.initial_input.clone(),
        )?;
        let surface = prepared.surface.clone();
        let notifications = self.surface_notifications();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let (placement, delta) = {
            let mut state = self.state.lock().unwrap();
            if state
                .indexed_surface_id_by_uuid(request.surface_uuid)
                .is_some_and(|existing| existing != surface.id)
            {
                surface.kill();
                anyhow::bail!("ensure-terminal surface UUID was created concurrently");
            }
            state.surfaces.insert(surface.id, surface.clone());
            state.launch_recipes.insert(
                request.surface_uuid,
                prepared.launch.take().expect("unpublished terminal has launch recipe"),
            );

            if let Some(workspace_index) =
                state.indexed_workspace_index_by_uuid(request.workspace_uuid)
            {
                let screen_index = state.workspaces[workspace_index].active_screen;
                let screen =
                    state.workspaces[workspace_index].screens.get(screen_index).ok_or_else(
                        || anyhow::anyhow!("ensure-terminal workspace has no active screen"),
                    )?;
                let pane_id = screen.active_pane;
                let screen_id = screen.id;
                let screen_uuid = screen.uuid;
                let workspace_id = state.workspaces[workspace_index].id;
                let pane = state
                    .panes
                    .get_mut(&pane_id)
                    .ok_or_else(|| anyhow::anyhow!("ensure-terminal active pane is missing"))?;
                pane.tabs.push(surface.id);
                pane.active_tab = pane.tabs.len() - 1;
                pane.active_at = self.next_active_at();
                let pane_uuid = pane.uuid;
                let index = pane.tabs.len() - 1;
                let targets = topology_targets(
                    &state,
                    Some(workspace_id),
                    Some(screen_id),
                    Some(pane_id),
                    Some(surface.id),
                );
                state.commit_topology(TopologyOperation::SurfaceAttached, targets);
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::TabAdded,
                    surface.id,
                )
                .expect("ensured terminal is present in tree snapshot");
                (
                    EnsureTerminalPlacement {
                        created: true,
                        workspace: workspace_id,
                        workspace_uuid: request.workspace_uuid,
                        screen: screen_id,
                        screen_uuid,
                        pane: pane_id,
                        pane_uuid,
                        surface: surface.id,
                        surface_uuid: request.surface_uuid,
                    },
                    TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace: workspace_id,
                        screen: Some(screen_id),
                        pane: Some(pane_id),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                    },
                )
            } else {
                let (pane_id, pane) = self.make_pane(surface.id);
                let pane_uuid = pane.uuid;
                let (screen_id, screen_uuid) = self.entity_ids.screen();
                let (workspace_id, _) = self.entity_ids.workspace();
                let name = format!("{}", state.workspaces.len() + 1);
                state.panes.insert(pane_id, pane);
                state.workspaces.push(Workspace {
                    id: workspace_id,
                    uuid: request.workspace_uuid,
                    name,
                    screens: vec![Screen {
                        id: screen_id,
                        uuid: screen_uuid,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                let targets = topology_targets(
                    &state,
                    Some(workspace_id),
                    Some(screen_id),
                    Some(pane_id),
                    Some(surface.id),
                );
                state.commit_topology(TopologyOperation::WorkspaceCreated, targets);
                let index = state.workspaces.len() - 1;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::WorkspaceAdded,
                    workspace_id,
                )
                .expect("ensured workspace is present in tree snapshot");
                (
                    EnsureTerminalPlacement {
                        created: true,
                        workspace: workspace_id,
                        workspace_uuid: request.workspace_uuid,
                        screen: screen_id,
                        screen_uuid,
                        pane: pane_id,
                        pane_uuid,
                        surface: surface.id,
                        surface_uuid: request.surface_uuid,
                    },
                    TreeDelta {
                        kind: TreeDeltaKind::WorkspaceAdded,
                        workspace: workspace_id,
                        screen: None,
                        pane: None,
                        surface: None,
                        index: Some(index),
                        entity,
                    },
                )
            }
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeDelta(delta));
        self.reap_if_dead(&surface);
        Ok(placement)
    }

    /// Resolve or materialize a cold set of app-owned terminals in one
    /// canonical transaction. Runtimes remain private until every spawn and
    /// topology precondition succeeds, so readers never observe a partial
    /// restore and persistence records one replacement snapshot.
    pub(crate) fn ensure_terminals(
        self: &Arc<Self>,
        requests: Vec<EnsureTerminalRequest>,
    ) -> anyhow::Result<Vec<EnsureTerminalPlacement>> {
        if requests.len() > MAX_ENSURE_TERMINAL_BATCH_SIZE {
            anyhow::bail!(
                "ensure-terminal batch exceeds {MAX_ENSURE_TERMINAL_BATCH_SIZE} requests"
            );
        }
        let mut surface_uuids = HashSet::with_capacity(requests.len());
        for request in &requests {
            validate_ensure_terminal_request(request)?;
            if !surface_uuids.insert(request.surface_uuid) {
                anyhow::bail!(
                    "ensure-terminal batch contains duplicate surface UUID {}",
                    request.surface_uuid
                );
            }
        }
        if requests.is_empty() {
            return Ok(Vec::new());
        }

        let _creation = self.ensure_terminal_lock.lock().unwrap();
        let mut placements = vec![None; requests.len()];
        let mut missing = Vec::new();
        let expected_topology_revision = {
            let state = self.state.lock().unwrap();
            let tombstoned_workspaces = state
                .tombstones
                .iter()
                .filter_map(|tombstone| {
                    (tombstone.kind == PersistedEntityKind::Workspace).then_some(tombstone.uuid)
                })
                .collect::<HashSet<_>>();
            let tombstoned_surfaces = state
                .tombstones
                .iter()
                .filter_map(|tombstone| {
                    (tombstone.kind == PersistedEntityKind::Surface).then_some(tombstone.uuid)
                })
                .collect::<HashSet<_>>();
            let mut unresolved_workspaces = HashSet::new();
            for (index, request) in requests.iter().enumerate() {
                if tombstoned_workspaces.contains(&request.workspace_uuid.as_uuid())
                    || tombstoned_surfaces.contains(&request.surface_uuid.as_uuid())
                {
                    anyhow::bail!(
                        "ensure-terminal identity is tombstoned and cannot be recreated: workspace {}, surface {}",
                        request.workspace_uuid,
                        request.surface_uuid
                    );
                }
                match ensure_terminal_placement_for_surface(
                    &state,
                    request.workspace_uuid,
                    request.surface_uuid,
                    false,
                )? {
                    Some(placement) => placements[index] = Some(placement),
                    None => {
                        missing.push(index);
                        unresolved_workspaces.insert(request.workspace_uuid);
                    }
                }
            }
            // Validate existing workspace destinations before spending work
            // on any process spawn. New workspace identities resolve to None.
            for workspace_uuid in unresolved_workspaces {
                let _ = ensure_terminal_workspace_location(&state, workspace_uuid)?;
            }
            state.topology.revision()
        };
        if missing.is_empty() {
            return Ok(placements
                .into_iter()
                .map(|placement| placement.expect("every terminal resolved"))
                .collect());
        }

        struct SpawnedTerminal {
            request_index: usize,
            prepared: PreparedTerminalLaunch,
        }

        let mut spawned: Vec<SpawnedTerminal> = Vec::with_capacity(missing.len());
        let mut spawned_position_by_request = vec![None; requests.len()];
        for request_index in missing.iter().copied() {
            let request = &requests[request_index];
            #[cfg(test)]
            if self.ensure_terminal_batch_fail_spawn_at.load(Ordering::Relaxed)
                == spawned.len() as u64 + 1
            {
                for spawned in &spawned {
                    spawned.prepared.surface.kill();
                }
                anyhow::bail!("injected ensure-terminal batch spawn failure");
            }
            let (surface_id, _) = self.entity_ids.surface();
            let created = self.prepare_surface_with_allocated_identity(
                surface_id,
                request.surface_uuid,
                request.cwd.clone(),
                request.argv.clone(),
                request.env.clone(),
                Some(request.wait_after_command),
                Some((request.cols, request.rows)),
                None,
                request.initial_input.clone(),
            );
            let prepared = match created {
                Ok(created) => created,
                Err(error) => {
                    for spawned in &spawned {
                        spawned.prepared.surface.kill();
                    }
                    return Err(error);
                }
            };
            spawned_position_by_request[request_index] = Some(spawned.len());
            spawned.push(SpawnedTerminal { request_index, prepared });
        }

        #[cfg(test)]
        if let Some(before_publish) =
            self.ensure_terminal_batch_before_publish.lock().unwrap().clone()
        {
            before_publish();
        }

        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let transaction = (|| -> anyhow::Result<()> {
            let mut state = self.state.lock().unwrap();
            if state.topology.revision() != expected_topology_revision {
                anyhow::bail!("ensure-terminal topology changed during batch materialization");
            }

            // Existing resolutions must remain identical across the private
            // spawn window. Any concurrent topology change aborts before the
            // new runtimes are published.
            for (index, placement) in placements.iter_mut().enumerate() {
                let Some(previous) = *placement else { continue };
                let current = ensure_terminal_placement_for_surface(
                    &state,
                    requests[index].workspace_uuid,
                    requests[index].surface_uuid,
                    false,
                )?
                .ok_or_else(|| {
                    anyhow::anyhow!("ensure-terminal topology changed during batch materialization")
                })?;
                if current.surface != previous.surface
                    || current.workspace != previous.workspace
                    || current.pane != previous.pane
                {
                    anyhow::bail!("ensure-terminal topology changed during batch materialization");
                }
                *placement = Some(current);
            }

            let tombstoned_workspaces = state
                .tombstones
                .iter()
                .filter_map(|tombstone| {
                    (tombstone.kind == PersistedEntityKind::Workspace).then_some(tombstone.uuid)
                })
                .collect::<HashSet<_>>();
            let tombstoned_surfaces = state
                .tombstones
                .iter()
                .filter_map(|tombstone| {
                    (tombstone.kind == PersistedEntityKind::Surface).then_some(tombstone.uuid)
                })
                .collect::<HashSet<_>>();

            let mut workspace_order = Vec::new();
            let mut request_indices_by_workspace =
                HashMap::<WorkspaceUuid, Vec<usize>>::with_capacity(missing.len());
            for request_index in missing.iter().copied() {
                let request = &requests[request_index];
                if tombstoned_workspaces.contains(&request.workspace_uuid.as_uuid())
                    || tombstoned_surfaces.contains(&request.surface_uuid.as_uuid())
                {
                    anyhow::bail!(
                        "ensure-terminal identity was tombstoned during batch materialization"
                    );
                }
                if ensure_terminal_placement_for_surface(
                    &state,
                    request.workspace_uuid,
                    request.surface_uuid,
                    false,
                )?
                .is_some()
                {
                    anyhow::bail!(
                        "ensure-terminal surface was created during batch materialization"
                    );
                }
                if !request_indices_by_workspace.contains_key(&request.workspace_uuid) {
                    workspace_order.push(request.workspace_uuid);
                }
                request_indices_by_workspace
                    .entry(request.workspace_uuid)
                    .or_default()
                    .push(request_index);
            }

            let mut locations = HashMap::with_capacity(workspace_order.len());
            for workspace_uuid in workspace_order.iter().copied() {
                let location = match ensure_terminal_workspace_location(&state, workspace_uuid)? {
                    Some(location) => location,
                    None => {
                        let (pane, pane_uuid) = self.entity_ids.pane();
                        let (screen, screen_uuid) = self.entity_ids.screen();
                        let (workspace, _) = self.entity_ids.workspace();
                        EnsureTerminalWorkspaceLocation {
                            workspace,
                            screen,
                            screen_uuid,
                            pane,
                            pane_uuid,
                            new_workspace: true,
                        }
                    }
                };
                locations.insert(workspace_uuid, location);
            }

            let targets = TopologyTargets {
                workspaces: workspace_order.clone(),
                screens: workspace_order
                    .iter()
                    .map(|workspace_uuid| locations[workspace_uuid].screen_uuid)
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect(),
                panes: workspace_order
                    .iter()
                    .map(|workspace_uuid| locations[workspace_uuid].pane_uuid)
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect(),
                surfaces: missing.iter().map(|index| requests[*index].surface_uuid).collect(),
            };

            // All fallible planning is complete. Publish runtimes, attach
            // them to panes, and commit one revision while holding the state
            // lock so readers see either the old topology or the full batch.
            for terminal in &mut spawned {
                let request = &requests[terminal.request_index];
                let previous_surface = state
                    .surfaces
                    .insert(terminal.prepared.surface.id, terminal.prepared.surface.clone());
                debug_assert!(previous_surface.is_none());
                let previous_launch = state.launch_recipes.insert(
                    request.surface_uuid,
                    terminal
                        .prepared
                        .launch
                        .take()
                        .expect("unpublished terminal has launch recipe"),
                );
                debug_assert!(previous_launch.is_none());
            }

            for workspace_uuid in workspace_order.iter().copied() {
                let location = locations[&workspace_uuid];
                let request_indices = &request_indices_by_workspace[&workspace_uuid];
                let tabs = request_indices
                    .iter()
                    .map(|request_index| {
                        let position = spawned_position_by_request[*request_index]
                            .expect("missing request has spawned runtime");
                        spawned[position].prepared.surface.id
                    })
                    .collect::<Vec<_>>();
                if location.new_workspace {
                    state.panes.insert(
                        location.pane,
                        Pane {
                            id: location.pane,
                            uuid: location.pane_uuid,
                            name: None,
                            active_tab: tabs.len() - 1,
                            tabs,
                            active_at: self.next_active_at(),
                        },
                    );
                    let name = format!("{}", state.workspaces.len() + 1);
                    state.workspaces.push(Workspace {
                        id: location.workspace,
                        uuid: workspace_uuid,
                        name,
                        screens: vec![Screen {
                            id: location.screen,
                            uuid: location.screen_uuid,
                            name: None,
                            root: Node::Leaf(location.pane),
                            active_pane: location.pane,
                            zoomed_pane: None,
                        }],
                        active_screen: 0,
                    });
                    state.active_workspace = state.workspaces.len() - 1;
                } else {
                    let pane = state
                        .panes
                        .get_mut(&location.pane)
                        .expect("validated ensure-terminal pane remains present");
                    pane.tabs.extend(tabs);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = self.next_active_at();
                }
                for request_index in request_indices {
                    let position = spawned_position_by_request[*request_index]
                        .expect("missing request has spawned runtime");
                    let surface = &spawned[position].prepared.surface;
                    placements[*request_index] = Some(EnsureTerminalPlacement {
                        created: true,
                        workspace: location.workspace,
                        workspace_uuid,
                        screen: location.screen,
                        screen_uuid: location.screen_uuid,
                        pane: location.pane,
                        pane_uuid: location.pane_uuid,
                        surface: surface.id,
                        surface_uuid: surface.uuid,
                    });
                }
            }
            state.commit_topology(TopologyOperation::LayoutApplied, targets);
            Ok(())
        })();

        if let Err(error) = transaction {
            drop(terminal_control);
            for terminal in &spawned {
                terminal.prepared.surface.kill();
            }
            return Err(error);
        }

        let surfaces =
            spawned.iter().map(|terminal| terminal.prepared.surface.clone()).collect::<Vec<_>>();
        for terminal in spawned {
            self.complete_committed_terminal_launch(terminal.prepared);
        }
        drop(terminal_control);
        for surface in surfaces {
            self.reap_if_dead(&surface);
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(placements
            .into_iter()
            .map(|placement| placement.expect("every terminal resolved or materialized"))
            .collect())
    }

    /// Move one stable terminal identity into the target workspace's active
    /// pane without replacing its runtime. The topology mutation commits once
    /// and retries are no-ops after the terminal reaches the target workspace.
    pub(crate) fn reparent_terminal(
        &self,
        surface_uuid: SurfaceUuid,
        workspace_uuid: WorkspaceUuid,
    ) -> anyhow::Result<ReparentTerminalPlacement> {
        if surface_uuid.as_uuid().is_nil() || workspace_uuid.as_uuid().is_nil() {
            anyhow::bail!("reparent-terminal UUIDs must be nonzero");
        }

        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (placement, renderer_presentations) = {
            let mut state = self.state.lock().unwrap();
            let surface_id = state
                .indexed_surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown terminal surface {surface_uuid}"))?;
            let surface = state
                .surfaces
                .get(&surface_id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("terminal surface runtime is missing"))?;
            if surface.semantic_scene_terminal_identity().is_none() {
                anyhow::bail!("surface {surface_uuid} is not a terminal");
            }
            let source_pane = state
                .indexed_pane_of(surface_id)
                .ok_or_else(|| anyhow::anyhow!("terminal surface is outside canonical topology"))?;
            let (source_workspace_index, _) = state
                .indexed_screen_of(source_pane)
                .ok_or_else(|| anyhow::anyhow!("terminal pane is outside canonical topology"))?;
            let target_workspace_index = state
                .indexed_workspace_index_by_uuid(workspace_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown target workspace {workspace_uuid}"))?;

            if source_workspace_index == target_workspace_index {
                let placement = ensure_terminal_placement_for_surface(
                    &state,
                    workspace_uuid,
                    surface_uuid,
                    false,
                )?
                .expect("resolved terminal remains in canonical topology");
                (
                    ReparentTerminalPlacement {
                        moved: false,
                        workspace: placement.workspace,
                        workspace_uuid: placement.workspace_uuid,
                        screen: placement.screen,
                        screen_uuid: placement.screen_uuid,
                        pane: placement.pane,
                        pane_uuid: placement.pane_uuid,
                        surface: placement.surface,
                        surface_uuid: placement.surface_uuid,
                    },
                    Vec::new(),
                )
            } else {
                let target_screen_index = state.workspaces[target_workspace_index].active_screen;
                let target_screen = state.workspaces[target_workspace_index]
                    .screens
                    .get(target_screen_index)
                    .ok_or_else(|| anyhow::anyhow!("target workspace has no active screen"))?;
                let target_pane = target_screen.active_pane;
                if !state.panes.contains_key(&target_pane) {
                    anyhow::bail!("target workspace active pane is missing");
                }

                let mut targets = TopologyTargets::from_legacy(
                    &state,
                    None,
                    None,
                    Some(source_pane),
                    Some(surface_id),
                );
                if !move_tab_in_state(&mut state, surface_id, target_pane, usize::MAX) {
                    anyhow::bail!("terminal could not be moved to the target workspace");
                }
                stamp_pane(&mut state, target_pane, self.next_active_at());
                targets.merge(TopologyTargets::from_legacy(
                    &state,
                    None,
                    None,
                    Some(target_pane),
                    Some(surface_id),
                ));
                state.commit_topology(TopologyOperation::TabMoved, targets);

                let placement = ensure_terminal_placement_for_surface(
                    &state,
                    workspace_uuid,
                    surface_uuid,
                    false,
                )?
                .expect("moved terminal remains in canonical topology");
                let renderer_presentations = self
                    .renderer_presentations
                    .lock()
                    .unwrap()
                    .iter()
                    .filter_map(|(presentation_id, runtime)| {
                        (runtime.attachment.terminal_id == surface_uuid.as_uuid())
                            .then_some(*presentation_id)
                    })
                    .collect::<Vec<_>>();
                (
                    ReparentTerminalPlacement {
                        moved: true,
                        workspace: placement.workspace,
                        workspace_uuid: placement.workspace_uuid,
                        screen: placement.screen,
                        screen_uuid: placement.screen_uuid,
                        pane: placement.pane,
                        pane_uuid: placement.pane_uuid,
                        surface: placement.surface,
                        surface_uuid: placement.surface_uuid,
                    },
                    renderer_presentations,
                )
            }
        };

        if placement.moved {
            // A renderer is scoped to one workspace worker. Retire the old
            // attachment before the frontend updates its presentation and
            // reconfigures, whose first scene is always a full scene.
            for presentation_id in renderer_presentations {
                self.invalidate_renderer_presentation(presentation_id);
                let _ =
                    self.set_renderer_presentation_workspace(presentation_id, Some(workspace_uuid));
            }
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(placement)
    }

    fn rehome_renderer_presentations(&self, surface: SurfaceId, workspace_uuid: WorkspaceUuid) {
        let Some(surface_uuid) = self.with_state(|state| state.surface_uuid(surface)) else {
            return;
        };
        let presentations = self
            .renderer_presentations
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(presentation_id, runtime)| {
                (runtime.attachment.terminal_id == surface_uuid.as_uuid())
                    .then_some(*presentation_id)
            })
            .collect::<Vec<_>>();
        for presentation_id in presentations {
            self.invalidate_renderer_presentation(presentation_id);
            let _ = self.set_renderer_presentation_workspace(presentation_id, Some(workspace_uuid));
        }
    }

    /// Creates an exactly identified workspace and terminal under one
    /// authority/revision fence. The child and one-time input remain private
    /// until the canonical commit is guaranteed to succeed.
    pub(crate) fn canonical_new_workspace(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        name: Option<String>,
        size: Option<(u16, u16)>,
        launch: TerminalLaunchRequest,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        validate_terminal_launch_request(&launch)?;
        if workspace_uuid.as_uuid().is_nil() || surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("canonical creation UUIDs must be nonzero");
        }
        if let Some(name) = &name {
            validate_terminal_launch_text(
                "workspace name",
                name,
                MAX_TERMINAL_LAUNCH_STRING_BYTES,
            )?;
        }
        let payload_digest = canonical_payload_digest(
            "new-workspace",
            &(workspace_uuid, surface_uuid, &name, size, &launch),
        )?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let key = {
            let state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "new-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.workspaces.contains(&workspace_uuid)
                        || !result.surfaces.contains(&surface_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            }
        };
        {
            let state = self.state.lock().unwrap();
            if state.indexed_workspace_index_by_uuid(workspace_uuid).is_some()
                || state.indexed_surface_id_by_uuid(surface_uuid).is_some()
                || state.tombstones.iter().any(|tombstone| {
                    tombstone.uuid == workspace_uuid.as_uuid()
                        || tombstone.uuid == surface_uuid.as_uuid()
                })
            {
                anyhow::bail!("canonical creation identity already exists or is tombstoned");
            }
        }
        let (surface_id, _) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
        let surface = prepared.surface.clone();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let transaction = (|| -> anyhow::Result<CanonicalSurfacePlacement> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "new-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                CanonicalMutationStart::Fresh { .. } => {
                    anyhow::bail!("canonical mutation key changed during creation")
                }
                CanonicalMutationStart::Replay { .. } => {
                    anyhow::bail!("canonical mutation unexpectedly replayed during creation")
                }
            }
            if state.indexed_workspace_index_by_uuid(workspace_uuid).is_some()
                || state.indexed_surface_id_by_uuid(surface_uuid).is_some()
            {
                anyhow::bail!("canonical creation identity appeared during spawn");
            }
            let (pane_id, pane_uuid) = self.entity_ids.pane();
            let (screen_id, screen_uuid) = self.entity_ids.screen();
            let (workspace_id, _) = self.entity_ids.workspace();
            state.surfaces.insert(surface.id, surface.clone());
            state.launch_recipes.insert(
                surface_uuid,
                prepared.launch.take().expect("unpublished terminal has launch recipe"),
            );
            state.panes.insert(
                pane_id,
                Pane {
                    id: pane_id,
                    uuid: pane_uuid,
                    name: None,
                    tabs: vec![surface.id],
                    active_tab: 0,
                    active_at: self.next_active_at(),
                },
            );
            let workspace_name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            state.workspaces.push(Workspace {
                id: workspace_id,
                uuid: workspace_uuid,
                name: workspace_name,
                screens: vec![Screen {
                    id: screen_id,
                    uuid: screen_uuid,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                }],
                active_screen: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
            let targets = TopologyTargets {
                workspaces: vec![workspace_uuid],
                screens: vec![screen_uuid],
                panes: vec![pane_uuid],
                surfaces: vec![surface_uuid],
            };
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::WorkspaceCreated,
                targets,
                key,
            );
            canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)
        })();
        let placement = match transaction {
            Ok(placement) => placement,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&surface);
        Ok(placement)
    }

    /// Materializes one exactly identified terminal in the active pane of an
    /// existing canonical workspace.
    pub(crate) fn canonical_materialize_terminal(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        size: Option<(u16, u16)>,
        mut launch: TerminalLaunchRequest,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        validate_terminal_launch_request(&launch)?;
        if workspace_uuid.as_uuid().is_nil() || surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("canonical materialization UUIDs must be nonzero");
        }
        let payload_digest = canonical_payload_digest(
            "materialize-terminal",
            &(workspace_uuid, surface_uuid, size, &launch),
        )?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (key, target_pane_uuid, inherited_cwd) = {
            let state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "materialize-terminal",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.workspaces.contains(&workspace_uuid)
                        || !result.surfaces.contains(&surface_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let workspace_index = state
                .indexed_workspace_index_by_uuid(workspace_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical workspace {workspace_uuid}"))?;
            let screen = state.workspaces[workspace_index]
                .screens
                .get(state.workspaces[workspace_index].active_screen)
                .ok_or_else(|| anyhow::anyhow!("canonical workspace has no active screen"))?;
            let pane = state
                .panes
                .get(&screen.active_pane)
                .ok_or_else(|| anyhow::anyhow!("canonical workspace active pane is missing"))?;
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some()
                || state.tombstones.iter().any(|tombstone| {
                    tombstone.kind == PersistedEntityKind::Surface
                        && tombstone.uuid == surface_uuid.as_uuid()
                })
            {
                anyhow::bail!(
                    "canonical materialized surface identity already exists or is tombstoned"
                );
            }
            let inherited =
                pane.active_surface().and_then(|surface| state.surfaces.get(&surface).cloned());
            (key, pane.uuid, inherited)
        };
        if launch.cwd.is_none() {
            launch.cwd = inherited_cwd.and_then(|surface| surface.pwd());
        }
        let (surface_id, _) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
        let surface = prepared.surface.clone();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let transaction = (|| -> anyhow::Result<CanonicalSurfacePlacement> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "materialize-terminal",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical materialization fence changed during spawn"),
            }
            let workspace_index = state
                .indexed_workspace_index_by_uuid(workspace_uuid)
                .ok_or_else(|| anyhow::anyhow!("canonical workspace disappeared during spawn"))?;
            let target_pane = state
                .pane_id_by_uuid(target_pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("canonical active pane disappeared during spawn"))?;
            let (actual_workspace_index, screen_index) = state
                .screen_of(target_pane)
                .ok_or_else(|| anyhow::anyhow!("canonical active pane has no screen"))?;
            if actual_workspace_index != workspace_index {
                anyhow::bail!("canonical active pane moved to another workspace during spawn");
            }
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical materialized surface UUID appeared during spawn");
            }
            state.surfaces.insert(surface.id, surface.clone());
            state.launch_recipes.insert(
                surface_uuid,
                prepared.launch.take().expect("unpublished terminal has launch recipe"),
            );
            let pane = state
                .panes
                .get_mut(&target_pane)
                .expect("stable active pane resolved immediately before attach");
            pane.tabs.push(surface.id);
            pane.active_tab = pane.tabs.len() - 1;
            pane.active_at = self.next_active_at();
            state.active_workspace = workspace_index;
            state.workspaces[workspace_index].active_screen = screen_index;
            state.workspaces[workspace_index].screens[screen_index].active_pane = target_pane;
            let targets = TopologyTargets::from_legacy(
                &state,
                Some(state.workspaces[workspace_index].id),
                Some(state.workspaces[workspace_index].screens[screen_index].id),
                Some(target_pane),
                Some(surface.id),
            );
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::SurfaceAttached,
                targets,
                key,
            );
            canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)
        })();
        let placement = match transaction {
            Ok(placement) => placement,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&surface);
        Ok(placement)
    }

    /// Atomically creates a workspace whose first surface owns only parser and
    /// renderer state. The remote tmux reconnect source stays in daemon memory.
    pub(crate) fn canonical_new_external_workspace(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        size: (u16, u16),
        no_reflow: bool,
        provenance: ExternalTerminalProvenance,
        producer_source: RemoteTmuxProducerSource,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        provenance.validate()?;
        producer_source.validate()?;
        if workspace_uuid.as_uuid().is_nil()
            || surface_uuid.as_uuid().is_nil()
            || size.0 == 0
            || size.1 == 0
        {
            anyhow::bail!("canonical external workspace identity and size must be nonzero");
        }
        let payload_digest = canonical_payload_digest(
            "new-external-workspace",
            &(workspace_uuid, surface_uuid, size, no_reflow, provenance),
        )?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let key = {
            let state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "new-external-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.workspaces.contains(&workspace_uuid)
                        || !result.surfaces.contains(&surface_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    self.remote_tmux_producers.ensure_surface(
                        provenance,
                        surface_uuid,
                        Some(producer_source),
                    )?;
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            }
        };
        {
            let state = self.state.lock().unwrap();
            if state.indexed_workspace_index_by_uuid(workspace_uuid).is_some()
                || state.indexed_surface_id_by_uuid(surface_uuid).is_some()
                || state.tombstones.iter().any(|tombstone| {
                    tombstone.uuid == workspace_uuid.as_uuid()
                        || tombstone.uuid == surface_uuid.as_uuid()
                })
            {
                anyhow::bail!(
                    "canonical external workspace identity already exists or is tombstoned"
                );
            }
        }
        let (surface_id, _) = self.entity_ids.surface();
        let surface = self.create_external_terminal_with_provenance(
            surface_id,
            surface_uuid,
            size,
            no_reflow,
            Some(provenance),
        )?;
        let transaction = (|| -> anyhow::Result<CanonicalSurfacePlacement> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "new-external-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical external workspace fence changed during creation"),
            }
            if state.indexed_workspace_index_by_uuid(workspace_uuid).is_some()
                || state.indexed_surface_id_by_uuid(surface_uuid).is_some()
            {
                anyhow::bail!("canonical external workspace identity appeared during creation");
            }
            let commit = || -> anyhow::Result<CanonicalSurfacePlacement> {
                let (pane_id, pane_uuid) = self.entity_ids.pane();
                let (screen_id, screen_uuid) = self.entity_ids.screen();
                let (workspace_id, _) = self.entity_ids.workspace();
                state.surfaces.insert(surface.id, surface.clone());
                state.panes.insert(
                    pane_id,
                    Pane {
                        id: pane_id,
                        uuid: pane_uuid,
                        name: None,
                        tabs: vec![surface.id],
                        active_tab: 0,
                        active_at: self.next_active_at(),
                    },
                );
                let workspace_name = format!("{}", state.workspaces.len() + 1);
                state.workspaces.push(Workspace {
                    id: workspace_id,
                    uuid: workspace_uuid,
                    name: workspace_name,
                    screens: vec![Screen {
                        id: screen_id,
                        uuid: screen_uuid,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                let targets = TopologyTargets {
                    workspaces: vec![workspace_uuid],
                    screens: vec![screen_uuid],
                    panes: vec![pane_uuid],
                    surfaces: vec![surface_uuid],
                };
                let receipt = self.commit_canonical_mutation(
                    &mut state,
                    TopologyOperation::WorkspaceCreated,
                    targets,
                    key,
                );
                canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)
            };
            self.remote_tmux_producers.transactionally_register_surface(
                provenance,
                surface_uuid,
                Some(producer_source.clone()),
                commit,
            )
        })();
        let placement = match transaction {
            Ok(placement) => placement,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.emit(MuxEvent::TreeChanged);
        Ok(placement)
    }

    /// Materializes one parser-only terminal in the active pane of an existing
    /// canonical workspace. This surface owns Ghostty state and rendering but
    /// intentionally owns no PTY or child process.
    pub(crate) fn canonical_materialize_external_terminal(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        size: (u16, u16),
        no_reflow: bool,
        provenance: ExternalTerminalProvenance,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        provenance.validate()?;
        if workspace_uuid.as_uuid().is_nil()
            || surface_uuid.as_uuid().is_nil()
            || size.0 == 0
            || size.1 == 0
        {
            anyhow::bail!("canonical external terminal identity and size must be nonzero");
        }
        let payload_digest = canonical_payload_digest(
            "materialize-external-terminal",
            &(workspace_uuid, surface_uuid, size, no_reflow, provenance),
        )?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (key, target_pane_uuid) = {
            let state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "materialize-external-terminal",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.workspaces.contains(&workspace_uuid)
                        || !result.surfaces.contains(&surface_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    self.remote_tmux_producers.ensure_surface(provenance, surface_uuid, None)?;
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let workspace_index = state
                .indexed_workspace_index_by_uuid(workspace_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical workspace {workspace_uuid}"))?;
            let screen = state.workspaces[workspace_index]
                .screens
                .get(state.workspaces[workspace_index].active_screen)
                .ok_or_else(|| anyhow::anyhow!("canonical workspace has no active screen"))?;
            let pane = state
                .panes
                .get(&screen.active_pane)
                .ok_or_else(|| anyhow::anyhow!("canonical workspace active pane is missing"))?;
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some()
                || state.tombstones.iter().any(|tombstone| {
                    tombstone.kind == PersistedEntityKind::Surface
                        && tombstone.uuid == surface_uuid.as_uuid()
                })
            {
                anyhow::bail!(
                    "canonical external surface identity already exists or is tombstoned"
                );
            }
            (key, pane.uuid)
        };
        let (surface_id, _) = self.entity_ids.surface();
        let surface = self.create_external_terminal_with_provenance(
            surface_id,
            surface_uuid,
            size,
            no_reflow,
            Some(provenance),
        )?;
        let transaction = (|| -> anyhow::Result<CanonicalSurfacePlacement> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "materialize-external-terminal",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical external terminal fence changed during creation"),
            }
            let workspace_index =
                state.indexed_workspace_index_by_uuid(workspace_uuid).ok_or_else(|| {
                    anyhow::anyhow!("canonical workspace disappeared during creation")
                })?;
            let target_pane = state.pane_id_by_uuid(target_pane_uuid).ok_or_else(|| {
                anyhow::anyhow!("canonical active pane disappeared during creation")
            })?;
            let (actual_workspace_index, screen_index) = state
                .screen_of(target_pane)
                .ok_or_else(|| anyhow::anyhow!("canonical active pane has no screen"))?;
            if actual_workspace_index != workspace_index {
                anyhow::bail!("canonical active pane moved to another workspace during creation");
            }
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical external surface UUID appeared during creation");
            }
            let commit = || -> anyhow::Result<CanonicalSurfacePlacement> {
                state.surfaces.insert(surface.id, surface.clone());
                let pane = state
                    .panes
                    .get_mut(&target_pane)
                    .expect("stable active pane resolved immediately before external attach");
                pane.tabs.push(surface.id);
                pane.active_tab = pane.tabs.len() - 1;
                pane.active_at = self.next_active_at();
                state.active_workspace = workspace_index;
                state.workspaces[workspace_index].active_screen = screen_index;
                state.workspaces[workspace_index].screens[screen_index].active_pane = target_pane;
                let targets = TopologyTargets::from_legacy(
                    &state,
                    Some(state.workspaces[workspace_index].id),
                    Some(state.workspaces[workspace_index].screens[screen_index].id),
                    Some(target_pane),
                    Some(surface.id),
                );
                let receipt = self.commit_canonical_mutation(
                    &mut state,
                    TopologyOperation::SurfaceAttached,
                    targets,
                    key,
                );
                canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)
            };
            self.remote_tmux_producers.transactionally_register_existing_surface(
                provenance,
                surface_uuid,
                commit,
            )
        })();
        let placement = match transaction {
            Ok(placement) => placement,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.emit(MuxEvent::TreeChanged);
        Ok(placement)
    }

    pub(crate) fn claim_external_terminal(
        &self,
        surface_uuid: SurfaceUuid,
        owner: ExternalTerminalOwner,
        request_id: uuid::Uuid,
    ) -> anyhow::Result<ExternalTerminalClaimReceipt> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        let surface = self.surface_by_uuid(surface_uuid)?;
        surface.claim_external_terminal(owner, request_id)
    }

    pub(crate) fn reset_external_terminal(
        &self,
        surface_uuid: SurfaceUuid,
        owner: ExternalTerminalOwner,
        owner_generation: u64,
        request_id: uuid::Uuid,
        output_generation: u64,
        cols: u16,
        rows: u16,
        no_reflow: bool,
        seed: &[u8],
    ) -> anyhow::Result<ExternalTerminalOutputReceipt> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        let surface = self.surface_by_uuid(surface_uuid)?;
        let receipt = surface.reset_external_terminal(
            owner,
            owner_generation,
            request_id,
            output_generation,
            cols,
            rows,
            no_reflow,
            seed,
        )?;
        if !receipt.replayed {
            let mut state = self.state.lock().unwrap();
            let revision = state.topology.revision();
            state.persist(
                revision,
                format!("external-terminal-policy:{surface_uuid}:{request_id}"),
                None,
            );
        }
        Ok(receipt)
    }

    pub(crate) fn apply_external_terminal_output(
        &self,
        surface_uuid: SurfaceUuid,
        owner: ExternalTerminalOwner,
        owner_generation: u64,
        request_id: uuid::Uuid,
        output_generation: u64,
        sequence: u64,
        bytes: &[u8],
    ) -> anyhow::Result<ExternalTerminalOutputReceipt> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        let surface = self.surface_by_uuid(surface_uuid)?;
        surface.apply_external_terminal_output(
            owner,
            owner_generation,
            request_id,
            output_generation,
            sequence,
            bytes,
        )
    }

    pub(crate) fn drain_external_terminal_egress(
        &self,
        surface_uuid: SurfaceUuid,
        owner: ExternalTerminalOwner,
        owner_generation: u64,
    ) -> anyhow::Result<Vec<u8>> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        let surface = self.surface_by_uuid(surface_uuid)?;
        surface.drain_external_terminal_egress(owner, owner_generation)
    }

    pub(crate) fn claim_frontend_native_browser(
        &self,
        surface_uuid: SurfaceUuid,
        owner: FrontendNativeBrowserOwner,
        request_id: uuid::Uuid,
        source_seed: Option<&str>,
    ) -> anyhow::Result<FrontendNativeBrowserClaimReceipt> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        let surface = self.surface_by_uuid(surface_uuid)?;
        let browser =
            surface.as_browser().ok_or_else(|| anyhow::anyhow!("surface is not a browser"))?;
        if browser.presentation_mode() != BrowserPresentationMode::FrontendNative {
            anyhow::bail!("browser is not frontend-native");
        }
        self.frontend_native_browsers.claim(surface_uuid, owner, request_id, source_seed)
    }

    pub(crate) fn update_frontend_native_browser_source(
        &self,
        surface_uuid: SurfaceUuid,
        owner: FrontendNativeBrowserOwner,
        owner_generation: u64,
        request_id: uuid::Uuid,
        source_url: &str,
    ) -> anyhow::Result<FrontendNativeBrowserSourceReceipt> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        let surface = self.surface_by_uuid(surface_uuid)?;
        let browser =
            surface.as_browser().ok_or_else(|| anyhow::anyhow!("surface is not a browser"))?;
        if browser.presentation_mode() != BrowserPresentationMode::FrontendNative {
            anyhow::bail!("browser is not frontend-native");
        }
        self.frontend_native_browsers.update_source(
            surface_uuid,
            owner,
            owner_generation,
            request_id,
            source_url,
        )
    }

    pub(crate) fn claim_remote_tmux_producer_source(
        &self,
        producer_id: uuid::Uuid,
        owner: RemoteTmuxProducerOwner,
        request_id: uuid::Uuid,
        source_seed: Option<&RemoteTmuxProducerSource>,
    ) -> anyhow::Result<RemoteTmuxProducerClaimReceipt> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        self.remote_tmux_producers.claim(producer_id, owner, request_id, source_seed)
    }

    pub(crate) fn update_remote_tmux_producer_source(
        &self,
        producer_id: uuid::Uuid,
        owner: RemoteTmuxProducerOwner,
        owner_generation: u64,
        request_id: uuid::Uuid,
        source: &RemoteTmuxProducerSource,
    ) -> anyhow::Result<RemoteTmuxProducerSourceUpdateReceipt> {
        let _lifecycle = self.terminal_control_lifecycle.read().unwrap();
        self.remote_tmux_producers.update_source(
            producer_id,
            owner,
            owner_generation,
            request_id,
            source,
        )
    }

    pub(crate) fn release_private_runtime_connection(&self, connection_id: u64) {
        self.frontend_native_browsers.release_connection(connection_id);
        self.remote_tmux_producers.release_connection(connection_id);
    }

    fn surface_by_uuid(&self, surface_uuid: SurfaceUuid) -> anyhow::Result<Arc<Surface>> {
        let state = self.state.lock().unwrap();
        let surface_id = state
            .indexed_surface_id_by_uuid(surface_uuid)
            .ok_or_else(|| anyhow::anyhow!("unknown canonical surface {surface_uuid}"))?;
        state
            .surfaces
            .get(&surface_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("canonical surface runtime is missing"))
    }

    /// Atomically replaces one daemon-owned PTY runtime while preserving its
    /// stable surface UUID and canonical pane/tab position. The retired child
    /// remains invisible to topology readers after the single durable commit.
    pub(crate) fn canonical_respawn_terminal(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        surface_uuid: SurfaceUuid,
        size: Option<(u16, u16)>,
        mut launch: TerminalLaunchRequest,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        validate_terminal_launch_request(&launch)?;
        if surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("canonical respawn surface UUID must be nonzero");
        }
        let payload_digest =
            canonical_payload_digest("respawn-terminal", &(surface_uuid, size, &launch))?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (key, old_surface, resolved_size, inherited_cwd, inherited_name) = {
            let state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "respawn-terminal",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.surfaces.contains(&surface_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let old_surface_id = state
                .indexed_surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical terminal {surface_uuid}"))?;
            let old_surface = state
                .surfaces
                .get(&old_surface_id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("canonical terminal runtime is missing"))?;
            if old_surface.kind() != crate::SurfaceKind::Pty || old_surface.is_external_terminal() {
                anyhow::bail!("canonical respawn requires a daemon-owned PTY terminal");
            }
            if state.indexed_pane_of(old_surface_id).is_none() {
                anyhow::bail!("canonical terminal is outside topology");
            }
            (
                key,
                old_surface.clone(),
                size.or_else(|| Some(old_surface.size())),
                old_surface.pwd(),
                old_surface.name(),
            )
        };
        if launch.cwd.is_none() {
            launch.cwd = inherited_cwd;
        }
        let (new_surface_id, _) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(new_surface_id, surface_uuid, &launch, resolved_size)?;
        let new_surface = prepared.surface.clone();
        new_surface.set_name(inherited_name);

        let _terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let transaction = (|| -> anyhow::Result<CanonicalSurfacePlacement> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "respawn-terminal",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical respawn fence changed during spawn"),
            }
            let current_surface_id = state
                .indexed_surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("canonical terminal disappeared during respawn"))?;
            if current_surface_id != old_surface.id
                || !state
                    .surfaces
                    .get(&current_surface_id)
                    .is_some_and(|surface| Arc::ptr_eq(surface, &old_surface))
            {
                anyhow::bail!("canonical terminal runtime changed during respawn");
            }
            let pane_id = state.indexed_pane_of(current_surface_id).ok_or_else(|| {
                anyhow::anyhow!("canonical terminal left topology during respawn")
            })?;
            let tab_index = state
                .panes
                .get(&pane_id)
                .and_then(|pane| {
                    pane.tabs.iter().position(|surface| *surface == current_surface_id)
                })
                .ok_or_else(|| {
                    anyhow::anyhow!("canonical terminal tab disappeared during respawn")
                })?;
            state.discard_surface_runtime(current_surface_id);
            state.surfaces.insert(new_surface.id, new_surface.clone());
            state.launch_recipes.insert(
                surface_uuid,
                prepared.launch.take().expect("unpublished terminal has launch recipe"),
            );
            let pane = state
                .panes
                .get_mut(&pane_id)
                .expect("respawn pane resolved immediately before replacement");
            pane.tabs[tab_index] = new_surface.id;
            let targets = TopologyTargets::from_legacy(
                &state,
                None,
                None,
                Some(pane_id),
                Some(new_surface.id),
            );
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::SurfaceReplaced,
                targets,
                key,
            );
            Ok(canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)
                .expect("committed respawn surface remains in canonical topology"))
        })();
        let placement = match transaction {
            Ok(placement) => placement,
            Err(error) => {
                new_surface.kill();
                return Err(error);
            }
        };
        self.complete_committed_terminal_launch(prepared);

        self.terminal_authority.retire_terminal(surface_uuid);
        let renderer_presentations = self
            .renderer_presentations
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(presentation_id, runtime)| {
                (runtime.attachment.terminal_id == surface_uuid.as_uuid())
                    .then_some(*presentation_id)
            })
            .collect::<Vec<_>>();
        for presentation_id in renderer_presentations {
            self.invalidate_renderer_presentation(presentation_id);
        }
        self.purge_surface_side_tables(old_surface.id);
        let changed_clients = self.control_clients.clear_surface_sizes(old_surface.id);
        self.emit_client_sizing_changes(changed_clients);
        old_surface.kill();
        drop(_terminal_control);

        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&new_surface);
        Ok(placement)
    }

    /// Creates an exactly identified daemon-owned browser in a new workspace.
    /// CDP bootstrap starts only after the canonical topology and idempotency
    /// result have been durably committed.
    pub(crate) fn canonical_new_browser_workspace(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        name: Option<String>,
        url: String,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        self.canonical_new_browser_workspace_with_presentation(
            expectation,
            workspace_uuid,
            surface_uuid,
            name,
            url,
            size,
            BrowserPresentationMode::DaemonRendered,
        )
    }

    pub(crate) fn canonical_new_browser_workspace_with_presentation(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        name: Option<String>,
        url: String,
        size: Option<(u16, u16)>,
        presentation: BrowserPresentationMode,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        validate_browser_url(&url)?;
        if workspace_uuid.as_uuid().is_nil() || surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("canonical browser creation UUIDs must be nonzero");
        }
        if let Some(name) = &name {
            validate_terminal_launch_text(
                "workspace name",
                name,
                MAX_TERMINAL_LAUNCH_STRING_BYTES,
            )?;
        }
        let payload_digest = match presentation {
            BrowserPresentationMode::DaemonRendered => canonical_payload_digest(
                "new-browser-workspace",
                &(workspace_uuid, surface_uuid, &name, &url, size, presentation.as_str()),
            )?,
            BrowserPresentationMode::FrontendNative => canonical_payload_digest(
                "new-browser-workspace",
                &(workspace_uuid, surface_uuid, &name, size, presentation.as_str()),
            )?,
        };
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let key = {
            let state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "new-browser-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.workspaces.contains(&workspace_uuid)
                        || !result.surfaces.contains(&surface_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    if presentation == BrowserPresentationMode::FrontendNative {
                        self.frontend_native_browsers
                            .ensure_surface_seed(surface_uuid, Some(&url))?;
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            }
        };
        {
            let state = self.state.lock().unwrap();
            if state.indexed_workspace_index_by_uuid(workspace_uuid).is_some()
                || state.indexed_surface_id_by_uuid(surface_uuid).is_some()
                || state.tombstones.iter().any(|tombstone| {
                    tombstone.uuid == workspace_uuid.as_uuid()
                        || tombstone.uuid == surface_uuid.as_uuid()
                })
            {
                anyhow::bail!(
                    "canonical browser creation identity already exists or is tombstoned"
                );
            }
        }
        let (surface_id, _) = self.entity_ids.surface();
        let surface = self.create_browser_surface_with_presentation(
            surface_id,
            surface_uuid,
            url.clone(),
            size,
            presentation,
        );
        let transaction = (|| -> anyhow::Result<CanonicalSurfacePlacement> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "new-browser-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical browser workspace fence changed during creation"),
            }
            if state.indexed_workspace_index_by_uuid(workspace_uuid).is_some()
                || state.indexed_surface_id_by_uuid(surface_uuid).is_some()
            {
                anyhow::bail!("canonical browser identity appeared during creation");
            }
            let commit = || -> anyhow::Result<CanonicalSurfacePlacement> {
                #[cfg(test)]
                if self.canonical_browser_fail_before_commit.load(Ordering::Acquire) {
                    anyhow::bail!("injected canonical browser pre-commit failure");
                }
                let (pane_id, pane_uuid) = self.entity_ids.pane();
                let (screen_id, screen_uuid) = self.entity_ids.screen();
                let (workspace_id, _) = self.entity_ids.workspace();
                state.surfaces.insert(surface.id, surface.clone());
                state.panes.insert(
                    pane_id,
                    Pane {
                        id: pane_id,
                        uuid: pane_uuid,
                        name: None,
                        tabs: vec![surface.id],
                        active_tab: 0,
                        active_at: self.next_active_at(),
                    },
                );
                let workspace_name =
                    name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
                state.workspaces.push(Workspace {
                    id: workspace_id,
                    uuid: workspace_uuid,
                    name: workspace_name,
                    screens: vec![Screen {
                        id: screen_id,
                        uuid: screen_uuid,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                let targets = TopologyTargets {
                    workspaces: vec![workspace_uuid],
                    screens: vec![screen_uuid],
                    panes: vec![pane_uuid],
                    surfaces: vec![surface_uuid],
                };
                let receipt = self.commit_canonical_mutation(
                    &mut state,
                    TopologyOperation::WorkspaceCreated,
                    targets,
                    key,
                );
                canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)
            };
            match presentation {
                BrowserPresentationMode::DaemonRendered => commit(),
                BrowserPresentationMode::FrontendNative => self
                    .frontend_native_browsers
                    .transactionally_insert_surface(surface_uuid, Some(url.clone()), commit),
            }
        })();
        let placement = match transaction {
            Ok(placement) => placement,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.emit(MuxEvent::TreeChanged);
        if presentation == BrowserPresentationMode::DaemonRendered {
            self.start_browser_bootstrap(surface.clone(), BrowserBootstrap::Create { url }, None);
            self.reap_if_dead(&surface);
        }
        Ok(placement)
    }

    /// Creates an exactly identified daemon-owned browser tab in a stable pane.
    pub(crate) fn canonical_new_browser_tab(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        pane_uuid: PaneUuid,
        surface_uuid: SurfaceUuid,
        url: String,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        self.canonical_new_browser_tab_with_presentation(
            expectation,
            pane_uuid,
            surface_uuid,
            url,
            size,
            BrowserPresentationMode::DaemonRendered,
        )
    }

    pub(crate) fn canonical_new_browser_tab_with_presentation(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        pane_uuid: PaneUuid,
        surface_uuid: SurfaceUuid,
        url: String,
        size: Option<(u16, u16)>,
        presentation: BrowserPresentationMode,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        validate_browser_url(&url)?;
        if pane_uuid.as_uuid().is_nil() || surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("canonical browser tab UUIDs must be nonzero");
        }
        let payload_digest = match presentation {
            BrowserPresentationMode::DaemonRendered => canonical_payload_digest(
                "new-browser-tab",
                &(pane_uuid, surface_uuid, &url, size, presentation.as_str()),
            )?,
            BrowserPresentationMode::FrontendNative => canonical_payload_digest(
                "new-browser-tab",
                &(pane_uuid, surface_uuid, size, presentation.as_str()),
            )?,
        };
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let key = {
            let state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "new-browser-tab",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.panes.contains(&pane_uuid)
                        || !result.surfaces.contains(&surface_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    if presentation == BrowserPresentationMode::FrontendNative {
                        self.frontend_native_browsers
                            .ensure_surface_seed(surface_uuid, Some(&url))?;
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            if state.pane_id_by_uuid(pane_uuid).is_none() {
                anyhow::bail!("unknown canonical pane {pane_uuid}");
            }
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical browser surface UUID already exists");
            }
            key
        };
        let (surface_id, _) = self.entity_ids.surface();
        let surface = self.create_browser_surface_with_presentation(
            surface_id,
            surface_uuid,
            url.clone(),
            size,
            presentation,
        );
        let transaction = (|| -> anyhow::Result<CanonicalSurfacePlacement> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "new-browser-tab",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical browser tab fence changed during creation"),
            }
            let pane_id = state
                .pane_id_by_uuid(pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("canonical pane disappeared during creation"))?;
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical browser surface UUID appeared during creation");
            }
            let commit = || -> anyhow::Result<CanonicalSurfacePlacement> {
                #[cfg(test)]
                if self.canonical_browser_fail_before_commit.load(Ordering::Acquire) {
                    anyhow::bail!("injected canonical browser pre-commit failure");
                }
                state.surfaces.insert(surface.id, surface.clone());
                let pane = state
                    .panes
                    .get_mut(&pane_id)
                    .expect("stable pane resolved immediately before browser attach");
                pane.tabs.push(surface.id);
                pane.active_tab = pane.tabs.len() - 1;
                pane.active_at = self.next_active_at();
                let (workspace_index, screen_index) =
                    state.screen_of(pane_id).expect("canonical pane belongs to a screen");
                state.active_workspace = workspace_index;
                state.workspaces[workspace_index].active_screen = screen_index;
                state.workspaces[workspace_index].screens[screen_index].active_pane = pane_id;
                let targets = TopologyTargets::from_legacy(
                    &state,
                    None,
                    None,
                    Some(pane_id),
                    Some(surface.id),
                );
                let receipt = self.commit_canonical_mutation(
                    &mut state,
                    TopologyOperation::SurfaceAttached,
                    targets,
                    key,
                );
                canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)
            };
            match presentation {
                BrowserPresentationMode::DaemonRendered => commit(),
                BrowserPresentationMode::FrontendNative => self
                    .frontend_native_browsers
                    .transactionally_insert_surface(surface_uuid, Some(url.clone()), commit),
            }
        })();
        let placement = match transaction {
            Ok(placement) => placement,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.emit(MuxEvent::TreeChanged);
        if presentation == BrowserPresentationMode::DaemonRendered {
            self.start_browser_bootstrap(surface.clone(), BrowserBootstrap::Create { url }, None);
            self.reap_if_dead(&surface);
        }
        Ok(placement)
    }

    /// Creates an exactly identified daemon-owned browser in a new pane next
    /// to a stable target pane.
    pub(crate) fn canonical_split_browser_pane(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        target_pane_uuid: PaneUuid,
        surface_uuid: SurfaceUuid,
        dir: SplitDir,
        insert_first: bool,
        ratio: f32,
        url: String,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        self.canonical_split_browser_pane_with_presentation(
            expectation,
            target_pane_uuid,
            surface_uuid,
            dir,
            insert_first,
            ratio,
            url,
            size,
            BrowserPresentationMode::DaemonRendered,
        )
    }

    pub(crate) fn canonical_split_browser_pane_with_presentation(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        target_pane_uuid: PaneUuid,
        surface_uuid: SurfaceUuid,
        dir: SplitDir,
        insert_first: bool,
        ratio: f32,
        url: String,
        size: Option<(u16, u16)>,
        presentation: BrowserPresentationMode,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        validate_browser_url(&url)?;
        if !ratio.is_finite() || ratio <= 0.0 || ratio >= 1.0 {
            anyhow::bail!("split ratio must be finite and between zero and one");
        }
        if target_pane_uuid.as_uuid().is_nil() || surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("canonical browser split UUIDs must be nonzero");
        }
        let payload_digest = match presentation {
            BrowserPresentationMode::DaemonRendered => canonical_payload_digest(
                "split-browser-pane",
                &(
                    target_pane_uuid,
                    surface_uuid,
                    canonical_split_direction(dir),
                    insert_first,
                    ratio,
                    &url,
                    size,
                    presentation.as_str(),
                ),
            )?,
            BrowserPresentationMode::FrontendNative => canonical_payload_digest(
                "split-browser-pane",
                &(
                    target_pane_uuid,
                    surface_uuid,
                    canonical_split_direction(dir),
                    insert_first,
                    ratio,
                    size,
                    presentation.as_str(),
                ),
            )?,
        };
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let key = {
            let state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "split-browser-pane",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.surfaces.contains(&surface_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    if presentation == BrowserPresentationMode::FrontendNative {
                        self.frontend_native_browsers
                            .ensure_surface_seed(surface_uuid, Some(&url))?;
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            if state.pane_id_by_uuid(target_pane_uuid).is_none() {
                anyhow::bail!("unknown canonical pane {target_pane_uuid}");
            }
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical browser surface UUID already exists");
            }
            key
        };
        let (surface_id, _) = self.entity_ids.surface();
        let surface = self.create_browser_surface_with_presentation(
            surface_id,
            surface_uuid,
            url.clone(),
            size,
            presentation,
        );
        let transaction = (|| -> anyhow::Result<(CanonicalSurfacePlacement, ScreenId)> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "split-browser-pane",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical browser split fence changed during creation"),
            }
            let target = state
                .pane_id_by_uuid(target_pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("canonical target pane disappeared"))?;
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical browser surface UUID appeared during creation");
            }
            let commit = || -> anyhow::Result<(CanonicalSurfacePlacement, ScreenId)> {
                #[cfg(test)]
                if self.canonical_browser_fail_before_commit.load(Ordering::Acquire) {
                    anyhow::bail!("injected canonical browser pre-commit failure");
                }
                let (workspace_index, screen_index) = state
                    .screen_of(target)
                    .ok_or_else(|| anyhow::anyhow!("canonical target pane has no screen"))?;
                let (pane_id, pane_uuid) = self.entity_ids.pane();
                let mut root = state.workspaces[workspace_index].screens[screen_index].root.clone();
                if !root.split_leaf(target, dir, pane_id, insert_first, ratio) {
                    anyhow::bail!("canonical target pane disappeared before browser split commit");
                }
                state.surfaces.insert(surface.id, surface.clone());
                state.panes.insert(
                    pane_id,
                    Pane {
                        id: pane_id,
                        uuid: pane_uuid,
                        name: None,
                        tabs: vec![surface.id],
                        active_tab: 0,
                        active_at: self.next_active_at(),
                    },
                );
                let workspace_uuid = state.workspaces[workspace_index].uuid;
                let screen = &mut state.workspaces[workspace_index].screens[screen_index];
                screen.root = root;
                screen.active_pane = pane_id;
                let screen_id = screen.id;
                let screen_uuid = screen.uuid;
                state.active_workspace = workspace_index;
                state.workspaces[workspace_index].active_screen = screen_index;
                let targets = TopologyTargets {
                    workspaces: vec![workspace_uuid],
                    screens: vec![screen_uuid],
                    panes: vec![target_pane_uuid, pane_uuid],
                    surfaces: vec![surface_uuid],
                };
                let receipt = self.commit_canonical_mutation(
                    &mut state,
                    TopologyOperation::PaneSplit,
                    targets,
                    key,
                );
                Ok((
                    canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)?,
                    screen_id,
                ))
            };
            match presentation {
                BrowserPresentationMode::DaemonRendered => commit(),
                BrowserPresentationMode::FrontendNative => self
                    .frontend_native_browsers
                    .transactionally_insert_surface(surface_uuid, Some(url.clone()), commit),
            }
        })();
        let (placement, screen) = match transaction {
            Ok(result) => result,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.emit(MuxEvent::TreeChanged);
        self.emit(MuxEvent::LayoutChanged(screen));
        if presentation == BrowserPresentationMode::DaemonRendered {
            self.start_browser_bootstrap(surface.clone(), BrowserBootstrap::Create { url }, None);
            self.reap_if_dead(&surface);
        }
        Ok(placement)
    }

    /// Creates an exactly identified terminal tab in one stable pane.
    pub(crate) fn canonical_new_tab(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        pane_uuid: PaneUuid,
        surface_uuid: SurfaceUuid,
        size: Option<(u16, u16)>,
        mut launch: TerminalLaunchRequest,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        validate_terminal_launch_request(&launch)?;
        if pane_uuid.as_uuid().is_nil() || surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("canonical tab UUIDs must be nonzero");
        }
        let payload_digest =
            canonical_payload_digest("new-tab", &(pane_uuid, surface_uuid, size, &launch))?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (key, inherited_cwd) = {
            let state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "new-tab",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.panes.contains(&pane_uuid)
                        || !result.surfaces.contains(&surface_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let pane_id = state
                .pane_id_by_uuid(pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical pane {pane_uuid}"))?;
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical surface UUID already exists");
            }
            let inherited = state
                .panes
                .get(&pane_id)
                .and_then(Pane::active_surface)
                .and_then(|surface| state.surfaces.get(&surface).cloned());
            (key, inherited)
        };
        if launch.cwd.is_none() {
            launch.cwd = inherited_cwd.and_then(|surface| surface.pwd());
        }
        let (surface_id, _) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
        let surface = prepared.surface.clone();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let transaction = (|| -> anyhow::Result<CanonicalSurfacePlacement> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(&state, expectation, "new-tab", &payload_digest)? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical new-tab fence changed during spawn"),
            }
            let pane_id = state
                .pane_id_by_uuid(pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("canonical pane disappeared during spawn"))?;
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical surface UUID appeared during spawn");
            }
            state.surfaces.insert(surface.id, surface.clone());
            state.launch_recipes.insert(
                surface_uuid,
                prepared.launch.take().expect("unpublished terminal has launch recipe"),
            );
            let pane = state
                .panes
                .get_mut(&pane_id)
                .expect("stable pane resolved immediately before attach");
            pane.tabs.push(surface.id);
            pane.active_tab = pane.tabs.len() - 1;
            pane.active_at = self.next_active_at();
            let (workspace_index, screen_index) =
                state.screen_of(pane_id).expect("canonical pane belongs to a screen");
            state.active_workspace = workspace_index;
            state.workspaces[workspace_index].active_screen = screen_index;
            state.workspaces[workspace_index].screens[screen_index].active_pane = pane_id;
            let targets =
                TopologyTargets::from_legacy(&state, None, None, Some(pane_id), Some(surface.id));
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::SurfaceAttached,
                targets,
                key,
            );
            canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)
        })();
        let placement = match transaction {
            Ok(placement) => placement,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&surface);
        Ok(placement)
    }

    /// Creates an exactly identified terminal in a new pane next to a stable
    /// target. Left/up place the new pane first; right/down place it second.
    pub(crate) fn canonical_split_pane(
        self: &Arc<Self>,
        expectation: CanonicalMutationExpectation,
        target_pane_uuid: PaneUuid,
        surface_uuid: SurfaceUuid,
        dir: SplitDir,
        insert_first: bool,
        ratio: f32,
        size: Option<(u16, u16)>,
        mut launch: TerminalLaunchRequest,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        validate_terminal_launch_request(&launch)?;
        if !ratio.is_finite() || ratio <= 0.0 || ratio >= 1.0 {
            anyhow::bail!("split ratio must be finite and between zero and one");
        }
        let payload_digest = canonical_payload_digest(
            "split-pane",
            &(
                target_pane_uuid,
                surface_uuid,
                canonical_split_direction(dir),
                insert_first,
                ratio,
                size,
                &launch,
            ),
        )?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (key, inherited_cwd) = {
            let state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "split-pane",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.surfaces.contains(&surface_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let target = state
                .pane_id_by_uuid(target_pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical pane {target_pane_uuid}"))?;
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical surface UUID already exists");
            }
            let inherited = state
                .panes
                .get(&target)
                .and_then(Pane::active_surface)
                .and_then(|surface| state.surfaces.get(&surface).cloned());
            (key, inherited)
        };
        if launch.cwd.is_none() {
            launch.cwd = inherited_cwd.and_then(|surface| surface.pwd());
        }
        let (surface_id, _) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
        let surface = prepared.surface.clone();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let transaction = (|| -> anyhow::Result<(CanonicalSurfacePlacement, ScreenId)> {
            let mut state = self.state.lock().unwrap();
            match self.canonical_mutation_start(
                &state,
                expectation,
                "split-pane",
                &payload_digest,
            )? {
                CanonicalMutationStart::Fresh { key: current } if current == key => {}
                _ => anyhow::bail!("canonical split-pane fence changed during spawn"),
            }
            let target = state
                .pane_id_by_uuid(target_pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("canonical target pane disappeared"))?;
            if state.indexed_surface_id_by_uuid(surface_uuid).is_some() {
                anyhow::bail!("canonical surface UUID appeared during spawn");
            }
            let (workspace_index, screen_index) = state
                .screen_of(target)
                .ok_or_else(|| anyhow::anyhow!("canonical target pane has no screen"))?;
            let (pane_id, pane_uuid) = self.entity_ids.pane();
            let mut root = state.workspaces[workspace_index].screens[screen_index].root.clone();
            if !root.split_leaf(target, dir, pane_id, insert_first, ratio) {
                anyhow::bail!("canonical target pane disappeared before split commit");
            }
            state.surfaces.insert(surface.id, surface.clone());
            state.launch_recipes.insert(
                surface_uuid,
                prepared.launch.take().expect("unpublished terminal has launch recipe"),
            );
            state.panes.insert(
                pane_id,
                Pane {
                    id: pane_id,
                    uuid: pane_uuid,
                    name: None,
                    tabs: vec![surface.id],
                    active_tab: 0,
                    active_at: self.next_active_at(),
                },
            );
            let workspace_uuid = state.workspaces[workspace_index].uuid;
            let screen = &mut state.workspaces[workspace_index].screens[screen_index];
            screen.root = root;
            screen.active_pane = pane_id;
            let screen_id = screen.id;
            let screen_uuid = screen.uuid;
            state.active_workspace = workspace_index;
            state.workspaces[workspace_index].active_screen = screen_index;
            let targets = TopologyTargets {
                workspaces: vec![workspace_uuid],
                screens: vec![screen_uuid],
                panes: vec![target_pane_uuid, pane_uuid],
                surfaces: vec![surface_uuid],
            };
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::PaneSplit,
                targets,
                key,
            );
            Ok((canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)?, screen_id))
        })();
        let (placement, screen) = match transaction {
            Ok(result) => result,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeChanged);
        self.emit(MuxEvent::LayoutChanged(screen));
        self.reap_if_dead(&surface);
        Ok(placement)
    }

    /// Moves an existing stable terminal into a new adjacent pane with one
    /// candidate-state commit. Failure discards the candidate without
    /// changing the live split tree.
    pub(crate) fn canonical_split_tab(
        &self,
        expectation: CanonicalMutationExpectation,
        surface_uuid: SurfaceUuid,
        target_pane_uuid: PaneUuid,
        dir: SplitDir,
        insert_first: bool,
        ratio: f32,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        if !ratio.is_finite() || ratio <= 0.0 || ratio >= 1.0 {
            anyhow::bail!("split ratio must be finite and between zero and one");
        }
        let payload_digest = canonical_payload_digest(
            "split-tab",
            &(surface_uuid, target_pane_uuid, canonical_split_direction(dir), insert_first, ratio),
        )?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (placement, screen_id, source_workspace, target_workspace, surface_id) = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "split-tab",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.surfaces.contains(&surface_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let surface = state
                .surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical surface {surface_uuid}"))?;
            let target = state
                .pane_id_by_uuid(target_pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical pane {target_pane_uuid}"))?;
            if state
                .surfaces
                .get(&surface)
                .is_none_or(|surface| surface.semantic_scene_terminal_identity().is_none())
            {
                anyhow::bail!("canonical surface is not a terminal");
            }
            let source = state
                .pane_of(surface)
                .ok_or_else(|| anyhow::anyhow!("canonical surface has no source pane"))?;
            if source == target && state.panes.get(&source).is_none_or(|pane| pane.tabs.len() <= 1)
            {
                anyhow::bail!("cannot move a pane's only tab into a split of itself");
            }
            let source_pane_uuid = state.panes[&source].uuid;
            let source_workspace_index = state
                .screen_of(source)
                .ok_or_else(|| anyhow::anyhow!("source pane is outside canonical topology"))?
                .0;
            let source_workspace_uuid = state.workspaces[source_workspace_index].uuid;
            let (target_workspace_index, target_screen_index) = state
                .screen_of(target)
                .ok_or_else(|| anyhow::anyhow!("target pane is outside canonical topology"))?;
            let target_workspace_uuid = state.workspaces[target_workspace_index].uuid;
            let target_screen_uuid =
                state.workspaces[target_workspace_index].screens[target_screen_index].uuid;
            let (pane_id, pane_uuid) = self.entity_ids.pane();
            let mut candidate = state.value.clone();
            let split = candidate.workspaces[target_workspace_index].screens[target_screen_index]
                .root
                .split_leaf(target, dir, pane_id, insert_first, ratio);
            if !split {
                anyhow::bail!("canonical target pane disappeared before candidate split");
            }
            #[cfg(test)]
            if self.canonical_split_tab_fail_after_split.load(Ordering::Relaxed) {
                anyhow::bail!("injected canonical split-tab failure after candidate split");
            }
            candidate.panes.insert(
                pane_id,
                Pane {
                    id: pane_id,
                    uuid: pane_uuid,
                    name: None,
                    tabs: Vec::new(),
                    active_tab: 0,
                    active_at: self.next_active_at(),
                },
            );
            if !move_tab_in_state(&mut candidate, surface, pane_id, 0) {
                anyhow::bail!("canonical surface could not move into candidate split");
            }
            CanonicalTopologyIndex::build(&candidate)?;
            state.value = candidate;
            let (workspace_index, screen_index) = state
                .screen_of(pane_id)
                .expect("validated candidate split has canonical placement");
            let screen_id = state.workspaces[workspace_index].screens[screen_index].id;
            let targets = TopologyTargets {
                workspaces: vec![source_workspace_uuid, target_workspace_uuid],
                screens: vec![target_screen_uuid],
                panes: vec![source_pane_uuid, target_pane_uuid, pane_uuid],
                surfaces: vec![surface_uuid],
            };
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::PaneSplit,
                targets,
                key,
            );
            (
                canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)?,
                screen_id,
                source_workspace_uuid,
                target_workspace_uuid,
                surface,
            )
        };
        if source_workspace != target_workspace {
            self.rehome_renderer_presentations(surface_id, target_workspace);
        }
        self.emit(MuxEvent::TreeChanged);
        self.emit(MuxEvent::LayoutChanged(screen_id));
        Ok(placement)
    }

    pub(crate) fn canonical_close_surface(
        &self,
        expectation: CanonicalMutationExpectation,
        surface_uuid: SurfaceUuid,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        let payload_digest = canonical_payload_digest("close-surface", &surface_uuid)?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let _terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let (receipt, closed) = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "close-surface",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.surfaces.contains(&surface_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let surface = state
                .indexed_surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical surface {surface_uuid}"))?;
            let changed_screens = unique_screen_ids(surface_screen_id(&state, surface));
            let targets = TopologyTargets::from_legacy(
                &state,
                None,
                None,
                state.pane_of(surface),
                Some(surface),
            );
            let removed = remove_surface(&mut state, surface).into_iter().collect();
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::SurfaceClosed,
                targets,
                key,
            );
            let closed = ClosedTree {
                surface_ids: vec![surface],
                removed,
                changed_screens,
                empty: state.workspaces.is_empty(),
                delta: None,
            };
            (receipt, closed)
        };
        self.finish_close(closed);
        Ok(receipt)
    }

    pub(crate) fn canonical_close_pane(
        &self,
        expectation: CanonicalMutationExpectation,
        pane_uuid: PaneUuid,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        let payload_digest = canonical_payload_digest("close-pane", &pane_uuid)?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let _terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let (receipt, closed) = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "close-pane",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.panes.contains(&pane_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let pane = state
                .pane_id_by_uuid(pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical pane {pane_uuid}"))?;
            let tabs = state.panes[&pane].tabs.clone();
            let changed_screens = unique_screen_ids(
                tabs.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
            );
            let targets =
                TopologyTargets::from_legacy(&state, None, None, Some(pane), tabs.iter().copied());
            let mut removed = Vec::with_capacity(tabs.len());
            for surface in &tabs {
                if let Some(runtime) = remove_surface(&mut state, *surface) {
                    removed.push(runtime);
                }
            }
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::PaneClosed,
                targets,
                key,
            );
            let closed = ClosedTree {
                surface_ids: tabs,
                removed,
                changed_screens,
                empty: state.workspaces.is_empty(),
                delta: None,
            };
            (receipt, closed)
        };
        self.finish_close(closed);
        Ok(receipt)
    }

    pub(crate) fn canonical_close_workspace(
        &self,
        expectation: CanonicalMutationExpectation,
        workspace_uuid: WorkspaceUuid,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        let payload_digest = canonical_payload_digest("close-workspace", &workspace_uuid)?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let _terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let (receipt, closed) = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "close-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.workspaces.contains(&workspace_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let workspace_index = state
                .indexed_workspace_index_by_uuid(workspace_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical workspace {workspace_uuid}"))?;
            let workspace = state.workspaces[workspace_index].id;
            let tabs = state.workspaces[workspace_index]
                .screens
                .iter()
                .flat_map(|screen| screen_tabs(&state, screen))
                .collect::<Vec<_>>();
            let panes =
                tabs.iter().filter_map(|surface| state.pane_of(*surface)).collect::<Vec<_>>();
            let changed_screens = unique_screen_ids(
                tabs.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
            );
            let targets =
                topology_targets_many(&state, &[workspace], &changed_screens, &panes, &tabs);
            let mut removed = Vec::with_capacity(tabs.len());
            for surface in &tabs {
                if let Some(runtime) = remove_surface(&mut state, *surface) {
                    removed.push(runtime);
                }
            }
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::WorkspaceClosed,
                targets,
                key,
            );
            let closed = ClosedTree {
                surface_ids: tabs,
                removed,
                changed_screens,
                empty: state.workspaces.is_empty(),
                delta: None,
            };
            (receipt, closed)
        };
        self.finish_close(closed);
        Ok(receipt)
    }

    pub(crate) fn canonical_rename_workspace(
        &self,
        expectation: CanonicalMutationExpectation,
        workspace_uuid: WorkspaceUuid,
        name: String,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        validate_terminal_launch_text("workspace name", &name, MAX_TERMINAL_LAUNCH_STRING_BYTES)?;
        let payload_digest =
            canonical_payload_digest("rename-workspace", &(workspace_uuid, &name))?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let receipt = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "rename-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.workspaces.contains(&workspace_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let index = state
                .indexed_workspace_index_by_uuid(workspace_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical workspace {workspace_uuid}"))?;
            state.workspaces[index].name = name;
            self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::WorkspaceRenamed,
                TopologyTargets { workspaces: vec![workspace_uuid], ..TopologyTargets::default() },
                key,
            )
        };
        self.emit(MuxEvent::TreeChanged);
        Ok(receipt)
    }

    pub(crate) fn canonical_rename_surface(
        &self,
        expectation: CanonicalMutationExpectation,
        surface_uuid: SurfaceUuid,
        name: String,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        validate_terminal_launch_text("surface name", &name, MAX_TERMINAL_LAUNCH_STRING_BYTES)?;
        let payload_digest = canonical_payload_digest("rename-surface", &(surface_uuid, &name))?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let receipt = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "rename-surface",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.surfaces.contains(&surface_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let surface = state
                .indexed_surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical surface {surface_uuid}"))?;
            state.surfaces[&surface].set_name((!name.is_empty()).then_some(name));
            let targets = TopologyTargets::from_legacy(&state, None, None, None, Some(surface));
            self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::SurfaceRenamed,
                targets,
                key,
            )
        };
        self.emit(MuxEvent::TreeChanged);
        Ok(receipt)
    }

    pub(crate) fn canonical_move_tab(
        &self,
        expectation: CanonicalMutationExpectation,
        surface_uuid: SurfaceUuid,
        pane_uuid: PaneUuid,
        index: usize,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        let payload_digest =
            canonical_payload_digest("move-tab", &(surface_uuid, pane_uuid, index))?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (receipt, surface, source_workspace, target_workspace) = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "move-tab",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.surfaces.contains(&surface_uuid)
                        || !result.panes.contains(&pane_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let surface = state
                .surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical surface {surface_uuid}"))?;
            let pane = state
                .pane_id_by_uuid(pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical pane {pane_uuid}"))?;
            let source_pane = state
                .pane_of(surface)
                .ok_or_else(|| anyhow::anyhow!("canonical surface has no source pane"))?;
            let source_pane_uuid = state.panes[&source_pane].uuid;
            let source_workspace = state
                .screen_of(source_pane)
                .map(|(wi, _)| state.workspaces[wi].uuid)
                .ok_or_else(|| anyhow::anyhow!("source pane has no workspace"))?;
            let target_workspace =
                state
                    .screen_of(pane)
                    .map(|(wi, _)| state.workspaces[wi].uuid)
                    .ok_or_else(|| anyhow::anyhow!("target pane has no workspace"))?;
            let mut candidate = state.value.clone();
            let _ = move_tab_in_state(&mut candidate, surface, pane, index);
            CanonicalTopologyIndex::build(&candidate)?;
            state.value = candidate;
            let targets = TopologyTargets {
                workspaces: vec![source_workspace, target_workspace],
                panes: vec![source_pane_uuid, pane_uuid],
                surfaces: vec![surface_uuid],
                ..TopologyTargets::default()
            };
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::TabMoved,
                targets,
                key,
            );
            (receipt, surface, source_workspace, target_workspace)
        };
        if source_workspace != target_workspace {
            self.rehome_renderer_presentations(surface, target_workspace);
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(receipt)
    }

    pub(crate) fn canonical_reorder_tabs(
        &self,
        expectation: CanonicalMutationExpectation,
        pane_uuid: PaneUuid,
        surface_uuids: Vec<SurfaceUuid>,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        if surface_uuids.len() > MAX_ENSURE_TERMINAL_BATCH_SIZE {
            anyhow::bail!("canonical tab reorder exceeds maximum entity count");
        }
        let payload_digest =
            canonical_payload_digest("reorder-tabs", &(pane_uuid, &surface_uuids))?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let receipt = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "reorder-tabs",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.panes.contains(&pane_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let pane_id = state
                .pane_id_by_uuid(pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical pane {pane_uuid}"))?;
            let mut seen = HashSet::with_capacity(surface_uuids.len());
            let requested = surface_uuids
                .iter()
                .map(|uuid| {
                    if !seen.insert(*uuid) {
                        anyhow::bail!("canonical tab reorder contains duplicate UUID {uuid}");
                    }
                    state
                        .surface_id_by_uuid(*uuid)
                        .ok_or_else(|| anyhow::anyhow!("unknown canonical surface {uuid}"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            let current = state.panes[&pane_id].tabs.clone();
            if requested.len() != current.len()
                || requested.iter().copied().collect::<HashSet<_>>()
                    != current.iter().copied().collect::<HashSet<_>>()
            {
                anyhow::bail!("canonical tab reorder must be an exact pane permutation");
            }
            let active = state.panes[&pane_id].active_surface();
            let pane = state.panes.get_mut(&pane_id).expect("pane resolved above");
            pane.tabs = requested;
            pane.active_tab = active
                .and_then(|active| pane.tabs.iter().position(|surface| *surface == active))
                .unwrap_or(0);
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::TabMoved,
                TopologyTargets {
                    panes: vec![pane_uuid],
                    surfaces: surface_uuids,
                    ..TopologyTargets::default()
                },
                key,
            );
            receipt
        };
        self.emit(MuxEvent::TreeChanged);
        Ok(receipt)
    }

    pub(crate) fn canonical_reorder_workspaces(
        &self,
        expectation: CanonicalMutationExpectation,
        workspace_uuids: Vec<WorkspaceUuid>,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        if workspace_uuids.len() > MAX_ENSURE_TERMINAL_BATCH_SIZE {
            anyhow::bail!("canonical workspace reorder exceeds maximum entity count");
        }
        let payload_digest = canonical_payload_digest("reorder-workspaces", &workspace_uuids)?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let receipt = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "reorder-workspaces",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if result.workspaces != workspace_uuids {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let mut seen = HashSet::with_capacity(workspace_uuids.len());
            let current =
                state.workspaces.iter().map(|workspace| workspace.uuid).collect::<Vec<_>>();
            if workspace_uuids.len() != current.len()
                || workspace_uuids.iter().any(|uuid| !seen.insert(*uuid))
                || workspace_uuids.iter().copied().collect::<HashSet<_>>()
                    != current.iter().copied().collect::<HashSet<_>>()
            {
                anyhow::bail!("canonical workspace reorder must be an exact session permutation");
            }
            let active_uuid =
                state.workspaces.get(state.active_workspace).map(|workspace| workspace.uuid);
            let mut by_uuid = std::mem::take(&mut state.workspaces)
                .into_iter()
                .map(|workspace| (workspace.uuid, workspace))
                .collect::<HashMap<_, _>>();
            state.workspaces = workspace_uuids
                .iter()
                .map(|uuid| by_uuid.remove(uuid).expect("exact permutation validated"))
                .collect();
            state.active_workspace = active_uuid
                .and_then(|uuid| {
                    state.workspaces.iter().position(|workspace| workspace.uuid == uuid)
                })
                .unwrap_or(0);
            self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::WorkspaceMoved,
                TopologyTargets { workspaces: workspace_uuids, ..TopologyTargets::default() },
                key,
            )
        };
        self.emit(MuxEvent::TreeChanged);
        Ok(receipt)
    }

    pub(crate) fn canonical_move_tab_to_new_workspace(
        &self,
        expectation: CanonicalMutationExpectation,
        surface_uuid: SurfaceUuid,
        workspace_uuid: WorkspaceUuid,
        name: Option<String>,
        index: Option<usize>,
    ) -> anyhow::Result<CanonicalSurfacePlacement> {
        if workspace_uuid.as_uuid().is_nil() {
            anyhow::bail!("canonical workspace UUID must be nonzero");
        }
        if let Some(name) = &name {
            validate_terminal_launch_text(
                "workspace name",
                name,
                MAX_TERMINAL_LAUNCH_STRING_BYTES,
            )?;
        }
        let payload_digest = canonical_payload_digest(
            "move-tab-to-new-workspace",
            &(surface_uuid, workspace_uuid, &name, index),
        )?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (placement, surface, old_workspace) = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "move-tab-to-new-workspace",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.workspaces.contains(&workspace_uuid)
                        || !result.surfaces.contains(&surface_uuid)
                    {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return canonical_surface_placement_for_uuid(&state, surface_uuid, receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            if state.indexed_workspace_index_by_uuid(workspace_uuid).is_some()
                || state.tombstones.iter().any(|tombstone| {
                    tombstone.kind == PersistedEntityKind::Workspace
                        && tombstone.uuid == workspace_uuid.as_uuid()
                })
            {
                anyhow::bail!(
                    "canonical destination workspace identity already exists or is tombstoned"
                );
            }
            let surface = state
                .surface_id_by_uuid(surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical surface {surface_uuid}"))?;
            let source_pane = state
                .pane_of(surface)
                .ok_or_else(|| anyhow::anyhow!("canonical surface has no source pane"))?;
            let source_pane_uuid = state.panes[&source_pane].uuid;
            let old_workspace = state
                .screen_of(source_pane)
                .map(|(wi, _)| state.workspaces[wi].uuid)
                .ok_or_else(|| anyhow::anyhow!("source pane has no workspace"))?;
            let (pane_id, pane_uuid) = self.entity_ids.pane();
            let (screen_id, screen_uuid) = self.entity_ids.screen();
            let (workspace_id, _) = self.entity_ids.workspace();
            let mut candidate = state.value.clone();
            let insertion =
                index.unwrap_or(candidate.workspaces.len()).min(candidate.workspaces.len());
            candidate.panes.insert(
                pane_id,
                Pane {
                    id: pane_id,
                    uuid: pane_uuid,
                    name: None,
                    tabs: Vec::new(),
                    active_tab: 0,
                    active_at: self.next_active_at(),
                },
            );
            candidate.workspaces.insert(
                insertion,
                Workspace {
                    id: workspace_id,
                    uuid: workspace_uuid,
                    name: name.unwrap_or_else(|| format!("{}", candidate.workspaces.len() + 1)),
                    screens: vec![Screen {
                        id: screen_id,
                        uuid: screen_uuid,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                },
            );
            if !move_tab_in_state(&mut candidate, surface, pane_id, 0) {
                anyhow::bail!("canonical surface could not move into candidate workspace");
            }
            CanonicalTopologyIndex::build(&candidate)?;
            state.value = candidate;
            state.active_workspace = state
                .workspaces
                .iter()
                .position(|workspace| workspace.uuid == workspace_uuid)
                .expect("candidate destination workspace remains present");
            let targets = TopologyTargets {
                workspaces: vec![old_workspace, workspace_uuid],
                screens: vec![screen_uuid],
                panes: vec![source_pane_uuid, pane_uuid],
                surfaces: vec![surface_uuid],
            };
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::WorkspaceCreated,
                targets,
                key,
            );
            (
                canonical_surface_placement_for_uuid(&state, surface_uuid, receipt)?,
                surface,
                old_workspace,
            )
        };
        if old_workspace != workspace_uuid {
            self.rehome_renderer_presentations(surface, workspace_uuid);
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(placement)
    }

    pub(crate) fn canonical_set_split_ratio(
        &self,
        expectation: CanonicalMutationExpectation,
        pane_uuid: PaneUuid,
        dir: SplitDir,
        target_in_first: bool,
        ratio: f32,
    ) -> anyhow::Result<CanonicalMutationReceipt> {
        if !ratio.is_finite() || ratio <= 0.0 || ratio >= 1.0 {
            anyhow::bail!("split ratio must be finite and between zero and one");
        }
        let payload_digest = canonical_payload_digest(
            "set-split-ratio",
            &(pane_uuid, canonical_split_direction(dir), target_in_first, ratio),
        )?;
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (receipt, screen_id) = {
            let mut state = self.state.lock().unwrap();
            let key = match self.canonical_mutation_start(
                &state,
                expectation,
                "set-split-ratio",
                &payload_digest,
            )? {
                CanonicalMutationStart::Replay { receipt, result } => {
                    if !result.panes.contains(&pane_uuid) {
                        anyhow::bail!("canonical mutation request_id payload changed");
                    }
                    return Ok(receipt);
                }
                CanonicalMutationStart::Fresh { key } => key,
            };
            let pane = state
                .pane_id_by_uuid(pane_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown canonical pane {pane_uuid}"))?;
            let (workspace_index, screen_index) = state
                .screen_of(pane)
                .ok_or_else(|| anyhow::anyhow!("canonical pane has no screen"))?;
            let screen = &mut state.workspaces[workspace_index].screens[screen_index];
            if screen.root.set_deepest_ratio_on_edge(pane, dir, target_in_first, ratio)
                == ChangeState::Missing
            {
                anyhow::bail!("canonical pane has no split on requested edge");
            }
            let screen_id = screen.id;
            let screen_uuid = screen.uuid;
            let workspace_uuid = state.workspaces[workspace_index].uuid;
            let receipt = self.commit_canonical_mutation(
                &mut state,
                TopologyOperation::SplitRatioChanged,
                TopologyTargets {
                    workspaces: vec![workspace_uuid],
                    screens: vec![screen_uuid],
                    panes: vec![pane_uuid],
                    ..TopologyTargets::default()
                },
                key,
            );
            (receipt, screen_id)
        };
        self.emit(MuxEvent::TreeChanged);
        self.emit(MuxEvent::LayoutChanged(screen_id));
        Ok(receipt)
    }

    /// Create a workspace with one screen holding one pane with one tab.
    /// Returns the tab's surface. `size` is the expected content size in
    /// cells, when the caller knows it (spawning at the final size avoids
    /// shell redraw artifacts).
    pub fn new_workspace(
        self: &Arc<Self>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_workspace_with_launch(name, size, TerminalLaunchRequest::default())
    }

    pub(crate) fn new_workspace_with_launch(
        self: &Arc<Self>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        launch: TerminalLaunchRequest,
    ) -> anyhow::Result<Arc<Surface>> {
        let (surface_id, surface_uuid) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
        let surface = prepared.surface.clone();
        let (pane_id, pane) = self.make_pane(surface.id);
        let (screen_id, screen_uuid) = self.entity_ids.screen();
        let (ws_id, workspace_uuid) = self.entity_ids.workspace();
        let notifications = self.surface_notifications();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let delta = {
            let mut state = self.state.lock().unwrap();
            state.launch_recipes.insert(
                surface_uuid,
                prepared.launch.take().expect("prepared terminal retains its launch recipe"),
            );
            state.surfaces.insert(surface_id, surface.clone());
            let name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            state.panes.insert(pane_id, pane);
            state.workspaces.push(Workspace {
                id: ws_id,
                uuid: workspace_uuid,
                name,
                screens: vec![Screen {
                    id: screen_id,
                    uuid: screen_uuid,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                }],
                active_screen: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
            let targets = topology_targets(
                &state,
                Some(ws_id),
                Some(screen_id),
                Some(pane_id),
                Some(surface.id),
            );
            state.commit_topology(TopologyOperation::WorkspaceCreated, targets);
            let index = state.workspaces.len() - 1;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceAdded,
                ws_id,
            )
            .expect("new workspace is present in tree snapshot");
            TreeDelta {
                kind: TreeDeltaKind::WorkspaceAdded,
                workspace: ws_id,
                screen: None,
                pane: None,
                surface: None,
                index: Some(index),
                entity,
            }
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeDelta(delta));
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    pub fn run_command_surface(
        self: &Arc<Self>,
        argv: Vec<String>,
        pane: Option<PaneId>,
        new_workspace: bool,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        if new_workspace {
            let launch =
                TerminalLaunchRequest { cwd, argv: Some(argv), ..TerminalLaunchRequest::default() };
            let (surface_id, surface_uuid) = self.entity_ids.surface();
            let mut prepared =
                self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
            let surface = prepared.surface.clone();
            if let Some(name) = name.as_ref() {
                surface.set_name(Some(name.clone()));
            }
            let (pane_id, pane) = self.make_pane(surface.id);
            let (screen_id, screen_uuid) = self.entity_ids.screen();
            let (ws_id, workspace_uuid) = self.entity_ids.workspace();
            let notifications = self.surface_notifications();
            let terminal_control = self.terminal_control_lifecycle.write().unwrap();
            let delta = {
                let mut state = self.state.lock().unwrap();
                state.launch_recipes.insert(
                    surface_uuid,
                    prepared.launch.take().expect("prepared terminal retains its launch recipe"),
                );
                state.surfaces.insert(surface_id, surface.clone());
                let workspace_name =
                    name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
                state.panes.insert(pane_id, pane);
                state.workspaces.push(Workspace {
                    id: ws_id,
                    uuid: workspace_uuid,
                    name: workspace_name,
                    screens: vec![Screen {
                        id: screen_id,
                        uuid: screen_uuid,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                let targets = topology_targets(
                    &state,
                    Some(ws_id),
                    Some(screen_id),
                    Some(pane_id),
                    Some(surface.id),
                );
                state.commit_topology(TopologyOperation::WorkspaceCreated, targets);
                let index = state.workspaces.len() - 1;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::WorkspaceAdded,
                    ws_id,
                )
                .expect("new workspace is present in tree snapshot");
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceAdded,
                    workspace: ws_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                }
            };
            self.complete_committed_terminal_launch(prepared);
            drop(terminal_control);
            self.emit(MuxEvent::TreeDelta(delta));
            self.reap_if_dead(&surface);
            return Ok(RunPlacement {
                surface: surface.id,
                pane: pane_id,
                screen: screen_id,
                workspace: ws_id,
            });
        }

        let target = {
            let state = self.state.lock().unwrap();
            match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            }
        };
        let Some(target) = target else {
            return self.run_command_surface(argv, None, true, cwd, name, size);
        };

        let cwd = cwd.or_else(|| self.pane_cwd(target));
        let launch =
            TerminalLaunchRequest { cwd, argv: Some(argv), ..TerminalLaunchRequest::default() };
        let (surface_id, surface_uuid) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
        let surface = prepared.surface.clone();
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        let active_at = self.next_active_at();
        let notifications = self.surface_notifications();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let (placement, delta) = {
            let mut state = self.state.lock().unwrap();
            let Some((wi, si)) = state.screen_of(target) else {
                surface.kill();
                anyhow::bail!("pane disappeared while creating tab");
            };
            state.launch_recipes.insert(
                surface_uuid,
                prepared.launch.take().expect("prepared terminal retains its launch recipe"),
            );
            state.surfaces.insert(surface_id, surface.clone());
            let Some(pane) = state.panes.get_mut(&target) else {
                unreachable!("screen lookup guarantees the pane exists");
            };
            pane.tabs.push(surface.id);
            pane.active_tab = pane.tabs.len() - 1;
            pane.active_at = active_at;
            let index = pane.tabs.len() - 1;
            let placement = RunPlacement {
                surface: surface.id,
                pane: target,
                screen: state.workspaces[wi].screens[si].id,
                workspace: state.workspaces[wi].id,
            };
            let targets = topology_targets(
                &state,
                Some(placement.workspace),
                Some(placement.screen),
                Some(target),
                Some(surface.id),
            );
            state.commit_topology(TopologyOperation::SurfaceAttached, targets);
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::TabAdded,
                surface.id,
            )
            .expect("new tab is present in tree snapshot");
            let delta = TreeDelta {
                kind: TreeDeltaKind::TabAdded,
                workspace: placement.workspace,
                screen: Some(placement.screen),
                pane: Some(target),
                surface: Some(surface.id),
                index: Some(index),
                entity,
            };
            (placement, delta)
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeDelta(delta));
        self.reap_if_dead(&surface);
        Ok(placement)
    }

    /// Create a screen in a workspace (default: the active one) with one
    /// pane/tab, and make it active. Returns the tab's surface.
    pub fn new_screen(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        // Validate the target before spawning a child.
        {
            let state = self.state.lock().unwrap();
            match workspace {
                Some(id) if !state.workspaces.iter().any(|w| w.id == id) => {
                    anyhow::bail!("unknown workspace {id}")
                }
                None if state.workspaces.is_empty() => {
                    drop(state);
                    return self.new_workspace(None, size);
                }
                _ => {}
            }
        }
        let (surface_id, surface_uuid) = self.entity_ids.surface();
        let mut prepared = self.prepare_surface_for_launch(
            surface_id,
            surface_uuid,
            &TerminalLaunchRequest::default(),
            size,
        )?;
        let surface = prepared.surface.clone();
        let (pane_id, pane) = self.make_pane(surface.id);
        let (screen_id, screen_uuid) = self.entity_ids.screen();
        let notifications = self.surface_notifications();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let workspace_index = match workspace {
                Some(id) => state.workspaces.iter().position(|w| w.id == id),
                None => Some(state.active_workspace),
            };
            match workspace_index {
                Some(workspace_index) if workspace_index < state.workspaces.len() => {
                    state.launch_recipes.insert(
                        surface_uuid,
                        prepared
                            .launch
                            .take()
                            .expect("prepared terminal retains its launch recipe"),
                    );
                    state.surfaces.insert(surface_id, surface.clone());
                    let ws = &mut state.workspaces[workspace_index];
                    ws.screens.push(Screen {
                        id: screen_id,
                        uuid: screen_uuid,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    });
                    ws.active_screen = ws.screens.len() - 1;
                    let workspace = ws.id;
                    let index = ws.screens.len() - 1;
                    state.panes.insert(pane_id, pane);
                    let targets = topology_targets(
                        &state,
                        Some(workspace),
                        Some(screen_id),
                        Some(pane_id),
                        Some(surface.id),
                    );
                    state.commit_topology(TopologyOperation::ScreenCreated, targets);
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::ScreenAdded,
                        screen_id,
                    )
                    .expect("new screen is present in tree snapshot");
                    Some(TreeDelta {
                        kind: TreeDeltaKind::ScreenAdded,
                        workspace,
                        screen: Some(screen_id),
                        pane: None,
                        surface: None,
                        index: Some(index),
                        entity,
                    })
                }
                _ => None,
            }
        };
        let Some(delta) = attached else {
            surface.kill();
            anyhow::bail!("workspace disappeared while creating screen");
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeDelta(delta));
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Create a tab in a pane (default: the active pane of the active
    /// screen). When the session has no workspaces yet (headless before
    /// any command), a workspace is created around the new tab.
    pub fn new_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_with_launch(
            pane,
            size,
            TerminalLaunchRequest { cwd, ..TerminalLaunchRequest::default() },
        )
    }

    pub(crate) fn new_tab_with_launch(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        mut launch: TerminalLaunchRequest,
    ) -> anyhow::Result<Arc<Surface>> {
        // Resolve and validate the target before spawning a child.
        let target = {
            let state = self.state.lock().unwrap();
            match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            }
        };
        let Some(target) = target else {
            return self.new_workspace_with_launch(None, size, launch);
        };

        launch.cwd = launch.cwd.or_else(|| self.pane_cwd(target));
        let (surface_id, surface_uuid) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
        let surface = prepared.surface.clone();
        let active_at = self.next_active_at();
        let notifications = self.surface_notifications();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let attached = {
            let mut state = self.state.lock().unwrap();
            if state.panes.contains_key(&target) {
                state.launch_recipes.insert(
                    surface_uuid,
                    prepared.launch.take().expect("prepared terminal retains its launch recipe"),
                );
                state.surfaces.insert(surface_id, surface.clone());
                match state.panes.get_mut(&target) {
                    Some(pane) => {
                        pane.tabs.push(surface.id);
                        pane.active_tab = pane.tabs.len() - 1;
                        pane.active_at = active_at;
                        let index = pane.tabs.len() - 1;
                        let (wi, si) =
                            state.screen_of(target).expect("live pane belongs to a screen");
                        let workspace = state.workspaces[wi].id;
                        let screen = state.workspaces[wi].screens[si].id;
                        let targets = topology_targets(
                            &state,
                            Some(workspace),
                            Some(screen),
                            Some(target),
                            Some(surface.id),
                        );
                        state.commit_topology(TopologyOperation::SurfaceAttached, targets);
                        let entity = crate::server::tree_entity_json(
                            &state,
                            &notifications,
                            TreeDeltaKind::TabAdded,
                            surface.id,
                        )
                        .expect("new tab is present in tree snapshot");
                        Some(TreeDelta {
                            kind: TreeDeltaKind::TabAdded,
                            workspace,
                            screen: Some(screen),
                            pane: Some(target),
                            surface: Some(surface.id),
                            index: Some(index),
                            entity,
                        })
                    }
                    None => unreachable!("pane presence checked while holding canonical state"),
                }
            } else {
                None
            }
        };
        let Some(delta) = attached else {
            surface.kill();
            anyhow::bail!("pane disappeared while creating tab");
        };
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeDelta(delta));
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Create a browser tab in a pane (default: the active pane). When
    /// the session has no workspaces yet, a workspace is created around
    /// the browser tab.
    pub fn new_browser_tab(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let target = {
            let state = self.state.lock().unwrap();
            match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            }
        };
        let Some(target) = target else {
            let surface = self.spawn_browser_surface(url, size);
            let (pane_id, pane) = self.make_pane(surface.id);
            let (screen_id, screen_uuid) = self.entity_ids.screen();
            let (ws_id, workspace_uuid) = self.entity_ids.workspace();
            let notifications = self.surface_notifications();
            let delta = {
                let mut state = self.state.lock().unwrap();
                let name = format!("{}", state.workspaces.len() + 1);
                state.panes.insert(pane_id, pane);
                state.workspaces.push(Workspace {
                    id: ws_id,
                    uuid: workspace_uuid,
                    name,
                    screens: vec![Screen {
                        id: screen_id,
                        uuid: screen_uuid,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                let targets = topology_targets(
                    &state,
                    Some(ws_id),
                    Some(screen_id),
                    Some(pane_id),
                    Some(surface.id),
                );
                state.commit_topology(TopologyOperation::WorkspaceCreated, targets);
                let index = state.workspaces.len() - 1;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::WorkspaceAdded,
                    ws_id,
                )
                .expect("new workspace is present in tree snapshot");
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceAdded,
                    workspace: ws_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                }
            };
            self.emit(MuxEvent::TreeDelta(delta));
            self.reap_if_dead(&surface);
            return Ok(surface);
        };

        let surface = self.spawn_browser_surface(url, size);
        let active_at = self.next_active_at();
        let notifications = self.surface_notifications();
        let attached = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    let index = pane.tabs.len() - 1;
                    let (wi, si) = state.screen_of(target).expect("live pane belongs to a screen");
                    let workspace = state.workspaces[wi].id;
                    let screen = state.workspaces[wi].screens[si].id;
                    let targets = topology_targets(
                        &state,
                        Some(workspace),
                        Some(screen),
                        Some(target),
                        Some(surface.id),
                    );
                    state.commit_topology(TopologyOperation::SurfaceAttached, targets);
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::TabAdded,
                        surface.id,
                    )
                    .expect("new browser tab is present in tree snapshot");
                    Some(TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                    })
                }
                None => {
                    state.discard_surface_runtime(surface.id);
                    None
                }
            }
        };
        let Some(delta) = attached else {
            surface.kill();
            anyhow::bail!("pane disappeared while creating browser tab");
        };
        self.emit(MuxEvent::TreeDelta(delta));
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    pub fn adopt_browser_target(
        self: &Arc<Self>,
        opener_surface: SurfaceId,
        target_id: String,
        url: String,
        runtime: Arc<BrowserRuntime>,
    ) -> bool {
        let (pane_id, size) = {
            let state = self.state.lock().unwrap();
            let Some(pane_id) = state.pane_of(opener_surface) else {
                return false;
            };
            let size = state.surfaces.get(&opener_surface).map(|surface| surface.size());
            (pane_id, size)
        };
        let (id, uuid) = self.entity_ids.surface();
        let opts = self.surface_options.lock().unwrap().clone();
        let size = size.unwrap_or((opts.cols, opts.rows));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let surface = browser::new_surface_with_uuid(
            id,
            uuid,
            url.clone(),
            size,
            cell_pixels,
            &opts,
            Arc::downgrade(self),
        );
        let active_at = self.next_active_at();
        match self.attach_browser_surface_to_pane_or_kill(pane_id, &surface, active_at) {
            BrowserSurfaceAttach::MissingPane => return false,
            BrowserSurfaceAttach::Attached(Some(delta)) => self.emit(MuxEvent::TreeDelta(delta)),
            BrowserSurfaceAttach::Attached(None) => self.emit(MuxEvent::TreeChanged),
        }
        self.start_browser_bootstrap(
            surface,
            BrowserBootstrap::ExistingTarget { target_id, url },
            Some(runtime),
        );
        true
    }

    fn attach_browser_surface_to_pane_or_kill(
        &self,
        pane_id: PaneId,
        surface: &Arc<Surface>,
        active_at: u64,
    ) -> BrowserSurfaceAttach {
        let notifications = self.surface_notifications();
        let attached = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&pane_id) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    state.surfaces.insert(surface.id, surface.clone());
                    let (wi, si) = state
                        .screen_of(pane_id)
                        .expect("browser target pane belongs to a live screen");
                    let targets = topology_targets(
                        &state,
                        Some(state.workspaces[wi].id),
                        Some(state.workspaces[wi].screens[si].id),
                        Some(pane_id),
                        Some(surface.id),
                    );
                    state.commit_topology(TopologyOperation::SurfaceAttached, targets);
                    let delta = (|| {
                        let (wi, si) = state.screen_of(pane_id)?;
                        let pane = state.panes.get(&pane_id)?;
                        let index = pane.tabs.iter().position(|id| *id == surface.id)?;
                        let entity = crate::server::tree_entity_json(
                            &state,
                            &notifications,
                            TreeDeltaKind::TabAdded,
                            surface.id,
                        )?;
                        Some(TreeDelta {
                            kind: TreeDeltaKind::TabAdded,
                            workspace: state.workspaces[wi].id,
                            screen: Some(state.workspaces[wi].screens[si].id),
                            pane: Some(pane_id),
                            surface: Some(surface.id),
                            index: Some(index),
                            entity,
                        })
                    })();
                    BrowserSurfaceAttach::Attached(delta)
                }
                None => BrowserSurfaceAttach::MissingPane,
            }
        };
        if matches!(attached, BrowserSurfaceAttach::MissingPane) {
            surface.kill();
        }
        attached
    }

    /// Working directory of a pane's active surface, if reported.
    fn pane_cwd(&self, pane: PaneId) -> Option<String> {
        let surface = {
            let state = self.state.lock().unwrap();
            let active = state.panes.get(&pane)?.active_surface()?;
            state.surfaces.get(&active).cloned()
        };
        surface.and_then(|s| s.pwd())
    }

    /// Split the screen containing `target`, putting a new single-tab
    /// pane after it. Returns the new pane's surface. `size` is the
    /// expected content size of the new pane, when the caller knows it.
    pub fn split(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.split_with_launch(target, dir, false, 0.5, size, TerminalLaunchRequest::default())
    }

    pub(crate) fn split_with_launch(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        insert_first: bool,
        ratio: f32,
        size: Option<(u16, u16)>,
        mut launch: TerminalLaunchRequest,
    ) -> anyhow::Result<Arc<Surface>> {
        if !ratio.is_finite() || ratio <= 0.0 || ratio >= 1.0 {
            anyhow::bail!("split ratio must be finite and between zero and one");
        }
        if !self.state.lock().unwrap().panes.contains_key(&target) {
            anyhow::bail!("pane {target} not found");
        }
        launch.cwd = launch.cwd.or_else(|| self.pane_cwd(target));
        let (surface_id, surface_uuid) = self.entity_ids.surface();
        let mut prepared =
            self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
        let surface = prepared.surface.clone();
        let (pane_id, pane_uuid) = self.entity_ids.pane();
        let active_at = self.next_active_at();
        let mut done = false;
        let mut changed_screen = None;
        let mut changed_workspace = None;
        let notifications = self.surface_notifications();
        let mut delta = None;
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        {
            let mut state = self.state.lock().unwrap();
            'outer: for ws in state.workspaces.iter_mut() {
                for screen in ws.screens.iter_mut() {
                    if screen.root.split_leaf(target, dir, pane_id, insert_first, ratio) {
                        screen.active_pane = pane_id;
                        changed_screen = Some(screen.id);
                        changed_workspace = Some(ws.id);
                        done = true;
                        break 'outer;
                    }
                }
            }
            if done {
                state.launch_recipes.insert(
                    surface_uuid,
                    prepared.launch.take().expect("prepared terminal retains its launch recipe"),
                );
                state.surfaces.insert(surface_id, surface.clone());
                state.panes.insert(
                    pane_id,
                    Pane {
                        id: pane_id,
                        uuid: pane_uuid,
                        name: None,
                        tabs: vec![surface.id],
                        active_tab: 0,
                        active_at,
                    },
                );
                let targets = topology_targets(
                    &state,
                    changed_workspace,
                    changed_screen,
                    Some(pane_id),
                    Some(surface.id),
                );
                state.commit_topology(TopologyOperation::PaneSplit, targets);
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::PaneAdded,
                    pane_id,
                )
                .expect("split pane is present in tree snapshot");
                delta = Some(TreeDelta {
                    kind: TreeDeltaKind::PaneAdded,
                    workspace: changed_workspace.expect("split workspace captured"),
                    screen: changed_screen,
                    pane: Some(pane_id),
                    surface: None,
                    index: Some(screen_pane_index(&state, changed_screen.unwrap(), pane_id)),
                    entity,
                });
            }
        }
        if !done {
            surface.kill();
            anyhow::bail!("pane {target} not found");
        }
        self.complete_committed_terminal_launch(prepared);
        drop(terminal_control);
        self.emit(MuxEvent::TreeDelta(delta.expect("successful split has a tree delta")));
        if let Some(screen) = changed_screen {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Moves an existing terminal tab into a new adjacent pane in one topology commit.
    pub(crate) fn split_tab(
        &self,
        surface: SurfaceId,
        target: PaneId,
        dir: SplitDir,
        insert_first: bool,
        ratio: f32,
    ) -> anyhow::Result<SurfaceId> {
        if !ratio.is_finite() || ratio <= 0.0 || ratio >= 1.0 {
            anyhow::bail!("split ratio must be finite and between zero and one");
        }
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (pane_id, pane_uuid) = self.entity_ids.pane();
        let active_at = self.next_active_at();
        let (screen_id, source_workspace_uuid, target_workspace_uuid) = {
            let mut state = self.state.lock().unwrap();
            let source = state
                .pane_of(surface)
                .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
            if !state.panes.contains_key(&target) {
                anyhow::bail!("unknown pane {target}");
            }
            if source == target && state.panes.get(&source).is_none_or(|pane| pane.tabs.len() <= 1)
            {
                anyhow::bail!("cannot move a pane's only tab into a split of itself");
            }
            let (source_workspace_index, _) = state
                .screen_of(source)
                .ok_or_else(|| anyhow::anyhow!("source pane is outside canonical topology"))?;
            let source_workspace_uuid = state.workspaces[source_workspace_index].uuid;
            let (target_workspace_index, target_screen_index) = state
                .screen_of(target)
                .ok_or_else(|| anyhow::anyhow!("target pane is outside canonical topology"))?;
            let target_workspace_uuid = state.workspaces[target_workspace_index].uuid;
            let target_screen_id =
                state.workspaces[target_workspace_index].screens[target_screen_index].id;
            let split = state.workspaces[target_workspace_index].screens[target_screen_index]
                .root
                .split_leaf(target, dir, pane_id, insert_first, ratio);
            if !split {
                anyhow::bail!("pane {target} disappeared before split commit");
            }
            state.panes.insert(
                pane_id,
                Pane {
                    id: pane_id,
                    uuid: pane_uuid,
                    name: None,
                    tabs: Vec::new(),
                    active_tab: 0,
                    active_at,
                },
            );
            if !move_tab_in_state(&mut state, surface, pane_id, 0) {
                state.panes.remove(&pane_id);
                anyhow::bail!("surface {surface} could not be moved into split pane");
            }
            let (workspace_index, screen_index) = state
                .screen_of(pane_id)
                .ok_or_else(|| anyhow::anyhow!("split pane lost canonical placement"))?;
            let screen_id = state.workspaces[workspace_index].screens[screen_index].id;
            let mut targets = TopologyTargets::from_legacy(
                &state,
                None,
                Some(target_screen_id),
                Some(target),
                Some(surface),
            );
            targets.merge(TopologyTargets::from_legacy(
                &state,
                Some(state.workspaces[workspace_index].id),
                Some(screen_id),
                Some(pane_id),
                Some(surface),
            ));
            state.commit_topology(TopologyOperation::PaneSplit, targets);
            (screen_id, source_workspace_uuid, target_workspace_uuid)
        };
        if source_workspace_uuid != target_workspace_uuid {
            self.rehome_renderer_presentations(surface, target_workspace_uuid);
        }
        self.emit(MuxEvent::TreeChanged);
        self.emit(MuxEvent::LayoutChanged(screen_id));
        Ok(surface)
    }

    /// Moves an existing terminal tab into a newly created workspace atomically.
    pub(crate) fn move_tab_to_new_workspace(
        &self,
        surface: SurfaceId,
        name: Option<String>,
        index: Option<usize>,
    ) -> anyhow::Result<SurfaceId> {
        let _mutation = self.ensure_terminal_lock.lock().unwrap();
        let (pane_id, pane_uuid) = self.entity_ids.pane();
        let (screen_id, screen_uuid) = self.entity_ids.screen();
        let (workspace_id, workspace_uuid) = self.entity_ids.workspace();
        let active_at = self.next_active_at();
        {
            let mut state = self.state.lock().unwrap();
            let source_pane = state
                .pane_of(surface)
                .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
            if state
                .surfaces
                .get(&surface)
                .is_none_or(|surface| surface.semantic_scene_terminal_identity().is_none())
            {
                anyhow::bail!("surface {surface} is not a terminal");
            }
            let insertion = index.unwrap_or(state.workspaces.len()).min(state.workspaces.len());
            let workspace_name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            state.panes.insert(
                pane_id,
                Pane {
                    id: pane_id,
                    uuid: pane_uuid,
                    name: None,
                    tabs: Vec::new(),
                    active_tab: 0,
                    active_at,
                },
            );
            state.workspaces.insert(
                insertion,
                Workspace {
                    id: workspace_id,
                    uuid: workspace_uuid,
                    name: workspace_name,
                    screens: vec![Screen {
                        id: screen_id,
                        uuid: screen_uuid,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                },
            );
            if !move_tab_in_state(&mut state, surface, pane_id, 0) {
                state.workspaces.retain(|workspace| workspace.id != workspace_id);
                state.panes.remove(&pane_id);
                anyhow::bail!("surface {surface} could not be moved into new workspace");
            }
            let workspace_index = state
                .workspaces
                .iter()
                .position(|workspace| workspace.id == workspace_id)
                .expect("new workspace remains present after tab move");
            state.active_workspace = workspace_index;
            let mut targets =
                TopologyTargets::from_legacy(&state, None, None, Some(source_pane), Some(surface));
            targets.merge(TopologyTargets::from_legacy(
                &state,
                Some(workspace_id),
                Some(screen_id),
                Some(pane_id),
                Some(surface),
            ));
            state.commit_topology(TopologyOperation::WorkspaceCreated, targets);
        }
        self.rehome_renderer_presentations(surface, workspace_uuid);
        self.emit(MuxEvent::TreeChanged);
        Ok(surface)
    }

    /// Close one tab. When it was the pane's last tab, the pane collapses
    /// out of its split tree (and emptied screens/workspaces are removed).
    pub fn close_surface(&self, target: SurfaceId) {
        let _terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let notifications = self.surface_notifications();
        if let Some(closed) =
            self.close_tree_transaction(CloseTreeTarget::Surface(target), &notifications)
        {
            self.finish_close(closed);
        } else if self.with_state(|state| state.workspaces.is_empty()) {
            // Preserve the legacy empty notification produced by a redundant
            // surface close after the final workspace disappeared.
            self.emit(MuxEvent::Empty);
        }
    }

    /// Close a pane and every tab in it.
    pub fn close_pane(&self, target: PaneId) {
        let _terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let notifications = self.surface_notifications();
        if let Some(closed) =
            self.close_tree_transaction(CloseTreeTarget::Pane(target), &notifications)
        {
            self.finish_close(closed);
        }
    }

    /// Close a screen and every pane/tab in it.
    pub fn close_screen(&self, target: ScreenId) -> bool {
        let _terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let notifications = self.surface_notifications();
        let Some(closed) =
            self.close_tree_transaction(CloseTreeTarget::Screen(target), &notifications)
        else {
            return false;
        };
        self.finish_close(closed);
        true
    }

    /// Close a workspace and every screen/pane/tab in it.
    pub fn close_workspace(&self, target: WorkspaceId) -> bool {
        let _terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let notifications = self.surface_notifications();
        let Some(closed) =
            self.close_tree_transaction(CloseTreeTarget::Workspace(target), &notifications)
        else {
            return false;
        };
        self.finish_close(closed);
        true
    }

    /// Resolve, remove, and journal an entire close under one canonical
    /// state lock. Child processes and legacy events are handled afterward.
    fn close_tree_transaction(
        &self,
        target: CloseTreeTarget,
        notifications: &HashMap<SurfaceId, SurfaceNotification>,
    ) -> Option<ClosedTree> {
        let mut state = self.state.lock().unwrap();
        let (tabs, delta) = match target {
            CloseTreeTarget::Surface(surface) => (state.surfaces.contains_key(&surface)
                || state.pane_of(surface).is_some())
            .then_some((vec![surface], close_surface_delta(&state, notifications, surface)))?,
            CloseTreeTarget::Pane(pane) => {
                let tabs = state.panes.get(&pane)?.tabs.clone();
                let delta = close_pane_delta(&state, notifications, pane)
                    .expect("live pane has a close delta");
                (tabs, Some(delta))
            }
            CloseTreeTarget::Screen(screen) => {
                let screen = state
                    .workspaces
                    .iter()
                    .flat_map(|workspace| &workspace.screens)
                    .find(|candidate| candidate.id == screen)?;
                let tabs = screen_tabs(&state, screen);
                let delta = close_screen_delta(&state, notifications, screen.id)
                    .expect("live screen has a close delta");
                (tabs, Some(delta))
            }
            CloseTreeTarget::Workspace(workspace) => {
                let workspace = state.workspaces.iter().find(|item| item.id == workspace)?;
                let tabs = workspace
                    .screens
                    .iter()
                    .flat_map(|screen| screen_tabs(&state, screen))
                    .collect::<Vec<_>>();
                let delta = close_workspace_delta(&state, notifications, workspace.id)
                    .expect("live workspace has a close delta");
                (tabs, Some(delta))
            }
        };
        let changed_screens = unique_screen_ids(
            tabs.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
        );
        let panes = tabs.iter().filter_map(|surface| state.pane_of(*surface)).collect::<Vec<_>>();
        let topology_targets = delta.as_ref().map(|delta| {
            topology_targets_many(
                &state,
                &[delta.workspace],
                &delta.screen.into_iter().collect::<Vec<_>>(),
                &panes,
                &tabs,
            )
        });
        let surface_ids = tabs;
        let mut removed = Vec::with_capacity(surface_ids.len());
        for surface in &surface_ids {
            if let Some(surface) = remove_surface(&mut state, *surface) {
                removed.push(surface);
            }
        }
        if let (Some(delta), Some(targets)) = (&delta, topology_targets) {
            state.commit_topology(close_topology_operation(delta.kind), targets);
        }
        Some(ClosedTree {
            surface_ids,
            removed,
            changed_screens,
            empty: state.workspaces.is_empty(),
            delta,
        })
    }

    fn finish_close(&self, closed: ClosedTree) {
        for surface in closed.surface_ids {
            self.purge_surface_side_tables(surface);
        }
        for surface in closed.removed {
            if surface.as_browser().is_some_and(|browser| {
                browser.presentation_mode() == BrowserPresentationMode::FrontendNative
            }) {
                self.frontend_native_browsers.remove_surface(surface.uuid);
            }
            if let Some(provenance) = surface.external_terminal_provenance() {
                self.remote_tmux_producers.remove_surface(provenance.producer_id, surface.uuid);
            }
            self.terminal_authority.retire_terminal(surface.uuid);
            for presentation_id in self.presentations.remove_surface(surface.uuid) {
                self.terminal_authority.revoke_presentation(presentation_id);
                let _ = self.remove_renderer_presentation(presentation_id);
            }
            surface.kill();
        }
        match closed.delta {
            Some(delta) => self.emit(MuxEvent::TreeDelta(delta)),
            None => self.emit(MuxEvent::TreeChanged),
        }
        for screen in closed.changed_screens {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        if closed.empty {
            self.emit(MuxEvent::Empty);
        }
        self.reconcile_renderer_workspaces();
    }

    pub fn rename_workspace(&self, target: WorkspaceId, name: String) -> bool {
        let notifications = self.surface_notifications();
        let renamed = {
            let mut state = self.state.lock().unwrap();
            match state.workspaces.iter().position(|ws| ws.id == target) {
                Some(index) => {
                    let change = if state.workspaces[index].name == name {
                        ChangeState::Unchanged
                    } else {
                        state.workspaces[index].name = name;
                        ChangeState::Changed
                    };
                    if change == ChangeState::Changed {
                        let targets = topology_targets(&state, Some(target), None, None, None);
                        state.commit_topology(TopologyOperation::WorkspaceRenamed, targets);
                    } else {
                        state.commit_legacy_topology();
                    }
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::WorkspaceRenamed,
                        target,
                    )
                    .expect("renamed workspace is present in tree snapshot");
                    Some(TreeDelta {
                        kind: TreeDeltaKind::WorkspaceRenamed,
                        workspace: target,
                        screen: None,
                        pane: None,
                        surface: None,
                        index: None,
                        entity,
                    })
                }
                None => None,
            }
        };
        if let Some(delta) = renamed {
            self.emit(MuxEvent::TreeDelta(delta));
            true
        } else {
            false
        }
    }

    /// Set a pane's user-visible name. An empty name clears it (the pane
    /// falls back to its active tab's title).
    pub fn rename_pane(&self, target: PaneId, name: String) -> bool {
        let renamed = {
            let mut state = self.state.lock().unwrap();
            let next_name = (!name.is_empty()).then_some(name);
            match state.panes.get(&target) {
                Some(pane) => {
                    let change = if pane.name == next_name {
                        ChangeState::Unchanged
                    } else {
                        state.panes.get_mut(&target).expect("pane remains present").name =
                            next_name;
                        ChangeState::Changed
                    };
                    if change == ChangeState::Changed {
                        let targets = topology_targets(&state, None, None, Some(target), None);
                        state.commit_topology(TopologyOperation::PaneRenamed, targets);
                    } else {
                        state.commit_legacy_topology();
                    }
                    true
                }
                None => false,
            }
        };
        if renamed {
            self.emit(MuxEvent::TreeChanged);
        }
        renamed
    }

    /// Set a tab's user-visible name. An empty name clears it (the tab
    /// falls back to its process title/number label).
    pub fn rename_surface(&self, target: SurfaceId, name: String) -> bool {
        let notifications = self.surface_notifications();
        let delta = {
            let mut state = self.state.lock().unwrap();
            let Some(surface) = state.surfaces.get(&target) else { return false };
            let next_name = (!name.is_empty()).then_some(name);
            let change = if surface.name() == next_name {
                ChangeState::Unchanged
            } else {
                surface.set_name(next_name);
                ChangeState::Changed
            };
            if change == ChangeState::Changed && state.pane_of(target).is_some() {
                let pane = state.pane_of(target);
                let screen = pane
                    .and_then(|pane| state.screen_of(pane))
                    .map(|(wi, si)| state.workspaces[wi].screens[si].id);
                let workspace = pane
                    .and_then(|pane| state.screen_of(pane))
                    .map(|(wi, _)| state.workspaces[wi].id);
                let targets = topology_targets(&state, workspace, screen, pane, Some(target));
                state.commit_topology(TopologyOperation::SurfaceRenamed, targets);
            } else if state.pane_of(target).is_some() {
                state.commit_legacy_topology();
            }
            (|| {
                let pane = state.pane_of(target)?;
                let (wi, si) = state.screen_of(pane)?;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::TabRenamed,
                    target,
                )?;
                Some(TreeDelta {
                    kind: TreeDeltaKind::TabRenamed,
                    workspace: state.workspaces[wi].id,
                    screen: Some(state.workspaces[wi].screens[si].id),
                    pane: Some(pane),
                    surface: Some(target),
                    index: None,
                    entity,
                })
            })()
        };
        match delta {
            Some(delta) => self.emit(MuxEvent::TreeDelta(delta)),
            None => self.emit(MuxEvent::TreeChanged),
        }
        true
    }

    /// Set a screen's user-visible name. An empty name clears it (the
    /// screen falls back to its number).
    pub fn rename_screen(&self, target: ScreenId, name: String) -> bool {
        let notifications = self.surface_notifications();
        let renamed = {
            let mut state = self.state.lock().unwrap();
            let Some((wi, si)) = state.workspaces.iter().enumerate().find_map(|(wi, workspace)| {
                workspace.screens.iter().position(|screen| screen.id == target).map(|si| (wi, si))
            }) else {
                return false;
            };
            let next_name = (!name.is_empty()).then_some(name);
            let change = if state.workspaces[wi].screens[si].name == next_name {
                ChangeState::Unchanged
            } else {
                state.workspaces[wi].screens[si].name = next_name;
                ChangeState::Changed
            };
            if change == ChangeState::Changed {
                let workspace = state.workspaces[wi].id;
                let targets = topology_targets(&state, Some(workspace), Some(target), None, None);
                state.commit_topology(TopologyOperation::ScreenRenamed, targets);
            } else {
                state.commit_legacy_topology();
            }
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::ScreenRenamed,
                target,
            )
            .expect("renamed screen is present in tree snapshot");
            TreeDelta {
                kind: TreeDeltaKind::ScreenRenamed,
                workspace: state.workspaces[wi].id,
                screen: Some(target),
                pane: None,
                surface: None,
                index: None,
                entity,
            }
        };
        self.emit(MuxEvent::TreeDelta(renamed));
        true
    }

    /// Reap a surface whose child exited before its tree attachment completed.
    /// `surface_exited` defers removal while the registered surface has no
    /// owning pane; the creator re-checks after publishing a valid attachment.
    fn reap_if_dead(&self, surface: &Arc<Surface>) {
        if surface.is_dead() && !surface.wait_after_command() {
            self.close_surface(surface.id);
        }
    }

    /// Called by a surface's reader thread when its child exits. The mux
    /// reaps the surface out of the tree itself, so frontends only need to
    /// drop their render state.
    pub(crate) fn surface_runtime_exited(&self, exited: &Arc<Surface>) {
        let Some(current) = self.surface(exited.id) else {
            return;
        };
        if !Arc::ptr_eq(&current, exited) {
            // Runtime replacement deliberately reuses neither the child nor
            // its reader. A late EOF from the retired runtime must not close
            // the newly committed terminal that now occupies this handle.
            return;
        }
        self.surface_exited(exited.id);
    }

    pub fn surface_exited(&self, id: SurfaceId) {
        if self.sidebar_surface_exited(id) {
            self.emit(MuxEvent::SurfaceExited(id));
            return;
        }
        if self.surface(id).is_some_and(|surface| surface.wait_after_command()) {
            self.emit(MuxEvent::SurfaceExited(id));
            return;
        }
        let pending_tree_attachment = {
            let state = self.state.lock().unwrap();
            state.surfaces.contains_key(&id) && state.pane_of(id).is_none()
        };
        if !pending_tree_attachment {
            self.close_surface(id);
        }
        self.emit(MuxEvent::SurfaceExited(id));
    }

    fn sidebar_surface_exited(&self, id: SurfaceId) -> bool {
        let mut runtime = self.sidebar_plugin.lock().unwrap();
        if runtime.surface != Some(id) {
            return false;
        }
        runtime.surface = None;
        runtime.failures = runtime.failures.saturating_add(1);
        let delay = sidebar_retry_delay(runtime.failures);
        runtime.last_error = Some("sidebar plugin exited".to_string());
        runtime.retry_at = Some(Instant::now() + delay);
        drop(runtime);
        self.state.lock().unwrap().discard_surface_runtime(id);
        true
    }

    /// Make `pane` the active pane of its screen (and that screen and
    /// workspace active).
    pub fn focus_pane(&self, pane: PaneId) -> bool {
        let active_at = self.next_active_at();
        let (found, viewed) = {
            let mut state = self.state.lock().unwrap();
            match state.screen_of(pane) {
                Some((wi, si)) => {
                    state.active_workspace = wi;
                    let ws = &mut state.workspaces[wi];
                    ws.active_screen = si;
                    ws.screens[si].active_pane = pane;
                    stamp_pane(&mut state, pane, active_at);
                    state.commit_legacy_topology();
                    (true, Self::active_surface_in_state(&state))
                }
                None => (false, None),
            }
        };
        if found {
            self.clear_viewed_notification(viewed);
            self.emit(MuxEvent::TreeChanged);
        }
        found
    }

    /// Set the deepest split ratio in `dir` on the path to `pane`.
    pub fn set_ratio(&self, pane: PaneId, dir: SplitDir, ratio: f32) -> bool {
        let ratio = clamp_split_ratio(ratio);
        let resolved = {
            let mut state = self.state.lock().unwrap();
            let resolved =
                state.workspaces.iter_mut().flat_map(|ws| ws.screens.iter_mut()).find_map(
                    |screen| {
                        let change = screen.root.set_deepest_ratio(pane, dir, ratio);
                        (change != ChangeState::Missing).then_some((screen.id, change))
                    },
                );
            if let Some((screen, ChangeState::Changed)) = resolved {
                let workspace = state
                    .workspaces
                    .iter()
                    .find(|workspace| workspace.screens.iter().any(|item| item.id == screen))
                    .map(|workspace| workspace.id);
                let targets = topology_targets(&state, workspace, Some(screen), Some(pane), None);
                state.commit_topology(TopologyOperation::SplitRatioChanged, targets);
            } else if resolved.is_some() {
                state.commit_legacy_topology();
            }
            resolved
        };
        if let Some((screen, _)) = resolved {
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::LayoutChanged(screen));
            true
        } else {
            false
        }
    }

    pub fn pane_neighbor(&self, pane: PaneId, dir: Direction) -> anyhow::Result<Option<PaneId>> {
        self.with_state(|state| {
            let Some((wi, si)) = state.screen_of(pane) else {
                anyhow::bail!("unknown pane {pane}");
            };
            let screen = &state.workspaces[wi].screens[si];
            let (dx, dy) = dir.delta();
            let layout =
                layout_screen(&screen.root, Rect { x: 0, y: 0, width: 10_000, height: 10_000 });
            Ok(layout.neighbor(pane, dx, dy))
        })
    }

    pub fn focus_direction(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        dir: Direction,
    ) -> anyhow::Result<PaneId> {
        let target = self.with_state(|state| pane.or_else(|| state.active_pane()));
        let Some(target) = target else {
            anyhow::bail!("no active pane");
        };
        let Some(next) = self.pane_neighbor(target, dir)? else {
            anyhow::bail!("no neighbor");
        };
        if !self.focus_pane(next) {
            anyhow::bail!("unknown pane {next}");
        }
        Ok(next)
    }

    pub fn swap_panes(&self, pane: PaneId, target: PaneId) -> bool {
        let changed_screen = {
            let mut state = self.state.lock().unwrap();
            let changed = state
                .workspaces
                .iter_mut()
                .flat_map(|ws| ws.screens.iter_mut())
                .find_map(|screen| screen.root.swap_leaves(pane, target).then_some(screen.id));
            if let Some(screen) = changed {
                let workspace = state
                    .workspaces
                    .iter()
                    .find(|workspace| workspace.screens.iter().any(|item| item.id == screen))
                    .map(|workspace| workspace.id);
                let targets = TopologyTargets::from_legacy(
                    &state,
                    workspace,
                    Some(screen),
                    [pane, target],
                    None,
                );
                state.commit_topology(TopologyOperation::PanesSwapped, targets);
            }
            changed
        };
        if let Some(screen) = changed_screen {
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::LayoutChanged(screen));
            true
        } else {
            false
        }
    }

    pub fn zoom_pane(&self, pane: Option<PaneId>, mode: ZoomMode) -> anyhow::Result<ZoomState> {
        let changed = {
            let mut state = self.state.lock().unwrap();
            let target = match pane.or_else(|| state.active_pane()) {
                Some(pane) => pane,
                None => anyhow::bail!("no active pane"),
            };
            let Some((wi, si)) = state.screen_of(target) else {
                anyhow::bail!("unknown pane {target}");
            };
            let screen = &mut state.workspaces[wi].screens[si];
            let next = match mode {
                ZoomMode::Toggle if screen.zoomed_pane == Some(target) => None,
                ZoomMode::Toggle => Some(target),
                ZoomMode::On => Some(target),
                ZoomMode::Off => None,
            };
            let changed = screen.zoomed_pane != next;
            screen.zoomed_pane = next;
            let screen_id = screen.id;
            if changed {
                state.commit_legacy_topology();
            }
            (screen_id, target, next, changed)
        };
        if changed.3 {
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::LayoutChanged(changed.0));
        }
        Ok(ZoomState { pane: changed.1, zoomed: changed.2.is_some(), zoomed_pane: changed.2 })
    }

    pub fn apply_layout(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        layout: &LayoutSpec,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<AppliedLayout> {
        validate_layout_spec(layout)?;
        {
            let state = self.state.lock().unwrap();
            if let Some(id) = workspace
                && !state.workspaces.iter().any(|ws| ws.id == id)
            {
                anyhow::bail!("unknown workspace {id}");
            }
        }

        let mut created = Vec::new();
        let mut panes = Vec::new();
        let mut prepared = Vec::new();
        let root =
            match self.instantiate_layout(layout, size, &mut panes, &mut created, &mut prepared) {
                Ok(root) => root,
                Err(err) => {
                    Self::discard_prepared_terminals(prepared);
                    return Err(err);
                }
            };
        let Some(active_pane) = created.first().map(|pane| pane.pane) else {
            Self::discard_prepared_terminals(prepared);
            anyhow::bail!("layout must contain at least one leaf");
        };
        let (screen_id, screen_uuid) = self.entity_ids.screen();
        let notifications = self.surface_notifications();
        let terminal_control = self.terminal_control_lifecycle.write().unwrap();
        let delta = {
            let mut state = self.state.lock().unwrap();
            if let Some(id) = workspace
                && !state.workspaces.iter().any(|candidate| candidate.id == id)
            {
                drop(state);
                Self::discard_prepared_terminals(prepared);
                anyhow::bail!("workspace {id} disappeared while applying layout");
            }
            for terminal in &mut prepared {
                state.launch_recipes.insert(
                    terminal.surface.uuid,
                    terminal.launch.take().expect("prepared terminal retains its launch recipe"),
                );
                state.surfaces.insert(terminal.surface.id, terminal.surface.clone());
            }
            for (pane_id, pane) in panes {
                state.panes.insert(pane_id, pane);
            }
            let screen = Screen {
                id: screen_id,
                uuid: screen_uuid,
                name,
                root,
                active_pane,
                zoomed_pane: None,
            };
            let mut created_workspace = None;
            let workspace_id = match workspace {
                Some(id) => {
                    let ws = state
                        .workspaces
                        .iter_mut()
                        .find(|ws| ws.id == id)
                        .expect("workspace validated before spawning");
                    ws.screens.push(screen);
                    id
                }
                None if state.workspaces.is_empty() => {
                    let (ws_id, workspace_uuid) = self.entity_ids.workspace();
                    state.workspaces.push(Workspace {
                        id: ws_id,
                        uuid: workspace_uuid,
                        name: "1".into(),
                        screens: vec![screen],
                        active_screen: 0,
                    });
                    state.active_workspace = 0;
                    created_workspace = Some(ws_id);
                    ws_id
                }
                None => {
                    let active = state.active_workspace;
                    let ws =
                        state.workspaces.get_mut(active).expect("active workspace index valid");
                    ws.screens.push(screen);
                    ws.id
                }
            };
            let created_panes = created.iter().map(|pane| pane.pane).collect::<Vec<_>>();
            let created_surfaces = created.iter().map(|pane| pane.surface).collect::<Vec<_>>();
            let targets = topology_targets_many(
                &state,
                &[workspace_id],
                &[screen_id],
                &created_panes,
                &created_surfaces,
            );
            state.commit_topology(TopologyOperation::LayoutApplied, targets);
            if let Some(workspace_id) = created_workspace {
                let index = state
                    .workspaces
                    .iter()
                    .position(|workspace| workspace.id == workspace_id)
                    .expect("new workspace index");
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::WorkspaceAdded,
                    workspace_id,
                )
                .expect("applied workspace is present in tree snapshot");
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceAdded,
                    workspace: workspace_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                }
            } else {
                let index = state
                    .workspaces
                    .iter()
                    .find(|workspace| workspace.id == workspace_id)
                    .and_then(|workspace| {
                        workspace.screens.iter().position(|screen| screen.id == screen_id)
                    })
                    .expect("new screen index");
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::ScreenAdded,
                    screen_id,
                )
                .expect("applied screen is present in tree snapshot");
                TreeDelta {
                    kind: TreeDeltaKind::ScreenAdded,
                    workspace: workspace_id,
                    screen: Some(screen_id),
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                }
            }
        };
        let spawned = prepared.iter().map(|terminal| terminal.surface.clone()).collect::<Vec<_>>();
        for terminal in prepared {
            self.complete_committed_terminal_launch(terminal);
        }
        drop(terminal_control);
        self.emit(MuxEvent::TreeDelta(delta));
        self.emit(MuxEvent::LayoutChanged(screen_id));
        for surface in spawned {
            self.reap_if_dead(&surface);
        }
        Ok(AppliedLayout { screen: screen_id, panes: created })
    }

    fn instantiate_layout(
        self: &Arc<Self>,
        layout: &LayoutSpec,
        size: Option<(u16, u16)>,
        panes: &mut Vec<(PaneId, Pane)>,
        created: &mut Vec<AppliedPane>,
        prepared: &mut Vec<PreparedTerminalLaunch>,
    ) -> anyhow::Result<Node> {
        match layout {
            LayoutSpec::Leaf(spec) => {
                if spec.command.as_ref().is_some_and(|argv| argv.is_empty()) {
                    anyhow::bail!("leaf command must not be empty");
                }
                let (surface_id, surface_uuid) = self.entity_ids.surface();
                let launch = TerminalLaunchRequest {
                    cwd: spec.cwd.clone(),
                    argv: spec.command.clone(),
                    ..TerminalLaunchRequest::default()
                };
                let terminal =
                    self.prepare_surface_for_launch(surface_id, surface_uuid, &launch, size)?;
                let surface = terminal.surface.clone();
                let (pane_id, pane) = self.make_pane(surface.id);
                created.push(AppliedPane { pane: pane_id, surface: surface.id });
                panes.push((pane_id, pane));
                prepared.push(terminal);
                Ok(Node::Leaf(pane_id))
            }
            LayoutSpec::Split { dir, ratio, a, b } => Ok(Node::Split {
                dir: *dir,
                ratio: clamp_split_ratio(*ratio),
                a: Box::new(self.instantiate_layout(a, size, panes, created, prepared)?),
                b: Box::new(self.instantiate_layout(b, size, panes, created, prepared)?),
            }),
        }
    }

    fn discard_prepared_terminals(prepared: Vec<PreparedTerminalLaunch>) {
        for terminal in prepared {
            terminal.surface.kill();
        }
    }

    /// Move an existing tab to `index` in `pane`. The surface is kept
    /// alive; if moving it empties the source pane, that pane collapses
    /// out of its split tree.
    pub fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) -> bool {
        let active_at = self.next_active_at();
        let moved = {
            let mut state = self.state.lock().unwrap();
            let source_pane = state.pane_of(surface);
            let mut targets =
                TopologyTargets::from_legacy(&state, None, None, source_pane, Some(surface));
            let moved = move_tab_in_state(&mut state, surface, pane, index);
            if moved {
                stamp_pane(&mut state, pane, active_at);
                targets.merge(TopologyTargets::from_legacy(
                    &state,
                    None,
                    None,
                    Some(pane),
                    Some(surface),
                ));
                state.commit_topology(TopologyOperation::TabMoved, targets);
            }
            moved
        };
        if moved {
            self.emit(MuxEvent::TreeChanged);
        }
        moved
    }

    /// Reorder a workspace. The active workspace follows the moved entry.
    pub fn move_workspace(&self, workspace: WorkspaceId, index: usize) -> bool {
        let moved = {
            let mut state = self.state.lock().unwrap();
            let Some(old_idx) = state.workspaces.iter().position(|ws| ws.id == workspace) else {
                return false;
            };
            let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
            let new_idx = new_idx.min(state.workspaces.len().saturating_sub(1));
            if new_idx == old_idx {
                return false;
            }
            let active_id = state.workspaces.get(state.active_workspace).map(|ws| ws.id);
            let ws = state.workspaces.remove(old_idx);
            state.workspaces.insert(new_idx, ws);
            state.active_workspace = active_id
                .and_then(|id| state.workspaces.iter().position(|ws| ws.id == id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            let targets = topology_targets(&state, Some(workspace), None, None, None);
            state.commit_topology(TopologyOperation::WorkspaceMoved, targets);
            true
        };
        if moved {
            self.emit(MuxEvent::TreeChanged);
        }
        moved
    }

    /// Select a tab within a pane (default: the active pane) by index or
    /// relative delta.
    pub fn select_tab(&self, pane: Option<PaneId>, index: Option<usize>, delta: Option<isize>) {
        let active_at = self.next_active_at();
        let (_change, viewed) = {
            let mut state = self.state.lock().unwrap();
            let Some(target) = pane.or_else(|| state.active_pane()) else { return };
            let Some(pane) = state.panes.get_mut(&target) else { return };
            let len = pane.tabs.len();
            if len == 0 {
                return;
            }
            let previous = pane.active_tab;
            if let Some(index) = index {
                if index < len {
                    pane.active_tab = index;
                }
            } else if let Some(delta) = delta {
                pane.active_tab =
                    ((pane.active_tab as isize + delta).rem_euclid(len as isize)) as usize;
            }
            let change = if pane.active_tab == previous {
                ChangeState::Unchanged
            } else {
                ChangeState::Changed
            };
            stamp_pane(&mut state, target, active_at);
            state.commit_legacy_topology();
            (change, state.panes.get(&target).and_then(|pane| pane.active_surface()))
        };
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a screen in the active workspace by index or relative delta.
    pub fn select_screen(&self, index: Option<usize>, delta: Option<isize>) {
        let active_at = self.next_active_at();
        let (_change, viewed) = {
            let mut state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let (change, pane) = {
                let Some(ws) = state.workspaces.get_mut(active) else { return };
                let len = ws.screens.len();
                if len == 0 {
                    return;
                }
                let previous = ws.active_screen;
                if let Some(index) = index {
                    if index < len {
                        ws.active_screen = index;
                    }
                } else if let Some(delta) = delta {
                    ws.active_screen =
                        ((ws.active_screen as isize + delta).rem_euclid(len as isize)) as usize;
                }
                let change = if ws.active_screen == previous {
                    ChangeState::Unchanged
                } else {
                    ChangeState::Changed
                };
                (change, ws.active_screen_ref().map(|screen| screen.active_pane))
            };
            if let Some(pane) = pane {
                stamp_pane(&mut state, pane, active_at);
            }
            state.commit_legacy_topology();
            (change, Self::active_surface_in_state(&state))
        };
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a workspace by index or relative delta.
    pub fn select_workspace(&self, index: Option<usize>, delta: Option<isize>) {
        let active_at = self.next_active_at();
        let (_change, viewed) = {
            let mut state = self.state.lock().unwrap();
            let len = state.workspaces.len();
            if len == 0 {
                return;
            }
            let previous = state.active_workspace;
            if let Some(index) = index {
                if index < len {
                    state.active_workspace = index;
                }
            } else if let Some(delta) = delta {
                state.active_workspace =
                    ((state.active_workspace as isize + delta).rem_euclid(len as isize)) as usize;
            }
            let change = if state.active_workspace == previous {
                ChangeState::Unchanged
            } else {
                ChangeState::Changed
            };
            if let Some(pane) = state
                .workspaces
                .get(state.active_workspace)
                .and_then(|ws| ws.active_screen_ref().map(|screen| screen.active_pane))
            {
                stamp_pane(&mut state, pane, active_at);
            }
            state.commit_legacy_topology();
            (change, Self::active_surface_in_state(&state))
        };
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

fn sidebar_retry_delay(failures: u32) -> Duration {
    let shift = failures.saturating_sub(1).min(5);
    Duration::from_secs(1u64 << shift)
}

impl Drop for Mux {
    fn drop(&mut self) {
        if let Ok(state) = self.state.get_mut() {
            for surface in state.surfaces.values() {
                surface.kill();
            }
        }
        if let Ok(runtime) = self.browser_runtime.get_mut()
            && let Some(runtime) = runtime.take()
        {
            runtime.shutdown();
        }
    }
}

/// Every surface in a screen (all panes, all tabs).
fn screen_tabs(state: &State, screen: &Screen) -> Vec<SurfaceId> {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    pane_ids
        .iter()
        .filter_map(|id| state.panes.get(id))
        .flat_map(|pane| pane.tabs.iter().copied())
        .collect()
}

fn stamp_pane(state: &mut State, pane: PaneId, active_at: u64) {
    if let Some(pane) = state.panes.get_mut(&pane) {
        pane.active_at = active_at;
    }
}

fn most_recent_pane(state: &State, panes: &[PaneId]) -> Option<PaneId> {
    panes
        .iter()
        .filter_map(|id| state.panes.get(id).map(|pane| (*id, pane.active_at)))
        .max_by_key(|(_, active_at)| *active_at)
        .map(|(id, _)| id)
}

fn clamp_split_ratio(ratio: f32) -> f32 {
    ratio.clamp(0.05, 0.95)
}

fn validate_layout_spec(layout: &LayoutSpec) -> anyhow::Result<()> {
    match layout {
        LayoutSpec::Leaf(spec) => {
            if spec.command.as_ref().is_some_and(Vec::is_empty) {
                anyhow::bail!("leaf command must not be empty");
            }
        }
        LayoutSpec::Split { ratio, a, b, .. } => {
            if !ratio.is_finite() {
                anyhow::bail!("split ratio must be finite");
            }
            validate_layout_spec(a)?;
            validate_layout_spec(b)?;
        }
    }
    Ok(())
}

fn unique_screen_ids(ids: impl IntoIterator<Item = ScreenId>) -> Vec<ScreenId> {
    let mut unique = Vec::new();
    for id in ids {
        if !unique.contains(&id) {
            unique.push(id);
        }
    }
    unique
}

fn surface_screen_id(state: &State, surface: SurfaceId) -> Option<ScreenId> {
    let pane = state.pane_of(surface)?;
    let (wi, si) = state.screen_of(pane)?;
    Some(state.workspaces[wi].screens[si].id)
}

fn topology_targets(
    state: &State,
    workspace: Option<WorkspaceId>,
    screen: Option<ScreenId>,
    pane: Option<PaneId>,
    surface: Option<SurfaceId>,
) -> TopologyTargets {
    TopologyTargets::from_legacy(state, workspace, screen, pane, surface)
}

fn topology_targets_many(
    state: &State,
    workspaces: &[WorkspaceId],
    screens: &[ScreenId],
    panes: &[PaneId],
    surfaces: &[SurfaceId],
) -> TopologyTargets {
    TopologyTargets::from_legacy(
        state,
        workspaces.iter().copied(),
        screens.iter().copied(),
        panes.iter().copied(),
        surfaces.iter().copied(),
    )
}

fn close_topology_operation(kind: TreeDeltaKind) -> TopologyOperation {
    match kind {
        TreeDeltaKind::TabClosed => TopologyOperation::SurfaceClosed,
        TreeDeltaKind::PaneClosed => TopologyOperation::PaneClosed,
        TreeDeltaKind::ScreenClosed => TopologyOperation::ScreenClosed,
        TreeDeltaKind::WorkspaceClosed => TopologyOperation::WorkspaceClosed,
        _ => panic!("non-close tree delta used for a topology close transaction"),
    }
}

fn screen_pane_index(state: &State, screen: ScreenId, pane: PaneId) -> usize {
    state
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .find(|candidate| candidate.id == screen)
        .map(|screen| {
            let mut panes = Vec::new();
            screen.root.pane_ids(&mut panes);
            panes.iter().position(|candidate| *candidate == pane).unwrap_or(0)
        })
        .unwrap_or(0)
}

fn close_surface_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    surface: SurfaceId,
) -> Option<TreeDelta> {
    let pane_id = state.pane_of(surface)?;
    let pane = state.panes.get(&pane_id)?;
    let tab_index = pane.tabs.iter().position(|candidate| *candidate == surface)?;
    let (wi, si) = state.screen_of(pane_id)?;
    let workspace = &state.workspaces[wi];
    let screen = &workspace.screens[si];
    if pane.tabs.len() > 1 {
        let entity = crate::server::tree_entity_json(
            state,
            notifications,
            TreeDeltaKind::TabClosed,
            surface,
        )?;
        return Some(TreeDelta {
            kind: TreeDeltaKind::TabClosed,
            workspace: workspace.id,
            screen: Some(screen.id),
            pane: Some(pane_id),
            surface: Some(surface),
            index: Some(tab_index),
            entity,
        });
    }
    close_pane_delta(state, notifications, pane_id)
}

fn close_pane_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    pane: PaneId,
) -> Option<TreeDelta> {
    let (wi, si) = state.screen_of(pane)?;
    let workspace = &state.workspaces[wi];
    let screen = &workspace.screens[si];
    let mut panes = Vec::new();
    screen.root.pane_ids(&mut panes);
    if panes.len() > 1 {
        let entity =
            crate::server::tree_entity_json(state, notifications, TreeDeltaKind::PaneClosed, pane)?;
        return Some(TreeDelta {
            kind: TreeDeltaKind::PaneClosed,
            workspace: workspace.id,
            screen: Some(screen.id),
            pane: Some(pane),
            surface: None,
            index: Some(panes.iter().position(|candidate| *candidate == pane)?),
            entity,
        });
    }
    close_screen_delta(state, notifications, screen.id)
}

fn close_screen_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    screen: ScreenId,
) -> Option<TreeDelta> {
    let (wi, si) = state.workspaces.iter().enumerate().find_map(|(wi, workspace)| {
        workspace.screens.iter().position(|candidate| candidate.id == screen).map(|si| (wi, si))
    })?;
    let workspace = &state.workspaces[wi];
    if workspace.screens.len() > 1 {
        let entity = crate::server::tree_entity_json(
            state,
            notifications,
            TreeDeltaKind::ScreenClosed,
            screen,
        )?;
        return Some(TreeDelta {
            kind: TreeDeltaKind::ScreenClosed,
            workspace: workspace.id,
            screen: Some(screen),
            pane: None,
            surface: None,
            index: Some(si),
            entity,
        });
    }
    close_workspace_delta(state, notifications, workspace.id)
}

fn close_workspace_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    workspace: WorkspaceId,
) -> Option<TreeDelta> {
    let index = state.workspaces.iter().position(|candidate| candidate.id == workspace)?;
    let entity = crate::server::tree_entity_json(
        state,
        notifications,
        TreeDeltaKind::WorkspaceClosed,
        workspace,
    )?;
    Some(TreeDelta {
        kind: TreeDeltaKind::WorkspaceClosed,
        workspace,
        screen: None,
        pane: None,
        surface: None,
        index: Some(index),
        entity,
    })
}

/// Remove one surface from the state: detach it from its
/// pane, and collapse emptied panes/screens/workspaces. Returns whether
/// anything was removed. Runs under the state lock.
fn remove_surface(state: &mut CanonicalState, target: SurfaceId) -> Option<Arc<Surface>> {
    let removed = state.discard_surface_runtime(target);
    if let Some(surface) = &removed {
        state.terminal_activity.remove_surface(surface.uuid);
    }
    let Some(pane_id) = state.pane_of(target) else {
        return removed;
    };
    let pane = state.panes.get_mut(&pane_id).expect("pane_of returned live id");
    let idx = pane.tabs.iter().position(|id| *id == target).expect("tab in pane");
    pane.tabs.remove(idx);
    if !pane.tabs.is_empty() {
        if pane.active_tab >= idx && pane.active_tab > 0 {
            pane.active_tab -= 1;
        }
        return removed;
    }

    // Last tab gone: the pane collapses out of its screen.
    state.panes.remove(&pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return removed;
    };
    let (was_active, root) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
        (was_active, root)
    };
    match root.remove_leaf(pane_id) {
        Some(root) => {
            let next_active = if was_active {
                let mut ids = Vec::new();
                root.pane_ids(&mut ids);
                most_recent_pane(state, &ids)
            } else {
                None
            };
            let screen = &mut state.workspaces[wi].screens[si];
            screen.root = root;
            if let Some(next) = next_active {
                screen.active_pane = next;
            }
            return removed;
        }
        None => {
            // Screen emptied: drop it from the workspace.
            let ws = &mut state.workspaces[wi];
            ws.screens.remove(si);
            ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
            if !ws.screens.is_empty() {
                return removed;
            }
        }
    }

    // Workspace emptied too: drop it, keeping the active selection stable.
    let active_id = state.workspaces.get(state.active_workspace).map(|w| w.id);
    state.workspaces.remove(wi);
    state.active_workspace = active_id
        .and_then(|id| state.workspaces.iter().position(|w| w.id == id))
        .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
    removed
}

fn collapse_empty_pane(state: &mut State, pane_id: PaneId) {
    state.panes.remove(&pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return;
    };
    let (was_active, root) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
        (was_active, root)
    };
    match root.remove_leaf(pane_id) {
        Some(root) => {
            let next_active = if was_active {
                let mut ids = Vec::new();
                root.pane_ids(&mut ids);
                most_recent_pane(state, &ids)
            } else {
                None
            };
            let screen = &mut state.workspaces[wi].screens[si];
            screen.root = root;
            if let Some(next) = next_active {
                screen.active_pane = next;
            }
        }
        None => {
            let ws = &mut state.workspaces[wi];
            ws.screens.remove(si);
            ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
            if !ws.screens.is_empty() {
                return;
            }
            let active_id = state.workspaces.get(state.active_workspace).map(|w| w.id);
            state.workspaces.remove(wi);
            state.active_workspace = active_id
                .and_then(|id| state.workspaces.iter().position(|w| w.id == id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
        }
    }
}

fn move_tab_in_state(
    state: &mut State,
    surface: SurfaceId,
    target_pane: PaneId,
    index: usize,
) -> bool {
    if !state.surfaces.contains_key(&surface) || !state.panes.contains_key(&target_pane) {
        return false;
    }
    let Some(source_pane) = state.pane_of(surface) else { return false };
    if source_pane == target_pane {
        let Some(pane) = state.panes.get_mut(&target_pane) else {
            return false;
        };
        let Some(old_idx) = pane.tabs.iter().position(|id| *id == surface) else {
            return false;
        };
        let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
        let new_idx = new_idx.min(pane.tabs.len().saturating_sub(1));
        if new_idx == old_idx {
            return false;
        }
        let tab = pane.tabs.remove(old_idx);
        pane.tabs.insert(new_idx, tab);
        pane.active_tab = new_idx;
        return true;
    }

    {
        let Some(source) = state.panes.get_mut(&source_pane) else {
            return false;
        };
        let Some(old_idx) = source.tabs.iter().position(|id| *id == surface) else {
            return false;
        };
        source.tabs.remove(old_idx);
        if !source.tabs.is_empty() && source.active_tab >= old_idx && source.active_tab > 0 {
            source.active_tab -= 1;
        }
    }

    if state.panes.get(&source_pane).is_some_and(|pane| pane.tabs.is_empty()) {
        collapse_empty_pane(state, source_pane);
    }

    let Some(target) = state.panes.get_mut(&target_pane) else {
        return false;
    };
    let new_idx = index.min(target.tabs.len());
    target.tabs.insert(new_idx, surface);
    target.active_tab = new_idx;
    if let Some((wi, si)) = state.screen_of(target_pane) {
        state.active_workspace = wi;
        let ws = &mut state.workspaces[wi];
        ws.active_screen = si;
        ws.screens[si].active_pane = target_pane;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use ghostty_vt::Rgb;
    use std::collections::HashMap;
    use std::sync::mpsc::{RecvTimeoutError, TryRecvError};

    const LARGE_INITIAL_INPUT_PREFIX: &str = "\u{1b}[200~日本語🙂";

    fn canonical_safe_initial_input(total_bytes: usize) -> String {
        assert_eq!(total_bytes % TERMINAL_INITIAL_INPUT_CANONICAL_LINE_MAX_BYTES, 0);
        assert!(LARGE_INITIAL_INPUT_PREFIX.len() < 511);
        let mut input = Vec::with_capacity(total_bytes);
        input.extend_from_slice(LARGE_INITIAL_INPUT_PREFIX.as_bytes());
        input.resize(511, b'x');
        input.push(b'\n');
        while input.len() < total_bytes {
            input.extend(std::iter::repeat_n(b'x', 511));
            input.push(b'\n');
        }
        String::from_utf8(input).unwrap()
    }

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("test", SurfaceOptions::default())
    }

    fn topology_subscription(mux: &Mux, revision: u64) -> crate::TopologySubscription {
        match mux.subscribe_topology(mux.daemon_instance_id, mux.session_id, revision) {
            TopologyResume::Subscribed(subscription) => subscription,
            TopologyResume::ResnapshotRequired(required) => {
                panic!("unexpected resnapshot requirement: {:?}", required.reason)
            }
        }
    }

    fn canonical_expectation(
        mux: &Mux,
        request_id: uuid::Uuid,
        expected_revision: u64,
    ) -> CanonicalMutationExpectation {
        CanonicalMutationExpectation {
            daemon_instance_id: mux.daemon_instance_id,
            session_id: mux.session_id,
            expected_revision,
            request_id,
        }
    }

    #[test]
    fn durable_terminal_launch_waits_at_fsync_and_release_barriers() {
        let directory = PersistenceTestDirectory::new("terminal-launch-barriers");
        let store = StateStore::new(&directory.0);
        let mux = Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
            .unwrap();
        let (phase_tx, phase_rx) = std::sync::mpsc::channel();
        let (resume_tx, resume_rx) = std::sync::mpsc::channel();
        let resume_rx = Arc::new(Mutex::new(resume_rx));
        mux.state.lock().unwrap().terminal_launch_atomicity_probe = Some(Arc::new(move |phase| {
            phase_tx.send(phase).unwrap();
            resume_rx.lock().unwrap().recv().unwrap();
        }));

        let worker_mux = mux.clone();
        let worker = std::thread::spawn(move || {
            worker_mux.canonical_new_workspace(
                canonical_expectation(&worker_mux, uuid::Uuid::new_v4(), 0),
                WorkspaceUuid::new(),
                SurfaceUuid::new(),
                Some("atomic".to_string()),
                Some((80, 24)),
                TerminalLaunchRequest {
                    argv: Some(vec!["/bin/sh".to_string()]),
                    initial_input: Some("first command\n".to_string()),
                    ..TerminalLaunchRequest::default()
                },
            )
        });

        let expected = [
            TerminalLaunchAtomicityPhase::BeforeFsync,
            TerminalLaunchAtomicityPhase::AfterFsync,
            TerminalLaunchAtomicityPhase::BeforeRelease,
            TerminalLaunchAtomicityPhase::AfterRelease,
            TerminalLaunchAtomicityPhase::AfterInitialInput,
        ];
        for phase in expected {
            assert_eq!(phase_rx.recv_timeout(Duration::from_secs(2)).unwrap(), phase);
            match phase {
                TerminalLaunchAtomicityPhase::BeforeFsync
                | TerminalLaunchAtomicityPhase::AfterFsync
                | TerminalLaunchAtomicityPhase::BeforeRelease => {
                    assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 0);
                    assert_eq!(mux.terminal_launch_gate_releases.load(Ordering::Relaxed), 0);
                }
                TerminalLaunchAtomicityPhase::AfterRelease => {
                    assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 0);
                    assert_eq!(mux.terminal_launch_gate_releases.load(Ordering::Relaxed), 1);
                }
                TerminalLaunchAtomicityPhase::AfterInitialInput => {
                    assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 1);
                    assert_eq!(mux.terminal_launch_gate_releases.load(Ordering::Relaxed), 1);
                }
            }
            resume_tx.send(()).unwrap();
        }
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn terminal_close_waits_for_single_durable_launch_completion() {
        let directory = PersistenceTestDirectory::new("terminal-launch-close-fence");
        let store = StateStore::new(&directory.0);
        let mux = Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
            .unwrap();
        let workspace_uuid = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        let (before_release_tx, before_release_rx) = std::sync::mpsc::sync_channel(1);
        let (resume_tx, resume_rx) = std::sync::mpsc::sync_channel(1);
        let resume_rx = Arc::new(Mutex::new(resume_rx));
        mux.state.lock().unwrap().terminal_launch_atomicity_probe = Some(Arc::new(move |phase| {
            if phase == TerminalLaunchAtomicityPhase::BeforeRelease {
                before_release_tx.send(()).unwrap();
                resume_rx.lock().unwrap().recv().unwrap();
            }
        }));

        let launch_mux = mux.clone();
        let launch = std::thread::spawn(move || {
            launch_mux.canonical_new_workspace(
                canonical_expectation(&launch_mux, uuid::Uuid::new_v4(), 0),
                workspace_uuid,
                surface_uuid,
                None,
                None,
                TerminalLaunchRequest::default(),
            )
        });
        before_release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let surface = mux.surface_by_uuid(surface_uuid).unwrap();
        assert_eq!(mux.canonical_topology_revision(), 1);

        let close_mux = mux.clone();
        let (close_attempt_tx, close_attempt_rx) = std::sync::mpsc::sync_channel(1);
        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn(move || {
            let launch_is_fenced = close_mux.terminal_control_lifecycle.try_write().is_err();
            close_attempt_tx.send(launch_is_fenced).unwrap();
            close_mux.close_surface(surface.id);
            close_done_tx.send(()).unwrap();
        });
        assert!(close_attempt_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        assert_eq!(close_done_rx.try_recv(), Err(TryRecvError::Empty));
        assert_eq!(mux.canonical_topology_revision(), 1);
        assert!(mux.surface_by_uuid(surface_uuid).is_ok());

        resume_tx.send(()).unwrap();
        let placement = launch.join().unwrap().unwrap();
        assert_eq!(placement.receipt.revision, 1);
        close_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        close.join().unwrap();
        assert_eq!(mux.canonical_topology_revision(), 2);
        assert!(mux.surface_by_uuid(surface_uuid).is_err());
    }

    #[test]
    fn terminal_close_waits_for_every_launch_in_a_durable_batch() {
        let directory = PersistenceTestDirectory::new("terminal-launch-batch-close-fence");
        let store = StateStore::new(&directory.0);
        let mux = Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
            .unwrap();
        let first_workspace_uuid = WorkspaceUuid::new();
        let first_surface_uuid = SurfaceUuid::new();
        let second_workspace_uuid = WorkspaceUuid::new();
        let second_surface_uuid = SurfaceUuid::new();
        let (before_release_tx, before_release_rx) = std::sync::mpsc::sync_channel(2);
        let (resume_tx, resume_rx) = std::sync::mpsc::sync_channel(2);
        let resume_rx = Arc::new(Mutex::new(resume_rx));
        let release_index = Arc::new(AtomicU64::new(0));
        mux.state.lock().unwrap().terminal_launch_atomicity_probe = Some(Arc::new({
            let release_index = release_index.clone();
            move |phase| {
                if phase == TerminalLaunchAtomicityPhase::BeforeRelease {
                    let index = release_index.fetch_add(1, Ordering::Relaxed) + 1;
                    before_release_tx.send(index).unwrap();
                    resume_rx.lock().unwrap().recv().unwrap();
                }
            }
        }));

        let launch_mux = mux.clone();
        let launch = std::thread::spawn(move || {
            launch_mux.ensure_terminals(vec![
                ensure_request(first_workspace_uuid, first_surface_uuid, ""),
                ensure_request(second_workspace_uuid, second_surface_uuid, ""),
            ])
        });
        assert_eq!(before_release_rx.recv_timeout(Duration::from_secs(2)).unwrap(), 1);
        let second_surface = mux.surface_by_uuid(second_surface_uuid).unwrap();
        assert_eq!(mux.canonical_topology_revision(), 1);

        let close_mux = mux.clone();
        let (close_attempt_tx, close_attempt_rx) = std::sync::mpsc::sync_channel(1);
        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn(move || {
            let batch_is_fenced = close_mux.terminal_control_lifecycle.try_write().is_err();
            close_attempt_tx.send(batch_is_fenced).unwrap();
            close_mux.close_surface(second_surface.id);
            close_done_tx.send(()).unwrap();
        });
        assert!(close_attempt_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        assert_eq!(close_done_rx.try_recv(), Err(TryRecvError::Empty));
        assert_eq!(mux.canonical_topology_revision(), 1);

        resume_tx.send(()).unwrap();
        assert_eq!(before_release_rx.recv_timeout(Duration::from_secs(1)).unwrap(), 2);
        assert_eq!(close_done_rx.try_recv(), Err(TryRecvError::Empty));
        assert_eq!(mux.canonical_topology_revision(), 1);
        assert!(mux.surface_by_uuid(second_surface_uuid).is_ok());

        resume_tx.send(()).unwrap();
        let placements = launch.join().unwrap().unwrap();
        assert_eq!(placements.len(), 2);
        close_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        close.join().unwrap();
        assert_eq!(mux.canonical_topology_revision(), 2);
        assert!(mux.surface_by_uuid(first_surface_uuid).is_ok());
        assert!(mux.surface_by_uuid(second_surface_uuid).is_err());
        assert_eq!(mux.terminal_launch_gate_releases.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn every_durable_terminal_creation_route_uses_the_launch_gate() {
        let directory = PersistenceTestDirectory::new("terminal-launch-route-census");
        let store = StateStore::new(&directory.0);
        let mux = Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
            .unwrap();
        let phases = Arc::new(Mutex::new(Vec::new()));
        let captured = phases.clone();
        mux.state.lock().unwrap().terminal_launch_atomicity_probe =
            Some(Arc::new(move |phase| captured.lock().unwrap().push(phase)));

        let first = mux.new_workspace(Some("legacy".to_string()), None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.new_tab(Some(first_pane), None, None).unwrap();
        mux.split(first_pane, SplitDir::Right, None).unwrap();
        let first_workspace = mux.with_state(|state| state.workspaces[0].id);
        mux.new_screen(Some(first_workspace), None).unwrap();
        mux.run_command_surface(
            vec!["/bin/sh".to_string()],
            Some(first_pane),
            false,
            None,
            None,
            None,
        )
        .unwrap();
        mux.apply_layout(
            Some(first_workspace),
            None,
            &LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: None }),
            None,
        )
        .unwrap();

        let canonical_workspace_uuid = WorkspaceUuid::new();
        let canonical_surface_uuid = SurfaceUuid::new();
        let canonical_workspace = mux
            .canonical_new_workspace(
                canonical_expectation(
                    &mux,
                    uuid::Uuid::new_v4(),
                    mux.canonical_topology_revision(),
                ),
                canonical_workspace_uuid,
                canonical_surface_uuid,
                None,
                None,
                TerminalLaunchRequest::default(),
            )
            .unwrap();
        mux.canonical_materialize_terminal(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), mux.canonical_topology_revision()),
            canonical_workspace_uuid,
            SurfaceUuid::new(),
            None,
            TerminalLaunchRequest::default(),
        )
        .unwrap();
        mux.canonical_new_tab(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), mux.canonical_topology_revision()),
            canonical_workspace.pane_uuid,
            SurfaceUuid::new(),
            None,
            TerminalLaunchRequest::default(),
        )
        .unwrap();
        mux.canonical_split_pane(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), mux.canonical_topology_revision()),
            canonical_workspace.pane_uuid,
            SurfaceUuid::new(),
            SplitDir::Right,
            false,
            0.5,
            None,
            TerminalLaunchRequest::default(),
        )
        .unwrap();
        mux.canonical_respawn_terminal(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), mux.canonical_topology_revision()),
            canonical_surface_uuid,
            None,
            TerminalLaunchRequest::default(),
        )
        .unwrap();

        mux.ensure_terminal(ensure_request(WorkspaceUuid::new(), SurfaceUuid::new(), "once\n"))
            .unwrap();
        mux.ensure_terminals(vec![
            ensure_request(WorkspaceUuid::new(), SurfaceUuid::new(), "first\n"),
            ensure_request(WorkspaceUuid::new(), SurfaceUuid::new(), "second\n"),
        ])
        .unwrap();

        let phases = phases.lock().unwrap();
        assert_eq!(
            phases
                .iter()
                .filter(|phase| **phase == TerminalLaunchAtomicityPhase::BeforeFsync)
                .count(),
            13
        );
        assert_eq!(
            phases
                .iter()
                .filter(|phase| **phase == TerminalLaunchAtomicityPhase::AfterFsync)
                .count(),
            13
        );
        assert_eq!(
            phases
                .iter()
                .filter(|phase| **phase == TerminalLaunchAtomicityPhase::BeforeRelease)
                .count(),
            14
        );
        assert_eq!(
            phases
                .iter()
                .filter(|phase| **phase == TerminalLaunchAtomicityPhase::AfterRelease)
                .count(),
            14
        );
        assert_eq!(
            phases
                .iter()
                .filter(|phase| **phase == TerminalLaunchAtomicityPhase::AfterInitialInput)
                .count(),
            14
        );
        assert_eq!(mux.terminal_launch_gate_releases.load(Ordering::Relaxed), 14);
    }

    #[test]
    fn source_census_keeps_ungated_terminal_spawn_recovery_only() {
        let source = include_str!("mux.rs");
        assert_eq!(
            source
                .matches(concat!("restore_already_durable_", "surface_with_allocated_identity("))
                .count(),
            3,
            "only the definition and two recovery attempts may use the ungated durable helper",
        );
        assert_eq!(
            source
                .matches(concat!("create_already_durable_", "surface_with_allocated_identity("))
                .count(),
            2,
            "the ungated constructor must remain private to recovery",
        );
        for removed_entrypoint in [
            concat!("spawn_surface_", "with_launch("),
            concat!("write_terminal_", "initial_input("),
            concat!("spawn_surface_", "with_command("),
        ] {
            assert!(
                !source.contains(removed_entrypoint),
                "durable creation must not regain legacy spawn entrypoint {removed_entrypoint}",
            );
        }
    }

    #[test]
    fn terminal_creation_rejects_caller_supplied_launch_gate_environment() {
        let mux = test_mux();
        for name in ["CMUX_INTERNAL_LAUNCH_GATE_SOCKET", "CMUX_INTERNAL_LAUNCH_GATE_TOKEN"] {
            let launch_error = mux
                .canonical_new_workspace(
                    canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
                    WorkspaceUuid::new(),
                    SurfaceUuid::new(),
                    None,
                    None,
                    TerminalLaunchRequest {
                        env: vec![(name.to_string(), "attacker".to_string())],
                        ..TerminalLaunchRequest::default()
                    },
                )
                .unwrap_err();
            assert!(launch_error.to_string().contains("reserved launch-gate name"));

            let mut request = ensure_request(WorkspaceUuid::new(), SurfaceUuid::new(), "");
            request.env.push((name.to_string(), "attacker".to_string()));
            let ensure_error = mux.ensure_terminal(request).unwrap_err();
            assert!(ensure_error.to_string().contains("invalid name or value"));
        }
        assert_eq!(mux.canonical_topology_revision(), 0);
        assert!(mux.state.lock().unwrap().surfaces.is_empty());
    }

    #[test]
    fn initial_input_lines_enforce_canonical_safe_boundary() {
        let accepted = format!("{}\n{}", "x".repeat(511), "y".repeat(512));
        let accepted_launch = TerminalLaunchRequest {
            initial_input: Some(accepted.clone()),
            ..TerminalLaunchRequest::default()
        };
        validate_terminal_launch_request(&accepted_launch).unwrap();
        validate_ensure_terminal_request(&ensure_request(
            WorkspaceUuid::new(),
            SurfaceUuid::new(),
            &accepted,
        ))
        .unwrap();

        for rejected in [format!("{}\n", "x".repeat(512)), "x".repeat(513)] {
            let launch_error = validate_terminal_launch_request(&TerminalLaunchRequest {
                initial_input: Some(rejected.clone()),
                ..TerminalLaunchRequest::default()
            })
            .unwrap_err();
            assert!(launch_error.to_string().contains("512 bytes including newline"));

            let ensure_error = validate_ensure_terminal_request(&ensure_request(
                WorkspaceUuid::new(),
                SurfaceUuid::new(),
                &rejected,
            ))
            .unwrap_err();
            assert!(ensure_error.to_string().contains("512 bytes including newline"));
        }
    }

    fn receive_test_datagram(
        receiver: &std::os::unix::net::UnixDatagram,
        timeout: Duration,
    ) -> std::io::Result<Vec<u8>> {
        receiver.set_read_timeout(Some(timeout))?;
        let mut message = vec![0u8; 64];
        let length = receiver.recv(&mut message)?;
        message.truncate(length);
        Ok(message)
    }

    #[test]
    fn large_initial_input_reader_entrypoint() {
        let Some(socket) = std::env::var_os("CMUX_TEST_LARGE_INPUT_SOCKET") else {
            return;
        };
        assert!(std::env::var_os("CMUX_INTERNAL_LAUNCH_GATE_SOCKET").is_none());
        assert!(std::env::var_os("CMUX_INTERNAL_LAUNCH_GATE_TOKEN").is_none());
        let expected =
            std::env::var("CMUX_TEST_LARGE_INPUT_LENGTH").unwrap().parse::<usize>().unwrap();
        let ordered_suffix = std::env::var_os("CMUX_TEST_LARGE_INPUT_ORDERED_SUFFIX").is_some();
        let expected_input = canonical_safe_initial_input(expected);
        let suffix_bytes = if ordered_suffix { 2 } else { 0 };
        let mut input = vec![0u8; expected + suffix_bytes];
        let stdin = std::io::stdin();
        let mut reader = std::io::BufReader::with_capacity(257, stdin.lock());
        for byte in &mut input {
            std::io::Read::read_exact(&mut reader, std::slice::from_mut(byte)).unwrap();
        }
        assert_eq!(&input[..expected], expected_input.as_bytes());
        if ordered_suffix {
            assert_eq!(&input[expected..], b"y\n");
        }
        let completion = std::os::unix::net::UnixDatagram::unbound().unwrap();
        completion.connect(socket).unwrap();
        assert_eq!(completion.send(b"clean\n").unwrap(), 6);
    }

    #[test]
    fn one_megabyte_initial_input_is_delivered_once_after_exec_in_order() {
        const INPUT_BYTES: usize = 1024 * 1024;

        let directory = PersistenceTestDirectory::new("large-initial-input");
        std::fs::create_dir_all(&directory.0).unwrap();
        let socket = std::path::PathBuf::from("/tmp").join(format!(
            "cmux-li-{}-{}.sock",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let receiver = std::os::unix::net::UnixDatagram::bind(&socket).unwrap();
        let store = StateStore::new(&directory.0.join("store"));
        let mux = Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        let request_id = uuid::Uuid::new_v4();
        let workspace_uuid = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        let executable = std::env::current_exe().unwrap();
        let launch = TerminalLaunchRequest {
            argv: Some(vec![
                executable.to_string_lossy().into_owned(),
                "--exact".to_string(),
                "mux::tests::large_initial_input_reader_entrypoint".to_string(),
                "--nocapture".to_string(),
            ]),
            env: vec![
                ("CMUX_TEST_LARGE_INPUT_SOCKET".to_string(), socket.to_string_lossy().into_owned()),
                ("CMUX_TEST_LARGE_INPUT_LENGTH".to_string(), INPUT_BYTES.to_string()),
                ("CMUX_TEST_LARGE_INPUT_ORDERED_SUFFIX".to_string(), "1".to_string()),
            ],
            initial_input: Some(canonical_safe_initial_input(INPUT_BYTES)),
            wait_after_command: true,
            ..TerminalLaunchRequest::default()
        };
        let expectation = canonical_expectation(&mux, request_id, 0);
        let (before_release_tx, before_release_rx) = std::sync::mpsc::channel();
        let (resume_tx, resume_rx) = std::sync::mpsc::channel();
        let resume_rx = Arc::new(Mutex::new(resume_rx));
        mux.state.lock().unwrap().terminal_launch_atomicity_probe = Some(Arc::new(move |phase| {
            if phase == TerminalLaunchAtomicityPhase::BeforeRelease {
                before_release_tx.send(()).unwrap();
                resume_rx.lock().unwrap().recv().unwrap();
            }
        }));
        let launch_mux = mux.clone();
        let first_launch = launch.clone();
        let launch_worker = std::thread::spawn(move || {
            launch_mux.canonical_new_workspace(
                expectation,
                workspace_uuid,
                surface_uuid,
                None,
                Some((80, 24)),
                first_launch,
            )
        });
        before_release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let surface = mux.surface_by_uuid(surface_uuid).unwrap();
        let (write_done_tx, write_done_rx) = std::sync::mpsc::channel();
        let write_worker = std::thread::spawn(move || {
            surface.write_bytes(b"y\n").unwrap();
            write_done_tx.send(()).unwrap();
        });
        assert!(
            matches!(
                write_done_rx.recv_timeout(Duration::from_millis(50)),
                Err(RecvTimeoutError::Timeout)
            ),
            "ordinary PTY input bypassed the launch input reservation"
        );
        resume_tx.send(()).unwrap();
        launch_worker.join().unwrap().unwrap();
        write_done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        write_worker.join().unwrap();
        let replay = mux
            .canonical_new_workspace(
                expectation,
                workspace_uuid,
                surface_uuid,
                None,
                Some((80, 24)),
                launch,
            )
            .unwrap();
        assert!(replay.receipt.replayed);
        let completion =
            receive_test_datagram(&receiver, Duration::from_secs(5)).unwrap_or_else(|error| {
                let terminal = mux
                    .surface_by_uuid(surface_uuid)
                    .unwrap()
                    .try_with_terminal(|terminal| terminal.plain_text())
                    .unwrap()
                    .unwrap();
                panic!("reader did not complete: {error}; terminal output: {terminal:?}");
            });
        assert_eq!(completion, b"clean\n");
        assert_eq!(mux.terminal_launch_gate_releases.load(Ordering::Relaxed), 1);
        drop(receiver);
        std::fs::remove_file(socket).unwrap();
    }

    #[test]
    fn initial_input_non_reader_entrypoint() {
        let Some(marker) = std::env::var_os("CMUX_TEST_NON_READER_EXIT_MARKER") else {
            return;
        };
        unsafe {
            libc::signal(libc::SIGHUP, libc::SIG_IGN);
        }
        let original_parent = unsafe { libc::getppid() };
        let deadline = Instant::now() + Duration::from_secs(10);
        while unsafe { libc::getppid() } == original_parent && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        std::fs::write(marker, b"parent-exited").unwrap();
    }

    #[test]
    fn initial_input_missing_reader_child_aborts() {
        let Some(root) = std::env::var_os("CMUX_TEST_MISSING_READER_ROOT") else {
            return;
        };
        let root = std::path::PathBuf::from(root);
        let target_exit_marker = root.join("target-exited");
        let store = StateStore::new(root.join("store"));
        let mux = Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        let executable = std::env::current_exe().unwrap();
        mux.canonical_new_workspace(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
            WorkspaceUuid::new(),
            SurfaceUuid::new(),
            None,
            Some((80, 24)),
            TerminalLaunchRequest {
                argv: Some(vec![
                    executable.to_string_lossy().into_owned(),
                    "--exact".to_string(),
                    "mux::tests::initial_input_non_reader_entrypoint".to_string(),
                    "--nocapture".to_string(),
                ]),
                env: vec![(
                    "CMUX_TEST_NON_READER_EXIT_MARKER".to_string(),
                    target_exit_marker.to_string_lossy().into_owned(),
                )],
                initial_input: Some(canonical_safe_initial_input(1024 * 1024)),
                ..TerminalLaunchRequest::default()
            },
        )
        .unwrap();
        panic!("missing initial-input reader returned instead of aborting");
    }

    #[test]
    fn missing_initial_input_reader_fails_stop_after_durable_commit() {
        let directory = PersistenceTestDirectory::new("missing-initial-input-reader");
        std::fs::create_dir_all(&directory.0).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("--exact")
            .arg("mux::tests::initial_input_missing_reader_child_aborts")
            .arg("--nocapture")
            .env("CMUX_TEST_MISSING_READER_ROOT", &directory.0)
            .env("CMUX_TEST_TERMINAL_INITIAL_INPUT_DEADLINE_MS", "100")
            .output()
            .unwrap();
        assert!(!output.status.success(), "missing-reader child unexpectedly returned success");
        assert!(directory.0.join("target-exited").is_file());
        let reopened = StateStore::new(directory.0.join("store")).open_session("main").unwrap();
        assert_eq!(reopened.snapshot.topology_revision, 1);
        assert_eq!(reopened.snapshot.surfaces.len(), 1);
    }

    #[test]
    fn executable_disappearance_after_ready_child_aborts() {
        let Some(root) = std::env::var_os("CMUX_TEST_DISAPPEARING_EXECUTABLE_ROOT") else {
            return;
        };
        let root = std::path::PathBuf::from(root);
        let executable = root.join("disappearing-command");
        let user_marker = root.join("user-command-ran");
        std::fs::write(&executable, format!("#!/bin/sh\nprintf ran > {}\n", user_marker.display()))
            .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let remove = executable.clone();
        let store = StateStore::new(root.join("store"));
        let mux = Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        mux.state.lock().unwrap().terminal_launch_atomicity_probe = Some(Arc::new(move |phase| {
            if phase == TerminalLaunchAtomicityPhase::BeforeFsync {
                std::fs::remove_file(&remove).unwrap();
            }
        }));
        mux.canonical_new_workspace(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
            WorkspaceUuid::new(),
            SurfaceUuid::new(),
            None,
            None,
            TerminalLaunchRequest {
                argv: Some(vec![executable.to_string_lossy().into_owned()]),
                ..TerminalLaunchRequest::default()
            },
        )
        .unwrap();
        panic!("disappearing executable returned instead of aborting");
    }

    #[test]
    fn executable_disappearance_after_ready_is_fail_stop_without_user_code() {
        let directory = PersistenceTestDirectory::new("disappearing-executable");
        std::fs::create_dir_all(&directory.0).unwrap();
        let gate_exit_marker = directory.0.join("gate-exited");
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("--exact")
            .arg("mux::tests::executable_disappearance_after_ready_child_aborts")
            .arg("--nocapture")
            .env("CMUX_TEST_DISAPPEARING_EXECUTABLE_ROOT", &directory.0)
            .env(crate::launch_gate::test_support::EXIT_MARKER_ENV, &gate_exit_marker)
            .output()
            .unwrap();
        assert!(!output.status.success(), "disappearing-executable child returned success");
        assert!(gate_exit_marker.is_file());
        assert!(!directory.0.join("user-command-ran").exists());
        let reopened = StateStore::new(directory.0.join("store")).open_session("main").unwrap();
        assert_eq!(reopened.snapshot.topology_revision, 1);
        assert_eq!(reopened.snapshot.surfaces.len(), 1);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn post_release_helper_death_child_must_abort_before_acknowledgement() {
        let Some(root) = std::env::var_os("CMUX_TEST_POST_RELEASE_HELPER_DEATH_ROOT") else {
            return;
        };
        let root = std::path::PathBuf::from(root);
        let store = StateStore::new(root.join("store"));
        let mux = Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        mux.canonical_new_workspace(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
            WorkspaceUuid::new(),
            SurfaceUuid::new(),
            None,
            None,
            TerminalLaunchRequest {
                argv: Some(vec!["/usr/bin/true".to_string()]),
                env: vec![(
                    crate::launch_gate::test_support::DIE_AFTER_RELEASE_ENV.to_string(),
                    "1".to_string(),
                )],
                ..TerminalLaunchRequest::default()
            },
        )
        .unwrap();
        std::fs::write(root.join("acknowledged"), b"acknowledged").unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn post_release_helper_death_is_fail_stop_with_durable_topology() {
        let directory = PersistenceTestDirectory::new("post-release-helper-death");
        std::fs::create_dir_all(&directory.0).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("--exact")
            .arg("mux::tests::post_release_helper_death_child_must_abort_before_acknowledgement")
            .arg("--nocapture")
            .env("CMUX_TEST_POST_RELEASE_HELPER_DEATH_ROOT", &directory.0)
            .output()
            .unwrap();
        assert!(!output.status.success(), "post-release helper death was acknowledged");
        assert!(!directory.0.join("acknowledged").exists());
        let reopened = StateStore::new(directory.0.join("store")).open_session("main").unwrap();
        assert_eq!(reopened.snapshot.topology_revision, 1);
        assert_eq!(reopened.snapshot.surfaces.len(), 1);
    }

    #[test]
    fn launch_gate_validates_executable_before_topology_commit() {
        let directory = PersistenceTestDirectory::new("precommit-executable-validation");
        std::fs::create_dir_all(&directory.0).unwrap();
        let plain = directory.0.join("plain");
        std::fs::write(&plain, b"plain").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&plain, std::fs::Permissions::from_mode(0o600)).unwrap();
        let folder = directory.0.join("folder");
        std::fs::create_dir(&folder).unwrap();
        let store = StateStore::new(directory.0.join("store"));
        let mux = Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();

        for argv0 in [directory.0.join("missing"), plain, folder] {
            let error = mux
                .canonical_new_workspace(
                    canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
                    WorkspaceUuid::new(),
                    SurfaceUuid::new(),
                    None,
                    None,
                    TerminalLaunchRequest {
                        argv: Some(vec![argv0.to_string_lossy().into_owned()]),
                        ..TerminalLaunchRequest::default()
                    },
                )
                .unwrap_err();
            assert!(
                error.to_string().contains("launch gate")
                    || error.to_string().contains("failed to fill whole buffer")
                    || error.to_string().contains("early eof"),
                "unexpected precommit validation error: {error:#}"
            );
        }
        assert_eq!(mux.canonical_topology_revision(), 0);
        assert!(mux.state.lock().unwrap().surfaces.is_empty());
    }

    #[test]
    fn unready_helper_ignoring_hup_is_killed_without_committing_or_execing() {
        let directory = PersistenceTestDirectory::new("unready-helper-ignores-hup");
        std::fs::create_dir_all(&directory.0).unwrap();
        let user_marker = directory.0.join("user-command-ran");
        let executable = directory.0.join("must-not-exec");
        std::fs::write(&executable, format!("#!/bin/sh\nprintf ran > {}\n", user_marker.display()))
            .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let store = StateStore::new(directory.0.join("store"));
        let mux = Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        let started = Instant::now();
        let error = mux
            .canonical_new_workspace(
                canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
                WorkspaceUuid::new(),
                SurfaceUuid::new(),
                None,
                None,
                TerminalLaunchRequest {
                    argv: Some(vec![executable.to_string_lossy().into_owned()]),
                    env: vec![
                        (
                            crate::launch_gate::test_support::FAIL_BEFORE_READY_ENV.to_string(),
                            "1".to_string(),
                        ),
                        (
                            crate::launch_gate::test_support::IGNORE_HUP_ENV.to_string(),
                            "1".to_string(),
                        ),
                    ],
                    ..TerminalLaunchRequest::default()
                },
            )
            .unwrap_err();
        assert!(started.elapsed() < Duration::from_secs(2), "unready helper cleanup wedged");
        assert!(!user_marker.exists());
        assert_eq!(mux.canonical_topology_revision(), 0);
        assert!(mux.state.lock().unwrap().surfaces.is_empty());
        assert!(error.to_string().contains("launch gate") || error.to_string().contains("buffer"));
    }

    #[test]
    fn launch_gate_executes_exact_relative_and_path_resolutions() {
        let directory = PersistenceTestDirectory::new("executable-resolution");
        std::fs::create_dir_all(&directory.0).unwrap();
        use std::os::unix::fs::PermissionsExt;
        let relative = directory.0.join("relative-tool");
        std::fs::write(&relative, b"#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&relative, std::fs::Permissions::from_mode(0o700)).unwrap();
        let bin = directory.0.join("bin");
        std::fs::create_dir(&bin).unwrap();
        let path_tool = bin.join("path-tool");
        std::fs::write(&path_tool, b"#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&path_tool, std::fs::Permissions::from_mode(0o700)).unwrap();
        let store = StateStore::new(directory.0.join("store"));
        let mux = Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();

        mux.canonical_new_workspace(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
            WorkspaceUuid::new(),
            SurfaceUuid::new(),
            None,
            None,
            TerminalLaunchRequest {
                cwd: Some(directory.0.to_string_lossy().into_owned()),
                argv: Some(vec!["./relative-tool".to_string()]),
                wait_after_command: true,
                ..TerminalLaunchRequest::default()
            },
        )
        .unwrap();
        mux.canonical_new_workspace(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 1),
            WorkspaceUuid::new(),
            SurfaceUuid::new(),
            None,
            None,
            TerminalLaunchRequest {
                cwd: Some(directory.0.to_string_lossy().into_owned()),
                argv: Some(vec!["path-tool".to_string()]),
                env: vec![("PATH".to_string(), "bin".to_string())],
                wait_after_command: true,
                ..TerminalLaunchRequest::default()
            },
        )
        .unwrap();
        assert_eq!(mux.canonical_topology_revision(), 2);
        assert_eq!(mux.terminal_launch_gate_releases.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn canonical_creation_echoes_and_replays_request_id_without_duplicate_state() {
        let mux = test_mux();
        let request_id = uuid::Uuid::new_v4();
        let workspace_uuid = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        let placement = mux
            .canonical_new_workspace(
                canonical_expectation(&mux, request_id, 0),
                workspace_uuid,
                surface_uuid,
                Some("canonical".into()),
                Some((80, 24)),
                TerminalLaunchRequest::default(),
            )
            .unwrap();
        assert_eq!(placement.receipt.request_id, request_id);
        assert_eq!(placement.receipt.base_revision, 0);
        assert_eq!(placement.receipt.revision, 1);
        assert!(!placement.receipt.replayed);
        let committed = mux.topology_snapshot();

        let replay = mux
            .canonical_new_workspace(
                canonical_expectation(&mux, request_id, 0),
                workspace_uuid,
                surface_uuid,
                Some("canonical".into()),
                Some((80, 24)),
                TerminalLaunchRequest::default(),
            )
            .unwrap();
        assert_eq!(replay.receipt.request_id, request_id);
        assert_eq!(replay.receipt.revision, 1);
        assert!(replay.receipt.replayed);
        assert_eq!(mux.topology_snapshot(), committed);

        let changed_name = mux.canonical_new_workspace(
            canonical_expectation(&mux, request_id, 0),
            workspace_uuid,
            surface_uuid,
            Some("changed".into()),
            Some((80, 24)),
            TerminalLaunchRequest::default(),
        );
        assert!(changed_name.unwrap_err().to_string().contains("payload changed"));

        let changed_launch = mux.canonical_new_workspace(
            canonical_expectation(&mux, request_id, 0),
            workspace_uuid,
            surface_uuid,
            Some("canonical".into()),
            Some((80, 24)),
            TerminalLaunchRequest {
                command: Some("printf must-not-run".into()),
                env: vec![("LANG".into(), "C".into())],
                initial_input: Some("changed-input".into()),
                ..TerminalLaunchRequest::default()
            },
        );
        assert!(changed_launch.unwrap_err().to_string().contains("payload changed"));
        assert_eq!(mux.topology_snapshot(), committed);

        let changed_payload = mux.canonical_new_workspace(
            canonical_expectation(&mux, request_id, 0),
            workspace_uuid,
            SurfaceUuid::new(),
            Some("canonical".into()),
            Some((80, 24)),
            TerminalLaunchRequest::default(),
        );
        assert!(changed_payload.is_err());
        assert_eq!(mux.topology_snapshot(), committed);

        let stale = mux.canonical_new_workspace(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
            WorkspaceUuid::new(),
            SurfaceUuid::new(),
            None,
            Some((80, 24)),
            TerminalLaunchRequest::default(),
        );
        assert!(stale.is_err());
        assert_eq!(mux.topology_snapshot(), committed);
    }

    #[test]
    fn live_replay_rejects_changed_private_browser_and_remote_sources_without_echoing_them() {
        let mux = test_mux();
        let browser_request = uuid::Uuid::new_v4();
        let browser_surface = SurfaceUuid::new();
        let browser_source_a = "https://private.invalid/sentinel-browser-a";
        let browser_source_b = "https://private.invalid/sentinel-browser-b";
        mux.canonical_new_browser_workspace_with_presentation(
            canonical_expectation(&mux, browser_request, 0),
            WorkspaceUuid::new(),
            browser_surface,
            None,
            browser_source_a.into(),
            Some((80, 24)),
            BrowserPresentationMode::FrontendNative,
        )
        .unwrap();
        let browser_topology = mux.topology_snapshot();
        let browser_error = mux
            .canonical_new_browser_workspace_with_presentation(
                canonical_expectation(&mux, browser_request, 0),
                browser_topology.topology["workspaces"][0]["uuid"]
                    .as_str()
                    .unwrap()
                    .parse()
                    .unwrap(),
                browser_surface,
                None,
                browser_source_b.into(),
                Some((80, 24)),
                BrowserPresentationMode::FrontendNative,
            )
            .unwrap_err()
            .to_string();
        assert!(browser_error.contains("replay source changed"));
        assert!(!browser_error.contains("sentinel-browser"));
        assert_eq!(mux.topology_snapshot(), browser_topology);
        let browser_claim = mux
            .claim_frontend_native_browser(
                browser_surface,
                FrontendNativeBrowserOwner {
                    client_uuid: uuid::Uuid::new_v4(),
                    process_instance_uuid: uuid::Uuid::new_v4(),
                    connection_id: 1,
                },
                uuid::Uuid::new_v4(),
                None,
            )
            .unwrap();
        assert_eq!(browser_claim.source_url.as_deref(), Some(browser_source_a));

        let producer_id = uuid::Uuid::new_v4();
        let provenance = ExternalTerminalProvenance {
            producer_kind: crate::remote_tmux_producer::ExternalTerminalProducerKind::RemoteTmux,
            producer_id,
            tmux_session_id: 7,
            tmux_window_id: 11,
            tmux_pane_id: 13,
            presentation_role:
                crate::remote_tmux_producer::ExternalTerminalPresentationRole::WorkspaceTab,
        };
        let source_a = RemoteTmuxProducerSource {
            destination: "agent@sentinel-remote-a.invalid".into(),
            port: None,
            identity_file: None,
            session_name: "agents-a".into(),
        };
        let source_b = RemoteTmuxProducerSource {
            destination: "agent@sentinel-remote-b.invalid".into(),
            port: None,
            identity_file: None,
            session_name: "agents-b".into(),
        };
        let external_request = uuid::Uuid::new_v4();
        let external_workspace = WorkspaceUuid::new();
        let external_surface = SurfaceUuid::new();
        mux.canonical_new_external_workspace(
            canonical_expectation(&mux, external_request, 1),
            external_workspace,
            external_surface,
            (80, 24),
            true,
            provenance,
            source_a.clone(),
        )
        .unwrap();
        let external_topology = mux.topology_snapshot();
        let external_error = mux
            .canonical_new_external_workspace(
                canonical_expectation(&mux, external_request, 1),
                external_workspace,
                external_surface,
                (80, 24),
                true,
                provenance,
                source_b,
            )
            .unwrap_err()
            .to_string();
        assert!(external_error.contains("replay source changed"));
        assert!(!external_error.contains("sentinel-remote"));
        assert_eq!(mux.topology_snapshot(), external_topology);
        let producer_claim = mux
            .claim_remote_tmux_producer_source(
                producer_id,
                RemoteTmuxProducerOwner {
                    client_uuid: uuid::Uuid::new_v4(),
                    process_instance_uuid: uuid::Uuid::new_v4(),
                    connection_id: 2,
                },
                uuid::Uuid::new_v4(),
                None,
            )
            .unwrap();
        assert_eq!(producer_claim.source, Some(source_a));
        let topology_text = external_topology.topology.to_string();
        assert!(!topology_text.contains("sentinel-browser"));
        assert!(!topology_text.contains("sentinel-remote"));
    }

    #[test]
    fn canonical_replay_rejects_changed_non_creation_order() {
        let mux = test_mux();
        let first_surface = SurfaceUuid::new();
        let first = mux
            .canonical_new_workspace(
                canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
                WorkspaceUuid::new(),
                first_surface,
                None,
                Some((80, 24)),
                TerminalLaunchRequest::default(),
            )
            .unwrap();
        let second_surface = SurfaceUuid::new();
        mux.canonical_new_tab(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 1),
            first.pane_uuid,
            second_surface,
            Some((80, 24)),
            TerminalLaunchRequest::default(),
        )
        .unwrap();

        let request_id = uuid::Uuid::new_v4();
        mux.canonical_reorder_tabs(
            canonical_expectation(&mux, request_id, 2),
            first.pane_uuid,
            vec![second_surface, first_surface],
        )
        .unwrap();
        let committed = mux.topology_snapshot();
        let changed_order = mux.canonical_reorder_tabs(
            canonical_expectation(&mux, request_id, 2),
            first.pane_uuid,
            vec![first_surface, second_surface],
        );
        assert!(changed_order.unwrap_err().to_string().contains("payload changed"));
        assert_eq!(mux.topology_snapshot(), committed);
    }

    #[test]
    fn canonical_split_tab_discards_failed_candidate_without_digest_change() {
        let mux = test_mux();
        let workspace_uuid = WorkspaceUuid::new();
        let first_surface_uuid = SurfaceUuid::new();
        let first = mux
            .canonical_new_workspace(
                canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
                workspace_uuid,
                first_surface_uuid,
                None,
                Some((80, 24)),
                TerminalLaunchRequest::default(),
            )
            .unwrap();
        mux.canonical_new_tab(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 1),
            first.pane_uuid,
            SurfaceUuid::new(),
            Some((80, 24)),
            TerminalLaunchRequest::default(),
        )
        .unwrap();
        let before = mux.topology_snapshot();
        mux.canonical_split_tab_fail_after_split.store(true, Ordering::Relaxed);
        let failed = mux.canonical_split_tab(
            canonical_expectation(&mux, uuid::Uuid::new_v4(), 2),
            first_surface_uuid,
            first.pane_uuid,
            SplitDir::Right,
            false,
            0.5,
        );
        assert!(failed.is_err());
        assert_eq!(mux.topology_snapshot(), before);
        assert_eq!(mux.canonical_topology_revision(), 2);
    }

    #[test]
    fn canonical_materialize_and_respawn_replace_runtime_once_and_ignore_stale_exit() {
        let mux = test_mux();
        let workspace_uuid = WorkspaceUuid::new();
        let initial = mux
            .canonical_new_workspace(
                canonical_expectation(&mux, uuid::Uuid::new_v4(), 0),
                workspace_uuid,
                SurfaceUuid::new(),
                None,
                Some((80, 24)),
                TerminalLaunchRequest::default(),
            )
            .unwrap();
        let surface_uuid = SurfaceUuid::new();
        let materialized = mux
            .canonical_materialize_terminal(
                canonical_expectation(&mux, uuid::Uuid::new_v4(), 1),
                workspace_uuid,
                surface_uuid,
                Some((100, 30)),
                TerminalLaunchRequest::default(),
            )
            .unwrap();
        assert_eq!(materialized.workspace_uuid, workspace_uuid);
        assert_eq!(materialized.pane_uuid, initial.pane_uuid);
        let old_surface = mux.surface(materialized.surface).unwrap();
        let old_epoch = old_surface.semantic_scene_terminal_identity().unwrap().runtime_epoch;

        let request_id = uuid::Uuid::new_v4();
        let respawned = mux
            .canonical_respawn_terminal(
                canonical_expectation(&mux, request_id, 2),
                surface_uuid,
                Some((120, 40)),
                TerminalLaunchRequest {
                    env: vec![("RESPAWN_TEST".into(), "1".into())],
                    ..TerminalLaunchRequest::default()
                },
            )
            .unwrap();
        assert_ne!(respawned.surface, materialized.surface);
        assert_eq!(respawned.surface_uuid, surface_uuid);
        assert!(mux.surface(materialized.surface).is_none());
        let replacement = mux.surface(respawned.surface).unwrap();
        assert_ne!(
            replacement.semantic_scene_terminal_identity().unwrap().runtime_epoch,
            old_epoch
        );
        assert_eq!(replacement.size(), (120, 40));

        mux.surface_runtime_exited(&old_surface);
        assert!(Arc::ptr_eq(&mux.surface(respawned.surface).unwrap(), &replacement));

        let committed = mux.topology_snapshot();
        let replay = mux
            .canonical_respawn_terminal(
                canonical_expectation(&mux, request_id, 2),
                surface_uuid,
                Some((120, 40)),
                TerminalLaunchRequest {
                    env: vec![("RESPAWN_TEST".into(), "1".into())],
                    ..TerminalLaunchRequest::default()
                },
            )
            .unwrap();
        assert!(replay.receipt.replayed);
        assert_eq!(replay.surface, respawned.surface);
        assert_eq!(mux.topology_snapshot(), committed);

        let changed = mux.canonical_respawn_terminal(
            canonical_expectation(&mux, request_id, 2),
            surface_uuid,
            Some((120, 40)),
            TerminalLaunchRequest {
                env: vec![("RESPAWN_TEST".into(), "changed".into())],
                ..TerminalLaunchRequest::default()
            },
        );
        assert!(changed.unwrap_err().to_string().contains("payload changed"));
        assert_eq!(mux.topology_snapshot(), committed);
    }

    #[test]
    fn resolved_custom_shader_count_uses_exact_nonempty_config_entries() {
        assert_eq!(
            resolved_custom_shader_count(
                b"font-size = 13\ncustom-shader = one.glsl\n custom-shader=two.glsl\ncustom-shader = \n"
            )
            .unwrap(),
            2
        );
        assert_eq!(resolved_custom_shader_count(b"").unwrap(), 0);
        assert!(resolved_custom_shader_count(&[0xff]).is_err());
    }

    #[test]
    fn renderer_epoch_binding_has_one_winner_and_advances_monotonically() {
        let bound = Arc::new(Mutex::new(0));
        let contenders = (0..32)
            .map(|_| {
                let bound = bound.clone();
                std::thread::spawn(move || claim_new_renderer_epoch(&bound, 7).is_some())
            })
            .collect::<Vec<_>>();

        let winners = contenders
            .into_iter()
            .map(|contender| contender.join().unwrap())
            .filter(|won| *won)
            .count();
        assert_eq!(winners, 1);
        assert_eq!(*bound.lock().unwrap(), 7);
        assert!(claim_new_renderer_epoch(&bound, 0).is_none());
        assert!(claim_new_renderer_epoch(&bound, 6).is_none());
        assert!(claim_new_renderer_epoch(&bound, 7).is_none());
        assert!(claim_new_renderer_epoch(&bound, 8).is_some());
        assert_eq!(*bound.lock().unwrap(), 8);
    }

    #[test]
    fn renderer_rehydrate_index_visits_only_presentations_in_the_ready_workspace() {
        let mut index = RendererPresentationWorkspaceIndex::default();
        for _ in 0..1_000 {
            index.insert(WorkspaceUuid::new(), crate::PresentationId::new());
        }
        let ready_workspace = WorkspaceUuid::new();
        let mut ready_presentations =
            (0..3).map(|_| crate::PresentationId::new()).collect::<Vec<_>>();
        ready_presentations.sort_unstable();
        for presentation_id in &ready_presentations {
            index.insert(ready_workspace, *presentation_id);
        }

        let selected = index.presentation_ids_for_rehydration(ready_workspace);
        assert_eq!(selected, ready_presentations);
        assert_eq!(index.rehydration_presentation_visits, 3);

        assert!(index.presentation_ids_for_rehydration(WorkspaceUuid::new()).is_empty());
        assert_eq!(index.rehydration_presentation_visits, 3);
        for presentation_id in ready_presentations {
            index.remove(ready_workspace, presentation_id);
        }
        assert!(index.get(ready_workspace).is_none());
    }

    #[test]
    fn failed_viewer_resize_preserves_previous_report_and_creation_default() {
        let mux = test_mux();
        let missing_surface = 99_999;
        mux.record_client_size(90, 30);
        mux.client_sizing
            .lock()
            .unwrap()
            .surfaces
            .entry(missing_surface)
            .or_default()
            .insert(7, (80, 25));

        assert!(mux.resize_surface_for_client(missing_surface, 7, 120, 40).is_err());
        assert_eq!(mux.client_surface_size(missing_surface, 7), Some((80, 25)));
        assert_eq!(mux.latest_client_size.lock().unwrap().size, Some((90, 30)));
    }

    #[test]
    fn removing_smallest_viewer_updates_unsized_creation_default() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 50).unwrap();
        assert_eq!(surface.size(), (80, 40));

        mux.remove_surface_size_client(surface.id, 2);
        assert_eq!(surface.size(), (120, 40));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (120, 40));
    }

    #[test]
    fn removing_latest_report_restores_previous_surface_creation_default() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let second = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(first.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(second.id, 2, 80, 24).unwrap();
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (80, 24));

        mux.remove_surface_size_client(second.id, 2);

        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (120, 40));
    }

    #[test]
    fn removing_last_viewer_restores_default_for_unsized_creation() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 117, 30).unwrap();
        mux.remove_size_client(1);

        assert_eq!(surface.size(), (117, 30));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (80, 24));
    }

    #[test]
    fn excluded_viewer_keeps_reporting_without_constraining_the_shared_grid() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 50).unwrap();
        assert_eq!(surface.size(), (80, 40));

        assert_eq!(mux.set_client_size_participation(2, false), Some(true));
        assert_eq!(surface.size(), (120, 40));
        assert!(!mux.client_size_participates(2));

        mux.resize_surface_for_client(surface.id, 2, 60, 30).unwrap();
        assert_eq!(surface.size(), (120, 40));
        assert_eq!(mux.client_surface_size(surface.id, 2), Some((60, 30)));

        assert_eq!(mux.set_client_size_participation(2, true), Some(true));
        assert_eq!(surface.size(), (60, 30));
        assert!(mux.client_size_participates(2));
    }

    #[test]
    fn local_sizing_mutations_broadcast_authoritative_client_changes() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 7, 80, 24).unwrap();
        let events = mux.subscribe();

        assert_eq!(mux.set_client_size_participation(7, false), Some(true));

        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: 7, .. })
        ));
    }

    #[test]
    fn stale_sizing_target_does_not_change_exclusive_state() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 24).unwrap();
        assert_eq!(mux.use_only_client_size(1), Some(true));

        assert_eq!(mux.set_client_size_participation(99, false), None);

        assert!(mux.client_size_participates(1));
        assert!(!mux.client_size_participates(2));
    }

    #[test]
    fn all_excluded_viewers_fall_back_to_their_shared_minimum() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 50).unwrap();
        assert_eq!(surface.size(), (80, 40));

        assert_eq!(mux.set_client_size_participation(1, false), Some(true));
        assert_eq!(surface.size(), (80, 50));
        assert_eq!(mux.set_client_size_participation(2, false), Some(true));

        // tmux's ignore-size flag is only effective while at least one
        // size-capable client is not ignored. If every viewer is ignored,
        // they all participate again so the shared grid remains defined.
        assert_eq!(surface.size(), (80, 40));
    }

    #[test]
    fn excluding_last_participant_recalculates_other_visible_surfaces() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let second = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(first.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(second.id, 2, 80, 25).unwrap();
        assert_eq!(mux.set_client_size_participation(2, false), Some(true));

        // Keep the ignored client's report current without applying it while
        // another size-capable client still participates elsewhere.
        mux.resize_surface_for_client(second.id, 2, 60, 20).unwrap();
        assert_eq!(second.size(), (80, 25));

        assert_eq!(mux.set_client_size_participation(1, false), Some(true));
        assert_eq!(first.size(), (120, 40));
        assert_eq!(second.size(), (60, 20));
    }

    #[test]
    fn detaching_last_participant_recalculates_ignored_surfaces() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let second = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(first.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(second.id, 2, 80, 25).unwrap();
        assert_eq!(mux.set_client_size_participation(2, false), Some(true));
        mux.resize_surface_for_client(second.id, 2, 60, 20).unwrap();
        assert_eq!(second.size(), (80, 25));

        mux.remove_size_client(1);
        assert_eq!(second.size(), (60, 20));
    }

    #[test]
    fn detaching_exclusive_target_restores_remaining_clients() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let other = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 30).unwrap();
        mux.resize_surface_for_client(other.id, 2, 80, 30).unwrap();

        assert_eq!(mux.use_only_client_size(1), Some(true));
        assert_eq!(surface.size(), (120, 40));
        mux.resize_surface_for_client(other.id, 2, 60, 20).unwrap();
        assert_eq!(other.size(), (80, 30));
        mux.remove_size_client(1);

        assert_eq!(surface.size(), (80, 30));
        assert_eq!(other.size(), (60, 20));
        assert!(mux.client_size_participates(2));
        assert_eq!(mux.use_only_client_size(99), None);
    }

    #[test]
    fn client_sizes_clamp_to_tmux_window_bounds() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 0, u16::MAX).unwrap();

        assert_eq!(mux.client_surface_size(surface.id, 1), Some((1, 10_000)));
        assert_eq!(surface.size(), (1, 10_000));
    }

    #[test]
    fn in_process_tui_is_listed_as_local_client_zero() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 0, 100, 30).unwrap();

        let clients = mux.control_clients_json(0);
        assert_eq!(clients[0]["client"], 0);
        assert_eq!(clients[0]["transport"], "local");
        assert_eq!(clients[0]["self"], true);
        assert_eq!(clients[0]["sizes"][0]["cols"], 100);
        assert_eq!(clients[0]["sizes"][0]["rows"], 30);
    }

    #[test]
    fn concurrent_viewer_reports_settle_at_shared_minimum() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let surface_id = surface.id;
        let pause_first = Arc::new(AtomicBool::new(true));
        let (reached_tx, reached_rx) = std::sync::mpsc::sync_channel(1);
        let release = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let hook_release = release.clone();
        mux.set_client_resize_before_apply(Some(Arc::new(move || {
            if pause_first.swap(false, Ordering::SeqCst) {
                reached_tx.send(()).unwrap();
                let (lock, ready) = &*hook_release;
                let mut released = lock.lock().unwrap();
                while !*released {
                    released = ready.wait(released).unwrap();
                }
            }
        })));

        let first_mux = mux.clone();
        let first = std::thread::spawn(move || {
            first_mux.resize_surface_for_client(surface_id, 1, 120, 40).unwrap();
        });
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let second_mux = mux.clone();
        let (second_done_tx, second_done_rx) = std::sync::mpsc::sync_channel(1);
        let second = std::thread::spawn(move || {
            second_mux.resize_surface_for_client(surface_id, 2, 80, 50).unwrap();
            second_done_tx.send(()).unwrap();
        });
        let second_finished_before_release =
            second_done_rx.recv_timeout(Duration::from_millis(250)).is_ok();

        let (lock, ready) = &*release;
        *lock.lock().unwrap() = true;
        ready.notify_all();
        first.join().unwrap();
        if !second_finished_before_release {
            second_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        second.join().unwrap();

        assert_eq!(mux.surface(surface_id).unwrap().size(), (80, 40));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (80, 40));
    }

    #[test]
    fn concurrent_viewer_removal_and_report_settle_at_shared_minimum() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let surface_id = surface.id;
        mux.resize_surface_for_client(surface_id, 1, 80, 40).unwrap();
        mux.resize_surface_for_client(surface_id, 2, 120, 50).unwrap();

        let pause_first = Arc::new(AtomicBool::new(true));
        let (reached_tx, reached_rx) = std::sync::mpsc::sync_channel(1);
        let release = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let hook_release = release.clone();
        mux.set_client_resize_before_apply(Some(Arc::new(move || {
            if pause_first.swap(false, Ordering::SeqCst) {
                reached_tx.send(()).unwrap();
                let (lock, ready) = &*hook_release;
                let mut released = lock.lock().unwrap();
                while !*released {
                    released = ready.wait(released).unwrap();
                }
            }
        })));

        let remove_mux = mux.clone();
        let remove = std::thread::spawn(move || {
            remove_mux.remove_surface_size_client(surface_id, 1);
        });
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let report_mux = mux.clone();
        let (report_done_tx, report_done_rx) = std::sync::mpsc::sync_channel(1);
        let report = std::thread::spawn(move || {
            report_mux.resize_surface_for_client(surface_id, 2, 90, 45).unwrap();
            report_done_tx.send(()).unwrap();
        });
        let report_finished_before_release =
            report_done_rx.recv_timeout(Duration::from_millis(250)).is_ok();

        let (lock, ready) = &*release;
        *lock.lock().unwrap() = true;
        ready.notify_all();
        remove.join().unwrap();
        if !report_finished_before_release {
            report_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        report.join().unwrap();

        assert_eq!(mux.surface(surface_id).unwrap().size(), (90, 45));
    }

    #[test]
    fn terminal_lease_migration_cannot_overtake_a_legacy_resize_already_in_flight() {
        use crate::terminal_authority::{
            PresentationAuthority, TerminalControlMode, TerminalLeaseClaim,
        };

        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let surface_id = surface.id;
        let surface_uuid = surface.uuid;
        mux.resize_surface_for_client(surface_id, 1, 80, 24).unwrap();
        mux.resize_surface_for_client(surface_id, 2, 120, 50).unwrap();

        let (reached_tx, reached_rx) = std::sync::mpsc::sync_channel(1);
        let release = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let hook_release = release.clone();
        mux.set_client_resize_before_apply(Some(Arc::new(move || {
            reached_tx.send(()).unwrap();
            let (lock, ready) = &*hook_release;
            let mut released = lock.lock().unwrap();
            while !*released {
                released = ready.wait(released).unwrap();
            }
        })));

        let remove_mux = mux.clone();
        let remove = std::thread::spawn(move || {
            remove_mux.remove_surface_size_client(surface_id, 1);
        });
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let presentation_id = crate::PresentationId::new();
        let claim = TerminalLeaseClaim {
            connection: 7,
            client_uuid: uuid::Uuid::new_v4(),
            process_instance_uuid: uuid::Uuid::new_v4(),
            presentation_id,
            presentation_generation: 1,
        };
        mux.terminal_authority
            .mark_presentation_visible(PresentationAuthority {
                connection: claim.connection,
                presentation_id,
                presentation_generation: claim.presentation_generation,
                surface_uuid,
            })
            .unwrap();

        let acquire_mux = mux.clone();
        let (acquired_tx, acquired_rx) = std::sync::mpsc::sync_channel(1);
        let acquire = std::thread::spawn(move || {
            let lease = acquire_mux
                .acquire_terminal_lease(surface_id, TerminalLeaseKind::Input, claim, 5_000)
                .unwrap();
            acquired_tx.send(lease).unwrap();
        });

        assert!(acquired_rx.recv_timeout(Duration::from_millis(250)).is_err());
        assert_eq!(mux.terminal_authority.mode(surface_uuid), TerminalControlMode::LegacyShared);

        let (lock, ready) = &*release;
        *lock.lock().unwrap() = true;
        ready.notify_all();
        remove.join().unwrap();
        let lease = acquired_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        acquire.join().unwrap();

        assert!(lease.migrated_from_legacy);
        assert_eq!(mux.terminal_authority.mode(surface_uuid), TerminalControlMode::Leased);
        assert_eq!(mux.client_surface_size(surface_id, 2), None);
        let surface = mux.surface(surface_id).unwrap();
        let legacy = mux.with_legacy_terminal_control(&surface, || Ok(()));
        assert!(legacy.unwrap_err().to_string().contains("protocol-v9 leased control"));
    }

    #[test]
    fn canonical_terminal_close_waits_for_an_accepted_v9_operation_fence() {
        use crate::terminal_authority::{PresentationAuthority, TerminalLeaseClaim};

        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let surface_id = surface.id;
        let presentation_id = crate::PresentationId::new();
        let claim = TerminalLeaseClaim {
            connection: 7,
            client_uuid: uuid::Uuid::new_v4(),
            process_instance_uuid: uuid::Uuid::new_v4(),
            presentation_id,
            presentation_generation: 1,
        };
        mux.terminal_authority
            .mark_presentation_visible(PresentationAuthority {
                connection: claim.connection,
                presentation_id,
                presentation_generation: claim.presentation_generation,
                surface_uuid: surface.uuid,
            })
            .unwrap();
        mux.acquire_terminal_lease(surface_id, TerminalLeaseKind::Input, claim, 5_000).unwrap();

        let operation = mux.read_terminal_control_lifecycle();
        let close_mux = mux.clone();
        let (closed_tx, closed_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn(move || {
            close_mux.close_surface(surface_id);
            closed_tx.send(()).unwrap();
        });

        assert!(closed_rx.recv_timeout(Duration::from_millis(250)).is_err());
        assert!(mux.surface(surface_id).is_some());
        drop(operation);

        closed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        close.join().unwrap();
        assert!(mux.surface(surface_id).is_none());
        assert_eq!(
            mux.terminal_authority.mode(surface.uuid),
            crate::terminal_authority::TerminalControlMode::LegacyShared,
            "terminal authority state is retired with canonical closure"
        );
    }

    #[test]
    fn randomized_multi_surface_sizing_settles_to_the_model() {
        let mux = test_mux();
        let surfaces =
            (0..3).map(|_| mux.new_workspace(None, Some((80, 24))).unwrap()).collect::<Vec<_>>();
        let mut reports = HashMap::<(SurfaceId, u64), (u16, u16)>::new();
        let mut excluded = HashSet::<u64>::new();
        let mut exclusive = None;
        let mut expected =
            surfaces.iter().map(|surface| (surface.id, surface.size())).collect::<HashMap<_, _>>();
        let mut random = 0x5eed_u64;
        let next = |state: &mut u64| {
            *state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
            *state
        };

        for step in 0..1_000 {
            let surface = surfaces[(next(&mut random) as usize) % surfaces.len()].id;
            let client = next(&mut random) % 6 + 1;
            match next(&mut random) % 5 {
                0 | 1 => {
                    let size =
                        ((next(&mut random) % 180 + 1) as u16, (next(&mut random) % 70 + 1) as u16);
                    if exclusive.is_some_and(|target| target != client) {
                        excluded.insert(client);
                    }
                    reports.insert((surface, client), size);
                    mux.resize_surface_for_client(surface, client, size.0, size.1).unwrap();
                }
                2 => {
                    reports.remove(&(surface, client));
                    mux.remove_surface_size_client(surface, client);
                }
                3 => {
                    if reports.keys().any(|(_, reporter)| *reporter == client) {
                        let participates = excluded.contains(&client);
                        if participates {
                            excluded.remove(&client);
                        } else {
                            excluded.insert(client);
                        }
                        assert!(mux.set_client_size_participation(client, participates).is_some());
                        exclusive = None;
                    }
                }
                _ => {
                    let known = reports.keys().any(|(_, reporter)| *reporter == client);
                    if known && step % 2 == 0 {
                        let known_clients =
                            reports.keys().map(|(_, reporter)| *reporter).collect::<HashSet<_>>();
                        excluded = known_clients
                            .into_iter()
                            .filter(|known_client| *known_client != client)
                            .collect();
                        exclusive = Some(client);
                        assert!(mux.use_only_client_size(client).is_some());
                    } else {
                        reports.retain(|(_, reporter), _| *reporter != client);
                        if exclusive == Some(client) {
                            exclusive = None;
                            excluded.clear();
                        } else {
                            excluded.remove(&client);
                        }
                        mux.remove_size_client(client);
                    }
                }
            }

            let use_excluded = !reports.keys().any(|(_, reporter)| !excluded.contains(reporter));
            for candidate in &surfaces {
                let effective = reports
                    .iter()
                    .filter(|((reported_surface, reporter), _)| {
                        *reported_surface == candidate.id
                            && (use_excluded || !excluded.contains(reporter))
                    })
                    .map(|(_, size)| *size)
                    .reduce(|smallest, size| (smallest.0.min(size.0), smallest.1.min(size.1)));
                if let Some(size) = effective {
                    expected.insert(candidate.id, size);
                }
                assert_eq!(
                    candidate.size(),
                    expected[&candidate.id],
                    "step {step}, surface {}, reports={reports:?}, excluded={excluded:?}",
                    candidate.id,
                );
            }
        }
    }

    #[test]
    fn agent_reports_apply_hook_authority() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let socket = mux.report_agent(
            surface.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("socket-session".to_string()),
        );
        assert_eq!(socket.state, AgentState::Working);
        assert_eq!(socket.source, AgentSource::Socket);

        let hook = mux.report_agent(
            surface.id,
            AgentState::Blocked,
            AgentSource::Hook,
            Some("hook-session".to_string()),
        );
        assert_eq!(hook.state, AgentState::Blocked);
        assert_eq!(hook.source, AgentSource::Hook);

        let ignored_socket = mux.report_agent(
            surface.id,
            AgentState::Done,
            AgentSource::Socket,
            Some("late-socket".to_string()),
        );
        assert_eq!(ignored_socket.state, AgentState::Blocked);
        assert_eq!(ignored_socket.source, AgentSource::Hook);

        let filtered = mux.list_agents(Some(surface.id), Some(AgentState::Blocked));
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].session.as_deref(), Some("hook-session"));
        assert!(mux.list_agents(Some(surface.id), Some(AgentState::Done)).is_empty());
    }

    #[test]
    fn closing_a_surface_purges_agent_and_notification_side_tables() {
        let mux = test_mux();
        let reader = uuid::Uuid::new_v4();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        // A second tab keeps the workspace alive after `first` closes, so we
        // exercise the per-surface purge rather than a full teardown.
        let second = mux.new_tab(Some(pane), None, None).unwrap();

        mux.report_agent(
            first.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("conf".to_string()),
        );
        mux.post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Warning,
            Some(first.id),
        )
        .unwrap();
        assert_eq!(mux.list_agents(Some(first.id), None).len(), 1);
        assert!(mux.surface_notification(first.id).is_some());
        let activity = mux.terminal_activity_snapshot(reader).unwrap();
        let fact = *activity.facts.iter().find(|fact| fact.surface_uuid == first.uuid).unwrap();
        mux.mark_terminal_seen(reader, first.uuid, fact.sequence).unwrap();

        mux.close_surface(first.id);

        // The dead surface must not linger in either side table.
        assert!(mux.list_agents(Some(first.id), None).is_empty());
        assert!(mux.list_agents(None, None).is_empty());
        assert!(mux.surface_notification(first.id).is_none());
        let activity = mux.terminal_activity_snapshot(reader).unwrap();
        assert_eq!(activity.latest_sequence, fact.sequence);
        assert!(activity.facts.iter().all(|candidate| candidate.surface_uuid != first.uuid));
        assert!(activity.receipts.iter().all(|candidate| candidate.surface_uuid != first.uuid));
        assert!(mux.with_state(|state| state.surfaces.contains_key(&second.id)));
    }

    #[test]
    fn failed_browser_surface_attach_kills_worker() {
        let mux = test_mux();
        let topology_revision = mux.topology_revision();
        let opts = mux.surface_options.lock().unwrap().clone();
        let surface = browser::new_surface(
            999,
            "https://example.test".to_string(),
            (10, 5),
            (8, 16),
            &opts,
            Arc::downgrade(&mux),
        );
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();

        assert!(matches!(
            mux.attach_browser_surface_to_pane_or_kill(123_456, &surface, 1),
            BrowserSurfaceAttach::MissingPane
        ));
        assert!(browser.is_dead());
        done.recv_timeout(Duration::from_secs(1))
            .expect("browser worker exited after failed attach");
        assert_eq!(mux.topology_revision(), topology_revision);
    }

    #[test]
    fn notification_sets_unread_and_clears_when_tab_is_viewed() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, None).unwrap();
        let notification = mux
            .post_notification(
                "Build".to_string(),
                "ok".to_string(),
                NotificationLevel::Warning,
                Some(first.id),
            )
            .unwrap();

        let state = mux.surface_notification(first.id).unwrap();
        assert_eq!(state.notification, notification);
        assert_eq!(state.level, NotificationLevel::Warning);
        assert!(state.unread);

        mux.select_tab(Some(pane), Some(1), None);
        assert!(mux.surface_notification(first.id).is_some());
        mux.select_tab(Some(pane), Some(0), None);
        assert!(mux.surface_notification(first.id).is_none());
        assert!(mux.surface_notification(second.id).is_none());
    }

    #[test]
    fn notification_to_active_surface_does_not_set_unread() {
        let mux = test_mux();
        let events = mux.subscribe();
        let stable_reader = uuid::Uuid::new_v4();
        let surface = mux.new_workspace(None, None).unwrap();
        assert_eq!(mux.active_surface(), Some(surface.id));

        let notification = mux
            .post_notification(
                "Build".to_string(),
                "ok".to_string(),
                NotificationLevel::Info,
                Some(surface.id),
            )
            .unwrap();

        assert!(mux.surface_notification(surface.id).is_none());
        assert!(mux.terminal_activity_snapshot(stable_reader).unwrap().is_unread(surface.uuid));
        assert!(events.try_iter().any(|event| {
            matches!(
                event,
                MuxEvent::Notification(note)
                    if note.notification == notification && note.surface == Some(surface.id)
            )
        }));
    }

    #[test]
    fn terminal_activity_receipts_are_per_reader_idempotent_and_future_safe() {
        let mux = test_mux();
        let activity_events = mux.subscribe_terminal_activity();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.new_tab(Some(pane), None, None).unwrap();
        let reader_a = uuid::Uuid::new_v4();
        let reader_b = uuid::Uuid::new_v4();

        mux.post_notification(
            "Build".to_string(),
            "private output".to_string(),
            NotificationLevel::Warning,
            Some(first.id),
        )
        .unwrap();
        let first_fact = mux
            .terminal_activity_snapshot(reader_a)
            .unwrap()
            .facts
            .into_iter()
            .find(|fact| fact.surface_uuid == first.uuid)
            .unwrap();
        assert!(mux.terminal_activity_snapshot(reader_a).unwrap().is_unread(first.uuid));
        assert!(mux.terminal_activity_snapshot(reader_b).unwrap().is_unread(first.uuid));
        assert!(matches!(
            activity_events.recv().unwrap(),
            MuxEvent::TerminalActivity(fact) if fact == first_fact
        ));

        let receipt = mux.mark_terminal_seen(reader_a, first.uuid, first_fact.sequence).unwrap();
        assert!(!mux.terminal_activity_snapshot(reader_a).unwrap().is_unread(first.uuid));
        assert!(mux.terminal_activity_snapshot(reader_b).unwrap().is_unread(first.uuid));
        assert!(matches!(
            activity_events.recv().unwrap(),
            MuxEvent::TerminalActivityReceipt(event) if event == receipt
        ));
        assert_eq!(
            mux.mark_terminal_seen(reader_a, first.uuid, first_fact.sequence).unwrap(),
            receipt
        );
        assert!(activity_events.try_iter().next().is_none());
        assert!(mux.mark_terminal_seen(reader_a, first.uuid, first_fact.sequence + 1).is_err());

        mux.post_notification(
            "Build again".to_string(),
            "new private output".to_string(),
            NotificationLevel::Error,
            Some(first.id),
        )
        .unwrap();
        let second_fact = mux
            .terminal_activity_snapshot(reader_a)
            .unwrap()
            .facts
            .into_iter()
            .find(|fact| fact.surface_uuid == first.uuid)
            .unwrap();
        assert_eq!(second_fact.sequence, first_fact.sequence + 1);
        assert!(mux.terminal_activity_snapshot(reader_a).unwrap().is_unread(first.uuid));
        assert!(mux.terminal_activity_snapshot(reader_b).unwrap().is_unread(first.uuid));
    }

    fn seed_split_ratio_tree(mux: &Mux) -> (PaneId, PaneId, PaneId) {
        let (p1, p2, p3) = (1, 2, 3);
        let mut state = mux.state.lock().unwrap();
        state.value = State {
            workspaces: vec![Workspace {
                id: 1,
                uuid: WorkspaceUuid::new(),
                name: "1".into(),
                screens: vec![Screen {
                    id: 1,
                    uuid: ScreenUuid::new(),
                    name: None,
                    root: Node::Split {
                        dir: SplitDir::Right,
                        ratio: 0.5,
                        a: Box::new(Node::Split {
                            dir: SplitDir::Right,
                            ratio: 0.5,
                            a: Box::new(Node::Leaf(p1)),
                            b: Box::new(Node::Leaf(p3)),
                        }),
                        b: Box::new(Node::Leaf(p2)),
                    },
                    active_pane: p3,
                    zoomed_pane: None,
                }],
                active_screen: 0,
            }],
            active_workspace: 0,
            panes: HashMap::from([
                (
                    p1,
                    Pane {
                        id: p1,
                        uuid: PaneUuid::new(),
                        name: None,
                        tabs: Vec::new(),
                        active_tab: 0,
                        active_at: 1,
                    },
                ),
                (
                    p2,
                    Pane {
                        id: p2,
                        uuid: PaneUuid::new(),
                        name: None,
                        tabs: Vec::new(),
                        active_tab: 0,
                        active_at: 2,
                    },
                ),
                (
                    p3,
                    Pane {
                        id: p3,
                        uuid: PaneUuid::new(),
                        name: None,
                        tabs: Vec::new(),
                        active_tab: 0,
                        active_at: 3,
                    },
                ),
            ]),
            surfaces: HashMap::new(),
        };
        state.rebuild_topology_index().unwrap();
        (p1, p2, p3)
    }

    fn leaf_spec() -> LayoutSpec {
        LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: None })
    }

    fn split_spec(dir: SplitDir, ratio: f32, a: LayoutSpec, b: LayoutSpec) -> LayoutSpec {
        LayoutSpec::Split { dir, ratio, a: Box::new(a), b: Box::new(b) }
    }

    fn node_shape(node: &Node) -> String {
        match node {
            Node::Leaf(_) => "leaf".to_string(),
            Node::Split { dir, ratio, a, b } => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                format!("{dir}:{ratio:.2}({}, {})", node_shape(a), node_shape(b))
            }
        }
    }

    fn spec_shape(spec: &LayoutSpec) -> String {
        match spec {
            LayoutSpec::Leaf(_) => "leaf".to_string(),
            LayoutSpec::Split { dir, ratio, a, b } => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                format!(
                    "{dir}:{:.2}({}, {})",
                    clamp_split_ratio(*ratio),
                    spec_shape(a),
                    spec_shape(b)
                )
            }
        }
    }

    fn leaf_order(node: &Node) -> Vec<PaneId> {
        let mut ids = Vec::new();
        node.pane_ids(&mut ids);
        ids
    }

    fn screen_root(mux: &Mux, screen: ScreenId) -> Node {
        mux.with_state(|s| {
            s.workspaces
                .iter()
                .flat_map(|ws| ws.screens.iter())
                .find(|candidate| candidate.id == screen)
                .unwrap()
                .root
                .clone()
        })
    }

    #[test]
    fn apply_layout_round_trip_reproduces_tree_shape_and_ratios() {
        let mux = test_mux();
        let spec = split_spec(
            SplitDir::Right,
            0.33,
            leaf_spec(),
            split_spec(SplitDir::Down, 0.67, leaf_spec(), leaf_spec()),
        );
        let first = mux.apply_layout(None, Some("round-trip".into()), &spec, None).unwrap();
        assert_eq!(mux.topology_revision(), 1);
        let exported_shape = node_shape(&screen_root(&mux, first.screen));

        let round_trip_spec = mux.with_state(|s| {
            fn from_node(node: &Node) -> LayoutSpec {
                match node {
                    Node::Leaf(_) => leaf_spec(),
                    Node::Split { dir, ratio, a, b } => {
                        split_spec(*dir, *ratio, from_node(a), from_node(b))
                    }
                }
            }
            from_node(&s.workspaces[0].screens[0].root)
        });
        let second =
            mux.apply_layout(None, Some("round-trip-2".into()), &round_trip_spec, None).unwrap();
        assert_eq!(mux.topology_revision(), 2);
        let applied_shape = node_shape(&screen_root(&mux, second.screen));

        assert_eq!(exported_shape, spec_shape(&spec));
        assert_eq!(applied_shape, exported_shape);
        assert_eq!(first.panes.len(), 3);
        assert_eq!(second.panes.len(), 3);
    }

    #[test]
    fn pane_neighbor_returns_directional_adjacency() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(
                    SplitDir::Right,
                    0.5,
                    leaf_spec(),
                    split_spec(SplitDir::Down, 0.5, leaf_spec(), leaf_spec()),
                ),
                None,
            )
            .unwrap();
        let p1 = applied.panes[0].pane;
        let p2 = applied.panes[1].pane;
        let p3 = applied.panes[2].pane;

        assert_eq!(mux.pane_neighbor(p1, Direction::Right).unwrap(), Some(p2));
        assert_eq!(mux.pane_neighbor(p2, Direction::Down).unwrap(), Some(p3));
        assert_eq!(mux.pane_neighbor(p1, Direction::Left).unwrap(), None);
    }

    #[test]
    fn focus_direction_moves_active_pane() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()),
                None,
            )
            .unwrap();
        let p1 = applied.panes[0].pane;
        let p2 = applied.panes[1].pane;
        assert!(mux.focus_pane(p1));

        assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), p2);
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].active_pane, p2));
        assert!(mux.focus_direction(None, Direction::Right).is_err());
    }

    #[test]
    fn swap_pane_exchanges_leaf_positions_and_preserves_surfaces() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()),
                None,
            )
            .unwrap();
        let p1 = applied.panes[0].pane;
        let s1 = applied.panes[0].surface;
        let p2 = applied.panes[1].pane;
        let s2 = applied.panes[1].surface;
        assert_eq!(leaf_order(&screen_root(&mux, applied.screen)), vec![p1, p2]);

        assert!(mux.swap_panes(p1, p2));
        assert_eq!(leaf_order(&screen_root(&mux, applied.screen)), vec![p2, p1]);
        mux.with_state(|s| {
            assert_eq!(s.panes[&p1].tabs, vec![s1]);
            assert_eq!(s.panes[&p2].tabs, vec![s2]);
        });
    }

    #[test]
    fn zoom_pane_toggles_screen_zoom_state() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()),
                None,
            )
            .unwrap();
        let p2 = applied.panes[1].pane;

        let zoomed = mux.zoom_pane(Some(p2), ZoomMode::Toggle).unwrap();
        assert_eq!(zoomed.zoomed_pane, Some(p2));
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].zoomed_pane, Some(p2)));

        let restored = mux.zoom_pane(Some(p2), ZoomMode::Toggle).unwrap();
        assert_eq!(restored.zoomed_pane, None);
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].zoomed_pane, None));
    }

    #[test]
    fn process_info_metadata_is_recorded_for_spawned_surface() {
        let mux = test_mux();
        let cwd = std::env::temp_dir().to_string_lossy().into_owned();
        let applied = mux
            .apply_layout(
                None,
                None,
                &LayoutSpec::Leaf(LayoutLeafSpec {
                    cwd: Some(cwd.clone()),
                    command: Some(vec!["echo".into(), "ok".into()]),
                }),
                None,
            )
            .unwrap();
        let surface = mux.surface(applied.panes[0].surface).unwrap();

        assert_eq!(surface.process_id(), Some(surface.id as u32));
        assert_eq!(surface.spawn_command().as_deref(), Some("echo ok"));
        assert_eq!(surface.spawn_argv(), Some(vec!["echo".into(), "ok".into()]));
        assert_eq!(
            surface.tty_name().as_deref(),
            Some(std::path::Path::new(&format!("/dev/ttys{}", surface.id)))
        );
        assert_eq!(surface.spawn_cwd().as_deref(), Some(cwd.as_str()));
    }

    #[test]
    fn default_color_changes_invalidate_renderer_config_once_per_revision() {
        let mux = test_mux();
        let events = mux.subscribe();
        let colors = DefaultColors {
            fg: Some(Rgb { r: 0x11, g: 0x22, b: 0x33 }),
            bg: Some(Rgb { r: 0x44, g: 0x55, b: 0x66 }),
            ..DefaultColors::default()
        };

        mux.set_default_colors(colors);
        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::RendererConfigInvalidated {
                revision: 1,
                reason,
                default_colors,
            } if reason.as_ref() == "default-colors-changed" && default_colors == colors
        ));
        assert_eq!(mux.default_colors_snapshot(), (1, colors));

        mux.set_default_colors(colors);
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));

        let next = DefaultColors { cursor_blink: Some(false), ..colors };
        mux.set_default_colors(next);
        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::RendererConfigInvalidated { revision: 2, default_colors, .. }
                if default_colors == next
        ));
        assert_eq!(mux.default_colors_snapshot(), (2, next));
    }

    #[test]
    fn split_and_close_collapses_tree() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p2, p3]);
        });

        mux.close_pane(p2);
        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p3]);
        });

        mux.close_pane(p1);
        mux.close_pane(p3);
        assert_eq!(mux.surface_count(), 0);
        mux.with_state(|s| assert!(s.workspaces.is_empty()));
    }

    #[test]
    fn structural_test_mux_can_create_many_surfaces_without_ptys() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((120, 40))).unwrap();
        let pane = mux.with_state(|s| s.pane_of(first.id).unwrap());

        for _ in 0..450 {
            mux.new_tab(Some(pane), None, None).unwrap();
        }

        assert_eq!(mux.surface_count(), 451);
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs.len(), 451);
            for surface in pane.tabs.iter().filter_map(|id| s.surfaces.get(id)) {
                assert_eq!(surface.kind(), crate::surface::SurfaceKind::Pty);
                assert_eq!(surface.size(), (120, 40));
                assert!(!surface.is_dead());
            }
        });
    }

    #[test]
    fn closing_active_pane_focuses_most_recent_remaining_pane() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

        assert!(mux.focus_pane(p1));
        assert!(mux.focus_pane(p3));
        mux.close_pane(p3);

        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].screens[0].active_pane, p1);
            assert!(s.panes.contains_key(&p2));
        });
    }

    #[test]
    fn tabs_within_pane() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();

        mux.with_state(|s| {
            let p = &s.panes[&pane];
            assert_eq!(p.tabs, vec![s1.id, s2.id]);
            assert_eq!(p.active_tab, 1);
        });

        // Closing the active tab activates the previous one; the pane stays.
        mux.close_surface(s2.id);
        mux.with_state(|s| {
            let p = &s.panes[&pane];
            assert_eq!(p.tabs, vec![s1.id]);
            assert_eq!(p.active_tab, 0);
            assert_eq!(s.workspaces.len(), 1);
        });

        // Closing the last tab collapses the pane, screen, and workspace.
        mux.close_surface(s1.id);
        mux.with_state(|s| assert!(s.workspaces.is_empty()));
    }

    #[test]
    fn move_tab_within_pane_clamps_and_tracks_active_tab() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();
        let s3 = mux.new_tab(Some(pane), None, None).unwrap();

        assert!(mux.move_tab(s3.id, pane, 0));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s3.id, s1.id, s2.id]);
            assert_eq!(pane.active_tab, 0);
        });

        assert!(mux.move_tab(s3.id, pane, 99));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s1.id, s2.id, s3.id]);
            assert_eq!(pane.active_tab, 2);
        });
    }

    #[test]
    fn move_tab_same_position_preserves_active_tab_and_emits_no_event() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();
        let s3 = mux.new_tab(Some(pane), None, None).unwrap();
        mux.select_tab(Some(pane), Some(0), None);
        let events = mux.subscribe();

        assert!(!mux.move_tab(s2.id, pane, 1));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s1.id, s2.id, s3.id]);
            assert_eq!(pane.active_tab, 0);
        });
        assert!(events.try_iter().all(|event| !matches!(event, MuxEvent::TreeChanged)));
    }

    #[test]
    fn move_tab_across_panes_collapses_empty_source_and_preserves_surface() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let original_count = mux.surface_count();

        assert!(mux.move_tab(s1.id, p2, 0));
        mux.with_state(|s| {
            assert!(!s.panes.contains_key(&p1));
            let target = &s.panes[&p2];
            assert_eq!(target.tabs, vec![s1.id, s2.id]);
            assert_eq!(target.active_tab, 0);
            assert!(s.surfaces.contains_key(&s1.id));
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p2]);
        });
        assert_eq!(mux.surface_count(), original_count);
    }

    #[test]
    fn set_ratio_updates_deepest_split_and_clamps() {
        let mux = test_mux();
        let (p1, p2, p3) = seed_split_ratio_tree(&mux);

        assert!(mux.set_ratio(p1, SplitDir::Right, 0.8));
        mux.with_state(|s| {
            let root = &s.workspaces[0].screens[0].root;
            let Node::Split { ratio: root_ratio, a, .. } = root else {
                panic!("root should be split");
            };
            assert_eq!(*root_ratio, 0.5);
            let Node::Split { ratio: inner_ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*inner_ratio, 0.8);
        });

        assert!(mux.set_ratio(p2, SplitDir::Right, -1.0));
        mux.with_state(|s| {
            let Node::Split { ratio, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            assert_eq!(*ratio, 0.05);
        });

        assert!(mux.set_ratio(p3, SplitDir::Right, 2.0));
        mux.with_state(|s| {
            let Node::Split { a, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            let Node::Split { ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*ratio, 0.95);
        });

        assert!(!mux.set_ratio(9999, SplitDir::Right, 0.4));
    }

    #[test]
    fn screens_within_workspace() {
        let mux = test_mux();
        mux.new_workspace(None, None).unwrap();
        let s2 = mux.new_screen(None, None).unwrap();

        let (screen1, screen2) = mux.with_state(|s| {
            let ws = &s.workspaces[0];
            assert_eq!(ws.screens.len(), 2);
            assert_eq!(ws.active_screen, 1);
            (ws.screens[0].id, ws.screens[1].id)
        });

        // Select back to screen 1; screen 2 keeps running.
        mux.select_screen(Some(0), None);
        mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 0));

        // Renaming a screen sticks; clearing falls back.
        assert!(mux.rename_screen(screen2, "logs".into()));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].screens[1].name.as_deref(), Some("logs"));
        });

        // Focusing a pane in screen 2 activates that screen.
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        assert!(mux.focus_pane(p2));
        mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 1));

        // Closing screen 2 keeps the workspace with screen 1.
        assert!(mux.close_screen(screen2));
        mux.with_state(|s| {
            let ws = &s.workspaces[0];
            assert_eq!(ws.screens.len(), 1);
            assert_eq!(ws.screens[0].id, screen1);
            assert_eq!(ws.active_screen, 0);
        });
    }

    #[test]
    fn workspaces_and_renames() {
        let mux = test_mux();
        let events = mux.subscribe();
        mux.new_workspace(None, None).unwrap();
        mux.new_workspace(Some("dev".into()), None).unwrap();

        let (ws0, ws1, pane1, surface1) = mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 2);
            assert_eq!(s.workspaces[1].name, "dev");
            assert_eq!(s.active_workspace, 1);
            let pane = s.workspaces[1].screens[0].active_pane;
            let surface = s.panes[&pane].tabs[0];
            (s.workspaces[0].id, s.workspaces[1].id, pane, surface)
        });

        assert!(mux.rename_workspace(ws0, "ops".into()));
        assert!(mux.rename_pane(pane1, "logs".into()));
        assert!(mux.rename_surface(surface1, "api".into()));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].name, "ops");
            assert_eq!(s.panes[&pane1].name.as_deref(), Some("logs"));
            assert_eq!(s.surfaces[&surface1].name().as_deref(), Some("api"));
        });
        // Clearing the names falls back to the generated labels.
        assert!(mux.rename_pane(pane1, String::new()));
        assert!(mux.rename_surface(surface1, String::new()));
        mux.with_state(|s| {
            assert_eq!(s.panes[&pane1].name, None);
            assert_eq!(s.surfaces[&surface1].name(), None);
        });

        assert!(mux.close_workspace(ws1));
        mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 1);
            assert_eq!(s.workspaces[0].id, ws0);
            assert_eq!(s.active_workspace, 0);
        });
        assert!(events.try_iter().count() > 0);
    }

    #[test]
    fn move_workspace_reorders_and_tracks_active_workspace() {
        let mux = test_mux();
        mux.new_workspace(Some("one".into()), None).unwrap();
        mux.new_workspace(Some("two".into()), None).unwrap();
        mux.new_workspace(Some("three".into()), None).unwrap();
        let (ws1, ws2, ws3) =
            mux.with_state(|s| (s.workspaces[0].id, s.workspaces[1].id, s.workspaces[2].id));

        assert!(mux.move_workspace(ws3, 0));
        mux.with_state(|s| {
            assert_eq!(
                s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(),
                vec![ws3, ws1, ws2]
            );
            assert_eq!(s.active_workspace, 0);
        });

        assert!(mux.move_workspace(ws1, 99));
        mux.with_state(|s| {
            assert_eq!(
                s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(),
                vec![ws3, ws2, ws1]
            );
            assert_eq!(s.active_workspace, 0);
        });
    }

    #[test]
    fn concurrent_topology_snapshots_pair_each_tree_with_its_committed_revision() {
        use std::sync::Barrier;
        use std::sync::atomic::{AtomicBool, Ordering};

        let mux = test_mux();
        let start = Arc::new(Barrier::new(2));
        let finished = Arc::new(AtomicBool::new(false));
        let writer_mux = mux.clone();
        let writer_start = start.clone();
        let writer_finished = finished.clone();
        let writer = std::thread::spawn(move || {
            writer_start.wait();
            for index in 0..128 {
                writer_mux.new_workspace(Some(format!("workspace-{index}")), None).unwrap();
                std::thread::yield_now();
            }
            writer_finished.store(true, Ordering::Release);
        });

        start.wait();
        let mut observed = 0;
        while !finished.load(Ordering::Acquire) {
            let snapshot = mux.with_state_snapshot(|state| state.workspaces.len());
            assert_eq!(snapshot.topology_revision as usize, snapshot.state);
            observed += 1;
            std::thread::yield_now();
        }
        writer.join().unwrap();
        let final_snapshot = mux.with_state_snapshot(|state| state.workspaces.len());
        assert_eq!(final_snapshot.topology_revision, 128);
        assert_eq!(final_snapshot.state, 128);
        assert!(observed > 0);
    }

    #[test]
    fn legacy_and_canonical_revisions_preserve_their_distinct_contracts() {
        let mux = test_mux();
        assert_eq!(mux.topology_revision(), 0);
        assert_eq!(mux.canonical_topology_revision(), 0);

        mux.new_workspace(Some("one".to_string()), None).unwrap();
        assert_eq!(mux.topology_revision(), 1);
        assert_eq!(mux.canonical_topology_revision(), 1);
        let workspace = mux.with_state(|state| state.workspaces[0].id);

        assert!(mux.rename_workspace(workspace, "renamed".to_string()));
        assert_eq!(mux.topology_revision(), 2);
        assert_eq!(mux.canonical_topology_revision(), 2);
        let subscription = topology_subscription(&mux, 2);
        assert!(mux.rename_workspace(workspace, "renamed".to_string()));
        assert!(!mux.move_workspace(workspace, 0));
        assert_eq!(mux.topology_revision(), 3);
        assert_eq!(mux.canonical_topology_revision(), 2);
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn canonical_no_ops_and_failed_targets_emit_no_delta() {
        let mux = test_mux();
        let surface = mux.new_workspace(Some("one".into()), None).unwrap();
        let (workspace, screen, pane) = mux.with_state(|state| {
            let workspace = &state.workspaces[0];
            let screen = &workspace.screens[0];
            (workspace.id, screen.id, screen.active_pane)
        });
        let revision = mux.canonical_topology_revision();
        let subscription = topology_subscription(&mux, revision);

        assert!(mux.rename_workspace(workspace, "one".into()));
        assert!(mux.rename_screen(screen, String::new()));
        assert!(mux.rename_pane(pane, String::new()));
        assert!(mux.rename_surface(surface.id, String::new()));
        assert!(mux.focus_pane(pane));
        assert!(!mux.set_ratio(pane, SplitDir::Right, 0.5));
        assert!(!mux.swap_panes(pane, pane));
        assert!(!mux.zoom_pane(Some(pane), ZoomMode::Off).unwrap().zoomed);
        assert!(!mux.move_tab(surface.id, pane, 0));
        assert!(!mux.move_workspace(workspace, 0));
        mux.select_tab(Some(pane), Some(0), None);
        mux.select_screen(Some(0), None);
        mux.select_workspace(Some(0), None);
        mux.close_surface(u64::MAX);
        mux.close_pane(u64::MAX);
        assert!(!mux.close_screen(u64::MAX));
        assert!(!mux.close_workspace(u64::MAX));

        assert_eq!(mux.canonical_topology_revision(), revision);
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn legacy_noop_events_do_not_advance_structural_v8_topology() {
        let mux = test_mux();
        let surface = mux.new_workspace(Some("one".into()), None).unwrap();
        let pane = mux.with_state(|state| state.active_pane().unwrap());
        mux.split(pane, SplitDir::Right, None).unwrap();
        let (workspace, screen) =
            mux.with_state(|state| (state.workspaces[0].id, state.workspaces[0].screens[0].id));
        let legacy_revision = mux.topology_revision();
        let revision = mux.canonical_topology_revision();
        let topology = topology_subscription(&mux, revision);
        let legacy = mux.subscribe();

        assert!(mux.rename_workspace(workspace, "one".into()));
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeDelta(_)));
        assert!(mux.rename_screen(screen, String::new()));
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeDelta(_)));
        assert!(mux.rename_pane(pane, String::new()));
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeChanged));
        assert!(mux.rename_surface(surface.id, String::new()));
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeDelta(_)));
        assert!(mux.focus_pane(pane));
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeChanged));
        assert!(mux.set_ratio(pane, SplitDir::Right, 0.5));
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeChanged));
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::LayoutChanged(_)));
        mux.select_tab(Some(pane), Some(0), None);
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeChanged));
        mux.select_screen(Some(0), None);
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeChanged));
        mux.select_workspace(Some(0), None);
        assert!(matches!(legacy.recv().unwrap(), MuxEvent::TreeChanged));

        assert!(mux.topology_revision() > legacy_revision);
        assert_eq!(mux.canonical_topology_revision(), revision);
        assert!(matches!(topology.receiver.try_recv(), Err(TryRecvError::Empty)));
        assert!(matches!(legacy.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn focus_selection_and_zoom_advance_only_the_legacy_revision() {
        let mux = test_mux();
        let first_surface = mux.new_workspace(Some("one".into()), None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first_surface.id).unwrap());
        mux.new_tab(Some(first_pane), None, None).unwrap();
        mux.split(first_pane, SplitDir::Right, None).unwrap();
        let canonical = mux.topology_snapshot();
        let mut legacy_revision = mux.topology_revision();

        assert!(mux.focus_pane(first_pane));
        legacy_revision += 1;
        assert_eq!(mux.topology_revision(), legacy_revision);
        assert_eq!(mux.topology_snapshot(), canonical);

        mux.select_tab(Some(first_pane), Some(0), None);
        legacy_revision += 1;
        assert_eq!(mux.topology_revision(), legacy_revision);
        assert_eq!(mux.topology_snapshot(), canonical);

        mux.select_screen(Some(0), None);
        legacy_revision += 1;
        assert_eq!(mux.topology_revision(), legacy_revision);
        assert_eq!(mux.topology_snapshot(), canonical);

        mux.select_workspace(Some(0), None);
        legacy_revision += 1;
        assert_eq!(mux.topology_revision(), legacy_revision);
        assert_eq!(mux.topology_snapshot(), canonical);

        let zoom = mux.zoom_pane(Some(first_pane), ZoomMode::On).unwrap();
        assert!(zoom.zoomed);
        legacy_revision += 1;
        assert_eq!(mux.topology_revision(), legacy_revision);
        assert_eq!(mux.topology_snapshot(), canonical);
    }

    #[test]
    fn concurrent_pane_close_never_reaps_a_tab_after_a_successful_move() {
        for iteration in 0..64 {
            let mux = test_mux();
            let first = mux.new_workspace(Some(format!("race-{iteration}")), None).unwrap();
            let source = mux.with_state(|state| state.active_pane().unwrap());
            let target_surface = mux.split(source, SplitDir::Right, None).unwrap();
            let target = mux.with_state(|state| state.pane_of(target_surface.id).unwrap());
            let mut candidates = vec![first.id];
            for _ in 0..4 {
                candidates.push(mux.new_tab(Some(source), None, None).unwrap().id);
            }
            let start = Arc::new(std::sync::Barrier::new(3));
            let move_mux = mux.clone();
            let move_start = start.clone();
            let move_candidates = candidates.clone();
            let mover = std::thread::spawn(move || {
                move_start.wait();
                move_candidates
                    .into_iter()
                    .map(|surface| (surface, move_mux.move_tab(surface, target, usize::MAX)))
                    .collect::<Vec<_>>()
            });
            let close_mux = mux.clone();
            let close_start = start.clone();
            let closer = std::thread::spawn(move || {
                close_start.wait();
                close_mux.close_pane(source);
            });
            start.wait();
            let moved = mover.join().unwrap();
            closer.join().unwrap();

            mux.with_state(|state| {
                for (surface, succeeded) in &moved {
                    if *succeeded {
                        assert_eq!(state.pane_of(*surface), Some(target));
                        assert!(state.surfaces.contains_key(surface));
                    }
                }
                let mut referenced = state
                    .panes
                    .values()
                    .flat_map(|pane| pane.tabs.iter().copied())
                    .collect::<Vec<_>>();
                referenced.sort_unstable();
                let mut stored = state.surfaces.keys().copied().collect::<Vec<_>>();
                stored.sort_unstable();
                assert_eq!(referenced, stored);
            });
        }
    }

    #[test]
    fn invalid_layout_is_rejected_before_spawning_any_surface() {
        let mux = test_mux();
        let before = mux.surface_count();
        let layout = LayoutSpec::Split {
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(LayoutSpec::Leaf(LayoutLeafSpec {
                cwd: None,
                command: Some(vec!["/bin/true".into()]),
            })),
            b: Box::new(LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: Some(Vec::new()) })),
        };
        assert!(mux.apply_layout(None, None, &layout, None).is_err());
        assert_eq!(mux.surface_count(), before);
        assert_eq!(mux.topology_revision(), 0);
    }

    #[test]
    fn entity_uuids_survive_renames_reorders_and_moves_but_not_recreation() {
        let mux = test_mux();
        let first_surface = mux.new_workspace(Some("first".into()), None).unwrap();
        let (workspace, workspace_uuid, screen, screen_uuid, pane, pane_uuid, surface_uuid) = mux
            .with_state(|state| {
                let workspace = &state.workspaces[0];
                let screen = &workspace.screens[0];
                let pane = &state.panes[&screen.active_pane];
                (
                    workspace.id,
                    workspace.uuid,
                    screen.id,
                    screen.uuid,
                    pane.id,
                    pane.uuid,
                    state.surfaces[&first_surface.id].uuid,
                )
            });

        assert!(mux.rename_workspace(workspace, "renamed".into()));
        assert!(mux.rename_screen(screen, "screen".into()));
        assert!(mux.rename_pane(pane, "pane".into()));
        assert!(mux.rename_surface(first_surface.id, "surface".into()));
        let second_surface = mux.new_workspace(Some("second".into()), None).unwrap();
        let (second_workspace_uuid, second_screen_uuid, second_pane, second_pane_uuid) = mux
            .with_state(|state| {
                let workspace = &state.workspaces[1];
                let screen = &workspace.screens[0];
                (
                    workspace.uuid,
                    screen.uuid,
                    screen.active_pane,
                    state.panes[&screen.active_pane].uuid,
                )
            });
        assert!(mux.move_workspace(workspace, 2));

        mux.with_state(|state| {
            assert_eq!(state.workspace_uuid(workspace), Some(workspace_uuid));
            assert_eq!(state.screen_uuid(screen), Some(screen_uuid));
            assert_eq!(state.pane_uuid(pane), Some(pane_uuid));
            assert_eq!(state.surface_uuid(first_surface.id), Some(surface_uuid));
            assert_eq!(state.workspace_id_by_uuid(workspace_uuid), Some(workspace));
            assert_eq!(state.screen_id_by_uuid(screen_uuid), Some(screen));
            assert_eq!(state.pane_id_by_uuid(pane_uuid), Some(pane));
            assert_eq!(state.surface_id_by_uuid(surface_uuid), Some(first_surface.id));
        });

        let subscription = topology_subscription(&mux, mux.canonical_topology_revision());
        assert!(mux.move_tab(first_surface.id, second_pane, 1));
        let moved = subscription.receiver.recv().unwrap();
        assert_eq!(moved.operation, TopologyOperation::TabMoved);
        assert!(moved.targets.workspaces.contains(&workspace_uuid));
        assert!(moved.targets.workspaces.contains(&second_workspace_uuid));
        assert!(moved.targets.screens.contains(&screen_uuid));
        assert!(moved.targets.screens.contains(&second_screen_uuid));
        assert!(moved.targets.panes.contains(&pane_uuid));
        assert!(moved.targets.panes.contains(&second_pane_uuid));
        assert!(moved.targets.surfaces.contains(&surface_uuid));
        assert_eq!(
            mux.with_state(|state| state.surface_uuid(first_surface.id)),
            Some(surface_uuid)
        );
        mux.close_surface(first_surface.id);
        assert_eq!(mux.with_state(|state| state.surface_uuid(first_surface.id)), None);
        let replacement = mux.new_tab(Some(second_pane), None, None).unwrap();
        assert_ne!(replacement.uuid, surface_uuid);
        assert_ne!(replacement.id, first_surface.id);
        assert!(mux.surface(second_surface.id).is_some());
    }

    #[test]
    fn canonical_delta_has_one_revision_stable_targets_and_full_replacement() {
        let mux = test_mux();
        let subscription = topology_subscription(&mux, 0);

        mux.new_workspace(Some("one".into()), None).unwrap();

        let delta = subscription.receiver.recv().unwrap();
        assert_eq!(delta.base_revision, 0);
        assert_eq!(delta.revision, 1);
        assert_eq!(delta.operation, TopologyOperation::WorkspaceCreated);
        assert_eq!(delta.targets.workspaces.len(), 1);
        assert_eq!(delta.targets.screens.len(), 1);
        assert_eq!(delta.targets.panes.len(), 1);
        assert_eq!(delta.targets.surfaces.len(), 1);
        assert_eq!(delta.replacement, mux.topology_snapshot().topology);
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn exit_after_registration_before_tab_attach_publishes_only_valid_topology() {
        let mux = test_mux();
        let existing = mux.new_workspace(Some("existing".into()), None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(existing.id).unwrap());
        let before = mux.topology_snapshot();
        let subscription = topology_subscription(&mux, before.revision);
        let registered = Arc::new(std::sync::Barrier::new(2));
        let resume = Arc::new(std::sync::Barrier::new(2));
        *mux.test_surface_registered_barriers.lock().unwrap() =
            Some((registered.clone(), resume.clone()));

        let worker_mux = mux.clone();
        let worker = std::thread::spawn(move || worker_mux.new_tab(Some(pane), None, None));
        registered.wait();

        let pending = mux.with_state(|state| {
            state
                .surfaces
                .keys()
                .copied()
                .find(|surface| *surface != existing.id && state.pane_of(*surface).is_none())
                .expect("registered surface is pending tree attachment")
        });
        let pending_surface = mux.surface(pending).unwrap();
        pending_surface.mark_dead_for_test();
        mux.surface_exited(pending);

        assert!(mux.surface(pending).is_some());
        assert_eq!(mux.canonical_topology_revision(), before.revision);
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));

        resume.wait();
        let returned = worker.join().expect("tab creator did not panic").unwrap();
        assert_eq!(returned.id, pending);

        let attached = subscription.receiver.recv().unwrap();
        assert_eq!(attached.operation, TopologyOperation::SurfaceAttached);
        assert_eq!(attached.base_revision, before.revision);
        assert_eq!(attached.revision, before.revision + 1);
        let attached_tabs = attached.replacement["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|workspace| workspace["screens"].as_array().unwrap())
            .flat_map(|screen| screen["panes"].as_array().unwrap())
            .flat_map(|pane| pane["tabs"].as_array().unwrap());
        assert!(attached_tabs.into_iter().any(|tab| tab["id"] == pending));

        let closed = subscription.receiver.recv().unwrap();
        assert_eq!(closed.operation, TopologyOperation::SurfaceClosed);
        assert_eq!(closed.base_revision, attached.revision);
        assert_eq!(closed.revision, attached.revision + 1);
        assert!(mux.surface(pending).is_none());
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn canonical_snapshot_accepts_empty_state_and_excludes_presentation_selections() {
        let mux = test_mux();
        let empty = mux.topology_snapshot();
        assert_eq!(empty.revision, 0);
        assert_eq!(empty.topology, serde_json::json!({"workspaces": []}));

        mux.new_workspace(Some("first".into()), None).unwrap();
        let first_pane = mux.with_state(|state| state.active_pane().unwrap());
        mux.new_tab(Some(first_pane), None, None).unwrap();
        mux.split(first_pane, SplitDir::Right, None).unwrap();
        mux.new_screen(None, None).unwrap();
        mux.new_workspace(Some("second".into()), None).unwrap();

        let snapshot = mux.topology_snapshot();
        let workspaces = snapshot.topology["workspaces"].as_array().unwrap();
        for workspace in workspaces {
            assert!(workspace.get("active").is_none());
            assert!(workspace.get("active_screen").is_none());
            let screens = workspace["screens"].as_array().unwrap();
            assert!(!screens.is_empty());

            for screen in screens {
                for excluded in
                    ["active", "active_pane", "active_pane_uuid", "zoomed_pane", "zoomed_pane_uuid"]
                {
                    assert!(screen.get(excluded).is_none());
                }
                let panes = screen["panes"].as_array().unwrap();
                assert!(!panes.is_empty());

                for pane in panes {
                    assert!(pane.get("active_tab").is_none());
                    let tabs = pane["tabs"].as_array().unwrap();
                    assert!(!tabs.is_empty());
                    assert!(tabs.iter().all(|tab| tab.get("active").is_none()));
                }
            }
        }
    }

    #[test]
    fn presentation_state_is_outside_canonical_topology_and_revision() {
        let mux = test_mux();
        mux.new_workspace(Some("one".into()), None).unwrap();
        let before = mux.topology_snapshot();
        let subscription = topology_subscription(&mux, before.revision);

        let presentation = mux
            .presentations
            .open(
                17,
                crate::PresentationView::default(),
                crate::PresentationZoom::default(),
                crate::PresentationScroll::default(),
            )
            .unwrap();
        assert_eq!(mux.topology_snapshot(), before);
        assert!(!before.topology.to_string().contains("presentation"));
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));

        mux.presentations.close(17, presentation.presentation_id).unwrap();
        assert_eq!(mux.topology_snapshot(), before);
    }

    #[test]
    fn concurrent_writers_publish_deltas_in_committed_revision_order() {
        let mux = test_mux();
        let subscription = topology_subscription(&mux, 0);
        let start = Arc::new(std::sync::Barrier::new(9));
        let writers = (0..8)
            .map(|worker| {
                let mux = mux.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    for index in 0..4 {
                        mux.new_workspace(Some(format!("{worker}-{index}")), None).unwrap();
                    }
                })
            })
            .collect::<Vec<_>>();
        start.wait();
        for writer in writers {
            writer.join().unwrap();
        }

        for revision in 1..=32 {
            let delta = subscription.receiver.recv().unwrap();
            assert_eq!(delta.base_revision, revision - 1);
            assert_eq!(delta.revision, revision);
        }
        assert_eq!(mux.canonical_topology_revision(), 32);
    }

    #[test]
    fn topology_fanout_computes_size_once_and_shares_one_delta_allocation() {
        let mux = test_mux();
        let subscriptions = (0..256).map(|_| topology_subscription(&mux, 0)).collect::<Vec<_>>();
        let size_computations = mux.topology_size_computations();
        let started = Instant::now();

        mux.new_workspace(Some("fanout".into()), None).unwrap();

        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(mux.topology_size_computations(), size_computations + 1);
        let first = subscriptions[0].receiver.recv().unwrap();
        for subscription in &subscriptions[1..] {
            let delivered = subscription.receiver.recv().unwrap();
            assert!(Arc::ptr_eq(&first, &delivered));
        }
    }

    #[test]
    fn snapshot_then_racing_subscribe_has_no_lost_mutation_window() {
        let mux = test_mux();
        let snapshot = mux.topology_snapshot();
        let start = Arc::new(std::sync::Barrier::new(2));
        let writer_mux = mux.clone();
        let writer_start = start.clone();
        let writer = std::thread::spawn(move || {
            writer_start.wait();
            for index in 0..64 {
                writer_mux.new_workspace(Some(format!("race-{index}")), None).unwrap();
                std::thread::yield_now();
            }
        });

        start.wait();
        let subscription = match mux.subscribe_topology(
            snapshot.daemon_instance_id,
            snapshot.session_id,
            snapshot.revision,
        ) {
            TopologyResume::Subscribed(subscription) => subscription,
            TopologyResume::ResnapshotRequired(required) => {
                panic!("unexpected resnapshot requirement: {:?}", required.reason)
            }
        };
        writer.join().unwrap();
        let final_revision = mux.canonical_topology_revision();
        let mut expected = snapshot.revision;
        while expected < final_revision {
            let delta = subscription.receiver.recv().unwrap();
            assert_eq!(delta.base_revision, expected);
            expected = delta.revision;
        }
        assert_eq!(expected, final_revision);
    }

    #[test]
    fn retained_history_count_and_byte_gaps_require_resnapshot() {
        let count_limited = Mux::new_for_test_with_topology_limits(
            "count-gap",
            SurfaceOptions::default(),
            TopologyLimits {
                history_count: 2,
                history_bytes: usize::MAX,
                subscriber_count: 32,
                subscriber_bytes: usize::MAX,
            },
        );
        for index in 0..3 {
            count_limited.new_workspace(Some(format!("count-{index}")), None).unwrap();
        }
        assert!(matches!(
            count_limited.subscribe_topology(
                count_limited.daemon_instance_id,
                count_limited.session_id,
                0,
            ),
            TopologyResume::ResnapshotRequired(crate::ResnapshotRequired {
                reason: crate::ResnapshotReason::HistoryGap,
                ..
            })
        ));
        let recovered = count_limited.topology_snapshot();
        let resumed = match count_limited.subscribe_topology(
            recovered.daemon_instance_id,
            recovered.session_id,
            recovered.revision,
        ) {
            TopologyResume::Subscribed(subscription) => subscription,
            TopologyResume::ResnapshotRequired(required) => {
                panic!("fresh snapshot did not recover: {:?}", required.reason)
            }
        };
        count_limited.new_workspace(Some("after-recovery".into()), None).unwrap();
        let next = resumed.receiver.recv().unwrap();
        assert_eq!(next.base_revision, recovered.revision);
        assert_eq!(next.revision, recovered.revision + 1);

        let byte_limited = Mux::new_for_test_with_topology_limits(
            "byte-gap",
            SurfaceOptions::default(),
            TopologyLimits {
                history_count: 32,
                history_bytes: 1,
                subscriber_count: 32,
                subscriber_bytes: usize::MAX,
            },
        );
        byte_limited.new_workspace(Some("one".into()), None).unwrap();
        assert!(matches!(
            byte_limited.subscribe_topology(
                byte_limited.daemon_instance_id,
                byte_limited.session_id,
                0,
            ),
            TopologyResume::ResnapshotRequired(crate::ResnapshotRequired {
                reason: crate::ResnapshotReason::HistoryGap,
                ..
            })
        ));
    }

    #[test]
    fn stale_daemon_resume_is_rejected_even_for_the_same_session() {
        let session_id = SessionId::new();
        let first = Mux::new_with_test_surface_runtime_and_limits(
            "restart",
            SurfaceOptions::default(),
            session_id,
            true,
            TopologyLimits::default(),
        );
        let old = first.topology_snapshot();
        let replacement = Mux::new_with_test_surface_runtime_and_limits(
            "restart",
            SurfaceOptions::default(),
            session_id,
            true,
            TopologyLimits::default(),
        );
        assert_eq!(old.session_id, replacement.session_id);
        assert_ne!(old.daemon_instance_id, replacement.daemon_instance_id);
        assert!(matches!(
            replacement.subscribe_topology(old.daemon_instance_id, old.session_id, old.revision),
            TopologyResume::ResnapshotRequired(crate::ResnapshotRequired {
                reason: crate::ResnapshotReason::StaleDaemon,
                ..
            })
        ));
    }

    #[test]
    fn stale_session_resume_is_rejected_before_revision_replay() {
        let mux = test_mux();
        mux.new_workspace(Some("one".into()), None).unwrap();
        assert!(matches!(
            mux.subscribe_topology(mux.daemon_instance_id, SessionId::new(), u64::MAX),
            TopologyResume::ResnapshotRequired(crate::ResnapshotRequired {
                reason: crate::ResnapshotReason::StaleSession,
                ..
            })
        ));
    }

    #[test]
    fn slow_topology_consumer_is_disconnected_without_skipping_silently() {
        let mux = Mux::new_for_test_with_topology_limits(
            "slow-consumer",
            SurfaceOptions::default(),
            TopologyLimits {
                history_count: 32,
                history_bytes: usize::MAX,
                subscriber_count: 2,
                subscriber_bytes: usize::MAX,
            },
        );
        let subscription = topology_subscription(&mux, 0);
        for index in 0..3 {
            mux.new_workspace(Some(format!("slow-{index}")), None).unwrap();
        }

        assert_eq!(subscription.receiver.recv().unwrap().revision, 1);
        assert_eq!(subscription.receiver.recv().unwrap().revision, 2);
        assert!(subscription.receiver.recv().is_err());
        assert!(subscription.receiver.overflowed());
    }

    fn ensure_request(
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        initial_input: &str,
    ) -> EnsureTerminalRequest {
        EnsureTerminalRequest {
            workspace_uuid,
            surface_uuid,
            cwd: Some("/tmp".to_owned()),
            argv: Some(vec!["/bin/sh".to_owned()]),
            env: vec![("CMUX_ENSURE_TEST".to_owned(), "1".to_owned())],
            initial_input: Some(initial_input.to_owned()),
            wait_after_command: false,
            cols: 90,
            rows: 30,
        }
    }

    struct PersistenceTestDirectory(std::path::PathBuf);

    impl PersistenceTestDirectory {
        fn new(name: &str) -> Self {
            Self(std::env::temp_dir().join(format!(
                "cmux-mux-persistence-{name}-{}-{}",
                std::process::id(),
                uuid::Uuid::new_v4()
            )))
        }
    }

    impl Drop for PersistenceTestDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn persisted_launch(argv: Vec<String>, cwd: Option<String>) -> PersistedLaunchRecipe {
        PersistedLaunchRecipe::sanitized(argv, cwd, Vec::new(), 80, 24, 10_000, false)
    }

    fn seed_persisted_terminals(
        store: &StateStore,
        terminals: Vec<(SurfaceUuid, Option<String>, PersistedLaunchRecipe)>,
    ) -> PersistedSessionState {
        let mut opened = store.open_session("main").unwrap();
        let workspace_uuid = WorkspaceUuid::new();
        let screen_uuid = ScreenUuid::new();
        let pane_uuid = PaneUuid::new();
        let tabs = terminals.iter().map(|(uuid, _, _)| *uuid).collect::<Vec<_>>();
        let mut state = opened.snapshot.clone();
        state.topology_revision = 1;
        state.active_workspace = Some(workspace_uuid);
        state.workspaces = vec![PersistedWorkspace {
            uuid: workspace_uuid,
            name: "1".to_string(),
            screens: vec![PersistedScreen {
                uuid: screen_uuid,
                name: None,
                root: PersistedNode::Leaf { pane_uuid },
                active_pane: pane_uuid,
                zoomed_pane: None,
            }],
            active_screen: 0,
        }];
        state.panes =
            vec![PersistedPane { uuid: pane_uuid, name: None, tabs, active_tab: 0, active_at: 1 }];
        state.surfaces = terminals
            .into_iter()
            .map(|(uuid, name, launch)| PersistedSurface {
                uuid,
                name,
                kind: PersistedSurfaceKind::Terminal { launch },
            })
            .collect();
        opened.durable.append(state.clone(), "seed".to_string(), None).unwrap();
        drop(opened.durable);
        state
    }

    fn wait_for_surface_uuid(mux: &Mux, uuid: SurfaceUuid, present: bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if mux.with_state(|state| state.surface_id_by_uuid(uuid).is_some()) == present {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("surface {uuid} presence did not become {present}");
    }

    #[test]
    fn daemon_restart_restores_exact_uuid_topology_with_new_terminal_runtime() {
        let directory = PersistenceTestDirectory::new("daemon-restart");
        let store = StateStore::new(&directory.0);
        let workspace_uuid = WorkspaceUuid::new();
        let first_uuid = SurfaceUuid::new();
        let second_uuid = SurfaceUuid::new();
        let first_mux =
            Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        let first_daemon = first_mux.daemon_instance_id;
        let session_id = first_mux.session_id;
        let mut first_request = ensure_request(workspace_uuid, first_uuid, "");
        first_request.argv = Some(vec!["/bin/cat".to_string()]);
        first_request.env.push(("API_TOKEN".to_string(), "must-not-persist".to_string()));
        let first = first_mux.ensure_terminal(first_request).unwrap();
        let mut second_request = ensure_request(workspace_uuid, second_uuid, "");
        second_request.argv = Some(vec!["/bin/cat".to_string()]);
        let second = first_mux.ensure_terminal(second_request).unwrap();
        assert!(first_mux.rename_workspace(first.workspace, "persisted-workspace".to_string()));
        assert!(first_mux.rename_pane(first.pane, "persisted-pane".to_string()));
        assert!(first_mux.rename_surface(first.surface, "first".to_string()));
        assert!(first_mux.rename_surface(second.surface, "second".to_string()));
        assert!(first_mux.move_tab(first.surface, first.pane, usize::MAX));

        let first_surface = first_mux.surface(first.surface).unwrap();
        let old_pid = first_surface.process_id().expect("real PTY child has a PID");
        let old_tty = first_surface.tty_name().expect("real PTY has a tty name");
        let old_epoch = first_surface
            .semantic_scene_terminal_identity()
            .expect("terminal has semantic identity")
            .runtime_epoch;
        let before = {
            let canonical = first_mux.state.lock().unwrap();
            canonical.persisted_snapshot(canonical.topology.revision()).unwrap()
        };
        drop(first_surface);
        drop(first_mux);

        let second_mux =
            Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        assert_eq!(second_mux.session_id, session_id);
        assert_ne!(second_mux.daemon_instance_id, first_daemon);
        let recovered_id = second_mux
            .with_state(|state| state.surface_id_by_uuid(first_uuid))
            .expect("stable surface UUID restored");
        let recovered = second_mux.surface(recovered_id).unwrap();
        assert_eq!(recovered.uuid, first_uuid);
        assert_eq!(recovered.spawn_argv(), Some(vec!["/bin/cat".to_string()]));
        assert_ne!(recovered.process_id(), Some(old_pid));
        assert_ne!(
            recovered
                .semantic_scene_terminal_identity()
                .expect("restored terminal has semantic identity")
                .runtime_epoch,
            old_epoch
        );
        assert!(second_mux.with_state(|state| {
            state.surfaces.values().all(|surface| surface.process_id() != Some(old_pid))
        }));
        let after = {
            let canonical = second_mux.state.lock().unwrap();
            canonical.persisted_snapshot(canonical.topology.revision()).unwrap()
        };
        assert_eq!(after, before);
        let journal = std::fs::read(store.journal_path("main")).unwrap();
        assert!(
            !journal
                .windows("must-not-persist".len())
                .any(|window| { window == "must-not-persist".as_bytes() })
        );
        let old_tty = old_tty.to_string_lossy();
        assert!(!journal.windows(old_tty.len()).any(|window| window == old_tty.as_bytes()));
    }

    #[test]
    fn daemon_restart_restores_external_terminal_recipe_without_owner_or_child() {
        let directory = PersistenceTestDirectory::new("external-terminal-restart");
        let store = StateStore::new(&directory.0);
        let workspace_uuid = WorkspaceUuid::new();
        let external_surface_uuid = SurfaceUuid::new();
        let producer_id = uuid::Uuid::new_v4();
        let provenance = ExternalTerminalProvenance {
            producer_kind: crate::remote_tmux_producer::ExternalTerminalProducerKind::RemoteTmux,
            producer_id,
            tmux_session_id: 7,
            tmux_window_id: 11,
            tmux_pane_id: 13,
            presentation_role:
                crate::remote_tmux_producer::ExternalTerminalPresentationRole::WorkspaceTab,
        };
        let producer_source = RemoteTmuxProducerSource {
            destination: "agent@sentinel-private-host.invalid".into(),
            port: Some(2222),
            identity_file: Some("/private/sentinel-key".into()),
            session_name: "sentinel-private-session".into(),
        };
        let first =
            Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
                .unwrap();
        first
            .canonical_new_external_workspace(
                canonical_expectation(&first, uuid::Uuid::new_v4(), 0),
                workspace_uuid,
                external_surface_uuid,
                (132, 43),
                true,
                provenance,
                producer_source,
            )
            .unwrap();
        let original_id =
            first.with_state(|state| state.surface_id_by_uuid(external_surface_uuid)).unwrap();
        let original = first.surface(original_id).unwrap();
        assert!(original.is_external_terminal());
        assert_eq!(original.external_terminal_recipe(), Some((132, 43, 10_000, true)));
        assert_eq!(original.process_id(), None);
        assert_eq!(original.tty_name(), None);
        let old_owner = ExternalTerminalOwner {
            client_uuid: uuid::Uuid::new_v4(),
            process_instance_uuid: uuid::Uuid::new_v4(),
            connection_id: 11,
        };
        let old_claim = first
            .claim_external_terminal(external_surface_uuid, old_owner, uuid::Uuid::new_v4())
            .unwrap();
        first
            .reset_external_terminal(
                external_surface_uuid,
                old_owner,
                old_claim.owner_generation,
                uuid::Uuid::new_v4(),
                old_claim.required_output_generation,
                132,
                43,
                false,
                b"persisted only by the Swift source of truth",
            )
            .unwrap();
        drop(original);
        drop(first);

        let restored =
            Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
                .unwrap();
        let restored_id = restored
            .with_state(|state| state.surface_id_by_uuid(external_surface_uuid))
            .expect("stable external terminal UUID restored");
        let surface = restored.surface(restored_id).unwrap();
        assert!(surface.is_external_terminal());
        assert_eq!(surface.external_terminal_recipe(), Some((132, 43, 10_000, false)));
        assert_eq!(surface.external_terminal_provenance(), Some(provenance));
        assert_eq!(surface.process_id(), None);
        assert_eq!(surface.tty_name(), None);
        let restored_source = restored
            .claim_remote_tmux_producer_source(
                producer_id,
                RemoteTmuxProducerOwner {
                    client_uuid: uuid::Uuid::new_v4(),
                    process_instance_uuid: uuid::Uuid::new_v4(),
                    connection_id: 20,
                },
                uuid::Uuid::new_v4(),
                None,
            )
            .unwrap();
        assert_eq!(restored_source.source, None);
        let journal = std::fs::read(store.journal_path("main")).unwrap();
        for secret in ["sentinel-private-host", "sentinel-key", "sentinel-private-session"] {
            assert!(!journal.windows(secret.len()).any(|window| window == secret.as_bytes()));
        }

        let replacement_owner = ExternalTerminalOwner {
            client_uuid: uuid::Uuid::new_v4(),
            process_instance_uuid: uuid::Uuid::new_v4(),
            connection_id: 12,
        };
        let replacement_claim = restored
            .claim_external_terminal(external_surface_uuid, replacement_owner, uuid::Uuid::new_v4())
            .unwrap();
        assert_eq!(replacement_claim.owner_generation, 1);
        assert_eq!(replacement_claim.required_output_generation, 1);
        let before_reset = restored.apply_external_terminal_output(
            external_surface_uuid,
            replacement_owner,
            replacement_claim.owner_generation,
            uuid::Uuid::new_v4(),
            replacement_claim.required_output_generation,
            1,
            b"late output",
        );
        assert!(before_reset.unwrap_err().to_string().contains("reset-and-seed"));
    }

    #[test]
    fn daemon_restart_restores_activity_and_independent_reader_receipts() {
        let directory = PersistenceTestDirectory::new("activity-restart");
        let store = StateStore::new(&directory.0);
        let workspace_uuid = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        let reader_a = uuid::Uuid::new_v4();
        let reader_b = uuid::Uuid::new_v4();
        let first =
            Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
                .unwrap();
        let placement =
            first.ensure_terminal(ensure_request(workspace_uuid, surface_uuid, "")).unwrap();
        let notification = first
            .post_notification(
                "private title".to_string(),
                "private body".to_string(),
                NotificationLevel::Warning,
                Some(placement.surface),
            )
            .unwrap();
        let fact = first
            .terminal_activity_snapshot(reader_a)
            .unwrap()
            .facts
            .into_iter()
            .find(|fact| fact.surface_uuid == surface_uuid)
            .unwrap();
        assert_eq!(fact.notification, notification);
        first.mark_terminal_seen(reader_a, surface_uuid, fact.sequence).unwrap();
        assert!(!first.terminal_activity_snapshot(reader_a).unwrap().is_unread(surface_uuid));
        assert!(first.terminal_activity_snapshot(reader_b).unwrap().is_unread(surface_uuid));
        drop(first);

        let restored =
            Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
                .unwrap();
        assert!(!restored.terminal_activity_snapshot(reader_a).unwrap().is_unread(surface_uuid));
        assert!(restored.terminal_activity_snapshot(reader_b).unwrap().is_unread(surface_uuid));
        let restored_surface =
            restored.with_state(|state| state.surface_id_by_uuid(surface_uuid)).unwrap();
        let next_notification = restored
            .post_notification(
                "new private title".to_string(),
                "new private body".to_string(),
                NotificationLevel::Error,
                Some(restored_surface),
            )
            .unwrap();
        let next_fact = restored
            .terminal_activity_snapshot(reader_a)
            .unwrap()
            .facts
            .into_iter()
            .find(|candidate| candidate.surface_uuid == surface_uuid)
            .unwrap();
        assert_eq!(next_notification, notification + 1);
        assert_eq!(next_fact.sequence, fact.sequence + 1);
        assert!(restored.terminal_activity_snapshot(reader_a).unwrap().is_unread(surface_uuid));
        assert!(restored.terminal_activity_snapshot(reader_b).unwrap().is_unread(surface_uuid));

        let journal = std::fs::read(store.journal_path("main")).unwrap();
        for secret in ["private title", "private body", "new private title", "new private body"] {
            assert!(!journal.windows(secret.len()).any(|window| window == secret.as_bytes()));
        }
    }

    #[cfg(unix)]
    #[test]
    fn restored_child_exit_is_tombstoned_before_a_second_restart() {
        let directory = PersistenceTestDirectory::new("restore-exit");
        let store = StateStore::new(&directory.0);
        let exited_uuid = SurfaceUuid::new();
        let retained_uuid = SurfaceUuid::new();
        seed_persisted_terminals(
            &store,
            vec![
                (
                    exited_uuid,
                    Some("exits".to_string()),
                    persisted_launch(vec!["/usr/bin/true".to_string()], None),
                ),
                (
                    retained_uuid,
                    Some("retained".to_string()),
                    persisted_launch(vec!["/bin/cat".to_string()], None),
                ),
            ],
        );

        let first =
            Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        wait_for_surface_uuid(&first, exited_uuid, false);
        wait_for_surface_uuid(&first, retained_uuid, true);
        assert!(first.state.lock().unwrap().tombstones.iter().any(|entry| {
            entry.kind == PersistedEntityKind::Surface && entry.uuid == exited_uuid.as_uuid()
        }));
        drop(first);

        let second =
            Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        second.with_state(|state| {
            assert!(state.surface_id_by_uuid(exited_uuid).is_none());
            assert!(state.surface_id_by_uuid(retained_uuid).is_some());
        });
    }

    #[cfg(unix)]
    #[test]
    fn recovery_isolates_missing_cwd_and_command_with_stable_uuids() {
        let directory = PersistenceTestDirectory::new("isolated-recovery");
        let store = StateStore::new(&directory.0);
        let cwd_uuid = SurfaceUuid::new();
        let command_uuid = SurfaceUuid::new();
        let neighbor_uuid = SurfaceUuid::new();
        let missing_cwd = directory.0.join("deleted-project");
        let missing_command = directory.0.join("do-not-log-secret-command");
        let cwd_recipe =
            persisted_launch(vec!["/bin/cat".to_string()], Some(missing_cwd.display().to_string()));
        let command_recipe = persisted_launch(
            vec![missing_command.display().to_string(), "secret-argument".to_string()],
            None,
        );
        let neighbor_recipe = persisted_launch(vec!["/bin/cat".to_string()], None);
        seed_persisted_terminals(
            &store,
            vec![
                (cwd_uuid, Some("user label".to_string()), cwd_recipe.clone()),
                (command_uuid, None, command_recipe.clone()),
                (neighbor_uuid, Some("neighbor".to_string()), neighbor_recipe.clone()),
            ],
        );

        let restored =
            Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        let home = crate::platform::native_home_dir().unwrap().to_string_lossy().into_owned();
        let cwd_surface = restored
            .surface(restored.with_state(|state| state.surface_id_by_uuid(cwd_uuid)).unwrap())
            .unwrap();
        let command_surface = restored
            .surface(restored.with_state(|state| state.surface_id_by_uuid(command_uuid)).unwrap())
            .unwrap();
        let neighbor_surface = restored
            .surface(restored.with_state(|state| state.surface_id_by_uuid(neighbor_uuid)).unwrap())
            .unwrap();

        assert_eq!(cwd_surface.uuid, cwd_uuid);
        assert_eq!(cwd_surface.name().as_deref(), Some("user label"));
        assert_eq!(cwd_surface.spawn_argv(), Some(vec!["/bin/cat".to_string()]));
        assert_eq!(cwd_surface.spawn_cwd().as_deref(), Some(home.as_str()));
        let cwd_text = cwd_surface.try_with_terminal(|term| term.plain_text()).unwrap().unwrap();
        assert!(cwd_text.contains("saved working directory was unavailable"));

        assert_eq!(command_surface.uuid, command_uuid);
        assert_eq!(command_surface.name().as_deref(), Some("Recovered terminal"));
        assert_eq!(command_surface.spawn_argv(), Some(vec![crate::platform::default_shell()]));
        assert_eq!(command_surface.spawn_cwd().as_deref(), Some(home.as_str()));
        let command_text =
            command_surface.try_with_terminal(|term| term.plain_text()).unwrap().unwrap();
        assert!(command_text.contains("saved command could not be started"));
        assert!(!command_text.contains("do-not-log-secret-command"));
        assert!(!command_text.contains("secret-argument"));

        assert_eq!(neighbor_surface.uuid, neighbor_uuid);
        assert_eq!(neighbor_surface.name().as_deref(), Some("neighbor"));
        assert_eq!(neighbor_surface.spawn_argv(), Some(vec!["/bin/cat".to_string()]));
        let neighbor_text =
            neighbor_surface.try_with_terminal(|term| term.plain_text()).unwrap().unwrap();
        assert!(!neighbor_text.contains("cmux recovery:"));

        let canonical = restored.state.lock().unwrap();
        assert_eq!(canonical.launch_recipes.get(&cwd_uuid), Some(&cwd_recipe));
        assert_eq!(canonical.launch_recipes.get(&command_uuid), Some(&command_recipe));
        assert_eq!(canonical.launch_recipes.get(&neighbor_uuid), Some(&neighbor_recipe));
        drop(canonical);
        drop(cwd_surface);
        drop(command_surface);
        drop(neighbor_surface);
        drop(restored);

        let restarted =
            Mux::recover_from_state_store("main", SurfaceOptions::default(), &store).unwrap();
        restarted.with_state(|state| {
            assert!(state.surface_id_by_uuid(cwd_uuid).is_some());
            assert!(state.surface_id_by_uuid(command_uuid).is_some());
            assert!(state.surface_id_by_uuid(neighbor_uuid).is_some());
        });
    }

    #[test]
    fn closed_terminal_tombstone_survives_restart_without_respawning_it() {
        let directory = PersistenceTestDirectory::new("tombstone-restart");
        let store = StateStore::new(&directory.0);
        let workspace_uuid = WorkspaceUuid::new();
        let retained_uuid = SurfaceUuid::new();
        let closed_uuid = SurfaceUuid::new();
        let mux = Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
            .unwrap();
        mux.ensure_terminal(ensure_request(workspace_uuid, retained_uuid, "")).unwrap();
        let closed = mux.ensure_terminal(ensure_request(workspace_uuid, closed_uuid, "")).unwrap();
        mux.close_surface(closed.surface);
        drop(mux);

        let restored =
            Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
                .unwrap();
        restored.with_state(|state| {
            assert!(state.surface_id_by_uuid(retained_uuid).is_some());
            assert!(state.surface_id_by_uuid(closed_uuid).is_none());
        });
        let canonical = restored.state.lock().unwrap();
        assert!(canonical.tombstones.iter().any(|tombstone| {
            tombstone.kind == PersistedEntityKind::Surface
                && tombstone.uuid == closed_uuid.as_uuid()
        }));
        drop(canonical);
        let retry = restored
            .ensure_terminal(ensure_request(workspace_uuid, closed_uuid, "must-not-run"))
            .unwrap_err();
        assert!(retry.to_string().contains("tombstoned"));
        restored.with_state(|state| assert_eq!(state.surfaces.len(), 1));
    }

    #[test]
    fn tombstones_and_idempotency_results_evict_oldest_entries_at_their_bounds() {
        let mux = test_mux();
        let surface = mux.new_workspace(Some("bounded".to_string()), None).unwrap();
        let workspace = mux.with_state(|state| state.workspaces[0].id);
        {
            let mut canonical = mux.state.lock().unwrap();
            canonical.tombstones = (0..MAX_PERSISTED_TOMBSTONES)
                .map(|index| PersistedTombstone {
                    kind: PersistedEntityKind::Surface,
                    uuid: uuid::Uuid::from_u128(index as u128 + 1),
                    removed_at_topology_revision: index as u64,
                })
                .collect();
            canonical.idempotency_results = (0..MAX_PERSISTED_IDEMPOTENCY_RESULTS)
                .map(|index| PersistedIdempotencyResult {
                    key: format!("seed-{index}"),
                    payload_digest: String::new(),
                    committed_topology_revision: index as u64,
                    workspaces: Vec::new(),
                    screens: Vec::new(),
                    panes: Vec::new(),
                    surfaces: Vec::new(),
                })
                .collect();
        }

        assert!(mux.rename_workspace(workspace, "bounded-renamed".to_string()));
        assert_eq!(
            mux.state.lock().unwrap().idempotency_results.len(),
            MAX_PERSISTED_IDEMPOTENCY_RESULTS
        );
        assert!(mux.durable_idempotency_result("seed-0").is_none());
        assert!(mux.durable_idempotency_result("seed-1").is_some());
        mux.close_surface(surface.id);
        let canonical = mux.state.lock().unwrap();
        assert_eq!(canonical.tombstones.len(), MAX_PERSISTED_TOMBSTONES);
        assert!(!canonical.tombstones.iter().any(|entry| entry.uuid == uuid::Uuid::from_u128(1)));
        assert!(canonical.tombstones.iter().any(|entry| entry.uuid == surface.uuid.as_uuid()));
    }

    #[test]
    fn ensure_terminal_batch_rejects_duplicate_surface_identity_before_spawning() {
        let mux = test_mux();
        let surface_uuid = SurfaceUuid::new();
        let before_revisions = mux.topology_revisions();
        let error = mux
            .ensure_terminals(vec![
                ensure_request(WorkspaceUuid::new(), surface_uuid, "first\n"),
                ensure_request(WorkspaceUuid::new(), surface_uuid, "second\n"),
            ])
            .unwrap_err();

        assert!(error.to_string().contains("duplicate surface UUID"));
        assert_eq!(mux.topology_revisions(), before_revisions);
        let state = mux.state.lock().unwrap();
        assert!(state.surfaces.is_empty());
        assert!(state.workspaces.is_empty());
        assert!(state.launch_recipes.is_empty());
        assert_eq!(state.topology_commit_count, 0);
        assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn ensure_terminal_batch_spawn_failure_leaves_no_runtime_or_topology_state() {
        let mux = test_mux();
        mux.ensure_terminal_batch_fail_spawn_at.store(3, Ordering::Relaxed);
        let before_revisions = mux.topology_revisions();
        let requests = (0..5)
            .map(|_| ensure_request(WorkspaceUuid::new(), SurfaceUuid::new(), "must-not-run\n"))
            .collect::<Vec<_>>();

        let error = mux.ensure_terminals(requests).unwrap_err();
        assert!(error.to_string().contains("injected ensure-terminal batch spawn failure"));
        assert_eq!(mux.topology_revisions(), before_revisions);
        let state = mux.state.lock().unwrap();
        assert!(state.surfaces.is_empty());
        assert!(state.workspaces.is_empty());
        assert!(state.launch_recipes.is_empty());
        assert_eq!(state.topology_commit_count, 0);
        assert_eq!(state.topology_replacement_serialization_count, 0);
        assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn ensure_terminal_batch_aborts_when_topology_changes_during_private_spawns() {
        let mux = test_mux();
        let workspace_uuid = WorkspaceUuid::new();
        let existing =
            mux.ensure_terminal(ensure_request(workspace_uuid, SurfaceUuid::new(), "")).unwrap();
        let new_surface_uuid = SurfaceUuid::new();
        let before_revisions = mux.topology_revisions();
        let weak_mux = Arc::downgrade(&mux);
        *mux.ensure_terminal_batch_before_publish.lock().unwrap() = Some(Arc::new(move || {
            let mux = weak_mux.upgrade().expect("test mux remains alive");
            assert!(mux.rename_workspace(existing.workspace, "changed-during-spawn".to_owned()));
        }));

        let error = mux
            .ensure_terminals(vec![ensure_request(workspace_uuid, new_surface_uuid, "")])
            .unwrap_err();
        *mux.ensure_terminal_batch_before_publish.lock().unwrap() = None;

        assert!(error.to_string().contains("topology changed during batch materialization"));
        assert_eq!(mux.topology_revisions(), (before_revisions.0 + 1, before_revisions.1 + 1));
        let state = mux.state.lock().unwrap();
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].name, "changed-during-spawn");
        assert_eq!(state.surfaces.len(), 1);
        assert!(state.indexed_surface_id_by_uuid(new_surface_uuid).is_none());
        assert_eq!(state.launch_recipes.len(), 1);
    }

    #[test]
    fn one_thousand_terminals_materialize_in_one_durable_canonical_transaction() {
        const TERMINAL_COUNT: usize = 1_000;

        let directory = PersistenceTestDirectory::new("batch-1000");
        let store = StateStore::new(&directory.0);
        let mux = Mux::recover_from_state_store_for_test("main", SurfaceOptions::default(), &store)
            .unwrap();
        let requests = (0..TERMINAL_COUNT)
            .map(|_| ensure_request(WorkspaceUuid::new(), SurfaceUuid::new(), ""))
            .collect::<Vec<_>>();
        let before_revision = mux.canonical_topology_revision();
        let subscription = topology_subscription(&mux, before_revision);
        let before_counts = {
            let state = mux.state.lock().unwrap();
            (
                state.topology_commit_count,
                state.topology_replacement_serialization_count,
                state.persisted_snapshot_count,
                state.topology_index_rebuild_count,
            )
        };

        let placements = mux.ensure_terminals(requests.clone()).unwrap();
        assert_eq!(placements.len(), TERMINAL_COUNT);
        assert!(placements.iter().all(|placement| placement.created));
        assert!(placements.iter().zip(&requests).all(|(placement, request)| {
            placement.workspace_uuid == request.workspace_uuid
                && placement.surface_uuid == request.surface_uuid
        }));
        let delta = subscription.receiver.recv().unwrap();
        assert_eq!(delta.operation, TopologyOperation::LayoutApplied);
        assert_eq!(delta.base_revision, before_revision);
        assert_eq!(delta.revision, before_revision + 1);
        assert_eq!(delta.targets.workspaces.len(), TERMINAL_COUNT);
        assert_eq!(delta.targets.screens.len(), TERMINAL_COUNT);
        assert_eq!(delta.targets.panes.len(), TERMINAL_COUNT);
        assert_eq!(delta.targets.surfaces.len(), TERMINAL_COUNT);
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));

        let after_counts = {
            let state = mux.state.lock().unwrap();
            assert_eq!(state.workspaces.len(), TERMINAL_COUNT);
            assert_eq!(state.panes.len(), TERMINAL_COUNT);
            assert_eq!(state.surfaces.len(), TERMINAL_COUNT);
            assert_eq!(
                state.topology_index.build_counts,
                CanonicalTopologyIndexBuildCounts {
                    workspace_visits: TERMINAL_COUNT,
                    screen_visits: TERMINAL_COUNT,
                    pane_visits: TERMINAL_COUNT,
                    surface_visits: TERMINAL_COUNT,
                    tab_visits: TERMINAL_COUNT,
                }
            );
            (
                state.topology_commit_count,
                state.topology_replacement_serialization_count,
                state.persisted_snapshot_count,
                state.topology_index_rebuild_count,
            )
        };
        assert_eq!(
            after_counts,
            (before_counts.0 + 1, before_counts.1 + 1, before_counts.2 + 1, before_counts.3 + 1,)
        );
        assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 0);

        let retried = mux.ensure_terminals(requests).unwrap();
        assert!(retried.iter().all(|placement| !placement.created));
        let retry_counts = {
            let state = mux.state.lock().unwrap();
            (
                state.topology_commit_count,
                state.topology_replacement_serialization_count,
                state.persisted_snapshot_count,
                state.topology_index_rebuild_count,
            )
        };
        assert_eq!(retry_counts, after_counts);
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));
        assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn concurrent_ensure_terminal_creates_and_initializes_exactly_once() {
        let mux = test_mux();
        let workspace_uuid = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        let ready = Arc::new(std::sync::Barrier::new(9));
        let mut threads = Vec::new();
        for _ in 0..8 {
            let mux = mux.clone();
            let ready = ready.clone();
            threads.push(std::thread::spawn(move || {
                ready.wait();
                mux.ensure_terminal(ensure_request(workspace_uuid, surface_uuid, "echo once\n"))
                    .unwrap()
            }));
        }
        ready.wait();
        let placements =
            threads.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>();

        assert_eq!(placements.iter().filter(|placement| placement.created).count(), 1);
        assert!(placements.iter().all(|placement| {
            placement.workspace_uuid == workspace_uuid
                && placement.surface_uuid == surface_uuid
                && placement.workspace == placements[0].workspace
                && placement.surface == placements[0].surface
        }));
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.surfaces.len(), 1);
        });
        assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn reconnecting_ensure_terminal_does_not_respawn_or_replay_initial_input() {
        let mux = test_mux();
        let workspace_uuid = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        let mut first_request = ensure_request(workspace_uuid, surface_uuid, "first\n");
        first_request.wait_after_command = true;
        let first = mux.ensure_terminal(first_request).unwrap();
        let second = mux
            .ensure_terminal(ensure_request(workspace_uuid, surface_uuid, "must-not-run\n"))
            .unwrap();

        assert!(first.created);
        assert!(!second.created);
        assert_eq!(first.workspace, second.workspace);
        assert_eq!(first.screen, second.screen);
        assert_eq!(first.pane, second.pane);
        assert_eq!(first.surface, second.surface);
        let surface = mux.surface(first.surface).unwrap();
        assert_eq!(surface.process_id(), Some(first.surface as u32));
        assert_eq!(surface.tty_name(), Some(format!("/dev/ttys{}", first.surface).into()));
        assert_eq!(surface.spawn_argv(), Some(vec!["/bin/sh".to_owned()]));
        assert!(surface.wait_after_command());
        assert_eq!(mux.ensure_terminal_initial_writes.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn ensure_terminal_rejects_cross_workspace_surface_uuid_reuse() {
        let mux = test_mux();
        let first_workspace = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        mux.ensure_terminal(ensure_request(first_workspace, surface_uuid, "")).unwrap();

        let error = mux
            .ensure_terminal(ensure_request(WorkspaceUuid::new(), surface_uuid, ""))
            .unwrap_err();
        assert!(error.to_string().contains("belongs to workspace"));
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.surfaces.len(), 1);
        });
    }

    #[test]
    fn reparent_terminal_preserves_runtime_process_and_tty_in_one_revision() {
        let mux = test_mux();
        let source_workspace_uuid = WorkspaceUuid::new();
        let target_workspace_uuid = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        let source =
            mux.ensure_terminal(ensure_request(source_workspace_uuid, surface_uuid, "")).unwrap();
        mux.ensure_terminal(ensure_request(target_workspace_uuid, SurfaceUuid::new(), "")).unwrap();
        let before_surface = mux.surface(source.surface).unwrap();
        let before_pid = before_surface.process_id();
        let before_tty = before_surface.tty_name();
        let before_argv = before_surface.spawn_argv();
        let before_revisions = mux.topology_revisions();

        let moved = mux.reparent_terminal(surface_uuid, target_workspace_uuid).unwrap();
        let after_surface = mux.surface(source.surface).unwrap();

        assert!(moved.moved);
        assert_eq!(moved.workspace_uuid, target_workspace_uuid);
        assert_eq!(moved.surface_uuid, surface_uuid);
        assert!(Arc::ptr_eq(&before_surface, &after_surface));
        assert_eq!(after_surface.process_id(), before_pid);
        assert_eq!(after_surface.tty_name(), before_tty);
        assert_eq!(after_surface.spawn_argv(), before_argv);
        assert_eq!(mux.topology_revisions(), (before_revisions.0 + 1, before_revisions.1 + 1));

        let after_revisions = mux.topology_revisions();
        let retry = mux.reparent_terminal(surface_uuid, target_workspace_uuid).unwrap();
        assert!(!retry.moved);
        assert_eq!(retry, ReparentTerminalPlacement { moved: false, ..moved });
        assert_eq!(mux.topology_revisions(), after_revisions);
    }

    #[test]
    fn reparent_terminal_rejects_unknown_and_nonterminal_identities() {
        let mux = test_mux();
        let target_workspace_uuid = WorkspaceUuid::new();
        mux.ensure_terminal(ensure_request(target_workspace_uuid, SurfaceUuid::new(), "")).unwrap();

        assert!(
            mux.reparent_terminal(SurfaceUuid::new(), target_workspace_uuid)
                .unwrap_err()
                .to_string()
                .contains("unknown terminal surface")
        );
        let terminal_uuid = SurfaceUuid::new();
        mux.ensure_terminal(ensure_request(WorkspaceUuid::new(), terminal_uuid, "")).unwrap();
        assert!(
            mux.reparent_terminal(terminal_uuid, WorkspaceUuid::new())
                .unwrap_err()
                .to_string()
                .contains("unknown target workspace")
        );

        let browser = mux.new_browser_tab("about:blank".to_owned(), None, None).unwrap();
        assert!(
            mux.reparent_terminal(browser.uuid, target_workspace_uuid)
                .unwrap_err()
                .to_string()
                .contains("is not a terminal")
        );
    }
}
