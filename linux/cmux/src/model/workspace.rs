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
    /// Sidebar summary for the latest notification in this workspace.
    pub latest_notification: Option<String>,
    /// Timestamp of the latest notification, used for latest-unread routing.
    pub latest_notification_at: Option<f64>,
    /// Panel that most recently requested attention, if known.
    pub attention_panel_id: Option<Uuid>,
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

/// Truncate a string to at most `max_bytes` bytes without splitting UTF-8.
pub fn truncate_str(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }

    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

impl Workspace {
    /// Create a new workspace with a single terminal panel.
    pub fn new() -> Self {
        let current_directory = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
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
            current_directory,
            focused_panel_id: Some(panel_id),
            layout: LayoutNode::single_pane(panel_id),
            panels,
            status_entries: Vec::new(),
            log_entries: Vec::new(),
            progress: None,
            git_branch: None,
            unread_count: 0,
            latest_notification: None,
            latest_notification_at: None,
            attention_panel_id: None,
        }
    }

    /// Create a new workspace with a specific working directory.
    pub fn with_directory(directory: &str) -> Self {
        let mut ws = Self::new();
        ws.current_directory = directory.to_string();
        if let Some(panel_id) = ws.focused_panel_id {
            if let Some(panel) = ws.panels.get_mut(&panel_id) {
                panel.directory = Some(directory.to_string());
            }
        }
        ws
    }

    /// Display title: custom title if set, otherwise process title.
    pub fn display_title(&self) -> &str {
        self.custom_title.as_deref().unwrap_or(&self.process_title)
    }

    /// Add a new panel by splitting the focused pane.
    pub fn split(&mut self, orientation: SplitOrientation, panel_type: PanelType) -> Uuid {
        let new_panel = match panel_type {
            PanelType::Terminal => Panel::new_terminal(),
            PanelType::Browser => Panel::new_browser(),
        };
        let new_id = new_panel.id;
        self.panels.insert(new_id, new_panel);

        // Find the focused pane and split it
        let mut split_done = false;
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
                split_done = true;
            }
        }

        if !split_done {
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

    const MAX_STATUS_ENTRIES: usize = 100;
    const MAX_STATUS_KEY_LEN: usize = 256;
    const MAX_STATUS_VALUE_LEN: usize = 4096;

    /// Update the status entry for a key, creating it if it doesn't exist.
    pub fn set_status(&mut self, key: &str, value: &str, icon: Option<&str>, color: Option<&str>) {
        let key = truncate_str(key, Self::MAX_STATUS_KEY_LEN);
        let value = truncate_str(value, Self::MAX_STATUS_VALUE_LEN);
        let icon = icon.map(|s| truncate_str(s, 256));
        let color = color.map(|s| truncate_str(s, 64));
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
            if self.status_entries.len() >= Self::MAX_STATUS_ENTRIES {
                if let Some(oldest_idx) = self
                    .status_entries
                    .iter()
                    .enumerate()
                    .min_by(|a, b| {
                        a.1.timestamp
                            .partial_cmp(&b.1.timestamp)
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .map(|(idx, _)| idx)
                {
                    self.status_entries.remove(oldest_idx);
                }
            }
            self.status_entries.push(StatusEntry {
                key: key.to_string(),
                value: value.to_string(),
                icon: icon.map(|s| s.to_string()),
                color: color.map(|s| s.to_string()),
                timestamp: now,
            });
        }
    }

    const MAX_LOG_ENTRIES: usize = 1000;
    const MAX_LOG_MESSAGE_LEN: usize = 8192;

    /// Append a log entry.
    pub fn append_log(&mut self, message: &str, level: &str, source: Option<&str>) {
        let message = truncate_str(message, Self::MAX_LOG_MESSAGE_LEN);
        let level = truncate_str(level, 64);
        let source = source.map(|s| truncate_str(s, 256));
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        if self.log_entries.len() >= Self::MAX_LOG_ENTRIES {
            self.log_entries.drain(..self.log_entries.len() / 4);
        }

        self.log_entries.push(LogEntry {
            message: message.to_string(),
            level: level.to_string(),
            source: source.map(|s| s.to_string()),
            timestamp: now,
        });
    }

    /// Most relevant status label for the sidebar.
    pub fn sidebar_status_label(&self) -> Option<&str> {
        self.status_entries
            .iter()
            .rev()
            .find(|entry| entry.key == "agent")
            .or_else(|| self.status_entries.last())
            .map(|entry| entry.value.as_str())
    }

    /// Record an attention event from a notification.
    pub fn record_notification(&mut self, title: &str, body: &str, panel_id: Option<Uuid>) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        self.unread_count = self.unread_count.saturating_add(1);
        self.latest_notification = Some(notification_summary(title, body));
        self.latest_notification_at = Some(now);
        self.attention_panel_id = panel_id.filter(|id| self.panels.contains_key(id));
    }

    /// Mark all workspace notifications as read.
    pub fn mark_notifications_read(&mut self) {
        self.unread_count = 0;
    }

    /// Focus a specific panel and reveal its tab.
    pub fn focus_panel(&mut self, panel_id: Uuid) -> bool {
        if !self.panels.contains_key(&panel_id) {
            return false;
        }

        if self.layout.select_panel(panel_id) {
            self.focused_panel_id = Some(panel_id);
            true
        } else {
            false
        }
    }
}

fn notification_summary(title: &str, body: &str) -> String {
    let title = title.trim();
    let body = body.trim();
    let summary = match (title.is_empty(), body.is_empty()) {
        (false, false) if body == title => title.to_string(),
        (false, false) => format!("{title}: {body}"),
        (false, true) => title.to_string(),
        (true, false) => body.to_string(),
        (true, true) => "Notification".to_string(),
    };

    let single_line = summary.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate_for_sidebar(&single_line, 120)
}

fn truncate_for_sidebar(text: &str, max_chars: usize) -> String {
    let mut truncated = text.chars().take(max_chars).collect::<String>();
    if text.chars().count() > max_chars {
        truncated.push_str("...");
    }
    truncated
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
        let panel_id = ws.focused_panel_id.expect("workspace should have a panel");
        assert_eq!(
            ws.panels
                .get(&panel_id)
                .and_then(|panel| panel.directory.as_deref()),
            None
        );
    }

    #[test]
    fn test_split_workspace() {
        let mut ws = Workspace::new();
        let new_id = ws.split(SplitOrientation::Horizontal, PanelType::Terminal);
        assert_eq!(ws.panels.len(), 2);
        assert_eq!(ws.focused_panel_id, Some(new_id));
        assert_eq!(
            ws.panels
                .get(&new_id)
                .and_then(|panel| panel.directory.as_deref()),
            None
        );
    }

    #[test]
    fn test_with_directory_updates_initial_terminal_panel() {
        let ws = Workspace::with_directory("/tmp/cmux-test");
        let panel_id = ws.focused_panel_id.expect("workspace should have a panel");
        assert_eq!(ws.current_directory, "/tmp/cmux-test");
        assert_eq!(
            ws.panels
                .get(&panel_id)
                .and_then(|panel| panel.directory.as_deref()),
            Some("/tmp/cmux-test")
        );
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

    #[test]
    fn test_status_entry_eviction_preserves_remaining_order() {
        let mut ws = Workspace::new();

        for i in 0..100 {
            ws.set_status(&format!("key-{i}"), &format!("value-{i}"), None, None);
        }

        ws.set_status("key-100", "value-100", None, None);

        assert_eq!(ws.status_entries.len(), 100);
        assert_eq!(
            ws.status_entries.first().map(|entry| entry.key.as_str()),
            Some("key-1")
        );
        assert_eq!(
            ws.status_entries.last().map(|entry| entry.key.as_str()),
            Some("key-100")
        );
    }

    #[test]
    fn test_record_notification_updates_unread_and_summary() {
        let mut ws = Workspace::new();
        let panel_id = ws.focused_panel_id;
        ws.record_notification("Codex", "Waiting for input", panel_id);

        assert_eq!(ws.unread_count, 1);
        assert_eq!(
            ws.latest_notification.as_deref(),
            Some("Codex: Waiting for input")
        );
        assert_eq!(ws.attention_panel_id, panel_id);
        assert!(ws.latest_notification_at.is_some());
    }

    #[test]
    fn test_record_notification_does_not_steal_focus() {
        let mut ws = Workspace::new();
        let original_focus = ws
            .focused_panel_id
            .expect("workspace should have a focused panel");
        let other_panel_id = ws.split(SplitOrientation::Horizontal, PanelType::Terminal);
        assert_eq!(ws.focused_panel_id, Some(other_panel_id));

        ws.focus_panel(original_focus);
        ws.record_notification("Codex", "Waiting for input", Some(other_panel_id));

        assert_eq!(ws.focused_panel_id, Some(original_focus));
        assert_eq!(ws.attention_panel_id, Some(other_panel_id));
    }

    #[test]
    fn test_mark_notifications_read_clears_unread_count() {
        let mut ws = Workspace::new();
        ws.record_notification("Claude Code", "Approval needed", None);
        assert_eq!(ws.unread_count, 1);

        ws.mark_notifications_read();
        assert_eq!(ws.unread_count, 0);
    }

    #[test]
    fn test_split_falls_back_to_root_when_focused_panel_is_stale() {
        let mut ws = Workspace::new();
        ws.focused_panel_id = Some(uuid::Uuid::new_v4());

        let new_id = ws.split(SplitOrientation::Horizontal, PanelType::Terminal);

        assert_eq!(ws.focused_panel_id, Some(new_id));
        assert!(ws.layout.all_panel_ids().contains(&new_id));
    }

    #[test]
    fn test_focus_panel_does_not_update_focus_when_layout_select_fails() {
        let mut ws = Workspace::new();
        let original_focus = ws.focused_panel_id;
        let panel_id = original_focus.expect("workspace should have a focused panel");

        ws.layout = LayoutNode::single_pane(uuid::Uuid::new_v4());

        assert!(!ws.focus_panel(panel_id));
        assert_eq!(ws.focused_panel_id, original_focus);
    }

    #[test]
    fn test_truncate_str_preserves_utf8_boundaries() {
        assert_eq!(truncate_str("abcdef", 4), "abcd");
        assert_eq!(truncate_str("あいう", 4), "あ");
    }
}
