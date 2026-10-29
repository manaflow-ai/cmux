//! Fixed owner update jobs use the existing correlated creation journal.
//! Stable intent is independent of registry versions and mutable argv.

use sha2::{Digest, Sha256};
use std::fmt;

use super::*;

#[derive(Debug)]
pub(crate) struct AgentCLIJobBusy;

impl fmt::Display for AgentCLIJobBusy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("an agent update job is being prepared")
    }
}

impl std::error::Error for AgentCLIJobBusy {}

impl Mux {
    /// Looks up the original intent without preparing, reconciling or launching it.
    /// A client that lost a reply must not use an execution RPC as a status read.
    #[track_caller]
    pub(crate) fn resolve_agent_cli_update_job(
        &self,
        cli: &str,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<Value> {
        let correlation = format!("agent-cli-job:{:x}", Sha256::digest(mutation.id.as_bytes()));
        let fingerprint = self.agent_cli_job_fingerprint(cli, mutation);
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let previous = registry
            .lookup_resource_creation(
                &correlation,
                &mutation.id,
                "workspace.create",
                &fingerprint,
                true,
            )
            .map_err(|error| job_lookup_error(error, mutation))?;
        Ok(match previous {
            None => json!({"state":"not_found"}),
            Some(ResourceCreationPreparation::Created { created_path, revision, .. }) => {
                let mut path = Map::new();
                for key in ["kind", "workspace_id", "screen_id", "pane_id", "tab_id", "terminal_id"]
                {
                    path.insert(key.into(), created_path.get(key).cloned().unwrap_or(Value::Null));
                }
                json!({"state":"created","receipt":{
                    "machine":self.machine_public_id,"session":self.session_public_id,"cli":cli,
                    "path":path,"revision":revision.to_string(),"replayed":true,
                }})
            }
            Some(ResourceCreationPreparation::Execute { .. }) => json!({"state":"prepared"}),
            Some(ResourceCreationPreparation::Failed { error, .. }) => {
                json!({"state":"failed","code":error.code})
            }
            Some(ResourceCreationPreparation::Blocked { .. }) => {
                let resolved = registry.resolve_resource_creation(&correlation)?;
                let state = if resolved.get("state").and_then(Value::as_str) == Some("pending") {
                    "pending"
                } else {
                    "indeterminate"
                };
                json!({"state":state})
            }
        })
    }

    fn agent_cli_job_fingerprint(&self, cli: &str, mutation: &WorkspaceMutation) -> Value {
        json!({"operation":"agent_cli.update","machine":self.machine_public_id,
            "session":self.session_public_id,"cli":cli,"actor":mutation.actor.wire()})
    }

    /// The caller has already admitted the principal, owner and user action.
    /// `prepare` is the owner's fixed-plan producer, never caller argv. It
    /// runs without registry/state locks, and is unnecessary for a receipt.
    #[track_caller]
    pub(crate) fn create_agent_cli_update_job(
        self: &Arc<Self>,
        cli: &str,
        mutation: &WorkspaceMutation,
        prepare: impl FnOnce() -> anyhow::Result<Vec<String>>,
    ) -> anyhow::Result<Value> {
        // Only a held lock is busy; a poisoned one guards nothing and must not refuse forever.
        let _one = match self.agent_cli_job_execution.try_lock() {
            Ok(guard) => guard,
            Err(std::sync::TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return Err(AgentCLIJobBusy.into()),
        };
        let correlation = format!("agent-cli-job:{:x}", Sha256::digest(mutation.id.as_bytes()));
        let fingerprint = self.agent_cli_job_fingerprint(cli, mutation);
        self.reconcile_interrupted_resource_creation(&correlation)?;
        let previous = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .lookup_resource_creation(
                &correlation,
                &mutation.id,
                "workspace.create",
                &fingerprint,
                true,
            )
            .map_err(|error| job_lookup_error(error, mutation))?;
        let mut fields = Map::from_iter([("correlation_key".to_owned(), json!(correlation))]);
        match previous {
            // The same intent replays with acpmux offline or a different
            // version/cache. Blocked/failed effects use their durable result.
            Some(
                ResourceCreationPreparation::Created { .. }
                | ResourceCreationPreparation::Blocked { .. }
                | ResourceCreationPreparation::Failed { .. },
            ) => {}
            Some(ResourceCreationPreparation::Execute { intent, .. }) => {
                // An unexecuted reservation keeps its exact original argv.
                // A changed installation cannot silently retarget a resume.
                let argv = prepare()?;
                anyhow::ensure!(
                    intent.get("fields").and_then(|fields| fields.get("argv"))
                        == Some(&json!(argv)),
                    "agent update installation changed after preparation"
                );
            }
            None => {
                let argv = prepare()?;
                fields.insert("initial_content".into(), json!("terminal"));
                fields.insert("argv".into(), json!(argv));
                fields.insert("on_exit".into(), json!("keep"));
            }
        }
        let commit = self.resource_correlated_creation_operation(
            ResourceOperation::WorkspaceCreate,
            vec![ResourceSelectors {
                machine: Some(self.machine_public_id.as_str().into()),
                session: Some(self.session_public_id.as_str().into()),
                ..ResourceSelectors::default()
            }],
            fields,
            None,
            mutation,
            &fingerprint,
        )?;
        if !commit.replayed {
            self.emit_resource_topology_legacy_events(ResourceOperation::WorkspaceCreate, &commit);
        }
        // This acknowledges a terminal, not a successful update. Its owner
        // provides terminal.wait_exit, including after detachment or exit.
        Ok(json!({"machine":self.machine_public_id,"session":self.session_public_id,"cli":cli,
            "path":commit.result,"revision":commit.revision.to_string(),"replayed":commit.replayed}))
    }
}

fn job_lookup_error(error: anyhow::Error, mutation: &WorkspaceMutation) -> anyhow::Error {
    if error.downcast_ref::<ResourceError>().is_some_and(|e| e.code == "creation.conflict") {
        ResourceError::idempotency_conflict(&mutation.id, "agent_cli.update").into()
    } else {
        error
    }
}
