//! The session tree: workspaces own screens; each screen is a binary
//! split tree of panes; each pane holds an ordered list of tabs
//! (surfaces).

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::Arc;

use crate::{
    PaneId, PanePublicId, PaneUuid, ScreenId, ScreenPublicId, ScreenUuid, SplitDir, Surface,
    SurfaceId, SurfaceUuid, WorkspaceId, WorkspacePublicId, WorkspaceUuid,
};

/// Result of resolving a requested mutation against canonical state.
///
/// Keeping `Unchanged` distinct from `Missing` lets legacy commands retain
/// their historical success/event behavior without publishing a canonical
/// topology revision for a semantic no-op.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ChangeState {
    Missing,
    Unchanged,
    Changed,
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

    fn collect_stack_expansions(&self, expansions: &mut BTreeMap<Vec<PaneId>, PaneId>) {
        match self {
            Node::Leaf(_) => {}
            Node::Split { a, b, .. } => {
                a.collect_stack_expansions(expansions);
                b.collect_stack_expansions(expansions);
            }
            Node::Stack { panes, expanded } => {
                let mut membership = panes.as_slice().to_vec();
                membership.sort_unstable();
                expansions.insert(membership, *expanded);
            }
        }
    }

    fn restore_stack_expansions(&mut self, expansions: &BTreeMap<Vec<PaneId>, PaneId>) {
        match self {
            Node::Leaf(_) => {}
            Node::Split { a, b, .. } => {
                a.restore_stack_expansions(expansions);
                b.restore_stack_expansions(expansions);
            }
            Node::Stack { panes, expanded } => {
                let mut membership = panes.as_slice().to_vec();
                membership.sort_unstable();
                if let Some(current) =
                    expansions.get(&membership).copied().filter(|pane| panes.contains(pane))
                {
                    *expanded = current;
                }
            }
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
        dir: SplitDir,
        new_pane: PaneId,
        insert_first: bool,
        ratio: f32,
    ) -> bool {
        match self {
            Node::Leaf(id) if *id == target => {
                let old = Node::Leaf(*id);
                let new = Node::Leaf(new_pane);
                let (a, b) = if insert_first { (new, old) } else { (old, new) };
                *self = Node::Split { id: split_id, dir, ratio, a: Box::new(a), b: Box::new(b) };
                true
            }
            Node::Leaf(_) => false,
            Node::Split { a, b, .. } => {
                a.split_leaf(target, dir, new_pane, insert_first, ratio)
                    || b.split_leaf(target, dir, new_pane, insert_first, ratio)
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

    pub(crate) fn deepest_split_for_pane(&self, target: PaneId, dir: SplitDir) -> Option<SplitId> {
        fn walk(node: &Node, target: PaneId, dir: SplitDir) -> (bool, Option<SplitId>) {
            match node {
                Node::Leaf(id) => (*id == target, None),
                Node::Split { id, dir: split_dir, a, b, .. } => {
                    let (a_contains, a_split) = walk(a, target, dir);
                    if a_split.is_some() {
                        return (true, a_split);
                    }
                    let (b_contains, b_split) = walk(b, target, dir);
                    if b_split.is_some() {
                        return (true, b_split);
                    }
                    let contains = a_contains || b_contains;
                    if contains && *split_dir == dir { (true, Some(*id)) } else { (contains, None) }
                }
                Node::Stack { panes, .. } => (panes.contains(&target), None),
            }
        }

        walk(self, target, dir).1
    }

    pub(crate) fn set_deepest_ratio(
        &mut self,
        target: PaneId,
        dir: SplitDir,
        new_ratio: f32,
    ) -> ChangeState {
        fn walk(
            node: &mut Node,
            target: PaneId,
            dir: SplitDir,
            new_ratio: f32,
        ) -> (bool, bool, bool) {
            match node {
                Node::Leaf(id) => (*id == target, false, false),
                Node::Split { dir: split_dir, ratio, a, b, .. } => {
                    let (a_contains, a_matched, a_updated) = walk(a, target, dir, new_ratio);
                    if a_matched {
                        return (true, true, a_updated);
                    }
                    let (b_contains, b_matched, b_updated) = walk(b, target, dir, new_ratio);
                    if b_matched {
                        return (true, true, b_updated);
                    }
                    let contains = a_contains || b_contains;
                    if contains && *split_dir == dir {
                        let changed = *ratio != new_ratio;
                        *ratio = new_ratio;
                        (true, true, changed)
                    } else {
                        (contains, false, false)
                    }
                }
                Node::Stack { panes, .. } => (panes.contains(&target), false, false),
            }
        }

        let (_, matched, changed) = walk(self, target, dir, new_ratio);
        match (matched, changed) {
            (false, _) => ChangeState::Missing,
            (true, false) => ChangeState::Unchanged,
            (true, true) => ChangeState::Changed,
        }
    }

    /// Sets the deepest split on one exact edge of a pane. `target_in_first`
    /// distinguishes right/down dividers from left/up dividers when nested
    /// splits share the same orientation.
    pub(crate) fn set_deepest_ratio_on_edge(
        &mut self,
        target: PaneId,
        dir: SplitDir,
        target_in_first: bool,
        new_ratio: f32,
    ) -> ChangeState {
        fn walk(
            node: &mut Node,
            target: PaneId,
            dir: SplitDir,
            target_in_first: bool,
            new_ratio: f32,
        ) -> (bool, bool, bool) {
            match node {
                Node::Leaf(id) => (*id == target, false, false),
                Node::Split { dir: split_dir, ratio, a, b, .. } => {
                    let (a_contains, a_matched, a_updated) =
                        walk(a, target, dir, target_in_first, new_ratio);
                    if a_matched {
                        return (true, true, a_updated);
                    }
                    let (b_contains, b_matched, b_updated) =
                        walk(b, target, dir, target_in_first, new_ratio);
                    if b_matched {
                        return (true, true, b_updated);
                    }
                    let contains = a_contains || b_contains;
                    let on_requested_edge = if target_in_first { a_contains } else { b_contains };
                    if on_requested_edge && *split_dir == dir {
                        let changed = *ratio != new_ratio;
                        *ratio = new_ratio;
                        (true, true, changed)
                    } else {
                        (contains, false, false)
                    }
                }
                Node::Stack { panes, .. } => (panes.contains(&target), false, false),
            }
        }

        let (_, matched, changed) = walk(self, target, dir, target_in_first, new_ratio);
        match (matched, changed) {
            (false, _) => ChangeState::Missing,
            (true, false) => ChangeState::Unchanged,
            (true, true) => ChangeState::Changed,
        }
    }
}

/// A split-tree leaf: an ordered list of tabs (surfaces) with one active.
#[derive(Debug, Clone)]
pub struct Pane {
    pub id: PaneId,
    pub public_id: PanePublicId,
    pub uuid: PaneUuid,
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
#[derive(Debug, Clone)]
pub struct Screen {
    pub id: ScreenId,
    pub public_id: ScreenPublicId,
    pub uuid: ScreenUuid,
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

#[derive(Debug, Clone)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub public_id: WorkspacePublicId,
    pub uuid: WorkspaceUuid,
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
#[derive(Clone)]
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
    /// Monotonic version of the public resource tree. Every atomic resource
    /// mutation advances this counter exactly once.
    pub resource_revision: u64,
    pub(crate) focus_sequence: u64,
    pub active_workspace: usize,
    pub panes: HashMap<PaneId, Pane>,
    /// View placements keyed by daemon-local placement identity.
    pub surfaces: HashMap<SurfaceId, Arc<Surface>>,
    /// Stable terminal content kept alive independently of view placement.
    pub(crate) terminal_catalog: HashMap<TerminalPublicId, Arc<Surface>>,
    /// Reverse lookup for catalog owners addressed by daemon-local runtime ID.
    pub(crate) terminal_catalog_by_runtime: HashMap<SurfaceId, TerminalPublicId>,
    pub(crate) split_screens: HashMap<SplitId, (usize, usize, ScreenId)>,
    pub(crate) resource_indexes: PublicSlotIndexes,
}

impl State {
    pub(crate) fn next_focus_sequence(&mut self) -> u64 {
        self.focus_sequence = self.focus_sequence.saturating_add(1);
        self.focus_sequence
    }

    pub(crate) fn insert_pane(&mut self, pane: Pane) {
        let id = pane.id;
        let public_id = pane.public_id.clone();
        let replaced = self.panes.insert(id, pane);
        debug_assert!(replaced.is_none(), "pane {id} was inserted twice");
        if replaced.is_none() {
            debug_assert!(
                self.resource_indexes.panes.insert(public_id.clone(), id).is_none(),
                "pane public id {public_id} was inserted twice"
            );
            self.resource_indexes.pane_ids.insert(id, public_id);
            self.pane_revision = self.pane_revision.saturating_add(1);
        }
    }

    pub(crate) fn remove_pane(&mut self, pane: PaneId) -> Option<Pane> {
        let removed = self.panes.remove(&pane);
        if let Some(removed) = removed.as_ref() {
            self.resource_indexes.panes.remove(&removed.public_id);
            self.resource_indexes.pane_ids.remove(&pane);
            self.resource_indexes.pane_screen.remove(&pane);
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
        self.resource_indexes.workspaces.insert(workspace.public_id.clone(), workspace.id);
        self.resource_indexes.workspace_ids.insert(workspace.id, workspace.public_id.clone());
        self.workspaces.push(workspace);
    }

    pub(crate) fn remove_workspace(&mut self, index: usize) -> Workspace {
        let workspace = self.workspaces.remove(index);
        self.resource_indexes.workspaces.remove(&workspace.public_id);
        self.resource_indexes.workspace_ids.remove(&workspace.id);
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

    pub(crate) fn rebuild_resource_indexes(&mut self) {
        let mut indexes = PublicSlotIndexes::default();
        let mut live_split_slots = self.split_screens.keys().copied().collect::<HashSet<_>>();
        for workspace in &self.workspaces {
            let old = indexes.workspaces.insert(workspace.public_id.clone(), workspace.id);
            debug_assert!(old.is_none(), "duplicate workspace public id");
            indexes.workspace_ids.insert(workspace.id, workspace.public_id.clone());
            for screen in &workspace.screens {
                live_split_slots.extend(screen.layout_columns.iter().map(|column| column.id));
                let old = indexes.screens.insert(screen.public_id.clone(), screen.id);
                debug_assert!(old.is_none(), "duplicate screen public id");
                indexes.screen_ids.insert(screen.id, screen.public_id.clone());
                indexes.screen_workspace.insert(screen.id, workspace.id);
                for pane_id in screen.root.pane_ids_vec() {
                    if let Some(pane) = self.panes.get(&pane_id) {
                        let old = indexes.panes.insert(pane.public_id.clone(), pane.id);
                        debug_assert!(old.is_none(), "duplicate pane public id");
                        indexes.pane_ids.insert(pane.id, pane.public_id.clone());
                        indexes.pane_screen.insert(pane.id, screen.id);
                        for surface_id in &pane.tabs {
                            let identity = self
                                .surfaces
                                .get(surface_id)
                                .and_then(|surface| surface.resource_identity())
                                .map(|identity| {
                                    (identity.tab_id.clone(), identity.content_id.clone())
                                })
                                .or_else(|| {
                                    Some((
                                        self.resource_indexes.tab_ids.get(surface_id)?.clone(),
                                        self.resource_indexes.content_ids.get(surface_id)?.clone(),
                                    ))
                                });
                            let Some((tab_id, content_id)) = identity else { continue };
                            let old = indexes.tabs.insert(tab_id.clone(), *surface_id);
                            debug_assert!(old.is_none(), "duplicate tab public id");
                            indexes.tab_ids.insert(*surface_id, tab_id);
                            indexes
                                .content_placements
                                .entry(content_id.clone())
                                .or_default()
                                .push(*surface_id);
                            indexes.content_ids.insert(*surface_id, content_id);
                            indexes.tab_pane.insert(*surface_id, pane.id);
                        }
                    }
                }
            }
        }
        for split in live_split_slots {
            if let Some(public_id) = self.resource_indexes.split_ids.get(&split).cloned() {
                indexes.splits.insert(public_id.clone(), split);
                indexes.split_ids.insert(split, public_id);
            }
        }
        self.resource_indexes = indexes;
    }

    pub fn workspace_by_public_id(&self, id: &WorkspacePublicId) -> Option<&Workspace> {
        self.resource_indexes.workspaces.get(id).and_then(|id| self.workspace_by_id(*id))
    }

    pub fn screen_by_public_id(&self, id: &ScreenPublicId) -> Option<&Screen> {
        let slot = self.resource_indexes.screens.get(id)?;
        let workspace = self.resource_indexes.screen_workspace.get(slot)?;
        self.workspace_by_id(*workspace)?.screens.iter().find(|screen| screen.id == *slot)
    }

    pub fn pane_by_public_id(&self, id: &PanePublicId) -> Option<&Pane> {
        self.resource_indexes.panes.get(id).and_then(|slot| self.panes.get(slot))
    }

    pub fn surface_by_tab_public_id(&self, id: &TabPublicId) -> Option<&Arc<Surface>> {
        self.resource_indexes.tabs.get(id).and_then(|slot| self.surfaces.get(slot))
    }

    pub fn surface_by_content_public_id(&self, id: &ContentPublicId) -> Option<&Arc<Surface>> {
        if let ContentPublicId::Terminal(terminal_id) = id
            && let Some(surface) = self.terminal_catalog.get(terminal_id)
        {
            return Some(surface);
        }
        self.single_placement_of_content(id).and_then(|slot| self.surfaces.get(&slot))
    }

    pub fn placements_of_content(&self, id: &ContentPublicId) -> &[SurfaceId] {
        self.resource_indexes.content_placements.get(id).map(Vec::as_slice).unwrap_or_default()
    }

    /// Return the placement for content whose model requires exactly one live
    /// view. Zero or multiple placements fail closed instead of selecting an
    /// arbitrary traversal-order winner.
    pub fn single_placement_of_content(&self, id: &ContentPublicId) -> Option<SurfaceId> {
        let [placement] = self.placements_of_content(id) else { return None };
        Some(*placement)
    }

    pub(crate) fn terminal_runtime_by_id(&self, id: SurfaceId) -> Option<&Arc<Surface>> {
        self.terminal_catalog_by_runtime
            .get(&id)
            .and_then(|terminal| self.terminal_catalog.get(terminal))
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
        self.resource_indexes.tab_pane.get(&surface).copied().or_else(|| {
            // A resource mutation can temporarily stage a local placement
            // before its public indexes are committed. Preserve lookup for
            // that bounded transient state without penalizing steady state.
            self.panes.values().find(|pane| pane.tabs.contains(&surface)).map(|pane| pane.id)
        })
    }

    pub fn active_pane(&self) -> Option<PaneId> {
        self.workspaces
            .get(self.active_workspace)?
            .active_screen_ref()
            .map(|screen| screen.active_pane)
    }

    pub fn workspace_uuid(&self, id: WorkspaceId) -> Option<WorkspaceUuid> {
        self.workspaces.iter().find(|workspace| workspace.id == id).map(|workspace| workspace.uuid)
    }

    pub fn screen_uuid(&self, id: ScreenId) -> Option<ScreenUuid> {
        self.workspaces
            .iter()
            .flat_map(|workspace| &workspace.screens)
            .find(|screen| screen.id == id)
            .map(|screen| screen.uuid)
    }

    pub fn pane_uuid(&self, id: PaneId) -> Option<PaneUuid> {
        self.panes.get(&id).map(|pane| pane.uuid)
    }

    pub fn surface_uuid(&self, id: SurfaceId) -> Option<SurfaceUuid> {
        self.surfaces.get(&id).map(|surface| surface.uuid)
    }

    pub fn workspace_id_by_uuid(&self, uuid: WorkspaceUuid) -> Option<WorkspaceId> {
        self.workspaces
            .iter()
            .find(|workspace| workspace.uuid == uuid)
            .map(|workspace| workspace.id)
    }

    pub fn screen_id_by_uuid(&self, uuid: ScreenUuid) -> Option<ScreenId> {
        self.workspaces
            .iter()
            .flat_map(|workspace| &workspace.screens)
            .find(|screen| screen.uuid == uuid)
            .map(|screen| screen.id)
    }

    pub fn pane_id_by_uuid(&self, uuid: PaneUuid) -> Option<PaneId> {
        self.panes.values().find(|pane| pane.uuid == uuid).map(|pane| pane.id)
    }

    pub fn surface_id_by_uuid(&self, uuid: SurfaceUuid) -> Option<SurfaceId> {
        self.surfaces.values().find(|surface| surface.uuid == uuid).map(|surface| surface.id)
    }
}
