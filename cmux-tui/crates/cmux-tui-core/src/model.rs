//! The session tree: workspaces own screens; each screen is a binary
//! split tree of panes; each pane holds an ordered list of tabs
//! (surfaces).

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::Arc;

use crate::{PaneId, ScreenId, SplitDir, SplitId, Surface, SurfaceId, WorkspaceId};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewportColumn {
    Base,
    Split(SplitId),
}

/// One stable horizontal column in a scrollable screen.
///
/// `Screen::root` remains the compatibility projection consumed by existing
/// split-tree clients. While columns are active, these records own the real
/// per-column trees and Zellij auto-layout order.
#[derive(Debug, Clone)]
pub(crate) struct LayoutColumn {
    pub(crate) id: SplitId,
    pub(crate) width: f32,
    pub(crate) root: Node,
    pub(crate) zellij_auto_layout: Option<Vec<PaneId>>,
}

#[derive(Debug, Clone)]
pub(crate) struct ScreenLayoutSnapshot {
    pub root: Node,
    pub active_pane: PaneId,
    pub zoomed_pane: Option<PaneId>,
    pub zellij_auto_layout: Option<Vec<PaneId>>,
    pub viewport_splits: BTreeMap<SplitId, f32>,
    pub viewport_base_width: Option<f32>,
    pub layout_columns: Vec<LayoutColumn>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LayoutMutationKey {
    Split { split: SplitId, client: u64, transaction: u64 },
    Column { column: SplitId, client: u64, transaction: u64 },
}

#[derive(Debug, Clone)]
pub(crate) struct LayoutUndoEntry {
    pub before: ScreenLayoutSnapshot,
    pub after_revision: u64,
    pub created_panes: Vec<PaneId>,
    pub coalesce: Option<LayoutMutationKey>,
}

const LAYOUT_UNDO_LIMIT: usize = 32;

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

    pub fn pane_ids_vec(&self) -> Vec<PaneId> {
        let mut panes = Vec::new();
        self.pane_ids(&mut panes);
        panes
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
            Node::Stack { panes, expanded } if panes.contains(&target) && *expanded != target => {
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

    pub(crate) fn swap_leaf_ids(&mut self, first: PaneId, second: PaneId) {
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

    pub fn viewport_column_owner(
        &self,
        target: PaneId,
        viewport_splits: &BTreeMap<SplitId, f32>,
    ) -> Option<ViewportColumn> {
        match self {
            Node::Split { id, a, b, .. } if viewport_splits.contains_key(id) => {
                if b.contains(target) {
                    Some(ViewportColumn::Split(*id))
                } else {
                    a.viewport_column_owner(target, viewport_splits)
                }
            }
            node => node.contains(target).then_some(ViewportColumn::Base),
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

    fn set_split_ratios(&mut self, ratios: &BTreeMap<SplitId, f32>) {
        match self {
            Node::Leaf(_) | Node::Stack { .. } => {}
            Node::Split { id, ratio, a, b, .. } => {
                if let Some(updated) = ratios.get(id) {
                    *ratio = *updated;
                }
                a.set_split_ratios(ratios);
                b.set_split_ratios(ratios);
            }
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
    /// Horizontal splits created as viewport columns. The value is the
    /// right-hand column width as a fraction of the frontend viewport.
    pub viewport_splits: BTreeMap<SplitId, f32>,
    /// Width of the first viewport column. `None` when horizontal viewport
    /// layout has not been activated for this screen.
    pub viewport_base_width: Option<f32>,
    /// Stable horizontal layout containers. Empty means the screen follows
    /// the ordinary single-tree behavior. `root`, `viewport_splits`, and
    /// `viewport_base_width` are derived compatibility projections while
    /// this list is non-empty.
    pub(crate) layout_columns: Vec<LayoutColumn>,
    /// Monotonic structural revision used to fence layout undo.
    pub(crate) layout_revision: u64,
    /// In-memory only. Pane processes cannot be resurrected across daemon
    /// restarts, so persisting this history would create unsafe expectations.
    pub(crate) layout_undo: VecDeque<LayoutUndoEntry>,
}

impl Screen {
    pub(crate) fn layout_snapshot(&self) -> ScreenLayoutSnapshot {
        ScreenLayoutSnapshot {
            root: self.root.clone(),
            active_pane: self.active_pane,
            zoomed_pane: self.zoomed_pane,
            zellij_auto_layout: self.zellij_auto_layout.clone(),
            viewport_splits: self.viewport_splits.clone(),
            viewport_base_width: self.viewport_base_width,
            layout_columns: self.layout_columns.clone(),
        }
    }

    fn coalesces_layout_change(&self, key: LayoutMutationKey) -> bool {
        self.layout_undo.back().is_some_and(|entry| {
            entry.created_panes.is_empty()
                && entry.coalesce == Some(key)
                && entry.after_revision == self.layout_revision
        })
    }

    pub(crate) fn layout_snapshot_for_coalescing_change(
        &self,
        key: Option<LayoutMutationKey>,
    ) -> Option<ScreenLayoutSnapshot> {
        if key.is_some_and(|key| self.coalesces_layout_change(key)) {
            None
        } else {
            Some(self.layout_snapshot())
        }
    }

    pub(crate) fn record_layout_change(
        &mut self,
        before: ScreenLayoutSnapshot,
        created_panes: Vec<PaneId>,
        coalesce: Option<LayoutMutationKey>,
    ) {
        self.record_prepared_layout_change(Some(before), created_panes, coalesce);
    }

    pub(crate) fn record_prepared_layout_change(
        &mut self,
        before: Option<ScreenLayoutSnapshot>,
        created_panes: Vec<PaneId>,
        coalesce: Option<LayoutMutationKey>,
    ) {
        self.layout_revision = self.layout_revision.saturating_add(1);
        if created_panes.is_empty()
            && coalesce.is_some()
            && self.layout_undo.back().is_some_and(|entry| {
                entry.created_panes.is_empty()
                    && entry.coalesce == coalesce
                    && entry.after_revision.saturating_add(1) == self.layout_revision
            })
        {
            if let Some(entry) = self.layout_undo.back_mut() {
                entry.after_revision = self.layout_revision;
            }
            return;
        }
        let before = before.expect("non-coalesced layout changes require a prior snapshot");
        self.layout_undo.push_back(LayoutUndoEntry {
            before,
            after_revision: self.layout_revision,
            created_panes,
            coalesce,
        });
        while self.layout_undo.len() > LAYOUT_UNDO_LIMIT {
            self.layout_undo.pop_front();
        }
    }

    pub(crate) fn invalidate_layout_undo(&mut self) {
        self.layout_revision = self.layout_revision.saturating_add(1);
        self.layout_undo.clear();
    }

    pub(crate) fn restore_layout_snapshot(&mut self, snapshot: ScreenLayoutSnapshot) {
        self.root = snapshot.root;
        self.active_pane = snapshot.active_pane;
        self.zoomed_pane = snapshot.zoomed_pane;
        self.zellij_auto_layout = snapshot.zellij_auto_layout;
        self.viewport_splits = snapshot.viewport_splits;
        self.viewport_base_width = snapshot.viewport_base_width;
        self.layout_columns = snapshot.layout_columns;
    }

    pub(crate) fn layout_columns_active(&self) -> bool {
        !self.layout_columns.is_empty()
    }

    pub(crate) fn layout_column_for_pane_mut(&mut self, pane: PaneId) -> Option<&mut LayoutColumn> {
        self.layout_columns.iter_mut().find(|column| column.root.contains(pane))
    }

    pub(crate) fn insert_layout_column_after(
        &mut self,
        target: PaneId,
        base_id: SplitId,
        column: LayoutColumn,
    ) -> bool {
        if self.layout_columns.is_empty() {
            if !self.root.contains(target) {
                return false;
            }
            let root = std::mem::replace(&mut self.root, Node::Leaf(0));
            self.layout_columns.push(LayoutColumn {
                id: base_id,
                width: self.viewport_base_width.unwrap_or(1.0),
                root,
                zellij_auto_layout: self.zellij_auto_layout.take(),
            });
        }
        let Some(index) =
            self.layout_columns.iter().position(|candidate| candidate.root.contains(target))
        else {
            return false;
        };
        self.layout_columns.insert(index + 1, column);
        self.sync_layout_column_projection();
        true
    }

    pub(crate) fn sync_layout_column_projection(&mut self) {
        let Some(first) = self.layout_columns.first() else {
            self.viewport_splits.clear();
            self.viewport_base_width = None;
            return;
        };
        self.viewport_splits.clear();
        self.viewport_base_width = Some(first.width);
        self.zellij_auto_layout = None;

        let mut root = first.root.clone();
        let mut width_before = first.width;
        for column in self.layout_columns.iter().skip(1) {
            let ratio = (width_before / (width_before + column.width)).clamp(0.05, 0.95);
            root = Node::Split {
                id: column.id,
                dir: SplitDir::Right,
                ratio,
                a: Box::new(root),
                b: Box::new(column.root.clone()),
            };
            self.viewport_splits.insert(column.id, column.width);
            width_before += column.width;
        }
        self.root = root;
        debug_assert!(self.layout_column_projection_is_consistent());
    }

    pub(crate) fn sync_layout_column_width_projection(&mut self) {
        let Some(first) = self.layout_columns.first() else {
            self.viewport_splits.clear();
            self.viewport_base_width = None;
            return;
        };
        self.viewport_splits.clear();
        self.viewport_base_width = Some(first.width);
        let mut ratios = BTreeMap::new();
        let mut width_before = first.width;
        for column in self.layout_columns.iter().skip(1) {
            ratios.insert(
                column.id,
                (width_before / (width_before + column.width)).clamp(0.05, 0.95),
            );
            self.viewport_splits.insert(column.id, column.width);
            width_before += column.width;
        }
        self.root.set_split_ratios(&ratios);
        debug_assert!(self.layout_column_projection_is_consistent());
    }

    pub(crate) fn collapse_single_layout_column(&mut self) {
        if self.layout_columns.len() != 1 {
            self.sync_layout_column_projection();
            return;
        }
        let column = self.layout_columns.pop().expect("single layout column");
        self.root = column.root;
        self.zellij_auto_layout = column.zellij_auto_layout;
        self.viewport_splits.clear();
        self.viewport_base_width = None;
    }

    pub(crate) fn layout_column_projection_is_consistent(&self) -> bool {
        if self.layout_columns.is_empty() {
            return self.viewport_splits.is_empty() && self.viewport_base_width.is_none();
        }
        if self.layout_columns.len() < 2
            || self.zellij_auto_layout.is_some()
            || self.viewport_base_width != self.layout_columns.first().map(|column| column.width)
            || self.viewport_splits.len() + 1 != self.layout_columns.len()
        {
            return false;
        }

        let projected_panes = self.root.pane_ids_vec();
        let column_panes = self
            .layout_columns
            .iter()
            .flat_map(|column| column.root.pane_ids_vec())
            .collect::<Vec<_>>();
        if projected_panes != column_panes {
            return false;
        }

        self.layout_columns.iter().enumerate().all(|(index, column)| {
            let expected_owner =
                if index == 0 { ViewportColumn::Base } else { ViewportColumn::Split(column.id) };
            (index == 0 || self.viewport_splits.get(&column.id).copied() == Some(column.width))
                && column.root.pane_ids_vec().into_iter().all(|pane| {
                    self.root.viewport_column_owner(pane, &self.viewport_splits)
                        == Some(expected_owner)
                })
        })
    }
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
