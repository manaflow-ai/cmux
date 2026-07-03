//! The session tree: workspaces own a binary split tree of panes; each
//! pane holds an ordered list of tabs (surfaces).

use std::collections::HashMap;
use std::sync::Arc;

use crate::{PaneId, SplitDir, Surface, SurfaceId, WorkspaceId};

/// Binary split tree over panes for one workspace.
#[derive(Debug, Clone)]
pub enum Node {
    Leaf(PaneId),
    Split { dir: SplitDir, ratio: f32, a: Box<Node>, b: Box<Node> },
}

impl Node {
    pub fn pane_ids(&self, out: &mut Vec<PaneId>) {
        match self {
            Node::Leaf(id) => out.push(*id),
            Node::Split { a, b, .. } => {
                a.pane_ids(out);
                b.pane_ids(out);
            }
        }
    }

    pub fn contains(&self, target: PaneId) -> bool {
        match self {
            Node::Leaf(id) => *id == target,
            Node::Split { a, b, .. } => a.contains(target) || b.contains(target),
        }
    }

    pub(crate) fn split_leaf(&mut self, target: PaneId, dir: SplitDir, new_pane: PaneId) -> bool {
        match self {
            Node::Leaf(id) if *id == target => {
                let old = Node::Leaf(*id);
                *self = Node::Split {
                    dir,
                    ratio: 0.5,
                    a: Box::new(old),
                    b: Box::new(Node::Leaf(new_pane)),
                };
                true
            }
            Node::Leaf(_) => false,
            Node::Split { a, b, .. } => {
                a.split_leaf(target, dir, new_pane) || b.split_leaf(target, dir, new_pane)
            }
        }
    }

    /// Remove a leaf, collapsing its parent split. Returns None when the
    /// whole node was the removed leaf.
    pub(crate) fn remove_leaf(self, target: PaneId) -> Option<Node> {
        match self {
            Node::Leaf(id) if id == target => None,
            leaf @ Node::Leaf(_) => Some(leaf),
            Node::Split { dir, ratio, a, b } => {
                match (a.remove_leaf(target), b.remove_leaf(target)) {
                    (Some(a), Some(b)) => {
                        Some(Node::Split { dir, ratio, a: Box::new(a), b: Box::new(b) })
                    }
                    (Some(a), None) => Some(a),
                    (None, Some(b)) => Some(b),
                    (None, None) => None,
                }
            }
        }
    }
}

/// A split-tree leaf: an ordered list of tabs (surfaces) with one active.
#[derive(Debug)]
pub struct Pane {
    pub id: PaneId,
    /// User-assigned name; falls back to the active tab's title.
    pub name: Option<String>,
    pub tabs: Vec<SurfaceId>,
    pub active_tab: usize,
}

impl Pane {
    pub fn active_surface(&self) -> Option<SurfaceId> {
        self.tabs.get(self.active_tab).copied()
    }
}

#[derive(Debug)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub name: String,
    pub root: Node,
    pub active_pane: PaneId,
}

/// The full mutable session state, exposed to [`crate::Mux::with_state`]
/// closures.
pub struct State {
    pub workspaces: Vec<Workspace>,
    pub active_workspace: usize,
    pub panes: HashMap<PaneId, Pane>,
    pub surfaces: HashMap<SurfaceId, Arc<Surface>>,
}

impl State {
    /// The workspace containing a pane.
    pub fn workspace_of(&self, pane: PaneId) -> Option<usize> {
        self.workspaces.iter().position(|ws| ws.root.contains(pane))
    }

    /// The pane a surface currently lives in.
    pub fn pane_of(&self, surface: SurfaceId) -> Option<PaneId> {
        self.panes.values().find(|p| p.tabs.contains(&surface)).map(|p| p.id)
    }

    pub fn active_pane(&self) -> Option<PaneId> {
        self.workspaces.get(self.active_workspace).map(|ws| ws.active_pane)
    }
}
