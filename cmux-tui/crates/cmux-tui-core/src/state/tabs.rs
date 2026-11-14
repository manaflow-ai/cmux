//! v2 tab state: pins, per-tab zoom and browser history, tab groups, and
//! the personal saved tab groups. Every mutation commits through
//! [`Mux::commit_tab_strip_change`] (tab order changes) or
//! [`Mux::commit_state`] (rows only), keyed by the request's idempotency key.
//! `tab.update` writes one tab's rows, so it is a rows-only commit: its cost
//! does not follow the size of the session.

use crate::Actor;
use crate::mux::tab_groups::{pane_by_public_id, tab_public_id};
use crate::mux::tab_strip::{StripRequest, StripResult};
use crate::mux::*;
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};
use crate::state::tab_state_store::{
    TabStateUpdate, delete_saved_tab_group, saved_tab_group, tab_attention_record, tab_group_ids,
    tab_group_snapshot, update_tab_state,
};
use crate::state::values::{fresh_upserts, upserted_value};

/// Advertises `icon` on `tab_group.update`, `TabGroupSnapshot`,
/// `SavedTabGroupSnapshot` and the raw `update-tab-group` and tab group runs.
pub(crate) const TAB_GROUP_ICON_CAPABILITY: &str = "tab-group-icon-v1";

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

/// `tab.update` found no stored row of a tab the session holds, so the rows
/// commit has no value to restate. The request then commits through the tab
/// strip commit, which writes the session's topology with the record.
#[derive(Debug)]
struct TabRowNotStored;

impl std::fmt::Display for TabRowNotStored {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("the tab has no stored row")
    }
}

impl std::error::Error for TabRowNotStored {}

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
                    // A browser tab keeps the page it is pinned on (Back to Pinned Page).
                    let url = pinned
                        .then(|| {
                            state.surfaces.get(&surface).and_then(|surface| surface.browser_url())
                        })
                        .flatten();
                    edit.pins.push((tab.clone(), pinned, url));
                }
                edit.result = StripResult::Tab(tab);
                Ok(())
            })?;
        Ok(commit)
    }

    /// `tab.update`: one tab's record (zoom, icon, unread mark, attention
    /// mark, a browser tab's back/forward lists, emulation and owner).
    ///
    /// A rows-only commit ([`Self::commit_state_refreshing`]): under the
    /// registry lock it resolves the tab (the state lock covers only that),
    /// writes the tab's rows, restates the tab by point reads and patches the
    /// two presentation cache fields a tab's record feeds. It clones no
    /// session state, projects no workspace and reads no whole topology or
    /// presentation, so its cost is the same on a session of any size
    /// (AGENT TRAFFIC 800: at 826 workspaces the tab strip commit held both
    /// locks for the whole session's projection).
    pub(crate) fn state_update_tab(
        self: &Arc<Self>,
        request: StripRequest,
        selectors: crate::ResourceSelectors,
        update: TabStateUpdate,
    ) -> anyhow::Result<ResourcePatchCommit> {
        update.validate()?;
        // An asset icon names a blob this daemon stores (as a new screen's icon does).
        if let Some(Some(icon)) = &update.icon {
            self.with_icon_registry(|registry| registry.require_icon_asset(icon))?;
        }
        let StripRequest { mutation, operation, fingerprint, expected_revision } = request;
        // What the commit wrote that the presentation cache holds.
        let written = std::cell::RefCell::new(None);
        let committed = self.commit_state_refreshing(
            &mutation,
            &operation,
            &fingerprint,
            expected_revision,
            true,
            |transaction, state| {
                let (tab, browser, update) =
                    self.tab_record_update(state, &selectors, update.clone())?;
                // No stored row of this tab yet: write nothing here (an
                // `owner` update would fail on the browser row it lacks).
                let stored: bool = transaction.query_row(
                    "SELECT EXISTS(SELECT 1 FROM resource_tabs WHERE public_id = ?1)",
                    [tab.as_str()],
                    |row| row.get(0),
                )?;
                if !stored {
                    return Err(TabRowNotStored.into());
                }
                update_tab_state(transaction, &tab, &update)?;
                let changes = fresh_upserts(transaction, &[], &[], std::slice::from_ref(&tab))?;
                let value = upserted_value(&changes, "tab", &tab).ok_or(TabRowNotStored)?;
                // The mark as stored: a stale request id leaves the old one.
                let attention = match update.attention {
                    Some(_) => Some(tab_attention_record(transaction, &tab)?),
                    None => None,
                };
                let owner = browser.zip(update.owner);
                *written.borrow_mut() = Some((tab, attention, owner));
                Ok(StateChanges::new(value, changes))
            },
            |_| {
                if let Some((tab, attention, owner)) = written.take() {
                    self.patch_tab_presentation(&tab, attention, owner);
                }
                Ok(())
            },
        );
        let commit = match committed {
            Ok(commit) => commit,
            Err(error) if error.is::<TabRowNotStored>() => {
                // The store holds no row of this tab yet: the transaction
                // rolled back, and the whole-session commit writes the
                // topology with the record.
                let request = StripRequest { mutation, operation, fingerprint, expected_revision };
                let (_, commit) =
                    self.commit_tab_strip_change(request, None, move |mux, state, edit| {
                        let (tab, _, update) = mux.tab_record_update(state, &selectors, update)?;
                        edit.tab_state.push((tab.clone(), update));
                        edit.result = StripResult::Tab(tab);
                        Ok(())
                    })?;
                return Ok(commit);
            }
            Err(error) => return Err(error),
        };
        Ok(ResourcePatchCommit {
            revision: commit.revision,
            result: commit.result,
            replayed: commit.replayed,
        })
    }

    /// What `tab.update` reads from the locked session: the tab's public id,
    /// its frontend browser (the only tab an owner applies to), and `update`
    /// with the page a new attention mark is set on. Refuses a field the
    /// tab's kind does not hold.
    fn tab_record_update(
        &self,
        state: &State,
        selectors: &crate::ResourceSelectors,
        mut update: TabStateUpdate,
    ) -> anyhow::Result<(String, Option<crate::resource::BrowserPublicId>, TabStateUpdate)> {
        let resolved = self.resolve_in_state(state, crate::ResourceTarget::Tab, selectors)?;
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
        anyhow::ensure!(
            browser || update.emulation.is_none(),
            "bad request: device emulation applies only to browser tabs"
        );
        if update.back.is_some() || update.forward.is_some() {
            let runtime = state.surfaces.get(&surface).context("tab has no surface")?;
            self.refuse_conversation_tab(runtime)?;
        }
        let frontend =
            state.surfaces.get(&surface).and_then(|runtime| self.frontend_browser_id(runtime));
        anyhow::ensure!(
            frontend.is_some() || update.owner.is_none(),
            "bad request: owner applies only to frontend browser tabs"
        );
        // tab-attention-v1: a browser tab's new mark records the page
        // it was set on, so only a later page clears it.
        if matches!(update.attention, Some(Some(_))) {
            update.attention_page = state
                .surfaces
                .get(&surface)
                .and_then(|runtime| runtime.as_browser())
                .map(|browser| browser.url())
                .filter(|url| !url.is_empty());
        }
        Ok((tab, frontend, update))
    }

    /// `tab-attention-v1`: a browser tab now on `page` drops an attention
    /// mark set on another page, since the page the agent asked the person to
    /// act on is gone (the person confirmed, logged in, or left). One read
    /// when the tab holds no such mark; otherwise a commit that decides again
    /// in its own transaction (a mark set on `page` meanwhile stays) and
    /// restates the tab when it cleared one.
    pub(crate) fn clear_attention_after_navigation(
        &self,
        actor: &Actor,
        surface: SurfaceId,
        page: &str,
    ) {
        if page.is_empty() {
            return;
        }
        let Some(tab) = self.with_state(|state| {
            state.resource_indexes.tab_ids.get(&surface).map(|id| id.as_str().to_string())
        }) else {
            return;
        };
        let marked = self.personal_state_read(|connection| {
            crate::state::tab_state_store::tab_has_attention_off_page(connection, &tab, page)
        });
        if !matches!(marked, Ok(true)) {
            return;
        }
        let fingerprint = serde_json::json!({
            "operation": "tab.attention.navigated",
            "tab": tab,
            "nonce": crate::workspace_registry::new_uuid_v4(),
        });
        let result = self.commit_state(
            &WorkspaceMutation::local("cmux-tui-tab-attention", actor.clone()),
            "tab.attention.navigated",
            &fingerprint,
            None,
            StateEffects::PRESENTATION,
            |transaction, state| {
                // A late callback for a page the tab has already left clears
                // nothing: the mark may be the newer page's, set since.
                let current = state
                    .surfaces
                    .get(&surface)
                    .and_then(|runtime| runtime.as_browser())
                    .map(|browser| browser.url());
                let cleared = current.as_deref() == Some(page)
                    && crate::state::tab_state_store::clear_attention_off_page(
                        transaction,
                        &tab,
                        page,
                    )?;
                let restated: &[String] = if cleared { std::slice::from_ref(&tab) } else { &[] };
                let changes = fresh_upserts(transaction, &[], &[], restated)?;
                Ok(StateChanges::new(serde_json::json!({"tab": tab, "cleared": cleared}), changes))
            },
        );
        if let Err(error) = result {
            eprintln!(
                "cmux-tui: clearing the attention mark of {tab} after navigation failed: {error:#}"
            );
        }
    }

    /// Store the owner (hosting app's install id) of a frontend-rendered
    /// browser tab on its record, restating the tab on `session.events`.
    /// The raw `update-frontend-browser-tab {owner}` path; `tab.update`
    /// writes the same column in its own rows commit.
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
                update_tab_state(transaction, tab, &update)?;
                let changes = fresh_upserts(transaction, &[], &[], &[tab.to_string()])?;
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
            None,
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
