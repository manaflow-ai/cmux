//! Committing a prepared resource effect, and staging a legacy workspace row inside one.

use super::*;

impl WorkspaceRegistry {
    /// Stage a legacy workspace row inside a prepared resource effect.
    ///
    /// The outer effect must subsequently commit a full resource projection.
    /// This stage deliberately leaves the public revision and event stream
    /// untouched so one logical creation produces one public batch.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_for_resource_effect(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
    ) -> anyhow::Result<RegistryCommit> {
        self.commit_for_resource_effect_with(
            mutation,
            fingerprint,
            expected_generation,
            expected_revision,
            event_kind,
            workspace_key,
            workspaces,
            active_workspace,
            result,
            None,
        )
    }

    /// [`Self::commit_for_resource_effect`] that also writes `extra` (state
    /// rows such as the ephemeral flag) in the staging transaction, so the
    /// resource projection that later publishes the workspace already sees
    /// them.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_for_resource_effect_with(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
        extra: Option<RegistryTransactionWrite<'_>>,
    ) -> anyhow::Result<RegistryCommit> {
        self.commit_workspace_registry(
            mutation,
            fingerprint,
            expected_generation,
            expected_revision,
            event_kind,
            workspace_key,
            workspaces,
            active_workspace,
            result,
            false,
            extra,
        )
    }

    /// [`Self::commit_resource_effect`] with `extra` written in the same
    /// request-side transaction (a notification's local feed rows, B2).
    pub(crate) fn commit_resource_effect_with(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        outcome: &ResourceEffectOutcome,
        deltas: Option<&Value>,
        extra: Option<RegistryTransactionWrite<'_>>,
    ) -> anyhow::Result<u64> {
        let (intent, finish) = self.prepare_effect_outcome_intent(
            idempotency_key,
            operation,
            fingerprint,
            outcome,
            deltas,
        )?;
        let receipt = self.commit_effect_intent_locally_with(&intent, extra)?;
        Ok(self.finish_effect_commit(finish, receipt)?.revision())
    }
}
