//! The agent change a terminal's end sends (W7-C, with #41123): the
//! transaction that tombstones a terminal deletes its agent record, so the
//! same journal batch carries an `agent` `delete` for it. An open
//! `session.events` subscriber then drops the agent at that moment, whatever
//! path ended the terminal (a close, `terminal close`, the reaper), and its
//! fold agrees with `agent.list` and the snapshot, which have no agent of an
//! ended terminal.

use super::*;

/// Queue, for each terminal `patch` tombstones that has an agent record, the
/// `delete` of that agent. It reads the record before the patch deletes it.
pub(super) fn queue_ended_agents(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    let ended = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneTerminal { public_id, .. } => Some(public_id.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>();
    if ended.is_empty() || !crate::state::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    for terminal_id in ended {
        let stored = transaction
            .query_row(
                "SELECT result_json FROM resource_agent_projections WHERE terminal_id = ?1",
                [terminal_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(stored) = stored else { continue };
        let value: Value = serde_json::from_str(&stored)
            .with_context(|| format!("invalid agent projection for terminal {terminal_id:?}"))?;
        let Some(id) = value.get("id").and_then(Value::as_str) else { continue };
        let change = json!({"kind": "delete", "sequence": 0, "resource": "agent", "id": id});
        crate::state::closed_history_store::queue_change(transaction, &change)?;
    }
    Ok(())
}
