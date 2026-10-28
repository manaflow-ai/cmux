//! Command rows of the merged history: the daemon's terminal command rows
//! (`terminal-command-history-v1`, mux/command_history.rs), the rows the
//! Swift History page lists (cx-hnmbt.12). An entry id is
//! `command:local/<row id>`, the Swift `TerminalCommand.qualifiedID` of the
//! local machine, so the app opens a row a page listed. A remove or clear
//! deletes rows through the command worker, as `delete-terminal-commands`.

use std::sync::{Arc, PoisonError};

use cmux_history::{HistoryEntry, HistoryKind};

use super::merged::LOCAL_MACHINE;
use crate::Mux;
use crate::panic_free::JsonFields;
use crate::state::command_history_store::{CommandDeletion, MAX_COMMAND_LIST_LIMIT};
use crate::workspace_registry::unix_epoch_ms;

pub(super) enum Selection {
    Ids(Vec<u64>),
    StartedSince(u64),
    All,
}

/// The row id of `command:local/<row id>`.
pub(super) fn row_id(id: &str) -> Option<u64> {
    let rest = id.strip_prefix("command:")?.strip_prefix(LOCAL_MACHINE)?.strip_prefix('/')?;
    if rest.is_empty() || !rest.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    rest.parse().ok()
}

pub(super) fn ids(ids: &[&str]) -> Vec<u64> {
    ids.iter().filter_map(|id| row_id(id)).collect()
}

/// The newest unexpired rows (at most the store's page) as entries.
pub(super) fn entries(mux: &Mux) -> anyhow::Result<Vec<HistoryEntry>> {
    let limit = MAX_COMMAND_LIST_LIMIT;
    let now = unix_epoch_ms()?;
    let page = mux
        .workspace_registry
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .list_terminal_commands(None, limit, now)?;
    Ok(page
        .commands
        .iter()
        .map(|row| {
            let at_ms = i64::try_from(row.started_at_ms).unwrap_or(i64::MAX);
            let title = row.command.clone().unwrap_or_default();
            let mut entry = HistoryEntry::new(
                format!("command:{LOCAL_MACHINE}/{}", row.id),
                HistoryKind::Command,
                at_ms,
                title,
            );
            entry.detail.clone_from(&row.cwd);
            entry.cwd.clone_from(&row.cwd);
            entry.command.clone_from(&row.command);
            entry.exit_code = row.exit_code.map(i64::from);
            entry
        })
        .collect())
}

/// Deletes rows in the command worker's order; answers the deleted count.
pub(super) fn delete(mux: &Arc<Mux>, selection: Selection) -> anyhow::Result<u64> {
    let deletion = match selection {
        Selection::Ids(ids) if ids.is_empty() => return Ok(0),
        Selection::Ids(mut ids) => {
            ids.sort_unstable();
            ids.dedup();
            ids.truncate(crate::state::command_history_store::MAX_COMMAND_DELETE_IDS);
            CommandDeletion::Ids(ids)
        }
        Selection::StartedSince(since) => CommandDeletion::StartedSince(since),
        Selection::All => CommandDeletion::All,
    };
    let answer = mux.delete_terminal_commands(deletion)?;
    Ok(answer.field("deleted").as_u64().unwrap_or(0))
}
