use anyhow::Context;
use serde_json::{Value, json};

use std::collections::{HashMap, HashSet};

use super::{Mux, ResourceMutationMetrics, ResourceMutationPlan};
use crate::browser::{BrowserSource, BrowserStatus};
use crate::model::{Node, State};
use crate::resource::{ContentPublicId, PanePublicId, SplitPublicId, WorkspacePublicId};
use crate::workspace_registry::{
    RegistryBrowser, RegistryBrowserLaunch, RegistryBrowserSource, RegistryBrowserStatus,
    RegistryLayoutNode, RegistryPane, RegistryScreen, RegistryTab, RegistryViewport,
    RegistryViewportColumn, RegistryWorkspace, ResourceChange, ResourcePatch, ResourcePatchCommit,
    WorkspaceMutation, WorkspaceRegistry,
};
use crate::{ResourceSelectors, ResourceTarget};

impl Mux {
    pub(crate) fn resource_move_terminal_selected(
        self: &std::sync::Arc<Self>,
        selectors: ResourceSelectors,
        destination: ResourceSelectors,
        index: usize,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = json!({
            "operation": "terminal.move",
            "selectors": selectors,
            "destination": destination,
            "index": index,
        });
        let commit = self.commit_resource_mutation_plan(
            mutation,
            "terminal.move",
            &fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let source = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Terminal,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let target = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &destination,
                    )
                    .map_err(anyhow::Error::new)?;
                let surface =
                    source.tab.context("terminal selector did not resolve a live surface")?;
                let source_pane_slot =
                    source.pane.context("terminal selector did not resolve a source pane")?;
                let target_pane_slot =
                    target.pane.context("destination did not resolve a live pane")?;
                let terminal_id = source
                    .path
                    .terminal
                    .clone()
                    .context("terminal selector omitted its public identity")?;
                let target_workspace_slot =
                    target.workspace.context("destination did not resolve a workspace")?;
                let target_workspace_index = state
                    .workspace_index(target_workspace_slot)
                    .context("destination workspace disappeared")?;
                let target_workspace = &state.workspaces[target_workspace_index];
                let target_workspace_key = target_workspace.key.clone();
                let target_workspace_id = target_workspace.public_id.clone();
                let target_screen_slot =
                    target.screen.context("destination did not resolve a screen")?;
                let target_screen_id =
                    target.path.screen.clone().context("destination omitted its screen id")?;
                let target_pane_id = target.path.pane.context("destination omitted its pane id")?;

                let topology = registry.resource_topology_snapshot()?;
                let snapshot = registry.snapshot()?;
                let source_tab = topology
                    .tabs
                    .iter()
                    .find(|tab| tab.content_id == ContentPublicId::Terminal(terminal_id.clone()))
                    .cloned()
                    .context("terminal has no durable tab")?;
                let terminal_surface = state
                    .surfaces
                    .get(&surface)
                    .context("terminal selector resolved a missing surface")?;
                let (terminal_cols, terminal_rows) = terminal_surface.size();
                let mut terminal_value = json!({
                    "id":terminal_id,
                    "tab_id":source_tab.public_id,
                    "title":terminal_surface.title(),
                    "cols":terminal_cols.max(1),
                    "rows":terminal_rows.max(1),
                    "running":!terminal_surface.is_dead(),
                });
                if let Some(cwd) = terminal_surface.spawn_cwd() {
                    terminal_value["cwd"] = json!(cwd);
                }
                let source_pane_id = source_tab.pane_id.clone();
                let structural = source_pane_slot != target_pane_slot
                    && state.panes.get(&source_pane_slot).is_some_and(|pane| pane.tabs.len() == 1);
                if structural {
                    return super::resource_topology::structural_tab_move_plan(
                        self,
                        state,
                        registry,
                        surface,
                        source_tab.public_id,
                        source_pane_slot,
                        target_pane_slot,
                        index,
                        json!({"terminal":terminal_id,"value":terminal_value}),
                    );
                }
                let mut source_pane = topology
                    .panes
                    .iter()
                    .find(|pane| pane.public_id == source_pane_id)
                    .cloned()
                    .context("terminal tab has no durable source pane")?;
                let mut target_pane = if target_pane_id == source_pane_id {
                    source_pane.clone()
                } else {
                    topology
                        .panes
                        .iter()
                        .find(|pane| pane.public_id == target_pane_id)
                        .cloned()
                        .context("destination has no durable pane")?
                };

                let mut source_tabs = ordered_tabs(&topology.tabs, &source_pane_id);
                let old_index = source_tabs
                    .iter()
                    .position(|tab| tab.public_id == source_tab.public_id)
                    .context("terminal tab is absent from its pane order")?;
                let mut target_tabs = if target_pane_id == source_pane_id {
                    Vec::new()
                } else {
                    ordered_tabs(&topology.tabs, &target_pane_id)
                };
                let moved = source_tabs.remove(old_index);
                let new_index = if target_pane_id == source_pane_id {
                    let adjusted = if index > old_index { index.saturating_sub(1) } else { index };
                    adjusted.min(source_tabs.len())
                } else {
                    index.min(target_tabs.len())
                };
                if target_pane_id == source_pane_id {
                    source_tabs.insert(new_index, moved);
                } else {
                    target_tabs.insert(new_index, moved);
                }

                reindex_tabs(&mut source_tabs, &source_pane_id);
                if target_pane_id != source_pane_id {
                    reindex_tabs(&mut target_tabs, &target_pane_id);
                }
                source_pane.active_tab = source_tabs
                    .get(
                        source_pane
                            .active_tab
                            .as_ref()
                            .and_then(|active| {
                                source_tabs.iter().position(|tab| &tab.public_id == active)
                            })
                            .unwrap_or_else(|| old_index.min(source_tabs.len().saturating_sub(1))),
                    )
                    .map(|tab| tab.public_id.clone());
                if target_pane_id == source_pane_id {
                    source_pane.active_tab =
                        source_tabs.get(new_index).map(|tab| tab.public_id.clone());
                    target_pane = source_pane.clone();
                } else {
                    target_pane.active_tab =
                        target_tabs.get(new_index).map(|tab| tab.public_id.clone());
                }

                let mut changes = Vec::new();
                changes.push(ResourceChange::UpsertPane(source_pane.clone()));
                if target_pane_id != source_pane_id {
                    changes.push(ResourceChange::UpsertPane(target_pane.clone()));
                }
                for tab in &source_tabs {
                    changes.push(ResourceChange::UpsertTab(tab.clone()));
                }
                if target_pane_id != source_pane_id {
                    for tab in &target_tabs {
                        changes.push(ResourceChange::UpsertTab(tab.clone()));
                    }
                }
                changes.push(ResourceChange::SetTabOrder {
                    pane_id: source_pane_id.clone(),
                    tab_ids: source_tabs.iter().map(|tab| tab.public_id.clone()).collect(),
                });
                if target_pane_id != source_pane_id {
                    changes.push(ResourceChange::SetTabOrder {
                        pane_id: target_pane_id.clone(),
                        tab_ids: target_tabs.iter().map(|tab| tab.public_id.clone()).collect(),
                    });
                }

                let source_workspace_id =
                    source.path.workspace.context("terminal source omitted its workspace id")?;
                if source_workspace_id != target_workspace_id {
                    let host_id = source_tab
                        .terminal_id
                        .as_deref()
                        .context("terminal tab omitted its host id")?;
                    let mut terminal = registry
                        .terminal_snapshot()?
                        .terminals
                        .into_iter()
                        .find(|terminal| terminal.terminal_id == host_id)
                        .context("terminal has no durable host placement")?;
                    terminal.workspace_key = target_workspace_key;
                    changes.push(ResourceChange::UpsertTerminal {
                        public_id: terminal_id.clone(),
                        terminal,
                    });
                }

                let mut target_screen = topology
                    .screens
                    .iter()
                    .find(|screen| screen.public_id == target_screen_id)
                    .cloned()
                    .context("destination screen is absent from durable topology")?;
                target_screen.active_pane = target_pane_id.clone();
                changes.push(ResourceChange::UpsertScreen(target_screen));
                let durable_workspace = snapshot
                    .workspaces
                    .iter()
                    .find(|workspace| workspace.public_id == target_workspace_id)
                    .cloned()
                    .context("destination workspace is absent from registry")?;
                changes.push(ResourceChange::UpsertWorkspace {
                    workspace: durable_workspace,
                    position: target_workspace_index,
                    active_screen: Some(target_screen_id),
                });
                changes.push(ResourceChange::SetActiveWorkspace {
                    workspace_id: Some(target_workspace_id.clone()),
                });

                let source_public = source_pane.public_id.clone();
                let target_public = target_pane.public_id.clone();
                let source_delta_tabs = source_tabs.clone();
                let target_delta_tabs = target_tabs.clone();
                let source_delta_pane = source_pane;
                let target_delta_pane = target_pane;
                let deltas = move_deltas(
                    &source_delta_pane,
                    &target_delta_pane,
                    &source_delta_tabs,
                    &target_delta_tabs,
                    source_pane_id == target_pane_id,
                );

                let source_old_index = state
                    .panes
                    .get(&source_pane_slot)
                    .and_then(|pane| pane.tabs.iter().position(|candidate| *candidate == surface))
                    .context("terminal is absent from its live source pane")?;
                let target_existing_len = state
                    .panes
                    .get(&target_pane_slot)
                    .context("destination pane disappeared")?
                    .tabs
                    .len();
                if source_pane_slot != target_pane_slot {
                    state
                        .panes
                        .get_mut(&target_pane_slot)
                        .expect("destination pane validated")
                        .tabs
                        .reserve(1);
                }
                let session_path = (target_workspace_slot, target_screen_slot, target_pane_slot);
                let result = json!({
                    "terminal": terminal_id,
                    "tab": source_tab.public_id,
                    "pane": target_public,
                    "index": new_index,
                    "value": terminal_value,
                });
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result,
                    Value::Array(deltas),
                    move |state| {
                        if source_pane_slot == target_pane_slot {
                            let pane = state
                                .panes
                                .get_mut(&source_pane_slot)
                                .expect("source pane validated before commit");
                            let moved = pane.tabs.remove(source_old_index);
                            pane.tabs.insert(new_index, moved);
                            pane.active_tab = new_index;
                        } else {
                            {
                                let source = state
                                    .panes
                                    .get_mut(&source_pane_slot)
                                    .expect("source pane validated before commit");
                                source.tabs.remove(source_old_index);
                                source.active_tab =
                                    source.active_tab.min(source.tabs.len().saturating_sub(1));
                            }
                            let target = state
                                .panes
                                .get_mut(&target_pane_slot)
                                .expect("destination pane validated before commit");
                            debug_assert!(target.tabs.capacity() > target_existing_len);
                            target.tabs.insert(new_index, surface);
                            target.active_tab = new_index;
                            state.resource_indexes.tab_pane.insert(surface, target_pane_slot);
                        }
                        let workspace_index = state
                            .workspace_index(session_path.0)
                            .expect("destination workspace validated before commit");
                        let screen_index = state.workspaces[workspace_index]
                            .screens
                            .iter()
                            .position(|screen| screen.id == session_path.1)
                            .expect("destination screen validated before commit");
                        state.active_workspace = workspace_index;
                        state.workspaces[workspace_index].active_screen = screen_index;
                        state.workspaces[workspace_index].screens[screen_index].active_pane =
                            session_path.2;
                    },
                )
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: if source_public == target_public { 2 } else { 4 },
                    order_entries: source_delta_tabs.len() + target_delta_tabs.len(),
                    terminal_queries: usize::from(source_workspace_id != target_workspace_id),
                    changed_rows: source_delta_tabs.len() + target_delta_tabs.len() + 4,
                }))
            },
        )?;

        if !commit.replayed
            && let Some(terminal_id) = commit.result["terminal"].as_str()
            && let Ok(terminal_id) = crate::resource::TerminalPublicId::parse(terminal_id)
            && let Some(surface_id) = self.resource_surface_for_terminal(&terminal_id)
            && let Some(surface) = self.surface(surface_id)
        {
            let path = {
                let state = self.state.lock().unwrap();
                state.resource_indexes.tab_pane.get(&surface_id).copied().and_then(|target_pane| {
                    let (workspace_index, screen_index) = state.screen_of(target_pane)?;
                    Some((
                        target_pane,
                        state.workspaces[workspace_index].key.clone(),
                        state.workspaces[workspace_index].id,
                        state.workspaces[workspace_index].screens[screen_index].id,
                    ))
                })
            };
            if let Some((target_pane, workspace_key, workspace, screen)) = path {
                let _ = surface.persist_host_workspace(&workspace_key);
                self.subscribers.update_surface_session_path(
                    surface_id,
                    workspace,
                    screen,
                    target_pane,
                );
            }
        }
        Ok(commit)
    }
}

/// Durable replacement projection and its public delta batch after an
/// externally confirmed content effect has already changed live state.
pub(crate) struct ResourceEffectProjection {
    pub(crate) patch: ResourcePatch,
    pub(crate) changes: Value,
    pub(crate) result: Value,
}

impl Mux {
    /// Project the complete live tree into one durable patch while the caller
    /// holds the registry -> state writer fence. The matching effect receipt
    /// must be committed before either guard is released.
    pub(super) fn resource_effect_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        let before = registry.resource_topology_snapshot()?;
        let terminal_records = registry
            .terminal_snapshot()?
            .terminals
            .into_iter()
            .map(|terminal| (terminal.terminal_id.clone(), terminal))
            .collect::<HashMap<_, _>>();
        // Local UI mutations can attach resource-identified surfaces before
        // their reverse indexes are populated. Full projection is the
        // reconciliation boundary, so rebuild from the live tree first.
        state.rebuild_resource_indexes();
        ensure_split_public_ids(state)?;

        let before_browsers = before
            .browsers
            .iter()
            .map(|browser| (browser.public_id.clone(), browser.clone()))
            .collect::<HashMap<_, _>>();
        let before_pane_ordinals = before
            .panes
            .iter()
            .map(|pane| (pane.public_id.clone(), pane.creation_ordinal))
            .collect::<HashMap<_, _>>();
        let mut live_workspaces = HashSet::new();
        let mut live_screens = HashSet::new();
        let mut live_panes = HashSet::new();
        let mut live_tabs = HashSet::new();
        let mut live_terminals = HashSet::new();
        let mut live_browsers = HashSet::new();
        let mut changes = Vec::new();
        let mut public = Vec::new();

        for (workspace_index, workspace) in state.workspaces.iter().enumerate() {
            live_workspaces.insert(workspace.public_id.clone());
            changes.push(ResourceChange::UpsertWorkspace {
                workspace: RegistryWorkspace {
                    id: workspace.id,
                    public_id: workspace.public_id.clone(),
                    key: workspace.key.clone(),
                    name: workspace.name.clone(),
                    group_key: self.session.clone(),
                },
                position: workspace_index,
                active_screen: workspace
                    .screens
                    .get(workspace.active_screen)
                    .map(|screen| screen.public_id.clone()),
            });
            public.push((
                "workspace",
                workspace.public_id.to_string(),
                json!({
                    "id":workspace.public_id,
                    "session_id":before.session_id,
                    "name":workspace.name,
                    "index":workspace_index,
                    "focused":workspace_index == state.active_workspace,
                }),
            ));
            let screen_ids =
                workspace.screens.iter().map(|screen| screen.public_id.clone()).collect::<Vec<_>>();
            changes.push(ResourceChange::SetScreenOrder {
                workspace_id: workspace.public_id.clone(),
                screen_ids,
            });

            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                live_screens.insert(screen.public_id.clone());
                let durable =
                    registry_screen_from_live(state, &workspace.public_id, screen_index, screen)?;
                let public_layout = public_layout_from_registry(&durable, state)?;
                changes.push(ResourceChange::UpsertScreen(durable.clone()));
                public.push((
                    "screen",
                    screen.public_id.to_string(),
                    json!({
                        "id":screen.public_id,
                        "workspace_id":workspace.public_id,
                        "name":screen.name,
                        "index":screen_index,
                        "focused":workspace_index == state.active_workspace
                            && workspace.active_screen == screen_index,
                        "layout":public_layout,
                    }),
                ));

                for pane_slot in screen.root.pane_ids_vec() {
                    let pane = state
                        .panes
                        .get(&pane_slot)
                        .with_context(|| format!("screen references missing pane {pane_slot}"))?;
                    live_panes.insert(pane.public_id.clone());
                    let active_tab = pane.tabs.get(pane.active_tab).and_then(|surface| {
                        state.resource_indexes.tab_ids.get(surface).cloned().or_else(|| {
                            state
                                .surfaces
                                .get(surface)
                                .and_then(|surface| surface.resource_identity())
                                .map(|identity| identity.tab_id.clone())
                        })
                    });
                    let creation_ordinal =
                        before_pane_ordinals.get(&pane.public_id).copied().unwrap_or(pane.id);
                    changes.push(ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane.public_id.clone(),
                        screen_id: screen.public_id.clone(),
                        name: pane.name.clone(),
                        active_tab,
                        creation_ordinal,
                    }));
                    public.push((
                        "pane",
                        pane.public_id.to_string(),
                        json!({
                            "id":pane.public_id,
                            "screen_id":screen.public_id,
                            "name":pane.name,
                            "focused":workspace_index == state.active_workspace
                                && workspace.active_screen == screen_index
                                && screen.active_pane == pane.id,
                            "zoomed":screen.zoomed_pane == Some(pane.id),
                        }),
                    ));

                    let mut tab_order = Vec::with_capacity(pane.tabs.len());
                    for (position, surface_slot) in pane.tabs.iter().enumerate() {
                        let surface = state.surfaces.get(surface_slot).with_context(|| {
                            format!("pane references missing surface {surface_slot}")
                        })?;
                        let identity = surface.resource_identity().with_context(|| {
                            format!("pane surface {surface_slot} has no resource identity")
                        })?;
                        live_tabs.insert(identity.tab_id.clone());
                        tab_order.push(identity.tab_id.clone());
                        let (browser_url, terminal_id) = match &identity.content_id {
                            ContentPublicId::Terminal(terminal_id) => {
                                live_terminals.insert(terminal_id.clone());
                                let host = self.resource_terminal_host_identity(surface).context(
                                    "terminal surface omitted its durable host identity",
                                )?;
                                let terminal = terminal_records
                                    .get(&host.terminal_id)
                                    .cloned()
                                    .context("terminal surface has no durable placement")?;
                                changes.push(ResourceChange::UpsertTerminal {
                                    public_id: terminal_id.clone(),
                                    terminal,
                                });
                                (None, Some(host.terminal_id))
                            }
                            ContentPublicId::Browser(browser_id) => {
                                live_browsers.insert(browser_id.clone());
                                let url = surface
                                    .browser_url()
                                    .or_else(|| {
                                        before_browsers
                                            .get(browser_id)
                                            .map(|browser| browser.url.clone())
                                    })
                                    .unwrap_or_else(|| "about:blank".to_string());
                                let (cols, rows) = surface.size();
                                let live_status = surface.browser_status();
                                let mut browser =
                                    before_browsers.get(browser_id).cloned().unwrap_or_else(|| {
                                        RegistryBrowser::recreate(
                                            browser_id.clone(),
                                            url.clone(),
                                            cols.max(1),
                                            rows.max(1),
                                        )
                                    });
                                browser.url = url.clone();
                                browser.cols = cols.max(1);
                                browser.rows = rows.max(1);
                                browser.status = match live_status.as_ref() {
                                    Some(BrowserStatus::Starting) => {
                                        RegistryBrowserStatus::Starting
                                    }
                                    Some(BrowserStatus::Live) => RegistryBrowserStatus::Live,
                                    Some(BrowserStatus::Failed(_)) => RegistryBrowserStatus::Failed,
                                    None if surface.is_dead() => RegistryBrowserStatus::Failed,
                                    None => browser.status,
                                };
                                if let Some(source) = surface.browser_source() {
                                    browser.source = match source {
                                        BrowserSource::External => RegistryBrowserSource::External,
                                        BrowserSource::Launched => RegistryBrowserSource::Launched,
                                    };
                                }
                                changes.push(ResourceChange::UpsertBrowser(browser));
                                (Some(url), None)
                            }
                        };
                        let tab = RegistryTab {
                            public_id: identity.tab_id.clone(),
                            pane_id: pane.public_id.clone(),
                            position,
                            content_id: identity.content_id.clone(),
                            name: surface.name(),
                            browser_url,
                            terminal_id,
                        };
                        changes.push(ResourceChange::UpsertTab(tab.clone()));
                        let content_kind = match &tab.content_id {
                            ContentPublicId::Terminal(_) => "terminal",
                            ContentPublicId::Browser(_) => "browser",
                        };
                        public.push((
                            "tab",
                            tab.public_id.to_string(),
                            json!({
                                "id":tab.public_id,
                                "pane_id":tab.pane_id,
                                "index":tab.position,
                                "name":tab.name,
                                "content_kind":content_kind,
                                "content_id":tab.content_id.as_str(),
                            }),
                        ));
                        let (cols, rows) = surface.size();
                        match &tab.content_id {
                            ContentPublicId::Terminal(id) => {
                                let mut value = json!({
                                    "id":id,
                                    "tab_id":tab.public_id,
                                    "title":surface.title(),
                                    "cols":cols.max(1),
                                    "rows":rows.max(1),
                                    "running":!surface.is_dead(),
                                });
                                if let Some(cwd) = surface.spawn_cwd() {
                                    value["cwd"] = json!(cwd);
                                }
                                public.push(("terminal", id.to_string(), value));
                            }
                            ContentPublicId::Browser(id) => {
                                let status = surface.browser_status();
                                let status_name = status
                                    .as_ref()
                                    .map(|status| status.as_str())
                                    .unwrap_or(if surface.is_dead() { "failed" } else { "live" });
                                let source = surface
                                    .browser_source()
                                    .map(|source| source.as_str())
                                    .or_else(|| {
                                        before_browsers.get(id).map(|browser| {
                                            match browser.source {
                                                RegistryBrowserSource::External => "external",
                                                RegistryBrowserSource::Launched => "launched",
                                                RegistryBrowserSource::Unknown => {
                                                    match browser.launch {
                                                        RegistryBrowserLaunch::Create => "launched",
                                                        RegistryBrowserLaunch::Adopted => {
                                                            "external"
                                                        }
                                                    }
                                                }
                                            }
                                        })
                                    })
                                    .unwrap_or("launched");
                                public.push((
                                    "browser",
                                    id.to_string(),
                                    json!({
                                        "id":id,
                                        "tab_id":tab.public_id,
                                        "url":tab.browser_url,
                                        "title":surface.title(),
                                        "loading":status_name == "starting",
                                        "source":source,
                                        "status":status_name,
                                        "error":status.and_then(|status| status.error()),
                                        "frames_stalled":surface.browser_frames_stalled()
                                            .unwrap_or(false),
                                        "size":{
                                            "cols":cols.max(1),
                                            "rows":rows.max(1),
                                        },
                                    }),
                                ));
                            }
                        }
                    }
                    changes.push(ResourceChange::SetTabOrder {
                        pane_id: pane.public_id.clone(),
                        tab_ids: tab_order,
                    });
                }
            }
        }
        changes.push(ResourceChange::SetWorkspaceOrder {
            workspace_ids: state
                .workspaces
                .iter()
                .map(|workspace| workspace.public_id.clone())
                .collect(),
        });
        changes.push(ResourceChange::SetActiveWorkspace {
            workspace_id: state
                .workspaces
                .get(state.active_workspace)
                .map(|workspace| workspace.public_id.clone()),
        });

        for tab in &before.tabs {
            if !live_tabs.contains(&tab.public_id) {
                changes.push(ResourceChange::TombstoneTab { tab_id: tab.public_id.clone() });
            }
            match &tab.content_id {
                ContentPublicId::Terminal(id) if !live_terminals.contains(id) => {
                    changes.push(ResourceChange::TombstoneTerminal {
                        public_id: id.clone(),
                        expected_incarnation: None,
                    });
                }
                ContentPublicId::Browser(id) if !live_browsers.contains(id) => {
                    changes.push(ResourceChange::TombstoneBrowser { public_id: id.clone() });
                }
                _ => {}
            }
        }
        for pane in &before.panes {
            if !live_panes.contains(&pane.public_id) {
                changes.push(ResourceChange::TombstonePane { pane_id: pane.public_id.clone() });
            }
        }
        for screen in &before.screens {
            if !live_screens.contains(&screen.public_id) {
                changes
                    .push(ResourceChange::TombstoneScreen { screen_id: screen.public_id.clone() });
            }
        }
        for (workspace_id, _) in &before.active_screens {
            if !live_workspaces.contains(workspace_id) {
                changes.push(ResourceChange::TombstoneWorkspace {
                    workspace_id: workspace_id.clone(),
                });
            }
        }

        let mut deltas = Vec::new();
        let live_keys = public
            .iter()
            .map(|(kind, id, _)| ((*kind).to_string(), id.clone()))
            .collect::<HashSet<_>>();
        for (kind, id, value) in public {
            let sequence = deltas.len();
            deltas.push(json!({
                "kind":"upsert",
                "sequence":sequence,
                "resource":kind,
                "id":id,
                "value":value,
            }));
        }
        for tab in &before.tabs {
            let (kind, id) = match &tab.content_id {
                ContentPublicId::Terminal(id) => ("terminal", id.as_str()),
                ContentPublicId::Browser(id) => ("browser", id.as_str()),
            };
            if !live_keys.contains(&(kind.to_string(), id.to_string())) {
                push_delete_delta(&mut deltas, kind, id);
            }
            if !live_keys.contains(&("tab".to_string(), tab.public_id.to_string())) {
                push_delete_delta(&mut deltas, "tab", tab.public_id.as_str());
            }
        }
        for pane in &before.panes {
            if !live_keys.contains(&("pane".to_string(), pane.public_id.to_string())) {
                push_delete_delta(&mut deltas, "pane", pane.public_id.as_str());
            }
        }
        for screen in &before.screens {
            if !live_keys.contains(&("screen".to_string(), screen.public_id.to_string())) {
                push_delete_delta(&mut deltas, "screen", screen.public_id.as_str());
            }
        }
        for (workspace_id, _) in &before.active_screens {
            if !live_keys.contains(&("workspace".to_string(), workspace_id.to_string())) {
                push_delete_delta(&mut deltas, "workspace", workspace_id.as_str());
            }
        }
        Ok(ResourceEffectProjection {
            patch: ResourcePatch { changes },
            changes: Value::Array(deltas),
            result,
        })
    }

    #[cfg(test)]
    pub(crate) fn resource_effect_projection(&self) -> anyhow::Result<ResourceEffectProjection> {
        let registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        self.resource_effect_projection_locked(&registry, &mut state, json!({}))
    }
}

fn registry_screen_from_live(
    state: &State,
    workspace_id: &WorkspacePublicId,
    position: usize,
    screen: &crate::model::Screen,
) -> anyhow::Result<RegistryScreen> {
    let layout = registry_layout_node(state, &screen.root)?;
    let viewport = if screen.layout_columns.is_empty() {
        RegistryViewport::default()
    } else {
        RegistryViewport {
            base_width: screen.viewport_base_width,
            columns: screen
                .layout_columns
                .iter()
                .map(|column| {
                    Ok(RegistryViewportColumn {
                        id: split_public_id(state, column.id)?,
                        width: column.width,
                        layout: registry_layout_node(state, &column.root)?,
                        auto_layout: column
                            .zellij_auto_layout
                            .as_ref()
                            .map(|panes| pane_public_ids(state, panes))
                            .transpose()?,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()?,
        }
    };
    Ok(RegistryScreen {
        public_id: screen.public_id.clone(),
        workspace_id: workspace_id.clone(),
        position,
        name: screen.name.clone(),
        layout,
        active_pane: pane_public_id(state, screen.active_pane)?,
        zoomed_pane: screen.zoomed_pane.map(|pane| pane_public_id(state, pane)).transpose()?,
        auto_layout: screen
            .zellij_auto_layout
            .as_ref()
            .map(|panes| pane_public_ids(state, panes))
            .transpose()?,
        viewport,
    })
}

fn ensure_split_public_ids(state: &mut State) -> anyhow::Result<()> {
    let mut splits = HashSet::new();
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            collect_node_split_ids(&screen.root, &mut splits);
            for column in &screen.layout_columns {
                splits.insert(column.id);
                collect_node_split_ids(&column.root, &mut splits);
            }
        }
    }
    for split in splits {
        if state.resource_indexes.split_ids.contains_key(&split) {
            continue;
        }
        let public_id = SplitPublicId::random()?;
        state.resource_indexes.splits.insert(public_id.clone(), split);
        state.resource_indexes.split_ids.insert(split, public_id);
    }
    Ok(())
}

fn collect_node_split_ids(node: &Node, splits: &mut HashSet<crate::SplitId>) {
    match node {
        Node::Leaf(_) | Node::Stack { .. } => {}
        Node::Split { id, a, b, .. } => {
            splits.insert(*id);
            collect_node_split_ids(a, splits);
            collect_node_split_ids(b, splits);
        }
    }
}

fn registry_layout_node(state: &State, node: &Node) -> anyhow::Result<RegistryLayoutNode> {
    Ok(match node {
        Node::Leaf(pane) => RegistryLayoutNode::Leaf { pane: pane_public_id(state, *pane)? },
        Node::Split { id, dir, ratio, a, b } => RegistryLayoutNode::Split {
            split: split_public_id(state, *id)?,
            direction: match dir {
                crate::SplitDir::Right => "right",
                crate::SplitDir::Down => "down",
            }
            .to_string(),
            ratio: *ratio,
            first: Box::new(registry_layout_node(state, a)?),
            second: Box::new(registry_layout_node(state, b)?),
        },
        Node::Stack { panes, expanded } => RegistryLayoutNode::Stack {
            panes: pane_public_ids(state, panes.as_slice())?,
            expanded: pane_public_id(state, *expanded)?,
        },
    })
}

fn pane_public_id(state: &State, pane: crate::PaneId) -> anyhow::Result<PanePublicId> {
    state
        .resource_indexes
        .pane_ids
        .get(&pane)
        .cloned()
        .with_context(|| format!("pane {pane} has no public identity"))
}

fn pane_public_ids(state: &State, panes: &[crate::PaneId]) -> anyhow::Result<Vec<PanePublicId>> {
    panes.iter().map(|pane| pane_public_id(state, *pane)).collect()
}

fn split_public_id(state: &State, split: crate::SplitId) -> anyhow::Result<SplitPublicId> {
    state
        .resource_indexes
        .split_ids
        .get(&split)
        .cloned()
        .with_context(|| format!("split {split} has no public identity"))
}

fn public_layout_from_registry(screen: &RegistryScreen, state: &State) -> anyhow::Result<Value> {
    Ok(json!({
        "version":1,
        "screen_id":screen.public_id,
        "active_pane_id":screen.active_pane,
        "zoomed_pane_id":screen.zoomed_pane,
        "root":public_layout_node(&screen.layout, state)?,
    }))
}

fn public_layout_node(node: &RegistryLayoutNode, state: &State) -> anyhow::Result<Value> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => {
            let slot =
                state.resource_indexes.panes.get(pane).context("layout pane has no live slot")?;
            let pane_state = state.panes.get(slot).context("layout pane is missing")?;
            json!({
                "kind":"leaf",
                "pane_id":pane,
                "tab_ids":pane_state.tabs.iter().filter_map(|surface| {
                    state.resource_indexes.tab_ids.get(surface)
                }).collect::<Vec<_>>(),
                "active_tab_id":pane_state.tabs.get(pane_state.active_tab).and_then(|surface| {
                    state.resource_indexes.tab_ids.get(surface)
                }),
            })
        }
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => json!({
            "kind":"split",
            "split_id":split,
            "direction":match direction.as_str() {
                "right" => "horizontal",
                "down" => "vertical",
                other => other,
            },
            "ratio":f64::from(*ratio),
            "first":public_layout_node(first, state)?,
            "second":public_layout_node(second, state)?,
        }),
        RegistryLayoutNode::Stack { panes, expanded } => json!({
            "kind":"stack",
            "pane_ids":panes,
            "expanded_pane_id":expanded,
        }),
    })
}

fn push_delete_delta(changes: &mut Vec<Value>, resource: &str, id: &str) {
    let sequence = changes.len();
    changes.push(json!({
        "kind":"delete",
        "sequence":sequence,
        "resource":resource,
        "id":id,
    }));
}

fn ordered_tabs(tabs: &[RegistryTab], pane: &PanePublicId) -> Vec<RegistryTab> {
    let mut result = tabs.iter().filter(|tab| &tab.pane_id == pane).cloned().collect::<Vec<_>>();
    result.sort_by_key(|tab| tab.position);
    result
}

fn reindex_tabs(tabs: &mut [RegistryTab], pane: &PanePublicId) {
    for (position, tab) in tabs.iter_mut().enumerate() {
        tab.pane_id = pane.clone();
        tab.position = position;
    }
}

fn move_deltas(
    source_pane: &RegistryPane,
    target_pane: &RegistryPane,
    source_tabs: &[RegistryTab],
    target_tabs: &[RegistryTab],
    same_pane: bool,
) -> Vec<Value> {
    let mut changes = Vec::new();
    push_pane_delta(&mut changes, source_pane, same_pane);
    if !same_pane {
        push_pane_delta(&mut changes, target_pane, true);
    }
    for tab in source_tabs {
        push_tab_delta(&mut changes, tab);
    }
    if !same_pane {
        for tab in target_tabs {
            push_tab_delta(&mut changes, tab);
        }
    }
    changes
}

fn push_pane_delta(changes: &mut Vec<Value>, pane: &RegistryPane, focused: bool) {
    let sequence = changes.len();
    changes.push(json!({
        "kind": "upsert",
        "sequence": sequence,
        "resource": "pane",
        "id": pane.public_id,
        "value": {
            "id": pane.public_id,
            "screen_id": pane.screen_id,
            "name": pane.name,
            "focused": focused,
            "zoomed": false,
        },
    }));
}

fn push_tab_delta(changes: &mut Vec<Value>, tab: &RegistryTab) {
    let sequence = changes.len();
    let content_kind = match &tab.content_id {
        ContentPublicId::Terminal(_) => "terminal",
        ContentPublicId::Browser(_) => "browser",
    };
    changes.push(json!({
        "kind": "upsert",
        "sequence": sequence,
        "resource": "tab",
        "id": tab.public_id,
        "value": {
            "id": tab.public_id,
            "pane_id": tab.pane_id,
            "index": tab.position,
            "name": tab.name,
            "content_kind": content_kind,
            "content_id": tab.content_id.as_str(),
        },
    }));
}
