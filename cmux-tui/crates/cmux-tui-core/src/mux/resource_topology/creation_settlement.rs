//! Resource creation settlement: correlated creation operations, live selector selection, settlement and rollback of interrupted creations, and creation evidence.

use super::*;

impl Mux {
    #[allow(clippy::too_many_arguments)]
    pub(super) fn resource_correlated_creation_operation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selector_candidates: Vec<ResourceSelectors>,
        fields: Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        debug_assert!(is_created_path_operation(operation));
        let _execution = self.resource_creation_execution.lock().unwrap();
        let operation_name = operation_name(operation);
        let correlation_key =
            fields.get("correlation_key").and_then(Value::as_str).unwrap_or(&mutation.id);
        self.reconcile_interrupted_resource_creation(correlation_key)?;
        let effect_fields = semantic_creation_fields(&fields);
        let preparation = {
            let mut registry = self.workspace_registry.lock().unwrap();
            match registry.lookup_resource_creation(
                correlation_key,
                &mutation.id,
                &operation_name,
                fingerprint,
                true,
            )? {
                Some(ResourceCreationPreparation::Execute { intent, .. }) => registry
                    .prepare_resource_creation_for(
                        correlation_key,
                        mutation,
                        &operation_name,
                        fingerprint,
                        &intent,
                        true,
                        None,
                        expected_revision,
                    )?,
                Some(preparation) => preparation,
                None => {
                    let mut state = self.state.lock().unwrap();
                    let selectors = self.select_live_creation_selectors(
                        operation,
                        &selector_candidates,
                        &state,
                        &registry,
                    )?;
                    let intent = self.resource_topology_effect_intent(
                        operation,
                        selectors,
                        &effect_fields,
                        ResourceEffectIntentContext { expected_revision, mutation },
                        &mut state,
                        &registry,
                    )?;
                    registry.prepare_resource_creation_for(
                        correlation_key,
                        mutation,
                        &operation_name,
                        fingerprint,
                        &intent,
                        true,
                        None,
                        expected_revision,
                    )?
                }
            }
        };
        let commit = match preparation {
            ResourceCreationPreparation::Created { created_path, revision, .. } => {
                Ok(ResourcePatchCommit { revision, result: created_path, replayed: true })
            }
            ResourceCreationPreparation::Blocked { idempotency_key, operation } => {
                Err(anyhow::Error::new(resource_effect_indeterminate(&idempotency_key, &operation)))
            }
            ResourceCreationPreparation::Failed { error, .. } => Err(anyhow::Error::new(error)),
            ResourceCreationPreparation::Execute { idempotency_key, .. } => {
                let _activity = ResourceCreationActivity::begin(&self.resource_creation_active);
                let intent = self.mark_resource_effect_executing(
                    &idempotency_key,
                    &operation_name,
                    fingerprint,
                )?;
                let recovery = self
                    .workspace_registry
                    .lock()
                    .unwrap()
                    .resource_creation_recovery(correlation_key)?
                    .context("executing resource creation omitted its recovery record")?;
                let result = match self.execute_resource_topology_effect(
                    &mutation.actor,
                    operation,
                    &intent,
                ) {
                    Ok(result) => result,
                    Err(error) => {
                        #[cfg(test)]
                        eprintln!("correlated resource creation failed: {error:#}");
                        let failure = resource_creation_failure(&recovery, &error);
                        return creation_settlement_result(
                            self.settle_resource_creation(recovery, Some(failure))?,
                            &idempotency_key,
                            &operation_name,
                        );
                    }
                };
                match self.commit_full_resource_effect_projection(
                    &idempotency_key,
                    &operation_name,
                    fingerprint,
                    result,
                ) {
                    Ok(commit) => Ok(commit),
                    Err(error) => {
                        #[cfg(test)]
                        eprintln!(
                            "correlated resource creation projection commit failed: {error:#}"
                        );
                        let failure = resource_creation_failure(&recovery, &error);
                        creation_settlement_result(
                            self.settle_resource_creation(recovery, Some(failure))?,
                            &idempotency_key,
                            &operation_name,
                        )
                    }
                }
            }
        }?;
        self.activate_created_terminal_launch(&commit.result)?;
        Ok(commit)
    }

    pub(super) fn activate_created_terminal_launch(&self, result: &Value) -> anyhow::Result<()> {
        if result.get("terminal_id").and_then(Value::as_str).is_none() {
            return Ok(());
        }
        let Some(tab_id) = result.get("tab_id").and_then(Value::as_str) else {
            return Ok(());
        };
        let tab_id = TabPublicId::parse(tab_id.to_string()).map_err(anyhow::Error::new)?;
        let Some(surface_id) =
            self.state.lock().unwrap().resource_indexes.tabs.get(&tab_id).copied()
        else {
            // A replay can outlive its detached terminal view. There is no
            // launch barrier to release in that case.
            return Ok(());
        };
        if let Some(surface) = self.surface(surface_id) {
            surface.activate_hosted_launch_stream()?;
        }
        Ok(())
    }

    pub(super) fn select_live_creation_selectors<'a>(
        &self,
        operation: ResourceOperation,
        candidates: &'a [ResourceSelectors],
        state: &State,
        registry: &WorkspaceRegistry,
    ) -> anyhow::Result<&'a ResourceSelectors> {
        let mut last_missing = None;
        for selectors in candidates {
            let target = effect_target(operation, selectors);
            match self.resolve_resource_path_in_state(state, registry, target, selectors) {
                Ok(_) => return Ok(selectors),
                Err(error) if error.code == "selector.not_found" => last_missing = Some(error),
                Err(error) => return Err(anyhow::Error::new(error)),
            }
        }
        Err(anyhow::Error::new(
            last_missing.expect("non-empty candidates either resolve or report missing"),
        ))
    }

    pub(super) fn settle_resource_creation(
        &self,
        recovery: ResourceCreationRecovery,
        failure: Option<ResourceError>,
    ) -> anyhow::Result<ResourceCreationSettlement> {
        match self.resource_creation_evidence(&recovery)? {
            ResourceCreationEvidence::Created(created_path) => {
                match self.commit_full_resource_effect_projection(
                    &recovery.idempotency_key,
                    &recovery.operation,
                    &recovery.fingerprint,
                    created_path,
                ) {
                    Ok(commit) => Ok(ResourceCreationSettlement::Created(commit)),
                    Err(error) => self.settle_unpublished_creation(&recovery, failure, error),
                }
            }
            ResourceCreationEvidence::NotApplied(reason) => {
                self.rollback_interrupted_workspace_creation(&recovery.intent)?;
                let error = failure.unwrap_or_else(|| {
                    ResourceError::operation_failed(
                        &recovery.operation,
                        reason,
                        json!({
                            "correlation_key":recovery.correlation_key,
                            "attempt":recovery.attempt,
                        }),
                    )
                });
                match self.commit_resource_effect(
                    &recovery.idempotency_key,
                    &recovery.operation,
                    &recovery.fingerprint,
                    &ResourceEffectOutcome::Failure(error.clone()),
                    None,
                ) {
                    Ok(_) => Ok(ResourceCreationSettlement::NotApplied(error)),
                    Err(_) => {
                        if let Some(settlement) = self.persisted_creation_settlement(&recovery)? {
                            return Ok(settlement);
                        }
                        self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                        Ok(ResourceCreationSettlement::Indeterminate)
                    }
                }
            }
            ResourceCreationEvidence::Ambiguous => {
                self.rollback_interrupted_workspace_creation(&recovery.intent)?;
                self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                Ok(ResourceCreationSettlement::Indeterminate)
            }
            ResourceCreationEvidence::AmbiguousLive => {
                self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                Ok(ResourceCreationSettlement::Indeterminate)
            }
            ResourceCreationEvidence::Pending => Ok(ResourceCreationSettlement::Pending),
            ResourceCreationEvidence::TerminalClosedAfterFailure => {
                let Some(error) = failure else {
                    self.rollback_interrupted_workspace_creation(&recovery.intent)?;
                    self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                    return Ok(ResourceCreationSettlement::Indeterminate);
                };
                self.rollback_interrupted_workspace_creation(&recovery.intent)?;
                match self.commit_resource_effect(
                    &recovery.idempotency_key,
                    &recovery.operation,
                    &recovery.fingerprint,
                    &ResourceEffectOutcome::Failure(error.clone()),
                    None,
                ) {
                    Ok(_) => Ok(ResourceCreationSettlement::NotApplied(error)),
                    Err(_) => {
                        if let Some(settlement) = self.persisted_creation_settlement(&recovery)? {
                            return Ok(settlement);
                        }
                        self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                        Ok(ResourceCreationSettlement::Indeterminate)
                    }
                }
            }
        }
    }

    pub(super) fn rollback_interrupted_workspace_creation(
        &self,
        intent: &Value,
    ) -> anyhow::Result<()> {
        let Some(reservation) = intent.get("workspace_reservation") else {
            return Ok(());
        };
        let public_id = WorkspacePublicId::parse(
            reservation["workspace_public_id"]
                .as_str()
                .context("stored workspace reservation omitted its public id")?
                .to_string(),
        )?;
        if self
            .workspace_registry
            .lock()
            .unwrap()
            .resource_topology_snapshot()?
            .active_screens
            .iter()
            .any(|(workspace, _)| workspace == &public_id)
        {
            return Ok(());
        }
        let workspace =
            self.state.lock().unwrap().resource_indexes.workspaces.get(&public_id).copied();
        if let Some(workspace) = workspace {
            anyhow::ensure!(
                self.close_workspace_at_revision_for_resource_effect(&Actor::Daemon, workspace)?
                    .is_some(),
                "interrupted staged workspace {public_id} disappeared during rollback"
            );
        }
        Ok(())
    }

    pub(super) fn persisted_creation_settlement(
        &self,
        recovery: &ResourceCreationRecovery,
    ) -> anyhow::Result<Option<ResourceCreationSettlement>> {
        let preparation = self.workspace_registry.lock().unwrap().lookup_resource_creation(
            &recovery.correlation_key,
            &recovery.idempotency_key,
            &recovery.operation,
            &recovery.fingerprint,
            true,
        )?;
        Ok(match preparation {
            Some(ResourceCreationPreparation::Created { created_path, revision, .. }) => {
                Some(ResourceCreationSettlement::Created(ResourcePatchCommit {
                    revision,
                    result: created_path,
                    replayed: true,
                }))
            }
            Some(ResourceCreationPreparation::Failed { error, .. }) => {
                Some(ResourceCreationSettlement::NotApplied(error))
            }
            _ => None,
        })
    }

    pub(super) fn resource_creation_evidence(
        &self,
        recovery: &ResourceCreationRecovery,
    ) -> anyhow::Result<ResourceCreationEvidence> {
        let operation: ResourceOperation =
            serde_json::from_value(Value::String(recovery.operation.clone()))
                .context("stored resource creation has an invalid operation")?;
        let fields = recovery.intent["fields"].as_object().cloned().unwrap_or_default();
        match creation_identity_kind(operation, &fields) {
            Some(CreatedIdentityKind::Browser) => {
                self.browser_creation_evidence(&recovery.intent, recovery.interrupted)
            }
            Some(CreatedIdentityKind::Terminal) => {
                self.terminal_creation_evidence(&recovery.intent, recovery.interrupted)
            }
            None => Ok(ResourceCreationEvidence::Ambiguous),
        }
    }

    pub(super) fn browser_creation_evidence(
        &self,
        intent: &Value,
        interrupted: bool,
    ) -> anyhow::Result<ResourceCreationEvidence> {
        let expected = self.effect_browser_reservation(intent)?;
        let surface = {
            let state = self.state.lock().unwrap();
            let mut matches = state
                .surfaces
                .values()
                .filter(|surface| surface.resource_identity() == Some(&expected))
                .map(|surface| surface.id);
            let first = matches.next();
            if matches.next().is_some() {
                return Ok(if interrupted {
                    ResourceCreationEvidence::Pending
                } else {
                    ResourceCreationEvidence::AmbiguousLive
                });
            }
            first
        };
        if let Some(surface) = surface {
            return Ok(match self.created_resource_path(surface) {
                Ok(path) => ResourceCreationEvidence::Created(path),
                Err(_) if interrupted => ResourceCreationEvidence::Pending,
                Err(_) => ResourceCreationEvidence::AmbiguousLive,
            });
        }
        Ok(if self.reserved_workspace_exists(intent)? {
            ResourceCreationEvidence::Ambiguous
        } else {
            ResourceCreationEvidence::NotApplied(
                "reserved browser identity is absent after creation reconciliation",
            )
        })
    }

    pub(super) fn terminal_creation_evidence(
        &self,
        intent: &Value,
        interrupted: bool,
    ) -> anyhow::Result<ResourceCreationEvidence> {
        let terminal_id = intent["terminal_reservation"]["terminal_id"]
            .as_str()
            .context("stored topology intent omitted its terminal reservation")?;
        let resolution = self.resolve_terminal(terminal_id)?;
        let Some(resolution) = resolution else {
            return Ok(if self.reserved_workspace_exists(intent)? {
                ResourceCreationEvidence::Ambiguous
            } else {
                ResourceCreationEvidence::NotApplied(
                    "reserved terminal identity is absent after creation reconciliation",
                )
            });
        };
        if let Some(surface) = resolution.surface {
            return Ok(match self.created_resource_path(surface) {
                Ok(path) => ResourceCreationEvidence::Created(path),
                Err(_) if interrupted => ResourceCreationEvidence::Pending,
                Err(_) => ResourceCreationEvidence::AmbiguousLive,
            });
        }
        Ok(match resolution.terminal.lifecycle {
            TerminalLifecycle::Launching
            | TerminalLifecycle::Adopting
            | TerminalLifecycle::Running
                if interrupted =>
            {
                ResourceCreationEvidence::Pending
            }
            TerminalLifecycle::Launching
            | TerminalLifecycle::Adopting
            | TerminalLifecycle::Running => ResourceCreationEvidence::AmbiguousLive,
            TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned => {
                ResourceCreationEvidence::TerminalClosedAfterFailure
            }
        })
    }

    pub(super) fn reserved_workspace_exists(&self, intent: &Value) -> anyhow::Result<bool> {
        let Some(reservation) = intent.get("workspace_reservation") else {
            return Ok(false);
        };
        let key = reservation["workspace_key"]
            .as_str()
            .context("stored workspace reservation omitted its key")?;
        Ok(self.state.lock().unwrap().workspaces.iter().any(|workspace| workspace.key == key))
    }
}
