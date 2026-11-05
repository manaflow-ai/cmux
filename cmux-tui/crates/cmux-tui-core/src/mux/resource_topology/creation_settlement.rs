//! Resource creation settlement: correlated creation operations, live selector selection, settlement and rollback of interrupted creations, and creation evidence.

use super::*;

impl Mux {
    /// A correlated creation (a terminal tab, pane or workspace). Its
    /// commits are in the WAL when it answers; the registry's syncer makes
    /// them power-loss durable off this path (`wal_durability`). Creations
    /// that wait for the creation fence at the same time run as one group
    /// and share one projection commit (`creation_group`).
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
        crate::debug_spans::mark("creation.start");
        let groupable = expected_revision.is_none() && creation_shares_group_commit(operation);
        let correlation_key =
            fields.get("correlation_key").and_then(Value::as_str).unwrap_or(&mutation.id);
        self.run_in_creation_group(groupable, &[correlation_key, &mutation.id], || {
            self.stage_correlated_creation(
                operation,
                &selector_candidates,
                &fields,
                expected_revision,
                mutation,
                fingerprint,
            )
            .unwrap_or_else(|error| StagedCreationOutcome::Answered(Err(error)))
        })
    }

    /// One creation's own steps, in its group turn under the creation fence:
    /// reconcile, prepare, mark executing and run the effect. A replay or a
    /// failure answers here; an executed creation is staged for the group's
    /// projection commit.
    #[allow(clippy::too_many_arguments)]
    fn stage_correlated_creation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selector_candidates: &[ResourceSelectors],
        fields: &Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<StagedCreationOutcome> {
        let operation_name = operation_name(operation);
        let correlation_key =
            fields.get("correlation_key").and_then(Value::as_str).unwrap_or(&mutation.id);
        self.reconcile_interrupted_resource_creation(correlation_key)?;
        crate::debug_spans::mark("creation.reconciled");
        let effect_fields = semantic_creation_fields(fields);
        let preparation = {
            let mut registry = self.workspace_registry.lock().unwrap();
            crate::debug_spans::mark("creation.registry_locked");
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
                    crate::debug_spans::mark("creation.looked_up");
                    let mut state = self.lock_state_pinned(&registry).unwrap();
                    crate::debug_spans::mark("creation.state_locked");
                    let selectors = self.select_live_creation_selectors(
                        operation,
                        selector_candidates,
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
                    crate::debug_spans::mark("creation.intent_built");
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
        crate::debug_spans::mark("creation.prepared");
        let replayed = match preparation {
            ResourceCreationPreparation::Created { created_path, revision, .. } => {
                ResourcePatchCommit { revision, result: created_path, replayed: true }
            }
            ResourceCreationPreparation::Blocked { idempotency_key, operation } => {
                return Err(anyhow::Error::new(resource_effect_indeterminate(
                    &idempotency_key,
                    &operation,
                )));
            }
            ResourceCreationPreparation::Failed { error, .. } => {
                return Err(anyhow::Error::new(error));
            }
            ResourceCreationPreparation::Execute { idempotency_key, .. } => {
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
                crate::debug_spans::mark("creation.executing_marked");
                self.run_creation_before_effect_hook();
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
                        return Ok(StagedCreationOutcome::Answered(self.settle_failed_creation(
                            recovery,
                            failure,
                            &idempotency_key,
                            &operation_name,
                        )));
                    }
                };
                crate::debug_spans::mark("creation.effect_done");
                return Ok(StagedCreationOutcome::Staged(Box::new(StagedCreation {
                    idempotency_key,
                    operation_name,
                    fingerprint: fingerprint.clone(),
                    result,
                    recovery,
                })));
            }
        };
        Ok(StagedCreationOutcome::Answered(self.activated_creation(replayed)))
    }

    /// Commit one staged creation's projection alone; settle it when the
    /// commit fails.
    pub(super) fn commit_staged_creation(
        &self,
        staged: StagedCreation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        match self.commit_full_resource_effect_projection(
            &staged.idempotency_key,
            &staged.operation_name,
            &staged.fingerprint,
            staged.result.clone(),
        ) {
            Ok(commit) => self.activated_creation(commit),
            Err(error) => self.settle_failed_staged_creation(staged, &error),
        }
    }

    /// Settle a staged creation whose projection commit failed with `error`.
    pub(super) fn settle_failed_staged_creation(
        &self,
        staged: StagedCreation,
        error: &anyhow::Error,
    ) -> anyhow::Result<ResourcePatchCommit> {
        #[cfg(test)]
        eprintln!("correlated resource creation projection commit failed: {error:#}");
        let StagedCreation { idempotency_key, operation_name, recovery, .. } = staged;
        let failure = resource_creation_failure(&recovery, error);
        self.settle_failed_creation(recovery, failure, &idempotency_key, &operation_name)
            .and_then(|commit| self.activated_creation(commit))
    }

    /// A created (or replayed) creation's answer, once its hosted launch
    /// may stream.
    pub(super) fn activated_creation(
        &self,
        commit: ResourcePatchCommit,
    ) -> anyhow::Result<ResourcePatchCommit> {
        crate::debug_spans::mark("creation.projection_committed");
        self.activate_created_terminal_launch(&commit.result)?;
        crate::debug_spans::mark("creation.launch_activated");
        Ok(commit)
    }

    /// Settle a creation that failed and answer the caller. When the
    /// settlement itself fails (its rollback or its receipt is a write, and
    /// a full disk refuses it), the error is logged and the caller gets the
    /// creation's own failure, which names the cause ("database or disk is
    /// full"), not the settlement's. Memory was rolled back before any of
    /// those writes, and the receipt stays unsettled: a retry with the same
    /// key is blocked, and the next start settles it.
    fn settle_failed_creation(
        &self,
        recovery: ResourceCreationRecovery,
        failure: ResourceError,
        idempotency_key: &str,
        operation_name: &str,
    ) -> anyhow::Result<ResourcePatchCommit> {
        match self.settle_resource_creation(recovery, Some(failure.clone())) {
            Ok(settlement) => {
                creation_settlement_result(settlement, idempotency_key, operation_name)
            }
            Err(error) => {
                eprintln!(
                    "cmux-tui: the failed creation {idempotency_key} ({operation_name}) could not be \
                     settled: {error:#}"
                );
                Err(anyhow::Error::new(failure))
            }
        }
    }

    /// Release the launch barrier of the terminal a creation made: its host
    /// sends none of the shell's output until then, with no deadline.
    ///
    /// The barrier belongs to the terminal's runtime, not to the tab that
    /// made it. A tab strip change takes no creation fence, so the new tab
    /// can leave before this runs while its terminal keeps running (closing
    /// a view never ends a terminal). The runtime is therefore found in the
    /// terminal catalog; a lookup through the tab missed it and left the
    /// host waiting for ever, an empty screen wherever the terminal showed
    /// again (open-P0 close-then-type, build dd832e31).
    pub(super) fn activate_created_terminal_launch(&self, result: &Value) -> anyhow::Result<()> {
        let Some(terminal_id) = result.get("terminal_id").and_then(Value::as_str) else {
            return Ok(());
        };
        let terminal_id =
            TerminalPublicId::parse(terminal_id.to_string()).map_err(anyhow::Error::new)?;
        let (runtime, tab_left) = {
            let state = self.state.lock().unwrap();
            let tab_left = result
                .get("tab_id")
                .and_then(Value::as_str)
                .and_then(|tab| TabPublicId::parse(tab.to_string()).ok())
                .is_some_and(|tab| !state.resource_indexes.tabs.contains_key(&tab));
            (state.terminal_catalog.get(&terminal_id).cloned(), tab_left)
        };
        let Some(runtime) = runtime else {
            // The terminal ended or was closed (its close ends the host), or
            // a replay outlived it: no host waits for this barrier.
            if tab_left {
                eprintln!(
                    "cmux-tui: created terminal {terminal_id} has no runtime at its launch \
                     activation; nothing to release"
                );
            }
            return Ok(());
        };
        let released = runtime.activate_hosted_launch_stream()?;
        if released && tab_left {
            eprintln!(
                "cmux-tui: created terminal {terminal_id} lost its tab before its launch \
                 activation; activated through its runtime"
            );
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
                // The terminal's outcome is unknown, but the creation did not
                // report success: a workspace it staged does not stay behind,
                // and neither does its terminal with no view.
                if recovery.intent.get("workspace_reservation").is_some()
                    && let Some(terminal_id) = recovery
                        .intent
                        .get("terminal_reservation")
                        .and_then(|reservation| reservation.get("terminal_id"))
                        .and_then(Value::as_str)
                    && let Err(error) = self.close_unpublished_terminal(terminal_id)
                {
                    eprintln!(
                        "cmux-tui: a failed creation's terminal could not be closed: {error:#}"
                    );
                }
                self.rollback_interrupted_workspace_creation(&recovery.intent)?;
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

    /// Roll back the workspace a creation staged, when it is not public.
    /// Memory always lets it go, even when the store refuses the close.
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
        let Some(workspace) = workspace else {
            return Ok(());
        };
        match self.close_workspace_at_revision_for_resource_effect(&Actor::Daemon, workspace) {
            Ok(Some(_)) => Ok(()),
            Ok(None) => {
                anyhow::bail!(
                    "interrupted staged workspace {public_id} disappeared during rollback"
                )
            }
            Err(error) => {
                // The store refused the close (a full disk). The workspace
                // still leaves memory and its subscribers, so no client shows
                // a workspace the store never published (fuzz restore h1).
                // The error goes on, so the receipt stays unsettled and the
                // creation's recovery closes the stored row later.
                match self.discard_unpublished_workspace_from_memory(workspace) {
                    Ok(_) => eprintln!(
                        "cmux-tui: staged workspace {public_id} left memory, but the store \
                         refused its close: {error:#}"
                    ),
                    Err(discard) => eprintln!(
                        "cmux-tui: the store refused the close of staged workspace {public_id} \
                         ({error:#}), and it stays in memory: {discard}"
                    ),
                }
                Err(error)
            }
        }
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
