//! Tab drag outcomes that create a pane: drop a tab on a pane edge (a new
//! split) or between strip columns (a new column).
//!
//! Each outcome is one atomic resource commit. The mutation runs on a clone
//! of the live [`State`] with the same in-memory helpers the existing split
//! and move paths use, the complete tree is projected into one durable
//! patch, and the clone replaces the live state only after that patch
//! commits. A failed commit therefore leaves nothing behind.
//!
//! When the tab's origin pane survives on the same screen, the drag records
//! one layout-undo entry that moves the tab back and removes the created
//! pane; undo never closes the tab. Other drags fence that screen's undo
//! history and report `undoable: false`.

use super::*;
use crate::layout::DEFAULT_VIEWPORT_PANE_WIDTH;
use crate::model::{LayoutColumn, LayoutUndoTabRestore};
use cmux_layout_reducer::{Edge, LayoutOpKind};

/// The pane edge a tab was dropped on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabDropEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl TabDropEdge {
    pub fn parse(value: &str) -> anyhow::Result<Self> {
        Ok(match value {
            "left" => Self::Left,
            "right" => Self::Right,
            "top" | "up" => Self::Top,
            "bottom" | "down" => Self::Bottom,
            other => anyhow::bail!(
                "bad edge {other:?} (want \"left\", \"right\", \"top\", or \"bottom\")"
            ),
        })
    }

    /// Split direction, and whether the new pane goes before the target.
    fn split(self) -> (SplitDir, bool) {
        match self {
            Self::Left => (SplitDir::Right, true),
            Self::Right => (SplitDir::Right, false),
            Self::Top => (SplitDir::Down, true),
            Self::Bottom => (SplitDir::Down, false),
        }
    }
}

/// Where a dragged tab lands.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TabDragDestination {
    /// A new pane beside `pane` on `edge`. `ratio` is the new pane's share
    /// of the split (default one half).
    Split { pane: PaneId, edge: TabDropEdge, ratio: Option<f32> },
    /// A new strip column on the screen containing `pane`, after the column
    /// `after_column` (default: after the last column), `width` wide as a
    /// fraction of the frontend viewport.
    Column { pane: PaneId, after_column: Option<SplitId>, width: f32 },
}

impl From<TabDropEdge> for Edge {
    fn from(edge: TabDropEdge) -> Self {
        match edge {
            TabDropEdge::Left => Self::Left,
            TabDropEdge::Right => Self::Right,
            TabDropEdge::Top => Self::Top,
            TabDropEdge::Bottom => Self::Bottom,
        }
    }
}

impl TabDragDestination {
    fn pane(self) -> PaneId {
        match self {
            Self::Split { pane, .. } | Self::Column { pane, .. } => pane,
        }
    }

    /// The reducer op for this drag, with the ids the daemon reserved.
    pub(super) fn layout_op(self, tab: SurfaceId, ids: &TabDragIds) -> LayoutOpKind {
        match self {
            Self::Split { pane, edge, .. } => {
                LayoutOpKind::MoveTabToSplit { tab, pane, edge: edge.into(), new_pane: ids.pane }
            }
            Self::Column { pane, after_column, width } => LayoutOpKind::MoveTabToColumn {
                tab,
                anchor: pane,
                after_column,
                // `move_tab_to_column` validated the width range.
                width_permille: (width * 1000.0).round() as u16,
                new_pane: ids.pane,
                new_column: ids.split,
                base_column: ids.base_column,
            },
        }
    }

    fn fingerprint(self) -> Value {
        match self {
            Self::Split { pane, edge, ratio } => serde_json::json!({
                "kind": "split",
                "pane": pane,
                "edge": format!("{edge:?}"),
                "ratio": ratio,
            }),
            Self::Column { pane, after_column, width } => serde_json::json!({
                "kind": "column",
                "pane": pane,
                "after_column": after_column,
                "width": width,
            }),
        }
    }
}

/// The committed result of one tab drag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabDragOutcome {
    pub surface: SurfaceId,
    pub pane: PaneId,
    pub screen: ScreenId,
    pub workspace: WorkspaceId,
    /// Whether `undo-layout` on the destination screen moves the tab back.
    pub undoable: bool,
}

pub(super) struct TabDragIds {
    pub(super) pane: PaneId,
    pub(super) pane_public: PanePublicId,
    pub(super) split: SplitId,
    pub(super) base_column: SplitId,
}

impl TabDragIds {
    pub(super) fn reserve(mux: &Mux) -> anyhow::Result<Self> {
        Ok(Self {
            pane: mux.next_id(),
            pane_public: PanePublicId::random()?,
            split: mux.next_id(),
            base_column: mux.next_id(),
        })
    }
}

impl Mux {
    /// Move a tab into a new split beside `pane`: one atomic, undoable (on
    /// the same screen) command for a drop on a pane edge.
    pub fn move_tab_to_split(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        edge: TabDropEdge,
        ratio: Option<f32>,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        if let Some(ratio) = ratio {
            anyhow::ensure!(
                ratio.is_finite() && (0.05..=0.95).contains(&ratio),
                "bad request: ratio must be between 0.05 and 0.95"
            );
        }
        self.commit_tab_drag(surface, TabDragDestination::Split { pane, edge, ratio }, transaction)
    }

    /// Move a tab into a new strip column on the screen containing `pane`.
    pub fn move_tab_to_column(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        after_column: Option<SplitId>,
        width: Option<f32>,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        let width = width.unwrap_or(DEFAULT_VIEWPORT_PANE_WIDTH);
        if !width.is_finite()
            || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
        {
            return Err(ViewportWidthError::OutOfRange { width }.into());
        }
        self.commit_tab_drag(
            surface,
            TabDragDestination::Column { pane, after_column, width },
            transaction,
        )
    }

    fn commit_tab_drag(
        self: &Arc<Self>,
        surface: SurfaceId,
        destination: TabDragDestination,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        let ids = TabDragIds::reserve(self)?;
        let fingerprint = serde_json::json!({
            "operation": "tab.drag",
            "surface": surface,
            "destination": destination.fingerprint(),
            "pane_id": ids.pane_public,
        });
        let mux = Arc::clone(self);
        let mut committed = None;
        let commit = self.commit_resource_mutation_plan(
            &WorkspaceMutation::local("cmux-tui-tab-drag"),
            "tab.drag",
            &fingerprint,
            None,
            None,
            |state, registry| {
                let mut projected = state.clone();
                let outcome =
                    apply_tab_drag(&mux, &mut projected, surface, destination, &ids, true)?;
                let source_key = state
                    .pane_of(surface)
                    .and_then(|pane| state.screen_of(pane))
                    .map(|(workspace, _)| state.workspaces[workspace].key.clone());
                let target_key = projected
                    .workspace_by_id(outcome.workspace)
                    .map(|workspace| workspace.key.clone())
                    .context("drag destination workspace disappeared")?;
                let tab_id = projected
                    .resource_indexes
                    .tab_ids
                    .get(&surface)
                    .cloned()
                    .context("dragged tab has no public identity")?;
                let mut projection = mux.resource_effect_projection_locked(
                    registry,
                    &mut projected,
                    serde_json::json!({"tab": tab_id, "pane": ids.pane_public}),
                )?;
                if source_key.as_deref() != Some(target_key.as_str())
                    && let Some(terminal) = projected
                        .surfaces
                        .get(&surface)
                        .and_then(|surface| surface.terminal_public_id())
                {
                    retarget_terminal_workspace(&mut projection.patch, terminal, &target_key);
                }
                committed = Some((outcome, target_key));
                Ok(ResourceMutationPlan::replacing(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    projected,
                )
                .with_layout_op(destination.layout_op(surface, &ids)))
            },
        )?;
        let (outcome, target_key) = committed.context("tab drag committed no outcome")?;
        if commit.replayed {
            return Ok(outcome);
        }
        if let Some(runtime) = self.surface(surface) {
            let _ = runtime.persist_host_workspace(&target_key);
        }
        self.emit(MuxEvent::TreeChanged);
        self.emit(MuxEvent::LayoutChanged(outcome.screen));
        self.emit_tab_changed_for_transaction(surface, transaction.map(Arc::from));
        Ok(outcome)
    }

    /// `move-tab` for a drag: move a tab to `pane` at insertion `index` in
    /// one commit. A move between two panes of one screen whose origin pane
    /// survives records a layout-undo entry that moves the tab back.
    /// Returns whether the tab moved and whether the move is undoable.
    pub fn move_tab_with_undo(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
        transaction: Option<String>,
    ) -> (bool, bool) {
        let origin = self.with_state(|state| {
            let source = state.pane_of(surface)?;
            let tabs = &state.panes.get(&source)?.tabs;
            let origin_index = tabs.iter().position(|candidate| *candidate == surface)?;
            let same_screen = state.screen_of(source)? == state.screen_of(pane)?;
            (same_screen && source != pane && tabs.len() > 1).then_some((source, origin_index))
        });
        if !self.move_tab(surface, pane, index) {
            return (false, false);
        }
        let mut undoable = false;
        if let Some((origin_pane, origin_index)) = origin {
            let mut state = self.state.lock().unwrap();
            // A non-structural move leaves the layout unchanged, so the
            // current layout is the one undo restores.
            if state.pane_of(surface) == Some(pane)
                && let Some((workspace, screen)) = state.screen_of(pane)
                && state.screen_of(origin_pane) == Some((workspace, screen))
            {
                let screen = &mut state.workspaces[workspace].screens[screen];
                let before = screen.layout_snapshot();
                screen.record_tab_drag_change(
                    before,
                    LayoutUndoTabRestore { surface, origin_pane, origin_index, created_pane: None },
                );
                undoable = true;
            }
        }
        self.emit_tab_changed_for_transaction(surface, transaction.map(Arc::from));
        (true, undoable)
    }

    /// Emit `tab-changed` for one tab, echoing the client transaction that
    /// caused it.
    pub(crate) fn emit_tab_changed_for_transaction(
        &self,
        surface: SurfaceId,
        transaction: Option<Arc<str>>,
    ) {
        let decorations = self.tree_decorations();
        let delta = {
            let state = self.state.lock().unwrap();
            presentation::tab_changed_delta(&state, &decorations, surface)
        };
        if let Some(mut delta) = delta {
            delta.transaction = transaction;
            self.emit(MuxEvent::TreeDelta(delta));
        }
    }
}

/// A terminal moved to another workspace: its durable host placement names
/// the new workspace, as `move-tab` does.
pub(super) fn retarget_terminal_workspace(
    patch: &mut ResourcePatch,
    terminal: &TerminalPublicId,
    workspace_key: &str,
) {
    for change in &mut patch.changes {
        if let ResourceChange::UpsertTerminal { public_id, terminal: record } = change
            && public_id == terminal
        {
            record.workspace_key = workspace_key.to_string();
        }
    }
}

fn screen_location(state: &State, screen: ScreenId) -> Option<(usize, usize)> {
    state.workspaces.iter().enumerate().find_map(|(workspace, item)| {
        item.screens
            .iter()
            .position(|candidate| candidate.id == screen)
            .map(|index| (workspace, index))
    })
}

/// Apply one drag to `state` (a clone of the live state).
pub(super) fn apply_tab_drag(
    mux: &Mux,
    state: &mut State,
    surface: SurfaceId,
    destination: TabDragDestination,
    ids: &TabDragIds,
    record_undo: bool,
) -> anyhow::Result<TabDragOutcome> {
    let target_pane = destination.pane();
    let source_pane =
        state.pane_of(surface).with_context(|| format!("unknown surface {surface}"))?;
    anyhow::ensure!(state.panes.contains_key(&target_pane), "unknown pane {target_pane}");
    let source_tabs = state.panes[&source_pane].tabs.len();
    anyhow::ensure!(
        source_pane != target_pane || source_tabs > 1,
        "bad request: a pane's only tab cannot be split out of that pane"
    );
    let origin_index = state.panes[&source_pane]
        .tabs
        .iter()
        .position(|candidate| *candidate == surface)
        .context("dragged tab left its pane")?;
    let (target_wi, target_si) =
        state.screen_of(target_pane).context("target pane has no screen")?;
    let source_location = state.screen_of(source_pane).context("source pane has no screen")?;
    let target_screen = state.workspaces[target_wi].screens[target_si].id;
    let source_screen = state.workspaces[source_location.0].screens[source_location.1].id;
    let target_workspace = state.workspaces[target_wi].id;
    let undoable = record_undo && target_screen == source_screen && source_tabs > 1;
    let before = state.workspaces[target_wi].screens[target_si].layout_snapshot();
    {
        let screen = &mut state.workspaces[target_wi].screens[target_si];
        match destination {
            TabDragDestination::Split { edge, ratio, .. } => {
                let (dir, before_target) = edge.split();
                let in_column = screen.layout_columns_active();
                let root = if in_column {
                    let column = screen
                        .layout_column_for_pane_mut(target_pane)
                        .context("target pane has no viewport column")?;
                    column.zellij_auto_layout = None;
                    &mut column.root
                } else {
                    &mut screen.root
                };
                anyhow::ensure!(
                    root.split_leaf(target_pane, ids.split, dir, ids.pane),
                    "target pane disappeared from its layout"
                );
                if before_target {
                    anyhow::ensure!(
                        root.swap_leaves(target_pane, ids.pane),
                        "new split leaves could not be ordered"
                    );
                }
                if let Some(ratio) = ratio {
                    let split_ratio = if before_target { ratio } else { 1.0 - ratio };
                    anyhow::ensure!(
                        root.set_split_ratio(ids.split, split_ratio),
                        "new split ratio could not be applied"
                    );
                }
                if in_column {
                    screen.sync_layout_column_projection();
                } else {
                    screen.zellij_auto_layout = None;
                }
            }
            TabDragDestination::Column { after_column, width, .. } => {
                let anchor = match after_column {
                    Some(column) => screen
                        .layout_columns
                        .iter()
                        .find(|candidate| candidate.id == column)
                        .map(|candidate| candidate.root.first_visible_pane())
                        .with_context(|| format!("unknown column {column}"))?,
                    None => screen
                        .layout_columns
                        .last()
                        .map(|column| column.root.first_visible_pane())
                        .unwrap_or(target_pane),
                };
                anyhow::ensure!(
                    screen.insert_layout_column_after(
                        anchor,
                        ids.base_column,
                        LayoutColumn {
                            id: ids.split,
                            width,
                            root: Node::Leaf(ids.pane),
                            zellij_auto_layout: Some(vec![ids.pane]),
                            sticky: None,
                        },
                    ),
                    "column anchor disappeared from its layout"
                );
            }
        }
        screen.active_pane = ids.pane;
        screen.zoomed_pane = None;
    }
    state.insert_pane(Pane {
        id: ids.pane,
        public_id: ids.pane_public.clone(),
        name: None,
        tabs: Vec::new(),
        active_tab: 0,
        active_at: mux.next_active_at(),
        focused_at: 0,
    });
    let (moved, _) = move_tab_in_state(mux, state, surface, ids.pane, 0);
    anyhow::ensure!(moved, "tab could not be moved into its new pane");
    stamp_pane_focus(mux, state, ids.pane);
    let (target_wi, target_si) =
        screen_location(state, target_screen).context("drag destination screen disappeared")?;
    if undoable {
        state.workspaces[target_wi].screens[target_si].record_tab_drag_change(
            before,
            LayoutUndoTabRestore {
                surface,
                origin_pane: source_pane,
                origin_index,
                created_pane: Some(ids.pane),
            },
        );
    } else {
        // Older entries on either screen describe layouts without this
        // change; undoing them would orphan or duplicate the moved tab.
        state.workspaces[target_wi].screens[target_si].invalidate_layout_undo();
        if let Some((workspace, screen)) = screen_location(state, source_screen) {
            state.workspaces[workspace].screens[screen].invalidate_layout_undo();
        }
    }
    Mux::rebuild_split_screen_index(state);
    Ok(TabDragOutcome {
        surface,
        pane: ids.pane,
        screen: target_screen,
        workspace: target_workspace,
        undoable,
    })
}

/// Undo one same-screen tab drag: move the tab back to its origin pane and
/// index, and remove the pane the drag created. Every precondition is
/// checked first, so a stale entry fails without changing anything.
pub(super) fn restore_dragged_tab(
    mux: &Mux,
    state: &mut State,
    workspace_index: usize,
    screen_index: usize,
    restore: LayoutUndoTabRestore,
) -> anyhow::Result<()> {
    let stale = |message: &str| anyhow::Error::new(LayoutUndoError::Stale(message.to_string()));
    let screen_panes = state.workspaces[workspace_index].screens[screen_index].root.pane_ids_vec();
    let current = state.pane_of(restore.surface).ok_or_else(|| stale("the dragged tab closed"))?;
    if !screen_panes.contains(&restore.origin_pane)
        || !state.panes.contains_key(&restore.origin_pane)
    {
        return Err(stale("the dragged tab's origin pane closed"));
    }
    if !screen_panes.contains(&current) {
        return Err(stale("the dragged tab left its screen"));
    }
    match restore.created_pane {
        Some(created) => {
            let alone = state
                .panes
                .get(&created)
                .is_some_and(|pane| pane.tabs.as_slice() == [restore.surface]);
            if current != created || !alone {
                return Err(stale("the pane created by the drag changed"));
            }
        }
        None if current == restore.origin_pane => {
            return Err(stale("the dragged tab is already in its origin pane"));
        }
        // The pane the tab moved into existed before the move and is part
        // of the layout being restored. If its other tabs have left since,
        // moving the tab back would leave that pane empty (I3).
        None if state.panes.get(&current).is_some_and(|pane| pane.tabs.len() == 1) => {
            return Err(stale("the dragged tab is the last tab of its pane"));
        }
        None => {}
    }
    {
        let pane = state.panes.get_mut(&current).expect("checked current pane");
        let old = pane
            .tabs
            .iter()
            .position(|candidate| *candidate == restore.surface)
            .expect("checked tab membership");
        pane.tabs.remove(old);
        if !pane.tabs.is_empty() && pane.active_tab >= old && pane.active_tab > 0 {
            pane.active_tab -= 1;
        }
    }
    if restore.created_pane == Some(current) {
        state.remove_pane(current);
    }
    let origin = state.panes.get_mut(&restore.origin_pane).expect("checked origin pane");
    let index = restore.origin_index.min(origin.tabs.len());
    origin.tabs.insert(index, restore.surface);
    origin.active_tab = index;
    state.resource_indexes.tab_pane.insert(restore.surface, restore.origin_pane);
    let workspace = state.workspaces[workspace_index].id;
    let screen = state.workspaces[workspace_index].screens[screen_index].id;
    mux.subscribers.update_surface_session_path(
        restore.surface,
        workspace,
        screen,
        restore.origin_pane,
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
        mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()))
            .unwrap_or_default()
    }

    fn pane_of(mux: &Mux, surface: SurfaceId) -> PaneId {
        mux.with_state(|state| state.pane_of(surface)).unwrap()
    }

    fn screen_panes(mux: &Mux, pane: PaneId) -> Vec<PaneId> {
        mux.with_state(|state| {
            let (workspace, screen) = state.screen_of(pane).unwrap();
            state.workspaces[workspace].screens[screen].root.pane_ids_vec()
        })
    }

    fn transaction_of(events: &MuxEventReceiver, surface: SurfaceId) -> Option<String> {
        std::iter::from_fn(|| events.try_recv().ok()).find_map(|event| match event {
            MuxEvent::TreeDelta(delta)
                if delta.kind == TreeDeltaKind::TabChanged && delta.surface == Some(surface) =>
            {
                delta.transaction.map(|transaction| transaction.to_string())
            }
            _ => None,
        })
    }

    #[test]
    fn cmux_next_tab_to_split_is_atomic_undoable_and_durable() {
        let mux = Mux::new_for_test("tab-drag-split", SurfaceOptions::default());
        let first = mux.new_workspace(None, None).unwrap().id;
        let origin = pane_of(&mux, first);
        let second = mux.new_tab(Some(origin), None, None).unwrap().id;
        // A pane's only tab cannot be split out of it.
        let lone = mux.new_workspace(None, None).unwrap().id;
        assert!(
            mux.move_tab_to_split(lone, pane_of(&mux, lone), TabDropEdge::Right, None, None)
                .is_err()
        );

        let events = mux.subscribe();
        let outcome = mux
            .move_tab_to_split(second, origin, TabDropEdge::Left, Some(0.3), Some("drag-1".into()))
            .unwrap();
        assert!(outcome.undoable);
        assert_eq!(pane_of(&mux, second), outcome.pane);
        assert_eq!(tabs(&mux, origin), vec![first]);
        assert_eq!(tabs(&mux, outcome.pane), vec![second]);
        // Left edge: the new pane comes first in the split.
        assert_eq!(screen_panes(&mux, origin), vec![outcome.pane, origin]);
        assert_eq!(transaction_of(&events, second).as_deref(), Some("drag-1"));
        drop(events);

        match mux.undo_layout(origin, None, false).unwrap() {
            LayoutUndoResult::Undone { .. } => {}
            other => panic!("tab drag undo required confirmation: {other:?}"),
        }
        assert_eq!(tabs(&mux, origin), vec![first, second]);
        assert_eq!(screen_panes(&mux, origin), vec![origin]);
        assert!(mux.with_state(|state| !state.panes.contains_key(&outcome.pane)));

        // Redo the drag: the split and the moved tab are durable topology.
        let outcome =
            mux.move_tab_to_split(second, origin, TabDropEdge::Bottom, None, None).unwrap();
        let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&second].clone());
        let pane_id =
            mux.with_state(|state| state.resource_indexes.pane_ids[&outcome.pane].clone());
        let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
        let durable_tab = topology.tabs.iter().find(|tab| tab.public_id == tab_id).unwrap();
        assert_eq!(durable_tab.pane_id, pane_id);
        assert!(topology.panes.iter().any(|pane| pane.public_id == pane_id));
    }

    #[test]
    fn cmux_next_tab_to_column_and_cross_pane_moves() {
        let mux = Mux::new_for_test("tab-drag-column", SurfaceOptions::default());
        let first = mux.new_workspace(None, None).unwrap().id;
        let origin = pane_of(&mux, first);
        let second = mux.new_tab(Some(origin), None, None).unwrap().id;
        let third = mux.new_tab(Some(origin), None, None).unwrap().id;

        let column = mux.move_tab_to_column(third, origin, None, None, None).unwrap();
        assert!(column.undoable);
        let columns = mux.with_state(|state| {
            let (workspace, screen) = state.screen_of(origin).unwrap();
            state.workspaces[workspace].screens[screen].layout_columns.len()
        });
        assert_eq!(columns, 2);
        assert_eq!(tabs(&mux, column.pane), vec![third]);
        assert!(mux.move_tab_to_column(second, origin, None, Some(3.0), None).is_err());

        // A cross-pane move on one screen is undoable too.
        let (moved, undoable) =
            mux.move_tab_with_undo(second, column.pane, 1, Some("drag-2".into()));
        assert!(moved && undoable);
        assert_eq!(tabs(&mux, column.pane), vec![third, second]);
        mux.undo_layout(origin, None, false).unwrap();
        assert_eq!(tabs(&mux, origin), vec![first, second]);
        mux.undo_layout(origin, None, false).unwrap();
        assert_eq!(tabs(&mux, origin), vec![first, second, third]);

        // Moving a pane's last tab into a split elsewhere removes the pane
        // and is not undoable.
        let split = mux.move_tab_to_split(third, origin, TabDropEdge::Right, None, None).unwrap();
        let moved = mux.move_tab_to_split(third, origin, TabDropEdge::Top, None, None).unwrap();
        assert!(!moved.undoable);
        assert!(mux.with_state(|state| !state.panes.contains_key(&split.pane)));
        assert_eq!(tabs(&mux, moved.pane), vec![third]);
    }

    #[test]
    fn cmux_next_tab_to_new_workspace_places_it_in_a_group() {
        let mux = Mux::new_for_test("tab-drag-workspace", SurfaceOptions::default());
        let first = mux.new_workspace(None, None).unwrap().id;
        let origin = pane_of(&mux, first);
        let second = mux.new_tab(Some(origin), None, None).unwrap().id;
        let member = mux.create_empty_workspace(Some("member".into()), None, None).unwrap();
        mux.create_workspace_group(Some("g".into()), "G".into(), None, false, None).unwrap();
        mux.move_workspace_to_group(
            None,
            Some(&member.key),
            Some("g".into()),
            None,
            None,
            None,
            &WorkspaceMutation::local("tab-drag-test"),
        )
        .unwrap();
        assert!(mux.move_tab_to_new_workspace(second, Some("missing".into()), None).is_err());
        let workspace = mux.move_tab_to_new_workspace(second, Some("g".into()), Some(0)).unwrap();
        let (order, key) = mux.with_state(|state| {
            (
                state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
                state.workspace_by_id(workspace).unwrap().key.clone(),
            )
        });
        // In-group index 0 places the new workspace before the member.
        let new_index = order.iter().position(|id| *id == workspace).unwrap();
        let member_index = order.iter().position(|id| *id == member.workspace).unwrap();
        assert_eq!(new_index + 1, member_index);
        assert_eq!(
            mux.presentation_snapshot().workspace(&key).and_then(|record| record.group.clone()),
            Some("g".to_string())
        );
        assert_eq!(tabs(&mux, pane_of(&mux, second)), vec![second]);
    }
}
