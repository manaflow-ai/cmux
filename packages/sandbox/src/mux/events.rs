use std::path::PathBuf;

use crate::models::{NotificationLevel, SandboxSummary};
use crate::mux::layout::PaneId;

/// Events that can occur in the multiplexer.
#[derive(Debug, Clone)]
pub enum MuxEvent {
    /// Request to create a sandbox from the launch workspace.
    CreateSandboxWithWorkspace {
        workspace_path: PathBuf,
        tab_id: Option<String>,
    },
    /// Sandbox list was refreshed.
    SandboxesRefreshed(Vec<SandboxSummary>),
    /// Failed to refresh sandboxes.
    SandboxRefreshFailed(String),
    /// A sandbox was created.
    SandboxCreated(SandboxSummary),
    /// Attach tab metadata to a sandbox (used to keep CMUX_TAB_ID aligned with UI tab).
    SandboxTabMapped { sandbox_id: String, tab_id: String },
    /// A sandbox was deleted.
    SandboxDeleted(String),
    /// Connection to a sandbox changed.
    SandboxConnectionChanged { sandbox_id: String, connected: bool },
    /// Terminal output received.
    TerminalOutput { pane_id: crate::mux::layout::PaneId },
    /// An error occurred.
    Error(String),
    /// A system notification to display.
    Notification {
        message: String,
        level: NotificationLevel,
        sandbox_id: Option<String>,
        tab_id: Option<String>,
    },
    /// Local status message (does not become a stored notification).
    StatusMessage { message: String },
    /// Request to connect to a sandbox (used for auto-connect on startup)
    ConnectToSandbox { sandbox_id: String },
    /// Request to connect the active pane to the active sandbox's terminal
    ConnectActivePaneToSandbox,
    /// Terminal connection closed for a pane
    TerminalExited { pane_id: PaneId, sandbox_id: String },
}
