//! Agent chat dock (a docked column with role `agent_chat`).
//!
//! The chat dock holds one pane for every client: a split or an edge drop
//! into it is refused. A column that already holds more panes (a record
//! written before this guard) keeps them, but may not grow.

use super::*;
use crate::model::DockRole;

/// `reason_code` / `error_code` of a change that would add a pane to the
/// agent chat dock.
pub const AGENT_CHAT_COLUMN_CODE: &str = "dock-column-agent-chat";

/// Pane count of every agent chat column, keyed by workspace and column.
pub(crate) fn agent_chat_columns(state: &State) -> Vec<((WorkspaceId, SplitId), usize)> {
    state
        .workspaces
        .iter()
        .flat_map(|workspace| {
            workspace.screens.iter().flat_map(move |screen| {
                screen
                    .layout_columns
                    .iter()
                    .filter(|column| {
                        column.dock.is_some_and(|flag| flag.role == Some(DockRole::AgentChat))
                    })
                    .map(move |column| {
                        ((workspace.id, column.id), column.root.pane_ids_vec().len())
                    })
            })
        })
        .collect()
}

/// Refuses a layout change that left an agent chat column with more panes
/// than it had (or more than one, for a column that was not a chat dock).
pub(crate) fn ensure_agent_chat_columns_unsplit(
    operation: &str,
    before: &[((WorkspaceId, SplitId), usize)],
    after: &State,
) -> anyhow::Result<()> {
    let grew = agent_chat_columns(after).into_iter().any(|(key, panes)| {
        let had = before.iter().find(|(entry, _)| *entry == key).map_or(1, |(_, had)| *had);
        panes > had.max(1)
    });
    if grew { Err(refusal(operation)) } else { Ok(()) }
}

/// Refuses a new pane in `target`'s column (a split, a row or an auto-layout
/// append) when that column is an agent chat dock. Pane creation spawns its
/// terminal outside the staged plan, so it checks here before the spawn and
/// again when it attaches. A new viewport column beside the dock is allowed.
pub(crate) fn ensure_pane_column_not_agent_chat(
    operation: &str,
    state: &State,
    target: PaneId,
) -> anyhow::Result<()> {
    let chat = state
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.layout_columns.iter())
        .any(|column| {
            column.dock.is_some_and(|flag| flag.role == Some(DockRole::AgentChat))
                && column.root.contains(target)
        });
    if chat { Err(refusal(operation)) } else { Ok(()) }
}

fn refusal(operation: &str) -> anyhow::Error {
    ResourceError::operation_failed(
        operation,
        format!("{AGENT_CHAT_COLUMN_CODE}: the agent chat dock holds one pane"),
        serde_json::json!({"reason_code": AGENT_CHAT_COLUMN_CODE}),
    )
    .into()
}
