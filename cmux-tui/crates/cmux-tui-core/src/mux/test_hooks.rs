//! Test-only hooks and seeding: resize/rollback/move interception points, mutation metrics, and seeded launching or running terminals.

use super::*;

impl Mux {
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
}
