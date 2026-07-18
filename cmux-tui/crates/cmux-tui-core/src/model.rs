//! The session tree: workspaces own screens; each screen is a binary
//! split tree of panes; each pane holds an ordered list of tabs
//! (surfaces).

use std::collections::HashMap;
use std::sync::Arc;

use crate::{
    PaneId, PaneUuid, ScreenId, ScreenUuid, SplitDir, Surface, SurfaceId, SurfaceUuid, WorkspaceId,
    WorkspaceUuid,
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
                *self = Node::Split {
                    dir,
                    ratio,
                    a: Box::new(a),
                    b: Box::new(b),
                };
                true
            }
            Node::Leaf(_) => false,
            Node::Split { a, b, .. } => {
                a.split_leaf(target, dir, new_pane, insert_first, ratio)
                    || b.split_leaf(target, dir, new_pane, insert_first, ratio)
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
                Node::Split { dir: split_dir, ratio, a, b } => {
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
                Node::Split { dir: split_dir, ratio, a, b } => {
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
            }
        }

        let (_, matched, changed) =
            walk(self, target, dir, target_in_first, new_ratio);
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
    pub uuid: PaneUuid,
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
#[derive(Debug, Clone)]
pub struct Screen {
    pub id: ScreenId,
    pub uuid: ScreenUuid,
    /// User-assigned name; display falls back to the screen's number.
    pub name: Option<String>,
    pub root: Node,
    pub active_pane: PaneId,
    pub zoomed_pane: Option<PaneId>,
}

#[derive(Debug, Clone)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub uuid: WorkspaceUuid,
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
    pub active_workspace: usize,
    pub panes: HashMap<PaneId, Pane>,
    pub surfaces: HashMap<SurfaceId, Arc<Surface>>,
}

impl State {
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
