//! Full projection of the live tree into one durable topology patch: the
//! reconciliation boundary that every topology commit passes, timed per
//! part for `server-stats` (`resource_projection`).

use std::time::Instant;

use super::*;
use crate::diagnostics::ProjectionSpans;
use crate::workspace_registry::{RegistryTerminal, ResourceTopologySnapshot};

impl Mux {
    /// Project the complete live tree into one durable patch while the caller
    /// holds the registry -> state writer fence. The matching effect receipt
    /// must be committed before either guard is released.
    pub(crate) fn resource_effect_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        let started = Instant::now();
        let before = registry.resource_topology_snapshot()?;
        let terminal_records = registry
            .terminal_snapshot()?
            .terminals
            .into_iter()
            .map(|terminal| (terminal.terminal_id.clone(), terminal))
            .collect::<HashMap<_, _>>();
        let read = started.elapsed();
        // Local UI mutations can attach resource-identified surfaces before
        // their reverse indexes are populated. Full projection is the
        // reconciliation boundary, so rebuild from the live tree first.
        state.rebuild_resource_indexes();
        state.ensure_tab_identity_coverage()?;
        ensure_split_public_ids(state)?;
        let terminal_tab_order = ordered_terminal_tab_ids(state)?;
        let index = started.elapsed().saturating_sub(read);
        let projection =
            self.project_live_tree(&before, &terminal_records, state, &terminal_tab_order, result)?;
        registry.resource_projection_stats().projected(ProjectionSpans {
            read,
            index,
            diff: started.elapsed().saturating_sub(read + index),
            changes: projection.patch.changes.len(),
            scoped: false,
        });
        Ok(projection)
    }

    /// Diff the live tree (with its resource indexes current) against the
    /// stored topology `before` and its terminal records.
    fn project_live_tree(
        &self,
        before: &ResourceTopologySnapshot,
        terminal_records: &HashMap<String, RegistryTerminal>,
        state: &State,
        terminal_tab_order: &HashMap<TerminalPublicId, Vec<TabPublicId>>,
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        let before_browsers = before
            .browsers
            .iter()
            .map(|browser| (browser.public_id.clone(), browser.clone()))
            .collect::<HashMap<_, _>>();
        let before_tabs = before
            .tabs
            .iter()
            .map(|tab| (tab.public_id.clone(), tab.clone()))
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
        let mut screens = PublishedScreens::default();

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
                screens.defer(
                    &mut public,
                    durable.clone(),
                    workspace_index == state.active_workspace
                        && workspace.active_screen == screen_index,
                );
                changes.push(ResourceChange::UpsertScreen(durable));

                for pane_slot in screen.root.pane_ids_vec() {
                    let pane = state
                        .panes
                        .get(&pane_slot)
                        .with_context(|| format!("screen references missing pane {pane_slot}"))?;
                    live_panes.insert(pane.public_id.clone());
                    let active_tab = pane
                        .tabs
                        .get(pane.active_tab)
                        .and_then(|slot| state.resource_indexes.tab_ids.get(slot).cloned());
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
                        let surface = state.surfaces.get(surface_slot);
                        let identity =
                            tab_resource_identity(state, *surface_slot).with_context(|| {
                                format!("pane surface {surface_slot} has no resource identity")
                            })?;
                        let before_tab = before_tabs.get(&identity.tab_id);
                        live_tabs.insert(identity.tab_id.clone());
                        tab_order.push(identity.tab_id.clone());
                        let (browser_url, terminal_id, first_terminal_placement) = match &identity
                            .content_id
                        {
                            ContentPublicId::Terminal(terminal_id) => {
                                let first_terminal_placement =
                                    live_terminals.insert(terminal_id.clone());
                                let runtime = state.terminal_catalog.get(terminal_id).or(surface);
                                let host_id = runtime
                                    .and_then(|surface| {
                                        self.resource_terminal_host_identity(surface)
                                            .map(|host| host.terminal_id)
                                    })
                                    .or_else(|| before_tab.and_then(|tab| tab.terminal_id.clone()))
                                    .context("terminal view omitted its durable host identity")?;
                                if first_terminal_placement {
                                    let terminal = terminal_records
                                        .get(&host_id)
                                        .cloned()
                                        .context("terminal view has no durable host")?;
                                    changes.push(ResourceChange::UpsertTerminal {
                                        public_id: terminal_id.clone(),
                                        terminal,
                                    });
                                }
                                (None, Some(host_id), first_terminal_placement)
                            }
                            ContentPublicId::Browser(browser_id) => {
                                // A browser view can also outlive its runtime,
                                // so the durable row is the fallback rather
                                // than a hard requirement.
                                live_browsers.insert(browser_id.clone());
                                let durable = before_browsers.get(browser_id).cloned();
                                let url = surface
                                    .and_then(|surface| surface.browser_url())
                                    .or_else(|| durable.as_ref().map(|browser| browser.url.clone()))
                                    .or_else(|| before_tab.and_then(|tab| tab.browser_url.clone()))
                                    .unwrap_or_else(|| "about:blank".to_string());
                                let (cols, rows) = match surface {
                                    Some(surface) => surface.size(),
                                    None => durable
                                        .as_ref()
                                        .map(|browser| (browser.cols, browser.rows))
                                        .unwrap_or((1, 1)),
                                };
                                let live_status =
                                    surface.and_then(|surface| surface.browser_status());
                                let mut browser = durable.unwrap_or_else(|| {
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
                                    None if surface.is_some_and(|surface| surface.is_dead()) => {
                                        RegistryBrowserStatus::Failed
                                    }
                                    None => browser.status,
                                };
                                if let Some(source) =
                                    surface.and_then(|surface| surface.browser_source())
                                {
                                    browser.source = match source {
                                        BrowserSource::External => RegistryBrowserSource::External,
                                        BrowserSource::Launched => RegistryBrowserSource::Launched,
                                        BrowserSource::Provider => RegistryBrowserSource::External,
                                    };
                                }
                                changes.push(ResourceChange::UpsertBrowser(browser));
                                (Some(url), None, false)
                            }
                        };
                        let tab = RegistryTab {
                            name_source: before_tab.map(|tab| tab.name_source).unwrap_or_default(),
                            name_revision: before_tab
                                .map(|tab| tab.name_revision)
                                .unwrap_or_default(),
                            public_id: identity.tab_id.clone(),
                            pane_id: pane.public_id.clone(),
                            position,
                            content_id: identity.content_id.clone(),
                            name: surface
                                .and_then(|surface| surface.name())
                                .or_else(|| before_tab.and_then(|tab| tab.name.clone())),
                            browser_url,
                            terminal_id,
                        };
                        changes.push(ResourceChange::UpsertTab(tab.clone()));
                        public.push((
                            "tab",
                            tab.public_id.to_string(),
                            tab.public_value(pane.active_tab == position),
                        ));
                        match &tab.content_id {
                            ContentPublicId::Terminal(id) if first_terminal_placement => {
                                let runtime = state.terminal_catalog.get(id).or(surface);
                                let durable = tab
                                    .terminal_id
                                    .as_deref()
                                    .and_then(|host| terminal_records.get(host))
                                    .context("terminal view has no durable host")?;
                                let tab_ids =
                                    terminal_tab_order.get(id).cloned().unwrap_or_default();
                                let value = public_terminal_snapshot(
                                    id,
                                    durable,
                                    runtime.map(std::sync::Arc::as_ref),
                                    tab_ids,
                                )?;
                                public.push(("terminal", id.to_string(), value));
                            }
                            ContentPublicId::Terminal(_) => {}
                            ContentPublicId::Browser(id) => {
                                let durable = before_browsers.get(id);
                                let (cols, rows) = match surface {
                                    Some(surface) => surface.size(),
                                    None => durable
                                        .map(|browser| (browser.cols, browser.rows))
                                        .unwrap_or((1, 1)),
                                };
                                let status = surface.and_then(|surface| surface.browser_status());
                                let status_name = status
                                    .as_ref()
                                    .map(|status| status.as_str())
                                    .unwrap_or(match surface {
                                        Some(surface) if surface.is_dead() => "failed",
                                        Some(_) => "live",
                                        None => match durable.map(|browser| &browser.status) {
                                            Some(RegistryBrowserStatus::Starting) => "starting",
                                            Some(RegistryBrowserStatus::Live) => "live",
                                            Some(RegistryBrowserStatus::Failed) | None => "failed",
                                        },
                                    });
                                let source = surface
                                    .and_then(|surface| surface.browser_source())
                                    .map(|source| source.as_str())
                                    .or_else(|| {
                                        before_browsers.get(id).map(|browser| {
                                            match browser.source {
                                                RegistryBrowserSource::External => "external",
                                                RegistryBrowserSource::Launched => "launched",
                                                RegistryBrowserSource::Unknown => {
                                                    match browser.launch {
                                                        RegistryBrowserLaunch::Create => "external",
                                                        RegistryBrowserLaunch::Adopted => {
                                                            "external"
                                                        }
                                                    }
                                                }
                                            }
                                        })
                                    })
                                    .unwrap_or("external");
                                public.push((
                                    "browser",
                                    id.to_string(),
                                    json!({
                                        "id":id,
                                        "tab_id":tab.public_id,
                                        "url":tab.browser_url,
                                        "title":surface.map(|surface| surface.title()),
                                        "loading":status_name == "starting",
                                        "source":source,
                                        "status":status_name,
                                        "error":status.and_then(|status| status.error()),
                                        "frames_stalled":surface
                                            .and_then(|surface| surface.browser_frames_stalled())
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
        for (terminal_id, surface) in &state.terminal_catalog {
            // An app terminal is published by its first view (`app_terminals.rs`).
            if !live_terminals.insert(terminal_id.clone())
                || self.is_unregistered_app_terminal(surface.id)
            {
                continue;
            }
            let host = self
                .resource_terminal_host_identity(surface)
                .context("catalog terminal omitted its durable host identity")?;
            let terminal = terminal_records
                .get(&host.terminal_id)
                .cloned()
                .context("catalog terminal has no durable host")?;
            // The one builder for published terminal records: a terminal with
            // no tab (kept or detached) still carries its `lifecycle`.
            let value =
                public_terminal_snapshot(terminal_id, &terminal, Some(surface), Vec::new())?;
            changes
                .push(ResourceChange::UpsertTerminal { public_id: terminal_id.clone(), terminal });
            public.push(("terminal", terminal_id.to_string(), value));
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

        let mut tombstoned_terminals = HashSet::new();
        let mut tombstoned_browsers = HashSet::new();
        for tab in &before.tabs {
            if !live_tabs.contains(&tab.public_id) {
                changes.push(ResourceChange::TombstoneTab {
                    tab_id: tab.public_id.clone(),
                    close_content: true,
                });
            }
            match &tab.content_id {
                ContentPublicId::Terminal(id)
                    if !live_terminals.contains(id) && tombstoned_terminals.insert(id.clone()) =>
                {
                    changes.push(ResourceChange::TombstoneTerminal {
                        public_id: id.clone(),
                        expected_incarnation: None,
                    });
                }
                ContentPublicId::Browser(id)
                    if !live_browsers.contains(id) && tombstoned_browsers.insert(id.clone()) =>
                {
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

        screens.publish(&mut public, &changes)?;
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
        let mut deleted_content = HashSet::new();
        for tab in &before.tabs {
            let (kind, id) = match &tab.content_id {
                ContentPublicId::Terminal(id) => ("terminal", id.as_str()),
                ContentPublicId::Browser(id) => ("browser", id.as_str()),
            };
            if !live_keys.contains(&(kind.to_string(), id.to_string()))
                && deleted_content.insert((kind, id))
            {
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
