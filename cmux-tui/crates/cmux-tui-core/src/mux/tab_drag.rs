//! Tab drag outcomes that create a pane: drop a tab on a pane edge (a new
//! split) or between strip columns (a new column).
//!
//! Each outcome is one atomic resource commit: the mutation runs on a clone
//! of the live [`State`] (the split and move helpers), the tree is projected
//! into one durable patch, and the clone replaces the live state only after
//! that patch commits, so a failed commit leaves nothing behind.
//!
//! When the origin pane survives on the same screen, the drag records one
//! layout-undo entry that moves the tab back and removes the created pane
//! (undo never closes the tab). Other drags fence that screen's undo history
//! and report `undoable: false`.

use super::dock_columns::reduce_column_dock;
use super::*;
use crate::layout::DEFAULT_VIEWPORT_PANE_WIDTH;
use crate::model::{ColumnDock, DockEdge, LayoutColumn, LayoutUndoTabRestore};
use cmux_layout_reducer::{Edge, LayoutOpKind, NewTab, TabContent};

/// The fresh tab a split of a pane's only tab leaves there (`respawn`,
/// `tab-split-respawn-v1`): the moved tab's kind, never a copy of its state.
#[derive(Debug, Clone)]
pub enum SplitRespawn {
    /// A new terminal, spawned like `new-tab`.
    Terminal(TerminalSpawnOptions),
    /// A new frontend browser tab (usually the new tab page).
    Browser(crate::workspace_registry::FrontendBrowserRecord),
}

/// The source pane a respawn split expects at commit: exactly these tabs.
struct SourceGuard {
    pane: PaneId,
    tabs: [SurfaceId; 2],
}

impl SourceGuard {
    fn check(&self, state: &State) -> anyhow::Result<()> {
        anyhow::ensure!(
            state.panes.get(&self.pane).is_some_and(|pane| {
                pane.tabs.len() == self.tabs.len()
                    && self.tabs.iter().all(|tab| pane.tabs.contains(tab))
            }),
            "stale: the pane changed during the respawn split"
        );
        Ok(())
    }
}

/// Where `move-tab-to-column` puts the tab: a new column after `after_column`
/// (default: right of `pane`'s), `width` a viewport fraction, pinned at `dock`.
#[derive(Debug, Clone, Copy)]
pub struct ColumnMove {
    pub pane: PaneId,
    pub after_column: Option<SplitId>,
    pub width: Option<f32>,
    pub dock: Option<ColumnDock>,
}

fn validated_column_width(width: Option<f32>) -> anyhow::Result<f32> {
    let width = width.unwrap_or(DEFAULT_VIEWPORT_PANE_WIDTH);
    if !width.is_finite() || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width) {
        return Err(ViewportWidthError::OutOfRange { width }.into());
    }
    Ok(width)
}

fn validate_split_ratio(ratio: Option<f32>) -> anyhow::Result<()> {
    if let Some(ratio) = ratio {
        anyhow::ensure!(
            ratio.is_finite() && (0.05..=0.95).contains(&ratio),
            "bad request: ratio must be between 0.05 and 0.95"
        );
    }
    Ok(())
}

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
    /// A new pane beside `pane` on `edge`, `ratio` of the split (default 1/2).
    /// With `keep_focus` the focused pane stays focused: the new pane is not
    /// made active (an app opening a pane for an agent, `tab-split-keep-focus-v1`).
    /// With `around` the new pane splits off that whole split, whose edge
    /// leaf beside the new pane is `pane` (a closed pane reopened beside the
    /// sibling it left); with that split gone or changed, off `pane` alone.
    Split {
        pane: PaneId,
        edge: TabDropEdge,
        ratio: Option<f32>,
        keep_focus: bool,
        around: Option<SplitId>,
    },
    /// A new strip column on `pane`'s screen after `after_column` (default:
    /// last), `width` a viewport fraction, pinned to an edge with `dock` (a
    /// screen-edge drop: a docked column or a top or bottom dock). `keep_focus`
    /// as for `Split`.
    Column {
        pane: PaneId,
        after_column: Option<SplitId>,
        width: f32,
        dock: Option<ColumnDock>,
        keep_focus: bool,
    },
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

    /// A new pinned column made from its anchor pane's only tab (`pinned-dock-alone-v1`).
    fn makes_lone_pinned_column(self, state: &State, tab: SurfaceId) -> bool {
        let Self::Column { pane, dock: Some(dock), .. } = self else { return false };
        dock.pinned && state.panes.get(&pane).is_some_and(|anchor| anchor.tabs == [tab])
    }

    /// The reducer op for this drag, with the ids the daemon reserved.
    pub(super) fn layout_op(self, tab: SurfaceId, ids: &TabDragIds) -> LayoutOpKind {
        match self {
            Self::Split { pane, edge, .. } => LayoutOpKind::MoveTabToSplit {
                tab,
                pane,
                edge: edge.into(),
                new_pane: ids.pane,
                respawn: None,
            },
            // The reducer models column structure, not pins: `dock` is
            // checked by `reduce_column_dock` in `apply_tab_drag`.
            Self::Column { pane, after_column, width, .. } => LayoutOpKind::MoveTabToColumn {
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
            Self::Split { pane, edge, ratio, keep_focus, around } => {
                let mut fingerprint = serde_json::json!({
                    "kind": "split",
                    "pane": pane,
                    "edge": format!("{edge:?}"),
                    "ratio": ratio,
                });
                // Only when set, so keys recorded before the field stay equal.
                if keep_focus {
                    fingerprint["keep_focus"] = Value::Bool(true);
                }
                if let Some(around) = around {
                    fingerprint["around"] = serde_json::json!(around);
                }
                fingerprint
            }
            Self::Column { pane, after_column, width, dock, keep_focus } => {
                let mut fingerprint = serde_json::json!({
                    "kind": "column",
                    "pane": pane,
                    "after_column": after_column,
                    "width": width,
                    "dock": dock,
                });
                if keep_focus {
                    fingerprint["keep_focus"] = Value::Bool(true);
                }
                fingerprint
            }
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

pub(crate) struct TabDragIds {
    pub(crate) pane: PaneId,
    pub(crate) pane_public: PanePublicId,
    pub(crate) split: SplitId,
    pub(crate) base_column: SplitId,
}

impl TabDragIds {
    pub(crate) fn reserve(mux: &Mux) -> anyhow::Result<Self> {
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
    /// the same screen) command for a drop on a pane edge. `keep_focus`
    /// leaves the focused pane focused (`tab-split-keep-focus-v1`).
    #[allow(clippy::too_many_arguments)]
    pub fn move_tab_to_split_as(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        pane: PaneId,
        edge: TabDropEdge,
        ratio: Option<f32>,
        keep_focus: bool,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        validate_split_ratio(ratio)?;
        self.commit_tab_drag(
            actor,
            surface,
            TabDragDestination::Split { pane, edge, ratio, keep_focus, around: None },
            transaction,
        )
    }

    /// [`Self::move_tab_to_split_as`] around the whole split `around` whose
    /// edge leaf beside the new pane is `pane` (a closed pane reopened beside
    /// the sibling split it left); off `pane` alone when `around` is None or
    /// no longer such a split.
    pub(crate) fn move_tab_to_split_around_as(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        pane: PaneId,
        edge: TabDropEdge,
        ratio: Option<f32>,
        around: Option<SplitId>,
    ) -> anyhow::Result<TabDragOutcome> {
        validate_split_ratio(ratio)?;
        self.commit_tab_drag(
            actor,
            surface,
            TabDragDestination::Split { pane, edge, ratio, keep_focus: false, around },
            None,
        )
    }

    /// `move-tab-to-split` with `respawn`: split the tab's own pane, which
    /// holds only that tab, and leave a fresh tab of the given kind in it.
    ///
    /// The layout reducer validates the whole op first (moved plus created
    /// tab, I1-I3). The fresh tab is created first, so the pane never
    /// empties; the split then commits with the client transaction only while
    /// the pane holds exactly the dragged and the fresh tab. A failed split
    /// closes the fresh tab again; a daemon that dies between the two commits
    /// keeps both tabs, so no tab is lost.
    #[allow(clippy::too_many_arguments)]
    pub fn move_tab_to_split_respawning_as(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        pane: PaneId,
        edge: TabDropEdge,
        ratio: Option<f32>,
        respawn: SplitRespawn,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        validate_split_ratio(ratio)?;
        let model = {
            let state = self.state.lock().unwrap();
            anyhow::ensure!(
                state.panes.get(&pane).is_some_and(|candidate| candidate.tabs == [surface]),
                "bad request: respawn applies only to a split of the pane's only tab"
            );
            layout_invariants::project(&state)
        };
        // Ids the model has never used stand in for the pane and tab the
        // live commits create.
        let kind = LayoutOpKind::MoveTabToSplit {
            tab: surface,
            pane,
            edge: edge.into(),
            new_pane: u64::MAX,
            respawn: Some(NewTab {
                tab: u64::MAX - 1,
                content: TabContent { runtime: u64::MAX, terminal: None, dead: false },
            }),
        };
        layout_invariants::model_result("tab.drag", &model, &kind)?;
        let destination =
            TabDragDestination::Split { pane, edge, ratio, keep_focus: false, around: None };
        self.commit_tab_drag_respawning(actor, surface, pane, destination, respawn, transaction)
    }

    /// `move-tab-to-column` with `respawn` (`tab-column-respawn-v1`): move a
    /// pane's only tab into a new (optionally docked) column and leave a fresh
    /// tab in its pane, guarded like [`Self::move_tab_to_split_respawning_as`].
    /// Docking a screen's only tab uses it, so the strip keeps a column.
    pub fn move_tab_to_column_respawning_as(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        destination: ColumnMove,
        respawn: SplitRespawn,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        let ColumnMove { pane, after_column, width, dock } = destination;
        let width = validated_column_width(width)?;
        let source = self.with_state(|state| state.pane_of(surface));
        let source = source.context("tab has no pane")?;
        self.with_state(|state| {
            anyhow::ensure!(
                state.panes.get(&source).is_some_and(|candidate| candidate.tabs == [surface]),
                "bad request: respawn applies only to a pane's only tab"
            );
            Ok(())
        })?;
        let destination =
            TabDragDestination::Column { pane, after_column, width, dock, keep_focus: false };
        self.commit_tab_drag_respawning(actor, surface, source, destination, respawn, transaction)
    }

    /// Creates the fresh tab in `source` first (the pane never empties), then
    /// commits while `source` holds exactly the fresh and the dragged tab. A
    /// failed drag closes the fresh tab again.
    fn commit_tab_drag_respawning(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        source: PaneId,
        destination: TabDragDestination,
        respawn: SplitRespawn,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        let size = self.surface(surface).map(|runtime| runtime.size());
        let fresh = match respawn {
            SplitRespawn::Terminal(spawn) => {
                self.new_tab_with_options_as(actor, Some(source), spawn, size)?
            }
            SplitRespawn::Browser(record) => {
                self.new_frontend_browser_tab_as(actor, Some(source), record, size)?
            }
        };
        let guard = SourceGuard { pane: source, tabs: [fresh.id, surface] };
        match self.commit_tab_drag_guarded(actor, surface, destination, transaction, Some(guard)) {
            Ok(outcome) => Ok(outcome),
            Err(error) => {
                if let Err(close) = self.close_surface_as(actor, fresh.id) {
                    eprintln!(
                        "cmux-tui: respawn drag could not close fresh tab {}: {close:#}",
                        fresh.id
                    );
                }
                Err(error)
            }
        }
    }

    /// Move a tab into a new strip column on the screen containing `pane`.
    #[allow(clippy::too_many_arguments)]
    pub fn move_tab_to_column_as(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        pane: PaneId,
        after_column: Option<SplitId>,
        width: Option<f32>,
        dock: Option<ColumnDock>,
        keep_focus: bool,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        let width = validated_column_width(width)?;
        self.commit_tab_drag(
            actor,
            surface,
            TabDragDestination::Column { pane, after_column, width, dock, keep_focus },
            transaction,
        )
    }

    fn commit_tab_drag(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        destination: TabDragDestination,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        self.commit_tab_drag_guarded(actor, surface, destination, transaction, None)
    }

    /// [`Self::commit_tab_drag`], refused (before anything changes) unless
    /// `guard`'s pane holds exactly its tabs when the commit runs.
    fn commit_tab_drag_guarded(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        destination: TabDragDestination,
        transaction: Option<String>,
        guard: Option<SourceGuard>,
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
            &WorkspaceMutation::local("cmux-tui-tab-drag", actor.clone()),
            "tab.drag",
            &fingerprint,
            None,
            None,
            |state, registry| {
                if let Some(guard) = &guard {
                    guard.check(state)?;
                }
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
                let plan = ResourceMutationPlan::replacing(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    projected,
                );
                // The reducer models no pins, so it has no op for a pane's only tab
                // becoming a lone pinned column (`pinned-dock-alone-v1`); the I1-I3
                // checks of the live result still run.
                Ok(if destination.makes_lone_pinned_column(state, surface) {
                    plan
                } else {
                    plan.with_layout_op(destination.layout_op(surface, &ids))
                })
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
        self.emit_layout_changed(outcome.screen, None);
        self.emit_tab_changed_for_transaction(surface, transaction.map(Arc::from));
        Ok(outcome)
    }

    /// `move-tab` for a drag: move a tab to `pane` at insertion `index` in
    /// one commit. A move between two panes of one screen whose origin pane
    /// survives records a layout-undo entry that moves the tab back.
    /// Returns whether the tab moved and whether the move is undoable.
    pub fn move_tab_with_undo_as(
        self: &Arc<Self>,
        actor: &Actor,
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
        if !self.move_tab_as(actor, surface, pane, index) {
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
    /// caused it. The delta carries the presentation (pin, group, name) as of
    /// the emit, not as of before the decorations' git lookups: a commit in
    /// between is in it. The presentation lock is held through the emit (state
    /// first, as commits take them), so a commit's reload waits until this
    /// delta is out and its `tree-changed` comes after it.
    pub(crate) fn emit_tab_changed_for_transaction(
        &self,
        surface: SurfaceId,
        transaction: Option<Arc<str>>,
    ) {
        let mut decorations = self.tree_decorations();
        #[cfg(test)]
        if let Some(hook) =
            self.tab_changed_after_decorations.lock().unwrap_or_else(|e| e.into_inner()).clone()
        {
            hook();
        }
        let state = self.state.lock().unwrap();
        let presentation = self.presentation.lock().unwrap_or_else(|e| e.into_inner());
        decorations.presentation = Arc::clone(&presentation);
        let delta = presentation::tab_changed_delta(&state, &decorations, surface);
        drop(state);
        if let Some(mut delta) = delta {
            delta.transaction = transaction;
            self.emit(MuxEvent::TreeDelta(delta));
        }
        drop(presentation);
    }
}

/// A terminal moved to another workspace: its durable host placement names
/// the new workspace, as `move-tab` does.
pub(crate) fn retarget_terminal_workspace(
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

/// The focus a `keep_focus` split leaves in place: the active workspace, the
/// target workspace's active screen and the target screen's active pane, as
/// they were before the move (which makes the new pane active).
/// Ids, not indexes: the move can close the source pane's screen.
struct KeptFocus {
    workspace: Option<WorkspaceId>,
    screen: Option<ScreenId>,
    pane: PaneId,
}

impl KeptFocus {
    fn read(state: &State, workspace: usize, screen: usize) -> Self {
        let target = &state.workspaces[workspace];
        Self {
            workspace: state.workspaces.get(state.active_workspace).map(|item| item.id),
            screen: target.screens.get(target.active_screen).map(|item| item.id),
            pane: target.screens[screen].active_pane,
        }
    }

    /// Puts the focus back on the target screen (`workspace`, `screen`: its
    /// location after the move); false (nothing changed) when the focused
    /// pane closed in the move or no longer is on that screen, so the new
    /// pane takes focus as without `keep_focus`.
    fn restore(&self, state: &mut State, workspace: usize, screen: usize) -> bool {
        if state.screen_of(self.pane) != Some((workspace, screen)) {
            return false;
        }
        let active = self.workspace.and_then(|id| state.workspaces.iter().position(|w| w.id == id));
        let target = &mut state.workspaces[workspace];
        if let Some(index) =
            self.screen.and_then(|id| target.screens.iter().position(|s| s.id == id))
        {
            target.active_screen = index;
        }
        target.screens[screen].active_pane = self.pane;
        if let Some(active) = active {
            state.active_workspace = active;
        }
        true
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
pub(crate) fn apply_tab_drag(
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
    // `pinned-dock-alone-v1`: a pane's only tab may become a lone pinned column (Home's
    // dock): its pane closes and the pinned column is all the screen holds.
    let lone_pinned = destination.makes_lone_pinned_column(state, surface);
    anyhow::ensure!(
        source_pane != target_pane || source_tabs > 1 || lone_pinned,
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
    let kept_focus = matches!(
        destination,
        TabDragDestination::Split { keep_focus: true, .. }
            | TabDragDestination::Column { keep_focus: true, .. }
    )
    .then(|| KeptFocus::read(state, target_wi, target_si));
    let before = state.workspaces[target_wi].screens[target_si].layout_snapshot();
    {
        let screen = &mut state.workspaces[target_wi].screens[target_si];
        match destination {
            TabDragDestination::Split { edge, ratio, around, .. } => {
                let (dir, before_target) = edge.split();
                let in_column = screen.layout_columns_active();
                let (root, around) = if in_column {
                    let column = screen
                        .layout_column_for_pane_mut(target_pane)
                        .context("target pane has no viewport column")?;
                    column.creation_order_auto_layout = None;
                    // A row's chain split is no subtree to wrap (rows-v1).
                    let around = around.filter(|split| !column.is_row_split(*split));
                    (&mut column.root, around)
                } else {
                    (&mut screen.root, around)
                };
                // Around a whole split, the new pane is already on its side.
                let wrapped = around.is_some_and(|split| {
                    root.split_around(split, target_pane, ids.split, dir, ids.pane, before_target)
                });
                anyhow::ensure!(
                    wrapped || root.split_leaf(target_pane, ids.split, dir, ids.pane),
                    "target pane disappeared from its layout"
                );
                if before_target && !wrapped {
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
                    screen.creation_order_auto_layout = None;
                }
            }
            TabDragDestination::Column { after_column, width, dock, .. } => {
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
                let mut column = LayoutColumn::single(ids.split, width, ids.pane);
                // `pinned-dock-alone-v1`: a pane's only tab that becomes a lone pinned
                // column (Home's dock with nothing beside it) is pinned before the move, so
                // the column does not collapse back to a plain screen when its source column
                // closes. Every other dock is set after the move, below.
                if lone_pinned {
                    column.dock = dock;
                }
                anyhow::ensure!(
                    screen.insert_layout_column_after(anchor, ids.base_column, column),
                    "column anchor disappeared from its layout"
                );
            }
        }
        if kept_focus.is_none() {
            screen.active_pane = ids.pane;
        }
        screen.zoomed_pane = None;
    }
    state.insert_pane(Pane {
        id: ids.pane,
        public_id: ids.pane_public.clone(),
        name: None,
        tabs: Vec::new(),
        active_tab: 0,
        // A kept focus leaves the new pane least recent, so closing the
        // focused pane does not move focus into it either.
        active_at: if kept_focus.is_some() { 0 } else { mux.next_active_at() },
        focused_at: 0,
    });
    let (moved, _) = move_tab_in_state(mux, state, surface, ids.pane, 0);
    anyhow::ensure!(moved, "tab could not be moved into its new pane");
    let (target_wi, target_si) =
        screen_location(state, target_screen).context("drag destination screen disappeared")?;
    match kept_focus {
        Some(kept) if kept.restore(state, target_wi, target_si) => {}
        _ => stamp_pane_focus(mux, state, ids.pane),
    }
    if let TabDragDestination::Column { dock: Some(dock), .. } = destination {
        // Pinned after the move: the move may close the source column, and
        // the same rules as `set-column-dock` must hold on the result (one
        // column per edge, the old holder scrolls again; one column scrolls).
        // A refusal fails the whole drag on this projected copy.
        let screen = &mut state.workspaces[target_wi].screens[target_si];
        let index = screen.layout_columns.iter().position(|c| c.id == ids.split);
        let index = index.context("new column disappeared")?;
        let flags: Vec<_> = screen.layout_columns.iter().map(|c| c.dock).collect();
        let flags = reduce_column_dock(&flags, index, Some(dock))?;
        for (column, flag) in screen.layout_columns.iter_mut().zip(flags) {
            column.dock = flag;
        }
        // A left dock leads the column order, so undocking it scrolls it in
        // on the left, where it was shown (cx-x7pl: the agent chat dock went
        // to the far right of the strip).
        if dock.edge == DockEdge::Left && index != 0 {
            let column = screen.layout_columns.remove(index);
            screen.layout_columns.insert(0, column);
            screen.sync_layout_column_projection();
        }
    }
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
mod tests;
