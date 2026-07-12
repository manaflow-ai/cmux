//! Terminal multiplexer core.
//!
//! Owns the workspace → screen → pane → tab tree and each tab's runtime
//! (a PTY child whose output feeds a libghostty-vt terminal). A workspace
//! holds screens; each screen is a binary split tree of panes; each pane
//! holds one or more tabs, and each tab is a [`Surface`]. Frontends (the
//! bundled TUI, or the cmux app over the control socket) subscribe to
//! [`MuxEvent`]s and read surface state; they never own terminal state
//! themselves, which is what makes the backend attachable.

mod browser;
mod model;
mod mux;
mod short_id;
mod surface;

pub mod layout;
pub mod platform;
pub mod server;

pub use browser::normalize_url;
pub use layout::{
    LayoutResult, Rect, SplitEdge, SplitResize, directional_neighbor, layout_screen,
    split_for_pane_edge, split_sides,
};
pub use model::{Node, Pane, Screen, State, Workspace};
pub use mux::{
    AgentRecord, AgentSource, AgentState, AppliedLayout, AppliedPane, Direction, LayoutLeafSpec,
    LayoutSpec, Mux, MuxEvent, NotificationEvent, NotificationLevel, RunPlacement,
    SidebarPluginOptions, SidebarPluginStatus, SurfaceNotification, ZoomMode, ZoomState,
};
pub use short_id::assign_short_ids;
pub use surface::{
    AttachFrame, AttachStream, BrowserAttachState, BrowserFrame, BrowserFrameStream, BrowserSource,
    BrowserStatus, DefaultColors, Surface, SurfaceKind, SurfaceOptions,
};

pub use cmux_tui_cdp::BrowserMode;
pub use ghostty_vt::Rgb;

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
