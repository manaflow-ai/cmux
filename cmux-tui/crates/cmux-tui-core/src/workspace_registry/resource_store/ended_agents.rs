//! The agent change a terminal's end sends (W7-C: an agent row ends with its
//! terminal). A read already shows the agent of a tombstoned terminal as
//! `done` (`public_agent_projections`); this queues the same change into the
//! batch that tombstones the terminal, so an open `session.events` subscriber
//! gets it at that moment, whatever path ended the terminal (a close, `terminal
//! close`, the reaper). The stored projection is unchanged, as for the read.

use super::*;

/// Queue, for each terminal `patch` tombstones, the end of its agent: an
/// `agent` upsert with state `done`, or a delete for a hook-reported agent
/// (a read leaves those out). An agent already `done` sends nothing.
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
        let mut value: Value = serde_json::from_str(&stored)
            .with_context(|| format!("invalid agent projection for terminal {terminal_id:?}"))?;
        let Some(fields) = value.as_object_mut() else { continue };
        let Some(id) = fields.get("id").and_then(Value::as_str).map(str::to_owned) else {
            continue;
        };
        if fields.get("state").and_then(Value::as_str) == Some("done") {
            continue;
        }
        let change = if fields.get("source").and_then(Value::as_str) == Some("hook") {
            json!({"kind": "delete", "sequence": 0, "resource": "agent", "id": id})
        } else {
            fields.insert("state".into(), json!("done"));
            // The public value never carries the internal hook markers.
            let internal =
                fields.get("source_session").and_then(Value::as_str).is_some_and(|session| {
                    session.starts_with("cmux-hook-sequence:")
                        || session.starts_with("cmux-hook-ended:")
                });
            if internal {
                fields.insert("source_session".into(), Value::Null);
            }
            json!({"kind": "upsert", "sequence": 0, "resource": "agent", "id": id, "value": value})
        };
        crate::state::closed_history_store::queue_change(transaction, &change)?;
    }
    Ok(())
}
