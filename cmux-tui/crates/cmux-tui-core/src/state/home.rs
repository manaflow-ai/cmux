//! `workspace.ensure_home {}` (`workspace-kind-v1`, plans/cmux-next/home.md
//! section 7). The hosting app sends it on every connect; the store creates
//! the home workspace once and replays it after that. Only this operation
//! writes `kind: home`: clients cannot pass `kind` to `workspace.create`, and
//! sessions whose app never asks (the TUI, the CLI) never get a home.
//!
//! Two commits, both idempotent: the empty workspace with its kind row
//! (fixed idempotency and correlation key `home`), then its personal
//! placement at index 0. A crash between them leaves a home without a
//! placement row, which the next `ensure_home` places.

use crate::mux::*;
use crate::state::PersonalChange;
use crate::state::home_store::{self, EmptyWorkspaceMark, HOME_CREATION_KEY};
use crate::state::prelude::*;

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
        let (workspace_id, key, mut revision, mut replayed) =
            match self.read_registry_state(home_store::live_home)? {
                Some((workspace_id, key)) => {
                    (workspace_id, key, self.with_state(|state| state.resource_revision), true)
                }
                None => {
                    let mutation = WorkspaceMutation::new(HOME_CREATION_KEY, HOME_MUTATION_ORIGIN)?;
                    let commit = self.resource_create_empty_workspace_selected(
                        Self::ordinary_resource_selectors(),
                        Some(HOME_DEFAULT_NAME.to_string()),
                        HOME_CREATION_KEY,
                        None,
                        &mutation,
                        EmptyWorkspaceMark::Home,
                    )?;
                    let (workspace_id, key) = self
                        .read_registry_state(home_store::live_home)?
                        .context("the created home workspace has no kind row")?;
                    (workspace_id, key, commit.revision, commit.replayed)
                }
            };
        if !self.read_registry_state(|connection| home_store::home_is_first(connection, &key))? {
            let mutation =
                WorkspaceMutation::new(format!("home-place-{revision}"), HOME_MUTATION_ORIGIN)?;
            let selectors = crate::ResourceSelectors {
                workspace: Some(workspace_id.clone()),
                ..Self::ordinary_resource_selectors()
            };
            let commit = self.state_personal(
                &mutation,
                "workspace.place",
                None,
                &selectors,
                PersonalChange::Place { group: Some(None), index: Some(0) },
            )?;
            revision = commit.revision;
            replayed = false;
        }
        Ok(EnsuredHome { workspace_id, revision, replayed })
    }
}
