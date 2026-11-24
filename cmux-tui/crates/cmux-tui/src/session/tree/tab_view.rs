//! A tab as the TUI draws it, and the parts of a tab in a daemon's tree
//! that are not plain fields.

use cmux_tui_core::resource::{ContentPublicId, TabPublicId, TerminalPublicId};
use cmux_tui_core::{BrowserSource, ShownProgramStatus, SurfaceId, SurfaceKind};
use std::sync::Arc;

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
    /// `tab-attention-v1`: an agent needs the person to act in this tab.
    pub attention: Option<TabAttentionView>,
    /// The git branch (or abbreviated commit when detached) of the PTY's
    /// directory, when the daemon resolved one.
    pub git_branch: Option<String>,
}

#[derive(Clone, Copy)]
pub struct TabNotificationView {
    pub unread: bool,
    pub level: &'static str,
    /// The daemon's notification number (ascending in posting order), so
    /// the attention queue puts the oldest unread tab first.
    pub sequence: u64,
}

/// An agent's "needs you here" mark on a tab: the one line the person reads
/// and when the agent asked (Unix ms).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TabAttentionView {
    pub reason: Arc<str>,
    pub at_ms: u64,
}

/// The tree tab's `attention` (`{reason, at_ms}`), absent or null when the tab
/// holds no mark; a mark without a readable reason is not drawn.
pub(crate) fn parse_attention(value: &Value) -> Option<TabAttentionView> {
    let attention = value.get("attention")?;
    let reason = attention.get("reason")?.as_str().filter(|reason| !reason.trim().is_empty())?;
    Some(TabAttentionView {
        reason: Arc::from(reason),
        at_ms: attention.get("at_ms").and_then(Value::as_u64).unwrap_or(0),
    })
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
        sequence: value.get("notification").and_then(Value::as_u64).unwrap_or(0),
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
