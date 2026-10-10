//! One durable commit for a tab strip change: tab order and placements (the
//! resource patch), tab groups, pins, tab state, and saved groups, in one
//! transaction with one idempotency record. Raw tab group commands use a
//! local mutation; v2 operations pass their idempotency key, so a retry
//! replays the stored result.
//!
//! `mutate` edits a clone of the live state plus a [`StripEdit`]; the clone
//! replaces the live state only after the commit. The batch restates every
//! tab whose group or pin changed and every tab group the change touched,
//! so `session.events` readers converge without refetching.

use std::collections::BTreeSet;

use super::tab_drag;
use super::tab_groups::prune_tab_groups;
use super::*;
use crate::state::store::{state_delete, state_upsert};
use crate::state::tab_state_store::{
    TabStateUpdate, put_saved_tab_group, saved_tab_group_snapshot, set_tab_pinned,
    tab_group_snapshot, update_tab_state, write_tab_groups,
};
use crate::state::values::{fresh_upserts, upserted_value};
use crate::workspace_registry::{SavedTabGroupRecord, TabGroupState, WorkspacePresentationUpdate};

/// The durable identity of one strip change.
pub(crate) struct StripRequest {
    pub(crate) mutation: WorkspaceMutation,
    pub(crate) operation: String,
    pub(crate) fingerprint: Value,
    pub(crate) expected_revision: Option<u64>,
}

impl StripRequest {
    /// A raw command: a fresh local mutation that never replays.
    pub(crate) fn local(operation: &str) -> Self {
        Self {
            mutation: WorkspaceMutation::local("cmux-tui-tab-groups"),
            operation: operation.to_string(),
            fingerprint: serde_json::json!({
                "operation": operation,
                "nonce": crate::workspace_registry::new_uuid_v4(),
            }),
            expected_revision: None,
        }
    }
}

/// What a strip change returns as its v2 result.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum StripResult {
    #[default]
    None,
    /// The `TabSnapshot` of a tab (public id).
    Tab(String),
    /// The `TabGroupSnapshot` of a group.
    Group(String),
    /// The snapshots of the groups that still exist.
    Groups(Vec<String>),
    /// `TabGroupReleaseResult`: a group's former members.
    Release { group: String, tabs: Vec<String> },
    /// The `SavedTabGroupSnapshot` of a saved group.
    Saved(String),
}

/// State rows a strip change writes besides the topology.
pub(crate) struct StripEdit {
    pub(crate) groups: TabGroupState,
    /// Public tab id to its new pinned flag.
    pub(crate) pins: Vec<(String, bool)>,
    pub(crate) tab_state: Vec<(String, TabStateUpdate)>,
    pub(crate) saved: Option<SavedTabGroupRecord>,
    pub(crate) result: StripResult,
}

impl Mux {
    /// Commit a tab strip change. Returns `mutate`'s output (`None` on a
    /// replay, which runs nothing) and the commit.
    pub(crate) fn commit_tab_strip_change<R>(
        self: &Arc<Self>,
        request: StripRequest,
        workspace_group: Option<String>,
        mutate: impl FnOnce(&Arc<Mux>, &mut State, &mut StripEdit) -> anyhow::Result<R>,
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
                let presentation = mux.presentation_snapshot();
                let mut edit = StripEdit {
                    groups: presentation.tab_groups.clone(),
                    pins: Vec::new(),
                    tab_state: Vec::new(),
                    saved: None,
                    result: StripResult::None,
                };
                let result = mutate(&mux, &mut projected, &mut edit)?;
                Mux::rebuild_split_screen_index(&mut projected);
                prune_tab_groups(&projected, &mut edit.groups);
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
                let write = strip_state_write(&presentation, edit);
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
}

/// The in-transaction write of a strip edit: rows, restatements, result.
fn strip_state_write(
    before: &crate::workspace_registry::PresentationSnapshot,
    edit: StripEdit,
) -> crate::resource_mutation::PlanStateWrite {
    let StripEdit { groups, pins, tab_state, saved, result: result_kind } = edit;
    let mut touched_tabs = BTreeSet::new();
    for (tab, group) in &before.tab_groups.members {
        if groups.members.get(tab) != Some(group) {
            touched_tabs.insert(tab.clone());
        }
    }
    for tab in groups.members.keys() {
        if !before.tab_groups.members.contains_key(tab) {
            touched_tabs.insert(tab.clone());
        }
    }
    for (tab, pinned) in &pins {
        if before.pinned_tabs.contains(tab) != *pinned {
            touched_tabs.insert(tab.clone());
        }
    }
    touched_tabs.extend(tab_state.iter().map(|(tab, _)| tab.clone()));
    if let StripResult::Tab(tab) = &result_kind {
        touched_tabs.insert(tab.clone());
    }
    let mut touched_groups = before.tab_groups.groups.keys().cloned().collect::<BTreeSet<_>>();
    touched_groups.extend(groups.groups.keys().cloned());
    let changed_groups = touched_groups
        .into_iter()
        .filter(|id| {
            before.tab_groups.groups.get(id) != groups.groups.get(id) || {
                let members_before =
                    before.tab_groups.members.iter().filter(|(_, g)| *g == id).count();
                let members_after = groups.members.iter().filter(|(_, g)| *g == id).count();
                members_before != members_after
            }
        })
        .collect::<Vec<_>>();
    let touched_tabs = touched_tabs.into_iter().collect::<Vec<_>>();
    Box::new(move |transaction, result, changes| {
        write_tab_groups(transaction, &groups)?;
        for (tab, pinned) in &pins {
            set_tab_pinned(transaction, tab, *pinned)?;
        }
        for (tab, update) in &tab_state {
            update_tab_state(transaction, tab, update)?;
        }
        if let Some(saved) = &saved {
            put_saved_tab_group(transaction, saved)?;
            if let Some(snapshot) = saved_tab_group_snapshot(transaction, &saved.id)? {
                changes.push(state_upsert("saved_tab_group", &saved.id, snapshot));
            }
        }
        let fresh = fresh_upserts(transaction, &[], &[], &touched_tabs)?;
        // Moved tabs are also topology changes; they move with the group,
        // so restate their group.
        let moved_tabs = changes
            .iter()
            .filter(|change| change["kind"] == "upsert" && change["resource"] == "tab")
            .filter_map(|change| change["id"].as_str().map(str::to_string))
            .collect::<BTreeSet<_>>();
        let mut group_ids = changed_groups.clone();
        for (tab, group) in &groups.members {
            if moved_tabs.contains(tab) && !group_ids.contains(group) {
                group_ids.push(group.clone());
            }
        }
        changes.extend(fresh.iter().cloned());
        for id in &group_ids {
            match tab_group_snapshot(transaction, id)? {
                Some(snapshot) => changes.push(state_upsert("tab_group", id, snapshot)),
                None => changes.push(state_delete("tab_group", id)),
            }
        }
        *result = match &result_kind {
            StripResult::None => result.clone(),
            StripResult::Tab(tab) => upserted_value(&fresh, "tab", tab)
                .ok_or_else(|| crate::state::commit::state_not_found("tab", tab))?,
            StripResult::Group(group) => tab_group_snapshot(transaction, group)?
                .ok_or_else(|| crate::state::commit::state_not_found("tab_group", group))?,
            StripResult::Groups(ids) => {
                let mut values = Vec::new();
                for id in ids {
                    if let Some(snapshot) = tab_group_snapshot(transaction, id)? {
                        values.push(snapshot);
                    }
                }
                Value::Array(values)
            }
            StripResult::Release { group, tabs } => {
                serde_json::json!({"tab_group_id": group, "tab_ids": tabs})
            }
            StripResult::Saved(saved) => saved_tab_group_snapshot(transaction, saved)?
                .ok_or_else(|| crate::state::commit::state_not_found("saved_tab_group", saved))?,
        };
        Ok(())
    })
}
