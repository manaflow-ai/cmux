//! Startup restore follow-ups: pending agent hook retries and materializing interrupted resource workspaces and restored browsers.

use super::*;

impl Mux {
    pub(super) fn retry_pending_agent_hooks(&self) -> anyhow::Result<()> {
        let mut cursor = None;
        // Keep startup work bounded. Remaining rows stay durable for a later
        // availability signal or restart.
        for _ in 0..crate::workspace_registry::AGENT_HOOK_MAX_RETRY_PAGES_PER_WAKE {
            let (pending, next_cursor) = self
                .workspace_registry
                .lock()
                .unwrap()
                .pending_agent_hook_projections_page(cursor.clone())?;
            let Some(next_cursor) = next_cursor else { break };
            cursor = Some(next_cursor);
            self.retry_pending_agent_hooks_rows(pending)?;
        }
        Ok(())
    }

    pub(super) fn retry_pending_agent_hooks_for_terminal(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> anyhow::Result<()> {
        // Drain in fixed-size pages, with a hard per-signal cap. Rows beyond
        // the cap remain durable for the next terminal availability signal.
        for _ in 0..crate::workspace_registry::AGENT_HOOK_MAX_RETRY_PAGES_PER_WAKE {
            let pending = self
                .workspace_registry
                .lock()
                .unwrap()
                .pending_agent_hook_projections_for_terminal(terminal_id)?;
            if pending.is_empty() {
                break;
            }
            let applied = self.retry_pending_agent_hooks_rows(pending)?;
            if applied == 0 {
                break;
            }
        }
        Ok(())
    }

    pub(super) fn retry_pending_agent_hooks_rows(
        &self,
        pending: Vec<(String, String, String, u64, crate::JournalIngress)>,
    ) -> anyhow::Result<usize> {
        let mut applied = 0;
        for (producer_id, origin, key, sequence, ingress) in pending {
            match self.apply_agent_hook_record(&ingress, sequence) {
                Ok(()) => {
                    if self
                        .workspace_registry
                        .lock()
                        .unwrap()
                        .clear_agent_hook_pending(&producer_id, &origin, &key)
                        .is_ok()
                    {
                        applied += 1;
                    } else {
                        self.report_internal_diagnostic("agent hook retry cleanup deferred");
                    }
                }
                Err(error) if agent_hook_terminal_gone(&error) => {
                    if self
                        .workspace_registry
                        .lock()
                        .unwrap()
                        .clear_agent_hook_pending(&producer_id, &origin, &key)
                        .is_ok()
                    {
                        applied += 1;
                    } else {
                        self.report_internal_diagnostic("agent hook retry cleanup deferred");
                    }
                }
                Err(error) => {
                    if self
                        .workspace_registry
                        .lock()
                        .unwrap()
                        .enqueue_agent_hook_pending(
                            &producer_id,
                            &origin,
                            &key,
                            sequence,
                            &ingress,
                            AgentHookPendingFailure {
                                error: AGENT_HOOK_RETRY_ERROR,
                                retry_class: agent_hook_retry_class(&error),
                            },
                        )
                        .is_err()
                    {
                        self.report_internal_diagnostic("agent hook retry bookkeeping deferred");
                    }
                }
            }
        }
        Ok(applied)
    }

    /// Rehydrate workspace rows that belong to an interrupted correlated
    /// creation without exposing them through the public snapshot. Terminal
    /// host adoption then restores the live content, and creation settlement
    /// publishes the complete resource subtree atomically before startup
    /// returns.
    pub(super) fn materialize_interrupted_resource_workspaces(&self) -> anyhow::Result<()> {
        let (recoveries, staged) = {
            let registry = self.workspace_registry.lock().unwrap();
            (
                registry.interrupted_resource_creation_recoveries()?,
                registry.interrupted_resource_workspaces()?,
            )
        };
        anyhow::ensure!(
            recoveries.len() <= 1,
            "multiple interrupted resource creations cannot be recovered atomically"
        );
        if staged.is_empty() {
            return Ok(());
        }
        anyhow::ensure!(
            staged.len() == 1,
            "multiple interrupted workspace creations cannot be recovered atomically"
        );
        let active_workspace = staged
            .last()
            .map(|(_, workspace)| workspace.id)
            .expect("non-empty staged workspace list");
        let mut state = self.state.lock().unwrap();
        for (position, workspace) in staged {
            anyhow::ensure!(
                position <= state.workspaces.len(),
                "interrupted workspace {} has invalid position {position}",
                workspace.key
            );
            anyhow::ensure!(
                state.workspace_by_id(workspace.id).is_none(),
                "interrupted workspace {} reuses numeric id {}",
                workspace.key,
                workspace.id
            );
            anyhow::ensure!(
                state.workspace_by_key(&workspace.key).is_none(),
                "interrupted workspace key {} is already live",
                workspace.key
            );
            anyhow::ensure!(
                !state.resource_indexes.workspaces.contains_key(&workspace.public_id),
                "interrupted workspace public id {} is already live",
                workspace.public_id
            );
            state.workspaces.insert(
                position,
                Workspace {
                    id: workspace.id,
                    public_id: workspace.public_id,
                    key: workspace.key,
                    name: workspace.name,
                    screens: Vec::new(),
                    active_screen: 0,
                },
            );
        }
        state.rebuild_workspace_indexes();
        state.rebuild_resource_indexes();
        state.active_workspace = state
            .workspace_index(active_workspace)
            .context("interrupted active workspace disappeared during restore")?;
        Ok(())
    }

    pub(super) fn materialize_restored_browsers(
        self: &Arc<Self>,
        contents: &[RestoredResourceContent],
    ) -> anyhow::Result<()> {
        let opts = self.surface_options.lock().unwrap().clone();
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let presentation = self.presentation_snapshot();
        for content in contents {
            let Some(browser) = content.browser.clone() else { continue };
            let size = (browser.cols, browser.rows);
            let frontend = presentation.frontend_browsers.get(browser.public_id.as_str());
            let url = frontend.map(|record| record.url.clone()).unwrap_or(browser.url);
            let surface = browser::new_surface_with_resource_identity(
                content.slot,
                url.clone(),
                size,
                cell_pixels,
                &opts,
                Arc::downgrade(self),
                content.identity.clone(),
            )?;
            surface.set_name(content.name.clone());
            if let (Some(record), Some(runtime)) = (frontend, surface.as_browser()) {
                runtime.set_frontend_location(None, record.title.clone());
            }
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone())?;
            match browser.reconnect {
                RegistryBrowserReconnect::Recreate => {
                    self.start_browser_bootstrap(
                        surface,
                        BrowserBootstrap::Provider { tab_id: content.identity.tab_id.clone(), url },
                        None,
                    );
                }
            }
        }
        Ok(())
    }
}
