//! Raw protocol handlers for terminal command history
//! (`terminal-command-history-v1`, plans/cmux-next/history.md section 6).
//! Command lines can hold secrets: only trusted local (Unix-classified)
//! connections read, change or delete them. The rows and their worker live
//! in the workspace registry and mux/command_history.rs.

use std::sync::Arc;

use serde::Deserialize;
use serde_json::Value;

use super::{Command, Mux};
use crate::resource::ResourceError;
use crate::workspace_registry::command_history_store::{CommandDeletion, MAX_COMMAND_LIST_LIMIT};

/// `set-terminal-command-history`.
#[derive(Deserialize)]
pub(super) struct SetParams {
    enabled: bool,
    #[serde(default)]
    retention_days: Option<u32>,
}

/// `list-terminal-commands`.
#[derive(Deserialize)]
pub(super) struct ListParams {
    #[serde(default)]
    after_id: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
}

/// `delete-terminal-commands`: exactly one of the three selectors.
#[derive(Deserialize)]
pub(super) struct DeleteParams {
    #[serde(default)]
    ids: Option<Vec<String>>,
    #[serde(default)]
    started_since_ms: Option<String>,
    #[serde(default)]
    all: bool,
}

pub(super) fn handle(mux: &Arc<Mux>, client: u64, command: Command) -> anyhow::Result<Value> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "terminal command history requires a trusted local connection"
    );
    match command {
        Command::SetTerminalCommandHistory(SetParams { enabled, retention_days }) => {
            mux.set_terminal_command_history(enabled, retention_days)
        }
        Command::ListTerminalCommands(ListParams { after_id, limit }) => {
            let after_id = after_id.as_deref().map(decimal).transpose()?;
            let limit = limit.map_or(MAX_COMMAND_LIST_LIMIT, |limit| {
                usize::try_from(limit).unwrap_or(usize::MAX)
            });
            mux.list_terminal_commands(after_id, limit)
        }
        Command::DeleteTerminalCommands(DeleteParams { ids, started_since_ms, all }) => {
            let deletion = match (ids, started_since_ms, all) {
                (Some(ids), None, false) => CommandDeletion::Ids(
                    ids.iter().map(|id| decimal(id)).collect::<anyhow::Result<_>>()?,
                ),
                (None, Some(since), false) => CommandDeletion::StartedSince(decimal(&since)?),
                (None, None, true) => CommandDeletion::All,
                _ => anyhow::bail!("bad request: give exactly one of ids, started_since_ms or all"),
            };
            mux.delete_terminal_commands(deletion)
        }
        _ => anyhow::bail!("not a terminal command history command"),
    }
}

/// `cmux_shell` is a reserved journal producer id (development builds
/// journaled commands under it): `session.journal.append` refuses it, so no
/// client can append records that look like those.
pub(super) fn refuse_reserved_producer(
    ingress: &crate::JournalIngress,
) -> Result<(), ResourceError> {
    if ingress.producer_id == crate::shell_history::SHELL_PRODUCER_ID {
        return Err(ResourceError::validation_invalid(
            Some("event"),
            "the cmux shell producer id is reserved".to_string(),
        ));
    }
    Ok(())
}

/// A command history id or time: a decimal string, like journal sequences.
fn decimal(value: &str) -> anyhow::Result<u64> {
    anyhow::ensure!(
        !value.is_empty() && value.len() <= 20 && value.bytes().all(|byte| byte.is_ascii_digit()),
        "bad request: expected a decimal string, got {value:?}"
    );
    value.parse().map_err(|_| anyhow::anyhow!("bad request: {value:?} is out of range"))
}

#[cfg(test)]
mod tests;
