//! Screen metadata (color, icon, pin), screen order, and Chrome-style screen
//! groups (`screen-metadata-v1`, `screen-groups-v1`).
//!
//! A screen group lives in one workspace: an id, a name (may be empty), one
//! of Chrome's nine colors, and a shared collapsed flag. Each screen belongs
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

use super::*;
use crate::workspace_registry::{
    SavedScreenGroupRecord, SavedScreenMember, ScreenGroupRecord, ScreenPresentationState,
    new_saved_screen_group_id, new_screen_group_id, validate_tab_group_color,
    validate_tab_group_name,
};

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

fn locate_screen(state: &State, screen: ScreenId) -> Option<(usize, usize)> {
    state.workspaces.iter().enumerate().find_map(|(wi, workspace)| {
        workspace.screens.iter().position(|candidate| candidate.id == screen).map(|si| (wi, si))
    })
}

fn screen_public_id(state: &State, screen: ScreenId) -> anyhow::Result<String> {
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
fn prune_screen_state(state: &State, screens: &mut ScreenPresentationState) {
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

/// Pinned screens first, then every group gathered at its first member. The
/// active screen stays active.
fn normalize_screen_order(workspace: &mut Workspace, screens: &ScreenPresentationState) {
    let active = workspace.screens.get(workspace.active_screen).map(|screen| screen.id);
    let group_of = |screen: &Screen| screens.members.get(screen.public_id.as_str()).cloned();
    let old = std::mem::take(&mut workspace.screens);
    let (mut ordered, rest): (Vec<Screen>, Vec<Screen>) =
        old.into_iter().partition(|screen| screens.is_pinned(screen.public_id.as_str()));
    let mut rest = rest.into_iter().map(Some).collect::<Vec<_>>();
    for index in 0..rest.len() {
        let Some(screen) = rest[index].take() else { continue };
        let group = group_of(&screen);
        ordered.push(screen);
        if let Some(group) = group {
            for later in rest.iter_mut().skip(index + 1) {
                if later
                    .as_ref()
                    .is_some_and(|candidate| group_of(candidate).as_ref() == Some(&group))
                {
                    ordered.extend(later.take());
                }
            }
        }
    }
    workspace.screens = ordered;
    let last = workspace.screens.len().saturating_sub(1);
    workspace.active_screen = active
        .and_then(|id| workspace.screens.iter().position(|screen| screen.id == id))
        .unwrap_or(0)
        .min(last);
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
    /// Commit a change that may reorder screens or move them between
    /// workspaces. `mutate` edits a clone of the live state and the screen
    /// rows; both commit together, then the clone replaces the live state.
    fn commit_screen_change<R>(
        self: &Arc<Self>,
        operation: &str,
        mutate: impl FnOnce(&Arc<Mux>, &mut State, &mut ScreenPresentationState) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let mux = Arc::clone(self);
        let mut output = None;
        let mut retarget = Vec::new();
        let fingerprint = serde_json::json!({
            "operation": operation,
            "nonce": crate::workspace_registry::new_uuid_v4(),
        });
        self.commit_resource_mutation_plan(
            &WorkspaceMutation::local("cmux-tui-screens"),
            operation,
            &fingerprint,
            None,
            None,
            |state, registry| {
                let mut projected = state.clone();
                let mut screens = mux.presentation_snapshot().screens.clone();
                let result = mutate(&mux, &mut projected, &mut screens)?;
                prune_screen_state(&projected, &mut screens);
                for workspace in &mut projected.workspaces {
                    normalize_screen_order(workspace, &screens);
                }
                projected.rebuild_resource_indexes();
                Mux::rebuild_split_screen_index(&mut projected);
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
                    presentation: None,
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
                .with_screen_state(screens);
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
        output.context("screen change committed no result")
    }

    /// Write screen rows without changing screen order.
    fn commit_screen_metadata<R>(
        &self,
        mutate: impl FnOnce(&State, &mut ScreenPresentationState) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let result = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let state = self.state.lock().unwrap();
            let mut screens = self.presentation_snapshot().screens.clone();
            let result = mutate(&state, &mut screens)?;
            prune_screen_state(&state, &mut screens);
            drop(state);
            registry.replace_screen_state(&screens)?;
            self.reload_presentation(&registry)?;
            result
        };
        self.publish_journal_event();
        Ok(result)
    }

    /// Emit `screen-changed` (full screen and its index) for each screen.
    pub(crate) fn emit_screen_changed(&self, screens: &[ScreenId]) {
        let decorations = self.tree_decorations();
        let deltas = {
            let state = self.state.lock().unwrap();
            screens
                .iter()
                .filter_map(|screen| {
                    let (wi, si) = locate_screen(&state, *screen)?;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &decorations,
                        TreeDeltaKind::ScreenChanged,
                        *screen,
                    )?;
                    Some(TreeDelta {
                        kind: TreeDeltaKind::ScreenChanged,
                        workspace: state.workspaces[wi].id,
                        screen: Some(*screen),
                        pane: None,
                        surface: None,
                        index: Some(si),
                        entity,
                        workspace_revision: None,
                        transaction: None,
                    })
                })
                .collect::<Vec<_>>()
        };
        for delta in deltas {
            self.emit(MuxEvent::TreeDelta(delta));
        }
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
        &self,
        screen: ScreenId,
        color: Option<Option<String>>,
        icon: Option<Option<String>>,
    ) -> anyhow::Result<bool> {
        if let Some(Some(color)) = &color {
            crate::workspace_registry::validate_presentation_color(color)?;
        }
        if let Some(Some(icon)) = &icon {
            crate::workspace_registry::validate_presentation_icon(icon)?;
        }
        let changed = self.commit_screen_metadata(|state, screens| {
            let public = screen_public_id(state, screen)?;
            let before = screens.screen(&public).cloned().unwrap_or_default();
            screens.edit(&public, |record| {
                if let Some(color) = color {
                    record.color = color;
                }
                if let Some(icon) = icon {
                    record.icon = icon;
                }
            });
            Ok(screens.screen(&public).cloned().unwrap_or_default() != before)
        })?;
        if changed {
            self.emit_screen_changed(&[screen]);
        }
        Ok(changed)
    }

    /// Pin or unpin a screen. Pinned screens sort first and leave their
    /// group. Returns whether the flag changed and the screen's new index.
    pub fn set_screen_pinned(
        self: &Arc<Self>,
        screen: ScreenId,
        pinned: bool,
    ) -> anyhow::Result<(bool, usize)> {
        let changed = self.commit_screen_change("screen.pin", |_, state, screens| {
            let public = screen_public_id(state, screen)?;
            let before = screens.is_pinned(&public);
            screens.edit(&public, |record| record.pinned = pinned);
            if pinned {
                screens.members.remove(&public);
            }
            Ok(before != pinned)
        })?;
        let index =
            self.with_state(|state| locate_screen(state, screen).map(|(_, si)| si)).unwrap_or(0);
        self.emit_screen_changed(&[screen]);
        Ok((changed, index))
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
        .inspect(|_| self.emit_screen_changed(&[screen]))
    }

    fn move_screen_block(
        self: &Arc<Self>,
        block: &[ScreenId],
        destination: ScreenDestination,
        operation: &str,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(!block.is_empty(), "bad request: nothing to move");
        let workspace_id = self.next_id();
        self.commit_screen_change(operation, |_, state, _| {
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
        })
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
        anyhow::ensure!(
            !members.is_empty(),
            "bad request: a screen group needs at least one screen"
        );
        let name = name.unwrap_or_default();
        let color = color.unwrap_or_else(|| "grey".to_string());
        validate_tab_group_name(&name)?;
        validate_tab_group_color(&color)?;
        let id = new_screen_group_id();
        self.commit_screen_change("screen.group.create", |_, state, screens| {
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
        let outcome = self.screen_group_outcome(&id);
        self.emit_screen_changed(&outcome.members);
        Ok(outcome)
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
        let saved = self.commit_screen_metadata(|_, screens| {
            let record = screens
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
        if saved.is_some() {
            self.sync_saved_screen_group(group)?;
        }
        self.emit(MuxEvent::TreeChanged);
        let outcome = self.screen_group_outcome(group);
        self.emit_screen_changed(&outcome.members);
        Ok(outcome)
    }

    /// Add screens to a group at `index` inside it (default: the end).
    pub fn add_screens_to_screen_group(
        self: &Arc<Self>,
        group: &str,
        added: &[ScreenId],
        index: Option<usize>,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        anyhow::ensure!(!added.is_empty(), "bad request: no screens to add");
        self.commit_screen_change("screen.group.add", |_, state, screens| {
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
        let outcome = self.screen_group_outcome(group);
        self.emit_screen_changed(&outcome.members);
        Ok(outcome)
    }

    /// Remove screens from their groups; each lands right after its former
    /// group. Returns the groups they left.
    pub fn remove_screens_from_screen_group(
        self: &Arc<Self>,
        removed: &[ScreenId],
    ) -> anyhow::Result<Vec<String>> {
        let left = self.commit_screen_change("screen.group.remove", |_, state, screens| {
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
            Ok(left)
        })?;
        self.emit_screen_changed(removed);
        Ok(left)
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
        let members = self.screen_group_outcome(group).members;
        self.commit_screen_metadata(|_, screens| {
            anyhow::ensure!(screens.groups.remove(group).is_some(), "unknown screen group {group}");
            screens.members.retain(|_, member| member != group);
            Ok(())
        })?;
        self.emit(MuxEvent::TreeChanged);
        self.emit_screen_changed(&members);
        Ok(members)
    }

    /// Close every member screen. A linked saved record stays.
    pub fn close_screen_group(
        self: &Arc<Self>,
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
                self.close_screen(*screen)?
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
    pub fn reopen_saved_screen_group(
        self: &Arc<Self>,
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
            let (_, screen) =
                self.new_screen_with_spec(Some(workspace), member.cwd.clone(), None, spec)?;
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
    pub fn new_screen_with_spec(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        spec: ScreenSpec,
    ) -> anyhow::Result<(Arc<Surface>, ScreenId)> {
        if let Some(color) = &spec.color {
            crate::workspace_registry::validate_presentation_color(color)?;
        }
        if let Some(icon) = &spec.icon {
            crate::workspace_registry::validate_presentation_icon(icon)?;
        }
        let surface = self.new_screen_named(workspace, spec.name.clone(), cwd, size)?;
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
mod tests {
    use super::*;

    struct Session {
        root: std::path::PathBuf,
    }

    impl Session {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir()
                .join(format!("cmux-screens-{name}-{}", WorkspacePublicId::random().unwrap()));
            Self { root }
        }

        /// The registry alone, after the mux that held it is dropped.
        fn registry(&self) -> WorkspaceRegistry {
            WorkspaceRegistry::open(&self.root, "screens").unwrap()
        }

        fn open(&self) -> Arc<Mux> {
            let registry = WorkspaceRegistry::open(&self.root, "screens").unwrap();
            Mux::from_workspace_registry(
                "screens".into(),
                SurfaceOptions::default(),
                registry,
                ProviderWorkspaceState::default(),
                true,
            )
            .unwrap()
        }
    }

    impl Drop for Session {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    /// Screen ids of workspace `index`, in order.
    fn order(mux: &Mux, index: usize) -> Vec<ScreenId> {
        mux.with_state(|state| state.workspaces[index].screens.iter().map(|s| s.id).collect())
    }

    fn public_order(mux: &Mux, index: usize) -> Vec<String> {
        mux.with_state(|state| {
            state.workspaces[index]
                .screens
                .iter()
                .map(|s| s.public_id.as_str().to_string())
                .collect()
        })
    }

    fn tree(mux: &Mux) -> Value {
        let decorations = mux.tree_decorations();
        mux.with_state(|state| crate::server::workspaces_json(state, &decorations))
    }

    fn new_screen(mux: &Arc<Mux>, workspace: WorkspaceId) -> ScreenId {
        mux.new_screen_with_spec(Some(workspace), None, None, ScreenSpec::default()).unwrap().1
    }

    #[test]
    fn cmux_next_screen_metadata_survives_restart_and_emits_screen_changed() {
        let session = Session::new("metadata");
        let mux = session.open();
        let first = mux.new_workspace(None, None).unwrap().id;
        let workspace = mux.with_state(|state| state.workspaces[0].id);
        let s1 = order(&mux, 0)[0];
        let s2 = new_screen(&mux, workspace);
        let s3 = new_screen(&mux, workspace);
        assert_eq!(order(&mux, 0), vec![s1, s2, s3]);
        let _ = first;

        let events = mux.subscribe();
        assert!(
            mux.set_screen_metadata(s3, Some(Some("green".into())), Some(Some("🚀".into())))
                .unwrap()
        );
        let delta = std::iter::from_fn(|| events.try_recv().ok())
            .find_map(|event| match event {
                MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::ScreenChanged => {
                    Some(delta)
                }
                _ => None,
            })
            .expect("screen-changed delta");
        assert_eq!(delta.screen, Some(s3));
        assert_eq!(delta.index, Some(2));
        assert_eq!(delta.entity["color"], "green");
        assert_eq!(delta.entity["icon"], "🚀");
        assert!(mux.set_screen_metadata(s3, Some(Some("bad color!".into())), None).is_err());
        assert!(mux.set_screen_metadata(s3, None, Some(Some("two words".into()))).is_err());
        // Absent keeps, null clears.
        assert!(mux.set_screen_metadata(s3, None, Some(None)).unwrap());
        assert!(!mux.set_screen_metadata(s3, None, None).unwrap());

        let (changed, index) = mux.set_screen_pinned(s3, true).unwrap();
        assert!(changed);
        assert_eq!(index, 0);
        assert_eq!(order(&mux, 0), vec![s3, s1, s2]);
        mux.rename_screen(s2, "logs".into());
        mux.move_screen(s2, ScreenDestination::Workspace { workspace: None, index: Some(0) })
            .unwrap();
        // The pinned screen stays first.
        assert_eq!(order(&mux, 0), vec![s3, s2, s1]);
        let json = tree(&mux);
        assert_eq!(json["workspaces"][0]["screens"][0]["pinned"], true);
        assert_eq!(json["workspaces"][0]["screens"][0]["color"], "green");
        assert_eq!(json["workspaces"][0]["screens"][0]["icon"], Value::Null);
        assert_eq!(json["workspaces"][0]["screens"][1]["name"], "logs");

        // Order, pin, and color are durable: the registry has them after
        // the daemon exits.
        let before = public_order(&mux, 0);
        let workspace_public =
            mux.with_state(|state| state.workspaces[0].public_id.as_str().to_string());
        drop(mux);
        let registry = session.registry();
        assert_eq!(registry.live_screen_order(&workspace_public).unwrap(), before);
        let snapshot = registry.presentation_snapshot().unwrap();
        let record = snapshot.screens.screen(&before[0]).unwrap();
        assert!(record.pinned);
        assert_eq!(record.color.as_deref(), Some("green"));
        assert_eq!(record.icon, None);
    }

    #[test]
    fn cmux_next_screen_groups_stay_contiguous_and_survive_restart() {
        let session = Session::new("groups");
        let mux = session.open();
        mux.new_workspace(None, None).unwrap();
        let workspace = mux.with_state(|state| state.workspaces[0].id);
        let s1 = order(&mux, 0)[0];
        let s2 = new_screen(&mux, workspace);
        let s3 = new_screen(&mux, workspace);
        let s4 = new_screen(&mux, workspace);
        mux.set_screen_pinned(s1, true).unwrap();
        assert!(
            mux.create_screen_group(&[s1], None, None).is_err(),
            "pinned screens cannot be grouped"
        );
        assert!(mux.create_screen_group(&[s2], None, Some("blurple".into())).is_err());

        let created = mux
            .create_screen_group(&[s4, s2], Some("Build".into()), Some("orange".into()))
            .unwrap();
        let group = created.group.clone().unwrap().id;
        assert_eq!(created.members, vec![s2, s4]);
        assert_eq!(order(&mux, 0), vec![s1, s2, s4, s3]);

        mux.update_screen_group(&group, Some(String::new()), Some("cyan".into()), Some(true))
            .unwrap();
        let record = mux.presentation_snapshot().screens.groups[&group].clone();
        assert_eq!(
            (record.name.as_str(), record.color.as_str(), record.collapsed),
            ("", "cyan", true)
        );

        mux.add_screens_to_screen_group(&group, &[s3], Some(0)).unwrap();
        assert_eq!(order(&mux, 0), vec![s1, s3, s2, s4]);
        mux.remove_screens_from_screen_group(&[s3]).unwrap();
        assert_eq!(order(&mux, 0), vec![s1, s2, s4, s3]);
        // A single screen move into the middle of the group is pulled out:
        // groups stay contiguous.
        mux.move_screen(s3, ScreenDestination::Workspace { workspace: None, index: Some(2) })
            .unwrap();
        let runs = mux.with_state(|state| {
            workspace_screen_groups(&state.workspaces[0], &mux.presentation_snapshot().screens)
        });
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].members.len(), 2);
        // Moving the group cannot pass the pinned screen.
        mux.move_screen_group(
            &group,
            ScreenDestination::Workspace { workspace: None, index: Some(0) },
        )
        .unwrap();
        assert_eq!(order(&mux, 0)[0], s1);

        let json = tree(&mux);
        let groups = &json["workspaces"][0]["screen_groups"];
        assert_eq!(groups[0]["id"], group.as_str());
        assert_eq!(groups[0]["count"], 2);
        assert_eq!(groups[0]["collapsed"], true);
        let start = groups[0]["start"].as_u64().unwrap() as usize;
        assert_eq!(json["workspaces"][0]["screens"][start]["group"], group.as_str());

        let saved = mux.save_screen_group(&group).unwrap();
        assert_eq!(mux.presentation_snapshot().saved_screen_groups[0].id, saved);
        assert_eq!(mux.presentation_snapshot().saved_screen_groups[0].members.len(), 2);

        let before = public_order(&mux, 0);
        let workspace_public =
            mux.with_state(|state| state.workspaces[0].public_id.as_str().to_string());
        drop(mux);
        {
            let registry = session.registry();
            assert_eq!(registry.live_screen_order(&workspace_public).unwrap(), before);
            let snapshot = registry.presentation_snapshot().unwrap();
            assert_eq!(snapshot.screens.groups[&group].saved_id.as_deref(), Some(saved.as_str()));
            assert!(snapshot.screens.groups[&group].collapsed);
            assert_eq!(snapshot.screens.members.values().filter(|g| **g == group).count(), 2);
            assert_eq!(snapshot.saved_screen_groups.len(), 1);
        }
        let mux = session.open();
        mux.new_workspace(None, None).unwrap();

        mux.ungroup_screen_group(&group).ok();
        assert!(mux.presentation_snapshot().screens.groups.is_empty());
        // The saved record outlives the live group and reopens it.
        let workspace = mux.with_state(|state| state.workspaces.last().unwrap().id);
        let reopened = mux.reopen_saved_screen_group(&saved, workspace).unwrap();
        assert_eq!(reopened.members.len(), 2);
        assert_eq!(reopened.group.unwrap().saved_id.as_deref(), Some(saved.as_str()));
        assert!(mux.delete_saved_screen_group(&saved).unwrap());
    }

    #[test]
    fn cmux_next_screens_move_between_workspaces_with_their_terminals() {
        let session = Session::new("moves");
        let mux = session.open();
        mux.new_workspace(None, None).unwrap();
        mux.new_workspace(None, None).unwrap();
        let (a, b) = mux.with_state(|state| (state.workspaces[0].id, state.workspaces[1].id));
        let s1 = order(&mux, 0)[0];
        // A workspace keeps at least one screen.
        assert!(
            mux.move_screen(s1, ScreenDestination::Workspace { workspace: Some(b), index: None })
                .is_err()
        );
        let s2 = new_screen(&mux, a);
        let surface = mux.with_state(|state| {
            let (wi, si) = locate_screen(state, s2).unwrap();
            state.panes[&state.workspaces[wi].screens[si].active_pane].tabs[0]
        });
        let moved = mux
            .move_screen(s2, ScreenDestination::Workspace { workspace: Some(b), index: Some(0) })
            .unwrap();
        assert_eq!(moved.workspace, b);
        assert_eq!(moved.index, 0);
        assert_eq!(order(&mux, 0), vec![s1]);
        assert_eq!(order(&mux, 1)[0], s2);
        // The terminal moved with its screen.
        let owner = mux.with_state(|state| {
            state.pane_of(surface).and_then(|pane| state.screen_of(pane)).map(|(wi, _)| wi)
        });
        assert_eq!(owner, Some(1));

        let count = mux.with_state(|state| state.workspaces.len());
        let s3 = new_screen(&mux, b);
        let moved = mux.move_screen(s3, ScreenDestination::NewWorkspace).unwrap();
        assert_eq!(mux.with_state(|state| state.workspaces.len()), count + 1);
        assert_eq!(order(&mux, count), vec![s3]);
        assert_eq!(moved.key, mux.with_state(|state| state.workspaces[count].key.clone()));

        // A screen that changes workspace leaves its group.
        let s4 = new_screen(&mux, b);
        let group = mux.create_screen_group(&[s4], None, None).unwrap().group.unwrap().id;
        mux.move_screen(s4, ScreenDestination::Workspace { workspace: Some(a), index: None })
            .unwrap();
        assert!(!mux.presentation_snapshot().screens.members.values().any(|g| g == &group));
    }

    #[test]
    fn cmux_next_new_screen_with_spec_applies_name_metadata_position_and_directory() {
        let session = Session::new("spec");
        let mux = session.open();
        mux.new_workspace(None, None).unwrap();
        let workspace = mux.with_state(|state| state.workspaces[0].id);
        let s1 = order(&mux, 0)[0];
        let group =
            mux.create_screen_group(&[s1], Some("g".into()), None).unwrap().group.unwrap().id;
        let dir = std::env::temp_dir();
        let spec = ScreenSpec {
            name: Some("deploy".into()),
            color: Some("red".into()),
            icon: Some("server.rack".into()),
            pinned: None,
            index: Some(0),
            group: Some(group.clone()),
        };
        let (_, screen) = mux
            .new_screen_with_spec(Some(workspace), Some(dir.display().to_string()), None, spec)
            .unwrap();
        let json = tree(&mux);
        let screens = json["workspaces"][0]["screens"].as_array().unwrap();
        let entity = screens.iter().find(|s| s["id"] == screen).unwrap();
        assert_eq!(entity["name"], "deploy");
        assert_eq!(entity["color"], "red");
        assert_eq!(entity["icon"], "server.rack");
        assert_eq!(entity["group"], group.as_str());
        assert_eq!(order(&mux, 0), vec![screen, s1]);
    }
}
