//! Whole workspaces in a stash (`stash-workspaces-v1`, Save and Close of a
//! workspace, a group or a window): `stash.create {workspaces}` closes them
//! with every tab, terminals included, as one stash of `kind: "workspace"`
//! members; `stash.restore` reopens each as its own workspace with its
//! screens, splits, name, color, group and sidebar place, as Reopen Closed
//! reopens a closed workspace. Storage lives in [`super::stash_store`].
//!
//! The close is the batch close a space delete uses: every tab of the
//! workspaces (and the workspaces with none) in one commit, ending their
//! terminals. Its transaction names the stash first
//! (`stash_store::pend_workspace_stash`), and the closed-history capture of
//! that close goes to the stash instead of Recently Closed.

use std::collections::HashSet;

use rusqlite::OptionalExtension;
use serde_json::json;

use crate::Actor;
use crate::mux::*;
use crate::state::closed_history::{Reopened, note_created};
use crate::state::commit::state_not_found;
use crate::state::prelude::*;
use crate::state::stash_store as store;
use crate::state::store::StateCommit;
use cmux_json::JsonSet as _;

/// Whether `member` is a whole stashed workspace.
pub(super) fn is_workspace(member: &Value) -> bool {
    member["kind"] == "workspace"
}

/// Every tab of the live workspace `public`, in screen and pane order.
fn workspace_surfaces(state: &State, public: &str) -> Option<Vec<SurfaceId>> {
    let workspace =
        state.workspaces.iter().find(|workspace| workspace.public_id.as_str() == public)?;
    let mut panes = Vec::new();
    for screen in &workspace.screens {
        screen.root.pane_ids(&mut panes);
    }
    Some(
        panes
            .iter()
            .filter_map(|pane| state.panes.get(pane))
            .flat_map(|pane| pane.tabs.iter().copied())
            .collect(),
    )
}

/// A `stash.create` name: trimmed, not empty, at most
/// [`store::MAX_NAME_BYTES`].
pub(crate) fn clean_name(name: &str) -> anyhow::Result<String> {
    let name = name.trim();
    anyhow::ensure!(!name.is_empty(), "bad request: name must not be empty");
    anyhow::ensure!(
        name.len() <= store::MAX_NAME_BYTES,
        "bad request: name is longer than {} bytes",
        store::MAX_NAME_BYTES
    );
    Ok(name.to_string())
}

impl Mux {
    /// `stash.create {workspaces, name?}`: those workspaces, each once in the
    /// order named, close whole into one stash. With no name, a single
    /// workspace's name names it. An unknown workspace is `resource.not_found`,
    /// an incognito one a bad request, the home `home.not_closable`; any
    /// refusal closes nothing.
    pub(crate) fn state_stash_workspaces(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        workspaces: &[String],
        name: Option<&str>,
    ) -> anyhow::Result<StateCommit> {
        const OPERATION: &str = "stash.create";
        let fingerprint = json!({"operation": OPERATION, "workspaces": workspaces, "name": name});
        if let Some(replay) = self
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replay_resource_patch(mutation, OPERATION, &fingerprint)?
        {
            return Ok(replay.into());
        }
        let mut seen = HashSet::new();
        let workspaces = workspaces
            .iter()
            .filter(|workspace| seen.insert(*workspace))
            .cloned()
            .collect::<Vec<_>>();
        anyhow::ensure!(!workspaces.is_empty(), "bad request: name the workspaces to stash");
        let name = name.map(clean_name).transpose()?;
        let name = self.read_registry_state(|connection| {
            for workspace in &workspaces {
                let live = connection
                    .query_row(
                        "SELECT 1 FROM resource_workspaces
                         WHERE public_id = ?1 AND deleted_revision IS NULL",
                        [workspace],
                        |_| Ok(()),
                    )
                    .optional()?;
                if live.is_none() {
                    return Err(state_not_found("workspace", workspace));
                }
                if super::closed_history_store::is_ephemeral(connection, workspace)? {
                    anyhow::bail!("bad request: an incognito workspace cannot be stashed");
                }
                crate::state::home_store::refuse_close_id(connection, workspace)?;
            }
            match (&name, workspaces.as_slice()) {
                (Some(name), _) => Ok(Some(name.clone())),
                (None, [only]) => store::workspace_name(connection, only),
                (None, _) => Ok(None),
            }
        })?;
        // Every tab of those workspaces, and the workspaces with none (they
        // close in the same plan).
        let (surfaces, bare, tab_ids) = self.with_state(|state| {
            let mut surfaces = Vec::new();
            let mut bare = Vec::new();
            for public in &workspaces {
                let tabs = workspace_surfaces(state, public)
                    .ok_or_else(|| state_not_found("workspace", public))?;
                if tabs.is_empty() {
                    let workspace = state
                        .workspaces
                        .iter()
                        .find(|workspace| workspace.public_id.as_str() == public.as_str())
                        .ok_or_else(|| state_not_found("workspace", public))?;
                    bare.push(workspace.id);
                }
                surfaces.extend(tabs);
            }
            let tab_ids = surfaces
                .iter()
                .filter_map(|surface| state.resource_indexes.tab_ids.get(surface))
                .map(ToString::to_string)
                .collect::<Vec<_>>();
            anyhow::Ok((surfaces, bare, tab_ids))
        })?;
        let stash_id = store::new_stash_id();
        let result = json!({
            "stash_id": stash_id,
            "tab_ids": tab_ids,
            "skipped": [],
            "workspace_ids": workspaces,
        });
        let before_patch = |transaction: &rusqlite::Transaction<'_>| -> anyhow::Result<()> {
            store::pend_workspace_stash(transaction, &stash_id, name.as_deref())
        };
        let outcome = self.close_tabs_for_room_delete(
            surfaces,
            OPERATION,
            crate::resource::ResourceOperation::WorkspaceClose,
            &fingerprint,
            mutation,
            RoomClose { before_patch: &before_patch, result, bare },
        )?;
        Ok(StateCommit {
            revision: outcome.resource_revision,
            result: outcome.result,
            replayed: outcome.replayed,
            personal_revision: None,
        })
    }

    /// Reopen the whole workspaces among `restore`, each as its own
    /// workspace, then form again the tab groups the stash kept
    /// (`record.tab_groups`) around the tabs they brought back.
    pub(super) fn restore_stashed_workspaces(
        self: &Arc<Self>,
        actor: &Actor,
        record: &Value,
        restore: &[Value],
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let mut any = false;
        for member in restore.iter().filter(|member| is_workspace(member)) {
            let known = reopened.workspaces.len();
            let outcome = self.reopen_closed_workspace(actor, member, reopened);
            // Every tab of the workspaces this reopen made, its first
            // terminal and its screens' included, so a failed restore closes
            // them whole (the last tab closes its workspace).
            let made = reopened.workspaces[known..].to_vec();
            for workspace in made {
                let tabs = self
                    .with_state(|state| workspace_surfaces(state, &workspace))
                    .unwrap_or_default();
                tabs.into_iter().for_each(note_created);
            }
            outcome?;
            any = true;
        }
        if !any {
            return Ok(());
        }
        for group in record["tab_groups"].as_array().into_iter().flatten() {
            let mut group = group.clone();
            let tabs = group["tab_ids"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|tab| reopened.reopened_as.get(tab.as_str()?).cloned())
                .collect::<Vec<_>>();
            if tabs.is_empty() {
                continue;
            }
            group.set("tab_ids", json!(tabs));
            self.reopen_tab_group(actor, &group, true, reopened)?;
        }
        Ok(())
    }
}
