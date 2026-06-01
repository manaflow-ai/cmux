//! Session snapshot types — JSON-compatible with the macOS cmux format.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::model::panel::{GitBranch, LayoutNode, SplitOrientation};
use crate::model::workspace::{LogEntry, Progress, StatusEntry};

/// Root session snapshot.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSessionSnapshot {
    pub version: u32,
    pub created_at: f64,
    pub windows: Vec<SessionWindowSnapshot>,
}

/// Window snapshot (Linux has one window typically, but supports multiple).
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionWindowSnapshot {
    pub frame: Option<SessionRectSnapshot>,
    pub tab_manager: SessionTabManagerSnapshot,
    pub sidebar: SessionSidebarSnapshot,
}

/// Tab manager snapshot.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTabManagerSnapshot {
    pub selected_workspace_index: Option<usize>,
    pub workspaces: Vec<SessionWorkspaceSnapshot>,
}

/// Workspace snapshot.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionWorkspaceSnapshot {
    pub process_title: String,
    pub custom_title: Option<String>,
    pub custom_color: Option<String>,
    pub is_pinned: bool,
    pub current_directory: String,
    pub focused_panel_id: Option<Uuid>,
    pub layout: SessionWorkspaceLayoutSnapshot,
    pub panels: Vec<SessionPanelSnapshot>,
    pub status_entries: Vec<StatusEntry>,
    pub log_entries: Vec<LogEntry>,
    pub progress: Option<Progress>,
    pub git_branch: Option<GitBranch>,
}

/// Recursive layout snapshot (matches macOS JSON format).
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SessionWorkspaceLayoutSnapshot {
    #[serde(rename = "pane")]
    Pane { pane: SessionPaneLayoutSnapshot },
    #[serde(rename = "split")]
    Split { split: SessionSplitLayoutSnapshot },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPaneLayoutSnapshot {
    pub panel_ids: Vec<Uuid>,
    pub selected_panel_id: Option<Uuid>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSplitLayoutSnapshot {
    pub orientation: SplitOrientation,
    pub divider_position: f64,
    pub first: Box<SessionWorkspaceLayoutSnapshot>,
    pub second: Box<SessionWorkspaceLayoutSnapshot>,
}

/// Panel snapshot.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPanelSnapshot {
    pub id: Uuid,
    #[serde(rename = "type")]
    pub panel_type: String,
    pub title: Option<String>,
    pub custom_title: Option<String>,
    pub directory: Option<String>,
    pub is_pinned: bool,
    pub is_manually_unread: bool,
    pub git_branch: Option<GitBranch>,
    pub listening_ports: Vec<u16>,
    pub tty_name: Option<String>,
    pub terminal: Option<SessionTerminalPanelSnapshot>,
    pub browser: Option<SessionBrowserPanelSnapshot>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTerminalPanelSnapshot {
    pub working_directory: Option<String>,
    pub scrollback: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionBrowserPanelSnapshot {
    pub url_string: Option<String>,
    pub should_render_web_view: bool,
    pub page_zoom: f64,
    pub developer_tools_visible: bool,
}

/// Window geometry.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRectSnapshot {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Sidebar state.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSidebarSnapshot {
    pub is_visible: bool,
    pub selection: String,
    pub width: Option<f64>,
}

// -----------------------------------------------------------------------
// Conversion helpers
// -----------------------------------------------------------------------

impl SessionWorkspaceLayoutSnapshot {
    /// Convert from a model LayoutNode.
    pub fn from_layout(node: &LayoutNode) -> Self {
        match node {
            LayoutNode::Pane {
                panel_ids,
                selected_panel_id,
            } => SessionWorkspaceLayoutSnapshot::Pane {
                pane: SessionPaneLayoutSnapshot {
                    panel_ids: panel_ids.clone(),
                    selected_panel_id: *selected_panel_id,
                },
            },
            LayoutNode::Split {
                orientation,
                divider_position,
                first,
                second,
            } => SessionWorkspaceLayoutSnapshot::Split {
                split: SessionSplitLayoutSnapshot {
                    orientation: *orientation,
                    divider_position: *divider_position,
                    first: Box::new(Self::from_layout(first)),
                    second: Box::new(Self::from_layout(second)),
                },
            },
        }
    }

    /// Convert to a model LayoutNode.
    pub fn to_layout(&self) -> LayoutNode {
        match self {
            SessionWorkspaceLayoutSnapshot::Pane { pane: p } => LayoutNode::Pane {
                panel_ids: p.panel_ids.clone(),
                selected_panel_id: p.selected_panel_id,
            },
            SessionWorkspaceLayoutSnapshot::Split { split: s } => LayoutNode::Split {
                orientation: s.orientation,
                divider_position: if s.divider_position.is_finite() {
                    s.divider_position.clamp(0.0, 1.0)
                } else {
                    0.5
                },
                first: Box::new(s.first.to_layout()),
                second: Box::new(s.second.to_layout()),
            },
        }
    }
}

impl SessionPanelSnapshot {
    /// Convert from a model Panel.
    pub fn from_panel(panel: &crate::model::panel::Panel) -> Self {
        let panel_type = match panel.panel_type {
            crate::model::PanelType::Terminal => "terminal".to_string(),
            crate::model::PanelType::Browser => "browser".to_string(),
        };

        Self {
            id: panel.id,
            panel_type,
            title: panel.title.clone(),
            custom_title: panel.custom_title.clone(),
            directory: panel.directory.clone(),
            is_pinned: panel.is_pinned,
            is_manually_unread: panel.is_manually_unread,
            git_branch: panel.git_branch.clone(),
            listening_ports: panel.listening_ports.clone(),
            tty_name: panel.tty_name.clone(),
            terminal: if panel.panel_type == crate::model::PanelType::Terminal {
                Some(SessionTerminalPanelSnapshot {
                    working_directory: panel.directory.clone(),
                    scrollback: None, // TODO: capture scrollback
                })
            } else {
                None
            },
            browser: if panel.panel_type == crate::model::PanelType::Browser {
                Some(SessionBrowserPanelSnapshot {
                    url_string: None,
                    should_render_web_view: true,
                    page_zoom: 1.0,
                    developer_tools_visible: false,
                })
            } else {
                None
            },
        }
    }
}
