//! Terminal multiplexer core.
//!
//! Owns the workspace → screen → pane → tab tree and each tab's runtime
//! (a PTY child whose output feeds a libghostty-vt terminal). A workspace
//! holds screens; each screen is a binary split tree of panes; each pane
//! holds one or more tabs, and each tab is a [`Surface`]. Frontends (the
//! bundled TUI, or the cmux app over the control socket) subscribe to
//! [`MuxEvent`]s and read surface state; they never own terminal state
//! themselves, which is what makes the backend attachable.

mod model;
mod mux;
mod surface;

pub mod layout;
pub mod server;

pub use layout::{layout_screen, split_sides, LayoutResult, Rect, Separator};
pub use model::{Node, Pane, Screen, State, Workspace};
pub use mux::{Mux, MuxEvent};
pub use surface::{AttachStream, Surface, SurfaceOptions};

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
