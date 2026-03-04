//! Workspace model — a named collection of panels with layout and metadata.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

use super::panel::{GitBranch, LayoutNode, Panel, PanelType, SplitOrientation};

/// A workspace contains one or more panels arranged in a split layout.
///
/// Each workspace appears as a tab in the sidebar.
#[derive(Debug, Clone)]
pub struct Workspace {
    pub id: Uuid,
    pub process_title: String,
    pub custom_title: Option<String>,
    pub custom_color: Option<String>,
    pub is_pinned: bool,
    pub current_directory: String,
    pub focused_panel_id: Option<Uuid>,

    /// The layout tree describing pane arrangement.
    pub layout: LayoutNode,

    /// All panels in this workspace, keyed by UUID.
    pub panels: HashMap<Uuid, Panel>,

    /// Status entries (agent metadata, key-value pairs).
    pub status_entries: Vec<StatusEntry>,

    /// Log entries from agents/tools.
    pub log_entries: Vec<LogEntry>,

    /// Progress indicator.
    pub progress: Option<Progress>,

    /// Git branch for the workspace root.
    pub git_branch: Option<GitBranch>,

    /// Unread notification count.
    pub unread_count: u32,
}

/// Status entry (agent metadata key-value pairs shown in sidebar).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusEntry {
    pub key: String,
    pub value: String,
    pub icon: Option<String>,
    pub color: Option<String>,
    pub timestamp: f64,
}

/// Log entry from agents/tools.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogEntry {
    pub message: String,
    pub level: String,
    pub source: Option<String>,
    pub timestamp: f64,
}

/// Progress indicator for a workspace.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Progress {
    pub value: f64,
    pub label: Option<String>,
}

impl Workspace {
    /// Create a new workspace with a single terminal panel.
    pub fn new() -> Self {
        let panel = Panel::new_terminal();
        let panel_id = panel.id;
        let mut panels = HashMap::new();
        panels.insert(panel_id, panel);

        Self {
            id: Uuid::new_v4(),
            process_title: "Terminal".to_string(),
            custom_title: None,
            custom_color: None,
            is_pinned: false,
            current_directory: std::env::var("HOME").unwrap_or_else(|_| "/".to_string()),
            focused_panel_id: Some(panel_id),
            layout: LayoutNode::single_pane(panel_id),
            panels,
            status_entries: Vec::new(),
            log_entries: Vec::new(),
            progress: None,
            git_branch: None,
            unread_count: 0,
        }
    }

    /// Create a new workspace with a specific working directory.
    pub fn with_directory(directory: &str) -> Self {
        let mut ws = Self::new();
        ws.current_directory = directory.to_string();
        ws
    }

    /// Display title: custom title if set, otherwise process title.
    pub fn display_title(&self) -> &str {
        self.custom_title.as_deref().unwrap_or(&self.process_title)
    }

    /// Add a new panel by splitting the focused pane.
    pub fn split(
        &mut self,
        orientation: SplitOrientation,
        panel_type: PanelType,
    ) -> Uuid {
        let new_panel = match panel_type {
            PanelType::Terminal => Panel::new_terminal(),
            PanelType::Browser => Panel::new_browser(),
        };
        let new_id = new_panel.id;
        self.panels.insert(new_id, new_panel);

        // Find the focused pane and split it
        if let Some(focused_id) = self.focused_panel_id {
            if let Some(pane) = self.layout.find_pane_with_panel(focused_id) {
                let old = std::mem::replace(
                    pane,
                    LayoutNode::Pane {
                        panel_ids: vec![],
                        selected_panel_id: None,
                    },
                );
                *pane = old.split(orientation, new_id);
            }
        } else {
            // No focused panel — just split the root
            let old = std::mem::replace(
                &mut self.layout,
                LayoutNode::Pane {
                    panel_ids: vec![],
                    selected_panel_id: None,
                },
            );
            self.layout = old.split(orientation, new_id);
        }

        self.focused_panel_id = Some(new_id);
        new_id
    }

    /// Remove a panel by ID. Returns true if the panel existed.
    pub fn remove_panel(&mut self, panel_id: Uuid) -> bool {
        if self.panels.remove(&panel_id).is_none() {
            return false;
        }
        self.layout.remove_panel(panel_id);

        // Update focused panel if needed
        if self.focused_panel_id == Some(panel_id) {
            self.focused_panel_id = self.layout.all_panel_ids().into_iter().next();
        }

        true
    }

    /// Get a reference to a panel by ID.
    pub fn panel(&self, id: Uuid) -> Option<&Panel> {
        self.panels.get(&id)
    }

    /// Get a mutable reference to a panel by ID.
    pub fn panel_mut(&mut self, id: Uuid) -> Option<&mut Panel> {
        self.panels.get_mut(&id)
    }

    /// Get all panel IDs in layout order.
    pub fn panel_ids(&self) -> Vec<Uuid> {
        self.layout.all_panel_ids()
    }

    /// Check if the workspace has no panels.
    pub fn is_empty(&self) -> bool {
        self.panels.is_empty()
    }

    /// Update the status entry for a key, creating it if it doesn't exist.
    pub fn set_status(&mut self, key: &str, value: &str, icon: Option<&str>, color: Option<&str>) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        if let Some(entry) = self.status_entries.iter_mut().find(|e| e.key == key) {
            entry.value = value.to_string();
            entry.icon = icon.map(|s| s.to_string());
            entry.color = color.map(|s| s.to_string());
            entry.timestamp = now;
        } else {
            self.status_entries.push(StatusEntry {
                key: key.to_string(),
                value: value.to_string(),
                icon: icon.map(|s| s.to_string()),
                color: color.map(|s| s.to_string()),
                timestamp: now,
            });
        }
    }

    /// Append a log entry.
    pub fn append_log(&mut self, message: &str, level: &str, source: Option<&str>) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        self.log_entries.push(LogEntry {
            message: message.to_string(),
            level: level.to_string(),
            source: source.map(|s| s.to_string()),
            timestamp: now,
        });
    }
}

impl Default for Workspace {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_workspace() {
        let ws = Workspace::new();
        assert_eq!(ws.panels.len(), 1);
        assert!(ws.focused_panel_id.is_some());
        assert_eq!(ws.display_title(), "Terminal");
    }

    #[test]
    fn test_split_workspace() {
        let mut ws = Workspace::new();
        let new_id = ws.split(SplitOrientation::Horizontal, PanelType::Terminal);
        assert_eq!(ws.panels.len(), 2);
        assert_eq!(ws.focused_panel_id, Some(new_id));
    }

    #[test]
    fn test_remove_panel() {
        let mut ws = Workspace::new();
        let new_id = ws.split(SplitOrientation::Horizontal, PanelType::Terminal);
        assert!(ws.remove_panel(new_id));
        assert_eq!(ws.panels.len(), 1);
    }

    #[test]
    fn test_status_entries() {
        let mut ws = Workspace::new();
        ws.set_status("agent", "claude-code", Some("robot"), None);
        assert_eq!(ws.status_entries.len(), 1);
        ws.set_status("agent", "claude-code v2", None, None);
        assert_eq!(ws.status_entries.len(), 1);
        assert_eq!(ws.status_entries[0].value, "claude-code v2");
    }
}
