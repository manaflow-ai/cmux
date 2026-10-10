//! Resource effects: the machine service, effect prepare/commit/projection,
//! input receipt HMACs, and resource selector lookups for surfaces.

use super::*;

mod effect_commit;

impl Mux {
    pub fn registry_identity(&self) -> (String, String) {
        let registry = self.workspace_registry.lock().unwrap();
        (registry.registry_id().to_string(), registry.generation().to_string())
    }

    pub fn install_resource_machine_service(
        &self,
        service: Arc<dyn crate::ResourceMachineService>,
    ) -> anyhow::Result<()> {
        self.resource_machine_service
            .set(service)
            .map_err(|_| anyhow::anyhow!("resource machine service is already installed"))
    }

    pub(crate) fn resource_machine_service(
        self: &Arc<Self>,
    ) -> Arc<dyn crate::ResourceMachineService> {
        self.resource_machine_service
            .get_or_init(|| {
                Arc::new(crate::resource_api::LocalResourceMachineService::new(Arc::downgrade(
                    self,
                )))
            })
            .clone()
    }

    pub(crate) fn local_resource_context(
        &self,
    ) -> anyhow::Result<crate::resource_api::LocalResourceContext> {
        let registry = self.workspace_registry.lock().unwrap();
        let topology = registry.resource_topology_snapshot()?;
        Ok(crate::resource_api::LocalResourceContext {
            machine_id: registry.machine_id().clone(),
            session_id: registry.session_id().clone(),
            session_name: self.session.clone(),
            generation: topology.generation,
            revision: topology.revision,
        })
    }

    pub(crate) fn with_resource_projection<R>(
        &self,
        project: impl FnOnce(&WorkspaceRegistry, &State) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let registry = self.workspace_registry.lock().unwrap();
        let state = self.lock_state_pinned(&registry).unwrap();
        project(&registry, &state)
    }

    pub(crate) fn lookup_resource_effect(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<ResourceEffectPreparation>> {
        self.workspace_registry.lock().unwrap().lookup_resource_effect(
            idempotency_key,
            operation,
            fingerprint,
        )
    }

    pub(crate) fn resource_input_receipt_hmac(
        &self,
        idempotency_key: &str,
        operation: &str,
        canonical_fields: &[u8],
    ) -> [u8; 32] {
        self.workspace_registry.lock().unwrap().resource_input_receipt_hmac(
            idempotency_key,
            operation,
            canonical_fields,
        )
    }

    /// Commit an agent report and its resource projection under the sequence
    /// fence used to preserve hook ordering across retries and restarts.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_resource_effect(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        intent: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<ResourceEffectPreparation> {
        self.workspace_registry.lock().unwrap().prepare_resource_effect_for(
            mutation,
            operation,
            fingerprint,
            intent,
            expected_generation,
            expected_revision,
        )
    }

    pub(crate) fn mark_resource_effect_executing(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<Value> {
        self.workspace_registry.lock().unwrap().mark_resource_effect_executing(
            idempotency_key,
            operation,
            fingerprint,
        )
    }

    pub(crate) fn commit_resource_effect(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        outcome: &ResourceEffectOutcome,
        deltas: Option<&Value>,
    ) -> anyhow::Result<u64> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let (intent, finish) = registry.prepare_effect_outcome_intent(
            idempotency_key,
            operation,
            fingerprint,
            outcome,
            deltas,
        )?;
        // The registry stays held across the writer receipt (see
        // effect_commit.rs); the connection and state are not held.
        let revision = self.commit_effect_intent(&mut registry, intent, finish)?.revision();
        if deltas.is_some() {
            self.state.lock().unwrap().resource_revision = revision;
            drop(registry);
            self.publish_resource_event();
        } else {
            drop(registry);
            self.publish_journal_event();
        }
        Ok(revision)
    }

    /// Capture a post-effect live projection and commit its topology, public
    /// deltas, and effect receipt under one registry hold. The registry
    /// keeps every other topology writer out between the captured tree and
    /// its durable revision. State and the connection pin are released
    /// before the journal writer receipt wait (lock order: registry ->
    /// connection -> state; the writer needs the connection), and state is
    /// locked again to install the committed revision. Readers in between see
    /// the pre-commit state and revision, as before publication.
    pub(crate) fn commit_resource_effect_projection(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        project: impl FnOnce(&WorkspaceRegistry, &mut State) -> anyhow::Result<ResourceEffectProjection>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.lock_state_pinned(&registry).unwrap();
        let mut projection = project(&registry, &mut state)?;
        persist_public_topology_result(operation, &mut projection.result, &projection.changes)?;
        #[cfg(test)]
        if let Some(hook) = self.resource_projection_before_commit.lock().unwrap().clone() {
            hook();
        }
        let (intent, finish) = registry.prepare_effect_patch_intent(
            idempotency_key,
            operation,
            fingerprint,
            &projection.patch,
            &projection.result,
            &projection.changes,
            projection.restates_all,
        )?;
        drop(projection);
        drop(state);
        let commit =
            self.commit_effect_intent(&mut registry, intent, finish)?.into_patch_commit()?;
        self.state.lock().unwrap_or_else(PoisonError::into_inner).resource_revision =
            commit.revision;
        drop(registry);
        self.publish_resource_event();
        self.publish_pending_terminal_directories();
        Ok(commit)
    }

    pub(crate) fn commit_full_resource_effect_projection(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        result: Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_effect_projection(
            idempotency_key,
            operation,
            fingerprint,
            |registry, state| self.created_view_projection_locked(registry, state, result),
        )
    }

    /// Reconcile an already-committed local mutation into one public topology
    /// revision. This is reserved for legacy/internal paths whose durable
    /// side effect predates the resource coordinator.
    pub(super) fn commit_ordinary_full_resource_projection(
        &self,
        actor: &Actor,
        operation: &'static str,
        result: Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
        let fingerprint = serde_json::json!({"operation":operation,"result":result});
        self.commit_full_resource_projection_with_mutation(
            &mutation,
            operation,
            &fingerprint,
            result,
        )
    }

    pub(crate) fn commit_full_resource_projection_with_mutation(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        result: Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            operation,
            fingerprint,
            None,
            None,
            |state, registry| {
                let projection = self.resource_effect_projection_locked(registry, state, result)?;
                Ok(ResourceMutationPlan::new(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    |_| {},
                ))
            },
        )
    }

    pub(crate) fn mark_resource_effect_indeterminate(
        &self,
        idempotency_key: &str,
    ) -> anyhow::Result<()> {
        self.workspace_registry.lock().unwrap().mark_resource_effect_indeterminate(idempotency_key)
    }

    pub(crate) fn resource_surface_for_terminal(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> Option<SurfaceId> {
        self.state.lock().unwrap().terminal_catalog.get(terminal_id).map(|surface| surface.id)
    }

    pub(crate) fn resource_selectors_for_pane(
        &self,
        pane: Option<PaneId>,
    ) -> anyhow::Result<crate::ResourceSelectors> {
        let state = self.state.lock().unwrap();
        let pane = pane.or_else(|| state.active_pane()).context("session has no active pane")?;
        let (workspace_index, screen_index) =
            state.screen_of(pane).context("pane has no containing screen")?;
        let workspace = &state.workspaces[workspace_index];
        let screen = &workspace.screens[screen_index];
        let pane =
            state.resource_indexes.pane_ids.get(&pane).context("pane has no public identity")?;
        Ok(crate::ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            workspace: Some(workspace.public_id.to_string()),
            screen: Some(screen.public_id.to_string()),
            pane: Some(pane.to_string()),
            ..crate::ResourceSelectors::default()
        })
    }

    pub(crate) fn resource_selectors_for_workspace(
        &self,
        workspace: Option<WorkspaceId>,
    ) -> anyhow::Result<crate::ResourceSelectors> {
        let state = self.state.lock().unwrap();
        let workspace = match workspace {
            Some(workspace) => state
                .workspaces
                .iter()
                .find(|candidate| candidate.id == workspace)
                .context("workspace does not exist")?,
            None => state
                .workspaces
                .get(state.active_workspace)
                .context("session has no active workspace")?,
        };
        Ok(crate::ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            workspace: Some(workspace.public_id.to_string()),
            ..crate::ResourceSelectors::default()
        })
    }

    pub(crate) fn resource_surface_for_created_path(
        &self,
        result: &Value,
    ) -> anyhow::Result<SurfaceId> {
        let tab = TabPublicId::parse(
            result["tab_id"]
                .as_str()
                .context("creation receipt omitted its tab identity")?
                .to_string(),
        )
        .map_err(anyhow::Error::new)?;
        self.state
            .lock()
            .unwrap()
            .resource_indexes
            .tabs
            .get(&tab)
            .copied()
            .context("created tab no longer has a live view")
    }

    pub(crate) fn has_durable_terminal_receipt(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> anyhow::Result<bool> {
        let registry = self.workspace_registry.lock().unwrap();
        let Some(host_id) = registry.terminal_host_id(terminal_id)? else {
            return Ok(false);
        };
        Ok(registry
            .terminal_record(&host_id)?
            .is_some_and(|terminal| terminal.lifecycle != TerminalLifecycle::Tombstoned))
    }
}
