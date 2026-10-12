//! The commit of a confirmed layout undo.
//!
//! The confirmation token (what the undo closes) is computed once by the
//! caller and travels in `fields`. The resource revision is only the
//! commit's precondition, so a `revision.conflict` caused by an unrelated
//! commit between reading it and committing is retried with the same token;
//! the commit re-checks the token against the state it commits on.

use super::*;

/// How many times a confirmed layout undo retries a resource revision conflict
/// caused by unrelated commits before it reports the undo as stale.
const LAYOUT_UNDO_COMMIT_ATTEMPTS: u32 = 3;

impl Mux {
    pub(super) fn commit_confirmed_layout_undo(
        self: &Arc<Self>,
        actor: &Actor,
        selectors: crate::ResourceSelectors,
        fields: Map<String, Value>,
        confirmed_close: bool,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut attempts = 0;
        let commit = loop {
            attempts += 1;
            let expected_resource_revision = if !confirmed_close {
                None
            } else {
                Some(self.workspace_registry.lock().unwrap().resource_topology_snapshot()?.revision)
            };
            #[cfg(test)]
            if let Some(hook) = self.layout_undo_before_commit.lock().unwrap().clone() {
                hook();
            }
            let result = self.commit_resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors.clone(),
                fields.clone(),
                expected_resource_revision,
                &WorkspaceMutation::local("cmux-tui-layout-undo", actor.clone()),
            );
            let conflict =
                result.as_ref().err().is_some_and(crate::resource_router::is_revision_conflict);
            if conflict && attempts < LAYOUT_UNDO_COMMIT_ATTEMPTS {
                continue;
            }
            break result.map_err(|error| {
                if conflict {
                    anyhow::Error::new(LayoutUndoError::Stale(
                        "layout revision conflict: resource topology changed before confirmed undo could commit"
                            .to_string(),
                    ))
                } else {
                    error
                }
            })?;
        };
        Ok(commit)
    }
}
