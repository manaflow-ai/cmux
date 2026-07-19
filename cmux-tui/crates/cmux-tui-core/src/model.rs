//! The session tree: workspaces own screens; each screen is a binary
//! split tree of panes; each pane holds an ordered list of tabs
//! (surfaces).

use std::collections::HashMap;
use std::sync::Arc;

use crate::{PaneId, ScreenId, SplitDir, SplitId, Surface, SurfaceId, WorkspaceId};

/// Binary split tree over panes for one screen.
#[derive(Debug, Clone)]
pub enum Node {
    Leaf(PaneId),
    Split { id: SplitId, dir: SplitDir, ratio: f32, a: Box<Node>, b: Box<Node> },
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

    pub fn contains_split(&self, target: SplitId) -> bool {
        match self {
            Node::Leaf(_) => false,
            Node::Split { id, a, b, .. } => {
                *id == target || a.contains_split(target) || b.contains_split(target)
            }
        }
    }

    pub(crate) fn swap_leaves(&mut self, first: PaneId, second: PaneId) -> bool {
        if first == second || !self.contains(first) || !self.contains(second) {
            return false;
        }
        self.swap_leaf_ids(first, second);
        true
    }

    fn swap_leaf_ids(&mut self, first: PaneId, second: PaneId) {
        match self {
            Node::Leaf(id) if *id == first => *id = second,
            Node::Leaf(id) if *id == second => *id = first,
            Node::Leaf(_) => {}
            Node::Split { a, b, .. } => {
                a.swap_leaf_ids(first, second);
                b.swap_leaf_ids(first, second);
            }
        }
    }

    pub(crate) fn split_leaf(
        &mut self,
        target: PaneId,
        split_id: SplitId,
        dir: SplitDir,
        new_pane: PaneId,
    ) -> bool {
        match self {
            Node::Leaf(id) if *id == target => {
                let old = Node::Leaf(*id);
                *self = Node::Split {
                    id: split_id,
                    dir,
                    ratio: 0.5,
                    a: Box::new(old),
                    b: Box::new(Node::Leaf(new_pane)),
                };
                true
            }
            Node::Leaf(_) => false,
            Node::Split { a, b, .. } => {
                a.split_leaf(target, split_id, dir, new_pane)
                    || b.split_leaf(target, split_id, dir, new_pane)
            }
        }
    }

    /// Remove a leaf, collapsing its parent split. Returns None when the
    /// whole node was the removed leaf.
    pub(crate) fn remove_leaf(self, target: PaneId) -> Option<Node> {
        match self {
            Node::Leaf(id) if id == target => None,
            leaf @ Node::Leaf(_) => Some(leaf),
            Node::Split { id, dir, ratio, a, b } => {
                match (a.remove_leaf(target), b.remove_leaf(target)) {
                    (Some(a), Some(b)) => {
                        Some(Node::Split { id, dir, ratio, a: Box::new(a), b: Box::new(b) })
                    }
                    (Some(a), None) => Some(a),
                    (None, Some(b)) => Some(b),
                    (None, None) => None,
                }
            }
        }
    }

    pub(crate) fn set_deepest_ratio(
        &mut self,
        target: PaneId,
        dir: SplitDir,
        new_ratio: f32,
    ) -> bool {
        fn walk(node: &mut Node, target: PaneId, dir: SplitDir, new_ratio: f32) -> (bool, bool) {
            match node {
                Node::Leaf(id) => (*id == target, false),
                Node::Split { dir: split_dir, ratio, a, b, .. } => {
                    let (a_contains, a_updated) = walk(a, target, dir, new_ratio);
                    if a_updated {
                        return (true, true);
                    }
                    let (b_contains, b_updated) = walk(b, target, dir, new_ratio);
                    if b_updated {
                        return (true, true);
                    }
                    let contains = a_contains || b_contains;
                    if contains && *split_dir == dir {
                        *ratio = new_ratio;
                        (true, true)
                    } else {
                        (contains, false)
                    }
                }
            }
        }

        walk(self, target, dir, new_ratio).1
    }

    pub(crate) fn set_split_ratio(&mut self, target: SplitId, new_ratio: f32) -> bool {
        match self {
            Node::Leaf(_) => false,
            Node::Split { id, ratio, a, b, .. } => {
                if *id == target {
                    *ratio = new_ratio;
                    true
                } else {
                    a.set_split_ratio(target, new_ratio) || b.set_split_ratio(target, new_ratio)
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nested_tree() -> Node {
        Node::Split {
            id: 10,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Split {
                id: 11,
                dir: SplitDir::Right,
                ratio: 0.4,
                a: Box::new(Node::Leaf(1)),
                b: Box::new(Node::Leaf(2)),
            }),
            b: Box::new(Node::Leaf(3)),
        }
    }

    #[test]
    fn split_ids_survive_leaf_swaps_and_unrelated_ratio_updates() {
        let mut root = nested_tree();

        assert!(root.swap_leaves(1, 3));
        assert!(root.set_deepest_ratio(2, SplitDir::Right, 0.7));

        assert!(root.contains_split(10));
        assert!(root.contains_split(11));
        assert!(!root.contains_split(12));
        let Node::Split { id, a, .. } = root else { panic!("root should be split") };
        assert_eq!(id, 10);
        let Node::Split { id, .. } = a.as_ref() else { panic!("child should be split") };
        assert_eq!(*id, 11);
    }

    #[test]
    fn exact_split_ratio_targets_one_same_direction_node() {
        let mut root = nested_tree();

        assert!(root.set_split_ratio(10, 0.8));
        let Node::Split { ratio: root_ratio, a, .. } = &root else {
            panic!("root should be split");
        };
        assert_eq!(*root_ratio, 0.8);
        let Node::Split { ratio: inner_ratio, .. } = a.as_ref() else {
            panic!("child should be split");
        };
        assert_eq!(*inner_ratio, 0.4);
        assert!(!root.set_split_ratio(999, 0.2));
    }

    #[test]
    fn collapsing_a_parent_preserves_surviving_descendant_split_id() {
        let root = nested_tree();

        let collapsed = root.remove_leaf(3).expect("left subtree should survive");

        let Node::Split { id, .. } = collapsed else { panic!("child split should survive") };
        assert_eq!(id, 11);
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
    pub active_at: u64,
}

impl Pane {
    pub fn active_surface(&self) -> Option<SurfaceId> {
        self.tabs.get(self.active_tab).copied()
    }
}

/// One split-tree of panes. A workspace can hold many screens; exactly
/// one is visible at a time (the status bar switches between them).
#[derive(Debug)]
pub struct Screen {
    pub id: ScreenId,
    /// User-assigned name; display falls back to the screen's number.
    pub name: Option<String>,
    pub root: Node,
    pub active_pane: PaneId,
    pub zoomed_pane: Option<PaneId>,
}

#[derive(Debug)]
pub struct Workspace {
    pub id: WorkspaceId,
    /// Stable external identity used by detached frontends. Unlike `id`, this
    /// survives snapshot/reconciliation boundaries and is safe to persist in
    /// a frontend's richer layout state.
    pub key: String,
    pub name: String,
    pub screens: Vec<Screen>,
    pub active_screen: usize,
}

impl Workspace {
    pub fn active_screen_ref(&self) -> Option<&Screen> {
        self.screens.get(self.active_screen)
    }
}

/// The full mutable session state, exposed to [`crate::Mux::with_state`]
/// closures.
pub struct State {
    pub workspaces: Vec<Workspace>,
    pub(crate) workspace_index_by_id: HashMap<WorkspaceId, usize>,
    pub(crate) workspace_id_by_key: HashMap<String, WorkspaceId>,
    /// Monotonic version of the ordered workspace registry. Pane, screen, and
    /// tab-only mutations do not advance this counter.
    pub workspace_revision: u64,
    pub active_workspace: usize,
    pub panes: HashMap<PaneId, Pane>,
    pub surfaces: HashMap<SurfaceId, Arc<Surface>>,
    pub(crate) split_screens: HashMap<SplitId, (usize, usize, ScreenId)>,
}

impl State {
    pub(crate) fn push_workspace(&mut self, workspace: Workspace) {
        let index = self.workspaces.len();
        debug_assert!(!self.workspace_index_by_id.contains_key(&workspace.id));
        debug_assert!(!self.workspace_id_by_key.contains_key(&workspace.key));
        self.workspace_index_by_id.insert(workspace.id, index);
        self.workspace_id_by_key.insert(workspace.key.clone(), workspace.id);
        self.workspaces.push(workspace);
    }

    pub(crate) fn remove_workspace(&mut self, index: usize) -> Workspace {
        let workspace = self.workspaces.remove(index);
        self.rebuild_workspace_indexes();
        workspace
    }

    pub(crate) fn move_workspace(&mut self, old_index: usize, new_index: usize) {
        let workspace = self.workspaces.remove(old_index);
        self.workspaces.insert(new_index, workspace);
        self.rebuild_workspace_indexes();
    }

    pub(crate) fn rebuild_workspace_indexes(&mut self) {
        self.workspace_index_by_id.clear();
        self.workspace_id_by_key.clear();
        for (index, workspace) in self.workspaces.iter().enumerate() {
            self.workspace_index_by_id.insert(workspace.id, index);
            self.workspace_id_by_key.insert(workspace.key.clone(), workspace.id);
        }
    }

    pub(crate) fn workspace_index(&self, id: WorkspaceId) -> Option<usize> {
        self.workspace_index_by_id.get(&id).copied()
    }

    pub(crate) fn workspace_by_id(&self, id: WorkspaceId) -> Option<&Workspace> {
        self.workspace_index(id).and_then(|index| self.workspaces.get(index))
    }

    pub(crate) fn workspace_by_key(&self, key: &str) -> Option<&Workspace> {
        self.workspace_id_by_key.get(key).and_then(|id| self.workspace_by_id(*id))
    }

    /// Workspace and screen indices of the screen containing a pane.
    pub fn screen_of(&self, pane: PaneId) -> Option<(usize, usize)> {
        self.workspaces.iter().enumerate().find_map(|(wi, ws)| {
            ws.screens.iter().position(|screen| screen.root.contains(pane)).map(|si| (wi, si))
        })
    }

    /// The pane a surface currently lives in.
    pub fn pane_of(&self, surface: SurfaceId) -> Option<PaneId> {
        self.panes.values().find(|p| p.tabs.contains(&surface)).map(|p| p.id)
    }

    pub fn active_pane(&self) -> Option<PaneId> {
        self.workspaces
            .get(self.active_workspace)?
            .active_screen_ref()
            .map(|screen| screen.active_pane)
    }
}
