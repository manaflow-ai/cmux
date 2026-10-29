//! Test-only hooks and seeding: resize/rollback/move interception points, mutation metrics, and seeded launching or running terminals.

use super::*;

impl Mux {
    #[cfg(test)]
    pub(super) fn set_client_resize_before_apply(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.client_resize_before_apply.lock().unwrap() = hook;
    }

    #[cfg(test)]
    pub(crate) fn set_client_rollback_before_wait(
        &self,
        hook: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.client_rollback_before_wait.lock().unwrap() = hook;
    }

    #[cfg(test)]
    pub(super) fn set_terminal_move_before_projection(
        &self,
        hook: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.terminal_move_before_projection.lock().unwrap() = hook;
    }

    /// Runs in `emit_tab_changed` after the tree decorations are read (their
    /// git lookups are the slow part), before the delta is built.
    #[cfg(test)]
    pub(crate) fn set_tab_changed_after_decorations(
        &self,
        hook: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.tab_changed_after_decorations.lock().unwrap_or_else(|e| e.into_inner()) = hook;
    }

    #[cfg(test)]
    pub(super) fn last_resource_mutation_metrics(&self) -> ResourceMutationMetrics {
        self.resource_mutation_metrics
            .lock()
            .unwrap()
            .expect("resource mutation did not record metrics")
    }

    #[cfg(all(test, unix))]
    pub(crate) fn seed_launching_terminal_for_test(
        &self,
        terminal_id: &str,
        workspace_key: &str,
    ) -> anyhow::Result<()> {
        let mut registry = self.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "seed-launching-terminal",
            &RegistryTerminal {
                terminal_id: terminal_id.to_string(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )?;
        Ok(())
    }

    #[cfg(all(test, unix))]
    pub(crate) fn seed_running_terminal_for_test(
        self: &Arc<Self>,
        terminal_id: &str,
        incarnation: &str,
        workspace_key: &str,
    ) -> anyhow::Result<SurfaceId> {
        self.seed_running_terminal_with_on_exit_for_test(
            terminal_id,
            incarnation,
            workspace_key,
            TerminalOnExit::Close,
        )
    }

    #[cfg(all(test, unix))]
    pub(crate) fn seed_running_terminal_with_on_exit_for_test(
        self: &Arc<Self>,
        terminal_id: &str,
        incarnation: &str,
        workspace_key: &str,
        on_exit: TerminalOnExit,
    ) -> anyhow::Result<SurfaceId> {
        let mut registry = self.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "seed-terminal-reservation",
            &RegistryTerminal {
                terminal_id: terminal_id.to_string(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit,
            },
        )?;
        commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "seed-running-terminal",
            terminal_id,
            TerminalLifecycle::Running,
            Some(incarnation),
            None,
        )?;
        let surface = Surface::exited_terminal_placeholder(
            self.next_id(),
            self.surface_options.lock().unwrap().clone(),
            Arc::downgrade(self),
            TerminalHostIdentity {
                terminal_id: terminal_id.to_string(),
                incarnation: incarnation.to_string(),
            },
        )?;
        let mut state = self.state.lock().unwrap();
        insert_surface_checked(&mut state, surface.clone())?;
        let (placement, changed) =
            self.project_terminal_to_workspace_in_state(&mut state, terminal_id, workspace_key)?;
        anyhow::ensure!(changed, "seeded terminal did not change topology");
        anyhow::ensure!(
            placement.is_some_and(|placement| placement.surface == surface.id),
            "seeded terminal projection returned the wrong surface"
        );
        drop(state);
        drop(registry);
        self.commit_ordinary_full_resource_projection(
            &Actor::Daemon,
            "test.terminal.seed",
            serde_json::json!({}),
        )?;
        Ok(surface.id)
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_close_failure_for_test(&self, enabled: bool) -> anyhow::Result<()> {
        self.workspace_registry.lock().unwrap().set_terminal_close_failure(enabled)
    }

    /// Replaces the in-memory test runtime of terminal surface `id` (no
    /// child) with a local PTY running `opts.command`, a real child process,
    /// with the same id, resource identity, pane and catalog entry. The
    /// caller holds no other reference to the old surface: its Kitty budget
    /// reservation is released by the drop before the new one is made.
    #[cfg(test)]
    pub(crate) fn respawn_with_real_child_for_test(
        self: &Arc<Self>,
        id: SurfaceId,
        opts: SurfaceOptions,
    ) -> anyhow::Result<Arc<Surface>> {
        let (old, catalog) = {
            let mut state = self.state.lock().recover_poison();
            let old = state
                .surfaces
                .remove(&id)
                .ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))?;
            let catalog = old
                .terminal_public_id()
                .cloned()
                .filter(|terminal_id| state.remove_catalog_terminal(terminal_id).is_some());
            (old, catalog)
        };
        let identity = old.resource_identity().cloned();
        let cell_pixels = old.cell_pixel_size();
        drop(old);
        let surface = Surface::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
            id,
            opts,
            Arc::downgrade(self),
            crate::surface::HostLaunch::default(),
            identity,
            crate::surface::PtyLifetime::SessionOwned,
            cell_pixels,
        )?;
        let mut state = self.state.lock().recover_poison();
        state.surfaces.insert(id, surface.clone());
        if let Some(terminal_id) = catalog {
            state.insert_catalog_terminal(&terminal_id, &surface)?;
            state.terminal_catalog_by_runtime.insert(id, terminal_id);
        }
        Ok(surface)
    }
}
