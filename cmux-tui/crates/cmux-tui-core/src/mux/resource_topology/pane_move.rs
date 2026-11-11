//! `pane.move` (W5-P): move a whole pane, every tab in order, in one
//! journaled commit.
//!
//! - `destination_pane` with `split`: the pane goes beside that pane, on
//!   that side. It keeps its id, its name and its tabs.
//! - `new_screen`: the pane becomes the only pane of a new screen in
//!   `destination_workspace` (default: its own workspace). It keeps its id.
//! - `destination_pane` without `split`, or `destination_tab`: the tabs go
//!   into that pane (at `index`; after the tab, or at the end) and the moved
//!   pane closes. Its tabs keep their ids; the pane id goes.
//!
//! A screen that the move empties closes; a workspace stays. The focus
//! stays where it was, unless the caller passes `focus: true` or the moved
//! pane had the focus: then the pane that holds the tabs has it.
//!
//! The plan edits a clone of the state and commits the full projection of
//! it, so a crash leaves the state before or after the move, never between.
//! A retry with the same idempotency key replays the stored result.

use crate::mux::tab_drag::retarget_terminal_workspace;
use crate::mux::tree_edit::{close_focus_successor, close_sibling, remove_pane_from_screen_layout};
use crate::resource::Selector;

use super::*;

/// Where `pane.move` puts the pane.
#[derive(Debug, Clone, Copy)]
enum Destination {
    /// A new pane split off `pane` (split direction, the moved pane first).
    Split { pane: PaneId, dir: SplitDir, before: bool },
    /// Into `pane` at `index`; the moved pane closes.
    Merge { pane: PaneId, index: usize },
    /// A new screen in `workspace`.
    NewScreen { workspace: WorkspaceId },
}

/// What the move did, for the result and the work after the commit.
struct Moved {
    /// The pane that holds the tabs now.
    pane: PaneId,
    tabs: Vec<SurfaceId>,
    first_index: usize,
    created_screen: Option<ScreenPublicId>,
    closed_screen: Option<ScreenPublicId>,
}

fn invalid(field: &str, reason: impl Into<String>) -> anyhow::Error {
    anyhow::Error::new(ResourceError::validation_invalid(Some(field), reason))
}

fn text_field<'a>(fields: &'a Map<String, Value>, name: &str) -> Option<&'a str> {
    fields.get(name).and_then(Value::as_str)
}

/// The selectors of a destination field: a name or `current` gets
/// `current` parents where the caller gave none, as the CLI sends a
/// target, so a name not in the focused place is looked up in the session.
fn destination_selectors(
    selectors: &ResourceSelectors,
    fields: &Map<String, Value>,
    slot: ResourceTarget,
    raw: &str,
) -> ResourceSelectors {
    let implicit = !matches!(Selector::parse(raw), Ok(Selector::Id(_)));
    let parent = |name: &str| {
        text_field(fields, name).map(str::to_owned).or_else(|| implicit.then(|| "current".into()))
    };
    let mut destination = ResourceSelectors {
        machine: selectors.machine.clone(),
        session: selectors.session.clone(),
        workspace: parent("destination_workspace"),
        screen: parent("destination_screen"),
        ..Default::default()
    };
    match slot {
        ResourceTarget::Tab => {
            destination.pane = implicit.then(|| "current".into());
            destination.tab = Some(raw.to_owned());
        }
        _ => destination.pane = Some(raw.to_owned()),
    }
    destination
}

/// The split direction of `split` and whether the moved pane goes first.
fn split_edge(split: &str) -> anyhow::Result<(SplitDir, bool)> {
    Ok(match split {
        "left" => (SplitDir::Right, true),
        "right" => (SplitDir::Right, false),
        "up" => (SplitDir::Down, true),
        "down" => (SplitDir::Down, false),
        other => {
            return Err(invalid("split", format!("split is left, right, up or down, not {other}")));
        }
    })
}

/// The workspace and screen positions of the screen with id `screen`.
fn screen_position(state: &State, screen: ScreenId) -> Option<(usize, usize)> {
    state.workspaces.iter().enumerate().find_map(|(workspace, item)| {
        item.screens.iter().position(|candidate| candidate.id == screen).map(|at| (workspace, at))
    })
}

fn screen_at(state: &mut State, (workspace, screen): (usize, usize)) -> Option<&mut Screen> {
    state.workspaces.get_mut(workspace).and_then(|item| item.screens.get_mut(screen))
}

/// Take `pane` out of its screen's layout and keep it. Returns the screen's
/// id when the screen emptied and closed.
fn detach_pane(
    mux: &Mux,
    state: &mut State,
    pane: PaneId,
) -> anyhow::Result<Option<ScreenPublicId>> {
    let location = state.screen_of(pane).context("the moved pane has no screen")?;
    let (remains, was_active, panes, sibling) = {
        let screen = screen_at(state, location).context("the moved pane's screen disappeared")?;
        let was_active = screen.active_pane == pane;
        if screen.zoomed_pane == Some(pane) {
            screen.zoomed_pane = None;
        }
        // The same successor as a pane close (#38194): the pane focused
        // last, else the sibling that takes the moved pane's space.
        let sibling = close_sibling(screen, pane);
        let remains = remove_pane_from_screen_layout(mux, screen, pane);
        (remains, was_active, screen.root.pane_ids_vec(), sibling)
    };
    if remains {
        if was_active
            && let Some(next) = close_focus_successor(state, &panes, sibling)
            && let Some(screen) = screen_at(state, location)
        {
            screen.active_pane = next;
        }
        return Ok(None);
    }
    let workspace =
        state.workspaces.get_mut(location.0).context("the moved pane's workspace disappeared")?;
    anyhow::ensure!(location.1 < workspace.screens.len(), "the moved pane's screen disappeared");
    let closed = workspace.screens.remove(location.1);
    workspace.active_screen =
        workspace.active_screen.min(workspace.screens.len().saturating_sub(1));
    Ok(Some(closed.public_id))
}

/// Put `moved` beside `target`, split in `dir`.
fn attach_split(
    state: &mut State,
    moved: PaneId,
    target: PaneId,
    dir: SplitDir,
    before: bool,
    split: SplitId,
) -> anyhow::Result<()> {
    let location = state.screen_of(target).context("the destination pane has no screen")?;
    let screen = screen_at(state, location).context("the destination screen disappeared")?;
    let in_column = screen.layout_columns_active();
    let root = if in_column {
        let column = screen
            .layout_column_for_pane_mut(target)
            .context("the destination pane has no viewport column")?;
        column.creation_order_auto_layout = None;
        &mut column.root
    } else {
        &mut screen.root
    };
    anyhow::ensure!(
        root.split_leaf(target, split, dir, moved),
        "the destination pane disappeared from its layout"
    );
    if before {
        anyhow::ensure!(root.swap_leaves(target, moved), "the new split could not be ordered");
    }
    if in_column {
        screen.sync_layout_column_projection();
    } else {
        screen.creation_order_auto_layout = None;
    }
    screen.zoomed_pane = None;
    screen.invalidate_layout_undo();
    Ok(())
}

/// The focus before the move: the focused workspace, screen and pane, and
/// each workspace's selected screen and each screen's active pane, by id.
struct KeptFocus {
    focused: Option<(WorkspaceId, ScreenId, PaneId)>,
    screens: Vec<(WorkspaceId, ScreenId)>,
    panes: Vec<(ScreenId, PaneId)>,
}

impl KeptFocus {
    fn read(state: &State) -> Self {
        Self {
            focused: current_focus_identity(state),
            screens: state
                .workspaces
                .iter()
                .filter_map(|workspace| {
                    workspace.screens.get(workspace.active_screen).map(|s| (workspace.id, s.id))
                })
                .collect(),
            panes: state
                .workspaces
                .iter()
                .flat_map(|workspace| &workspace.screens)
                .map(|screen| (screen.id, screen.active_pane))
                .collect(),
        }
    }

    /// Puts back every selection the move did not remove.
    fn restore(&self, state: &mut State) {
        for (workspace, screen) in &self.screens {
            if let Some(index) = state.workspace_index(*workspace)
                && let Some(item) = state.workspaces.get_mut(index)
                && let Some(at) = item.screens.iter().position(|s| s.id == *screen)
            {
                item.active_screen = at;
            }
        }
        for (screen, pane) in &self.panes {
            if let Some(location) = screen_position(state, *screen)
                && let Some(item) = screen_at(state, location)
                && item.root.contains(*pane)
            {
                item.active_pane = *pane;
            }
        }
        restore_focus_identity(state, self.focused);
    }
}

/// Focus `pane`: its workspace, its screen, and it.
fn focus_pane(mux: &Mux, state: &mut State, pane: PaneId) -> anyhow::Result<()> {
    let (workspace, screen) =
        state.screen_of(pane).context("the moved tabs' pane has no screen")?;
    state.active_workspace = workspace;
    let item = state.workspaces.get_mut(workspace).context("workspace disappeared")?;
    item.active_screen = screen;
    let item = item.screens.get_mut(screen).context("screen disappeared")?;
    item.active_pane = pane;
    stamp_pane_focus(mux, state, pane);
    Ok(())
}

/// Moves `source` to `destination` in `state` (a clone of the live state).
fn move_pane_in_state(
    mux: &Mux,
    state: &mut State,
    source: PaneId,
    destination: Destination,
    name: Option<String>,
) -> anyhow::Result<Moved> {
    let pane = state.panes.get(&source).context("the moved pane disappeared")?;
    let tabs = pane.tabs.clone();
    let selected = pane.active_surface();
    anyhow::ensure!(!tabs.is_empty(), "the moved pane has no tab");
    let moved = match destination {
        Destination::Split { pane: target, dir, before } => {
            // No index rebuild between the two steps: a rebuild drops the
            // tab identities of a pane outside every screen.
            let closed_screen = detach_pane(mux, state, source)?;
            attach_split(state, source, target, dir, before, mux.next_id())?;
            Moved { pane: source, tabs, first_index: 0, created_screen: None, closed_screen }
        }
        Destination::NewScreen { workspace } => {
            let closed_screen = detach_pane(mux, state, source)?;
            let public_id = ScreenPublicId::random()?;
            let index = state.workspace_index(workspace).context("workspace disappeared")?;
            let item = state.workspaces.get_mut(index).context("workspace disappeared")?;
            item.screens.push(Screen {
                id: mux.next_id(),
                public_id: public_id.clone(),
                name,
                root: Node::Leaf(source),
                active_pane: source,
                zoomed_pane: None,
                creation_order_auto_layout: Some(vec![source]),
                viewport_splits: Default::default(),
                viewport_base_width: None,
                layout_columns: Vec::new(),
                layout_revision: 0,
                layout_undo: Default::default(),
            });
            // A workspace whose only screen this is shows it.
            if item.screens.len() == 1 {
                item.active_screen = 0;
            }
            Moved {
                pane: source,
                tabs,
                first_index: 0,
                created_screen: Some(public_id),
                closed_screen,
            }
        }
        Destination::Merge { pane: target, index } => {
            let source_screen = state
                .screen_of(source)
                .and_then(|(workspace, screen)| {
                    state.workspaces.get(workspace)?.screens.get(screen)
                })
                .map(|screen| screen.public_id.clone());
            let first_index = index.min(state.panes.get(&target).map_or(0, |pane| pane.tabs.len()));
            for (offset, surface) in tabs.iter().enumerate() {
                let (moved, _) =
                    move_tab_in_state(mux, state, *surface, target, first_index + offset);
                anyhow::ensure!(moved, "tab {surface} could not move into the destination pane");
            }
            // The tab that was selected in the moved pane stays selected.
            if let Some(selected) = selected
                && let Some(pane) = state.panes.get_mut(&target)
                && let Some(at) = pane.tabs.iter().position(|tab| *tab == selected)
            {
                pane.active_tab = at;
            }
            let closed_screen = source_screen.filter(|screen| {
                !state.workspaces.iter().any(|workspace| {
                    workspace.screens.iter().any(|candidate| candidate.public_id == *screen)
                })
            });
            Moved { pane: target, tabs, first_index, created_screen: None, closed_screen }
        }
    };
    state.rebuild_resource_indexes();
    Mux::rebuild_split_screen_index(state);
    Ok(moved)
}

impl Mux {
    pub(super) fn resource_move_pane(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        fields: &Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let destination_pane = text_field(fields, "destination_pane");
        let destination_tab = text_field(fields, "destination_tab");
        let new_screen = fields.get("new_screen").and_then(Value::as_bool).unwrap_or(false);
        let split = text_field(fields, "split").map(split_edge).transpose()?;
        let name = text_field(fields, "name").map(str::to_owned);
        let index = fields
            .get("index")
            .and_then(Value::as_u64)
            .map(|index| usize::try_from(index).unwrap_or(usize::MAX));
        let focus = fields.get("focus").and_then(Value::as_bool).unwrap_or(false);
        let chosen = [destination_pane.is_some(), destination_tab.is_some(), new_screen];
        if chosen.iter().filter(|chosen| **chosen).count() != 1 {
            return Err(invalid(
                "destination_pane",
                "pane.move takes exactly one of destination_pane, destination_tab and new_screen",
            ));
        }
        if split.is_some() && destination_pane.is_none() {
            return Err(invalid("split", "split goes with destination_pane"));
        }
        if name.is_some() && !new_screen {
            return Err(invalid("name", "name names the new screen: it goes with new_screen"));
        }
        if name.as_deref().is_some_and(|name| name.trim().is_empty()) {
            return Err(invalid("name", "the new screen's name is empty"));
        }
        if index.is_some() && (new_screen || split.is_some()) {
            return Err(invalid(
                "index",
                "index places tabs in a pane: not with split or new_screen",
            ));
        }
        if new_screen && text_field(fields, "destination_screen").is_some() {
            return Err(invalid("destination_screen", "new_screen makes the screen"));
        }

        let mux = Arc::clone(self);
        let mut committed = None;
        let commit = self.commit_resource_mutation_plan(
            mutation,
            "pane.move",
            fingerprint,
            None,
            expected_revision,
            |state, registry| {
                let source = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let source_pane = source.pane.context("pane selector has no live pane")?;
                let source_id = source.path.pane.clone().context("pane has no public id")?;
                let source_workspace = source.workspace.context("pane has no workspace")?;
                let resolve = |slot: ResourceTarget, raw: &str| {
                    let selectors = destination_selectors(&selectors, fields, slot, raw);
                    mux.resolve_resource_path_in_state(state, registry, slot, &selectors)
                        .map_err(anyhow::Error::new)
                };
                let destination = match (destination_pane, destination_tab) {
                    (Some(raw), _) => {
                        let target =
                            resolve(ResourceTarget::Pane, raw)?.pane.context("no live pane")?;
                        match split {
                            Some((dir, before)) => Destination::Split { pane: target, dir, before },
                            None => Destination::Merge {
                                pane: target,
                                index: index.unwrap_or(usize::MAX),
                            },
                        }
                    }
                    (None, Some(raw)) => {
                        let found = resolve(ResourceTarget::Tab, raw)?;
                        let tab = found.tab.context("no live tab")?;
                        let target = found.pane.context("the tab has no pane")?;
                        let after = state
                            .panes
                            .get(&target)
                            .and_then(|pane| pane.tabs.iter().position(|item| *item == tab))
                            .map_or(usize::MAX, |at| at.saturating_add(1));
                        Destination::Merge { pane: target, index: index.unwrap_or(after) }
                    }
                    (None, None) => {
                        let workspace = match text_field(fields, "destination_workspace") {
                            Some(raw) => {
                                let selectors = ResourceSelectors {
                                    machine: selectors.machine.clone(),
                                    session: selectors.session.clone(),
                                    workspace: Some(raw.to_owned()),
                                    ..Default::default()
                                };
                                mux.resolve_resource_path_in_state(
                                    state,
                                    registry,
                                    ResourceTarget::Workspace,
                                    &selectors,
                                )
                                .map_err(anyhow::Error::new)?
                                .workspace
                                .context("no live workspace")?
                            }
                            None => source_workspace,
                        };
                        Destination::NewScreen { workspace }
                    }
                };
                if let Destination::Split { pane, .. } | Destination::Merge { pane, .. } =
                    destination
                    && pane == source_pane
                {
                    return Err(invalid(
                        if destination_tab.is_some() {
                            "destination_tab"
                        } else {
                            "destination_pane"
                        },
                        format!(
                            "pane {source_id} cannot move into itself: name a place outside it"
                        ),
                    ));
                }

                let kept = KeptFocus::read(state);
                let source_focused = state.active_pane() == Some(source_pane);
                let source_key = state
                    .workspace_by_id(source_workspace)
                    .map(|workspace| workspace.key.clone())
                    .context("the moved pane's workspace disappeared")?;
                let mut projected = state.clone();
                let moved =
                    move_pane_in_state(&mux, &mut projected, source_pane, destination, name)?;
                if focus || source_focused {
                    focus_pane(&mux, &mut projected, moved.pane)?;
                } else {
                    kept.restore(&mut projected);
                }
                let (workspace, screen) = projected
                    .screen_of(moved.pane)
                    .context("the moved tabs' pane has no screen")?;
                let workspace = projected.workspaces.get(workspace).context("no workspace")?;
                let target_key = workspace.key.clone();
                let workspace_id = workspace.public_id.clone();
                let screen_item = workspace.screens.get(screen).context("no screen")?;
                let screen_id = screen_item.public_id.clone();
                let screen_slot = screen_item.id;
                let workspace_slot = workspace.id;
                let pane_id = projected
                    .resource_indexes
                    .pane_ids
                    .get(&moved.pane)
                    .cloned()
                    .context("the moved tabs' pane has no public id")?;
                if moved.pane == source_pane {
                    // Merge moves update their tabs' paths in `move_tab_in_state`.
                    for surface in &moved.tabs {
                        mux.subscribers.update_surface_session_path(
                            *surface,
                            workspace_slot,
                            screen_slot,
                            moved.pane,
                        );
                    }
                }
                let tab_ids = moved
                    .tabs
                    .iter()
                    .filter_map(|surface| projected.resource_indexes.tab_ids.get(surface).cloned())
                    .collect::<Vec<_>>();
                let terminals = moved
                    .tabs
                    .iter()
                    .filter_map(|surface| {
                        match projected.resource_indexes.content_ids.get(surface) {
                            Some(ContentPublicId::Terminal(id)) => Some(id.clone()),
                            _ => None,
                        }
                    })
                    .collect::<Vec<_>>();
                let focused_pane = projected
                    .active_pane()
                    .and_then(|pane| projected.resource_indexes.pane_ids.get(&pane).cloned());
                let mut result = json!({
                    "pane_id": pane_id,
                    "moved_pane_id": source_id,
                    "pane_kept": moved.pane == source_pane,
                    "workspace_id": workspace_id,
                    "screen_id": screen_id,
                    "tab_ids": tab_ids,
                    "index": moved.first_index,
                });
                if let Some(object) = result.as_object_mut() {
                    if let Some(created) = &moved.created_screen {
                        object.insert("created_screen_id".into(), json!(created));
                    }
                    if let Some(closed) = &moved.closed_screen {
                        object.insert("closed_screen_id".into(), json!(closed));
                    }
                    if let Some(focused) = &focused_pane {
                        object.insert("focused_pane_id".into(), json!(focused));
                    }
                }
                let mut projection =
                    mux.resource_effect_projection_locked(registry, &mut projected, result)?;
                if source_key != target_key {
                    for terminal in &terminals {
                        retarget_terminal_workspace(&mut projection.patch, terminal, &target_key);
                    }
                }
                committed = Some((moved.tabs, source_key != target_key, target_key));
                Ok(ResourceMutationPlan::replacing(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    projected,
                )
                .projected(projection.restates_all))
            },
        )?;
        if !commit.replayed
            && let Some((tabs, crossed, key)) = committed
            && crossed
        {
            for surface in tabs {
                if let Some(runtime) = self.surface(surface) {
                    // The durable record already names the new workspace;
                    // the host copy follows it, as a tab drag's does.
                    let _ = runtime.persist_host_workspace(&key);
                }
            }
        }
        Ok(commit)
    }
}
