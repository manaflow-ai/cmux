//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

use std::collections::{HashMap, HashSet};
#[cfg(test)]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::browser::{self, BrowserBootstrap, BrowserRuntime};
use crate::event_bus::{MuxEventBroadcaster, MuxEventReceiver};
use crate::layout::{Rect, layout_screen};
use crate::model::{Node, Pane, Screen, State, Workspace};
use crate::pairing::PairingBroker;
use crate::surface::{DefaultColors, Surface, SurfaceOptions};
use crate::{
    PairingChallenge, PairingDecision, PairingError, PaneId, ScreenId, SplitDir, SplitId,
    SurfaceId, WorkspaceId,
};

pub type SurfaceResizeReporter = Arc<dyn Fn(SurfaceId, (u16, u16), Option<u64>) + Send + Sync>;

const TERMINAL_DIMENSION_MAX: u16 = 10_000;
const WORKSPACE_REGISTRY_LIMIT: usize = 4_096;
const WORKSPACE_KEY_MAX_BYTES: usize = 256;
const WORKSPACE_NAME_MAX_BYTES: usize = 1_024;

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
    /// A surface's child exited. The mux has already reaped it from the
    /// tree (a tree-changed follows) by the time this arrives.
    SurfaceExited(SurfaceId),
    TitleChanged {
        surface: SurfaceId,
        title: Arc<str>,
    },
    Bell(SurfaceId),
    Notification(NotificationEvent),
    Status(String),
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
    /// Delta subscribers need a coarse snapshot resync for a selection-only change.
    TreeSelectionChanged,
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
    WorkspaceMoved,
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
            Self::WorkspaceMoved => "workspace-moved",
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
    /// Present for ordered workspace-registry mutations. Consumers can apply
    /// only the exact next revision and refetch after a gap.
    pub workspace_revision: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationLevel {
    Info,
    Warning,
    Error,
}

impl NotificationLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            NotificationLevel::Info => "info",
            NotificationLevel::Warning => "warning",
            NotificationLevel::Error => "error",
        }
    }
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
    Stack { pane_count: usize, expanded_index: usize },
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspacePlacement {
    pub workspace: WorkspaceId,
    pub key: String,
    pub index: usize,
    pub revision: u64,
}

#[derive(Clone, Copy)]
enum TreeCloseTarget {
    Pane(PaneId),
    Screen(ScreenId),
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
type AppliedClientSize = (SurfaceResizeAcceptance, Option<(u16, u16)>, ClientSizeRollback);
type SurfaceResizeOutcome = Result<(), Arc<str>>;
type SurfaceResizeCompletion = SyncSender<SurfaceResizeOutcome>;

struct PendingWorkspaceSurface<'a> {
    pending: &'a Mutex<HashMap<SurfaceId, WorkspaceId>>,
    surface: SurfaceId,
}

impl Drop for PendingWorkspaceSurface<'_> {
    fn drop(&mut self) {
        self.pending.lock().unwrap().remove(&self.surface);
    }
}

enum SurfaceResizeRestore {
    Complete(bool),
    Pending(Receiver<SurfaceResizeOutcome>),
}

#[derive(PartialEq, Eq)]
struct ClientSizingRollbackToken {
    surface_sizes: Option<HashMap<u64, (u16, u16)>>,
    surface_orders: HashMap<u64, u64>,
    participating_surface_clients: HashSet<u64>,
    uses_excluded_fallback: bool,
}

#[derive(Clone, Copy)]
pub(crate) struct ClientSizeRollback {
    pub(crate) previous_size: Option<(u16, u16)>,
    pub(crate) previous_report_order: Option<u64>,
    pub(crate) previous_geometry: Option<(u16, u16)>,
    pub(crate) applied_report_order: u64,
}

pub(crate) struct ControlClientResize {
    pub accepted: bool,
    pub reservation_id: Option<u64>,
    pub effective_size: Option<(u16, u16)>,
    pub attached: Option<crate::server::ClientSizeUpdate>,
    pub rollback: ClientSizeRollback,
}

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
    fn rollback_token(
        &self,
        surface: SurfaceId,
        attached_clients: &HashSet<u64>,
    ) -> ClientSizingRollbackToken {
        let participating_surface_clients = self
            .surfaces
            .get(&surface)
            .into_iter()
            .flat_map(HashMap::keys)
            .filter(|client| self.client_participates(**client))
            .copied()
            .collect();
        ClientSizingRollbackToken {
            surface_sizes: self.surfaces.get(&surface).cloned(),
            surface_orders: self
                .report_order
                .iter()
                .filter_map(|((reported_surface, client), order)| {
                    (*reported_surface == surface).then_some((*client, *order))
                })
                .collect(),
            participating_surface_clients,
            uses_excluded_fallback: self.uses_excluded_fallback(attached_clients),
        }
    }

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

/// The multiplexer. Shared by frontends and the control socket server.
pub struct Mux {
    state: Mutex<State>,
    subscribers: MuxEventBroadcaster,
    next_id: AtomicU64,
    next_notification_id: AtomicU64,
    next_active_at: AtomicU64,
    surface_options: Mutex<SurfaceOptions>,
    latest_client_size: Mutex<LatestClientSize>,
    workspace_lifecycles: Mutex<HashMap<WorkspaceId, Weak<Mutex<()>>>>,
    pending_workspace_surfaces: Mutex<HashMap<SurfaceId, WorkspaceId>>,
    client_sizing_lifecycle: Mutex<()>,
    client_sizing: Mutex<ClientSizingState>,
    #[cfg(test)]
    client_resize_before_apply: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    client_rollback_before_wait: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    workspace_close_before_empty_check: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    workspace_close_after_selector_resolution: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    layout_apply_after_workspace_reservation: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    terminal_create_after_empty_check: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    terminal_create_after_materialization_lock: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    terminal_create_after_workspace_reservation: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    browser_runtime: Mutex<Option<Arc<BrowserRuntime>>>,
    cell_pixels: Mutex<(u16, u16)>,
    default_colors: Mutex<DefaultColors>,
    sidebar_plugin: Mutex<SidebarPluginRuntime>,
    agent_records: Mutex<HashMap<SurfaceId, AgentRecord>>,
    surface_notifications: Mutex<HashMap<SurfaceId, SurfaceNotification>>,
    pub(crate) control_clients: crate::server::ClientRegistry,
    pairing: PairingBroker,
    #[cfg(test)]
    test_surface_runtime: bool,
    pub session: String,
}

impl Mux {
    pub fn new(session: impl Into<String>, surface_options: SurfaceOptions) -> Arc<Self> {
        Self::new_with_test_surface_runtime(session, surface_options, false)
    }

    fn new_with_test_surface_runtime(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> Arc<Self> {
        let session = session.into();
        let mut surface_options = surface_options;
        surface_options.browser_session_name = session.clone();
        Arc::new(Mux {
            state: Mutex::new(State {
                workspaces: Vec::new(),
                workspace_index_by_id: HashMap::new(),
                workspace_id_by_key: HashMap::new(),
                workspace_revision: 0,
                pane_revision: 0,
                focus_sequence: 0,
                active_workspace: 0,
                panes: HashMap::new(),
                surfaces: HashMap::new(),
                split_screens: HashMap::new(),
            }),
            subscribers: MuxEventBroadcaster::default(),
            next_id: AtomicU64::new(1),
            next_notification_id: AtomicU64::new(1),
            next_active_at: AtomicU64::new(1),
            surface_options: Mutex::new(surface_options),
            latest_client_size: Mutex::new(LatestClientSize::default()),
            workspace_lifecycles: Mutex::new(HashMap::new()),
            pending_workspace_surfaces: Mutex::new(HashMap::new()),
            client_sizing_lifecycle: Mutex::new(()),
            client_sizing: Mutex::new(ClientSizingState::default()),
            #[cfg(test)]
            client_resize_before_apply: Mutex::new(None),
            #[cfg(test)]
            client_rollback_before_wait: Mutex::new(None),
            #[cfg(test)]
            workspace_close_before_empty_check: Mutex::new(None),
            #[cfg(test)]
            workspace_close_after_selector_resolution: Mutex::new(None),
            #[cfg(test)]
            layout_apply_after_workspace_reservation: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_empty_check: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_materialization_lock: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_workspace_reservation: Mutex::new(None),
            browser_runtime: Mutex::new(None),
            cell_pixels: Mutex::new((8, 16)),
            default_colors: Mutex::new(DefaultColors::default()),
            sidebar_plugin: Mutex::new(SidebarPluginRuntime::default()),
            agent_records: Mutex::new(HashMap::new()),
            surface_notifications: Mutex::new(HashMap::new()),
            control_clients: crate::server::ClientRegistry::new(),
            pairing: PairingBroker::new(),
            #[cfg(test)]
            test_surface_runtime,
            session,
        })
    }

    #[cfg(test)]
    pub(crate) fn new_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(session, surface_options, true)
    }

    fn next_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    fn next_active_at(&self) -> u64 {
        self.next_active_at.fetch_add(1, Ordering::Relaxed)
    }

    fn next_notification_id(&self) -> u64 {
        self.next_notification_id.fetch_add(1, Ordering::Relaxed)
    }

    fn new_workspace_key() -> anyhow::Result<String> {
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|_| {
            anyhow::anyhow!(
                "could not create workspace identity; retry, then restart cmux if the problem continues"
            )
        })?;
        // RFC 9562 UUIDv4 version and variant bits. Keeping the formatter
        // local avoids making stable workspace identity depend on a UUID
        // library at the protocol boundary.
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        Ok(format!(
            "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
    }

    fn validate_workspace_key(key: &str) -> anyhow::Result<()> {
        if key.trim().is_empty() {
            anyhow::bail!("workspace key cannot be empty");
        }
        if key.len() > WORKSPACE_KEY_MAX_BYTES {
            anyhow::bail!("workspace key exceeds {WORKSPACE_KEY_MAX_BYTES} bytes");
        }
        Ok(())
    }

    fn validate_workspace_name(name: &str) -> anyhow::Result<()> {
        if name.len() > WORKSPACE_NAME_MAX_BYTES {
            anyhow::bail!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes");
        }
        Ok(())
    }

    fn workspace_lifecycle(&self, workspace: WorkspaceId) -> Arc<Mutex<()>> {
        let mut lifecycles = self.workspace_lifecycles.lock().unwrap();
        lifecycles.retain(|_, lifecycle| lifecycle.strong_count() > 0);
        if let Some(lifecycle) = lifecycles.get(&workspace).and_then(Weak::upgrade) {
            return lifecycle;
        }
        let lifecycle = Arc::new(Mutex::new(()));
        lifecycles.insert(workspace, Arc::downgrade(&lifecycle));
        lifecycle
    }

    fn pending_workspace_surface(&self, surface: SurfaceId) -> PendingWorkspaceSurface<'_> {
        PendingWorkspaceSurface { pending: &self.pending_workspace_surfaces, surface }
    }

    fn workspace_for_surface_in_state(state: &State, surface: SurfaceId) -> Option<WorkspaceId> {
        let pane = state.pane_of(surface)?;
        let (workspace, _) = state.screen_of(pane)?;
        Some(state.workspaces[workspace].id)
    }

    fn workspace_for_tree_target_in_state(
        state: &State,
        target: TreeCloseTarget,
    ) -> Option<WorkspaceId> {
        match target {
            TreeCloseTarget::Pane(pane) => {
                let (workspace, _) = state.screen_of(pane)?;
                Some(state.workspaces[workspace].id)
            }
            TreeCloseTarget::Screen(screen) => state
                .workspaces
                .iter()
                .find(|workspace| workspace.screens.iter().any(|candidate| candidate.id == screen))
                .map(|workspace| workspace.id),
        }
    }

    fn surface_workspace(&self, surface: SurfaceId) -> Option<WorkspaceId> {
        self.pending_workspace_surfaces.lock().unwrap().get(&surface).copied().or_else(|| {
            let state = self.state.lock().unwrap();
            Self::workspace_for_surface_in_state(&state, surface)
        })
    }

    fn require_workspace_revision(state: &State, expected: Option<u64>) -> anyhow::Result<()> {
        if let Some(expected) = expected
            && expected != state.workspace_revision
        {
            anyhow::bail!(
                "workspace revision conflict: expected {expected}, current {}",
                state.workspace_revision
            );
        }
        Ok(())
    }

    fn resolve_workspace_selector(
        state: &State,
        id: Option<WorkspaceId>,
        key: Option<&str>,
    ) -> anyhow::Result<Option<(WorkspaceId, String)>> {
        let by_id = id.and_then(|id| state.workspace_by_id(id));
        let by_key = key.and_then(|key| state.workspace_by_key(key));
        let workspace = match (id, key, by_id, by_key) {
            (None, None, _, _) => anyhow::bail!("workspace or key is required"),
            (Some(id), None, Some(workspace), _) if workspace.id == id => Some(workspace),
            (Some(_), None, None, _) => None,
            (None, Some(key), _, Some(workspace)) if workspace.key == key => Some(workspace),
            (None, Some(_), _, None) => None,
            (Some(_), Some(_), Some(by_id), Some(by_key)) if by_id.id == by_key.id => Some(by_id),
            (Some(_), Some(_), _, _) => {
                anyhow::bail!("workspace id and key do not identify the same workspace")
            }
            _ => unreachable!("workspace selector cases are exhaustive"),
        };
        Ok(workspace.map(|workspace| (workspace.id, workspace.key.clone())))
    }

    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribers.subscribe()
    }

    pub fn subscribe_attached_surface(&self, surface: SurfaceId) -> MuxEventReceiver {
        self.subscribers.subscribe_attached_surface(surface)
    }

    pub fn emit(&self, event: MuxEvent) {
        self.subscribers.emit(event);
    }

    fn emit_tree_delta(&self, delta: TreeDelta, selection_resync: bool) {
        self.emit(MuxEvent::TreeDelta(delta));
        if selection_resync {
            self.emit(MuxEvent::TreeSelectionChanged);
        }
    }

    fn emit_empty_if_current(&self, workspace_revision: Option<u64>) {
        let Some(workspace_revision) = workspace_revision else { return };
        #[cfg(test)]
        let before_empty_check = self.workspace_close_before_empty_check.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_empty_check {
            hook();
        }
        let state = self.state.lock().unwrap();
        if state.workspaces.is_empty() && state.workspace_revision == workspace_revision {
            self.emit(MuxEvent::Empty);
        }
    }

    fn rebuild_split_screen_index(state: &mut State) {
        fn index_node(
            node: &Node,
            workspace_index: usize,
            screen_index: usize,
            screen: ScreenId,
            index: &mut HashMap<SplitId, (usize, usize, ScreenId)>,
        ) {
            if let Node::Split { id, a, b, .. } = node {
                index.insert(*id, (workspace_index, screen_index, screen));
                index_node(a, workspace_index, screen_index, screen, index);
                index_node(b, workspace_index, screen_index, screen, index);
            }
        }

        let mut index = HashMap::new();
        for (workspace_index, workspace) in state.workspaces.iter().enumerate() {
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                index_node(&screen.root, workspace_index, screen_index, screen.id, &mut index);
            }
        }
        state.split_screens = index;
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

    fn spawn_surface_with_command(
        self: &Arc<Self>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        command: Option<Vec<String>>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.spawn_surface_with(cwd, command, size, None)
    }

    fn spawn_surface_with(
        self: &Arc<Self>,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
        pending_workspace: Option<WorkspaceId>,
    ) -> anyhow::Result<Arc<Surface>> {
        let id = self.next_id();
        if let Some(workspace) = pending_workspace {
            self.pending_workspace_surfaces.lock().unwrap().insert(id, workspace);
        }
        let mut opts = self.surface_options.lock().unwrap().clone();
        if cwd.is_some() {
            opts.cwd = cwd;
        }
        if command.is_some() {
            opts.command = command;
        }
        // Spawn at the latest client-owned size: starting at the default
        // 80x24 and resizing a frame later makes shells emit artifacts
        // (e.g. zsh's reverse-video %% partial-line marker).
        let (cols, rows) = self.resolve_client_size(size, (opts.cols, opts.rows));
        opts.cols = cols;
        opts.rows = rows;
        #[cfg(test)]
        let surface = if self.test_surface_runtime {
            Surface::spawn_for_test(id, opts, Arc::downgrade(self))
        } else {
            Surface::spawn(id, opts, Arc::downgrade(self))
        };
        #[cfg(not(test))]
        let surface = Surface::spawn(id, opts, Arc::downgrade(self));
        let surface = match surface {
            Ok(surface) => surface,
            Err(error) => {
                self.pending_workspace_surfaces.lock().unwrap().remove(&id);
                return Err(error);
            }
        };
        self.state.lock().unwrap().surfaces.insert(id, surface.clone());
        Ok(surface)
    }

    fn spawn_surface(
        self: &Arc<Self>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.spawn_surface_with_command(cwd, size, None)
    }

    fn spawn_sidebar_plugin_surface(
        self: &Arc<Self>,
        options: &SidebarPluginOptions,
        size: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        if options.command.is_empty() {
            anyhow::bail!("sidebar plugin command is empty");
        }
        let id = self.next_id();
        let mut opts = self.surface_options.lock().unwrap().clone();
        opts.command = Some(options.command.clone());
        opts.cwd = options.cwd.clone();
        opts.cols = size.0.max(1);
        opts.rows = size.1.max(1);
        opts.extra_env.push(("CMUX_SIDEBAR".to_string(), "1".to_string()));
        #[cfg(test)]
        let surface = if self.test_surface_runtime {
            Surface::spawn_for_test(id, opts, Arc::downgrade(self))?
        } else {
            Surface::spawn(id, opts, Arc::downgrade(self))?
        };
        #[cfg(not(test))]
        let surface = Surface::spawn(id, opts, Arc::downgrade(self))?;
        self.state.lock().unwrap().surfaces.insert(id, surface.clone());
        Ok(surface)
    }

    fn spawn_browser_surface(
        self: &Arc<Self>,
        url: String,
        size: Option<(u16, u16)>,
        pending_workspace: Option<WorkspaceId>,
    ) -> Arc<Surface> {
        let id = self.next_id();
        if let Some(workspace) = pending_workspace {
            self.pending_workspace_surfaces.lock().unwrap().insert(id, workspace);
        }
        let opts = self.surface_options.lock().unwrap().clone();
        let size = self.resolve_client_size(size, (opts.cols, opts.rows));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let surface =
            browser::new_surface(id, url.clone(), size, cell_pixels, &opts, Arc::downgrade(self));
        self.state.lock().unwrap().surfaces.insert(id, surface.clone());
        self.start_browser_bootstrap(surface.clone(), BrowserBootstrap::Create { url }, None);
        surface
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
            None,
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
    ) -> anyhow::Result<ControlClientResize> {
        self.resize_surface_for_control_client_with_completion(id, client, cols, rows, None)
    }

    pub(crate) fn resize_surface_for_control_client_with_completion(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
        completion: Option<SurfaceResizeCompletion>,
    ) -> anyhow::Result<ControlClientResize> {
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
            completion,
        );
        if result.is_err()
            && let Some((_, _, _, previous)) = attached.as_ref()
        {
            self.control_clients.restore_size(client, id, *previous);
        }
        let result = result?;
        self.control_clients.set_report_order(client, id, result.2.applied_report_order);
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
        Ok(ControlClientResize {
            accepted: result.0.0,
            reservation_id: result.0.1,
            effective_size: result.1,
            attached,
            rollback: result.2,
        })
    }

    fn resize_surface_for_client_locked(
        &self,
        sizing: &mut ClientSizingState,
        attached_clients: &HashSet<u64>,
        id: SurfaceId,
        client: u64,
        requested: (u16, u16),
        completion: Option<SurfaceResizeCompletion>,
    ) -> anyhow::Result<AppliedClientSize> {
        let previous_geometry = self.surface(id).map(|surface| surface.size());
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
            return Ok((
                (false, None),
                None,
                ClientSizeRollback {
                    previous_size: previous,
                    previous_report_order: previous_order,
                    previous_geometry,
                    applied_report_order: report_order,
                },
            ));
        };
        #[cfg(test)]
        let before_apply = self.client_resize_before_apply.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_apply {
            hook();
        }
        match self.resize_surface_with_completion(id, effective.0, effective.1, completion) {
            Ok(changed) => Ok((
                changed,
                Some(effective),
                ClientSizeRollback {
                    previous_size: previous,
                    previous_report_order: previous_order,
                    previous_geometry,
                    applied_report_order: report_order,
                },
            )),
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

    pub(crate) fn rollback_surface_size_client(
        &self,
        id: SurfaceId,
        client: u64,
        rollback: ClientSizeRollback,
    ) {
        let lifecycle = self.lock_client_sizing_lifecycle();
        if !self.control_clients.contains(client) {
            return;
        }
        let mut sizing = self.client_sizing.lock().unwrap();
        let current_size =
            sizing.surfaces.get(&id).and_then(|viewers| viewers.get(&client).copied());
        let current_report_order = sizing.report_order.get(&(id, client)).copied();
        if current_report_order != Some(rollback.applied_report_order) {
            return;
        }
        self.control_clients.restore_size_and_report_order(
            client,
            id,
            rollback.previous_size,
            rollback.previous_report_order,
        );
        match rollback.previous_size {
            Some(size) => {
                sizing.surfaces.entry(id).or_default().insert(client, size);
            }
            None => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    viewers.remove(&client);
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
            }
        }
        match rollback.previous_report_order {
            Some(order) => {
                sizing.report_order.insert((id, client), order);
            }
            None => {
                sizing.report_order.remove(&(id, client));
            }
        }
        let attached_clients = self.control_clients.attached_client_ids();
        let use_excluded = sizing.uses_excluded_fallback(&attached_clients);
        let desired_geometry =
            sizing.effective_size(id, use_excluded).or(rollback.previous_geometry);
        let restore =
            desired_geometry.map_or(SurfaceResizeRestore::Complete(true), |(cols, rows)| {
                let (completion, completed) = std::sync::mpsc::sync_channel(1);
                match self.resize_surface_with_completion(id, cols, rows, Some(completion)) {
                    Ok((true, Some(_))) => SurfaceResizeRestore::Pending(completed),
                    Ok((_, _)) => match self.surface(id) {
                        Some(surface) if surface.size() == (cols, rows) => {
                            SurfaceResizeRestore::Complete(true)
                        }
                        Some(surface) => match surface.pending_resize_completion(cols, rows) {
                            Ok(Some(pending)) => SurfaceResizeRestore::Pending(pending.completion),
                            Ok(None) | Err(_) => SurfaceResizeRestore::Complete(false),
                        },
                        None => SurfaceResizeRestore::Complete(false),
                    },
                    Err(_) => SurfaceResizeRestore::Complete(false),
                }
            });
        let rollback_token = sizing.rollback_token(id, &attached_clients);
        self.reconcile_latest_client_size(&sizing, &attached_clients);
        drop(sizing);
        drop(lifecycle);

        #[cfg(test)]
        if let Some(hook) = self.client_rollback_before_wait.lock().unwrap().clone() {
            hook();
        }

        let restoration_failed = match restore {
            SurfaceResizeRestore::Complete(restored) => !restored,
            SurfaceResizeRestore::Pending(completion) => {
                match completion.recv_timeout(Duration::from_secs(10)) {
                    Ok(Ok(())) => false,
                    Ok(Err(_)) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => true,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        // The rolled-back registry remains authoritative while
                        // the compensating browser reservation stays queued.
                        // Do not reinstall the failed attach's claim before the
                        // browser worker reaches a terminal outcome, and do not
                        // retain the connection or another blocking waiter.
                        return;
                    }
                }
            }
        };
        if restoration_failed {
            self.reconcile_failed_surface_size_rollback(
                id,
                client,
                current_size,
                current_report_order,
                rollback_token,
            );
        }
    }

    fn reconcile_failed_surface_size_rollback(
        &self,
        id: SurfaceId,
        client: u64,
        current_size: Option<(u16, u16)>,
        current_report_order: Option<u64>,
        rollback_token: ClientSizingRollbackToken,
    ) {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        if !self.control_clients.contains(client) {
            return;
        }
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids();
        if sizing.rollback_token(id, &attached_clients) != rollback_token {
            return;
        }
        // The failed attach already changed the real surface geometry. If
        // restoration fails, retain the pre-rollback report only when no
        // newer sizing mutation superseded this rollback while it was pending.
        self.control_clients.restore_size_and_report_order(
            client,
            id,
            current_size,
            current_report_order,
        );
        match current_size {
            Some(size) => {
                sizing.surfaces.entry(id).or_default().insert(client, size);
            }
            None => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    viewers.remove(&client);
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
            }
        }
        match current_report_order {
            Some(order) => {
                sizing.report_order.insert((id, client), order);
            }
            None => {
                sizing.report_order.remove(&(id, client));
            }
        }
        self.reconcile_latest_client_size(&sizing, &attached_clients);
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

    #[cfg(test)]
    pub(crate) fn set_client_rollback_before_wait(
        &self,
        hook: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.client_rollback_before_wait.lock().unwrap() = hook;
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
        let id = self.next_id();
        let active_at = self.next_active_at();
        (id, Pane { id, name: None, tabs: vec![surface], active_tab: 0, active_at, focused_at: 0 })
    }

    pub fn surface(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().surfaces.get(&id).cloned()
    }

    #[cfg(test)]
    pub(crate) fn remove_surface_runtime_for_test(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().surfaces.remove(&id)
    }

    /// Run `f` with the session state.
    ///
    /// The state lock is held for the duration of `f`; do not call back
    /// into `Mux` methods that take it (`surface()`, `close_pane()`, ...).
    pub fn with_state<R>(&self, f: impl FnOnce(&State) -> R) -> R {
        f(&self.state.lock().unwrap())
    }

    pub fn surface_count(&self) -> usize {
        self.state.lock().unwrap().surfaces.len()
    }

    pub fn surface_notification(&self, surface: SurfaceId) -> Option<SurfaceNotification> {
        self.surface_notifications.lock().unwrap().get(&surface).copied()
    }

    pub fn surface_notifications(&self) -> HashMap<SurfaceId, SurfaceNotification> {
        self.surface_notifications.lock().unwrap().clone()
    }

    pub fn clear_surface_notification(&self, surface: SurfaceId) -> bool {
        let cleared = self.surface_notifications.lock().unwrap().remove(&surface).is_some();
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
        if let Some(surface) = surface {
            let _ = self.surface_notifications.lock().unwrap().remove(&surface);
        }
    }

    pub fn post_notification(
        &self,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
    ) -> u64 {
        let id = self.next_notification_id();
        let mut unread_changed = false;
        if let Some(surface) = surface
            && self.active_surface() != Some(surface)
        {
            self.surface_notifications
                .lock()
                .unwrap()
                .insert(surface, SurfaceNotification { notification: id, level, unread: true });
            unread_changed = true;
        }
        self.emit(MuxEvent::Notification(NotificationEvent {
            notification: id,
            title,
            body,
            level,
            surface,
        }));
        if unread_changed {
            self.emit(MuxEvent::TreeChanged);
        }
        id
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
        self.surface_notifications.lock().unwrap().remove(&surface);
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
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            surface.kill();
        }
        if let Some(runtime) = self.browser_runtime.lock().unwrap().take() {
            runtime.shutdown();
        }
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
            old_surface.and_then(|id| self.state.lock().unwrap().surfaces.remove(&id))
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
        *self.default_colors.lock().unwrap()
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        {
            let mut current = self.default_colors.lock().unwrap();
            if *current == colors {
                return;
            }
            *current = colors;
        }
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit(MuxEvent::SurfaceOutput(surface.id));
        }
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
        self.resize_surface_with_completion(id, cols, rows, None)
    }

    fn resize_surface_with_completion(
        &self,
        id: SurfaceId,
        cols: u16,
        rows: u16,
        completion: Option<SurfaceResizeCompletion>,
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
                surface.resize_reporting_completion(cols, rows, Box::new(|_| {}), completion)?;
            return Ok((reservation_id.is_some(), reservation_id));
        }
        if !surface.resize(cols, rows)? {
            if let Some(completion) = completion {
                let _ = completion.send(Ok(()));
            }
            return Ok((false, None));
        }
        if let Some(completion) = completion {
            let _ = completion.send(Ok(()));
        }
        let (cols, rows) = surface.size();
        self.emit(MuxEvent::SurfaceResized { surface: id, cols, rows, reservation_id: None });
        Ok((true, None))
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
        let workspace_key = Self::new_workspace_key()?;
        let surface = self.spawn_surface(None, size)?;
        let (pane_id, pane) = self.make_pane(surface.id);
        let screen_id = self.next_id();
        let ws_id = self.next_id();
        let notifications = self.surface_notifications();
        let delta = {
            let mut state = self.state.lock().unwrap();
            let name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            state.insert_pane(pane);
            stamp_pane_focus(self, &mut state, pane_id);
            state.push_workspace(Workspace {
                id: ws_id,
                key: workspace_key,
                name,
                screens: vec![Screen {
                    id: screen_id,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                    zellij_auto_layout: Some(vec![pane_id]),
                }],
                active_screen: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
            state.workspace_revision = state.workspace_revision.saturating_add(1);
            let workspace_revision = state.workspace_revision;
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
                workspace_revision: Some(workspace_revision),
            }
        };
        let selection_resync = delta.index.is_some_and(|index| index > 0);
        self.emit_tree_delta(delta, selection_resync);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Add an ordered workspace-registry entry without creating a PTY,
    /// screen, or pane. Detached GUI frontends use this when a user creates
    /// an empty workspace in Chrome.
    pub fn create_empty_workspace(
        &self,
        name: Option<String>,
        key: Option<String>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<WorkspacePlacement> {
        if let Some(name) = name.as_deref() {
            Self::validate_workspace_name(name)?;
        }
        let key = key.map_or_else(Self::new_workspace_key, Ok)?;
        Self::validate_workspace_key(&key)?;
        let notifications = self.surface_notifications();
        let (placement, delta, selection_resync) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            if state.workspaces.len() >= WORKSPACE_REGISTRY_LIMIT {
                anyhow::bail!("workspace limit reached ({WORKSPACE_REGISTRY_LIMIT})");
            }
            if state.workspace_by_key(&key).is_some() {
                anyhow::bail!("workspace key already exists: {key}");
            }
            let ws_id = self.next_id();
            let name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            let selection_resync = !state.workspaces.is_empty();
            state.push_workspace(Workspace {
                id: ws_id,
                key: key.clone(),
                name,
                screens: Vec::new(),
                active_screen: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
            state.workspace_revision = state.workspace_revision.saturating_add(1);
            let index = state.workspaces.len() - 1;
            let revision = state.workspace_revision;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceAdded,
                ws_id,
            )
            .expect("new empty workspace is present in tree snapshot");
            (
                WorkspacePlacement { workspace: ws_id, key, index, revision },
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceAdded,
                    workspace: ws_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                    workspace_revision: Some(revision),
                },
                selection_resync,
            )
        };
        self.emit_tree_delta(delta, selection_resync);
        Ok(placement)
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
            let workspace_key = Self::new_workspace_key()?;
            let surface = self.spawn_surface_with_command(cwd, size, Some(argv))?;
            if let Some(name) = name.as_ref() {
                surface.set_name(Some(name.clone()));
            }
            let (pane_id, pane) = self.make_pane(surface.id);
            let screen_id = self.next_id();
            let ws_id = self.next_id();
            let notifications = self.surface_notifications();
            let delta = {
                let mut state = self.state.lock().unwrap();
                let workspace_name =
                    name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
                state.insert_pane(pane);
                stamp_pane_focus(self, &mut state, pane_id);
                state.push_workspace(Workspace {
                    id: ws_id,
                    key: workspace_key,
                    name: workspace_name,
                    screens: vec![Screen {
                        id: screen_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        zellij_auto_layout: Some(vec![pane_id]),
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                state.workspace_revision = state.workspace_revision.saturating_add(1);
                let workspace_revision = state.workspace_revision;
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
                    workspace_revision: Some(workspace_revision),
                }
            };
            let selection_resync = delta.index.is_some_and(|index| index > 0);
            self.emit_tree_delta(delta, selection_resync);
            self.reap_if_dead(&surface);
            return Ok(RunPlacement {
                surface: surface.id,
                pane: pane_id,
                screen: screen_id,
                workspace: ws_id,
            });
        }

        let (target, empty_workspace) = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            let empty_workspace = target.is_none().then(|| {
                state
                    .workspaces
                    .get(state.active_workspace)
                    .filter(|workspace| workspace.screens.is_empty())
                    .map(|workspace| workspace.id)
            });
            (target, empty_workspace.flatten())
        };
        let Some(target) = target else {
            if let Some(workspace) = empty_workspace {
                return self.create_terminal_in_workspace(workspace, Some(argv), cwd, name, size);
            }
            return self.run_command_surface(argv, None, true, cwd, name, size);
        };

        let cwd = cwd.or_else(|| self.pane_cwd(target));
        let surface = self.spawn_surface_with_command(cwd, size, Some(argv))?;
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        let active_at = self.next_active_at();
        let notifications = self.surface_notifications();
        let (placement, delta) = {
            let mut state = self.state.lock().unwrap();
            let Some((wi, si)) = state.screen_of(target) else {
                state.surfaces.remove(&surface.id);
                surface.kill();
                anyhow::bail!("pane disappeared while creating tab");
            };
            let Some(pane) = state.panes.get_mut(&target) else {
                state.surfaces.remove(&surface.id);
                surface.kill();
                anyhow::bail!("pane disappeared while creating tab");
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
                workspace_revision: None,
            };
            (placement, delta)
        };
        self.emit_tree_delta(delta, true);
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
        self.new_screen_with_cwd(workspace, None, size)
    }

    fn new_screen_with_cwd(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        cwd: Option<String>,
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
        let surface = self.spawn_surface(cwd, size)?;
        let (pane_id, pane) = self.make_pane(surface.id);
        let screen_id = self.next_id();
        let notifications = self.surface_notifications();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let ws = match workspace {
                Some(id) => state.workspaces.iter_mut().find(|w| w.id == id),
                None => state.workspaces.get_mut(active),
            };
            match ws {
                Some(ws) => {
                    ws.screens.push(Screen {
                        id: screen_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        zellij_auto_layout: Some(vec![pane_id]),
                    });
                    ws.active_screen = ws.screens.len() - 1;
                    let workspace = ws.id;
                    let index = ws.screens.len() - 1;
                    state.insert_pane(pane);
                    stamp_pane_focus(self, &mut state, pane_id);
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
                        workspace_revision: None,
                    })
                }
                None => {
                    state.surfaces.remove(&surface.id);
                    None
                }
            }
        };
        let Some(delta) = attached else {
            surface.kill();
            anyhow::bail!("workspace disappeared while creating screen");
        };
        self.emit_tree_delta(delta, true);
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
        // Resolve and validate the target before spawning a child.
        let (target, empty_workspace) = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            let empty_workspace = target
                .is_none()
                .then(|| state.workspaces.get(state.active_workspace))
                .flatten()
                .filter(|workspace| workspace.screens.is_empty())
                .map(|workspace| workspace.id);
            (target, empty_workspace)
        };
        let Some(target) = target else {
            if let Some(workspace) = empty_workspace {
                return self
                    .create_terminal_surface_in_workspace(workspace, None, cwd, None, size)
                    .map(|(surface, _)| surface);
            }
            return self.new_workspace(None, size);
        };

        let cwd = cwd.or_else(|| self.pane_cwd(target));
        let surface = self.spawn_surface(cwd, size)?;
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
                        workspace_revision: None,
                    })
                }
                None => {
                    // Pane disappeared between validation and attach.
                    state.surfaces.remove(&surface.id);
                    None
                }
            }
        };
        let Some(delta) = attached else {
            surface.kill();
            anyhow::bail!("pane disappeared while creating tab");
        };
        self.emit_tree_delta(delta, true);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Create a terminal in a specific workspace without changing the mux's
    /// active workspace. An empty workspace gets its first screen and pane;
    /// otherwise the new surface becomes a tab in that workspace's active
    /// pane. The target is re-resolved under the attach lock so concurrent
    /// first-terminal requests cannot accidentally create another workspace.
    pub fn create_terminal_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        self.create_terminal_surface_in_workspace(workspace, argv, cwd, name, size)
            .map(|(_, placement)| placement)
    }

    fn create_terminal_surface_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<(Arc<Surface>, RunPlacement)> {
        {
            let state = self.state.lock().unwrap();
            if state.workspace_by_id(workspace).is_none() {
                anyhow::bail!("unknown workspace {workspace}");
            }
        }
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_empty_check.lock().unwrap().clone() {
            hook();
        }
        let lifecycle = self.workspace_lifecycle(workspace);
        let workspace_lifecycle = lifecycle.lock().unwrap();
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_materialization_lock.lock().unwrap().clone()
        {
            hook();
        }
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_workspace_reservation.lock().unwrap().clone()
        {
            hook();
        }
        let inherited_cwd = {
            let state = self.state.lock().unwrap();
            let Some(workspace) = state.workspace_by_id(workspace) else {
                anyhow::bail!("unknown workspace {workspace}");
            };
            workspace.active_screen_ref().map(|screen| screen.active_pane)
        }
        .and_then(|pane| self.pane_cwd(pane));
        let surface =
            self.spawn_surface_with(cwd.or(inherited_cwd), argv, size, Some(workspace))?;
        let pending_surface = self.pending_workspace_surface(surface.id);
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        let notifications = self.surface_notifications();
        let active_at = self.next_active_at();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let Some(wi) = state.workspace_index(workspace) else {
                state.surfaces.remove(&surface.id);
                surface.kill();
                anyhow::bail!("workspace disappeared while creating terminal");
            };
            let target = state.workspaces[wi].active_screen_ref().map(|screen| screen.active_pane);
            if let Some(target) = target {
                let Some((_, si)) = state.screen_of(target) else {
                    state.surfaces.remove(&surface.id);
                    surface.kill();
                    anyhow::bail!("workspace active pane disappeared while creating terminal");
                };
                let Some(pane) = state.panes.get_mut(&target) else {
                    state.surfaces.remove(&surface.id);
                    surface.kill();
                    anyhow::bail!("workspace active pane disappeared while creating terminal");
                };
                pane.tabs.push(surface.id);
                pane.active_tab = pane.tabs.len() - 1;
                pane.active_at = active_at;
                let index = pane.tabs.len() - 1;
                let screen = state.workspaces[wi].screens[si].id;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::TabAdded,
                    surface.id,
                )
                .expect("new terminal tab is present in tree snapshot");
                (
                    RunPlacement { surface: surface.id, pane: target, screen, workspace },
                    TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                    },
                    true,
                )
            } else {
                let (pane_id, pane) = self.make_pane(surface.id);
                let screen_id = self.next_id();
                state.insert_pane(pane);
                stamp_pane_focus(self, &mut state, pane_id);
                state.workspaces[wi].screens.push(Screen {
                    id: screen_id,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                    zellij_auto_layout: Some(vec![pane_id]),
                });
                state.workspaces[wi].active_screen = 0;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::ScreenAdded,
                    screen_id,
                )
                .expect("first workspace screen is present in tree snapshot");
                (
                    RunPlacement {
                        surface: surface.id,
                        pane: pane_id,
                        screen: screen_id,
                        workspace,
                    },
                    TreeDelta {
                        kind: TreeDeltaKind::ScreenAdded,
                        workspace,
                        screen: Some(screen_id),
                        pane: None,
                        surface: None,
                        index: Some(0),
                        entity,
                        workspace_revision: None,
                    },
                    false,
                )
            }
        };
        drop(pending_surface);
        self.emit_tree_delta(attached.1, attached.2);
        drop(workspace_lifecycle);
        self.reap_if_dead(&surface);
        Ok((surface, attached.0))
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
        let (target, empty_workspace) = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            let empty_workspace = target
                .is_none()
                .then(|| state.workspaces.get(state.active_workspace))
                .flatten()
                .filter(|workspace| workspace.screens.is_empty())
                .map(|workspace| workspace.id);
            (target, empty_workspace)
        };
        let Some(target) = target else {
            if let Some(workspace) = empty_workspace {
                return self.create_browser_surface_in_workspace(workspace, url, size);
            }
            let workspace_key = Self::new_workspace_key()?;
            let surface = self.spawn_browser_surface(url, size, None);
            let (pane_id, pane) = self.make_pane(surface.id);
            let screen_id = self.next_id();
            let ws_id = self.next_id();
            let notifications = self.surface_notifications();
            let delta = {
                let mut state = self.state.lock().unwrap();
                let name = format!("{}", state.workspaces.len() + 1);
                state.insert_pane(pane);
                stamp_pane_focus(self, &mut state, pane_id);
                state.push_workspace(Workspace {
                    id: ws_id,
                    key: workspace_key,
                    name,
                    screens: vec![Screen {
                        id: screen_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        zellij_auto_layout: Some(vec![pane_id]),
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                state.workspace_revision = state.workspace_revision.saturating_add(1);
                let workspace_revision = state.workspace_revision;
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
                    workspace_revision: Some(workspace_revision),
                }
            };
            let selection_resync = delta.index.is_some_and(|index| index > 0);
            self.emit_tree_delta(delta, selection_resync);
            self.reap_if_dead(&surface);
            return Ok(surface);
        };

        let surface = self.spawn_browser_surface(url, size, None);
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
                        workspace_revision: None,
                    })
                }
                None => {
                    state.surfaces.remove(&surface.id);
                    None
                }
            }
        };
        let Some(delta) = attached else {
            surface.kill();
            anyhow::bail!("pane disappeared while creating browser tab");
        };
        self.emit_tree_delta(delta, true);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    fn create_browser_surface_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        url: String,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let lifecycle = self.workspace_lifecycle(workspace);
        let workspace_lifecycle = lifecycle.lock().unwrap();
        if self.state.lock().unwrap().workspace_by_id(workspace).is_none() {
            anyhow::bail!("unknown workspace {workspace}");
        }
        let surface = self.spawn_browser_surface(url, size, Some(workspace));
        let pending_surface = self.pending_workspace_surface(surface.id);
        let notifications = self.surface_notifications();
        let active_at = self.next_active_at();
        let (delta, selection_resync) = {
            let mut state = self.state.lock().unwrap();
            let Some(wi) = state.workspace_index(workspace) else {
                state.surfaces.remove(&surface.id);
                surface.kill();
                anyhow::bail!("workspace disappeared while creating browser tab");
            };
            let target = state.workspaces[wi].active_screen_ref().map(|screen| screen.active_pane);
            if let Some(target) = target {
                let Some((_, si)) = state.screen_of(target) else {
                    state.surfaces.remove(&surface.id);
                    surface.kill();
                    anyhow::bail!("workspace active pane disappeared while creating browser tab");
                };
                let Some(pane) = state.panes.get_mut(&target) else {
                    state.surfaces.remove(&surface.id);
                    surface.kill();
                    anyhow::bail!("workspace active pane disappeared while creating browser tab");
                };
                pane.tabs.push(surface.id);
                pane.active_tab = pane.tabs.len() - 1;
                pane.active_at = active_at;
                let index = pane.tabs.len() - 1;
                let screen = state.workspaces[wi].screens[si].id;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::TabAdded,
                    surface.id,
                )
                .expect("new browser tab is present in tree snapshot");
                (
                    TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                    },
                    true,
                )
            } else {
                let (pane_id, pane) = self.make_pane(surface.id);
                let screen_id = self.next_id();
                state.insert_pane(pane);
                stamp_pane_focus(self, &mut state, pane_id);
                state.workspaces[wi].screens.push(Screen {
                    id: screen_id,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                    zellij_auto_layout: Some(vec![pane_id]),
                });
                state.workspaces[wi].active_screen = 0;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::ScreenAdded,
                    screen_id,
                )
                .expect("first browser screen is present in tree snapshot");
                (
                    TreeDelta {
                        kind: TreeDeltaKind::ScreenAdded,
                        workspace,
                        screen: Some(screen_id),
                        pane: None,
                        surface: None,
                        index: Some(0),
                        entity,
                        workspace_revision: None,
                    },
                    false,
                )
            }
        };
        drop(pending_surface);
        self.emit_tree_delta(delta, selection_resync);
        drop(workspace_lifecycle);
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
        let id = self.next_id();
        let opts = self.surface_options.lock().unwrap().clone();
        let size = size.unwrap_or((opts.cols, opts.rows));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let surface =
            browser::new_surface(id, url.clone(), size, cell_pixels, &opts, Arc::downgrade(self));
        let active_at = self.next_active_at();
        match self.attach_browser_surface_to_pane_or_kill(pane_id, &surface, active_at) {
            BrowserSurfaceAttach::MissingPane => return false,
            BrowserSurfaceAttach::Attached(Some(delta)) => self.emit_tree_delta(delta, true),
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
                            workspace_revision: None,
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
        surface.and_then(|surface| surface.pwd().or_else(|| surface.spawn_cwd()))
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
        let cwd = self.pane_cwd(target);
        let surface = self.spawn_surface(cwd, size)?;
        let pane_id = self.next_id();
        let split_id = self.next_id();
        let active_at = self.next_active_at();
        let mut done = false;
        let mut changed_screen = None;
        let mut changed_workspace = None;
        let notifications = self.surface_notifications();
        let mut delta = None;
        {
            let mut state = self.state.lock().unwrap();
            'outer: for ws in state.workspaces.iter_mut() {
                for screen in ws.screens.iter_mut() {
                    if screen.root.split_leaf(target, split_id, dir, pane_id) {
                        screen.active_pane = pane_id;
                        // A directional split damages the automatic layout.
                        // The next Alt-N can establish a fresh Zellij layout
                        // from stable pane ids, but close must preserve this
                        // manual tree until then.
                        screen.zellij_auto_layout = None;
                        changed_screen = Some(screen.id);
                        changed_workspace = Some(ws.id);
                        done = true;
                        break 'outer;
                    }
                }
            }
            if done {
                state.insert_pane(Pane {
                    id: pane_id,
                    name: None,
                    tabs: vec![surface.id],
                    active_tab: 0,
                    active_at,
                    focused_at: 0,
                });
                stamp_pane_focus(self, &mut state, pane_id);
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
                    workspace_revision: None,
                });
            } else {
                state.surfaces.remove(&surface.id);
            }
            if done {
                Self::rebuild_split_screen_index(&mut state);
            }
        }
        if !done {
            surface.kill();
            anyhow::bail!("pane {target} not found");
        }
        self.emit(MuxEvent::TreeDelta(delta.expect("successful split has a tree delta")));
        if let Some(screen) = changed_screen {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Create a pane and reapply Zellij's default pane distribution to the
    /// containing screen. The screen stores creation order independently of
    /// the mutable split tree, so swaps and directional splits cannot reorder
    /// terminals when automatic layout resumes.
    pub fn new_pane(
        self: &Arc<Self>,
        target: PaneId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        if self.state.lock().unwrap().screen_of(target).is_none() {
            anyhow::bail!("unknown pane {target}");
        }
        let cwd = self.pane_cwd(target);
        let surface = self.spawn_surface(cwd, size).map_err(|error| {
            eprintln!("cmux-tui: pane PTY creation failed: {error:#}");
            anyhow::anyhow!("pane creation failed")
        })?;
        let pane_id = self.next_id();
        let active_at = self.next_active_at();
        let mut changed_screen = None;
        let mut changed_workspace = None;
        let notifications = self.surface_notifications();
        let mut delta = None;
        {
            let mut state = self.state.lock().unwrap();
            'outer: for ws in &mut state.workspaces {
                for screen in &mut ws.screens {
                    if !screen.root.contains(target) {
                        continue;
                    }
                    let mut panes = screen.zellij_auto_layout.clone().unwrap_or_else(|| {
                        let mut panes = Vec::new();
                        screen.root.pane_ids(&mut panes);
                        panes.sort_unstable();
                        panes
                    });
                    let mut current_panes = Vec::new();
                    screen.root.pane_ids(&mut current_panes);
                    let current_panes = current_panes.into_iter().collect::<HashSet<_>>();
                    panes.retain(|pane| current_panes.contains(pane));
                    panes.push(pane_id);
                    screen.root =
                        crate::layout::zellij_default_pane_layout_with_ids(&panes, &mut || {
                            self.next_id()
                        })
                        .expect("new pane layout always has at least one pane");
                    screen.active_pane = pane_id;
                    screen.zoomed_pane = None;
                    screen.zellij_auto_layout = Some(panes);
                    changed_screen = Some(screen.id);
                    changed_workspace = Some(ws.id);
                    break 'outer;
                }
            }
            if let Some(screen) = changed_screen {
                state.insert_pane(Pane {
                    id: pane_id,
                    name: None,
                    tabs: vec![surface.id],
                    active_tab: 0,
                    active_at,
                    focused_at: 0,
                });
                stamp_pane_focus(self, &mut state, pane_id);
                Self::rebuild_split_screen_index(&mut state);
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::PaneAdded,
                    pane_id,
                )
                .expect("new pane is present in tree snapshot");
                delta = Some(TreeDelta {
                    kind: TreeDeltaKind::PaneAdded,
                    workspace: changed_workspace.expect("new pane workspace captured"),
                    screen: Some(screen),
                    pane: Some(pane_id),
                    surface: None,
                    index: Some(screen_pane_index(&state, screen, pane_id)),
                    entity,
                    workspace_revision: None,
                });
            } else {
                state.surfaces.remove(&surface.id);
            }
        }
        let Some(screen) = changed_screen else {
            surface.kill();
            anyhow::bail!("pane {target} not found");
        };
        self.emit(MuxEvent::TreeDelta(delta.expect("successful new pane has a tree delta")));
        self.emit(MuxEvent::LayoutChanged(screen));
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Close one tab. When it was the pane's last tab, the pane collapses
    /// out of its split tree (and emptied screens/workspaces are removed).
    pub fn close_surface(&self, target: SurfaceId) {
        let notifications = self.surface_notifications();
        let remove = || {
            let mut state = self.state.lock().unwrap();
            let selection_before = active_tree_selection(&state);
            let changed_screen = surface_screen_id(&state, target);
            let mut delta = close_surface_delta(&state, &notifications, target);
            let (removed, split_index_dirty) = remove_surface(self, &mut state, target);
            if split_index_dirty {
                Self::rebuild_split_screen_index(&mut state);
            }
            if matches!(
                delta.as_ref().map(|delta| delta.kind),
                Some(TreeDeltaKind::WorkspaceClosed)
            ) {
                state.workspace_revision = state.workspace_revision.saturating_add(1);
                if let Some(delta) = delta.as_mut() {
                    delta.workspace_revision = Some(state.workspace_revision);
                }
            }
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            let selection_resync =
                empty_revision.is_none() && selection_before != active_tree_selection(&state);
            (
                removed,
                changed_screen.into_iter().collect::<Vec<_>>(),
                empty_revision,
                delta,
                selection_resync,
            )
        };
        let (removed, changed_screens, empty_revision, delta, selection_resync) = loop {
            let Some(workspace) = self.surface_workspace(target) else {
                break remove();
            };
            let lifecycle = self.workspace_lifecycle(workspace);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            if self.surface_workspace(target) != Some(workspace) {
                drop(workspace_lifecycle);
                continue;
            }
            let result = remove();
            drop(workspace_lifecycle);
            break result;
        };
        if let Some(surface) = &removed {
            self.purge_surface_side_tables(surface.id);
            surface.kill();
        }
        if let Some(delta) = delta {
            self.emit_tree_delta(delta, selection_resync);
        } else if removed.is_some() {
            self.emit(MuxEvent::TreeChanged);
        }
        if removed.is_some() || !changed_screens.is_empty() {
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        self.emit_empty_if_current(empty_revision);
    }

    /// Close a pane or screen and build its delta in the same critical section
    /// as removal so a concurrent registry mutation cannot stale its index.
    fn close_tree_target(&self, target: TreeCloseTarget) -> bool {
        let notifications = self.surface_notifications();
        let result = loop {
            let Some(workspace) =
                self.with_state(|state| Self::workspace_for_tree_target_in_state(state, target))
            else {
                return false;
            };
            let lifecycle = self.workspace_lifecycle(workspace);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            if self.with_state(|state| Self::workspace_for_tree_target_in_state(state, target))
                != Some(workspace)
            {
                drop(workspace_lifecycle);
                continue;
            }
            let result = (|| {
                let mut state = self.state.lock().unwrap();
                let selection_before = active_tree_selection(&state);
                let (tabs, mut delta) = match target {
                    TreeCloseTarget::Pane(target) => {
                        let pane = state.panes.get(&target)?;
                        (
                            pane.tabs.clone(),
                            close_pane_delta(&state, &notifications, target)
                                .expect("live pane has a close delta"),
                        )
                    }
                    TreeCloseTarget::Screen(target) => {
                        let screen = state
                            .workspaces
                            .iter()
                            .flat_map(|workspace| &workspace.screens)
                            .find(|screen| screen.id == target)?;
                        (
                            screen_tabs(&state, screen),
                            close_screen_delta(&state, &notifications, target)
                                .expect("live screen has a close delta"),
                        )
                    }
                };
                let changed_screens = unique_screen_ids(
                    tabs.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
                );
                let mut removed = Vec::new();
                let mut split_index_dirty = false;
                for surface in tabs {
                    let (surface, topology_changed) = remove_surface(self, &mut state, surface);
                    split_index_dirty |= topology_changed;
                    if let Some(surface) = surface {
                        removed.push(surface);
                    }
                }
                if split_index_dirty {
                    Self::rebuild_split_screen_index(&mut state);
                }
                let tree_removed = match target {
                    TreeCloseTarget::Pane(target) => !state.panes.contains_key(&target),
                    TreeCloseTarget::Screen(target) => !state
                        .workspaces
                        .iter()
                        .flat_map(|workspace| &workspace.screens)
                        .any(|screen| screen.id == target),
                };
                if tree_removed && delta.kind == TreeDeltaKind::WorkspaceClosed {
                    state.workspace_revision = state.workspace_revision.saturating_add(1);
                    delta.workspace_revision = Some(state.workspace_revision);
                }
                let empty_revision =
                    state.workspaces.is_empty().then_some(state.workspace_revision);
                let selection_resync =
                    empty_revision.is_none() && selection_before != active_tree_selection(&state);
                Some((
                    removed,
                    changed_screens,
                    empty_revision,
                    delta,
                    tree_removed,
                    selection_resync,
                ))
            })();
            drop(workspace_lifecycle);
            break result;
        };
        let Some((removed, changed_screens, empty_revision, delta, tree_removed, selection_resync)) =
            result
        else {
            return false;
        };
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
            surface.kill();
        }
        if tree_removed {
            self.emit_tree_delta(delta, selection_resync);
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        self.emit_empty_if_current(empty_revision);
        true
    }

    /// Close a pane and every tab in it.
    pub fn close_pane(&self, target: PaneId) {
        self.close_tree_target(TreeCloseTarget::Pane(target));
    }

    /// Close a screen and every pane/tab in it.
    pub fn close_screen(&self, target: ScreenId) -> bool {
        self.close_tree_target(TreeCloseTarget::Screen(target))
    }

    /// Close a workspace and every screen/pane/tab in it.
    pub fn close_workspace(&self, target: WorkspaceId) -> bool {
        self.close_workspace_at_revision(target, None)
            .map(|revision| revision.is_some())
            .unwrap_or(false)
    }

    /// Atomically close one workspace if the caller's registry snapshot is
    /// still current. Returns the resulting revision when the workspace was
    /// present and closed.
    pub fn close_workspace_at_revision(
        &self,
        target: WorkspaceId,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_at_revision(Some(target), None, expected_revision)?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn close_workspace_selector_at_revision(
        &self,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        let notifications = self.surface_notifications();
        loop {
            let target = {
                let state = self.state.lock().unwrap();
                Self::require_workspace_revision(&state, expected_revision)?;
                let Some((target, _)) = Self::resolve_workspace_selector(&state, id, key)? else {
                    return Ok(None);
                };
                target
            };
            #[cfg(test)]
            if let Some(hook) =
                self.workspace_close_after_selector_resolution.lock().unwrap().clone()
            {
                hook();
            }
            let lifecycle = self.workspace_lifecycle(target);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let Some((resolved_target, key)) = Self::resolve_workspace_selector(&state, id, key)?
            else {
                return Ok(None);
            };
            if resolved_target != target {
                drop(state);
                drop(workspace_lifecycle);
                continue;
            }
            let index = state.workspace_index(target).expect("resolved workspace is indexed");
            let previous_active = state.active_pane();
            let mut delta = close_workspace_delta(&state, &notifications, target)
                .expect("live workspace has a close delta");
            let was_active = state.active_workspace == index;
            let active_id =
                state.workspaces.get(state.active_workspace).map(|workspace| workspace.id);
            let workspace = state.remove_workspace(index);
            let mut pane_ids = Vec::new();
            for screen in &workspace.screens {
                screen.root.pane_ids(&mut pane_ids);
            }
            let mut removed = Vec::new();
            for pane_id in pane_ids {
                if let Some(pane) = state.remove_pane(pane_id) {
                    for surface in pane.tabs {
                        if let Some(surface) = state.surfaces.remove(&surface) {
                            removed.push(surface);
                        }
                    }
                }
            }
            state.active_workspace = active_id
                .and_then(|id| state.workspace_index(id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            stamp_changed_active_pane(self, &mut state, previous_active);
            Self::rebuild_split_screen_index(&mut state);
            state.workspace_revision = state.workspace_revision.saturating_add(1);
            let revision = state.workspace_revision;
            delta.workspace_revision = Some(revision);
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            let selection_resync = was_active && empty_revision.is_none();
            drop(state);
            drop(workspace_lifecycle);
            for surface in removed {
                self.purge_surface_side_tables(surface.id);
                surface.kill();
            }
            self.emit_tree_delta(delta, selection_resync);
            self.emit_empty_if_current(empty_revision);
            return Ok(Some((target, key, revision)));
        }
    }

    pub fn rename_workspace(&self, target: WorkspaceId, name: String) -> bool {
        self.rename_workspace_at_revision(target, name, None)
            .map(|revision| revision.is_some())
            .unwrap_or(false)
    }

    pub fn rename_workspace_at_revision(
        &self,
        target: WorkspaceId,
        name: String,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_at_revision(Some(target), None, name, expected_revision)?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn rename_workspace_selector_at_revision(
        &self,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        name: String,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        Self::validate_workspace_name(&name)?;
        let notifications = self.surface_notifications();
        let (target, key, renamed) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let Some((target, key)) = Self::resolve_workspace_selector(&state, id, key)? else {
                return Ok(None);
            };
            let index = state.workspace_index(target).expect("resolved workspace is indexed");
            state.workspaces[index].name = name;
            state.workspace_revision = state.workspace_revision.saturating_add(1);
            let workspace_revision = state.workspace_revision;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceRenamed,
                target,
            )
            .expect("renamed workspace is present in tree snapshot");
            let renamed = (
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceRenamed,
                    workspace: target,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: None,
                    entity,
                    workspace_revision: Some(workspace_revision),
                },
                workspace_revision,
            );
            (target, key, renamed)
        };
        self.emit(MuxEvent::TreeDelta(renamed.0));
        Ok(Some((target, key, renamed.1)))
    }

    /// Set a pane's user-visible name. An empty name clears it (the pane
    /// falls back to its active tab's title).
    pub fn rename_pane(&self, target: PaneId, name: String) -> bool {
        let renamed = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.name = (!name.is_empty()).then_some(name);
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
            let state = self.state.lock().unwrap();
            let Some(surface) = state.surfaces.get(&target) else { return false };
            surface.set_name((!name.is_empty()).then_some(name));
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
                    workspace_revision: None,
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
            state.workspaces[wi].screens[si].name = (!name.is_empty()).then_some(name);
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
                workspace_revision: None,
            }
        };
        self.emit(MuxEvent::TreeDelta(renamed));
        true
    }

    /// Reap a surface whose child exited before its tree insert completed.
    /// The exit handler sets the dead flag before calling `surface_exited`,
    /// whose `close_surface` finds nothing to remove in that window; the
    /// creator re-checks after the insert (a harmless no-op otherwise).
    fn reap_if_dead(&self, surface: &Arc<Surface>) {
        if surface.is_dead() {
            self.close_surface(surface.id);
        }
    }

    /// Called by a surface's reader thread when its child exits. The mux
    /// reaps the surface out of the tree itself, so frontends only need to
    /// drop their render state.
    pub fn surface_exited(&self, id: SurfaceId) {
        if self.sidebar_surface_exited(id) {
            self.emit(MuxEvent::SurfaceExited(id));
            return;
        }
        self.close_surface(id);
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
        self.state.lock().unwrap().surfaces.remove(&id);
        true
    }

    /// Make `pane` the active pane of its screen (and that screen and
    /// workspace active).
    pub fn focus_pane(&self, pane: PaneId) -> bool {
        let (found, viewed, layout_changed) = {
            let mut state = self.state.lock().unwrap();
            match state.screen_of(pane) {
                Some((wi, si)) => {
                    state.active_workspace = wi;
                    let ws = &mut state.workspaces[wi];
                    ws.active_screen = si;
                    let screen = &mut ws.screens[si];
                    let previous = screen.active_pane;
                    let layout_changed = (previous != pane
                        && (screen.root.contains_stack_pane(previous)
                            || screen.root.contains_stack_pane(pane)))
                    .then_some(screen.id);
                    screen.root.expand_stack_pane(previous);
                    screen.root.expand_stack_pane(pane);
                    screen.active_pane = pane;
                    stamp_pane_focus(self, &mut state, pane);
                    (true, Self::active_surface_in_state(&state), layout_changed)
                }
                None => (false, None, None),
            }
        };
        if found {
            self.clear_viewed_notification(viewed);
            if let Some(screen) = layout_changed {
                self.emit(MuxEvent::LayoutChanged(screen));
            } else {
                self.emit(MuxEvent::TreeChanged);
            }
        }
        found
    }

    /// Set the deepest split ratio in `dir` on the path to `pane`.
    pub fn set_ratio(&self, pane: PaneId, dir: SplitDir, ratio: f32) -> bool {
        let ratio = clamp_split_ratio(ratio);
        let changed_screen = {
            let mut state = self.state.lock().unwrap();
            state.workspaces.iter_mut().flat_map(|ws| ws.screens.iter_mut()).find_map(|screen| {
                if screen.root.set_deepest_ratio(pane, dir, ratio) {
                    screen.zellij_auto_layout = None;
                    Some(screen.id)
                } else {
                    None
                }
            })
        };
        if let Some(screen) = changed_screen {
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::LayoutChanged(screen));
            true
        } else {
            false
        }
    }

    /// Set one split ratio by its stable split-tree node id.
    pub fn set_split_ratio(&self, split: SplitId, ratio: f32) -> bool {
        let ratio = clamp_split_ratio(ratio);
        let changed_screen = {
            let mut state = self.state.lock().unwrap();
            let Some((workspace_index, screen_index, owner)) =
                state.split_screens.get(&split).copied()
            else {
                return false;
            };
            let changed = state
                .workspaces
                .get_mut(workspace_index)
                .and_then(|workspace| workspace.screens.get_mut(screen_index))
                .filter(|screen| screen.id == owner)
                .and_then(|screen| {
                    if screen.root.set_split_ratio(split, ratio) {
                        screen.zellij_auto_layout = None;
                        Some(screen.id)
                    } else {
                        None
                    }
                });
            if changed.is_none() {
                state.split_screens.remove(&split);
            }
            changed
        };
        if let Some(screen) = changed_screen {
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
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 10_000, height: 10_000 },
                Some(screen.active_pane),
            );
            Ok(layout.neighbor(pane, dx, dy))
        })
    }

    fn pane_focus_neighbor(&self, pane: PaneId, dir: Direction) -> anyhow::Result<Option<PaneId>> {
        self.with_state(|state| {
            let Some((wi, si)) = state.screen_of(pane) else {
                anyhow::bail!("unknown pane {pane}");
            };
            let screen = &state.workspaces[wi].screens[si];
            let (dx, dy) = dir.delta();
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 10_000, height: 10_000 },
                Some(screen.active_pane),
            );
            Ok(layout.neighbor_by_recency(pane, dx, dy, |candidate| {
                state.panes.get(&candidate).map(|pane| pane.focused_at).unwrap_or_default()
            }))
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
        let Some(next) = self.pane_focus_neighbor(target, dir)? else {
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
            state.workspaces.iter_mut().flat_map(|ws| ws.screens.iter_mut()).find_map(|screen| {
                if screen.root.swap_leaves(pane, target) {
                    screen.zellij_auto_layout = None;
                    Some(screen.id)
                } else {
                    None
                }
            })
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
            (screen.id, target, next, changed)
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
        let workspace_lifecycle = workspace.map(|id| self.workspace_lifecycle(id));
        let _workspace_lifecycle_guard =
            workspace_lifecycle.as_ref().map(|lifecycle| lifecycle.lock().unwrap());
        {
            let state = self.state.lock().unwrap();
            if let Some(id) = workspace
                && !state.workspaces.iter().any(|ws| ws.id == id)
            {
                anyhow::bail!("unknown workspace {id}");
            }
        }
        #[cfg(test)]
        if let Some(hook) = self.layout_apply_after_workspace_reservation.lock().unwrap().clone() {
            hook();
        }

        // Generate the only fallible workspace metadata before spawning any
        // layout surfaces. A concurrently emptied registry may still need it.
        let new_workspace_key = workspace.is_none().then(Self::new_workspace_key).transpose()?;

        let mut created = Vec::new();
        let mut panes = Vec::new();
        let mut spawned = Vec::new();
        let root =
            match self.instantiate_layout(layout, size, &mut panes, &mut created, &mut spawned) {
                Ok(root) => root,
                Err(err) => {
                    self.discard_spawned(spawned);
                    return Err(err);
                }
            };
        if created.is_empty() {
            self.discard_spawned(spawned);
            anyhow::bail!("layout must contain at least one leaf");
        }
        let active_pane = root.first_visible_pane();
        let screen_id = self.next_id();
        let notifications = self.surface_notifications();
        let delta = {
            let mut state = self.state.lock().unwrap();
            for (_, pane) in panes {
                state.insert_pane(pane);
            }
            stamp_pane_focus(self, &mut state, active_pane);
            let screen = Screen {
                id: screen_id,
                name,
                root,
                active_pane,
                zoomed_pane: None,
                zellij_auto_layout: None,
            };
            let mut created_workspace = None;
            let workspace_id = match workspace {
                Some(id) => {
                    let workspace_index =
                        state.workspace_index(id).expect("workspace validated before spawning");
                    let ws = &mut state.workspaces[workspace_index];
                    ws.screens.push(screen);
                    id
                }
                None if state.workspaces.is_empty() => {
                    let ws_id = self.next_id();
                    state.push_workspace(Workspace {
                        id: ws_id,
                        key: new_workspace_key.expect("workspace key generated before spawning"),
                        name: "1".into(),
                        screens: vec![screen],
                        active_screen: 0,
                    });
                    state.active_workspace = 0;
                    state.workspace_revision = state.workspace_revision.saturating_add(1);
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
            let delta = if let Some(workspace_id) = created_workspace {
                let index = state.workspace_index(workspace_id).expect("new workspace index");
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
                    workspace_revision: Some(state.workspace_revision),
                }
            } else {
                let index = state
                    .workspace_by_id(workspace_id)
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
                    workspace_revision: None,
                }
            };
            Self::rebuild_split_screen_index(&mut state);
            delta
        };
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
        spawned: &mut Vec<Arc<Surface>>,
    ) -> anyhow::Result<Node> {
        match layout {
            LayoutSpec::Leaf(spec) => {
                if spec.command.as_ref().is_some_and(|argv| argv.is_empty()) {
                    anyhow::bail!("leaf command must not be empty");
                }
                let surface =
                    self.spawn_surface_with(spec.cwd.clone(), spec.command.clone(), size, None)?;
                let (pane_id, pane) = self.make_pane(surface.id);
                created.push(AppliedPane { pane: pane_id, surface: surface.id });
                panes.push((pane_id, pane));
                spawned.push(surface);
                Ok(Node::Leaf(pane_id))
            }
            LayoutSpec::Split { dir, ratio, a, b } => Ok(Node::Split {
                id: self.next_id(),
                dir: *dir,
                ratio: clamp_split_ratio(*ratio),
                a: Box::new(self.instantiate_layout(a, size, panes, created, spawned)?),
                b: Box::new(self.instantiate_layout(b, size, panes, created, spawned)?),
            }),
            LayoutSpec::Stack { pane_count, expanded_index } => {
                if *pane_count == 0 {
                    anyhow::bail!("stack must contain at least one pane");
                }
                if *expanded_index >= *pane_count {
                    anyhow::bail!("stack expanded pane must be a member");
                }
                let mut pane_ids = Vec::with_capacity(*pane_count);
                for _ in 0..*pane_count {
                    let node = self.instantiate_layout(
                        &LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: None }),
                        size,
                        panes,
                        created,
                        spawned,
                    )?;
                    let Node::Leaf(pane_id) = node else { unreachable!() };
                    pane_ids.push(pane_id);
                }
                let expanded = pane_ids[*expanded_index];
                Ok(Node::stack_with_expanded(pane_ids, expanded).expect("validated stack"))
            }
        }
    }

    fn discard_spawned(&self, spawned: Vec<Arc<Surface>>) {
        if spawned.is_empty() {
            return;
        }
        let ids = spawned.iter().map(|surface| surface.id).collect::<Vec<_>>();
        {
            let mut state = self.state.lock().unwrap();
            for id in &ids {
                state.surfaces.remove(id);
            }
        }
        for surface in spawned {
            surface.kill();
        }
    }

    /// Move an existing tab to `index` in `pane`. The surface is kept
    /// alive; if moving it empties the source pane, that pane collapses
    /// out of its split tree.
    pub fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) -> bool {
        let move_tab = || {
            let mut state = self.state.lock().unwrap();
            let workspace_count = state.workspaces.len();
            let previous_active = state.active_pane();
            let source_pane = state.pane_of(surface);
            let source_screen = source_pane
                .filter(|source| *source != pane)
                .and_then(|source| state.screen_of(source))
                .map(|(wi, si)| state.workspaces[wi].screens[si].id);
            let (moved, topology_changed) =
                move_tab_in_state(self, &mut state, surface, pane, index);
            if moved {
                let focused = previous_active != Some(pane) && state.active_pane() == Some(pane);
                if focused {
                    stamp_pane_focus(self, &mut state, pane);
                } else if let Some(pane) = state.panes.get_mut(&pane) {
                    pane.active_at = self.next_active_at();
                }
                if state.workspaces.len() != workspace_count {
                    state.workspace_revision = state.workspace_revision.saturating_add(1);
                }
            }
            if topology_changed {
                Self::rebuild_split_screen_index(&mut state);
            }
            let changed_screen = (moved && topology_changed)
                .then_some(source_screen)
                .flatten()
                .filter(|source_screen| {
                    state.workspaces.iter().any(|workspace| {
                        workspace.screens.iter().any(|screen| screen.id == *source_screen)
                    })
                });
            (moved, changed_screen)
        };
        let (moved, changed_screen) = loop {
            let Some(workspace) =
                self.with_state(|state| Self::workspace_for_surface_in_state(state, surface))
            else {
                return false;
            };
            let lifecycle = self.workspace_lifecycle(workspace);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            if self.with_state(|state| Self::workspace_for_surface_in_state(state, surface))
                != Some(workspace)
            {
                drop(workspace_lifecycle);
                continue;
            }
            let result = move_tab();
            drop(workspace_lifecycle);
            break result;
        };
        if moved {
            self.emit(MuxEvent::TreeChanged);
            if let Some(screen) = changed_screen {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        moved
    }

    /// Reorder a workspace. The active workspace follows the moved entry.
    pub fn move_workspace(&self, workspace: WorkspaceId, index: usize) -> bool {
        self.move_workspace_at_revision(workspace, index, None)
            .map(|result| result.is_some_and(|(_, changed)| changed))
            .unwrap_or(false)
    }

    pub fn move_workspace_at_revision(
        &self,
        workspace: WorkspaceId,
        index: usize,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(u64, bool)>> {
        Ok(self
            .move_workspace_selector_at_revision(Some(workspace), None, index, expected_revision)?
            .map(|(_, _, revision, changed)| (revision, changed)))
    }

    pub(crate) fn move_workspace_selector_at_revision(
        &self,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        index: usize,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64, bool)>> {
        let notifications = self.surface_notifications();
        let (workspace, key, delta) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let Some((workspace, key)) = Self::resolve_workspace_selector(&state, id, key)? else {
                return Ok(None);
            };
            let old_idx = state.workspace_index(workspace).expect("resolved workspace is indexed");
            // Protocol v7 retains insertion-index semantics: after removing the
            // source, insertion points to its right shift left by one.
            let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
            let new_idx = new_idx.min(state.workspaces.len().saturating_sub(1));
            if new_idx == old_idx {
                return Ok(Some((workspace, key, state.workspace_revision, false)));
            }
            let active_id = state.workspaces.get(state.active_workspace).map(|ws| ws.id);
            state.move_workspace(old_idx, new_idx);
            state.active_workspace = active_id
                .and_then(|id| state.workspace_index(id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            Self::rebuild_split_screen_index(&mut state);
            state.workspace_revision = state.workspace_revision.saturating_add(1);
            let workspace_revision = state.workspace_revision;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceMoved,
                workspace,
            )
            .expect("moved workspace is present in tree snapshot");
            let delta = Some((
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceMoved,
                    workspace,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(new_idx),
                    entity,
                    workspace_revision: Some(workspace_revision),
                },
                workspace_revision,
            ));
            (workspace, key, delta)
        };
        if let Some((delta, revision)) = delta {
            self.emit(MuxEvent::TreeDelta(delta));
            Ok(Some((workspace, key, revision, true)))
        } else {
            Ok(None)
        }
    }

    /// Select a tab within a pane (default: the active pane) by index or
    /// relative delta.
    pub fn select_tab(&self, pane: Option<PaneId>, index: Option<usize>, delta: Option<isize>) {
        let viewed = {
            let mut state = self.state.lock().unwrap();
            let Some(target) = pane.or_else(|| state.active_pane()) else { return };
            let Some(pane) = state.panes.get_mut(&target) else { return };
            let len = pane.tabs.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    pane.active_tab = index;
                }
            } else if let Some(delta) = delta {
                pane.active_tab =
                    ((pane.active_tab as isize + delta).rem_euclid(len as isize)) as usize;
            }
            let focused = state.active_pane() == Some(target);
            if focused {
                stamp_pane_focus(self, &mut state, target);
            } else if let Some(pane) = state.panes.get_mut(&target) {
                pane.active_at = self.next_active_at();
            }
            state.panes.get(&target).and_then(|pane| pane.active_surface())
        };
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a screen in the active workspace by index or relative delta.
    pub fn select_screen(&self, index: Option<usize>, delta: Option<isize>) {
        let viewed = {
            let mut state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let Some(ws) = state.workspaces.get_mut(active) else { return };
            let len = ws.screens.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    ws.active_screen = index;
                }
            } else if let Some(delta) = delta {
                ws.active_screen =
                    ((ws.active_screen as isize + delta).rem_euclid(len as isize)) as usize;
            }
            if let Some(pane) = ws.active_screen_ref().map(|screen| screen.active_pane) {
                stamp_pane_focus(self, &mut state, pane);
            }
            Self::active_surface_in_state(&state)
        };
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a workspace by index or relative delta.
    pub fn select_workspace(&self, index: Option<usize>, delta: Option<isize>) {
        let viewed = {
            let mut state = self.state.lock().unwrap();
            let len = state.workspaces.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    state.active_workspace = index;
                }
            } else if let Some(delta) = delta {
                state.active_workspace =
                    ((state.active_workspace as isize + delta).rem_euclid(len as isize)) as usize;
            }
            if let Some(pane) = state
                .workspaces
                .get(state.active_workspace)
                .and_then(|ws| ws.active_screen_ref().map(|screen| screen.active_pane))
            {
                stamp_pane_focus(self, &mut state, pane);
            }
            Self::active_surface_in_state(&state)
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

fn stamp_pane_focus(mux: &Mux, state: &mut State, pane: PaneId) {
    let focused_at = state.next_focus_sequence();
    let active_at = mux.next_active_at();
    if let Some(pane) = state.panes.get_mut(&pane) {
        pane.active_at = active_at;
        pane.focused_at = focused_at;
    }
}

fn stamp_changed_active_pane(mux: &Mux, state: &mut State, previous: Option<PaneId>) {
    let current = state.active_pane();
    if current != previous
        && let Some(pane) = current
    {
        stamp_pane_focus(mux, state, pane);
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

fn unique_screen_ids(ids: impl IntoIterator<Item = ScreenId>) -> Vec<ScreenId> {
    let mut unique = Vec::new();
    for id in ids {
        if !unique.contains(&id) {
            unique.push(id);
        }
    }
    unique
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct ActiveTreeSelection {
    workspace: Option<WorkspaceId>,
    screen: Option<ScreenId>,
    pane: Option<PaneId>,
    surface: Option<SurfaceId>,
}

fn active_tree_selection(state: &State) -> ActiveTreeSelection {
    let workspace = state.workspaces.get(state.active_workspace);
    let screen = workspace.and_then(|workspace| workspace.screens.get(workspace.active_screen));
    let pane = screen.and_then(|screen| state.panes.get(&screen.active_pane));
    ActiveTreeSelection {
        workspace: workspace.map(|workspace| workspace.id),
        screen: screen.map(|screen| screen.id),
        pane: screen.map(|screen| screen.active_pane),
        surface: pane.and_then(|pane| pane.tabs.get(pane.active_tab)).copied(),
    }
}

fn surface_screen_id(state: &State, surface: SurfaceId) -> Option<ScreenId> {
    let pane = state.pane_of(surface)?;
    let (wi, si) = state.screen_of(pane)?;
    Some(state.workspaces[wi].screens[si].id)
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
            workspace_revision: None,
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
            workspace_revision: None,
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
            workspace_revision: None,
        });
    }
    close_workspace_delta(state, notifications, workspace.id)
}

fn close_workspace_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    workspace: WorkspaceId,
) -> Option<TreeDelta> {
    let index = state.workspace_index(workspace)?;
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
        workspace_revision: None,
    })
}

/// Remove one surface from the state: detach it from its
/// pane, and collapse emptied panes/screens/workspaces. Returns whether
/// the removed surface and whether split ownership or positional indexes
/// changed. Runs under the state lock.
fn remove_surface(mux: &Mux, state: &mut State, target: SurfaceId) -> (Option<Arc<Surface>>, bool) {
    let previous_active = state.active_pane();
    let removed = state.surfaces.remove(&target);
    let Some(pane_id) = state.pane_of(target) else {
        return (removed, false);
    };
    let pane = state.panes.get_mut(&pane_id).expect("pane_of returned live id");
    let idx = pane.tabs.iter().position(|id| *id == target).expect("tab in pane");
    pane.tabs.remove(idx);
    if !pane.tabs.is_empty() {
        if pane.active_tab >= idx && pane.active_tab > 0 {
            pane.active_tab -= 1;
        }
        return (removed, false);
    }

    // Last tab gone: the pane collapses out of its screen.
    state.remove_pane(pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return (removed, false);
    };
    let (was_active, root, mut zellij_auto_layout) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
        (was_active, root, screen.zellij_auto_layout.take())
    };
    let stack_expanded = root.stack_expanded_pane();
    match root.remove_leaf(pane_id) {
        Some(mut root) => {
            if let Some(panes) = zellij_auto_layout.as_mut() {
                panes.retain(|pane| *pane != pane_id);
                if let Some(layout) =
                    crate::layout::zellij_default_pane_layout_with_ids(panes, &mut || mux.next_id())
                {
                    root = layout;
                    if let Some(expanded) = stack_expanded {
                        root.expand_stack_pane(expanded);
                    }
                } else {
                    zellij_auto_layout = None;
                }
            }
            let next_active = if was_active {
                let mut ids = Vec::new();
                root.pane_ids(&mut ids);
                most_recent_pane(state, &ids)
            } else {
                None
            };
            let screen = &mut state.workspaces[wi].screens[si];
            screen.root = root;
            screen.zellij_auto_layout = zellij_auto_layout;
            if let Some(next) = next_active {
                screen.active_pane = next;
            }
            stamp_changed_active_pane(mux, state, previous_active);
            return (removed, true);
        }
        None => {
            // Screen emptied: drop it from the workspace.
            let ws = &mut state.workspaces[wi];
            ws.screens.remove(si);
            ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
            if !ws.screens.is_empty() {
                stamp_changed_active_pane(mux, state, previous_active);
                return (removed, true);
            }
        }
    }

    // Workspace emptied too: drop it, keeping the active selection stable.
    let active_id = state.workspaces.get(state.active_workspace).map(|w| w.id);
    state.remove_workspace(wi);
    state.active_workspace = active_id
        .and_then(|id| state.workspace_index(id))
        .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
    stamp_changed_active_pane(mux, state, previous_active);
    (removed, true)
}

fn collapse_empty_pane(mux: &Mux, state: &mut State, pane_id: PaneId) {
    state.remove_pane(pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return;
    };
    let (was_active, root, mut zellij_auto_layout) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
        (was_active, root, screen.zellij_auto_layout.take())
    };
    let stack_expanded = root.stack_expanded_pane();
    match root.remove_leaf(pane_id) {
        Some(mut root) => {
            if let Some(panes) = zellij_auto_layout.as_mut() {
                panes.retain(|pane| *pane != pane_id);
                if let Some(layout) =
                    crate::layout::zellij_default_pane_layout_with_ids(panes, &mut || mux.next_id())
                {
                    root = layout;
                    if let Some(expanded) = stack_expanded {
                        root.expand_stack_pane(expanded);
                    }
                } else {
                    zellij_auto_layout = None;
                }
            }
            let next_active = if was_active {
                let mut ids = Vec::new();
                root.pane_ids(&mut ids);
                most_recent_pane(state, &ids)
            } else {
                None
            };
            let screen = &mut state.workspaces[wi].screens[si];
            screen.root = root;
            screen.zellij_auto_layout = zellij_auto_layout;
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
            state.remove_workspace(wi);
            state.active_workspace = active_id
                .and_then(|id| state.workspace_index(id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
        }
    }
}

fn move_tab_in_state(
    mux: &Mux,
    state: &mut State,
    surface: SurfaceId,
    target_pane: PaneId,
    index: usize,
) -> (bool, bool) {
    if !state.surfaces.contains_key(&surface) || !state.panes.contains_key(&target_pane) {
        return (false, false);
    }
    let Some(source_pane) = state.pane_of(surface) else { return (false, false) };
    if source_pane == target_pane {
        let Some(pane) = state.panes.get_mut(&target_pane) else {
            return (false, false);
        };
        let Some(old_idx) = pane.tabs.iter().position(|id| *id == surface) else {
            return (false, false);
        };
        let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
        let new_idx = new_idx.min(pane.tabs.len().saturating_sub(1));
        if new_idx == old_idx {
            return (false, false);
        }
        let tab = pane.tabs.remove(old_idx);
        pane.tabs.insert(new_idx, tab);
        pane.active_tab = new_idx;
        return (true, false);
    }

    {
        let Some(source) = state.panes.get_mut(&source_pane) else {
            return (false, false);
        };
        let Some(old_idx) = source.tabs.iter().position(|id| *id == surface) else {
            return (false, false);
        };
        source.tabs.remove(old_idx);
        if !source.tabs.is_empty() && source.active_tab >= old_idx && source.active_tab > 0 {
            source.active_tab -= 1;
        }
    }

    let topology_changed = state.panes.get(&source_pane).is_some_and(|pane| pane.tabs.is_empty());
    if topology_changed {
        collapse_empty_pane(mux, state, source_pane);
    }

    let Some(target) = state.panes.get_mut(&target_pane) else {
        return (false, topology_changed);
    };
    let new_idx = index.min(target.tabs.len());
    target.tabs.insert(new_idx, surface);
    target.active_tab = new_idx;
    if let Some((wi, si)) = state.screen_of(target_pane) {
        state.active_workspace = wi;
        let ws = &mut state.workspaces[wi];
        ws.active_screen = si;
        let screen = &mut ws.screens[si];
        screen.active_pane = target_pane;
    }
    (true, topology_changed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("test", SurfaceOptions::default())
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
        );
        assert_eq!(mux.list_agents(Some(first.id), None).len(), 1);
        assert!(mux.surface_notification(first.id).is_some());

        mux.close_surface(first.id);

        // The dead surface must not linger in either side table.
        assert!(mux.list_agents(Some(first.id), None).is_empty());
        assert!(mux.list_agents(None, None).is_empty());
        assert!(mux.surface_notification(first.id).is_none());
        assert!(mux.with_state(|state| state.surfaces.contains_key(&second.id)));
    }

    #[test]
    fn failed_browser_surface_attach_kills_worker() {
        let mux = test_mux();
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
    }

    #[test]
    fn notification_sets_unread_and_clears_when_tab_is_viewed() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, None).unwrap();
        let notification = mux.post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Warning,
            Some(first.id),
        );

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
        let surface = mux.new_workspace(None, None).unwrap();
        assert_eq!(mux.active_surface(), Some(surface.id));

        let notification = mux.post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Info,
            Some(surface.id),
        );

        assert!(mux.surface_notification(surface.id).is_none());
        assert!(events.try_iter().any(|event| {
            matches!(
                event,
                MuxEvent::Notification(note)
                    if note.notification == notification && note.surface == Some(surface.id)
            )
        }));
    }

    fn seed_split_ratio_tree(mux: &Mux) -> (PaneId, PaneId, PaneId) {
        let (p1, p2, p3) = (1, 2, 3);
        let mut state = mux.state.lock().unwrap();
        *state = State {
            workspaces: vec![Workspace {
                id: 1,
                key: "00000000-0000-4000-8000-000000000001".into(),
                name: "1".into(),
                screens: vec![Screen {
                    id: 1,
                    name: None,
                    root: Node::Split {
                        id: 10,
                        dir: SplitDir::Right,
                        ratio: 0.5,
                        a: Box::new(Node::Split {
                            id: 11,
                            dir: SplitDir::Right,
                            ratio: 0.5,
                            a: Box::new(Node::Leaf(p1)),
                            b: Box::new(Node::Leaf(p3)),
                        }),
                        b: Box::new(Node::Leaf(p2)),
                    },
                    active_pane: p3,
                    zoomed_pane: None,
                    zellij_auto_layout: None,
                }],
                active_screen: 0,
            }],
            workspace_index_by_id: HashMap::from([(1, 0)]),
            workspace_id_by_key: HashMap::from([(
                "00000000-0000-4000-8000-000000000001".into(),
                1,
            )]),
            workspace_revision: 1,
            pane_revision: 3,
            focus_sequence: 3,
            active_workspace: 0,
            panes: HashMap::from([
                (
                    p1,
                    Pane {
                        id: p1,
                        name: None,
                        tabs: vec![1],
                        active_tab: 0,
                        active_at: 1,
                        focused_at: 1,
                    },
                ),
                (
                    p2,
                    Pane {
                        id: p2,
                        name: None,
                        tabs: vec![2],
                        active_tab: 0,
                        active_at: 2,
                        focused_at: 2,
                    },
                ),
                (
                    p3,
                    Pane {
                        id: p3,
                        name: None,
                        tabs: vec![3],
                        active_tab: 0,
                        active_at: 3,
                        focused_at: 3,
                    },
                ),
            ]),
            surfaces: HashMap::new(),
            split_screens: HashMap::new(),
        };
        Mux::rebuild_split_screen_index(&mut state);
        drop(state);
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
            Node::Split { dir, ratio, a, b, .. } => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                format!("{dir}:{ratio:.2}({}, {})", node_shape(a), node_shape(b))
            }
            Node::Stack { panes, expanded } => format!("stack:{panes:?}:{expanded}"),
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
            LayoutSpec::Stack { pane_count, expanded_index } => {
                format!("stack:{pane_count}:{expanded_index}")
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
        let exported_shape = node_shape(&screen_root(&mux, first.screen));

        let round_trip_spec = mux.with_state(|s| {
            fn from_node(node: &Node) -> LayoutSpec {
                match node {
                    Node::Leaf(_) => leaf_spec(),
                    Node::Split { dir, ratio, a, b, .. } => {
                        split_spec(*dir, *ratio, from_node(a), from_node(b))
                    }
                    Node::Stack { panes, expanded } => LayoutSpec::Stack {
                        pane_count: panes.len(),
                        expanded_index: panes
                            .iter()
                            .position(|pane| pane == expanded)
                            .expect("valid stack expansion"),
                    },
                }
            }
            from_node(&s.workspaces[0].screens[0].root)
        });
        let second =
            mux.apply_layout(None, Some("round-trip-2".into()), &round_trip_spec, None).unwrap();
        let applied_shape = node_shape(&screen_root(&mux, second.screen));

        assert_eq!(exported_shape, spec_shape(&spec));
        assert_eq!(applied_shape, exported_shape);
        assert_eq!(first.panes.len(), 3);
        assert_eq!(second.panes.len(), 3);
    }

    #[test]
    fn apply_layout_holds_target_workspace_lifecycle_through_commit() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
        let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.layout_apply_after_workspace_reservation.lock().unwrap() = Some(Arc::new({
            move || {
                reserved_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }));
        let apply = std::thread::spawn({
            let mux = mux.clone();
            move || mux.apply_layout(Some(target.workspace), None, &leaf_spec(), None)
        });
        reserved_rx.recv().unwrap();

        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn({
            let mux = mux.clone();
            move || {
                close_done_tx
                    .send(mux.close_workspace_at_revision(target.workspace, Some(1)))
                    .unwrap();
            }
        });
        let premature_close = close_done_rx.recv_timeout(Duration::from_millis(250));
        let closed_early = premature_close.is_ok();
        release_tx.send(()).unwrap();
        let applied = apply.join();
        let close_result = match premature_close {
            Ok(result) => result,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => close_done_rx.recv().unwrap(),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                panic!("workspace close result channel disconnected")
            }
        };
        close.join().unwrap();
        *mux.layout_apply_after_workspace_reservation.lock().unwrap() = None;

        assert!(!closed_early, "workspace closed before layout commit");
        assert!(applied.unwrap().is_ok());
        assert_eq!(close_result.unwrap(), Some(2));
        mux.shutdown();
    }

    #[test]
    fn apply_layout_constructs_stack_with_requested_expansion() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                Some("stack".into()),
                &LayoutSpec::Stack { pane_count: 3, expanded_index: 1 },
                None,
            )
            .unwrap();
        let root = screen_root(&mux, applied.screen);

        assert!(matches!(
            root,
            Node::Stack { ref panes, expanded }
                if panes.len() == 3 && expanded == applied.panes[1].pane
        ));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[0].screens[0].active_pane, applied.panes[1].pane);
        });
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
    fn focus_direction_returns_to_most_recently_focused_adjacent_pane() {
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
        let left = applied.panes[0].pane;
        let top_right = applied.panes[1].pane;
        let bottom_right = applied.panes[2].pane;

        assert!(mux.focus_pane(top_right));
        assert!(mux.focus_pane(bottom_right));
        assert_eq!(mux.focus_direction(None, Direction::Left).unwrap(), left);
        assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), bottom_right);
    }

    #[test]
    fn fresh_layout_focus_uses_layout_order_for_unfocused_candidates() {
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

        assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), applied.panes[1].pane);
    }

    #[test]
    fn selecting_a_tab_in_an_inactive_pane_does_not_change_focus_recency() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let left = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right_surface = mux.split(left, SplitDir::Right, None).unwrap();
        let right = mux.with_state(|state| state.pane_of(right_surface.id).unwrap());
        assert!(mux.focus_pane(left));
        mux.new_tab(Some(right), None, None).unwrap();
        let before = mux.with_state(|state| state.panes[&right].focused_at);

        mux.select_tab(Some(right), Some(0), None);

        assert_eq!(mux.with_state(|state| state.panes[&right].focused_at), before);
    }

    #[test]
    fn moving_a_tab_to_another_pane_stamps_the_new_focus() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let left = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let extra = mux.new_tab(Some(left), None, None).unwrap();
        let right_surface = mux.split(left, SplitDir::Right, None).unwrap();
        let right = mux.with_state(|state| state.pane_of(right_surface.id).unwrap());
        assert!(mux.focus_pane(left));
        let before = mux.with_state(|state| state.panes[&right].focused_at);

        assert!(mux.move_tab(extra.id, right, 0));

        mux.with_state(|state| {
            assert_eq!(state.active_pane(), Some(right));
            assert!(state.panes[&right].focused_at > before);
        });
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
        assert_eq!(surface.spawn_cwd().as_deref(), Some(cwd.as_str()));
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
    fn zellij_new_pane_uses_creation_order_after_manual_split() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_pane(p1, None).unwrap();
        let p2 = mux.with_state(|state| state.pane_of(second.id).unwrap());
        let third = mux.split(p1, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|state| state.pane_of(third.id).unwrap());
        let fourth = mux.new_pane(p3, None).unwrap();
        let p4 = mux.with_state(|state| state.pane_of(fourth.id).unwrap());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let mut order = Vec::new();
            screen.root.pane_ids(&mut order);
            assert_eq!(order, vec![p1, p2, p3, p4]);
            assert_eq!(screen.zellij_auto_layout.as_deref(), Some(order.as_slice()));
        });
    }

    #[test]
    fn zellij_new_pane_exits_zoom_before_focusing_the_new_pane() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.zoom_pane(Some(first_pane), ZoomMode::On).unwrap();

        let new_surface = mux.new_pane(first_pane, None).unwrap();
        let new_pane = mux.with_state(|state| state.pane_of(new_surface.id).unwrap());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, new_pane);
            assert_eq!(screen.zoomed_pane, None);
        });
    }

    #[test]
    fn zellij_new_pane_emits_pane_added_delta_and_layout_change() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let (workspace, screen, first_pane) = mux.with_state(|state| {
            let workspace = &state.workspaces[0];
            let screen = &workspace.screens[0];
            (workspace.id, screen.id, state.pane_of(first.id).unwrap())
        });
        let events = mux.subscribe();

        let added = mux.new_pane(first_pane, None).unwrap();
        let added_pane = mux.with_state(|state| state.pane_of(added.id).unwrap());

        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::TreeDelta(TreeDelta {
                kind: TreeDeltaKind::PaneAdded,
                workspace: event_workspace,
                screen: Some(event_screen),
                pane: Some(event_pane),
                surface: None,
                index: Some(1),
                ..
            }) if event_workspace == workspace && event_screen == screen && event_pane == added_pane
        ));
        assert!(
            matches!(events.recv().unwrap(), MuxEvent::LayoutChanged(event_screen) if event_screen == screen)
        );
        assert!(events.try_iter().all(|event| !matches!(event, MuxEvent::TreeChanged)));
    }

    #[test]
    fn closing_zellij_pane_reapplies_layout_for_remaining_count() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut surfaces = vec![first];
        let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        for _ in 0..4 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            surfaces.push(surface);
        }

        mux.close_surface(surfaces[0].id);
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let order = screen.zellij_auto_layout.as_ref().unwrap();
            assert_eq!(order.len(), 4);
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 200, height: 40 },
                Some(screen.active_pane),
            );
            assert_eq!(layout.rect_of(order[0]).unwrap().height, 40);
            let right_heights = order[1..]
                .iter()
                .map(|pane| layout.rect_of(*pane).unwrap().height)
                .collect::<Vec<_>>();
            assert_eq!(right_heights, vec![13, 14, 13]);
        });
    }

    #[test]
    fn closing_zellij_stack_pane_keeps_active_pane_expanded() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut surfaces = vec![first];
        let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        for _ in 1..14 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            surfaces.push(surface);
        }
        let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        let active_stack_pane = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
        assert!(mux.focus_pane(active_stack_pane));

        mux.close_surface(surfaces[1].id);
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, active_stack_pane);
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, a, b, .. }
                    if matches!(a.as_ref(), Node::Leaf(pane) if *pane == leading_pane)
                        && matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&active_stack_pane))
            ));
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&active_stack_pane));
            assert!(layout.rect_of(active_stack_pane).unwrap().height > 1);
        });
    }

    #[test]
    fn rebuilding_zellij_layout_preserves_stack_expansion_while_focus_is_elsewhere() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut surfaces = vec![first];
        let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        for _ in 1..14 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            surfaces.push(surface);
        }
        let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        let expanded_stack_pane = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
        assert!(mux.focus_pane(expanded_stack_pane));
        assert!(mux.focus_pane(leading_pane));

        mux.close_surface(surfaces[1].id);
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&expanded_stack_pane));
            assert!(layout.rect_of(expanded_stack_pane).unwrap().height > 1);
        });
    }

    #[test]
    fn moving_zellij_stack_pane_keeps_target_pane_expanded() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut surfaces = vec![first];
        let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        for _ in 1..14 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            surfaces.push(surface);
        }
        let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        let target = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
        let events = mux.subscribe();

        assert!(mux.move_tab(surfaces[1].id, target, 0));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, target);
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, a, b, .. }
                    if matches!(a.as_ref(), Node::Leaf(pane) if *pane == leading_pane)
                        && matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&target))
            ));
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&target));
            assert!(layout.rect_of(target).unwrap().height > 1);
        });
        assert!(events.try_iter().any(|event| matches!(event, MuxEvent::LayoutChanged(_))));
    }

    #[test]
    fn swapping_zellij_stack_panes_keeps_active_pane_expanded() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active = first_pane;
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }

        assert!(mux.swap_panes(active, first_pane));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, active);
            assert!(screen.zellij_auto_layout.is_none());
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&active));
            assert!(layout.rect_of(active).unwrap().height > 1);
        });
    }

    #[test]
    fn closing_active_pane_in_damaged_stack_expands_replacement() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active_surface = first;
        let mut active = first_pane;
        for _ in 1..14 {
            active_surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(active_surface.id).unwrap());
        }
        assert!(mux.swap_panes(active, first_pane));

        mux.close_surface(active_surface.id);
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(screen.zellij_auto_layout.is_none());
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&screen.active_pane));
            assert!(layout.rect_of(screen.active_pane).unwrap().height > 1);
        });
    }

    #[test]
    fn focusing_zellij_stack_header_expands_that_pane() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut active = mux.with_state(|state| state.pane_of(first.id).unwrap());
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }
        let stack_pane = mux.with_state(|state| {
            state.workspaces[0].screens[0].zellij_auto_layout.as_ref().unwrap()[1]
        });

        assert!(mux.focus_pane(stack_pane));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, stack_pane);
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, b, .. }
                    if matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&stack_pane))
            ));
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&stack_pane));
            assert!(layout.rect_of(stack_pane).unwrap().height > 1);
        });
    }

    #[test]
    fn focusing_outside_a_stack_emits_layout_changed() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active = first_pane;
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }
        let stack_pane = mux.with_state(|state| {
            state.workspaces[0].screens[0].zellij_auto_layout.as_ref().unwrap()[1]
        });
        let outside = mux.split(active, SplitDir::Right, None).unwrap();
        let outside_pane = mux.with_state(|state| state.pane_of(outside.id).unwrap());
        assert!(mux.focus_pane(stack_pane));
        let events = mux.subscribe();

        assert!(mux.focus_pane(outside_pane));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&stack_pane));
            assert!(layout.rect_of(stack_pane).unwrap().height > 1);
        });
        let invalidations = events
            .try_iter()
            .filter(|event| matches!(event, MuxEvent::TreeChanged | MuxEvent::LayoutChanged(_)))
            .collect::<Vec<_>>();
        assert_eq!(invalidations.len(), 1);
        assert!(matches!(invalidations[0], MuxEvent::LayoutChanged(_)));
    }

    #[test]
    fn directional_split_of_zellij_stack_preserves_requested_direction() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active = first_pane;
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }

        let split = mux.split(active, SplitDir::Right, None).unwrap();
        let split_pane = mux.with_state(|state| state.pane_of(split.id).unwrap());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, a, b, .. }
                    if matches!(a.as_ref(), Node::Leaf(pane) if *pane == first_pane)
                        && matches!(
                            b.as_ref(),
                            Node::Split { dir: SplitDir::Right, a, b, .. }
                                if matches!(a.as_ref(), Node::Stack { .. })
                                    && matches!(b.as_ref(), Node::Leaf(pane) if *pane == split_pane)
                        )
            ));
            assert!(screen.zellij_auto_layout.is_none());
        });
    }

    #[test]
    fn splitting_a_collapsed_stack_member_expands_the_target_side() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active = first_pane;
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }
        let target = mux.with_state(|state| {
            state.workspaces[0].screens[0].zellij_auto_layout.as_ref().unwrap()[1]
        });

        mux.split(target, SplitDir::Right, None).unwrap();
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(matches!(
                &screen.root,
                Node::Split { b, .. }
                    if matches!(
                        b.as_ref(),
                        Node::Split { a, .. }
                            if matches!(a.as_ref(), Node::Stack { expanded, .. } if *expanded == target)
                    )
            ));
        });
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
        let previous_p1_focus = mux.with_state(|state| state.panes[&p1].focused_at);
        let events = mux.subscribe();
        mux.close_pane(p3);

        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::PaneClosed, pane, .. }))
                if pane == Some(p3)
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeSelectionChanged)
        ));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].screens[0].active_pane, p1);
            assert!(s.panes.contains_key(&p2));
            assert!(s.panes[&p1].focused_at > previous_p1_focus);
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
        let events = mux.subscribe();
        mux.close_surface(s2.id);
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::TabClosed, surface, .. }))
                if surface == Some(s2.id)
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeSelectionChanged)
        ));
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
    fn closing_an_ordinary_tab_does_not_rebuild_the_split_index() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.split(pane, SplitDir::Right, None).unwrap();
        let ordinary_tab = mux.new_tab(Some(pane), None, None).unwrap();
        let sentinel = SplitId::MAX;
        {
            let mut state = mux.state.lock().unwrap();
            state.split_screens.insert(sentinel, (usize::MAX, usize::MAX, ScreenId::MAX));
        }

        mux.close_surface(ordinary_tab.id);

        mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
        mux.close_surface(first.id);
        mux.with_state(|state| assert!(!state.split_screens.contains_key(&sentinel)));
    }

    #[test]
    fn move_tab_within_pane_clamps_and_tracks_active_tab() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();
        let s3 = mux.new_tab(Some(pane), None, None).unwrap();
        let pane_revision = mux.with_state(|s| s.pane_revision);

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
            assert_eq!(s.pane_revision, pane_revision);
        });
    }

    #[test]
    fn ordinary_tab_moves_do_not_rebuild_the_split_index() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.split(first_pane, SplitDir::Right, None).unwrap();
        let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
        let extra = mux.new_tab(Some(first_pane), None, None).unwrap();
        let sentinel = SplitId::MAX;
        {
            let mut state = mux.state.lock().unwrap();
            state.split_screens.insert(sentinel, (usize::MAX, usize::MAX, ScreenId::MAX));
        }

        assert!(mux.move_tab(extra.id, first_pane, 0));
        mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
        let events = mux.subscribe();
        assert!(mux.move_tab(extra.id, second_pane, 0));
        mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeChanged));
        assert!(events.try_recv().is_err());
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
        let pane_revision = mux.with_state(|s| s.pane_revision);

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
            assert_eq!(s.pane_revision, pane_revision + 1);
        });
        assert_eq!(mux.surface_count(), original_count);
    }

    #[test]
    fn move_tab_does_not_emit_layout_for_a_removed_source_screen() {
        let mux = test_mux();
        let source = mux.new_workspace(None, None).unwrap();
        let (workspace, source_screen) =
            mux.with_state(|state| (state.workspaces[0].id, state.workspaces[0].screens[0].id));
        let target = mux.new_screen(Some(workspace), None).unwrap();
        let target_pane = mux.with_state(|state| state.pane_of(target.id).unwrap());
        let events = mux.subscribe();

        assert!(mux.move_tab(source.id, target_pane, 0));
        mux.with_state(|state| {
            assert!(state.workspaces[0].screens.iter().all(|screen| screen.id != source_screen));
        });
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeChanged));
        assert!(events.try_iter().all(
            |event| !matches!(event, MuxEvent::LayoutChanged(screen) if screen == source_screen)
        ));
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
    fn set_split_ratio_updates_only_the_exact_split_and_clamps() {
        let mux = test_mux();
        seed_split_ratio_tree(&mux);
        mux.state.lock().unwrap().workspaces[0].screens[0].zellij_auto_layout = Some(vec![1, 2, 3]);
        let events = mux.subscribe();

        assert!(mux.set_split_ratio(10, 2.0));
        mux.with_state(|s| {
            let Node::Split { id, ratio: root_ratio, a, .. } = &s.workspaces[0].screens[0].root
            else {
                panic!("root should be split");
            };
            assert_eq!(*id, 10);
            assert_eq!(*root_ratio, 0.95);
            let Node::Split { id, ratio: inner_ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*id, 11);
            assert_eq!(*inner_ratio, 0.5);
            assert!(s.workspaces[0].screens[0].zellij_auto_layout.is_none());
        });
        assert!(matches!(events.recv().unwrap(), MuxEvent::LayoutChanged(1)));
        assert!(events.try_recv().is_err());
        assert!(!mux.set_split_ratio(9999, 0.4));
    }

    #[test]
    fn dynamically_created_split_ids_remain_stable_across_tree_edits() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(first.id).unwrap());
        let second = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(second.id).unwrap());
        let original = mux.with_state(|s| {
            let Node::Split { id, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            *id
        });

        let third = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(third.id).unwrap());
        let nested = mux.with_state(|s| {
            let Node::Split { b, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should remain split");
            };
            let Node::Split { id, .. } = b.as_ref() else {
                panic!("second child should be split");
            };
            *id
        });
        let screen = mux.with_state(|state| state.workspaces[0].screens[0].id);
        mux.with_state(|state| {
            assert_eq!(state.split_screens.get(&original).map(|location| location.2), Some(screen));
            assert_eq!(state.split_screens.get(&nested).map(|location| location.2), Some(screen));
        });
        assert!(mux.swap_panes(p1, p3));
        assert!(mux.set_split_ratio(original, 0.7));

        mux.with_state(|s| {
            let Node::Split { id, ratio, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should remain split");
            };
            assert_eq!(*id, original);
            assert_eq!(*ratio, 0.7);
        });

        mux.close_surface(third.id);
        mux.with_state(|state| {
            assert!(!state.split_screens.contains_key(&original));
            assert!(state.split_screens.contains_key(&nested));
        });
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
    fn empty_workspace_registry_has_stable_keys_revisions_and_close() {
        let mux = test_mux();
        let events = mux.subscribe();
        let key = "018f6e21-7b70-7e70-8000-000000000001".to_string();
        let first = mux
            .create_empty_workspace(Some("empty".into()), Some(key.clone()), None)
            .expect("create empty workspace");
        assert_eq!(first.key, key);
        assert_eq!(first.index, 0);
        assert_eq!(first.revision, 1);
        mux.with_state(|state| {
            assert_eq!(state.workspace_revision, 1);
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].key, key);
            assert!(state.workspaces[0].screens.is_empty());
            assert_eq!(state.workspace_index(first.workspace), Some(0));
            assert_eq!(
                state.workspace_by_key(&key).map(|workspace| workspace.id),
                Some(first.workspace)
            );
        });
        let MuxEvent::TreeDelta(added) = events.recv().expect("workspace-added delta") else {
            panic!("expected workspace-added delta");
        };
        assert_eq!(added.kind, TreeDeltaKind::WorkspaceAdded);
        assert_eq!(added.workspace_revision, Some(1));
        assert_eq!(added.entity["key"], key);

        assert!(
            mux.create_empty_workspace(None, Some(first.key.clone()), None)
                .expect_err("duplicate stable key must fail")
                .to_string()
                .contains("already exists")
        );
        let conflict = mux
            .rename_workspace_at_revision(first.workspace, "stale".into(), Some(0))
            .expect_err("stale registry mutation must fail");
        assert_eq!(conflict.to_string(), "workspace revision conflict: expected 0, current 1");
        assert_eq!(
            mux.rename_workspace_at_revision(first.workspace, "renamed".into(), Some(1)).unwrap(),
            Some(2)
        );
        assert_eq!(mux.close_workspace_at_revision(first.workspace, Some(2)).unwrap(), Some(3));
        mux.with_state(|state| {
            assert!(state.workspaces.is_empty());
            assert_eq!(state.workspace_revision, 3);
            assert!(state.workspace_by_id(first.workspace).is_none());
            assert!(state.workspace_by_key(&key).is_none());
        });
        let MuxEvent::TreeDelta(closed) = events.recv().expect("workspace-closed delta") else {
            panic!("expected workspace-closed delta");
        };
        assert_eq!(closed.kind, TreeDeltaKind::WorkspaceClosed);
        assert_eq!(closed.workspace_revision, Some(3));
        assert!(matches!(events.recv().expect("empty event"), MuxEvent::Empty));
    }

    #[test]
    fn empty_workspace_registry_enforces_count_and_string_limits() {
        let mux = test_mux();
        let key = "k".repeat(WORKSPACE_KEY_MAX_BYTES);
        let name = "n".repeat(WORKSPACE_NAME_MAX_BYTES);
        let placement = mux
            .create_empty_workspace(Some(name.clone()), Some(key.clone()), None)
            .expect("boundary-sized workspace fields");
        mux.with_state(|state| {
            let workspace = state.workspace_by_id(placement.workspace).unwrap();
            assert_eq!(workspace.key, key);
            assert_eq!(workspace.name, name);
        });

        let oversized_key = "k".repeat(WORKSPACE_KEY_MAX_BYTES + 1);
        assert_eq!(
            mux.create_empty_workspace(None, Some(oversized_key), None)
                .expect_err("oversized key must fail")
                .to_string(),
            format!("workspace key exceeds {WORKSPACE_KEY_MAX_BYTES} bytes")
        );
        let oversized_name = "n".repeat(WORKSPACE_NAME_MAX_BYTES + 1);
        assert_eq!(
            mux.create_empty_workspace(Some(oversized_name.clone()), None, None)
                .expect_err("oversized name must fail")
                .to_string(),
            format!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes")
        );
        assert_eq!(
            mux.rename_workspace_at_revision(placement.workspace, oversized_name, Some(1))
                .expect_err("oversized rename must fail")
                .to_string(),
            format!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes")
        );
        mux.with_state(|state| {
            assert_eq!(state.workspace_revision, 1);
            assert_eq!(state.workspace_by_id(placement.workspace).unwrap().name, name);
        });

        let full_mux = test_mux();
        {
            let mut state = full_mux.state.lock().unwrap();
            for index in 0..WORKSPACE_REGISTRY_LIMIT {
                state.push_workspace(Workspace {
                    id: index as u64 + 1,
                    key: format!("key-{index}"),
                    name: format!("workspace-{index}"),
                    screens: Vec::new(),
                    active_screen: 0,
                });
            }
        }
        assert_eq!(
            full_mux
                .create_empty_workspace(None, None, None)
                .expect_err("full registry must reject another workspace")
                .to_string(),
            format!("workspace limit reached ({WORKSPACE_REGISTRY_LIMIT})")
        );
        full_mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), WORKSPACE_REGISTRY_LIMIT);
            assert_eq!(state.workspace_revision, 0);
        });
    }

    #[test]
    fn concurrent_workspace_creation_suppresses_stale_empty_event() {
        let mux = test_mux();
        let initial = mux.create_empty_workspace(None, None, None).unwrap();
        let events = mux.subscribe();
        let close_ready = Arc::new(std::sync::Barrier::new(2));
        let resume_close = Arc::new(std::sync::Barrier::new(2));
        *mux.workspace_close_before_empty_check.lock().unwrap() = Some(Arc::new({
            let close_ready = close_ready.clone();
            let resume_close = resume_close.clone();
            move || {
                close_ready.wait();
                resume_close.wait();
            }
        }));

        let close_mux = mux.clone();
        let close = std::thread::spawn(move || {
            close_mux.close_workspace_at_revision(initial.workspace, Some(1)).unwrap()
        });
        close_ready.wait();
        let replacement = mux.create_empty_workspace(None, None, Some(2)).unwrap();
        *mux.workspace_close_before_empty_check.lock().unwrap() = None;
        resume_close.wait();
        assert_eq!(close.join().unwrap(), Some(2));

        let emitted = events.try_iter().collect::<Vec<_>>();
        assert!(emitted.iter().any(|event| matches!(
            event,
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceClosed, .. })
        )));
        assert!(emitted.iter().any(|event| matches!(
            event,
            MuxEvent::TreeDelta(TreeDelta {
                kind: TreeDeltaKind::WorkspaceAdded,
                workspace,
                ..
            }) if *workspace == replacement.workspace
        )));
        assert!(!emitted.iter().any(|event| matches!(event, MuxEvent::Empty)));
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, replacement.workspace);
        });
    }

    #[test]
    fn registry_active_workspace_changes_emit_resync_barriers() {
        let mux = test_mux();
        let events = mux.subscribe();
        let first = mux.create_empty_workspace(Some("first".into()), None, None).unwrap();
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeDelta(_)));

        let second = mux.create_empty_workspace(Some("second".into()), None, None).unwrap();
        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceAdded, .. })
        ));
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeSelectionChanged));

        mux.close_workspace_at_revision(second.workspace, Some(2)).unwrap();
        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceClosed, .. })
        ));
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeSelectionChanged));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[state.active_workspace].id, first.workspace);
        });
    }

    #[test]
    fn reaped_surface_close_advances_workspace_registry_revision() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let events = mux.subscribe();
        let previous_revision = mux.with_state(|state| state.workspace_revision);

        let reaped = mux.state.lock().unwrap().surfaces.remove(&surface.id);
        assert!(reaped.is_some(), "surface must exist before simulating the early-exit race");
        mux.close_surface(surface.id);

        mux.with_state(|state| {
            assert!(state.workspaces.is_empty());
            assert_eq!(state.workspace_revision, previous_revision + 1);
        });
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeDelta(TreeDelta {
                kind: TreeDeltaKind::WorkspaceClosed,
                workspace_revision: Some(revision),
                ..
            })) if revision == previous_revision + 1
        ));
        assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(MuxEvent::Empty)));
        surface.kill();
    }

    #[test]
    fn reaped_surface_tree_target_close_advances_workspace_registry_revision() {
        for close_screen in [false, true] {
            let mux = test_mux();
            let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
            let (pane, screen, previous_revision) = mux.with_state(|state| {
                let pane = state.pane_of(surface.id).unwrap();
                let (wi, si) = state.screen_of(pane).unwrap();
                (pane, state.workspaces[wi].screens[si].id, state.workspace_revision)
            });
            let events = mux.subscribe();
            let reaped = mux.state.lock().unwrap().surfaces.remove(&surface.id);
            assert!(reaped.is_some(), "surface must exist before simulating the race");

            if close_screen {
                assert!(mux.close_screen(screen));
            } else {
                mux.close_pane(pane);
            }

            mux.with_state(|state| {
                assert!(state.workspaces.is_empty());
                assert_eq!(state.workspace_revision, previous_revision + 1);
            });
            assert!(matches!(
                events.recv_timeout(Duration::from_secs(1)),
                Ok(MuxEvent::TreeDelta(TreeDelta {
                    kind: TreeDeltaKind::WorkspaceClosed,
                    workspace_revision: Some(revision),
                    ..
                })) if revision == previous_revision + 1
            ));
            surface.kill();
        }
    }

    #[test]
    fn new_tab_materializes_selected_empty_workspace() {
        let mux = test_mux();
        let placement = mux.create_empty_workspace(Some("gui".into()), None, None).unwrap();
        let surface = mux.new_tab(None, Some("/tmp".into()), Some((80, 24))).unwrap();
        assert_eq!(surface.spawn_cwd().as_deref(), Some("/tmp"));
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, placement.workspace);
            assert_eq!(state.workspaces[0].screens.len(), 1);
            assert_eq!(state.pane_of(surface.id), state.active_pane());
            assert_eq!(state.workspace_revision, 1);
        });
    }

    #[test]
    fn concurrent_new_tabs_materialize_one_empty_workspace_screen() {
        let mux = test_mux();
        let placement = mux.create_empty_workspace(Some("gui".into()), None, None).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(9));
        let mut threads = Vec::new();
        for _ in 0..8 {
            let mux = mux.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                mux.new_tab(None, None, Some((80, 24))).unwrap()
            }));
        }
        barrier.wait();
        let surfaces = threads.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>();

        mux.with_state(|state| {
            let workspace = state.workspace_by_id(placement.workspace).unwrap();
            assert_eq!(workspace.screens.len(), 1);
            let pane = workspace.screens[0].active_pane;
            assert_eq!(state.panes[&pane].tabs.len(), surfaces.len());
        });
        for surface in surfaces {
            surface.kill();
        }
    }

    #[test]
    fn concurrent_empty_workspace_terminal_inherits_the_first_terminals_cwd() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(Some("shared".into()), None, None).unwrap();
        let empty_checks = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let (second_checked_tx, second_checked_rx) = std::sync::mpsc::sync_channel(1);
        *mux.terminal_create_after_empty_check.lock().unwrap() = Some(Arc::new({
            move || {
                if empty_checks.fetch_add(1, Ordering::SeqCst) == 1 {
                    second_checked_tx.send(()).unwrap();
                }
            }
        }));

        let first_locked = Arc::new(AtomicBool::new(false));
        let (first_locked_tx, first_locked_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.terminal_create_after_materialization_lock.lock().unwrap() = Some(Arc::new({
            move || {
                if !first_locked.swap(true, Ordering::SeqCst) {
                    first_locked_tx.send(()).unwrap();
                    release_rx.lock().unwrap().recv().unwrap();
                }
            }
        }));

        let first = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    workspace.workspace,
                    None,
                    Some("/tmp".into()),
                    None,
                    Some((80, 24)),
                )
                .unwrap()
            }
        });
        first_locked_rx.recv().unwrap();
        let second = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    workspace.workspace,
                    None,
                    None,
                    None,
                    Some((80, 24)),
                )
                .unwrap()
            }
        });
        second_checked_rx.recv().unwrap();
        release_tx.send(()).unwrap();

        let (first_surface, _) = first.join().unwrap();
        let (second_surface, _) = second.join().unwrap();
        assert_eq!(first_surface.spawn_cwd().as_deref(), Some("/tmp"));
        assert_eq!(second_surface.spawn_cwd().as_deref(), Some("/tmp"));
        *mux.terminal_create_after_empty_check.lock().unwrap() = None;
        *mux.terminal_create_after_materialization_lock.lock().unwrap() = None;
        mux.shutdown();
    }

    #[test]
    fn workspace_close_waits_for_targeted_terminal_commit() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
        let unrelated = mux.create_empty_workspace(Some("unrelated".into()), None, None).unwrap();
        let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.terminal_create_after_workspace_reservation.lock().unwrap() = Some(Arc::new({
            move || {
                reserved_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }));

        let create = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    workspace.workspace,
                    None,
                    None,
                    None,
                    Some((80, 24)),
                )
            }
        });
        reserved_rx.recv().unwrap();
        assert!(mux.workspace_lifecycle(workspace.workspace).try_lock().is_err());
        let unrelated_lifecycle = mux.workspace_lifecycle(unrelated.workspace);
        assert!(unrelated_lifecycle.try_lock().is_ok());

        let (close_started_tx, close_started_rx) = std::sync::mpsc::sync_channel(1);
        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn({
            let mux = mux.clone();
            move || {
                close_started_tx.send(()).unwrap();
                let result = mux.close_workspace_at_revision(workspace.workspace, Some(2));
                close_done_tx.send(result).unwrap();
            }
        });
        close_started_rx.recv().unwrap();
        for _ in 0..1_000 {
            std::thread::yield_now();
        }
        assert!(matches!(close_done_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

        release_tx.send(()).unwrap();
        let (surface, placement) = create.join().unwrap().unwrap();
        assert_eq!(placement.workspace, workspace.workspace);
        assert_eq!(close_done_rx.recv().unwrap().unwrap(), Some(3));
        close.join().unwrap();
        *mux.terminal_create_after_workspace_reservation.lock().unwrap() = None;
        surface.kill();
        mux.shutdown();
    }

    #[test]
    fn key_close_reacquires_replacement_workspace_lifecycle() {
        let mux = test_mux();
        let key = "stable-key".to_string();
        let original =
            mux.create_empty_workspace(Some("original".into()), Some(key.clone()), None).unwrap();
        let original_lifecycle = mux.workspace_lifecycle(original.workspace);
        let original_guard = original_lifecycle.lock().unwrap();

        let selector_resolved = Arc::new(AtomicBool::new(false));
        let (resolved_tx, resolved_rx) = std::sync::mpsc::sync_channel(1);
        *mux.workspace_close_after_selector_resolution.lock().unwrap() = Some(Arc::new({
            move || {
                if !selector_resolved.swap(true, Ordering::SeqCst) {
                    resolved_tx.send(()).unwrap();
                }
            }
        }));
        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn({
            let mux = mux.clone();
            let key = key.clone();
            move || {
                close_done_tx
                    .send(mux.close_workspace_selector_at_revision(None, Some(&key), None))
                    .unwrap();
            }
        });
        resolved_rx.recv().unwrap();

        {
            let mut state = mux.state.lock().unwrap();
            let index = state.workspace_index(original.workspace).unwrap();
            state.remove_workspace(index);
            state.workspace_revision = state.workspace_revision.saturating_add(1);
        }
        let replacement = mux
            .create_empty_workspace(Some("replacement".into()), Some(key.clone()), None)
            .unwrap();

        let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.terminal_create_after_workspace_reservation.lock().unwrap() = Some(Arc::new({
            move || {
                reserved_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }));
        let create = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    replacement.workspace,
                    None,
                    None,
                    None,
                    Some((80, 24)),
                )
            }
        });
        reserved_rx.recv().unwrap();
        drop(original_guard);

        let premature_close = close_done_rx.recv_timeout(Duration::from_millis(250));
        let closed_early = premature_close.is_ok();
        release_tx.send(()).unwrap();
        let created = create.join().unwrap();
        let close_result = match premature_close {
            Ok(result) => result,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => close_done_rx.recv().unwrap(),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                panic!("workspace close result channel disconnected")
            }
        };
        close.join().unwrap();
        *mux.workspace_close_after_selector_resolution.lock().unwrap() = None;
        *mux.terminal_create_after_workspace_reservation.lock().unwrap() = None;

        assert!(!closed_early, "replacement closed without its lifecycle lock");
        let (surface, placement) = created.expect("replacement terminal commits before close");
        assert_eq!(placement.workspace, replacement.workspace);
        assert_eq!(
            close_result.unwrap(),
            Some((replacement.workspace, key, replacement.revision + 1))
        );
        surface.kill();
        mux.shutdown();
    }

    #[test]
    fn create_terminal_targets_inactive_empty_workspace() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
        let active = mux.create_empty_workspace(Some("active".into()), None, None).unwrap();
        let placement = mux
            .create_terminal_in_workspace(target.workspace, None, None, None, Some((80, 24)))
            .unwrap();
        mux.with_state(|state| {
            assert_eq!(state.active_workspace, 1);
            assert_eq!(state.workspaces[1].id, active.workspace);
            assert!(state.workspaces[1].screens.is_empty());
            assert_eq!(placement.workspace, target.workspace);
            assert_eq!(state.workspaces[0].screens.len(), 1);
            assert_eq!(state.pane_of(placement.surface), Some(placement.pane));
            assert_eq!(state.workspace_revision, 2);
        });
    }

    #[test]
    fn create_terminal_in_existing_pane_emits_selection_resync() {
        let mux = test_mux();
        let initial = mux.new_workspace(None, Some((80, 24))).unwrap();
        let workspace = mux.with_state(|state| state.workspaces[0].id);
        let events = mux.subscribe();

        let placement =
            mux.create_terminal_in_workspace(workspace, None, None, None, Some((80, 24))).unwrap();

        assert_ne!(placement.surface, initial.id);
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::TabAdded, surface, .. }))
                if surface == Some(placement.surface)
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeSelectionChanged)
        ));
    }

    #[test]
    fn run_materializes_active_empty_workspace() {
        let mux = test_mux();
        let placement = mux
            .create_empty_workspace(Some("gui".into()), Some("gui-stable".into()), None)
            .unwrap();
        let run = mux
            .run_command_surface(
                vec!["/bin/echo".into(), "ready".into()],
                None,
                false,
                Some("/tmp".into()),
                Some("runner".into()),
                Some((80, 24)),
            )
            .unwrap();

        assert_eq!(run.workspace, placement.workspace);
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, placement.workspace);
            assert_eq!(state.workspaces[0].screens.len(), 1);
            assert_eq!(state.workspace_revision, 1);
        });
        mux.shutdown();
    }

    #[test]
    fn new_browser_tab_materializes_selected_empty_workspace() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("browser".into()), None, None).unwrap();
        let surface = mux.new_browser_tab("about:blank".into(), None, Some((80, 24))).unwrap();

        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, target.workspace);
            assert_eq!(state.workspaces[0].screens.len(), 1);
            assert_eq!(state.pane_of(surface.id), Some(state.workspaces[0].screens[0].active_pane));
            assert_eq!(state.workspace_revision, 1);
        });
        mux.shutdown();
    }

    #[test]
    fn concurrent_browser_tabs_materialize_one_empty_workspace_screen() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("browser".into()), None, None).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(9));
        let mut threads = Vec::new();
        for index in 0..8 {
            let mux = mux.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                mux.new_browser_tab(format!("about:blank#{index}"), None, Some((80, 24)))
            }));
        }
        barrier.wait();
        let surfaces = threads
            .into_iter()
            .map(|thread| thread.join().unwrap().expect("concurrent browser creation"))
            .collect::<Vec<_>>();

        mux.with_state(|state| {
            let workspace = state.workspace_by_id(target.workspace).unwrap();
            assert_eq!(workspace.screens.len(), 1);
            let pane = workspace.screens[0].active_pane;
            assert_eq!(state.panes[&pane].tabs.len(), surfaces.len());
        });
        mux.shutdown();
    }

    #[test]
    fn browser_tab_in_existing_workspace_pane_emits_selection_resync() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let first = mux
            .create_browser_surface_in_workspace(
                workspace.workspace,
                "about:blank#first".into(),
                Some((80, 24)),
            )
            .unwrap();
        let events = mux.subscribe();

        let second = mux
            .create_browser_surface_in_workspace(
                workspace.workspace,
                "about:blank#second".into(),
                Some((80, 24)),
            )
            .unwrap();

        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::TabAdded, surface, .. }))
                if surface == Some(second.id)
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::TreeSelectionChanged)
        ));
        first.kill();
        second.kill();
    }

    #[test]
    fn concurrent_browser_and_terminal_share_empty_workspace_screen() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("mixed".into()), None, None).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let browser = {
            let mux = mux.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                mux.new_browser_tab("about:blank".into(), None, Some((80, 24)))
            })
        };
        let terminal = {
            let mux = mux.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                mux.create_terminal_in_workspace(target.workspace, None, None, None, Some((80, 24)))
            })
        };
        barrier.wait();
        let browser = browser.join().unwrap().expect("concurrent browser creation");
        let terminal = terminal.join().unwrap().expect("concurrent terminal creation");

        mux.with_state(|state| {
            let workspace = state.workspace_by_id(target.workspace).unwrap();
            assert_eq!(workspace.screens.len(), 1);
            let pane = workspace.screens[0].active_pane;
            assert_eq!(state.panes[&pane].tabs.len(), 2);
            assert_eq!(state.pane_of(browser.id), Some(pane));
            assert_eq!(state.pane_of(terminal.surface), Some(pane));
        });
        mux.shutdown();
    }

    #[test]
    fn move_workspace_reorders_and_tracks_active_workspace() {
        let mux = test_mux();
        let events = mux.subscribe();
        mux.new_workspace(Some("one".into()), None).unwrap();
        mux.new_workspace(Some("two".into()), None).unwrap();
        mux.new_workspace(Some("three".into()), None).unwrap();
        let (ws1, ws2, ws3) =
            mux.with_state(|s| (s.workspaces[0].id, s.workspaces[1].id, s.workspaces[2].id));

        assert_eq!(mux.move_workspace_at_revision(ws3, 2, Some(3)).unwrap(), Some((3, false)));
        assert!(!mux.move_workspace(ws3, 2));
        assert!(mux.move_workspace(ws3, 0));
        let mut deltas = events.try_iter().filter_map(|event| match event {
            MuxEvent::TreeDelta(delta) => Some(delta),
            _ => None,
        });
        let moved = deltas
            .find(|delta| delta.kind == TreeDeltaKind::WorkspaceMoved)
            .expect("workspace-moved delta");
        assert_eq!(moved.workspace, ws3);
        assert_eq!(moved.index, Some(0));
        assert_eq!(moved.workspace_revision, Some(4));
        mux.with_state(|s| {
            assert_eq!(
                s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(),
                vec![ws3, ws1, ws2]
            );
            assert_eq!(s.active_workspace, 0);
            assert_eq!(s.workspace_index(ws3), Some(0));
            assert_eq!(s.workspace_index(ws1), Some(1));
            assert_eq!(s.workspace_index(ws2), Some(2));
        });

        assert!(mux.move_workspace(ws1, 99));
        mux.with_state(|s| {
            assert_eq!(
                s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(),
                vec![ws3, ws2, ws1]
            );
            assert_eq!(s.active_workspace, 0);
            assert_eq!(s.workspace_index(ws1), Some(2));
        });
    }

    #[test]
    fn move_workspace_right_uses_insertion_index() {
        let mux = test_mux();
        mux.new_workspace(Some("one".into()), None).unwrap();
        mux.new_workspace(Some("two".into()), None).unwrap();
        mux.new_workspace(Some("three".into()), None).unwrap();
        let (ws1, ws2, ws3) = mux.with_state(|state| {
            (state.workspaces[0].id, state.workspaces[1].id, state.workspaces[2].id)
        });

        assert_eq!(mux.move_workspace_at_revision(ws1, 1, Some(3)).unwrap(), Some((3, false)));
        mux.with_state(|state| {
            assert_eq!(
                state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
                vec![ws1, ws2, ws3]
            );
        });

        assert_eq!(mux.move_workspace_at_revision(ws1, 2, Some(3)).unwrap(), Some((4, true)));
        mux.with_state(|state| {
            assert_eq!(
                state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
                vec![ws2, ws1, ws3]
            );
        });

        assert_eq!(mux.move_workspace_at_revision(ws1, 3, Some(4)).unwrap(), Some((5, true)));
        mux.with_state(|state| {
            assert_eq!(
                state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
                vec![ws2, ws3, ws1]
            );
        });
    }
}
