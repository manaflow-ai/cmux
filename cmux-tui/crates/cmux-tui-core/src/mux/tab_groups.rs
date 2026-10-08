//! Tab groups (named, colored, collapsible tab runs) and saved (pinned) groups.
//!
//! A tab group lives in one pane's tab strip: an id, a name (may be empty),
//! one of nine named colors, and a shared collapsed flag. Each tab
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
use super::tab_strip::{StripRequest, StripResult};
use super::*;
use crate::workspace_registry::{
    DEFAULT_PROFILE_ID, PresentationSnapshot, SavedTabGroupRecord, SavedTabMember, TabGroupRecord,
    TabGroupState, new_saved_tab_group_id, new_tab_group_id, validate_tab_group_color,
    validate_tab_group_name, validate_workspace_group_id,
};
mod public_ids;
pub(crate) use public_ids::{is_pinned, pane_by_public_id, pane_public_id, tab_public_id};

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
    /// Into a new strip column on `pane`'s screen.
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

/// The current members of `group` in strip order.
pub(crate) fn group_members(state: &State, groups: &TabGroupState, group: &str) -> Vec<SurfaceId> {
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

/// Remove `group` from `groups` and return its member placements, for a
/// batch close that commits the group rows with the closed members.
pub(crate) fn take_tab_group(
    state: &State,
    groups: &mut TabGroupState,
    group: &str,
) -> anyhow::Result<Vec<SurfaceId>> {
    let members = group_members(state, groups, group);
    anyhow::ensure!(!members.is_empty(), "unknown tab group {group}");
    groups.groups.remove(group);
    groups.members.retain(|_, member| member != group);
    Ok(members)
}

/// Reorder `pane` so `block` sits contiguously starting at insertion index
/// `index` among the pane's other tabs. The active tab stays active.
pub(crate) fn place_block(state: &mut State, pane: PaneId, block: &[SurfaceId], index: usize) {
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
pub(crate) fn prune_tab_groups(state: &State, groups: &mut TabGroupState) {
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

/// Move `members` (in order) into `pane` at insertion index `index`, across
/// panes when needed. Returns the members that changed workspace.
pub(crate) fn move_members_into(
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
    /// Commit a raw tab group command (a local mutation that never replays).
    fn commit_tab_group_change<R>(
        self: &Arc<Self>,
        operation: &str,
        workspace_group: Option<String>,
        mutate: impl FnOnce(&Arc<Mux>, &mut State, &mut TabGroupState) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let (output, _) = self.commit_tab_strip_change(
            StripRequest::local(operation),
            workspace_group,
            |mux, state, edit| mutate(mux, state, &mut edit.groups),
        )?;
        output.context("tab group change committed no result")
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
        let id = id.unwrap_or_else(new_tab_group_id);
        let requested = surfaces.to_vec();
        self.tab_group_create(
            StripRequest::local("tab.group.create"),
            move |_| Ok(requested),
            name,
            color,
            id.clone(),
        )?;
        let outcome = self.tab_group_outcome(&id);
        self.emit_tab_group_members(&outcome.members, transaction);
        Ok(outcome)
    }

    /// The shared body of raw `create-tab-group` and v2 `tab_group.create`.
    /// `tabs` resolves the members against the locked state.
    pub(crate) fn tab_group_create(
        self: &Arc<Self>,
        request: StripRequest,
        tabs: impl FnOnce(&State) -> anyhow::Result<Vec<SurfaceId>>,
        name: Option<String>,
        color: Option<String>,
        id: String,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let name = name.unwrap_or_default();
        let color = color.unwrap_or_else(|| "grey".to_string());
        validate_tab_group_name(&name)?;
        validate_tab_group_color(&color)?;
        validate_workspace_group_id(&id)?;
        let (_, commit) =
            self.commit_tab_strip_change(request, None, move |mux, state, edit| {
                anyhow::ensure!(
                    !edit.groups.groups.contains_key(&id),
                    "tab group {id} already exists"
                );
                let requested = tabs(state)?;
                anyhow::ensure!(
                    !requested.is_empty(),
                    "bad request: a tab group needs at least one tab"
                );
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
                edit.groups.groups.insert(
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
                    edit.groups.members.insert(tab_public_id(state, *surface)?, id.clone());
                }
                edit.result = StripResult::Group(id);
                Ok(())
            })?;
        Ok(commit)
    }

    /// Rename, recolor, or collapse a group. A linked saved group follows.
    pub fn update_tab_group(
        self: &Arc<Self>,
        group: &str,
        name: Option<String>,
        color: Option<String>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<TabGroupOutcome> {
        self.tab_group_update(
            StripRequest::local("tab.group.update"),
            group,
            name,
            color,
            collapsed,
        )?;
        Ok(self.tab_group_outcome(group))
    }

    pub(crate) fn tab_group_update(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
        name: Option<String>,
        color: Option<String>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        if let Some(name) = &name {
            validate_tab_group_name(name)?;
        }
        if let Some(color) = &color {
            validate_tab_group_color(color)?;
        }
        let group_id = group.to_string();
        let (_, commit) =
            self.commit_tab_strip_change(request, None, move |mux, state, edit| {
                let record =
                    edit.groups.groups.get_mut(&group_id).ok_or_else(|| {
                        crate::state::commit::state_not_found("tab_group", &group_id)
                    })?;
                if let Some(name) = name {
                    record.name = name;
                }
                if let Some(color) = color {
                    record.color = color;
                }
                if let Some(collapsed) = collapsed {
                    record.collapsed = collapsed;
                }
                edit.saved = mux.saved_record_for(state, &edit.groups, &group_id);
                edit.result = StripResult::Group(group_id);
                Ok(())
            })?;
        Ok(commit)
    }

    /// Add tabs to a group, at the end of its run. Tabs in other panes move
    /// into the group's pane in the same commit.
    pub fn add_tabs_to_tab_group(
        self: &Arc<Self>,
        group: &str,
        surfaces: &[SurfaceId],
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        let added = surfaces.to_vec();
        self.tab_group_add(StripRequest::local("tab.group.add"), group, move |_| Ok(added), None)?;
        let outcome = self.tab_group_outcome(group);
        self.emit_tab_group_members(surfaces, transaction);
        Ok(outcome)
    }

    /// `index` is the position inside the group (default: the end).
    pub(crate) fn tab_group_add(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
        tabs: impl FnOnce(&State) -> anyhow::Result<Vec<SurfaceId>>,
        index: Option<usize>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let group_id = group.to_string();
        let (_, commit) =
            self.commit_tab_strip_change(request, None, move |mux, state, edit| {
                let presentation = mux.presentation_snapshot();
                let record =
                    edit.groups.groups.get(&group_id).cloned().ok_or_else(|| {
                        crate::state::commit::state_not_found("tab_group", &group_id)
                    })?;
                // First occurrence only: a repeated surface would be spliced
                // into the pane's tab order twice and committed as the
                // durable order.
                let mut added = Vec::new();
                for surface in tabs(state)? {
                    if !added.contains(&surface) {
                        added.push(surface);
                    }
                }
                let pane =
                    pane_by_public_id(state, &record.pane_id).context("tab group pane is gone")?;
                for surface in &added {
                    anyhow::ensure!(state.pane_of(*surface).is_some(), "unknown surface {surface}");
                    anyhow::ensure!(
                        !is_pinned(state, &presentation, *surface),
                        "bad request: pinned tabs cannot be grouped"
                    );
                }
                let mut members = group_members(state, &edit.groups, &group_id);
                members.retain(|surface| !added.contains(surface));
                // Insertion index among the tabs that are not in the final block.
                let strip = &state.panes[&pane].tabs;
                let anchor = match members.first() {
                    Some(first) => strip
                        .iter()
                        .take_while(|tab| *tab != first)
                        .filter(|tab| !added.contains(tab))
                        .count(),
                    None => strip.iter().filter(|tab| !added.contains(tab)).count(),
                };
                let at = index.unwrap_or(members.len()).min(members.len());
                members.splice(at..at, added.iter().copied());
                move_members_into(mux, state, &members, pane, anchor)?;
                for surface in &added {
                    edit.groups.members.insert(tab_public_id(state, *surface)?, group_id.clone());
                }
                edit.saved = mux.saved_record_for(state, &edit.groups, &group_id);
                edit.result = StripResult::Group(group_id);
                Ok(())
            })?;
        Ok(commit)
    }

    /// Remove tabs from their groups; each lands just after its old group.
    pub fn remove_tabs_from_tab_group(
        self: &Arc<Self>,
        surfaces: &[SurfaceId],
        transaction: Option<&str>,
    ) -> anyhow::Result<Vec<String>> {
        let removed = surfaces.to_vec();
        let (touched, _) =
            self.tab_group_remove(StripRequest::local("tab.group.remove"), move |_| Ok(removed))?;
        self.emit_tab_group_members(surfaces, transaction);
        Ok(touched.unwrap_or_default())
    }

    pub(crate) fn tab_group_remove(
        self: &Arc<Self>,
        request: StripRequest,
        tabs: impl FnOnce(&State) -> anyhow::Result<Vec<SurfaceId>>,
    ) -> anyhow::Result<(Option<Vec<String>>, ResourcePatchCommit)> {
        self.commit_tab_strip_change(request, None, move |mux, state, edit| {
            let removed = tabs(state)?;
            let mut touched = Vec::new();
            for surface in &removed {
                let tab = tab_public_id(state, *surface)?;
                let Some(group) = edit.groups.members.get(&tab).cloned() else { continue };
                let members = group_members(state, &edit.groups, &group);
                edit.groups.members.remove(&tab);
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
            for group in &touched {
                if let Some(saved) = mux.saved_record_for(state, &edit.groups, group) {
                    edit.saved = Some(saved);
                }
            }
            edit.result = StripResult::Groups(touched.clone());
            Ok(touched)
        })
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
                            TabDragDestination::Column { pane, after_column, width, dock: None },
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
                                creation_order_auto_layout: Some(vec![ids.pane]),
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
    pub fn ungroup_tab_group(self: &Arc<Self>, group: &str) -> anyhow::Result<Vec<SurfaceId>> {
        let members = self.tab_group_outcome(group).members;
        self.tab_group_ungroup(StripRequest::local("tab.group.ungroup"), group)?;
        Ok(members)
    }

    pub(crate) fn tab_group_ungroup(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let group_id = group.to_string();
        let (_, commit) = self.commit_tab_strip_change(request, None, move |_, state, edit| {
            let members = group_members(state, &edit.groups, &group_id);
            anyhow::ensure!(
                edit.groups.groups.remove(&group_id).is_some(),
                crate::state::commit::state_not_found("tab_group", &group_id)
            );
            edit.groups.members.retain(|_, member| member != &group_id);
            let tabs = members
                .iter()
                .map(|surface| tab_public_id(state, *surface))
                .collect::<anyhow::Result<Vec<_>>>()?;
            edit.result = StripResult::Release { group: group_id, tabs };
            Ok(())
        })?;
        Ok(commit)
    }

    /// Close a group: close every member placement in one commit. Terminal
    /// processes keep running (closing a view never ends a terminal);
    /// browsers close with their only tab. A linked saved group remains.
    pub fn close_tab_group(self: &Arc<Self>, group: &str) -> anyhow::Result<Vec<SurfaceId>> {
        let (closed, _) = self.tab_group_close(StripRequest::local("tab.group.close"), group)?;
        closed.context("tab group close committed no result")
    }

    pub(crate) fn tab_group_close(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
    ) -> anyhow::Result<(Option<Vec<SurfaceId>>, ResourcePatchCommit)> {
        let group_id = group.to_string();
        let mut removed_surfaces = Vec::new();
        let (closed, commit) =
            self.commit_tab_strip_change(request, None, |mux, state, edit| {
                let members = group_members(state, &edit.groups, &group_id);
                if members.is_empty() {
                    return Err(crate::state::commit::state_not_found("tab_group", &group_id));
                }
                let tabs = members
                    .iter()
                    .map(|surface| tab_public_id(state, *surface))
                    .collect::<anyhow::Result<Vec<_>>>()?;
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
                edit.groups.groups.remove(&group_id);
                edit.groups.members.retain(|_, member| member != &group_id);
                edit.result = StripResult::Release { group: group_id.clone(), tabs };
                Ok(members)
            })?;
        for runtime in removed_surfaces {
            self.purge_surface_side_tables(runtime.id);
            if runtime.kind() == SurfaceKind::Browser {
                runtime.kill();
            }
        }
        Ok((closed, commit))
    }

    /// v2 `tab_group.move` into a strip: `pane` (default: the group's own
    /// pane) at insertion index `index` among that pane's other tabs,
    /// clamped behind its pinned tabs.
    pub(crate) fn tab_group_move_to_strip(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
        pane: Option<String>,
        index: Option<usize>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let group_id = group.to_string();
        let (_, commit) =
            self.commit_tab_strip_change(request, None, move |mux, state, edit| {
                let presentation = mux.presentation_snapshot();
                let members = group_members(state, &edit.groups, &group_id);
                if members.is_empty() {
                    return Err(crate::state::commit::state_not_found("tab_group", &group_id));
                }
                let target = match &pane {
                    Some(pane) => pane_by_public_id(state, pane).ok_or_else(|| {
                        anyhow::Error::new(ResourceError::not_found("pane", pane))
                    })?,
                    None => state.pane_of(members[0]).context("tab group pane is gone")?,
                };
                let others =
                    state.panes[&target].tabs.iter().filter(|tab| !members.contains(tab)).count();
                let pinned = state.panes[&target]
                    .tabs
                    .iter()
                    .filter(|tab| !members.contains(tab) && is_pinned(state, &presentation, **tab))
                    .count();
                let index = index.unwrap_or(others).clamp(pinned, others);
                move_members_into(mux, state, &members, target, index)?;
                Mux::rebuild_split_screen_index(state);
                let pane_public = pane_public_id(state, target)?;
                if let Some(record) = edit.groups.groups.get_mut(&group_id) {
                    record.pane_id = pane_public;
                }
                edit.result = StripResult::Group(group_id);
                Ok(())
            })?;
        Ok(commit)
    }

    /// Add a new view of a running terminal to `pane` (its last tab).
    pub(crate) fn project_terminal_into_pane(
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
            &WorkspaceMutation::daemon_local("cmux-tui-tab-groups"),
        )?;
        self.with_state(|state| {
            state.panes.get(&pane).and_then(|record| record.tabs.get(index).copied())
        })
        .context("reattached terminal view is missing")
    }

    fn saved_member_descriptor(&self, state: &State, surface: SurfaceId) -> Option<SavedTabMember> {
        let runtime = state.surfaces.get(&surface)?;
        match runtime.kind() {
            SurfaceKind::Browser => {
                let frontend = self.frontend_browser(runtime);
                Some(SavedTabMember::Browser {
                    url: runtime.browser_url().unwrap_or_default(),
                    engine: frontend.as_ref().map(|record| record.engine.clone()),
                    profile_id: frontend.and_then(|record| record.profile_id),
                    title: Some(runtime.title()).filter(|title| !title.is_empty()),
                })
            }
            SurfaceKind::Pty => Some(SavedTabMember::Terminal {
                terminal_id: self
                    .resource_terminal_host_identity(runtime)
                    .map(|identity| identity.terminal_id),
                cwd: runtime.presented_directory(),
                title: Some(runtime.title()).filter(|title| !title.is_empty()),
            }),
        }
    }

    /// The refreshed saved record of a live group linked to one, built from
    /// `state` (the projected state of the change being committed).
    pub(crate) fn saved_record_for(
        &self,
        state: &State,
        groups: &TabGroupState,
        group: &str,
    ) -> Option<SavedTabGroupRecord> {
        let record = groups.groups.get(group)?;
        let saved_id = record.saved_id.clone()?;
        let members = group_members(state, groups, group)
            .iter()
            .filter_map(|surface| self.saved_member_descriptor(state, *surface))
            .collect::<Vec<_>>();
        let room = self
            .presentation_snapshot()
            .saved_tab_groups
            .iter()
            .find(|saved| saved.id == saved_id)
            .map_or_else(|| DEFAULT_PROFILE_ID.to_string(), |saved| saved.room.clone());
        Some(SavedTabGroupRecord {
            id: saved_id,
            room,
            name: record.name.clone(),
            color: record.color.clone(),
            members,
            updated_at_ms: now_ms(),
        })
    }

    /// Save (pin) a live group. Returns the saved record's id.
    pub fn save_tab_group(self: &Arc<Self>, group: &str) -> anyhow::Result<String> {
        let commit = self.tab_group_save(StripRequest::local("tab.group.save"), group, None)?;
        commit.result["id"].as_str().map(str::to_string).context("saved group has no id")
    }

    /// Save a live group into `room` (default: its existing room, else
    /// `default`), or refresh the record it already links to.
    pub(crate) fn tab_group_save(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
        room: Option<String>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        if let Some(room) = &room {
            validate_workspace_group_id(room)?;
        }
        let group_id = group.to_string();
        let (_, commit) =
            self.commit_tab_strip_change(request, None, move |mux, state, edit| {
                let record =
                    edit.groups.groups.get_mut(&group_id).ok_or_else(|| {
                        crate::state::commit::state_not_found("tab_group", &group_id)
                    })?;
                let saved_id = record.saved_id.get_or_insert_with(new_saved_tab_group_id).clone();
                let mut saved = mux
                    .saved_record_for(state, &edit.groups, &group_id)
                    .context("saved group record is missing")?;
                if let Some(room) = room {
                    saved.room = room;
                }
                edit.saved = Some(saved);
                edit.result = StripResult::Saved(saved_id);
                Ok(())
            })?;
        Ok(commit)
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
        let commit = self.saved_tab_group_delete(
            &WorkspaceMutation::daemon_local("cmux-tui-tab-groups"),
            None,
            saved_id,
            true,
        )?;
        Ok(commit.result["deleted"].as_bool().unwrap_or(false))
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
            .ok_or_else(|| crate::state::commit::state_not_found("saved_tab_group", saved_id))?;
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
                                // The app that shows the reopened tab claims it.
                                owner: None,
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
        let link = saved_id.to_string();
        let room = saved.room;
        let linked = group.clone();
        self.commit_tab_strip_change(
            StripRequest::local("tab.group.save"),
            None,
            move |mux, state, edit| {
                let group = linked;
                if let Some(record) = edit.groups.groups.get_mut(&group) {
                    record.saved_id = Some(link.clone());
                }
                if let Some(mut record) = mux.saved_record_for(state, &edit.groups, &group) {
                    record.room = room;
                    edit.saved = Some(record);
                }
                Ok(())
            },
        )?;
        Ok(self.tab_group_outcome(&group))
    }
}

#[cfg(test)]
mod tests;
