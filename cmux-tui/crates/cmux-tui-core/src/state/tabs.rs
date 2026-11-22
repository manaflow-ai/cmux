//! v2 tab state: pins, per-tab zoom and browser history, tab groups, and
//! the personal saved tab groups. Every mutation commits through
//! [`Mux::commit_tab_strip_change`] (tab order changes) or
//! [`Mux::commit_state`] (rows only), keyed by the request's idempotency key.

use crate::Actor;
use crate::mux::tab_groups::{pane_by_public_id, tab_public_id};
use crate::mux::tab_strip::{StripRequest, StripResult};
use crate::mux::*;
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};
use crate::state::tab_state_store::{
    TabStateUpdate, delete_saved_tab_group, saved_tab_group, tab_group_ids, tab_group_snapshot,
};

/// Resolve public tab ids against a locked state, in request order.
pub(crate) fn resolve_tabs(state: &State, tabs: &[String]) -> anyhow::Result<Vec<SurfaceId>> {
    tabs.iter()
        .map(|tab| {
            let id = TabPublicId::parse(tab.clone())?;
            state
                .resource_indexes
                .tabs
                .get(&id)
                .copied()
                .ok_or_else(|| anyhow::Error::new(ResourceError::not_found("tab", tab)))
        })
        .collect()
}

impl Mux {
    /// `tab.pin` / `tab.unpin`. A pinned tab leaves its group and moves to
    /// the end of its pane's pinned run; an unpinned tab moves to the start
    /// of the unpinned run.
    pub(crate) fn state_pin_tab(
        self: &Arc<Self>,
        request: StripRequest,
        selectors: crate::ResourceSelectors,
        pinned: bool,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let (_, commit) =
            self.commit_tab_strip_change(request, None, move |mux, state, edit| {
                let resolved =
                    mux.resolve_in_state(state, crate::ResourceTarget::Tab, &selectors)?;
                let surface = resolved.tab.context("tab selector resolved no tab")?;
                let tab = tab_public_id(state, surface)?;
                let presentation = mux.presentation_snapshot();
                let pane = state.pane_of(surface).context("tab has no pane")?;
                let other_pinned = state.panes[&pane]
                    .tabs
                    .iter()
                    .filter(|candidate| **candidate != surface)
                    .filter(|candidate| {
                        state
                            .resource_indexes
                            .tab_ids
                            .get(candidate)
                            .is_some_and(|id| presentation.pinned_tabs.contains(id.as_str()))
                    })
                    .count();
                let unchanged = presentation.pinned_tabs.contains(tab.as_str()) == pinned;
                if !unchanged {
                    if pinned {
                        edit.groups.members.remove(&tab);
                    }
                    tab_groups::place_block(state, pane, &[surface], other_pinned);
                    edit.pins.push((tab.clone(), pinned));
                }
                edit.result = StripResult::Tab(tab);
                Ok(())
            })?;
        Ok(commit)
    }

    /// `tab.update`: zoom and a browser tab's back/forward lists.
    pub(crate) fn state_update_tab(
        self: &Arc<Self>,
        request: StripRequest,
        selectors: crate::ResourceSelectors,
        update: TabStateUpdate,
    ) -> anyhow::Result<ResourcePatchCommit> {
        update.validate()?;
        let (_, commit) =
            self.commit_tab_strip_change(request, None, move |mux, state, edit| {
                let resolved =
                    mux.resolve_in_state(state, crate::ResourceTarget::Tab, &selectors)?;
                let surface = resolved.tab.context("tab selector resolved no tab")?;
                let tab = tab_public_id(state, surface)?;
                let browser = state
                    .surfaces
                    .get(&surface)
                    .is_some_and(|runtime| runtime.kind() == SurfaceKind::Browser);
                anyhow::ensure!(
                    browser || (update.back.is_none() && update.forward.is_none()),
                    "bad request: back and forward apply only to browser tabs"
                );
                if update.back.is_some() || update.forward.is_some() {
                    let runtime = state.surfaces.get(&surface).context("tab has no surface")?;
                    mux.refuse_conversation_tab(runtime)?;
                }
                let frontend = state
                    .surfaces
                    .get(&surface)
                    .is_some_and(|runtime| mux.frontend_browser_id(runtime).is_some());
                anyhow::ensure!(
                    frontend || update.owner.is_none(),
                    "bad request: owner applies only to frontend browser tabs"
                );
                edit.tab_state.push((tab.clone(), update));
                edit.result = StripResult::Tab(tab);
                Ok(())
            })?;
        Ok(commit)
    }

    /// Store the owner (hosting app's install id) of a frontend-rendered
    /// browser tab on its record, restating the tab on `session.events`.
    /// The raw `update-frontend-browser-tab {owner}` path; `tab.update`
    /// writes the same column through the tab strip commit.
    pub(crate) fn commit_browser_owner(
        &self,
        actor: &Actor,
        tab: &str,
        owner: &str,
    ) -> anyhow::Result<()> {
        crate::state::window_record_store::validate_key("owner", owner)?;
        let fingerprint = serde_json::json!({
            "operation": "browser.owner.set",
            "tab": tab,
            "owner": owner,
            "nonce": crate::workspace_registry::new_uuid_v4(),
        });
        self.commit_state(
            &WorkspaceMutation::local("cmux-tui-browser-owner", actor.clone()),
            "browser.owner.set",
            &fingerprint,
            None,
            StateEffects::PRESENTATION,
            |transaction, _| {
                let update =
                    TabStateUpdate { owner: Some(owner.to_string()), ..Default::default() };
                crate::state::tab_state_store::update_tab_state(transaction, tab, &update)?;
                let changes =
                    crate::state::values::fresh_upserts(transaction, &[], &[], &[tab.to_string()])?;
                Ok(StateChanges::new(serde_json::json!({"tab": tab}), changes))
            },
        )?;
        Ok(())
    }

    /// `tab_group.create`.
    pub(crate) fn state_create_tab_group(
        self: &Arc<Self>,
        request: StripRequest,
        tabs: Vec<String>,
        name: Option<String>,
        color: Option<String>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.tab_group_create(
            request,
            move |state| resolve_tabs(state, &tabs),
            name,
            color,
            crate::workspace_registry::new_tab_group_id(),
        )
    }

    /// `tab_group.add_tabs`.
    pub(crate) fn state_add_tabs_to_group(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
        tabs: Vec<String>,
        index: Option<usize>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.tab_group_add(request, group, move |state| resolve_tabs(state, &tabs), index)
    }

    /// `tab_group.remove_tabs`.
    pub(crate) fn state_remove_tabs_from_groups(
        self: &Arc<Self>,
        request: StripRequest,
        tabs: Vec<String>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.tab_group_remove(request, move |state| resolve_tabs(state, &tabs))
            .map(|(_, commit)| commit)
    }

    /// `tab_group.move`. A pane id that names no live pane is not found.
    pub(crate) fn state_move_tab_group(
        self: &Arc<Self>,
        request: StripRequest,
        group: &str,
        pane: Option<String>,
        index: Option<usize>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.tab_group_move_to_strip(request, group, pane, index)
    }

    /// `saved_tab_group.delete` (and raw `delete-saved-tab-group`): the
    /// record goes, and live groups linked to it stay, unlinked.
    pub(crate) fn saved_tab_group_delete(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        saved_id: &str,
        local: bool,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = serde_json::json!({
            "operation": "saved_tab_group.delete",
            "saved_tab_group": saved_id,
            "nonce": local.then(crate::workspace_registry::new_uuid_v4),
        });
        self.commit_state(
            mutation,
            "saved_tab_group.delete",
            &fingerprint,
            expected_revision,
            StateEffects::PRESENTATION,
            |transaction, _| {
                let linked = tab_group_ids(transaction)?
                    .into_iter()
                    .filter(|id| {
                        tab_group_snapshot(transaction, id).ok().flatten().is_some_and(|group| {
                            group["saved_tab_group_id"].as_str() == Some(saved_id)
                        })
                    })
                    .collect::<Vec<_>>();
                let deleted = delete_saved_tab_group(transaction, saved_id)?;
                let mut changes = Vec::new();
                if deleted {
                    changes.push(state_delete("saved_tab_group", saved_id));
                    for id in linked {
                        if let Some(group) = tab_group_snapshot(transaction, &id)? {
                            changes.push(state_upsert("tab_group", &id, group));
                        }
                    }
                }
                Ok(StateChanges::new(
                    serde_json::json!({"id": saved_id, "deleted": deleted}),
                    changes,
                ))
            },
        )
    }

    /// `saved_tab_group.reopen`. Reopening composes several creations, so
    /// the request's key guards the whole: a retry returns the recorded
    /// result, and a reopen whose saved group already has a live group
    /// returns that group.
    pub(crate) fn state_reopen_saved_tab_group(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        saved_id: &str,
        pane: Option<String>,
    ) -> anyhow::Result<StateCommit> {
        const OPERATION: &str = "saved_tab_group.reopen";
        let fingerprint = serde_json::json!({
            "operation": OPERATION,
            "saved_tab_group": saved_id,
            "pane_id": pane,
        });
        if let Some(replay) = self.workspace_registry.lock().unwrap().replay_resource_patch(
            mutation,
            OPERATION,
            &fingerprint,
        )? {
            return Ok(replay.into());
        }
        if self.read_registry_state(|connection| saved_tab_group(connection, saved_id))?.is_none() {
            return Err(state_not_found("saved_tab_group", saved_id));
        }
        let target = match &pane {
            Some(pane) => self
                .with_state(|state| pane_by_public_id(state, pane))
                .ok_or_else(|| anyhow::Error::new(ResourceError::not_found("pane", pane)))?,
            None => self
                .with_state(|state| state.active_pane())
                .context("no focused pane to reopen into")?,
        };
        let outcome = self.reopen_saved_tab_group_as(&mutation.actor, saved_id, target, None)?;
        let group = outcome.group.context("reopened group is missing")?.id;
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let snapshot = tab_group_snapshot(transaction, &group)?
                    .ok_or_else(|| state_not_found("tab_group", &group))?;
                Ok(StateChanges::new(
                    serde_json::json!({"saved_tab_group_id": saved_id, "tab_group": snapshot}),
                    Vec::new(),
                ))
            },
        )
    }

    /// A v2 strip request for `operation` with a canonical fingerprint.
    pub(crate) fn strip_request(
        mutation: WorkspaceMutation,
        operation: &str,
        fingerprint: Value,
        expected_revision: Option<u64>,
    ) -> StripRequest {
        StripRequest { mutation, operation: operation.to_string(), fingerprint, expected_revision }
    }
}
