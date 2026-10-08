//! Screen metadata (color, icon, pin), screen order, and screen
//! groups (`screen-metadata-v1`, `screen-groups-v1`).
//!
//! A screen group lives in one workspace: an id, a name (may be empty), one
//! of nine named colors, and a shared collapsed flag. Each screen belongs
//! to at most one group and members are contiguous in the workspace's screen
//! order, after the pinned screens. Every command keeps that invariant by
//! normalizing the order (pinned first, then each group gathered at its
//! first member) before it commits.
//!
//! Commands that change screen order or move screens between workspaces run
//! on a clone of the live state, project the full tree, and commit the patch
//! and the screen rows in one transaction. Color and icon changes write the
//! screen rows alone and emit `screen-changed`.
//!
//! A saved screen group is a session-wide record (name, color, members'
//! names, colors, icons and directories) that outlives its screens.

use super::tab_strip::StripRequest;
use super::*;
use crate::state::screen_state_store::ScreenMetaUpdate;
use crate::state::screens::ScreenResult;
use crate::state::store::StateCommit;
use crate::workspace_registry::{
    SavedScreenGroupRecord, SavedScreenMember, ScreenGroupRecord, ScreenPresentationState,
    new_saved_screen_group_id, new_screen_group_id, validate_tab_group_color,
    validate_tab_group_name,
};
mod screen_order;
pub(crate) use screen_order::normalize_screen_order;

/// One contiguous screen group run in a workspace, as frontends see it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceScreenGroup {
    pub group: ScreenGroupRecord,
    /// Index of the first member in the workspace's screen list.
    pub start: usize,
    pub members: Vec<ScreenId>,
}

/// Result of a screen group command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenGroupOutcome {
    pub group: Option<ScreenGroupRecord>,
    pub workspace: Option<WorkspaceId>,
    pub key: Option<String>,
    pub members: Vec<ScreenId>,
}

/// Result of a screen move.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenMoveOutcome {
    pub screen: ScreenId,
    pub workspace: WorkspaceId,
    pub key: String,
    pub index: usize,
}

/// Where a screen or a whole screen group lands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenDestination {
    /// Insertion index among the other screens of `workspace` (default: the
    /// screen's own workspace; default index: the end).
    Workspace { workspace: Option<WorkspaceId>, index: Option<usize> },
    /// A new workspace created in the same commit.
    NewWorkspace,
}

/// What a new screen starts with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScreenSpec {
    pub name: Option<String>,
    pub color: Option<String>,
    pub icon: Option<String>,
    pub pinned: Option<bool>,
    pub index: Option<usize>,
    pub group: Option<String>,
}

impl ScreenSpec {
    pub fn has_presentation(&self) -> bool {
        self.color.is_some()
            || self.icon.is_some()
            || self.pinned.is_some()
            || self.index.is_some()
            || self.group.is_some()
    }
}

/// Contiguous screen group runs of one workspace. A group's run starts at its
/// first member; a member after a gap is reported ungrouped.
pub(crate) fn workspace_screen_groups(
    workspace: &Workspace,
    screens: &ScreenPresentationState,
) -> Vec<WorkspaceScreenGroup> {
    let mut runs: Vec<WorkspaceScreenGroup> = Vec::new();
    let mut open: Option<usize> = None;
    for (index, screen) in workspace.screens.iter().enumerate() {
        let group = screens
            .members
            .get(screen.public_id.as_str())
            .and_then(|group| screens.groups.get(group))
            .filter(|group| group.workspace_key == workspace.key);
        match group {
            Some(group) if open.is_some_and(|run| runs[run].group.id == group.id) => {
                runs[open.expect("checked open run")].members.push(screen.id);
            }
            Some(group) if !runs.iter().any(|run| run.group.id == group.id) => {
                runs.push(WorkspaceScreenGroup {
                    group: group.clone(),
                    start: index,
                    members: vec![screen.id],
                });
                open = Some(runs.len() - 1);
            }
            _ => open = None,
        }
    }
    runs
}

pub(super) fn locate_screen(state: &State, screen: ScreenId) -> Option<(usize, usize)> {
    state.workspaces.iter().enumerate().find_map(|(wi, workspace)| {
        workspace.screens.iter().position(|candidate| candidate.id == screen).map(|si| (wi, si))
    })
}

pub(crate) fn screen_public_id(state: &State, screen: ScreenId) -> anyhow::Result<String> {
    let (wi, si) =
        locate_screen(state, screen).with_context(|| format!("unknown screen {screen}"))?;
    Ok(state.workspaces[wi].screens[si].public_id.as_str().to_string())
}

/// Member screens of `group` in order, wherever they are.
fn group_members(state: &State, screens: &ScreenPresentationState, group: &str) -> Vec<ScreenId> {
    let Some(record) = screens.groups.get(group) else { return Vec::new() };
    state
        .workspaces
        .iter()
        .filter(|workspace| workspace.key == record.workspace_key)
        .flat_map(|workspace| workspace.screens.iter())
        .filter(|screen| screens.members.get(screen.public_id.as_str()).is_some_and(|g| g == group))
        .map(|screen| screen.id)
        .collect()
}

/// Drop rows of screens that are gone, memberships of pinned screens or of
/// screens outside their group's workspace, and groups left empty.
pub(crate) fn prune_screen_state(state: &State, screens: &mut ScreenPresentationState) {
    let live = state
        .workspaces
        .iter()
        .flat_map(|workspace| {
            workspace
                .screens
                .iter()
                .map(move |screen| (screen.public_id.as_str().to_string(), workspace.key.clone()))
        })
        .collect::<HashMap<String, String>>();
    screens.screens.retain(|screen, record| live.contains_key(screen) && !record.is_empty());
    let pinned = screens
        .screens
        .iter()
        .filter(|(_, r)| r.pinned)
        .map(|(s, _)| s.clone())
        .collect::<HashSet<_>>();
    let groups = screens.groups.clone();
    screens.members.retain(|screen, group| {
        !pinned.contains(screen)
            && groups
                .get(group)
                .is_some_and(|record| live.get(screen) == Some(&record.workspace_key))
    });
    let used = screens.members.values().cloned().collect::<HashSet<_>>();
    screens.groups.retain(|id, _| used.contains(id));
}

/// Move `block` (screens of workspace `from`) to workspace `to` at insertion
/// index `index` among its other screens. The source keeps at least one
/// screen.
fn place_screens(
    state: &mut State,
    block: &[ScreenId],
    from: usize,
    to: usize,
    index: Option<usize>,
) -> anyhow::Result<()> {
    let active_from =
        state.workspaces[from].screens.get(state.workspaces[from].active_screen).map(|s| s.id);
    let mut moving = Vec::with_capacity(block.len());
    for id in block {
        let position = state.workspaces[from]
            .screens
            .iter()
            .position(|screen| screen.id == *id)
            .with_context(|| format!("screen {id} left its workspace"))?;
        moving.push(state.workspaces[from].screens.remove(position));
    }
    if from != to {
        anyhow::ensure!(
            !state.workspaces[from].screens.is_empty(),
            "bad request: a workspace's last screen cannot be moved out of it"
        );
    }
    let target = &mut state.workspaces[to];
    let active_to = target.screens.get(target.active_screen).map(|s| s.id);
    let index = index.unwrap_or(target.screens.len()).min(target.screens.len());
    target.screens.splice(index..index, moving);
    let keep = if from == to { active_from } else { active_to };
    target.active_screen = keep
        .and_then(|id| target.screens.iter().position(|screen| screen.id == id))
        .unwrap_or(index);
    if from != to {
        let source = &mut state.workspaces[from];
        let last = source.screens.len().saturating_sub(1);
        source.active_screen = active_from
            .and_then(|id| source.screens.iter().position(|screen| screen.id == id))
            .unwrap_or(0)
            .min(last);
    }
    Ok(())
}

impl Mux {
    /// A raw screen command that may reorder screens or move them between
    /// workspaces: one local commit through the shared screen path.
    fn commit_screen_change<R>(
        self: &Arc<Self>,
        operation: &str,
        mutate: impl FnOnce(&Arc<Mux>, &mut State, &mut ScreenPresentationState) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        self.commit_screen_request(StripRequest::local_screens(operation), |mux, state, edit| {
            mutate(mux, state, &mut edit.screens)
        })?
        .0
        .context("screen change committed no result")
    }

    /// A raw screen command that leaves screen order alone.
    fn commit_screen_metadata<R>(
        &self,
        mutate: impl FnOnce(&State, &mut ScreenPresentationState) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        self.commit_screen_rows(
            StripRequest::local_screens("screen.presentation"),
            |state, edit| mutate(state, &mut edit.screens),
        )?
        .0
        .context("screen change committed no result")
    }

    /// The group's record, workspace, and members (for command results).
    pub fn screen_group_outcome_public(&self, group: &str) -> ScreenGroupOutcome {
        self.screen_group_outcome(group)
    }

    fn screen_group_outcome(&self, group: &str) -> ScreenGroupOutcome {
        let presentation = self.presentation_snapshot();
        self.with_state(|state| {
            let record = presentation.screens.groups.get(group).cloned();
            let members = group_members(state, &presentation.screens, group);
            let workspace = record
                .as_ref()
                .and_then(|record| state.workspaces.iter().find(|w| w.key == record.workspace_key));
            ScreenGroupOutcome {
                workspace: workspace.map(|workspace| workspace.id),
                key: workspace.map(|workspace| workspace.key.clone()),
                group: record,
                members,
            }
        })
    }

    /// Set or clear a screen's color and icon. `None` leaves a field,
    /// `Some(None)` clears it. Returns whether anything changed.
    pub fn set_screen_metadata(
        self: &Arc<Self>,
        screen: ScreenId,
        color: Option<Option<String>>,
        icon: Option<Option<String>>,
    ) -> anyhow::Result<bool> {
        let before = self.screen_presentation_record(screen);
        self.update_screen_presentation(
            StripRequest::local_screens("screen.metadata"),
            screen,
            ScreenMetaUpdate { pinned: None, color, icon },
        )?;
        Ok(self.screen_presentation_record(screen) != before)
    }

    /// Pin or unpin a screen. Pinned screens sort first and leave their
    /// group. Returns whether the flag changed and the screen's new index.
    pub fn set_screen_pinned(
        self: &Arc<Self>,
        screen: ScreenId,
        pinned: bool,
    ) -> anyhow::Result<(bool, usize)> {
        let before = self.screen_presentation_record(screen).is_some_and(|record| record.pinned);
        self.update_screen_presentation(
            StripRequest::local_screens("screen.pin"),
            screen,
            ScreenMetaUpdate { pinned: Some(pinned), color: None, icon: None },
        )?;
        let index =
            self.with_state(|state| locate_screen(state, screen).map(|(_, si)| si)).unwrap_or(0);
        Ok((before != pinned, index))
    }

    fn screen_presentation_record(
        &self,
        screen: ScreenId,
    ) -> Option<crate::workspace_registry::ScreenPresentationRecord> {
        let presentation = self.presentation_snapshot();
        self.with_state(|state| {
            let public = screen_public_id(state, screen).ok()?;
            presentation.screens.screen(&public).cloned()
        })
    }

    /// Move one screen within its workspace, into another workspace, or into
    /// a new one. The screen keeps its panes, tabs, and terminals; it leaves
    /// its group when it changes workspace.
    pub fn move_screen(
        self: &Arc<Self>,
        screen: ScreenId,
        destination: ScreenDestination,
    ) -> anyhow::Result<ScreenMoveOutcome> {
        self.move_screen_block(&[screen], destination, "screen.move")?;
        self.with_state(|state| {
            let (wi, si) =
                locate_screen(state, screen).with_context(|| format!("unknown screen {screen}"))?;
            Ok(ScreenMoveOutcome {
                screen,
                workspace: state.workspaces[wi].id,
                key: state.workspaces[wi].key.clone(),
                index: si,
            })
        })
    }

    fn move_screen_block(
        self: &Arc<Self>,
        block: &[ScreenId],
        destination: ScreenDestination,
        operation: &str,
    ) -> anyhow::Result<()> {
        self.move_screen_block_request(
            StripRequest::local_screens(operation),
            block,
            destination,
            false,
        )
        .map(|_| ())
    }

    /// Move a block of screens; with `screen_result`, the v2 result is the
    /// first screen's snapshot.
    pub(crate) fn move_screen_block_request(
        self: &Arc<Self>,
        request: StripRequest,
        block: &[ScreenId],
        destination: ScreenDestination,
        screen_result: bool,
    ) -> anyhow::Result<ResourcePatchCommit> {
        anyhow::ensure!(!block.is_empty(), "bad request: nothing to move");
        let workspace_id = self.next_id();
        let (_, commit) = self.commit_screen_request(request, |_, state, edit| {
            if screen_result {
                edit.result = ScreenResult::Screen(screen_public_id(state, block[0])?);
            }
            let (from, _) = locate_screen(state, block[0])
                .with_context(|| format!("unknown screen {}", block[0]))?;
            for screen in block {
                anyhow::ensure!(
                    locate_screen(state, *screen).is_some_and(|(wi, _)| wi == from),
                    "bad request: screens to move must share one workspace"
                );
            }
            let (to, index) = match destination {
                ScreenDestination::Workspace { workspace, index } => {
                    let to = match workspace {
                        Some(id) => state
                            .workspace_index(id)
                            .with_context(|| format!("unknown workspace {id}"))?,
                        None => from,
                    };
                    (to, index)
                }
                ScreenDestination::NewWorkspace => {
                    anyhow::ensure!(
                        state.workspaces.len() < WORKSPACE_REGISTRY_LIMIT,
                        "workspace limit reached"
                    );
                    let name = Mux::default_workspace_name(state);
                    state.push_workspace(Workspace {
                        id: workspace_id,
                        public_id: WorkspacePublicId::random()?,
                        key: Mux::new_workspace_key()?,
                        name,
                        screens: Vec::new(),
                        active_screen: 0,
                    });
                    let to = state.workspaces.len() - 1;
                    state.active_workspace = to;
                    (to, Some(0))
                }
            };
            // A screen that changes workspace leaves its group: pruning drops
            // a membership whose group lives in another workspace.
            place_screens(state, block, from, to, index)?;
            Ok(())
        })?;
        if !commit.replayed {
            self.emit_screen_changed(block);
        }
        Ok(commit)
    }

    /// Create a group from screens of one workspace. Members become
    /// contiguous at the position of the first; screens leave any group they
    /// were in. Pinned screens cannot be grouped.
    pub fn create_screen_group(
        self: &Arc<Self>,
        members: &[ScreenId],
        name: Option<String>,
        color: Option<String>,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        let (id, _) = self.create_screen_group_request(
            StripRequest::local_screens("screen.group.create"),
            members,
            name,
            color,
        )?;
        Ok(self.screen_group_outcome(&id))
    }

    pub(crate) fn create_screen_group_request(
        self: &Arc<Self>,
        request: StripRequest,
        members: &[ScreenId],
        name: Option<String>,
        color: Option<String>,
    ) -> anyhow::Result<(String, ResourcePatchCommit)> {
        anyhow::ensure!(
            !members.is_empty(),
            "bad request: a screen group needs at least one screen"
        );
        let name = name.unwrap_or_default();
        let color = color.unwrap_or_else(|| "grey".to_string());
        validate_tab_group_name(&name)?;
        validate_tab_group_color(&color)?;
        let id = new_screen_group_id();
        let (_, commit) = self.commit_screen_request(request, |_, state, edit| {
            edit.result = ScreenResult::Group(id.clone());
            let screens = &mut edit.screens;
            let (wi, _) = locate_screen(state, members[0])
                .with_context(|| format!("unknown screen {}", members[0]))?;
            let key = state.workspaces[wi].key.clone();
            for screen in members {
                anyhow::ensure!(
                    locate_screen(state, *screen).is_some_and(|(candidate, _)| candidate == wi),
                    "bad request: grouped screens must share one workspace"
                );
                let public = screen_public_id(state, *screen)?;
                anyhow::ensure!(
                    !screens.is_pinned(&public),
                    "bad request: pinned screens cannot be grouped"
                );
                screens.members.insert(public, id.clone());
            }
            screens.groups.insert(
                id.clone(),
                ScreenGroupRecord {
                    id: id.clone(),
                    workspace_key: key,
                    name,
                    color,
                    collapsed: false,
                    saved_id: None,
                },
            );
            Ok(())
        })?;
        if !commit.replayed {
            let outcome = self.screen_group_outcome(&id);
            self.emit_screen_changed(&outcome.members);
        }
        Ok((id, commit))
    }

    /// Rename, recolor, or collapse a group. A linked saved record follows.
    pub fn update_screen_group(
        &self,
        group: &str,
        name: Option<String>,
        color: Option<String>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        if let Some(name) = &name {
            validate_tab_group_name(name)?;
        }
        if let Some(color) = &color {
            validate_tab_group_color(color)?;
        }
        self.update_screen_group_request(
            StripRequest::local_screens("screen.group.update"),
            group,
            name,
            color,
            collapsed,
        )?;
        Ok(self.screen_group_outcome(group))
    }

    pub(crate) fn update_screen_group_request(
        &self,
        request: StripRequest,
        group: &str,
        name: Option<String>,
        color: Option<String>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<StateCommit> {
        if let Some(name) = &name {
            validate_tab_group_name(name)?;
        }
        if let Some(color) = &color {
            validate_tab_group_color(color)?;
        }
        let (saved, commit) = self.commit_screen_rows(request, |_, edit| {
            edit.result = ScreenResult::Group(group.to_string());
            let record = edit
                .screens
                .groups
                .get_mut(group)
                .with_context(|| format!("unknown screen group {group}"))?;
            if let Some(name) = name {
                record.name = name;
            }
            if let Some(color) = color {
                record.color = color;
            }
            if let Some(collapsed) = collapsed {
                record.collapsed = collapsed;
            }
            Ok(record.saved_id.clone())
        })?;
        if commit.replayed {
            return Ok(commit);
        }
        if saved.flatten().is_some() {
            self.sync_saved_screen_group(group)?;
        }
        let outcome = self.screen_group_outcome(group);
        self.emit_screen_changed(&outcome.members);
        Ok(commit)
    }

    /// Add screens to a group at `index` inside it (default: the end).
    pub fn add_screens_to_screen_group(
        self: &Arc<Self>,
        group: &str,
        added: &[ScreenId],
        index: Option<usize>,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        self.add_screens_request(
            StripRequest::local_screens("screen.group.add"),
            group,
            added,
            index,
        )?;
        Ok(self.screen_group_outcome(group))
    }

    pub(crate) fn add_screens_request(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
        added: &[ScreenId],
        index: Option<usize>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        anyhow::ensure!(!added.is_empty(), "bad request: no screens to add");
        let (_, commit) = self.commit_screen_request(request, |_, state, edit| {
            edit.result = ScreenResult::Group(group.to_string());
            let screens = &mut edit.screens;
            let record = screens
                .groups
                .get(group)
                .cloned()
                .with_context(|| format!("unknown screen group {group}"))?;
            let members = group_members(state, screens, group);
            let wi = state
                .workspaces
                .iter()
                .position(|workspace| workspace.key == record.workspace_key)
                .context("screen group workspace disappeared")?;
            for screen in added {
                anyhow::ensure!(
                    locate_screen(state, *screen).is_some_and(|(candidate, _)| candidate == wi),
                    "bad request: a screen can join only a group of its own workspace"
                );
                let public = screen_public_id(state, *screen)?;
                anyhow::ensure!(
                    !screens.is_pinned(&public),
                    "bad request: pinned screens cannot be grouped"
                );
                screens.members.insert(public, group.to_string());
            }
            // Place the new members at `index` inside the group run.
            let run = members
                .iter()
                .filter(|screen| !added.contains(screen))
                .copied()
                .collect::<Vec<_>>();
            let offset = index.unwrap_or(run.len()).min(run.len());
            let anchor = run.first().copied();
            let mut block = run;
            block.splice(offset..offset, added.iter().copied());
            let start = anchor
                .and_then(|anchor| state.workspaces[wi].screens.iter().position(|s| s.id == anchor))
                .unwrap_or(state.workspaces[wi].screens.len());
            let before = state.workspaces[wi].screens
                [..start.min(state.workspaces[wi].screens.len())]
                .iter()
                .filter(|screen| block.contains(&screen.id))
                .count();
            place_screens(state, &block, wi, wi, Some(start - before))?;
            Ok(())
        })?;
        if !commit.replayed {
            let outcome = self.screen_group_outcome(group);
            self.emit_screen_changed(&outcome.members);
        }
        Ok(commit)
    }

    /// Remove screens from their groups; each lands right after its former
    /// group. Returns the groups they left.
    pub fn remove_screens_from_screen_group(
        self: &Arc<Self>,
        removed: &[ScreenId],
    ) -> anyhow::Result<Vec<String>> {
        Ok(self
            .remove_screens_request(StripRequest::local_screens("screen.group.remove"), removed)?
            .0)
    }

    pub(crate) fn remove_screens_request(
        self: &Arc<Self>,
        request: StripRequest,
        removed: &[ScreenId],
    ) -> anyhow::Result<(Vec<String>, ResourcePatchCommit)> {
        let (left, commit) = self.commit_screen_request(request, |_, state, edit| {
            let screens = &mut edit.screens;
            let mut left = Vec::new();
            for screen in removed {
                let public = screen_public_id(state, *screen)?;
                let Some(group) = screens.members.remove(&public) else { continue };
                let (wi, _) = locate_screen(state, *screen).context("screen disappeared")?;
                let rest = group_members(state, screens, &group);
                if let Some(last) = rest.last()
                    && let Some(position) =
                        state.workspaces[wi].screens.iter().position(|s| s.id == *last)
                {
                    let own = state.workspaces[wi]
                        .screens
                        .iter()
                        .position(|s| s.id == *screen)
                        .unwrap_or(0);
                    let insertion = if own <= position { position } else { position + 1 };
                    place_screens(state, &[*screen], wi, wi, Some(insertion))?;
                }
                if !left.contains(&group) {
                    left.push(group);
                }
            }
            edit.result = ScreenResult::Groups(left.clone());
            Ok(left)
        })?;
        if !commit.replayed {
            self.emit_screen_changed(removed);
        }
        Ok((left.unwrap_or_default(), commit))
    }

    /// Move a whole group within its workspace, into another workspace, or
    /// into a new one. Members keep their order and stay grouped.
    pub fn move_screen_group(
        self: &Arc<Self>,
        group: &str,
        destination: ScreenDestination,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        let members = self.screen_group_outcome(group).members;
        anyhow::ensure!(!members.is_empty(), "unknown screen group {group}");
        let workspace_id = self.next_id();
        self.commit_screen_change("screen.group.move", |_, state, screens| {
            let (from, _) = locate_screen(state, members[0]).context("screen group disappeared")?;
            let (to, index) = match destination {
                ScreenDestination::Workspace { workspace, index } => match workspace {
                    Some(id) => (
                        state
                            .workspace_index(id)
                            .with_context(|| format!("unknown workspace {id}"))?,
                        index,
                    ),
                    None => (from, index),
                },
                ScreenDestination::NewWorkspace => {
                    anyhow::ensure!(
                        state.workspaces.len() < WORKSPACE_REGISTRY_LIMIT,
                        "workspace limit reached"
                    );
                    let name = Mux::default_workspace_name(state);
                    state.push_workspace(Workspace {
                        id: workspace_id,
                        public_id: WorkspacePublicId::random()?,
                        key: Mux::new_workspace_key()?,
                        name,
                        screens: Vec::new(),
                        active_screen: 0,
                    });
                    let to = state.workspaces.len() - 1;
                    state.active_workspace = to;
                    (to, Some(0))
                }
            };
            place_screens(state, &members, from, to, index)?;
            let key = state.workspaces[to].key.clone();
            if let Some(record) = screens.groups.get_mut(group) {
                record.workspace_key = key;
            }
            Ok(())
        })?;
        let outcome = self.screen_group_outcome(group);
        self.emit_screen_changed(&outcome.members);
        Ok(outcome)
    }

    /// Dissolve a group; its screens stay in place. Returns the members.
    pub fn ungroup_screen_group(&self, group: &str) -> anyhow::Result<Vec<ScreenId>> {
        Ok(self
            .ungroup_screen_group_request(
                StripRequest::local_screens("screen.group.ungroup"),
                group,
            )?
            .0)
    }

    pub(crate) fn ungroup_screen_group_request(
        &self,
        request: StripRequest,
        group: &str,
    ) -> anyhow::Result<(Vec<ScreenId>, StateCommit)> {
        let members = self.screen_group_outcome(group).members;
        let (_, commit) = self.commit_screen_rows(request, |state, edit| {
            let screens = &mut edit.screens;
            anyhow::ensure!(screens.groups.remove(group).is_some(), "unknown screen group {group}");
            screens.members.retain(|_, member| member != group);
            edit.result = ScreenResult::Release {
                group: group.to_string(),
                screens: members
                    .iter()
                    .filter_map(|screen| screen_public_id(state, *screen).ok())
                    .collect(),
            };
            Ok(())
        })?;
        if !commit.replayed {
            self.emit_screen_changed(&members);
        }
        Ok((members, commit))
    }

    /// Close every member screen. A linked saved record stays.
    pub fn close_screen_group_as(
        self: &Arc<Self>,
        actor: &Actor,
        group: &str,
        end_terminals: bool,
    ) -> anyhow::Result<Vec<ScreenId>> {
        let members = self.screen_group_outcome(group).members;
        anyhow::ensure!(!members.is_empty(), "unknown screen group {group}");
        let workspace_screens = self.with_state(|state| {
            locate_screen(state, members[0]).map(|(wi, _)| state.workspaces[wi].screens.len())
        });
        anyhow::ensure!(
            workspace_screens.is_some_and(|count| count > members.len()),
            "bad request: closing the group would leave its workspace without a screen; close the workspace instead"
        );
        let mut closed = Vec::new();
        for screen in &members {
            let ok = if end_terminals {
                self.close_container_ending_terminals(BatchCloseTarget::Screen(*screen)).is_ok()
            } else {
                self.close_screen_as(actor, *screen)?
            };
            if ok {
                closed.push(*screen);
            }
        }
        Ok(closed)
    }

    // MARK: Saved screen groups

    fn saved_members(&self, members: &[ScreenId]) -> Vec<SavedScreenMember> {
        let presentation = self.presentation_snapshot();
        self.with_state(|state| {
            members
                .iter()
                .filter_map(|screen| {
                    let (wi, si) = locate_screen(state, *screen)?;
                    let screen = &state.workspaces[wi].screens[si];
                    let record = presentation
                        .screens
                        .screen(screen.public_id.as_str())
                        .cloned()
                        .unwrap_or_default();
                    let cwd = state
                        .panes
                        .get(&screen.active_pane)
                        .and_then(|pane| pane.tabs.get(pane.active_tab))
                        .and_then(|surface| state.surfaces.get(surface))
                        .and_then(|runtime| runtime.presented_directory());
                    Some(SavedScreenMember {
                        name: screen.name.clone(),
                        color: record.color,
                        icon: record.icon,
                        cwd,
                    })
                })
                .collect()
        })
    }

    fn sync_saved_screen_group(&self, group: &str) -> anyhow::Result<()> {
        let outcome = self.screen_group_outcome(group);
        let Some(record) = outcome.group else { return Ok(()) };
        let Some(saved_id) = record.saved_id.clone() else { return Ok(()) };
        let profile_id = self
            .presentation_snapshot()
            .saved_screen_groups
            .iter()
            .find(|saved| saved.id == saved_id)
            .and_then(|saved| saved.profile_id.clone());
        let saved = SavedScreenGroupRecord {
            id: saved_id,
            name: record.name,
            color: record.color,
            profile_id,
            members: self.saved_members(&outcome.members),
            updated_at_ms: crate::workspace_registry::unix_epoch_ms()?,
        };
        let mut registry = self.workspace_registry.lock().unwrap();
        registry.put_saved_screen_group(&saved)?;
        self.reload_presentation(&registry)
    }

    /// Save a group: a session-wide record linked to the live group.
    pub fn save_screen_group(&self, group: &str) -> anyhow::Result<String> {
        let saved_id = self.commit_screen_metadata(|_, screens| {
            let record = screens
                .groups
                .get_mut(group)
                .with_context(|| format!("unknown screen group {group}"))?;
            Ok(record.saved_id.get_or_insert_with(new_saved_screen_group_id).clone())
        })?;
        self.sync_saved_screen_group(group)?;
        self.emit(MuxEvent::TreeChanged);
        Ok(saved_id)
    }

    /// Unsave a live group: delete its saved record and unlink it.
    pub fn unsave_screen_group(&self, group: &str) -> anyhow::Result<()> {
        let saved = self
            .presentation_snapshot()
            .screens
            .groups
            .get(group)
            .with_context(|| format!("unknown screen group {group}"))?
            .saved_id
            .clone()
            .context("bad request: the screen group is not saved")?;
        self.delete_saved_screen_group(&saved)?;
        Ok(())
    }

    pub fn delete_saved_screen_group(&self, saved: &str) -> anyhow::Result<bool> {
        let removed = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let removed = registry.delete_saved_screen_group(saved)?;
            self.reload_presentation(&registry)?;
            removed
        };
        anyhow::ensure!(removed, "unknown saved screen group {saved}");
        self.publish_journal_event();
        self.emit(MuxEvent::TreeChanged);
        Ok(removed)
    }

    /// Reopen a saved group into `workspace`: one new screen per member, in
    /// the member's directory, with its name, color, and icon, grouped and
    /// linked to the saved record. An open group is returned as it is.
    pub fn reopen_saved_screen_group_as(
        self: &Arc<Self>,
        actor: &Actor,
        saved: &str,
        workspace: WorkspaceId,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        let presentation = self.presentation_snapshot();
        let record = presentation
            .saved_screen_groups
            .iter()
            .find(|candidate| candidate.id == saved)
            .cloned()
            .with_context(|| format!("unknown saved screen group {saved}"))?;
        if let Some(open) = presentation
            .screens
            .groups
            .values()
            .find(|group| group.saved_id.as_deref() == Some(saved))
        {
            return Ok(self.screen_group_outcome(&open.id));
        }
        let mut created = Vec::new();
        for member in &record.members {
            let spec = ScreenSpec {
                name: member.name.clone(),
                color: member.color.clone(),
                icon: member.icon.clone(),
                ..ScreenSpec::default()
            };
            let spawn = TerminalSpawnOptions::new(member.cwd.clone(), Vec::new());
            let (_, screen) =
                self.new_screen_with_spec_as(actor, Some(workspace), spawn, None, spec)?;
            created.push(screen);
        }
        anyhow::ensure!(!created.is_empty(), "bad request: the saved screen group has no members");
        let outcome =
            self.create_screen_group(&created, Some(record.name.clone()), Some(record.color))?;
        let group = outcome
            .group
            .as_ref()
            .map(|group| group.id.clone())
            .context("screen group disappeared")?;
        self.commit_screen_metadata(|_, screens| {
            if let Some(live) = screens.groups.get_mut(&group) {
                live.saved_id = Some(saved.to_string());
            }
            Ok(())
        })?;
        self.emit(MuxEvent::TreeChanged);
        Ok(self.screen_group_outcome(&group))
    }

    /// New screen in `workspace` (default: the active one) with `spec`
    /// applied: the name in the creating commit, the rest (color, icon, pin,
    /// position, group) in one screen commit right after. Returns the new
    /// surface and screen.
    pub fn new_screen_with_spec_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: Option<WorkspaceId>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
        spec: ScreenSpec,
    ) -> anyhow::Result<(Arc<Surface>, ScreenId)> {
        if let Some(color) = &spec.color {
            crate::workspace_registry::validate_presentation_color(color)?;
        }
        if let Some(icon) = &spec.icon {
            crate::workspace_registry::validate_presentation_icon(icon)?;
        }
        let surface = self.new_screen_named_as(actor, workspace, spec.name.clone(), spawn, size)?;
        #[cfg(test)]
        if let Some(hook) = self.screen_created_hook.lock().unwrap().take() {
            hook(surface.id);
        }
        let screen = self
            .with_state(|state| {
                let pane = state.pane_of(surface.id)?;
                let (wi, si) = state.screen_of(pane)?;
                Some(state.workspaces[wi].screens[si].id)
            })
            .context("new screen disappeared")?;
        if spec.has_presentation() {
            self.commit_screen_change("screen.create.presentation", |_, state, screens| {
                let public = screen_public_id(state, screen)?;
                screens.edit(&public, |record| {
                    record.color = spec.color.clone();
                    record.icon = spec.icon.clone();
                    record.pinned = spec.pinned.unwrap_or(false);
                });
                if let Some(group) = &spec.group {
                    let record = screens
                        .groups
                        .get(group)
                        .with_context(|| format!("unknown screen group {group}"))?;
                    let (wi, _) = locate_screen(state, screen).context("new screen disappeared")?;
                    anyhow::ensure!(
                        record.workspace_key == state.workspaces[wi].key,
                        "bad request: a screen can join only a group of its own workspace"
                    );
                    screens.members.insert(public, group.clone());
                }
                if let Some(index) = spec.index {
                    let (wi, _) = locate_screen(state, screen).context("new screen disappeared")?;
                    place_screens(state, &[screen], wi, wi, Some(index))?;
                }
                Ok(())
            })?;
            self.emit_screen_changed(&[screen]);
        }
        Ok((surface, screen))
    }
}

#[cfg(test)]
mod tests;
