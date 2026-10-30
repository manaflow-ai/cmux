//! Frontend projections and registry reads: terminal registry snapshots and pages, workspace registry events, frontend projection get/put, and workspace selector resolution.

use super::*;
use crate::panic_free::RecoverPoison;

impl Mux {
    /// The terminal registry revision without reading every terminal row:
    /// the registry lock is held for one indexed read.
    #[track_caller]
    pub fn terminal_registry_revision(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner).terminal_revision()
    }

    #[track_caller]
    pub fn terminal_registry_snapshot(&self) -> anyhow::Result<TerminalRegistrySnapshot> {
        self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner).terminal_snapshot()
    }

    #[track_caller]
    pub fn terminal_registry_events_page(
        &self,
        revision: u64,
    ) -> anyhow::Result<(
        TerminalRegistrySnapshot,
        Vec<crate::workspace_registry::TerminalRegistryEvent>,
    )> {
        // One writer guard is the read transaction boundary exposed to a
        // frontend. Otherwise a commit between snapshot and event queries can
        // return an event whose revision is newer than terminal_revision.
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let snapshot = registry.terminal_snapshot()?;
        let events = registry.terminal_events_after(revision)?;
        Ok((snapshot, events))
    }

    #[track_caller]
    pub fn workspace_registry_event(
        &self,
        revision: u64,
    ) -> anyhow::Result<Option<crate::workspace_registry::RegistryEvent>> {
        self.workspace_registry.lock().recover_poison().workspace_event(revision)
    }

    #[track_caller]
    pub fn get_frontend_projection(
        &self,
        frontend: &str,
        scope: &str,
        subject_key: &str,
    ) -> anyhow::Result<Option<FrontendProjection>> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_frontend_projection(frontend, scope, subject_key)
    }

    #[allow(clippy::too_many_arguments)]
    #[track_caller]
    pub fn put_frontend_projection(
        &self,
        mutation: &WorkspaceMutation,
        frontend: &str,
        scope: &str,
        subject_key: &str,
        schema_version: u32,
        expected_projection_revision: Option<u64>,
        projection: &Value,
    ) -> anyhow::Result<ProjectionCommit> {
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let commit = registry.put_frontend_projection(
            mutation,
            frontend,
            scope,
            subject_key,
            schema_version,
            expected_projection_revision,
            projection,
        )?;
        if !commit.replayed {
            self.emit(MuxEvent::FrontendProjectionChanged {
                frontend: frontend.to_string(),
                scope: scope.to_string(),
                subject_key: subject_key.to_string(),
                projection_revision: commit.projection.projection_revision,
                origin: mutation.origin.clone(),
                mutation_id: mutation.id.clone(),
            });
        }
        Ok(commit)
    }

    #[track_caller]
    pub(crate) fn resource_put_frontend_projection_selected(
        &self,
        selectors: crate::ResourceSelectors,
        projection_id: &FrontendProjectionPublicId,
        projection: &Value,
        expected_projection_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation":"frontend_projection.put",
            "selectors":selectors,
            "projection":projection,
        });
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(replay) =
            registry.replay_resource_patch(mutation, "frontend_projection.put", &fingerprint)?
        {
            return Ok(replay);
        }
        let projection_revision = registry
            .get_frontend_projection("resource-api", "session", projection_id.as_str())?
            .map(|projection| projection.projection_revision)
            .unwrap_or(0)
            .checked_add(1)
            .context("frontend projection revision exhausted")?;
        let mut session_selectors = selectors;
        session_selectors.frontend_projection = None;
        let mut state = self.lock_state_pinned(&registry).recover_poison();
        let resolved = self
            .resolve_resource_path_in_state(
                &state,
                &registry,
                crate::ResourceTarget::Session,
                &session_selectors,
            )
            .map_err(anyhow::Error::new)?;
        let session_id =
            resolved.path.session.context("projection route omitted its session identity")?;
        let value = serde_json::json!({
            "id":projection_id,
            "session_id":session_id,
            "frontend_id":projection["frontend_id"],
            "window_id":projection["window_id"],
            "generation":projection["generation"],
            "projection":projection["projection"],
            "projection_revision":projection_revision.to_string(),
        });
        let deltas = serde_json::json!([{
            "kind":"upsert",
            "sequence":0,
            "resource":"frontend_projection",
            "id":projection_id,
            "value":value,
        }]);
        let commit = registry.commit_resource_projection(
            mutation,
            "frontend_projection.put",
            &fingerprint,
            None,
            expected_projection_revision,
            "resource-api",
            "session",
            projection_id.as_str(),
            RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION,
            projection,
            &value,
            &deltas,
        )?;
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
            self.emit(MuxEvent::FrontendProjectionChanged {
                frontend: "resource-api".to_string(),
                scope: "session".to_string(),
                subject_key: projection_id.to_string(),
                projection_revision: commit.revision,
                origin: mutation.origin.clone(),
                mutation_id: mutation.id.clone(),
            });
        }
        Ok(commit)
    }

    pub(super) fn resolve_workspace_selector(
        state: &State,
        id: Option<WorkspaceId>,
        key: Option<&str>,
    ) -> anyhow::Result<Option<(WorkspaceId, String)>> {
        let by_id = id.and_then(|id| state.workspace_by_id(id).filter(|ws| ws.id == id));
        let by_key = key.and_then(|key| state.workspace_by_key(key).filter(|ws| ws.key == key));
        let workspace = match (id, key, by_id, by_key) {
            (None, None, _, _) => anyhow::bail!("workspace or key is required"),
            (Some(_), None, by_id, _) => by_id,
            (None, Some(_), _, by_key) => by_key,
            (Some(_), Some(_), Some(by_id), Some(by_key)) if by_id.id == by_key.id => Some(by_id),
            (Some(_), Some(_), _, _) => {
                anyhow::bail!("workspace id and key do not identify the same workspace")
            }
        };
        Ok(workspace.map(|workspace| (workspace.id, workspace.key.clone())))
    }
}
