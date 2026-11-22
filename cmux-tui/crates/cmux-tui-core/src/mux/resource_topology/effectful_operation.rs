//! The effectful resource topology operation path: idempotent effects that create, close or reshape topology.

use super::*;

impl Mux {
    #[allow(clippy::too_many_arguments)]
    pub(super) fn resource_effectful_topology_operation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selectors: ResourceSelectors,
        fields: Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        if is_created_path_operation(operation) {
            return self.resource_correlated_creation_operation(
                operation,
                vec![selectors],
                fields,
                expected_revision,
                mutation,
                fingerprint,
            );
        }
        let _creation_handoff = is_resource_close_operation(operation)
            .then(|| self.resource_creation_handoff.lock().unwrap());
        let _creation_fence = is_resource_close_operation(operation)
            .then(|| self.resource_creation_execution.lock().unwrap());
        let operation_name = operation_name(operation);
        let preparation = {
            let mut registry = self.workspace_registry.lock().unwrap();
            if let Some(preparation) =
                registry.lookup_resource_effect(&mutation.id, &operation_name, fingerprint)?
            {
                preparation
            } else {
                let mut state = self.state.lock().unwrap();
                let intent = self.resource_topology_effect_intent(
                    operation,
                    &selectors,
                    &fields,
                    ResourceEffectIntentContext { expected_revision, mutation },
                    &mut state,
                    &registry,
                )?;
                registry.prepare_resource_effect_for(
                    mutation,
                    &operation_name,
                    fingerprint,
                    &intent,
                    None,
                    expected_revision,
                )?
            }
        };
        match preparation {
            ResourceEffectPreparation::Committed { outcome, revision } => match outcome {
                ResourceEffectOutcome::Success(result) => {
                    Ok(ResourcePatchCommit { revision, result, replayed: true })
                }
                ResourceEffectOutcome::Failure(error) => Err(anyhow::Error::new(error)),
            },
            ResourceEffectPreparation::Indeterminate => Err(anyhow::Error::new(
                resource_effect_indeterminate(&mutation.id, &operation_name),
            )),
            ResourceEffectPreparation::Execute { .. } => {
                let intent = self.mark_resource_effect_executing(
                    &mutation.id,
                    &operation_name,
                    fingerprint,
                )?;
                if is_resource_close_operation(operation) {
                    let committed = match self.commit_resource_close_effect(
                        operation,
                        &intent,
                        &mutation.id,
                        &operation_name,
                        fingerprint,
                    ) {
                        Ok(committed) => committed,
                        Err(error) => {
                            // A refused home close is a typed, committed failure.
                            let error = crate::state::home_store::resource_error(&error)
                                .unwrap_or_else(|| {
                                    ResourceError::operation_failed(
                                        &operation_name,
                                        format!("{error:#}"),
                                        json!({"idempotency_key":mutation.id}),
                                    )
                                });
                            if self
                                .commit_resource_effect(
                                    &mutation.id,
                                    &operation_name,
                                    fingerprint,
                                    &ResourceEffectOutcome::Failure(error.clone()),
                                    None,
                                )
                                .is_ok()
                            {
                                return Err(anyhow::Error::new(error));
                            } else {
                                let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                                return Err(anyhow::Error::new(resource_effect_indeterminate(
                                    &mutation.id,
                                    &operation_name,
                                )));
                            }
                        }
                    };
                    drop(_creation_fence);
                    drop(_creation_handoff);
                    return Ok(self.finish_resource_close(committed));
                }
                let result = match self.execute_resource_topology_effect(
                    &mutation.actor,
                    operation,
                    &intent,
                ) {
                    Ok(result) => result,
                    Err(error)
                        if error
                            .downcast_ref::<ResourceError>()
                            .is_some_and(|error| error.code == "confirmation.required")
                            || crate::state::home_store::resource_error(&error).is_some() =>
                    {
                        let error = crate::state::home_store::resource_error(&error)
                            .or_else(|| error.downcast_ref::<ResourceError>().cloned())
                            .expect("checked");
                        let outcome = ResourceEffectOutcome::Failure(error.clone());
                        if self
                            .commit_resource_effect(
                                &mutation.id,
                                &operation_name,
                                fingerprint,
                                &outcome,
                                None,
                            )
                            .is_ok()
                        {
                            return Err(anyhow::Error::new(error));
                        }
                        let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                        return Err(anyhow::Error::new(resource_effect_indeterminate(
                            &mutation.id,
                            &operation_name,
                        )));
                    }
                    Err(error)
                        if operation == ResourceOperation::ScreenLayoutUndo
                            && error.downcast_ref::<LayoutUndoError>().is_some() =>
                    {
                        // A stale undo is rejected before it changes live or durable state.
                        // Preserve that deterministic race as a committed revision conflict
                        // instead of poisoning the idempotency key as indeterminate.
                        let Some(expected) = expected_revision else {
                            let error = ResourceError::operation_failed(
                                &operation_name,
                                format!("{error:#}"),
                                json!({"idempotency_key":mutation.id}),
                            );
                            if self
                                .commit_resource_effect(
                                    &mutation.id,
                                    &operation_name,
                                    fingerprint,
                                    &ResourceEffectOutcome::Failure(error.clone()),
                                    None,
                                )
                                .is_ok()
                            {
                                return Err(anyhow::Error::new(error));
                            }
                            let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                            return Err(anyhow::Error::new(resource_effect_indeterminate(
                                &mutation.id,
                                &operation_name,
                            )));
                        };
                        let actual = match self
                            .workspace_registry
                            .lock()
                            .unwrap()
                            .resource_topology_snapshot()
                        {
                            Ok(snapshot) => snapshot.revision,
                            Err(_) => {
                                let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                                return Err(anyhow::Error::new(resource_effect_indeterminate(
                                    &mutation.id,
                                    &operation_name,
                                )));
                            }
                        };
                        let error = ResourceError::revision_conflict(expected, actual);
                        if self
                            .commit_resource_effect(
                                &mutation.id,
                                &operation_name,
                                fingerprint,
                                &ResourceEffectOutcome::Failure(error.clone()),
                                None,
                            )
                            .is_ok()
                        {
                            return Err(anyhow::Error::new(error));
                        }
                        let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                        return Err(anyhow::Error::new(resource_effect_indeterminate(
                            &mutation.id,
                            &operation_name,
                        )));
                    }
                    Err(_error) => {
                        #[cfg(test)]
                        eprintln!("resource topology effect execution failed: {_error:#}");
                        let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                        return Err(anyhow::Error::new(resource_effect_indeterminate(
                            &mutation.id,
                            &operation_name,
                        )));
                    }
                };
                match self.commit_full_resource_effect_projection(
                    &mutation.id,
                    &operation_name,
                    fingerprint,
                    result,
                ) {
                    Ok(commit) => Ok(commit),
                    Err(_error) => {
                        #[cfg(test)]
                        eprintln!("resource topology effect projection commit failed: {_error:#}");
                        let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                        Err(anyhow::Error::new(resource_effect_indeterminate(
                            &mutation.id,
                            &operation_name,
                        )))
                    }
                }
            }
        }
    }
}
