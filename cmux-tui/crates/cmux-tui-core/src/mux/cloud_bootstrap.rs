//! Cloud reserves its initial workspace before accepting clients, but starts
//! the shell only after attach preparation has installed the machine's grant.

use super::*;

impl Mux {
    /// Returns false for a pre-existing registry, whose sessions keep the
    /// existing bootstrap behavior. A fresh Cloud workspace has a durable key
    /// before any client can race to create its first terminal.
    pub fn reserve_cloud_initial_workspace(self: &Arc<Self>) -> anyhow::Result<bool> {
        let _bootstrap = self.lock_initial_bootstrap();
        let reservation = self.workspace_registry.lock().unwrap().reserve_cloud_bootstrap(
            &Self::new_workspace_key()?,
            &TerminalId::random()?.to_hex(),
        )?;
        let Some(reservation) = reservation else { return Ok(false) };
        let created = self
            .workspace_registry
            .lock()
            .unwrap()
            .cloud_bootstrap_workspace_created(&reservation.workspace_key)?;
        if !reservation.finished && !created {
            self.create_empty_workspace_with_mutation(
                None,
                Some(reservation.workspace_key.clone()),
                None,
                None,
                &WorkspaceMutation::new(
                    format!("cloud-workspace-{}", reservation.terminal_id),
                    "cloud-bootstrap",
                )?,
            )?;
        }
        Ok(true)
    }

    /// Local control-plane preparation only: no caller-supplied command or
    /// workspace selector. The stored identities own retries and concurrency.
    pub fn start_cloud_initial_terminal(self: &Arc<Self>, welcome: bool) -> anyhow::Result<()> {
        let _bootstrap = self.lock_initial_bootstrap();
        let reservation = self.workspace_registry.lock().unwrap().cloud_bootstrap()?;
        let Some(reservation) = reservation.filter(|entry| !entry.finished) else { return Ok(()) };
        let workspace = self.with_state(|state| {
            state
                .workspaces
                .iter()
                .find(|workspace| workspace.key == reservation.workspace_key)
                .map(|workspace| workspace.id)
        });
        let Some(workspace) = workspace else {
            // An explicitly deleted starter workspace must never be recreated.
            self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
            return Ok(());
        };
        if self
            .workspace_registry
            .lock()
            .unwrap()
            .cloud_bootstrap_has_other_terminal(&reservation)?
        {
            // A caller already supplied initial content. Never overwrite it or
            // type into it, even if the account still has an unused grant.
            self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
            return Ok(());
        }
        let command = self.surface_options.lock().unwrap().command.clone();
        let argv = cloud_initial_argv(command, welcome);
        let mutation = WorkspaceMutation::new(
            format!("cloud-terminal-{}", reservation.terminal_id),
            "cloud-bootstrap",
        )?;
        let created = self.create_raw_terminal_in_workspace_with_mutation(
            workspace,
            argv,
            None,
            None,
            None,
            Some(&reservation.terminal_id),
            None,
            None,
            &mutation,
        )?;
        let projection = serde_json::json!({
            "terminal_id": created.terminal_id,
            "workspace_key": reservation.workspace_key,
        });
        self.commit_full_resource_projection_with_mutation(
            &mutation,
            "raw.terminal.create",
            &projection,
            projection.clone(),
        )?;
        self.activate_created_terminal_surface(created.created_surface)?;
        self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
        Ok(())
    }
}

fn cloud_initial_argv(command: Option<Vec<String>>, welcome: bool) -> Option<Vec<String>> {
    // Explicit startup commands (including agents) keep their original argv.
    if !welcome || command.is_some() {
        return command;
    }
    Some(vec![
        "/bin/sh".into(),
        "-c".into(),
        "if [ -x /usr/local/bin/cmux ]; then /usr/local/bin/cmux welcome --auto 2>/dev/null || :; fi; exec \"$@\"".into(),
        "cmux-cloud-initial-shell".into(),
        platform::default_shell(),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mux() -> Arc<Mux> {
        Mux::new_for_test("cloud-bootstrap", SurfaceOptions::default())
    }

    #[test]
    fn cloud_bootstrap_defers_shell_and_serializes_first_attachments() {
        let mux = mux();
        assert!(mux.reserve_cloud_initial_workspace().unwrap());
        let first = mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert!(state.surfaces.is_empty());
            state.workspaces[0].id
        });
        assert!(mux.rename_workspace(first, "my project".into()));
        let threads = (0..8)
            .map(|_| {
                let mux = mux.clone();
                std::thread::spawn(move || mux.start_cloud_initial_terminal(true).unwrap())
            })
            .collect::<Vec<_>>();
        for thread in threads {
            thread.join().unwrap();
        }
        let before = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
        assert_eq!(before.terminals.len(), 1);
        mux.start_cloud_initial_terminal(true).unwrap();
        assert!(mux.reserve_cloud_initial_workspace().unwrap());
        let after = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
        assert_eq!(before, after);
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, first);
            assert_eq!(state.workspaces[0].name, "my project");
        });
    }

    #[test]
    fn cloud_bootstrap_does_not_claim_preexisting_or_deleted_workspaces() {
        let existing = mux();
        let workspace = existing.create_empty_workspace(None, None, None).unwrap();
        assert!(existing.close_workspace(workspace.workspace));
        assert!(!existing.reserve_cloud_initial_workspace().unwrap());
        existing.start_cloud_initial_terminal(true).unwrap();
        assert!(existing.with_state(|state| state.workspaces.is_empty()));

        let deleted = mux();
        deleted.reserve_cloud_initial_workspace().unwrap();
        let first = deleted.with_state(|state| state.workspaces[0].id);
        assert!(deleted.close_workspace(first));
        // Simulate startup's reservation recovery before a later attach.
        assert!(deleted.reserve_cloud_initial_workspace().unwrap());
        assert!(deleted.with_state(|state| state.workspaces.is_empty()));
        deleted.start_cloud_initial_terminal(true).unwrap();
        deleted.reserve_cloud_initial_workspace().unwrap();
        assert!(deleted.with_state(|state| state.workspaces.is_empty()));
    }

    #[test]
    fn cloud_bootstrap_leaves_user_startup_content_untouched() {
        let mux = mux();
        mux.reserve_cloud_initial_workspace().unwrap();
        let first = mux.with_state(|state| state.workspaces[0].id);
        mux.create_terminal_in_workspace(
            first,
            Some(vec!["user-command".into()]),
            None,
            None,
            None,
        )
        .unwrap();
        let before = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
        mux.start_cloud_initial_terminal(true).unwrap();
        let after = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
        assert_eq!(before, after);
    }

    #[test]
    fn cloud_bootstrap_retries_failed_creation_without_an_extra_workspace() {
        let mux = mux();
        mux.reserve_cloud_initial_workspace().unwrap();
        let first = mux.with_state(|state| state.workspaces[0].key.clone());
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
        assert!(mux.start_cloud_initial_terminal(true).is_err());
        assert!(
            !mux.workspace_registry.lock().unwrap().cloud_bootstrap().unwrap().unwrap().finished
        );
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
        mux.start_cloud_initial_terminal(true).unwrap();
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].key, first);
        });
        assert_eq!(
            mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap().terminals.len(),
            1
        );
    }

    #[test]
    fn cloud_bootstrap_preserves_explicit_argv_and_skips_ineligible_shells() {
        let command = Some(vec!["codex".into(), "exec".into(), "keep this input".into()]);
        assert_eq!(cloud_initial_argv(command.clone(), true), command);
        assert_eq!(cloud_initial_argv(None, false), None);
        let command = cloud_initial_argv(None, true).unwrap();
        assert_eq!(command.last(), Some(&platform::default_shell()));
    }
}
