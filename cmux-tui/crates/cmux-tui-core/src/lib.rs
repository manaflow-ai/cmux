//! Terminal multiplexer core.
//!
//! Owns the workspace → screen → pane → tab tree and each tab's runtime
//! (a PTY child whose output feeds a libghostty-vt terminal). A workspace
//! holds screens; each screen is a binary split tree of panes; each pane
//! holds one or more tabs, and each tab is a [`Surface`]. Frontends (the
//! bundled TUI, or the cmux app over the control socket) subscribe to
//! [`MuxEvent`]s and read surface state; they never own terminal state
//! themselves, which is what makes the backend attachable.

mod accessibility;
mod browser;
pub mod build_identity;
mod connection_security;
mod event_bus;
mod identity;
mod model;
mod mux;
mod pairing;
mod presentation;
mod projection_state;
pub mod renderer_control;
pub mod renderer_supervisor;
mod semantic_scene;
mod short_id;
mod state_store;
mod surface;
mod terminal_activity;
mod terminal_authority;
mod topology;

pub mod layout;
pub mod platform;
pub mod server;

pub use browser::{TRANSPORT_SAFE_CAPTURE_MEGAPIXELS, normalize_url};
pub use event_bus::{MuxEventBroadcaster, MuxEventReceiver};
pub use identity::{
    DaemonInstanceId, PaneUuid, PresentationId, ScreenUuid, SessionId, SurfaceUuid, WorkspaceUuid,
};
pub use layout::{
    LayoutResult, Rect, SplitEdge, SplitResize, directional_neighbor, layout_screen,
    split_for_pane_edge, split_sides,
};
pub use model::{Node, Pane, Screen, State, Workspace};
pub use mux::{
    AgentRecord, AgentSource, AgentState, AppliedLayout, AppliedPane, CanonicalSnapshot,
    CellPixelUpdate, CellPixelUpdateFailure, Direction, LayoutLeafSpec, LayoutSpec, Mux, MuxEvent,
    NotificationEvent, RunPlacement, SidebarPluginOptions, SidebarPluginStatus,
    SurfaceNotification, SurfaceResizeReporter, TreeDelta, TreeDeltaKind, ZoomMode, ZoomState,
};
pub use pairing::{PairingChallenge, PairingDecision, PairingError};
pub use presentation::{Presentation, PresentationScroll, PresentationView, PresentationZoom};
pub use renderer_supervisor::{
    RendererSupervisor, RendererSupervisorConfig, RendererSupervisorError, RendererSupervisorEvent,
    RendererWorkerState, RendererWorkerStatus,
};
pub use semantic_scene::{
    SEMANTIC_SCENE_EVENT_CAPACITY, SEMANTIC_SCENE_MAX_EVENT_CAPACITY, SemanticSceneAttachError,
    SemanticSceneAttachment, SemanticSceneAttachmentOptions, SemanticSceneCaptureOptions,
    SemanticSceneControl, SemanticSceneEvent, SemanticSceneFailure, SemanticSceneFrame,
    SemanticScenePresentationIdentity, SemanticSceneReceiver, SemanticSceneTerminalIdentity,
};
pub use short_id::assign_short_ids;
pub use state_store::{STATE_STORE_VERSION, StateRecovery, StateStore, StateStoreError};
pub use surface::{
    AttachFrame, AttachFrameReceiver, AttachStream, BrowserAttachState, BrowserFrame,
    BrowserFrameStream, BrowserSource, BrowserStatus, DefaultColors, RenderAttachFrame,
    RenderAttachStream, Surface, SurfaceKind, SurfaceOptions, SurfaceRenderFrame, TerminalColors,
};
pub use terminal_activity::{
    LEGACY_TERMINAL_ACTIVITY_READER_UUID, NotificationLevel, TerminalActivityFact,
    TerminalActivityKind, TerminalActivityReadReceipt, TerminalActivitySnapshot,
};
pub use topology::{
    ResnapshotReason, ResnapshotRequired, TopologyDelta, TopologyDeltaReceiver, TopologyLimits,
    TopologyOperation, TopologyResume, TopologySnapshot, TopologySubscription, TopologyTargets,
};

pub use cmux_tui_cdp::BrowserMode;
pub use ghostty_vt::{CursorShape, Rgb};

pub type SurfaceId = u64;
pub type PaneId = u64;
pub type ScreenId = u64;
pub type WorkspaceId = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitDir {
    /// Split into left/right columns.
    Right,
    /// Split into top/bottom rows.
    Down,
}
pub use accessibility::{
    TERMINAL_ACCESSIBILITY_MAX_CELLS, TERMINAL_ACCESSIBILITY_MAX_LINKS,
    TERMINAL_ACCESSIBILITY_MAX_ROWS, TERMINAL_ACCESSIBILITY_MAX_TEXT_BYTES,
    TERMINAL_ACCESSIBILITY_MAX_UTF16_UNITS, TERMINAL_ACCESSIBILITY_MAX_WIRE_BYTES,
    TERMINAL_ACCESSIBILITY_SCHEMA_VERSION, TerminalAccessibilityCell, TerminalAccessibilityCursor,
    TerminalAccessibilityLine, TerminalAccessibilityLink, TerminalAccessibilityRange,
    TerminalAccessibilitySelection, TerminalAccessibilitySnapshot,
};
