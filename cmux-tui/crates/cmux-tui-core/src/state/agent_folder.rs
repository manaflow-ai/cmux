//! The workspace's agent folder (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE,
//! amendment 2): the folder new agent chats of the workspace start in, once
//! the user chose one. One shared value for every client (Mac, iOS, GPUI),
//! carried as `extra.agent_folder` on every workspace snapshot and saved with
//! the workspace state, so it survives a restart.
//!
//! Only the user sets it: `workspace.agent_folder.set` is a gate A2
//! operation (request_origin.rs), and the app sends it after a real gesture.
//! The value is an absolute path of an existing directory, in canonical form
//! (no symlink, no `.` or `..` step, no trailing slash); null clears it.
//! Without one, the app gives a folderless workspace its own agent-home
//! folder; that folder is app state, never stored here.

use rusqlite::{Connection, OptionalExtension, Transaction};
use serde_json::json;

use crate::mux::*;
use crate::state::commit::{StateEffects, workspace_identity};
use crate::state::prelude::*;
use crate::state::store::StateChanges;
use crate::state::store::StateCommit;
use crate::state::values::{fresh_upserts, upserted_value};

pub(crate) const OPERATION: &str = "workspace.agent_folder.set";
/// Advertised by `identify` once `workspace.agent_folder.set` and
/// `extra.agent_folder` exist, so an app can tell an older daemon (one that
/// kept running across an app update) before it sends the operation.
pub(crate) const CAPABILITY: &str = "workspace-agent-folder-v1";
/// The longest path accepted (PATH_MAX on macOS and Linux).
const MAX_PATH_BYTES: usize = 4096;

pub(crate) fn create_agent_folder_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_agent_folder (
           workspace_id TEXT PRIMARY KEY NOT NULL,
           path TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// The workspace's agent folder, if the user chose one.
pub(crate) fn agent_folder(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT path FROM workspace_agent_folder WHERE workspace_id = ?1",
            [workspace_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// `path` when it is an absolute, existing directory in canonical form,
/// else the reason it is refused.
pub(crate) fn validate(path: &str) -> Result<(), String> {
    if path.is_empty() || path.len() > MAX_PATH_BYTES || path.contains('\0') {
        return Err("path must be 1 to 4096 bytes without NUL".into());
    }
    if !path.starts_with('/') {
        return Err("path must be absolute".into());
    }
    let canonical = std::fs::canonicalize(path)
        .map_err(|error| format!("path does not name an existing folder: {error}"))?;
    if canonical.as_os_str() != std::ffi::OsStr::new(path) {
        return Err(
            "path must be canonical (no symlink, no . or .. step, no trailing slash)".into()
        );
    }
    if !canonical.is_dir() {
        return Err("path must name a folder".into());
    }
    Ok(())
}

impl Mux {
    /// `workspace.agent_folder.set`: set or clear (`None`) the folder.
    pub(crate) fn state_set_agent_folder(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        path: Option<String>,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = json!({"operation": OPERATION, "selectors": selectors, "path": path});
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                // Checked inside the commit, so a replay returns its stored
                // result even after the folder went away.
                if let Some(path) = path.as_deref() {
                    validate(path).map_err(|reason| {
                        ResourceError::validation_invalid(Some("path"), reason)
                    })?;
                }
                let resolved =
                    self.resolve_in_state(state, crate::ResourceTarget::Workspace, selectors)?;
                let (_, public_id) = workspace_identity(state, resolved.workspace)?;
                match path.as_deref() {
                    Some(path) => transaction.execute(
                        "INSERT INTO workspace_agent_folder(workspace_id, path) VALUES(?1, ?2)
                         ON CONFLICT(workspace_id) DO UPDATE SET path = excluded.path",
                        [public_id.as_str(), path],
                    )?,
                    None => transaction.execute(
                        "DELETE FROM workspace_agent_folder WHERE workspace_id = ?1",
                        [public_id.as_str()],
                    )?,
                };
                let changes = fresh_upserts(transaction, &[public_id.to_string()], &[], &[])?;
                let result = upserted_value(&changes, "workspace", public_id.as_str())
                    .context("updated workspace has no public value")?;
                Ok(StateChanges::new(result, changes))
            },
        )
    }
}
