//! A tab as the TUI draws it, and the parts of a tab in a daemon's tree
//! that are not plain fields.

use cmux_tui_core::resource::{ContentPublicId, TabPublicId, TerminalPublicId};
use cmux_tui_core::{BrowserSource, ShownProgramStatus, SurfaceId, SurfaceKind};
use serde_json::Value;

#[derive(Clone)]
pub struct TabView {
    pub surface: SurfaceId,
    pub public_id: Option<TabPublicId>,
    pub content_id: Option<ContentPublicId>,
    pub terminal_id: Option<TerminalPublicId>,
    pub short_id: String,
    pub name: Option<String>,
    pub title: String,
    pub kind: SurfaceKind,
    pub browser_source: Option<BrowserSource>,
    pub browser_frames_stalled: bool,
    pub supports_clear_history_key_fallback: bool,
    pub notification: Option<TabNotificationView>,
    /// OSC 7501: the status the tab shows (tab bar indicator).
    pub program_status: Option<ShownProgramStatus>,
}

#[derive(Clone, Copy)]
pub struct TabNotificationView {
    pub unread: bool,
    pub level: &'static str,
}

pub(super) fn parse_notification(value: &Value) -> Option<TabNotificationView> {
    let level = match value.get("level").and_then(|v| v.as_str()).unwrap_or("info") {
        "warning" => "warning",
        "error" => "error",
        _ => "info",
    };
    Some(TabNotificationView {
        unread: value.get("unread").and_then(|v| v.as_bool()).unwrap_or(false),
        level,
    })
}

/// OSC 7501: the status a tab in the tree (or a `program-status-changed`
/// event) shows (`program_status`).
pub(crate) fn parse_program_status(value: &Value) -> Option<ShownProgramStatus> {
    value.get("program_status").and_then(ShownProgramStatus::from_wire)
}

impl super::TreeView {
    /// Set the shown status of tab `id` at `location` (workspace, screen,
    /// pane, tab); `None` when the tab is no longer there.
    pub(crate) fn update_program_status_at(
        &mut self,
        id: SurfaceId,
        [workspace, screen, pane, tab]: [usize; 4],
        status: Option<ShownProgramStatus>,
    ) -> Option<()> {
        let tab = self
            .workspaces
            .get_mut(workspace)?
            .screens
            .get_mut(screen)?
            .panes
            .get_mut(pane)?
            .tabs
            .get_mut(tab)?;
        (tab.surface == id).then(|| tab.program_status = status)
    }
}
