//! Workspace identity (title, color, icon) and workspace status (entries,
//! progress, log) as v2 state mutations.

use serde::Serialize;

use crate::mux::*;
use crate::state::commit::{StateEffects, workspace_identity};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_upsert, write_workspace_identity};
use crate::state::values::{fresh_upserts, upserted_value};
use crate::state::workspace_status_store as status;
use crate::workspace_registry::WorkspacePresentationUpdate;

/// One workspace status mutation.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "change", rename_all = "snake_case")]
pub(crate) enum WorkspaceStatusChange {
    Set {
        key: String,
        text: String,
        icon: Option<String>,
        color: Option<String>,
        #[serde(skip_serializing_if = "crate::state::status_meta::StatusMeta::is_plain_boxed")]
        meta: Box<crate::state::status_meta::StatusMeta>,
    },
    Clear {
        key: Option<String>,
    },
    Progress {
        value: Option<f64>,
        label: Option<String>,
    },
    ProgressClear,
    Log {
        level: String,
        source: Option<String>,
        text: String,
    },
    LogClear,
}

impl Mux {
    /// `workspace.update`: set or clear the shared title, color, and icon.
    pub(crate) fn state_update_workspace(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        update: WorkspacePresentationUpdate,
    ) -> anyhow::Result<StateCommit> {
        update.validate()?;
        let fingerprint = serde_json::json!({
            "operation": "workspace.update",
            "selectors": selectors,
            "title": update.title,
            "color": update.color,
            "icon": update.icon,
        });
        self.commit_state(
            mutation,
            "workspace.update",
            &fingerprint,
            expected_revision,
            StateEffects::PRESENTATION,
            |transaction, state| {
                let resolved =
                    self.resolve_in_state(state, crate::ResourceTarget::Workspace, selectors)?;
                let (key, public_id) = workspace_identity(state, resolved.workspace)?;
                write_workspace_identity(transaction, &key, &update)?;
                let changes = fresh_upserts(transaction, &[public_id.to_string()], &[], &[])?;
                let result = upserted_value(&changes, "workspace", public_id.as_str())
                    .context("updated workspace has no public value")?;
                Ok(StateChanges::new(result, changes))
            },
        )
    }

    /// `workspace_status.*`, `workspace_progress.*`, `workspace_log.*`.
    pub(crate) fn state_workspace_status(
        &self,
        mutation: &WorkspaceMutation,
        operation: &'static str,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        change: WorkspaceStatusChange,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = serde_json::json!({
            "operation": operation,
            "selectors": selectors,
            "change": change,
        });
        // A process owner is honored only on the machine that accepted it.
        let machine = self.workspace_registry.lock().unwrap().machine_id().as_str().to_owned();
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
                    WorkspaceStatusChange::Set { key, text, icon, color, meta } => {
                        meta.validate(|id| state.terminal_catalog.contains_key(id))?;
                        // Checked here, after the replay check, so a retry of
                        // a committed set returns its stored result.
                        let owner_process = match meta.owner_pid {
                            Some(pid) => Some(
                                crate::state::status_meta::OwnerProcess::current(pid).ok_or_else(
                                    || {
                                        anyhow::anyhow!(
                                            "bad request: owner.pid {pid} is not running"
                                        )
                                    },
                                )?,
                            ),
                            None => None,
                        };
                        status::set_status(
                            transaction,
                            workspace,
                            key,
                            text,
                            icon.as_deref(),
                            color.as_deref(),
                            now,
                        )?;
                        crate::state::status_meta::write_meta(
                            transaction,
                            workspace,
                            key,
                            meta,
                            owner_process,
                            &machine,
                            now,
                        )?;
                    }
                    WorkspaceStatusChange::Clear { key } => {
                        status::clear_status(transaction, workspace, key.as_deref())?;
                    }
                    WorkspaceStatusChange::Progress { value, label } => {
                        status::set_progress(
                            transaction,
                            workspace,
                            *value,
                            label.as_deref(),
                            now,
                        )?;
                    }
                    WorkspaceStatusChange::ProgressClear => {
                        status::clear_progress(transaction, workspace)?;
                    }
                    WorkspaceStatusChange::Log { level, source, text } => status::append_log(
                        transaction,
                        workspace,
                        level,
                        source.as_deref(),
                        text,
                        now,
                    )?,
                    WorkspaceStatusChange::LogClear => status::clear_log(transaction, workspace)?,
                }
                let snapshot = status::status_snapshot(transaction, workspace)?;
                Ok(StateChanges::new(
                    snapshot.clone(),
                    vec![state_upsert("workspace_status", workspace, snapshot)],
                ))
            },
        )
    }

    /// Status snapshots: one workspace, or every workspace with status.
    pub(crate) fn workspace_status_snapshots(
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
                Ok(vec![status::status_snapshot(connection, workspace.as_str())?])
            }
            Some(None) => Ok(Vec::new()),
            None => status::status_snapshots(connection),
        })
        .map_err(crate::resource_api::operation_failed)
    }

    /// The newest `limit` log lines of one workspace, oldest first.
    pub(crate) fn workspace_log_lines(
        &self,
        selectors: &crate::ResourceSelectors,
        limit: usize,
    ) -> Result<Vec<Value>, ResourceError> {
        let workspace = self
            .resolve_resource_path(crate::ResourceTarget::Workspace, selectors)?
            .workspace
            .ok_or_else(|| ResourceError::not_found("workspace", "<resolved>"))?;
        self.read_registry_state(|connection| {
            status::log_lines(connection, workspace.as_str(), limit)
        })
        .map_err(crate::resource_api::operation_failed)
    }
}

impl Mux {
    /// Close every ephemeral workspace left by an earlier run, and end the
    /// terminals that only it showed. Runs once at daemon start.
    pub(crate) fn close_ephemeral_workspaces(self: &Arc<Self>) -> anyhow::Result<()> {
        // Owned status entries a previous run left: re-arm their watches and
        // drop the ones whose TTL passed while the daemon was down.
        crate::state::status_owners::resume(self);
        let ephemeral = self.read_registry_state(crate::state::store::ephemeral_workspaces)?;
        for workspace_id in ephemeral {
            let target = self.with_state(|state| {
                let index = state
                    .workspaces
                    .iter()
                    .position(|workspace| workspace.public_id.as_str() == workspace_id)?;
                let workspace = &state.workspaces[index];
                let terminals = state
                    .panes
                    .values()
                    .filter(|pane| {
                        state.screen_of(pane.id).is_some_and(|(owner, _)| owner == index)
                    })
                    .flat_map(|pane| pane.tabs.iter())
                    .filter_map(|surface| state.surfaces.get(surface))
                    .filter_map(|runtime| runtime.terminal_public_id().cloned())
                    .collect::<Vec<_>>();
                Some((workspace.id, terminals))
            });
            let Some((slot, terminals)) = target else { continue };
            if !self.close_workspace(slot) {
                eprintln!("cmux-tui: could not close ephemeral workspace {workspace_id}");
                continue;
            }
            for terminal in terminals {
                let orphan = self.with_state(|state| {
                    state
                        .placements_of_content(&ContentPublicId::Terminal(terminal.clone()))
                        .is_empty()
                });
                if !orphan {
                    continue;
                }
                let host = self.workspace_registry.lock().unwrap().terminal_host_id(&terminal)?;
                if let Some(host) = host
                    && let Err(error) = self.close_terminal_with_mutation(
                        &host,
                        None,
                        None,
                        None,
                        &WorkspaceMutation::local("cmux-tui-ephemeral"),
                    )
                {
                    eprintln!(
                        "cmux-tui: could not end terminal {terminal} of an ephemeral workspace: {error}"
                    );
                }
            }
        }
        Ok(())
    }
}
