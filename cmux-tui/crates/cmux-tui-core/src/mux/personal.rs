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
    #[track_caller]
    pub fn personal_snapshot(&self) -> anyhow::Result<PersonalSnapshot> {
        self.workspace_registry.lock().unwrap().personal_snapshot()
    }

    /// Run one personal mutation under the registry lock. When it changed
    /// durable state, notify journal readers and subscribers.
    #[track_caller]
    /// The key of the workspace `surface` is placed in now (the tree, not a
    /// spawn still pending), when it is a canonical workspace UUID.
    pub(crate) fn placed_workspace_key(&self, surface: SurfaceId) -> Option<String> {
        self.with_state(|state| {
            let workspace = Self::workspace_for_surface_in_state(state, surface)?;
            let key = &state.workspace_by_id(workspace)?.key;
            crate::workspace_registry::is_canonical_workspace_key(key).then(|| key.clone())
        })
    }

    /// The canonical key of workspace `id`, if any.
    pub(crate) fn workspace_key_by_id(&self, id: WorkspaceId) -> Option<String> {
        self.with_state(|state| {
            let key = &state.workspace_by_id(id)?.key;
            crate::workspace_registry::is_canonical_workspace_key(key).then(|| key.clone())
        })
    }

    /// Gives the workspace `to_key` of this daemon the room pin of
    /// `from_key` (`WorkspaceRegistry::inherit_workspace_pin`). Best effort:
    /// a move already done never fails on it.
    pub(crate) fn inherit_room_pin(&self, from_key: Option<String>, to_key: Option<String>) {
        let (Some(from_key), Some(to_key)) = (from_key, to_key) else { return };
        if from_key == to_key {
            return;
        }
        // Frontends pin under the registry id `identify` reports.
        let session = self.registry_identity().0;
        let result = self.personal_mutation(|registry| {
            Ok(((), registry.inherit_workspace_pin(&session, &from_key, &to_key)?))
        });
        if let Err(error) = result {
            eprintln!("cmux-tui: new workspace kept no room pin: {error:#}");
        }
    }

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
