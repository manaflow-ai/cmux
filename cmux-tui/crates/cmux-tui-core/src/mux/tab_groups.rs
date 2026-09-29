//! Chrome-style tab groups and saved (pinned) groups.
//!
//! A tab group lives in one pane's tab strip: an id, a name (may be empty),
//! one of Chrome's nine colors, and a shared collapsed flag. Each tab
//! placement belongs to at most one group, and members are contiguous in
//! tab order. Membership is keyed by the public tab id and is valid only
//! while the tab sits in the group's pane, so a tab moved away by another
//! path simply leaves its group.
//!
//! Commands that change tab order (create, add, remove, move, close) run on
//! a clone of the live state, project the full tree, and commit the patch
//! and the tab group rows in one transaction. Metadata-only commands
//! (rename, recolor, collapse, ungroup, save) write the group rows alone.
//!
//! A saved group is a session-wide record (name, color, member descriptors)
//! that outlives its placements. A live group linked to a saved record keeps
//! it in sync; reopening a saved group reattaches still-running terminals
//! and starts new ones in the saved directory otherwise.

use super::tab_drag::{TabDragDestination, TabDragIds, apply_tab_drag};
use super::*;
use crate::workspace_registry::{
    PresentationSnapshot, SavedTabGroupRecord, SavedTabMember, TabGroupRecord, TabGroupState,
    WorkspacePresentationUpdate, new_saved_tab_group_id, new_tab_group_id,
    validate_tab_group_color, validate_tab_group_name, validate_workspace_group_id,
};

/// One contiguous group run in a pane's tab strip, as frontends see it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneTabGroup {
    pub group: TabGroupRecord,
    /// Strip index of the first member.
    pub start: usize,
    pub members: Vec<SurfaceId>,
}

/// Where a whole tab group lands.
#[derive(Debug, Clone, PartialEq)]
pub enum TabGroupDestination {
    /// Into `pane`'s strip (the group's own pane reorders it) at insertion
    /// index `index` among that pane's other tabs (default: the end).
    Strip { pane: PaneId, index: Option<usize> },
    /// Into a new split beside `pane`.
    Split { pane: PaneId, edge: TabDropEdge, ratio: Option<f32> },
    /// Into a new niri column on `pane`'s screen.
    Column { pane: PaneId, after_column: Option<SplitId>, width: Option<f32> },
    /// Into a new workspace, optionally in a sidebar group at an index.
    NewWorkspace { group: Option<String>, index: Option<usize> },
}

/// Result of a tab group command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabGroupOutcome {
    pub group: Option<TabGroupRecord>,
    pub pane: Option<PaneId>,
    pub members: Vec<SurfaceId>,
    pub workspace: Option<WorkspaceId>,
}

/// Contiguous group runs of one pane. A group's run starts at its first
/// member in strip order; a member after a gap is reported ungrouped, so
/// frontends always see contiguous groups even after a legacy path moved a
/// tab into the middle of a strip.
pub(crate) fn pane_tab_groups(
    state: &State,
    presentation: &PresentationSnapshot,
    pane: PaneId,
) -> Vec<PaneTabGroup> {
    let (Some(record), Some(pane_public)) =
        (state.panes.get(&pane), state.resource_indexes.pane_ids.get(&pane))
    else {
        return Vec::new();
    };
    let mut runs: Vec<PaneTabGroup> = Vec::new();
    let mut open: Option<usize> = None;
    for (index, surface) in record.tabs.iter().enumerate() {
        let group = state
            .resource_indexes
            .tab_ids
            .get(surface)
            .and_then(|tab| presentation.tab_groups.members.get(tab.as_str()))
            .and_then(|group| presentation.tab_groups.groups.get(group))
            .filter(|group| group.pane_id == pane_public.as_str());
        match group {
            Some(group) if open.is_some_and(|run| runs[run].group.id == group.id) => {
                runs[open.expect("checked open run")].members.push(*surface);
            }
            Some(group) if !runs.iter().any(|run| run.group.id == group.id) => {
                runs.push(PaneTabGroup {
                    group: group.clone(),
                    start: index,
                    members: vec![*surface],
                });
                open = Some(runs.len() - 1);
            }
            _ => open = None,
        }
    }
    runs
}

fn tab_public_id(state: &State, surface: SurfaceId) -> anyhow::Result<String> {
    state
        .resource_indexes
        .tab_ids
        .get(&surface)
        .map(|tab| tab.as_str().to_string())
        .with_context(|| format!("surface {surface} has no tab identity"))
}

fn pane_public_id(state: &State, pane: PaneId) -> anyhow::Result<String> {
    state
        .resource_indexes
        .pane_ids
        .get(&pane)
        .map(|id| id.as_str().to_string())
        .with_context(|| format!("unknown pane {pane}"))
}

fn pane_by_public_id(state: &State, pane: &str) -> Option<PaneId> {
    state
        .resource_indexes
        .panes
        .iter()
        .find_map(|(id, slot)| (id.as_str() == pane).then_some(*slot))
}

/// The current members of `group` in strip order.
fn group_members(state: &State, groups: &TabGroupState, group: &str) -> Vec<SurfaceId> {
    let Some(record) = groups.groups.get(group) else { return Vec::new() };
    let Some(pane) = pane_by_public_id(state, &record.pane_id) else { return Vec::new() };
    state.panes[&pane]
        .tabs
        .iter()
        .copied()
        .filter(|surface| {
            state
                .resource_indexes
                .tab_ids
                .get(surface)
                .and_then(|tab| groups.members.get(tab.as_str()))
                .is_some_and(|member| member == group)
        })
        .collect()
}

/// Reorder `pane` so `block` sits contiguously starting at insertion index
/// `index` among the pane's other tabs. The active tab stays active.
fn place_block(state: &mut State, pane: PaneId, block: &[SurfaceId], index: usize) {
    let Some(record) = state.panes.get_mut(&pane) else { return };
    let active = record.active_surface();
    let mut rest =
        record.tabs.iter().copied().filter(|surface| !block.contains(surface)).collect::<Vec<_>>();
    let index = index.min(rest.len());
    rest.splice(index..index, block.iter().copied());
    record.tabs = rest;
    if let Some(active) = active {
        record.active_tab =
            record.tabs.iter().position(|surface| *surface == active).unwrap_or(record.active_tab);
    }
    for surface in block {
        state.resource_indexes.tab_pane.insert(*surface, pane);
    }
}

/// Drop memberships whose tab is gone or left the group's pane, and groups
/// left without members.
fn prune_tab_groups(state: &State, groups: &mut TabGroupState) {
    let live = state
        .panes
        .values()
        .flat_map(|pane| {
            let pane_public =
                state.resource_indexes.pane_ids.get(&pane.id).map(|id| id.as_str().to_string());
            pane.tabs.iter().filter_map(move |surface| {
                Some((
                    state.resource_indexes.tab_ids.get(surface)?.as_str().to_string(),
                    pane_public.clone()?,
                ))
            })
        })
        .collect::<HashMap<String, String>>();
    let panes = groups
        .groups
        .iter()
        .map(|(id, group)| (id.clone(), group.pane_id.clone()))
        .collect::<HashMap<_, _>>();
    groups.members.retain(|tab, group| {
        live.get(tab).is_some_and(|pane| panes.get(group).is_some_and(|expected| expected == pane))
    });
    let occupied = groups.members.values().cloned().collect::<HashSet<_>>();
    groups.groups.retain(|id, _| occupied.contains(id));
}

fn is_pinned(state: &State, presentation: &PresentationSnapshot, surface: SurfaceId) -> bool {
    state
        .resource_indexes
        .tab_ids
        .get(&surface)
        .is_some_and(|tab| presentation.pinned_tabs.contains(tab.as_str()))
}

/// Move `members` (in order) into `pane` at insertion index `index`, across
/// panes when needed. Returns the members that changed workspace.
fn move_members_into(
    mux: &Mux,
    state: &mut State,
    members: &[SurfaceId],
    pane: PaneId,
    index: usize,
) -> anyhow::Result<()> {
    for surface in members {
        if state.pane_of(*surface) != Some(pane) {
            let end = state.panes.get(&pane).map_or(0, |record| record.tabs.len());
            let (moved, _) = move_tab_in_state(mux, state, *surface, pane, end);
            anyhow::ensure!(moved, "tab {surface} could not be moved");
        }
    }
    place_block(state, pane, members, index);
    fence_layout_undo_for_tab_membership(state, &[pane]);
    Ok(())
}

impl Mux {
    /// Commit a tab group change that may reorder or move tabs. `mutate`
    /// edits a clone of the live state and the tab group rows; both commit
    /// together, and the clone replaces the live state only afterwards.
    fn commit_tab_group_change<R>(
        self: &Arc<Self>,
        operation: &str,
        workspace_group: Option<String>,
        mutate: impl FnOnce(&Arc<Mux>, &mut State, &mut TabGroupState) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let mux = Arc::clone(self);
        let mut output = None;
        let mut retarget = Vec::new();
        let fingerprint = serde_json::json!({
            "operation": operation,
            "nonce": crate::workspace_registry::new_uuid_v4(),
        });
        self.commit_resource_mutation_plan(
            &WorkspaceMutation::local("cmux-tui-tab-groups"),
            operation,
            &fingerprint,
            None,
            None,
            |state, registry| {
                let mut projected = state.clone();
                let mut groups = mux.presentation_snapshot().tab_groups.clone();
                let result = mutate(&mux, &mut projected, &mut groups)?;
                Mux::rebuild_split_screen_index(&mut projected);
                prune_tab_groups(&projected, &mut groups);
                let workspace_key = |state: &State, surface: SurfaceId| {
                    state
                        .pane_of(surface)
                        .and_then(|pane| state.screen_of(pane))
                        .map(|(workspace, _)| state.workspaces[workspace].key.clone())
                };
                for (surface, runtime) in &projected.surfaces {
                    let (Some(before), Some(after)) =
                        (workspace_key(&*state, *surface), workspace_key(&projected, *surface))
                    else {
                        continue;
                    };
                    if before != after
                        && let Some(terminal) = runtime.terminal_public_id()
                    {
                        retarget.push((*surface, terminal.clone(), after));
                    }
                }
                let created = projected
                    .workspaces
                    .iter()
                    .enumerate()
                    .find(|(_, workspace)| state.workspace_index(workspace.id).is_none())
                    .map(|(index, workspace)| (index, workspace.id, workspace.key.clone()));
                let ledger = created.map(|(index, id, key)| ResourceWorkspaceLedger {
                    event_kind: "workspace-added",
                    workspace_key: key.clone(),
                    workspaces: mux.registry_projection(&projected),
                    legacy_result: serde_json::json!({
                        "workspace": id,
                        "key": key,
                        "index": index,
                        "changed": true,
                    }),
                    presentation: workspace_group.clone().map(|group| {
                        WorkspacePresentationUpdate {
                            group: Some(Some(group)),
                            ..WorkspacePresentationUpdate::default()
                        }
                    }),
                });
                let mut projection = mux.resource_effect_projection_locked(
                    registry,
                    &mut projected,
                    serde_json::json!({}),
                )?;
                for (_, terminal, key) in &retarget {
                    tab_drag::retarget_terminal_workspace(&mut projection.patch, terminal, key);
                }
                output = Some(result);
                let mut plan = ResourceMutationPlan::new(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    move |state| *state = projected,
                )
                .with_tab_groups(groups);
                if let Some(ledger) = ledger {
                    plan = plan.with_workspace_ledger(ledger);
                }
                Ok(plan)
            },
        )?;
        {
            let registry = self.workspace_registry.lock().unwrap();
            self.reload_presentation(&registry)?;
        }
        for (surface, _, key) in retarget {
            if let Some(runtime) = self.surface(surface) {
                let _ = runtime.persist_host_workspace(&key);
            }
        }
        self.publish_journal_event();
        self.emit(MuxEvent::TreeChanged);
        output.context("tab group change committed no result")
    }

    /// Write tab group rows without changing tab order.
    fn commit_tab_group_metadata<R>(
        &self,
        mutate: impl FnOnce(&State, &mut TabGroupState) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let result = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let state = self.state.lock().unwrap();
            let mut groups = self.presentation_snapshot().tab_groups.clone();
            let result = mutate(&state, &mut groups)?;
            prune_tab_groups(&state, &mut groups);
            drop(state);
            registry.replace_tab_groups(&groups)?;
            self.reload_presentation(&registry)?;
            result
        };
        self.publish_journal_event();
        self.emit(MuxEvent::TreeChanged);
        Ok(result)
    }

    fn emit_tab_group_members(&self, members: &[SurfaceId], transaction: Option<&str>) {
        for surface in members {
            self.emit_tab_changed_for_transaction(*surface, transaction.map(Arc::from));
        }
    }

    fn tab_group_outcome(&self, group: &str) -> TabGroupOutcome {
        let presentation = self.presentation_snapshot();
        self.with_state(|state| {
            let record = presentation.tab_groups.groups.get(group).cloned();
            let pane = record.as_ref().and_then(|record| pane_by_public_id(state, &record.pane_id));
            let members = group_members(state, &presentation.tab_groups, group);
            let workspace = pane
                .and_then(|pane| state.screen_of(pane))
                .map(|(workspace, _)| state.workspaces[workspace].id);
            TabGroupOutcome { group: record, pane, members, workspace }
        })
    }

    /// Create a group from tabs of one pane. The members become contiguous
    /// at the strip position of the first of them; tabs leave any group
    /// they were in. Pinned tabs cannot be grouped.
    pub fn create_tab_group(
        self: &Arc<Self>,
        surfaces: &[SurfaceId],
        name: Option<String>,
        color: Option<String>,
        id: Option<String>,
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        anyhow::ensure!(!surfaces.is_empty(), "bad request: a tab group needs at least one tab");
        let name = name.unwrap_or_default();
        let color = color.unwrap_or_else(|| "grey".to_string());
        validate_tab_group_name(&name)?;
        validate_tab_group_color(&color)?;
        let id = id.unwrap_or_else(new_tab_group_id);
        validate_workspace_group_id(&id)?;
        anyhow::ensure!(
            !self.presentation_snapshot().tab_groups.groups.contains_key(&id),
            "tab group {id} already exists"
        );
        let group_id = id.clone();
        let requested = surfaces.to_vec();
        self.commit_tab_group_change("tab.group.create", None, move |mux, state, groups| {
            let presentation = mux.presentation_snapshot();
            let pane = state
                .pane_of(requested[0])
                .with_context(|| format!("unknown surface {}", requested[0]))?;
            let tabs = state.panes[&pane].tabs.clone();
            let mut members = Vec::new();
            for surface in &requested {
                anyhow::ensure!(
                    state.pane_of(*surface) == Some(pane),
                    "bad request: tab group members must share one pane"
                );
                anyhow::ensure!(
                    !is_pinned(state, &presentation, *surface),
                    "bad request: pinned tabs cannot be grouped"
                );
                if !members.contains(surface) {
                    members.push(*surface);
                }
            }
            members.sort_by_key(|surface| tabs.iter().position(|tab| tab == surface));
            let anchor = tabs.iter().position(|tab| *tab == members[0]).unwrap_or(0);
            place_block(state, pane, &members, anchor);
            groups.groups.insert(
                id.clone(),
                TabGroupRecord {
                    id: id.clone(),
                    pane_id: pane_public_id(state, pane)?,
                    name,
                    color,
                    collapsed: false,
                    saved_id: None,
                },
            );
            for surface in &members {
                groups.members.insert(tab_public_id(state, *surface)?, id.clone());
            }
            Ok(())
        })?;
        let outcome = self.tab_group_outcome(&group_id);
        self.emit_tab_group_members(&outcome.members, transaction);
        Ok(outcome)
    }

    /// Rename, recolor, or collapse a group. A linked saved group follows.
    pub fn update_tab_group(
        &self,
        group: &str,
        name: Option<String>,
        color: Option<String>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<TabGroupOutcome> {
        if let Some(name) = &name {
            validate_tab_group_name(name)?;
        }
        if let Some(color) = &color {
            validate_tab_group_color(color)?;
        }
        self.commit_tab_group_metadata(|_, groups| {
            let record = groups
                .groups
                .get_mut(group)
                .ok_or_else(|| anyhow::anyhow!("unknown tab group {group}"))?;
            if let Some(name) = name {
                record.name = name;
            }
            if let Some(color) = color {
                record.color = color;
            }
            if let Some(collapsed) = collapsed {
                record.collapsed = collapsed;
            }
            Ok(())
        })?;
        self.sync_saved_tab_group(group)?;
        Ok(self.tab_group_outcome(group))
    }

    /// Add tabs to a group, at the end of its run. Tabs in other panes move
    /// into the group's pane in the same commit.
    pub fn add_tabs_to_tab_group(
        self: &Arc<Self>,
        group: &str,
        surfaces: &[SurfaceId],
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        let group_id = group.to_string();
        let added = surfaces.to_vec();
        self.commit_tab_group_change("tab.group.add", None, |mux, state, groups| {
            let presentation = mux.presentation_snapshot();
            let record = groups
                .groups
                .get(&group_id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("unknown tab group {group_id}"))?;
            let pane =
                pane_by_public_id(state, &record.pane_id).context("tab group pane is gone")?;
            for surface in &added {
                anyhow::ensure!(state.pane_of(*surface).is_some(), "unknown surface {surface}");
                anyhow::ensure!(
                    !is_pinned(state, &presentation, *surface),
                    "bad request: pinned tabs cannot be grouped"
                );
            }
            let mut members = group_members(state, groups, &group_id);
            members.retain(|surface| !added.contains(surface));
            // Insertion index among the tabs that are not in the final block.
            let tabs = &state.panes[&pane].tabs;
            let anchor = match members.first() {
                Some(first) => tabs
                    .iter()
                    .take_while(|tab| *tab != first)
                    .filter(|tab| !added.contains(tab))
                    .count(),
                None => tabs.iter().filter(|tab| !added.contains(tab)).count(),
            };
            members.extend(added.iter().copied());
            move_members_into(mux, state, &members, pane, anchor)?;
            for surface in &added {
                groups.members.insert(tab_public_id(state, *surface)?, group_id.clone());
            }
            Ok(())
        })?;
        self.sync_saved_tab_group(group)?;
        let outcome = self.tab_group_outcome(group);
        self.emit_tab_group_members(surfaces, transaction);
        Ok(outcome)
    }

    /// Remove tabs from their groups; each lands just after its old group.
    pub fn remove_tabs_from_tab_group(
        self: &Arc<Self>,
        surfaces: &[SurfaceId],
        transaction: Option<&str>,
    ) -> anyhow::Result<Vec<String>> {
        let removed = surfaces.to_vec();
        let touched =
            self.commit_tab_group_change("tab.group.remove", None, |_, state, groups| {
                let mut touched = Vec::new();
                for surface in &removed {
                    let tab = tab_public_id(state, *surface)?;
                    let Some(group) = groups.members.get(&tab).cloned() else { continue };
                    let members = group_members(state, groups, &group);
                    groups.members.remove(&tab);
                    let last = members.iter().rev().find(|member| *member != surface);
                    if let (Some(pane), Some(last)) = (state.pane_of(*surface), last) {
                        let rest = state.panes[&pane]
                            .tabs
                            .iter()
                            .copied()
                            .filter(|candidate| candidate != surface)
                            .collect::<Vec<_>>();
                        let after = rest
                            .iter()
                            .position(|candidate| candidate == last)
                            .map_or(rest.len(), |index| index + 1);
                        place_block(state, pane, &[*surface], after);
                    }
                    if !touched.contains(&group) {
                        touched.push(group);
                    }
                }
                Ok(touched)
            })?;
        for group in &touched {
            self.sync_saved_tab_group(group)?;
        }
        self.emit_tab_group_members(surfaces, transaction);
        Ok(touched)
    }

    /// Move a whole group: within or across strips, into a new split or
    /// column, or into a new workspace. Members keep their order and stay
    /// grouped; the group is not layout-undoable.
    pub fn move_tab_group(
        self: &Arc<Self>,
        group: &str,
        destination: TabGroupDestination,
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        let group_id = group.to_string();
        let ids = TabDragIds::reserve(self)?;
        let (workspace_group, workspace_index) = match &destination {
            TabGroupDestination::NewWorkspace { group, index } => {
                if let Some(group) = group {
                    anyhow::ensure!(
                        self.presentation_snapshot().group(group).is_some(),
                        "unknown workspace group {group}"
                    );
                }
                (group.clone(), *index)
            }
            _ => (None, None),
        };
        let screen_id = self.next_id();
        let workspace_id = self.next_id();
        let presentation = self.presentation_snapshot();
        self.commit_tab_group_change(
            "tab.group.move",
            workspace_group.clone(),
            |mux, state, groups| {
                let members = group_members(state, groups, &group_id);
                anyhow::ensure!(!members.is_empty(), "unknown tab group {group_id}");
                let target = match destination {
                    TabGroupDestination::Strip { pane, index } => {
                        anyhow::ensure!(state.panes.contains_key(&pane), "unknown pane {pane}");
                        let others = state.panes[&pane]
                            .tabs
                            .iter()
                            .filter(|tab| !members.contains(tab))
                            .count();
                        let pinned = state.panes[&pane]
                            .tabs
                            .iter()
                            .filter(|tab| {
                                !members.contains(tab) && is_pinned(state, &presentation, **tab)
                            })
                            .count();
                        let index = index.unwrap_or(others).clamp(pinned, others);
                        move_members_into(mux, state, &members, pane, index)?;
                        pane
                    }
                    TabGroupDestination::Split { pane, edge, ratio } => {
                        apply_tab_drag(
                            mux,
                            state,
                            members[0],
                            TabDragDestination::Split { pane, edge, ratio },
                            &ids,
                            false,
                        )?;
                        move_members_into(mux, state, &members, ids.pane, 0)?;
                        ids.pane
                    }
                    TabGroupDestination::Column { pane, after_column, width } => {
                        let width = width.unwrap_or(crate::layout::DEFAULT_VIEWPORT_PANE_WIDTH);
                        if !width.is_finite()
                            || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
                        {
                            return Err(ViewportWidthError::OutOfRange { width }.into());
                        }
                        apply_tab_drag(
                            mux,
                            state,
                            members[0],
                            TabDragDestination::Column { pane, after_column, width },
                            &ids,
                            false,
                        )?;
                        move_members_into(mux, state, &members, ids.pane, 0)?;
                        ids.pane
                    }
                    TabGroupDestination::NewWorkspace { .. } => {
                        anyhow::ensure!(
                            state.workspaces.len() < WORKSPACE_REGISTRY_LIMIT,
                            "workspace limit reached"
                        );
                        let position = resource_topology::new_workspace_position(
                            state,
                            &presentation,
                            workspace_group.as_deref(),
                            workspace_index,
                        );
                        state.insert_pane(Pane {
                            id: ids.pane,
                            public_id: ids.pane_public.clone(),
                            name: None,
                            tabs: Vec::new(),
                            active_tab: 0,
                            active_at: mux.next_active_at(),
                            focused_at: 0,
                        });
                        state.push_workspace(Workspace {
                            id: workspace_id,
                            public_id: WorkspacePublicId::random()?,
                            key: Mux::new_workspace_key()?,
                            name: Mux::default_workspace_name(state),
                            screens: vec![Screen {
                                id: screen_id,
                                public_id: ScreenPublicId::random()?,
                                name: None,
                                root: Node::Leaf(ids.pane),
                                active_pane: ids.pane,
                                zoomed_pane: None,
                                zellij_auto_layout: Some(vec![ids.pane]),
                                viewport_splits: Default::default(),
                                viewport_base_width: None,
                                layout_columns: Vec::new(),
                                layout_revision: 0,
                                layout_undo: Default::default(),
                            }],
                            active_screen: 0,
                        });
                        let last = state.workspaces.len() - 1;
                        if position < last {
                            state.move_workspace(last, position);
                        }
                        state.rebuild_resource_indexes();
                        move_members_into(mux, state, &members, ids.pane, 0)?;
                        if let Some(index) = state.workspace_index(workspace_id) {
                            state.active_workspace = index;
                        }
                        ids.pane
                    }
                };
                Mux::rebuild_split_screen_index(state);
                let pane_public = pane_public_id(state, target)?;
                if let Some(record) = groups.groups.get_mut(&group_id) {
                    record.pane_id = pane_public;
                }
                Ok(())
            },
        )?;
        let outcome = self.tab_group_outcome(group);
        self.emit_tab_group_members(&outcome.members, transaction);
        Ok(outcome)
    }

    /// Ungroup: the members stay in place without a group.
    pub fn ungroup_tab_group(&self, group: &str) -> anyhow::Result<Vec<SurfaceId>> {
        let members = self.tab_group_outcome(group).members;
        self.commit_tab_group_metadata(|_, groups| {
            anyhow::ensure!(groups.groups.remove(group).is_some(), "unknown tab group {group}");
            groups.members.retain(|_, member| member != group);
            Ok(())
        })?;
        Ok(members)
    }

    /// Close a group: close every member placement in one commit. Terminal
    /// processes keep running (closing a view never ends a terminal);
    /// browsers close with their only tab. A linked saved group remains.
    pub fn close_tab_group(self: &Arc<Self>, group: &str) -> anyhow::Result<Vec<SurfaceId>> {
        let group_id = group.to_string();
        let mut removed_surfaces = Vec::new();
        let closed =
            self.commit_tab_group_change("tab.group.close", None, |mux, state, groups| {
                let members = group_members(state, groups, &group_id);
                anyhow::ensure!(!members.is_empty(), "unknown tab group {group_id}");
                let panes = members
                    .iter()
                    .filter_map(|surface| state.pane_of(*surface))
                    .collect::<Vec<_>>();
                fence_layout_undo_for_tab_membership(state, &panes);
                for surface in &members {
                    if let (Some(runtime), _) = remove_surface(mux, state, *surface) {
                        removed_surfaces.push(runtime);
                    }
                }
                groups.groups.remove(&group_id);
                groups.members.retain(|_, member| member != &group_id);
                Ok(members)
            })?;
        for runtime in removed_surfaces {
            self.purge_surface_side_tables(runtime.id);
            if runtime.kind() == SurfaceKind::Browser {
                runtime.kill();
            }
        }
        Ok(closed)
    }

    /// Add a new view of a running terminal to `pane` (its last tab).
    fn project_terminal_into_pane(
        self: &Arc<Self>,
        terminal_id: &str,
        pane: PaneId,
    ) -> anyhow::Result<SurfaceId> {
        let public = self
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_resource_id(terminal_id)?
            .context("terminal has no public identity")?;
        let destination =
            self.ordinary_pane_selectors(pane).with_context(|| format!("unknown pane {pane}"))?;
        let selectors = crate::ResourceSelectors {
            terminal: Some(public.as_str().to_string()),
            ..Self::ordinary_resource_selectors()
        };
        let index =
            self.with_state(|state| state.panes.get(&pane).map_or(0, |record| record.tabs.len()));
        self.resource_project_terminal_selected(
            selectors,
            destination,
            index,
            None,
            None,
            &WorkspaceMutation::local("cmux-tui-tab-groups"),
        )?;
        self.with_state(|state| {
            state.panes.get(&pane).and_then(|record| record.tabs.get(index).copied())
        })
        .context("reattached terminal view is missing")
    }

    fn saved_member_descriptor(&self, surface: SurfaceId) -> Option<SavedTabMember> {
        let runtime = self.surface(surface)?;
        match runtime.kind() {
            SurfaceKind::Browser => {
                let frontend = self.frontend_browser(&runtime);
                Some(SavedTabMember::Browser {
                    url: runtime.browser_url().unwrap_or_default(),
                    engine: frontend.as_ref().map(|record| record.engine.clone()),
                    profile_id: frontend.and_then(|record| record.profile_id),
                    title: Some(runtime.title()).filter(|title| !title.is_empty()),
                })
            }
            SurfaceKind::Pty => Some(SavedTabMember::Terminal {
                terminal_id: self
                    .resource_terminal_host_identity(&runtime)
                    .map(|identity| identity.terminal_id),
                cwd: runtime.presented_directory(),
                title: Some(runtime.title()).filter(|title| !title.is_empty()),
            }),
        }
    }

    /// Refresh the saved record linked to a live group.
    fn sync_saved_tab_group(&self, group: &str) -> anyhow::Result<()> {
        let outcome = self.tab_group_outcome(group);
        let Some(record) = outcome.group else { return Ok(()) };
        let Some(saved_id) = record.saved_id.clone() else { return Ok(()) };
        let members = outcome
            .members
            .iter()
            .filter_map(|surface| self.saved_member_descriptor(*surface))
            .collect::<Vec<_>>();
        let saved = SavedTabGroupRecord {
            id: saved_id,
            name: record.name,
            color: record.color,
            members,
            updated_at_ms: now_ms(),
        };
        let mut registry = self.workspace_registry.lock().unwrap();
        registry.put_saved_tab_group(&saved)?;
        self.reload_presentation(&registry)?;
        Ok(())
    }

    /// Save (pin) a live group. Returns the saved record's id.
    pub fn save_tab_group(&self, group: &str) -> anyhow::Result<String> {
        let saved_id = self.commit_tab_group_metadata(|_, groups| {
            let record = groups
                .groups
                .get_mut(group)
                .ok_or_else(|| anyhow::anyhow!("unknown tab group {group}"))?;
            Ok(record.saved_id.get_or_insert_with(new_saved_tab_group_id).clone())
        })?;
        self.sync_saved_tab_group(group)?;
        Ok(saved_id)
    }

    /// Unsave a live group: delete its saved record and keep the group.
    pub fn unsave_tab_group(&self, group: &str) -> anyhow::Result<bool> {
        let saved_id = self
            .presentation_snapshot()
            .tab_groups
            .groups
            .get(group)
            .ok_or_else(|| anyhow::anyhow!("unknown tab group {group}"))?
            .saved_id
            .clone();
        let Some(saved_id) = saved_id else { return Ok(false) };
        self.delete_saved_tab_group(&saved_id)
    }

    /// Delete a saved group. A live group linked to it stays, unlinked.
    pub fn delete_saved_tab_group(&self, saved_id: &str) -> anyhow::Result<bool> {
        let removed = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let removed = registry.delete_saved_tab_group(saved_id)?;
            self.reload_presentation(&registry)?;
            removed
        };
        if removed {
            self.publish_journal_event();
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(removed)
    }

    pub fn saved_tab_groups(&self) -> Vec<SavedTabGroupRecord> {
        self.presentation_snapshot().saved_tab_groups.clone()
    }

    /// Reopen a saved group into `pane`. A live group already linked to the
    /// record is returned unchanged. Otherwise each member is restored: a
    /// terminal still running is reattached (a new view of the same
    /// terminal), other terminals start in their saved directory, and
    /// browsers reopen at their saved URL.
    pub fn reopen_saved_tab_group(
        self: &Arc<Self>,
        saved_id: &str,
        pane: PaneId,
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        let presentation = self.presentation_snapshot();
        let saved = presentation
            .saved_tab_groups
            .iter()
            .find(|record| record.id == saved_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("unknown saved tab group {saved_id}"))?;
        if let Some(live) = presentation
            .tab_groups
            .groups
            .values()
            .find(|group| group.saved_id.as_deref() == Some(saved_id))
        {
            return Ok(self.tab_group_outcome(&live.id));
        }
        anyhow::ensure!(
            self.with_state(|state| state.panes.contains_key(&pane)),
            "unknown pane {pane}"
        );
        let mut surfaces = Vec::new();
        for member in &saved.members {
            let surface = match member {
                SavedTabMember::Terminal { terminal_id, cwd, .. } => {
                    let reattached = terminal_id
                        .as_deref()
                        .and_then(|terminal| self.resolve_terminal(terminal).ok().flatten())
                        .filter(|resolution| {
                            resolution.terminal.lifecycle == TerminalLifecycle::Running
                        })
                        .and_then(|resolution| {
                            self.project_terminal_into_pane(&resolution.terminal.terminal_id, pane)
                                .ok()
                        });
                    match reattached {
                        Some(surface) => surface,
                        None => self.new_tab(Some(pane), cwd.clone(), None)?.id,
                    }
                }
                SavedTabMember::Browser { url, engine, profile_id, title } => match engine {
                    Some(engine) => {
                        self.new_frontend_browser_tab(
                            Some(pane),
                            crate::workspace_registry::FrontendBrowserRecord {
                                engine: engine.clone(),
                                url: url.clone(),
                                title: title.clone(),
                                favicon_url: None,
                                profile_id: profile_id.clone(),
                            },
                            None,
                        )?
                        .id
                    }
                    None => self.new_browser_tab(url.clone(), Some(pane), None)?.id,
                },
            };
            surfaces.push(surface);
        }
        let outcome = self.create_tab_group(
            &surfaces,
            Some(saved.name),
            Some(saved.color),
            None,
            transaction,
        )?;
        let group = outcome
            .group
            .as_ref()
            .map(|group| group.id.clone())
            .context("reopened group missing")?;
        self.commit_tab_group_metadata(|_, groups| {
            if let Some(record) = groups.groups.get_mut(&group) {
                record.saved_id = Some(saved_id.to_string());
            }
            Ok(())
        })?;
        self.sync_saved_tab_group(&group)?;
        Ok(self.tab_group_outcome(&group))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
        mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()))
            .unwrap_or_default()
    }

    fn runs(mux: &Mux, pane: PaneId) -> Vec<(String, Vec<SurfaceId>)> {
        let presentation = mux.presentation_snapshot();
        mux.with_state(|state| {
            pane_tab_groups(state, &presentation, pane)
                .into_iter()
                .map(|run| (run.group.id, run.members))
                .collect()
        })
    }

    #[test]
    fn cmux_next_tab_groups_keep_members_contiguous_through_edits() {
        let mux = Mux::new_for_test("tab-groups", SurfaceOptions::default());
        let t1 = mux.new_workspace(None, None).unwrap().id;
        let pane = mux.with_state(|state| state.pane_of(t1)).unwrap();
        let t2 = mux.new_tab(Some(pane), None, None).unwrap().id;
        let t3 = mux.new_tab(Some(pane), None, None).unwrap().id;
        let t4 = mux.new_tab(Some(pane), None, None).unwrap().id;
        mux.set_tab_pinned(t1, true).unwrap();
        assert!(mux.create_tab_group(&[t1], None, None, None, None).is_err());
        assert!(mux.create_tab_group(&[t2], None, Some("blurple".into()), None, None).is_err());

        let created = mux
            .create_tab_group(
                &[t4, t2],
                Some("Agents".into()),
                Some("green".into()),
                Some("g1".into()),
                Some("tx-1"),
            )
            .unwrap();
        assert_eq!(created.members, vec![t2, t4]);
        assert_eq!(tabs(&mux, pane), vec![t1, t2, t4, t3]);
        assert_eq!(runs(&mux, pane), vec![("g1".to_string(), vec![t2, t4])]);
        let durable = mux.workspace_registry.lock().unwrap().presentation_snapshot().unwrap();
        assert_eq!(durable.tab_groups.groups["g1"].color, "green");
        assert_eq!(durable.tab_groups.members.len(), 2);

        mux.update_tab_group("g1", Some("".into()), Some("cyan".into()), Some(true)).unwrap();
        let group = mux.presentation_snapshot().tab_groups.groups["g1"].clone();
        assert_eq!(
            (group.name.as_str(), group.color.as_str(), group.collapsed),
            ("", "cyan", true)
        );

        mux.add_tabs_to_tab_group("g1", &[t3], None).unwrap();
        assert_eq!(runs(&mux, pane), vec![("g1".to_string(), vec![t2, t4, t3])]);
        mux.remove_tabs_from_tab_group(&[t2], None).unwrap();
        assert_eq!(tabs(&mux, pane), vec![t1, t4, t3, t2]);
        assert_eq!(runs(&mux, pane), vec![("g1".to_string(), vec![t4, t3])]);

        // Moving the group within its strip cannot pass the pinned tab.
        mux.move_tab_group("g1", TabGroupDestination::Strip { pane, index: Some(0) }, None)
            .unwrap();
        assert_eq!(tabs(&mux, pane), vec![t1, t4, t3, t2]);
        mux.move_tab_group("g1", TabGroupDestination::Strip { pane, index: None }, None).unwrap();
        assert_eq!(tabs(&mux, pane), vec![t1, t2, t4, t3]);

        let decorations = mux.tree_decorations();
        let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
        let pane_json = &tree["workspaces"][0]["screens"][0]["panes"][0];
        assert_eq!(pane_json["tab_groups"][0]["id"], "g1");
        assert_eq!(pane_json["tab_groups"][0]["start"], 2);
        assert_eq!(pane_json["tab_groups"][0]["count"], 2);
        assert_eq!(pane_json["tabs"][2]["group"], "g1");
        assert!(pane_json["tabs"][1]["group"].is_null());

        // The whole group moves into a new split and stays grouped.
        let moved = mux
            .move_tab_group(
                "g1",
                TabGroupDestination::Split { pane, edge: TabDropEdge::Right, ratio: None },
                None,
            )
            .unwrap();
        let new_pane = moved.pane.unwrap();
        assert_ne!(new_pane, pane);
        assert_eq!(tabs(&mux, new_pane), vec![t4, t3]);
        assert_eq!(tabs(&mux, pane), vec![t1, t2]);
        assert_eq!(runs(&mux, new_pane), vec![("g1".to_string(), vec![t4, t3])]);

        // Ungroup leaves the tabs in place.
        assert_eq!(mux.ungroup_tab_group("g1").unwrap(), vec![t4, t3]);
        assert!(runs(&mux, new_pane).is_empty());
        assert_eq!(tabs(&mux, new_pane), vec![t4, t3]);
    }

    #[test]
    fn cmux_next_saved_tab_groups_outlive_close_and_reopen() {
        let mux = Mux::new_for_test("saved-tab-groups", SurfaceOptions::default());
        let t1 = mux.new_workspace(None, None).unwrap().id;
        let pane = mux.with_state(|state| state.pane_of(t1)).unwrap();
        let t2 = mux.new_tab(Some(pane), None, None).unwrap().id;
        let t3 = mux.new_tab(Some(pane), None, None).unwrap().id;
        mux.create_tab_group(
            &[t2, t3],
            Some("Build".into()),
            Some("orange".into()),
            Some("g".into()),
            None,
        )
        .unwrap();
        let saved = mux.save_tab_group("g").unwrap();
        let record = mux.saved_tab_groups().into_iter().find(|record| record.id == saved).unwrap();
        assert_eq!((record.name.as_str(), record.members.len()), ("Build", 2));
        // Rename syncs to the saved record.
        mux.update_tab_group("g", Some("Release".into()), None, None).unwrap();
        assert_eq!(mux.saved_tab_groups()[0].name, "Release");

        let closed = mux.close_tab_group("g").unwrap();
        assert_eq!(closed, vec![t2, t3]);
        assert_eq!(tabs(&mux, pane), vec![t1]);
        assert!(mux.presentation_snapshot().tab_groups.groups.is_empty());
        assert_eq!(mux.saved_tab_groups().len(), 1);

        let reopened = mux.reopen_saved_tab_group(&saved, pane, Some("tx-reopen")).unwrap();
        let group = reopened.group.clone().unwrap();
        assert_eq!(group.name, "Release");
        assert_eq!(group.color, "orange");
        assert_eq!(group.saved_id.as_deref(), Some(saved.as_str()));
        assert_eq!(reopened.members.len(), 2);
        // Reopening again returns the live group.
        let again = mux.reopen_saved_tab_group(&saved, pane, None).unwrap();
        assert_eq!(again.group.unwrap().id, group.id);

        // Moving the group into a new workspace carries it along.
        let moved = mux
            .move_tab_group(
                &group.id,
                TabGroupDestination::NewWorkspace { group: None, index: None },
                None,
            )
            .unwrap();
        let workspace = moved.workspace.unwrap();
        assert!(mux.with_state(|state| state.workspace_index(workspace).is_some()));
        assert_eq!(runs(&mux, moved.pane.unwrap()).len(), 1);

        assert!(mux.unsave_tab_group(&group.id).unwrap());
        assert!(mux.saved_tab_groups().is_empty());
        assert!(!mux.delete_saved_tab_group(&saved).unwrap());
    }
}
