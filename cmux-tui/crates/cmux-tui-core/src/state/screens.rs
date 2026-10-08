//! One durable commit for every screen presentation change: screen color,
//! icon and pin, screen order, and screen groups. The raw screen commands
//! (`screen_groups.rs`, `screen-metadata-v1`, `screen-groups-v1`) and the v2
//! operations (`screen.update`, `screen.move`, `screen_group.*`) share it, so
//! there is one storage (`screen_store`'s tables) and one event path.
//!
//! A change that may reorder screens commits the topology patch and the
//! screen rows in one transaction ([`Mux::commit_screen_request`]); a
//! change that leaves order alone commits the rows alone
//! ([`Mux::commit_screen_rows`]). Raw commands pass a local mutation; v2
//! operations pass their idempotency key, so a retry replays the stored
//! result. Either way the `session.events` batch restates every screen whose
//! presentation or group changed and every screen group the change touched.

use std::collections::BTreeSet;

use crate::mux::tab_strip::StripRequest;
use crate::mux::*;
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::prelude::*;
use crate::state::screen_state_store::{
    ScreenMetaUpdate, screen_group_snapshot, write_screen_rows,
};
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};
use crate::state::values::{fresh_upserts, upserted_value};
use crate::workspace_registry::ScreenPresentationState;

/// What a screen change returns as its v2 result.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum ScreenResult {
    #[default]
    None,
    /// The decorated `ScreenSnapshot` of a screen (public id).
    Screen(String),
    /// The `ScreenGroupSnapshot` of a group.
    Group(String),
    /// The snapshots of the groups that still exist.
    Groups(Vec<String>),
    /// A dissolved group and its former members.
    Release { group: String, screens: Vec<String> },
}

/// The screen rows a change edits, starting from the committed ones.
pub(crate) struct ScreenEdit {
    pub(crate) screens: ScreenPresentationState,
    pub(crate) result: ScreenResult,
}

/// One v2 screen request.
#[derive(Debug, Clone)]
pub(crate) enum ScreenChange {
    Update {
        selectors: crate::ResourceSelectors,
        update: ScreenMetaUpdate,
    },
    Move {
        selectors: crate::ResourceSelectors,
        index: usize,
    },
    GroupCreate {
        screens: Vec<String>,
        name: String,
        color: String,
    },
    GroupAdd {
        group: String,
        screens: Vec<String>,
    },
    GroupRemove {
        screens: Vec<String>,
    },
    GroupUpdate {
        group: String,
        name: Option<String>,
        color: Option<String>,
        collapsed: Option<bool>,
    },
    GroupUngroup {
        group: String,
    },
}

impl StripRequest {
    /// A raw screen command: a fresh local mutation that never replays.
    pub(crate) fn local_screens(operation: &str) -> Self {
        Self {
            mutation: WorkspaceMutation::daemon_local("cmux-tui-screens"),
            ..Self::local(operation)
        }
    }
}

/// The in-transaction write of a screen edit: rows, restatements, result.
fn screen_rows_write(
    before: &ScreenPresentationState,
    edit: ScreenEdit,
) -> crate::resource_mutation::PlanStateWrite {
    let ScreenEdit { screens, result: result_kind } = edit;
    let mut touched_screens = BTreeSet::new();
    for id in before.screens.keys().chain(screens.screens.keys()) {
        if before.screens.get(id) != screens.screens.get(id) {
            touched_screens.insert(id.clone());
        }
    }
    for id in before.members.keys().chain(screens.members.keys()) {
        if before.members.get(id) != screens.members.get(id) {
            touched_screens.insert(id.clone());
        }
    }
    if let ScreenResult::Screen(screen) = &result_kind {
        touched_screens.insert(screen.clone());
    }
    let mut changed_groups = BTreeSet::new();
    for id in before.groups.keys().chain(screens.groups.keys()) {
        let members = |state: &ScreenPresentationState| {
            state.members.iter().filter(|(_, group)| *group == id).count()
        };
        if before.groups.get(id) != screens.groups.get(id) || members(before) != members(&screens) {
            changed_groups.insert(id.clone());
        }
    }
    let touched_screens = touched_screens.into_iter().collect::<Vec<_>>();
    Box::new(move |transaction, result, changes| {
        write_screen_rows(transaction, &screens)?;
        let fresh = fresh_upserts(transaction, &[], &touched_screens, &[])?;
        // Screens the patch moved restate their group: its member order
        // changed with them.
        let moved = changes
            .iter()
            .filter(|change| change["kind"] == "upsert" && change["resource"] == "screen")
            .filter_map(|change| change["id"].as_str().map(str::to_string))
            .collect::<BTreeSet<_>>();
        let mut group_ids = changed_groups.clone();
        for (screen, group) in &screens.members {
            if moved.contains(screen) {
                group_ids.insert(group.clone());
            }
        }
        changes.extend(fresh.iter().cloned());
        for id in &group_ids {
            match screen_group_snapshot(transaction, id)? {
                Some(snapshot) => changes.push(state_upsert("screen_group", id, snapshot)),
                None => changes.push(state_delete("screen_group", id)),
            }
        }
        *result = match &result_kind {
            ScreenResult::None => result.clone(),
            ScreenResult::Screen(screen) => upserted_value(&fresh, "screen", screen)
                .ok_or_else(|| state_not_found("screen", screen))?,
            ScreenResult::Group(group) => screen_group_snapshot(transaction, group)?
                .ok_or_else(|| state_not_found("screen_group", group))?,
            ScreenResult::Groups(ids) => {
                let mut values = Vec::new();
                for id in ids {
                    if let Some(snapshot) = screen_group_snapshot(transaction, id)? {
                        values.push(snapshot);
                    }
                }
                Value::Array(values)
            }
            ScreenResult::Release { group, screens } => {
                serde_json::json!({"screen_group_id": group, "screen_ids": screens})
            }
        };
        Ok(())
    })
}

impl Mux {
    /// The live screen with this public id.
    fn screen_id_of(&self, public: &str) -> Option<ScreenId> {
        self.with_state(|state| {
            state
                .workspaces
                .iter()
                .flat_map(|workspace| workspace.screens.iter())
                .find(|screen| screen.public_id.as_str() == public)
                .map(|screen| screen.id)
        })
    }

    /// Commit a change that may reorder screens or move them between
    /// workspaces. `mutate` edits a clone of the live state and the screen
    /// rows; both commit together, then the clone replaces the live state.
    /// Returns `mutate`'s output (`None` on a replay, which runs nothing).
    pub(crate) fn commit_screen_request<R>(
        self: &Arc<Self>,
        request: StripRequest,
        mutate: impl FnOnce(&Arc<Mux>, &mut State, &mut ScreenEdit) -> anyhow::Result<R>,
    ) -> anyhow::Result<(Option<R>, ResourcePatchCommit)> {
        let mux = Arc::clone(self);
        let mut output = None;
        let mut retarget = Vec::new();
        let commit = self.commit_resource_mutation_plan(
            &request.mutation,
            &request.operation,
            &request.fingerprint,
            None,
            request.expected_revision,
            |state, registry| {
                let mut projected = state.clone();
                let before = mux.presentation_snapshot().screens.clone();
                let mut edit = ScreenEdit { screens: before.clone(), result: ScreenResult::None };
                let result = mutate(&mux, &mut projected, &mut edit)?;
                screen_groups::prune_screen_state(&projected, &mut edit.screens);
                for workspace in &mut projected.workspaces {
                    screen_groups::normalize_screen_order(workspace, &edit.screens);
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
                let write = screen_rows_write(&before, edit);
                let mut plan = ResourceMutationPlan::replacing(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    projected,
                )
                .with_state_write(write);
                if let Some(ledger) = ledger {
                    plan = plan.with_workspace_ledger(ledger);
                }
                Ok(plan)
            },
        )?;
        if !commit.replayed {
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
        }
        Ok((output, commit))
    }

    /// Commit screen rows that leave screen order alone (color, icon, group
    /// name, color and collapsed state, ungroup, saved links).
    pub(crate) fn commit_screen_rows<R>(
        &self,
        request: StripRequest,
        mutate: impl FnOnce(&State, &mut ScreenEdit) -> anyhow::Result<R>,
    ) -> anyhow::Result<(Option<R>, StateCommit)> {
        let mut output = None;
        let commit = self.commit_state(
            &request.mutation,
            &request.operation,
            &request.fingerprint,
            request.expected_revision,
            StateEffects::PRESENTATION,
            |transaction, state| {
                let before = self.presentation_snapshot().screens.clone();
                let mut edit = ScreenEdit { screens: before.clone(), result: ScreenResult::None };
                output = Some(mutate(state, &mut edit)?);
                screen_groups::prune_screen_state(state, &mut edit.screens);
                let mut result = Value::Null;
                let mut changes = Vec::new();
                screen_rows_write(&before, edit)(transaction, &mut result, &mut changes)?;
                Ok(StateChanges::new(result, changes))
            },
        )?;
        if !commit.replayed {
            self.publish_journal_event();
        }
        Ok((output, commit))
    }

    /// The v2 screen operations: `screen.update`, `screen.move`, and
    /// `screen_group.create|add_screens|remove_screens|update|ungroup`.
    pub(crate) fn state_screen_change(
        self: &Arc<Self>,
        request: StripRequest,
        change: ScreenChange,
    ) -> anyhow::Result<StateCommit> {
        let screen_of = |selectors: &crate::ResourceSelectors| -> anyhow::Result<ScreenId> {
            let resolved = self.resolve_resource_path(crate::ResourceTarget::Screen, selectors)?;
            let public = resolved.screen.context("screen selector resolved no screen")?;
            self.screen_id_of(public.as_str())
                .ok_or_else(|| state_not_found("screen", public.as_str()))
        };
        let screens_of = |ids: &[String]| -> anyhow::Result<Vec<ScreenId>> {
            anyhow::ensure!(!ids.is_empty(), "bad request: screens is empty");
            ids.iter()
                .map(|id| self.screen_id_of(id).ok_or_else(|| state_not_found("screen", id)))
                .collect()
        };
        Ok(match change {
            ScreenChange::Update { selectors, update } => {
                update.validate()?;
                let screen = screen_of(&selectors)?;
                self.update_screen_presentation(request, screen, update)?
            }
            ScreenChange::Move { selectors, index } => {
                let screen = screen_of(&selectors)?;
                self.move_screen_block_request(
                    request,
                    &[screen],
                    ScreenDestination::Workspace { workspace: None, index: Some(index) },
                    true,
                )?
                .into()
            }
            ScreenChange::GroupCreate { screens, name, color } => {
                let screens = screens_of(&screens)?;
                self.create_screen_group_request(request, &screens, Some(name), Some(color))?
                    .1
                    .into()
            }
            ScreenChange::GroupAdd { group, screens } => {
                let screens = screens_of(&screens)?;
                self.add_screens_request(request, &group, &screens, None)?.into()
            }
            ScreenChange::GroupRemove { screens } => {
                let screens = screens_of(&screens)?;
                self.remove_screens_request(request, &screens)?.1.into()
            }
            ScreenChange::GroupUpdate { group, name, color, collapsed } => {
                self.update_screen_group_request(request, &group, name, color, collapsed)?
            }
            ScreenChange::GroupUngroup { group } => {
                self.ungroup_screen_group_request(request, &group)?.1
            }
        })
    }

    /// Set a screen's color, icon, and pin in one commit. Pinning reorders
    /// (pinned screens first) and leaves the screen's group.
    pub(crate) fn update_screen_presentation(
        self: &Arc<Self>,
        request: StripRequest,
        screen: ScreenId,
        update: ScreenMetaUpdate,
    ) -> anyhow::Result<StateCommit> {
        update.validate()?;
        let edit_rows = move |state: &State, edit: &mut ScreenEdit| -> anyhow::Result<bool> {
            let public = screen_groups::screen_public_id(state, screen)?;
            let before = edit.screens.screen(&public).cloned().unwrap_or_default();
            edit.screens.edit(&public, |record| {
                if let Some(color) = update.color {
                    record.color = color;
                }
                if let Some(icon) = update.icon {
                    record.icon = icon;
                }
                if let Some(pinned) = update.pinned {
                    record.pinned = pinned;
                }
            });
            if update.pinned == Some(true) {
                edit.screens.members.remove(&public);
            }
            let changed = edit.screens.screen(&public).cloned().unwrap_or_default() != before;
            edit.result = ScreenResult::Screen(public);
            Ok(changed)
        };
        let (changed, commit) = if update.pinned.is_some() {
            let (changed, commit) =
                self.commit_screen_request(request, |_, state, edit| edit_rows(state, edit))?;
            (changed, commit.into())
        } else {
            self.commit_screen_rows(request, edit_rows)?
        };
        if changed.unwrap_or(false) {
            self.emit_screen_changed(&[screen]);
        }
        Ok(commit)
    }
}
