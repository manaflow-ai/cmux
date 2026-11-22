//! Events the mux broadcasts to frontends and servers (`MuxEvent`), with the
//! tree delta and machine usage payloads they carry.

use std::sync::Arc;

use serde_json::Value;

use super::NotificationEvent;
use super::personal;
use crate::sizing_policy::TerminalSizingState;
use crate::{PairingChallenge, PaneId, ScreenId, SurfaceId, WorkspaceId};

/// Structured graphics failures localized by the presentation frontend.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GraphicsStatus {
    KittyImageBudgetWorkerStartFailed { error: Arc<str> },
    KittyImageBudgetUpdateFailed { retry_exhausted: bool, summary: Arc<str> },
    CellPixelUpdateRetriesExhausted { attempts: u8, remaining: usize, cell_pixels: (u16, u16) },
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
    /// A surface's child exited. Hosted terminal views have been atomically
    /// detached while their durable exit receipt remains queryable; local
    /// terminals have already been reaped when this arrives.
    SurfaceExited(SurfaceId),
    TitleChanged {
        surface: SurfaceId,
        title: Arc<str>,
    },
    /// The latest agent state for one surface changed.
    AgentChanged {
        surface: SurfaceId,
        state: Arc<str>,
        source: Arc<str>,
        session: Option<Arc<str>>,
        agent: Option<Arc<str>>,
        updated_at_ms: u64,
    },
    Bell(SurfaceId),
    Notification(NotificationEvent),
    GraphicsStatus(GraphicsStatus),
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
    FrontendProjectionChanged {
        frontend: String,
        scope: String,
        subject_key: String,
        projection_revision: u64,
        origin: String,
        mutation_id: String,
    },
    /// The home session's personal state (rooms, sessions, personal groups
    /// and order; `profiles-v1`) changed. Consumers refetch `list-personal`.
    PersonalChanged {
        personal_revision: u64,
    },
    BookmarksChanged(personal::BookmarksChange),
    Conversation(Arc<crate::conversation_store::ConversationEvent>),
    /// An event of the cloud conversations proxy (`cloud-conversations-v1`).
    CloudConversation(Arc<crate::cloud_conversations::CloudEvent>),
    /// A durable terminal-registry mutation committed. Consumers use this as
    /// a barrier, then fetch `terminal-events` or a fresh snapshot.
    TerminalRegistryChanged {
        registry_id: String,
        generation: String,
        terminal_revision: u64,
    },
    /// The owner ended a terminal that had no tab placement for the reap
    /// grace period and was not marked `keep` (`terminal-reap-v1`).
    TerminalReaped {
        /// Stable terminal host id.
        terminal_id: String,
        /// Public `term_` resource id, when the terminal had one.
        terminal: Option<String>,
        grace_ms: u64,
    },
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
    /// The shared sizing state of a terminal changed. Emitted once per
    /// placement of the terminal runtime; `generation` orders the states.
    SizeStateChanged {
        surface: SurfaceId,
        runtime: SurfaceId,
        state: Arc<TerminalSizingState>,
    },
    /// A recovered event subscription may have missed client lifecycle
    /// events, so consumers must reload the authoritative client list.
    ClientListInvalidated,
    /// An unauthenticated browser is waiting for a trusted TUI decision.
    PairingRequested(PairingChallenge),
    /// A pairing request was approved, denied, disconnected, or expired.
    PairingResolved {
        request: u64,
    },
    /// The daemon's machine-level model spend readout changed. `None` means
    /// the readout is unavailable and frontends must hide it.
    MachineUsageChanged(Option<MachineUsage>),
    /// Every workspace is gone.
    Empty,
}

/// Machine-level model spend for the machine hosting this daemon, as
/// reported by coderouter for the trailing `period_days` window. Frontends
/// show it as an informational readout beside the machine identity.
#[derive(Debug, Clone, PartialEq)]
pub struct MachineUsage {
    pub vm_id: String,
    pub period_days: u32,
    pub total_tokens: u64,
    pub api_equivalent_usd: f64,
    /// Server-side timestamp of the snapshot, when known.
    pub as_of: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TreeDeltaKind {
    WorkspaceAdded,
    WorkspaceClosed,
    WorkspaceRenamed,
    WorkspaceMoved,
    /// Workspace presentation (color, icon, title) changed.
    WorkspaceChanged,
    ScreenAdded,
    ScreenClosed,
    ScreenRenamed,
    /// Screen presentation (color, icon, pin, group) or position changed.
    ScreenChanged,
    PaneAdded,
    PaneClosed,
    TabAdded,
    TabClosed,
    TabRenamed,
    /// Tab metadata (pinned flag, directory, git HEAD, unread marker)
    /// changed.
    TabChanged,
}

impl TreeDeltaKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WorkspaceAdded => "workspace-added",
            Self::WorkspaceClosed => "workspace-closed",
            Self::WorkspaceRenamed => "workspace-renamed",
            Self::WorkspaceMoved => "workspace-moved",
            Self::WorkspaceChanged => "workspace-changed",
            Self::ScreenAdded => "screen-added",
            Self::ScreenClosed => "screen-closed",
            Self::ScreenRenamed => "screen-renamed",
            Self::ScreenChanged => "screen-changed",
            Self::PaneAdded => "pane-added",
            Self::PaneClosed => "pane-closed",
            Self::TabAdded => "tab-added",
            Self::TabClosed => "tab-closed",
            Self::TabRenamed => "tab-renamed",
            Self::TabChanged => "tab-changed",
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
    /// The client transaction id of the command that caused this delta, so
    /// a frontend can reconcile its optimistic UI.
    pub transaction: Option<Arc<str>>,
}
