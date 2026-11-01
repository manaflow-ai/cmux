//! Agent chat dock (a docked column with role `agent_chat`).
//!
//! The chat dock keeps its chat on top for every client: Split Down (a
//! `pane.split` toward `down` of a pane in the dock) adds a pane below, as
//! classic cmux's Cmd-Shift-D does (#29848); any other split, new row,
//! auto-layout append or edge drop into it is refused, so the chat stays the
//! dock's first pane.

use super::*;
use crate::model::DockRole;

/// `reason_code` / `error_code` of a change that would add a pane to the
/// agent chat dock.
pub const AGENT_CHAT_COLUMN_CODE: &str = "dock-column-agent-chat";

/// An agent chat column before a change: its key (workspace and column),
/// its pane count, its top pane (the chat's) and that pane's tabs.
pub(crate) type AgentChatColumn = ((WorkspaceId, SplitId), usize, Option<PaneId>, Vec<SurfaceId>);

/// Every agent chat column of `state` ([`AgentChatColumn`]).
pub(crate) fn agent_chat_columns(state: &State) -> Vec<AgentChatColumn> {
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
                        let panes = column.root.pane_ids_vec();
                        let top = panes.first().copied();
                        let chat = top
                            .and_then(|pane| state.panes.get(&pane))
                            .map(|pane| pane.tabs.clone())
                            .unwrap_or_default();
                        ((workspace.id, column.id), panes.len(), top, chat)
                    })
            })
        })
        .collect()
}

/// Refuses a layout change that left an agent chat column with more panes
/// than it had (or more than one, for a column that was not a chat dock),
/// or that changed its top pane while the chat stays in it (a swap, or the
/// chat's tab moved into a pane below it, #29848): the chat dock's top pane
/// is always the chat's own. Moving the chat out of its column is allowed
/// and leaves a plain dock ([`release_agent_chat_role`]); so is setting or
/// clearing the role, which keeps the top pane. Split Down
/// attaches its pane outside the staged plan
/// ([`ensure_pane_column_not_agent_chat`]), so it never reaches this check.
pub(crate) fn ensure_agent_chat_columns_unsplit(
    operation: &str,
    before: &[AgentChatColumn],
    after: &State,
) -> anyhow::Result<()> {
    let grew = agent_chat_columns(after).into_iter().any(|(key, panes, _, _)| {
        let had = before.iter().find(|(entry, ..)| *entry == key).map_or(1, |(_, had, ..)| *had);
        panes > had.max(1)
    });
    let displaced =
        before.iter().any(|(key, _, top, chat)| chat_displaced(after, *key, *top, chat));
    if grew || displaced { Err(refusal(operation)) } else { Ok(()) }
}

/// Whether the chat (`chat`, the tabs of its top pane `top`) is still in
/// column `key` of `after` under another top pane.
fn chat_displaced(
    after: &State,
    (workspace, column): (WorkspaceId, SplitId),
    top: Option<PaneId>,
    chat: &[SurfaceId],
) -> bool {
    let Some(column) = after
        .workspaces
        .iter()
        .filter(|entry| entry.id == workspace)
        .flat_map(|entry| entry.screens.iter())
        .flat_map(|screen| screen.layout_columns.iter())
        .find(|entry| entry.id == column)
    else {
        return false;
    };
    let tabs =
        |pane: &PaneId| after.panes.get(pane).map(|pane| pane.tabs.as_slice()).unwrap_or(&[]);
    let holds_chat = |pane: &PaneId| tabs(pane).iter().any(|tab| chat.contains(tab));
    let panes = column.root.pane_ids_vec();
    panes.iter().any(holds_chat) && panes.first().copied() != top
}

/// Refuses a new pane in `target`'s column (a split, a row or an auto-layout
/// append) when that column is an agent chat dock, unless it is a split
/// below `target` (`splits_down`: `pane.split` toward `down`, #29848) in a
/// dock that is not pinned (Home's pinned dock takes no new pane). Pane
/// creation spawns its terminal outside the staged plan, so it checks here
/// before the spawn and again when it attaches. A new viewport column beside
/// the dock is allowed.
pub(crate) fn ensure_pane_column_not_agent_chat(
    operation: &str,
    state: &State,
    target: PaneId,
    splits_down: bool,
) -> anyhow::Result<()> {
    // Home's pinned dock takes no pane at all, Split Down included.
    let refused = state
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.layout_columns.iter())
        .any(|column| {
            column.root.contains(target)
                && column.dock.is_some_and(|flag| {
                    flag.role == Some(DockRole::AgentChat) && (flag.pinned || !splits_down)
                })
        });
    if refused { Err(refusal(operation)) } else { Ok(()) }
}

/// Whether `pane` is the top pane of an agent chat column: the chat itself.
pub(crate) fn is_agent_chat_top(column: &LayoutColumn, pane: PaneId) -> bool {
    column.dock.is_some_and(|flag| flag.role == Some(DockRole::AgentChat))
        && column.root.pane_ids_vec().first() == Some(&pane)
}

/// After the chat's own pane left its dock (closed or moved out) while Split
/// Down panes stay below it (#29848), the column is no longer the chat: it
/// drops the `agent_chat` role and stays docked on its edge as a plain dock,
/// so a terminal is never taken for the chat.
pub(crate) fn release_agent_chat_role(column: &mut LayoutColumn) {
    if let Some(flag) = column.dock.as_mut() {
        flag.role = None;
    }
}

fn refusal(operation: &str) -> anyhow::Error {
    ResourceError::operation_failed(
        operation,
        format!("{AGENT_CHAT_COLUMN_CODE}: the agent chat dock takes a new pane only below, by Split Down"),
        serde_json::json!({"reason_code": AGENT_CHAT_COLUMN_CODE}),
    )
    .into()
}
