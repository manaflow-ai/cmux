//! A keyed create-terminal whose workspace is gone (moved out of mux.rs):
//! a retry of a create whose short-lived process ended and closed its
//! workspace (LAST-TAB-CLOSES-WORKSPACE) replays from its receipt.

use super::*;

impl Mux {
    #[allow(clippy::too_many_arguments)]
    /// `workspace` None: the request's workspace (`workspace_key`) is gone.
    /// A retry of a create whose process ended and closed that workspace
    /// (LAST-TAB-CLOSES-WORKSPACE) still replays from its receipt.
    pub(crate) fn create_raw_terminal_in_workspace_with_mutation(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        workspace_key: &str,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        requested_terminal_id: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        env: Vec<(String, String)>,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_execution = self.resource_creation_execution.lock().unwrap();
        let Some(workspace) = workspace else {
            let fingerprint = terminal_create_fingerprint(
                workspace_key,
                requested_terminal_id,
                argv.as_deref(),
                cwd.as_deref(),
                name.as_deref(),
                size,
                None,
            )?;
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let replay = registry.replay_terminal(mutation, &fingerprint)?;
            drop(registry);
            let terminal_id = replay
                .as_ref()
                .and_then(|replay| replay.result["terminal_id"].as_str())
                .ok_or_else(|| anyhow::anyhow!("unknown workspace key {workspace_key}"))?;
            return self.replayed_terminal_placement(terminal_id);
        };
        self.create_terminal_in_workspace_with_mutation_env(
            workspace,
            argv,
            cwd,
            name,
            size,
            requested_terminal_id,
            expected_generation,
            expected_revision,
            mutation,
            None,
            env,
        )
    }
}
