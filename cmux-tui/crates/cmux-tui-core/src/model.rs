//! The session tree: workspaces own screens; each screen is a binary
//! split tree of panes; each pane holds an ordered list of tabs
//! (surfaces).

use std::collections::HashMap;
use std::sync::Arc;

use crate::{PaneId, ScreenId, SplitDir, SplitId, Surface, SurfaceId, WorkspaceId};

/// Pane membership for a stack. Construction rejects empty stacks so layout
/// and protocol consumers never need to assume a member exists.
#[derive(Debug, Clone)]
pub struct StackPanes(Vec<PaneId>);

impl StackPanes {
    pub fn new(panes: Vec<PaneId>) -> Option<Self> {
        (!panes.is_empty()).then_some(Self(panes))
    }

    pub fn as_slice(&self) -> &[PaneId] {
        &self.0
    }

    fn iter_mut(&mut self) -> impl Iterator<Item = &mut PaneId> {
        self.0.iter_mut()
    }

    fn retain(&mut self, predicate: impl FnMut(&PaneId) -> bool) {
        self.0.retain(predicate);
    }
}

impl std::ops::Deref for StackPanes {
    type Target = [PaneId];

    fn deref(&self) -> &Self::Target {
        self.as_slice()
    }
}

/// Binary split tree over panes for one screen.
#[derive(Debug, Clone)]
pub enum Node {
    Leaf(PaneId),
    Split {
        id: SplitId,
        dir: SplitDir,
        ratio: f32,
        a: Box<Node>,
        b: Box<Node>,
    },
    /// Zellij-style stacked panes. `expanded` preserves the selected member
    /// while focus is elsewhere in the split tree.
    Stack {
        panes: StackPanes,
        expanded: PaneId,
    },
}

impl Node {
    pub fn stack(panes: Vec<PaneId>) -> Option<Self> {
        let expanded = *panes.last()?;
        StackPanes::new(panes).map(|panes| Self::Stack { panes, expanded })
    }

    pub fn stack_with_expanded(panes: Vec<PaneId>, expanded: PaneId) -> Option<Self> {
        let panes = StackPanes::new(panes)?;
        panes.contains(&expanded).then_some(Self::Stack { panes, expanded })
    }

    pub fn pane_ids(&self, out: &mut Vec<PaneId>) {
        match self {
            Node::Leaf(id) => out.push(*id),
            Node::Split { a, b, .. } => {
                a.pane_ids(out);
                b.pane_ids(out);
            }
            Node::Stack { panes, .. } => out.extend(panes.iter().copied()),
        }
    }

    pub fn contains(&self, target: PaneId) -> bool {
        match self {
            Node::Leaf(id) => *id == target,
            Node::Split { a, b, .. } => a.contains(target) || b.contains(target),
            Node::Stack { panes, .. } => panes.contains(&target),
        }
    }

    pub(crate) fn contains_stack_pane(&self, target: PaneId) -> bool {
        match self {
            Node::Leaf(_) => false,
            Node::Split { a, b, .. } => {
                a.contains_stack_pane(target) || b.contains_stack_pane(target)
            }
            Node::Stack { panes, .. } => panes.contains(&target),
        }
    }

    pub(crate) fn expand_stack_pane(&mut self, target: PaneId) -> bool {
        match self {
            Node::Leaf(_) => false,
            Node::Split { a, b, .. } => a.expand_stack_pane(target) || b.expand_stack_pane(target),
            Node::Stack { panes, expanded } if panes.contains(&target) => {
                *expanded = target;
                true
            }
            Node::Stack { .. } => false,
        }
    }

    pub(crate) fn stack_expanded_pane(&self) -> Option<PaneId> {
        match self {
            Node::Leaf(_) => None,
            Node::Split { a, b, .. } => a.stack_expanded_pane().or_else(|| b.stack_expanded_pane()),
            Node::Stack { expanded, .. } => Some(*expanded),
        }
    }

    pub(crate) fn first_visible_pane(&self) -> PaneId {
        match self {
            Node::Leaf(pane) => *pane,
            Node::Split { a, .. } => a.first_visible_pane(),
            Node::Stack { expanded, .. } => *expanded,
        }
    }

    pub fn contains_split(&self, target: SplitId) -> bool {
        match self {
            Node::Leaf(_) => false,
            Node::Split { id, a, b, .. } => {
                *id == target || a.contains_split(target) || b.contains_split(target)
            }
            Node::Stack { .. } => false,
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
            Node::Stack { panes, expanded } => {
                let first_in_stack = panes.contains(&first);
                let second_in_stack = panes.contains(&second);
                for pane in panes.iter_mut() {
                    if *pane == first {
                        *pane = second;
                    } else if *pane == second {
                        *pane = first;
                    }
                }
                if first_in_stack != second_in_stack {
                    if *expanded == first {
                        *expanded = second;
                    } else if *expanded == second {
                        *expanded = first;
                    }
                }
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
            Node::Stack { panes, expanded } if panes.contains(&target) => {
                *expanded = target;
                let old = std::mem::replace(self, Node::Leaf(target));
                *self = Node::Split {
                    id: split_id,
                    dir,
                    ratio: 0.5,
                    a: Box::new(old),
                    b: Box::new(Node::Leaf(new_pane)),
                };
                true
            }
            Node::Stack { .. } => false,
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
            Node::Stack { panes, expanded } if !panes.contains(&target) => {
                Some(Node::Stack { panes, expanded })
            }
            Node::Stack { mut panes, expanded } => {
                panes.retain(|pane| *pane != target);
                match panes.as_slice() {
                    [] => None,
                    [pane] => Some(Node::Leaf(*pane)),
                    _ => {
                        let expanded = if expanded == target {
                            *panes.last().expect("retained stack is non-empty")
                        } else {
                            expanded
                        };
                        Some(Node::Stack { panes, expanded })
                    }
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
                Node::Stack { panes, .. } => (panes.contains(&target), false),
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
            Node::Stack { .. } => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stack_construction_rejects_empty_membership() {
        assert!(Node::stack(Vec::new()).is_none());
        assert!(Node::stack(vec![1]).is_some());
    }

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

    #[test]
    fn removing_an_unrelated_branch_preserves_a_singleton_stack() {
        let root = Node::Split {
            id: 10,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::stack_with_expanded(vec![1], 1).unwrap()),
            b: Box::new(Node::Leaf(2)),
        };

        let remaining = root.remove_leaf(2).unwrap();

        assert!(matches!(
            remaining,
            Node::Stack { ref panes, expanded: 1 } if panes.as_slice() == [1]
        ));
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
    /// Monotonic sequence updated only when this pane receives focus.
    pub focused_at: u64,
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
    /// Stable pane creation order for Zellij's default auto-layout family.
    /// `None` means the screen owns a custom/damaged layout.
    pub zellij_auto_layout: Option<Vec<PaneId>>,
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
    /// Monotonic version of the live pane-ID set. Focus, layout, tab, screen,
    /// and workspace selection changes do not advance this counter.
    pub pane_revision: u64,
    pub(crate) focus_sequence: u64,
    pub active_workspace: usize,
    pub panes: HashMap<PaneId, Pane>,
    pub surfaces: HashMap<SurfaceId, Arc<Surface>>,
    pub(crate) split_screens: HashMap<SplitId, (usize, usize, ScreenId)>,
}

impl State {
    pub(crate) fn next_focus_sequence(&mut self) -> u64 {
        self.focus_sequence = self.focus_sequence.saturating_add(1);
        self.focus_sequence
    }

    pub(crate) fn insert_pane(&mut self, pane: Pane) {
        let id = pane.id;
        let replaced = self.panes.insert(id, pane);
        debug_assert!(replaced.is_none(), "pane {id} was inserted twice");
        if replaced.is_none() {
            self.pane_revision = self.pane_revision.saturating_add(1);
        }
    }

    pub(crate) fn remove_pane(&mut self, pane: PaneId) -> Option<Pane> {
        let removed = self.panes.remove(&pane);
        if removed.is_some() {
            self.pane_revision = self.pane_revision.saturating_add(1);
        }
        removed
    }

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
