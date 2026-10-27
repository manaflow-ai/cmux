//! Workspace checklists (`workspace-checklist-v1`) as v2 state mutations:
//! `workspace_checklist.add`, `.update`, `.remove` and `.list`. Each commit
//! publishes the workspace's whole checklist as one `workspace_checklist`
//! state upsert, so a client mirrors it by replacing its copy.

use serde::Serialize;

use crate::mux::*;
use crate::state::commit::{StateEffects, workspace_identity};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_upsert};
use crate::state::workspace_checklist_store as store;

/// The capability that advertises the `workspace_checklist.*` operations.
pub(crate) const CAPABILITY: &str = "workspace-checklist-v1";

/// One workspace checklist mutation.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "change", rename_all = "snake_case")]
pub(crate) enum WorkspaceChecklistChange {
    Add { text: String, state: Option<String>, origin: String, index: Option<usize> },
    Update { item: String, update: store::ChecklistItemUpdate },
    Remove { item: String },
}

impl Mux {
    /// `workspace_checklist.add`, `.update` and `.remove`.
    #[track_caller]
    pub(crate) fn state_workspace_checklist(
        &self,
        mutation: &WorkspaceMutation,
        operation: &'static str,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        change: WorkspaceChecklistChange,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = serde_json::json!({
            "operation": operation,
            "selectors": selectors,
            "change": change,
        });
        self.commit_state(
            mutation,
            operation,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                let resolved =
                    self.resolve_in_state(state, crate::ResourceTarget::Workspace, selectors)?;
                let (_, public_id) = workspace_identity(state, resolved.workspace)?;
                let workspace = public_id.as_str();
                let now = now_ms();
                match &change {
                    WorkspaceChecklistChange::Add { text, state, origin, index } => {
                        store::add_item(
                            transaction,
                            workspace,
                            text,
                            state.as_deref(),
                            origin,
                            *index,
                            now,
                        )?;
                    }
                    WorkspaceChecklistChange::Update { item, update } => {
                        store::update_item(transaction, workspace, item, update, now)?;
                    }
                    WorkspaceChecklistChange::Remove { item } => {
                        store::remove_item(transaction, workspace, item)?;
                    }
                }
                let snapshot = store::checklist_snapshot(transaction, workspace)?;
                Ok(StateChanges::new(
                    snapshot.clone(),
                    vec![state_upsert("workspace_checklist", workspace, snapshot)],
                ))
            },
        )
    }

    /// Checklists: one workspace's, or every workspace's that has items.
    #[track_caller]
    pub(crate) fn workspace_checklist_snapshots(
        &self,
        selectors: &crate::ResourceSelectors,
    ) -> Result<Vec<Value>, ResourceError> {
        let workspace = if selectors.workspace.is_some() {
            Some(self.resolve_resource_path(crate::ResourceTarget::Workspace, selectors)?.workspace)
        } else {
            self.resolve_resource_path(crate::ResourceTarget::Session, selectors)?;
            None
        };
        self.read_registry_state(|connection| match workspace {
            Some(Some(workspace)) => {
                Ok(vec![store::checklist_snapshot(connection, workspace.as_str())?])
            }
            Some(None) => Ok(Vec::new()),
            None => store::checklist_snapshots(connection),
        })
        .map_err(crate::resource_api::operation_failed)
    }
}
