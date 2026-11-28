//! Personal state of the home session (plans/cmux-next/data-model.md
//! sections 1-3, `profiles-v1`). The durable rows live in the workspace
//! registry (`workspace_registry/personal_store.rs`); each committed change
//! wakes journal readers and emits `personal-changed` with the new
//! `personal_revision`, after which frontends refetch `list-personal`.

use super::*;
use crate::workspace_registry::PersonalSnapshot;

mod bookmarks;
pub use bookmarks::BookmarksChange;

impl Mux {
    pub fn personal_snapshot(&self) -> anyhow::Result<PersonalSnapshot> {
        self.workspace_registry.lock().unwrap().personal_snapshot()
    }

    /// Run one personal mutation under the registry lock. When it changed
    /// durable state, notify journal readers and subscribers.
    pub(crate) fn personal_mutation<T>(
        &self,
        mutation: impl FnOnce(&mut WorkspaceRegistry) -> anyhow::Result<(T, bool)>,
    ) -> anyhow::Result<(T, bool)> {
        let (value, changed, revision) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let (value, changed) = mutation(&mut registry)?;
            (value, changed, registry.personal_revision()?)
        };
        if changed {
            self.publish_journal_event();
            self.emit(MuxEvent::PersonalChanged { personal_revision: revision });
        }
        Ok((value, changed))
    }
}
