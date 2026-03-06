//! Panel model — represents a terminal or browser panel within a workspace.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Panel type discriminator.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PanelType {
    Terminal,
    Browser,
}

/// A panel within a workspace pane.
///
/// Panels are the leaf nodes of the layout tree. Each panel is either a
/// terminal (backed by a ghostty surface) or a browser (WebKit2GTK).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Panel {
    pub id: Uuid,
    pub panel_type: PanelType,
    pub title: Option<String>,
    pub custom_title: Option<String>,
    pub directory: Option<String>,
    pub is_pinned: bool,
    pub is_manually_unread: bool,
    pub git_branch: Option<GitBranch>,
    pub listening_ports: Vec<u16>,
    pub tty_name: Option<String>,
}

impl Panel {
    /// Create a new terminal panel.
    pub fn new_terminal() -> Self {
        Self {
            id: Uuid::new_v4(),
            panel_type: PanelType::Terminal,
            title: None,
            custom_title: None,
            directory: None,
            is_pinned: false,
            is_manually_unread: false,
            git_branch: None,
            listening_ports: Vec::new(),
            tty_name: None,
        }
    }

    /// Create a new browser panel.
    pub fn new_browser() -> Self {
        Self {
            id: Uuid::new_v4(),
            panel_type: PanelType::Browser,
            title: None,
            custom_title: None,
            directory: None,
            is_pinned: false,
            is_manually_unread: false,
            git_branch: None,
            listening_ports: Vec::new(),
            tty_name: None,
        }
    }

    /// Display title: custom title if set, otherwise process title, otherwise "Terminal"/"Browser".
    pub fn display_title(&self) -> &str {
        if let Some(ref t) = self.custom_title {
            return t;
        }
        if let Some(ref t) = self.title {
            return t;
        }
        match self.panel_type {
            PanelType::Terminal => "Terminal",
            PanelType::Browser => "Browser",
        }
    }
}

/// Git branch info for a panel or workspace.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitBranch {
    pub branch: String,
    pub is_dirty: bool,
}

/// Recursive layout tree for workspace pane arrangement.
///
/// A workspace's content area is described by a `LayoutNode`:
/// - `Pane`: a leaf containing one or more panels (tabs within a pane)
/// - `Split`: a binary split (horizontal or vertical) with two children
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum LayoutNode {
    #[serde(rename = "pane")]
    Pane {
        /// Panel IDs in tab order within this pane.
        panel_ids: Vec<Uuid>,
        /// Currently selected panel in this pane.
        selected_panel_id: Option<Uuid>,
    },
    #[serde(rename = "split")]
    Split {
        orientation: SplitOrientation,
        /// Normalized divider position (0.0 to 1.0).
        divider_position: f64,
        first: Box<LayoutNode>,
        second: Box<LayoutNode>,
    },
}

/// Split orientation for layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SplitOrientation {
    Horizontal,
    Vertical,
}

impl LayoutNode {
    /// Create a simple single-pane layout with one panel.
    pub fn single_pane(panel_id: Uuid) -> Self {
        LayoutNode::Pane {
            panel_ids: vec![panel_id],
            selected_panel_id: Some(panel_id),
        }
    }

    /// Split this node, placing the existing content in the first half
    /// and a new panel in the second half.
    pub fn split(self, orientation: SplitOrientation, new_panel_id: Uuid) -> Self {
        LayoutNode::Split {
            orientation,
            divider_position: 0.5,
            first: Box::new(self),
            second: Box::new(LayoutNode::Pane {
                panel_ids: vec![new_panel_id],
                selected_panel_id: Some(new_panel_id),
            }),
        }
    }

    /// Collect all panel IDs in this layout tree.
    pub fn all_panel_ids(&self) -> Vec<Uuid> {
        match self {
            LayoutNode::Pane { panel_ids, .. } => panel_ids.clone(),
            LayoutNode::Split { first, second, .. } => {
                let mut ids = first.all_panel_ids();
                ids.extend(second.all_panel_ids());
                ids
            }
        }
    }

    /// Find the pane containing the given panel ID and return a mutable reference.
    pub fn find_pane_with_panel(&mut self, panel_id: Uuid) -> Option<&mut LayoutNode> {
        match self {
            LayoutNode::Pane { panel_ids, .. } => {
                if panel_ids.contains(&panel_id) {
                    Some(self)
                } else {
                    None
                }
            }
            LayoutNode::Split { first, second, .. } => first
                .find_pane_with_panel(panel_id)
                .or_else(|| second.find_pane_with_panel(panel_id)),
        }
    }

    /// Remove a panel from the layout. If a pane becomes empty, the split
    /// is collapsed. Returns true if the panel was found and removed.
    pub fn remove_panel(&mut self, panel_id: Uuid) -> bool {
        match self {
            LayoutNode::Pane {
                panel_ids,
                selected_panel_id,
            } => {
                if let Some(pos) = panel_ids.iter().position(|&id| id == panel_id) {
                    panel_ids.remove(pos);
                    if *selected_panel_id == Some(panel_id) {
                        *selected_panel_id = panel_ids.first().copied();
                    }
                    true
                } else {
                    false
                }
            }
            LayoutNode::Split { first, second, .. } => {
                let removed = first.remove_panel(panel_id) || second.remove_panel(panel_id);
                if removed {
                    // Collapse if either side is now empty
                    if first.is_empty() {
                        *self = *second.clone();
                    } else if second.is_empty() {
                        *self = *first.clone();
                    }
                }
                removed
            }
        }
    }

    /// Check if this node contains no panels.
    pub fn is_empty(&self) -> bool {
        match self {
            LayoutNode::Pane { panel_ids, .. } => panel_ids.is_empty(),
            LayoutNode::Split { first, second, .. } => first.is_empty() && second.is_empty(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_single_pane() {
        let id = Uuid::new_v4();
        let node = LayoutNode::single_pane(id);
        assert_eq!(node.all_panel_ids(), vec![id]);
    }

    #[test]
    fn test_split() {
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        let node = LayoutNode::single_pane(id1).split(SplitOrientation::Horizontal, id2);
        let ids = node.all_panel_ids();
        assert_eq!(ids.len(), 2);
        assert!(ids.contains(&id1));
        assert!(ids.contains(&id2));
    }

    #[test]
    fn test_remove_panel_collapses_split() {
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        let mut node = LayoutNode::single_pane(id1).split(SplitOrientation::Horizontal, id2);
        assert!(node.remove_panel(id2));
        assert_eq!(node.all_panel_ids(), vec![id1]);
        // Should have collapsed back to a single pane
        assert!(matches!(node, LayoutNode::Pane { .. }));
    }

    #[test]
    fn test_layout_serialization_roundtrip() {
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        let node = LayoutNode::single_pane(id1).split(SplitOrientation::Vertical, id2);
        let json = serde_json::to_string(&node).unwrap();
        let restored: LayoutNode = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.all_panel_ids().len(), 2);
    }
}
