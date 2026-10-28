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

    /// Runs at the start of every terminal spawn, before its PTY exists, on
    /// the thread that spawns it: a test holds a create there (its terminal
    /// is still creating) for as long as the hook blocks.
    #[cfg(test)]
    pub(crate) fn set_terminal_spawn_start_hook_for_test(
        &self,
        hook: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.terminal_spawn_after_cell_pixel_snapshot.lock().unwrap() =
            hook.map(|hook| Arc::new(move |_unlocked: bool| hook()) as _);
    }

    /// Runs with each test-runtime terminal a reserved create spawns, before
    /// it is published: a test installs its PTY capture there, before any
    /// input queued for the terminal is written.
    #[cfg(test)]
    pub(crate) fn set_terminal_spawned_hook_for_test(
        &self,
        hook: Option<TerminalSpawnBeforeCellPixelReconcileHook>,
    ) {
        *self.terminal_spawn_before_cell_pixel_reconcile.lock().unwrap() = hook;
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
}
