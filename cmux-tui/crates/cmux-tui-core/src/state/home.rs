//! `workspace.ensure_home {}` (`workspace-kind-v1`, plans/cmux-next/home.md
//! section 7). The hosting app sends it on every connect; the store creates
//! the home workspace once and replays it after that. Only this operation
//! writes `kind: home`: clients cannot pass `kind` to `workspace.create`, and
//! sessions whose app never asks (the TUI, the CLI) never get a home.
//!
//! One commit through the normal empty-creation path (fixed idempotency and
//! correlation key `home`): the workspace row, its kind row and its personal
//! placement first in the top section, with the placement changes in the
//! same `session.events` batch.

use crate::mux::*;
use crate::state::home_store::{self, EmptyWorkspaceMark, HOME_CREATION_KEY};
use crate::state::prelude::*;
use crate::user_settings::NewWorkspacePlacement;
use crate::workspace_registry::personal_store::personal_revision;

/// The stored name of the home workspace. Clients show their own localized
/// title for `extra.kind == "home"`; a rename by the user replaces this.
const HOME_DEFAULT_NAME: &str = "Home";
const HOME_MUTATION_ORIGIN: &str = "cmux-tui-home";

/// What `workspace.ensure_home` returns.
pub(crate) struct EnsuredHome {
    pub(crate) workspace_id: String,
    pub(crate) revision: u64,
    pub(crate) replayed: bool,
}

impl Mux {
    pub(crate) fn state_ensure_home(self: &Arc<Self>) -> anyhow::Result<EnsuredHome> {
        if let Some((workspace_id, _)) = self.read_registry_state(home_store::live_home)? {
            let revision = self.with_state(|state| state.resource_revision);
            return Ok(EnsuredHome { workspace_id, revision, replayed: true });
        }
        let personal_before = self.read_registry_state(personal_revision)?;
        let mutation = WorkspaceMutation::daemon(HOME_CREATION_KEY, HOME_MUTATION_ORIGIN)?;
        // Home always takes the top row (then `place_home_first` pins it at
        // index 0), whatever `workspaces.newPlacement` says.
        let commit = NewWorkspacePlacement::Top.scoped(|| {
            self.resource_create_empty_workspace_selected(
                Self::ordinary_resource_selectors(),
                Some(HOME_DEFAULT_NAME.to_string()),
                HOME_CREATION_KEY,
                None,
                &mutation,
                EmptyWorkspaceMark::Home,
            )
        })?;
        let (workspace_id, _) = self
            .read_registry_state(home_store::live_home)?
            .context("the created home workspace has no kind row")?;
        // The raw tree reads `kind` from the presentation snapshot.
        self.reload_presentation(&self.workspace_registry.lock().unwrap())?;
        self.emit(MuxEvent::TreeChanged);
        // The creation commit moved the personal order too; raw
        // `personal-changed` readers refetch on this event.
        let personal_after = self.read_registry_state(personal_revision)?;
        if personal_after != personal_before {
            self.emit(MuxEvent::PersonalChanged { personal_revision: personal_after });
        }
        Ok(EnsuredHome { workspace_id, revision: commit.revision, replayed: commit.replayed })
    }
}
