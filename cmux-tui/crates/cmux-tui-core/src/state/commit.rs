//! The mux side of a state mutation (state-ownership.md steps A and B):
//! one registry transaction under the registry -> state fence, then the
//! in-memory revision, the presentation cache, and the notifications every
//! client follows (`session.events` wakeups, `personal-changed`,
//! `tree-changed`).

use rusqlite::Transaction;

use crate::mux::*;
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit};

/// What a committed state mutation must refresh besides the event feed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct StateEffects {
    /// Reload the presentation cache (workspace identity, pins, tab groups,
    /// saved groups) that the raw tree serializer reads.
    pub(crate) presentation: bool,
    /// Emit `tree-changed` for raw frontends.
    pub(crate) tree: bool,
}

impl StateEffects {
    pub(crate) const PRESENTATION: Self = Self { presentation: true, tree: true };
    pub(crate) const EVENTS_ONLY: Self = Self { presentation: false, tree: false };
}

impl Mux {
    /// Commit one state mutation. Selector resolution belongs inside `apply`
    /// (it receives the locked state), so an idempotent replay returns its
    /// stored result before any selector is resolved.
    pub(crate) fn commit_state(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        effects: StateEffects,
        apply: impl FnOnce(&Transaction<'_>, &State) -> anyhow::Result<StateChanges>,
    ) -> anyhow::Result<StateCommit> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let commit = {
            let mut state = self.state.lock().unwrap();
            let commit = registry.commit_state_mutation(
                mutation,
                operation,
                fingerprint,
                expected_revision,
                |transaction| apply(transaction, &state),
            )?;
            if !commit.replayed {
                state.resource_revision = commit.revision;
            }
            commit
        };
        if !commit.replayed && effects.presentation {
            self.reload_presentation(&registry)?;
        }
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
            if let Some(personal_revision) = commit.personal_revision {
                self.emit(MuxEvent::PersonalChanged { personal_revision });
            }
            if effects.tree {
                self.emit(MuxEvent::TreeChanged);
            }
        }
        Ok(commit)
    }

    /// Resolve public selectors against a state the caller already locked.
    pub(crate) fn resolve_in_state(
        &self,
        state: &State,
        target: crate::ResourceTarget,
        selectors: &crate::ResourceSelectors,
    ) -> Result<ResolvedResourceSlots, ResourceError> {
        resolve_resource_selectors(
            state,
            ResourceSelectorContext {
                machine_id: &self.machine_public_id,
                machine_name: None,
                session_id: &self.session_public_id,
                session_name: &self.session,
            },
            target,
            selectors,
        )
    }

    /// Read the registry under its lock.
    pub(crate) fn read_registry_state<T>(
        &self,
        read: impl FnOnce(&rusqlite::Connection) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        self.workspace_registry.lock().unwrap().read_state(read)
    }
}

/// A typed `resource.not_found` for a state resource, carried through
/// `anyhow` so the router keeps its code.
pub(crate) fn state_not_found(scope: &str, id: &str) -> anyhow::Error {
    anyhow::Error::new(ResourceError::new(
        "resource.not_found",
        format!("no {scope} {id:?}"),
        serde_json::json!({"scope": scope, "id": id}),
        false,
    ))
}

/// The workspace key and public id of a live workspace slot.
pub(crate) fn workspace_identity(
    state: &State,
    workspace: Option<WorkspaceId>,
) -> anyhow::Result<(String, WorkspacePublicId)> {
    let index = workspace
        .and_then(|workspace| state.workspace_index(workspace))
        .context("workspace has no live slot")?;
    let workspace = &state.workspaces[index];
    Ok((workspace.key.clone(), workspace.public_id.clone()))
}
