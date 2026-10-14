//! `agent.message.release`: a person's decision on a held delivery, and the
//! expiry of held deliveries.
//!
//! A held delivery waits [`HOLD_MS`] for a decision. Approve moves it to
//! `queued`, where every delivery path finds it; decline moves it to
//! `declined`. Expiry is applied lazily: every agent message mutation first
//! declines the held deliveries whose time is up (reason `expired`), and
//! reads report such a delivery as declined and expired before any mutation
//! has stored it, so a list never shows an expired hold as waiting.

use rusqlite::{OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::agent_message_policy::{HOLD_MS, refused_by};
use super::agent_message_store::{not_found, snapshot};

/// Decline every held delivery whose wait ended at or before `now_ms`.
pub(crate) fn expire_held(transaction: &Transaction<'_>, now_ms: i64) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE agent_message_deliveries
         SET state = 'declined', reason = 'expired', updated_at_ms = ?1
         WHERE state = 'held' AND COALESCE(held_until_ms, 0) <= ?1",
        [now_ms],
    )?;
    Ok(())
}

/// When a delivery held at `now_ms` expires.
pub(crate) fn hold_deadline(now_ms: i64) -> i64 {
    now_ms.saturating_add(HOLD_MS)
}

/// Apply `decision` (`approve` or `decline`) to `recipient`'s held delivery
/// of `message_id` and return the message's snapshot.
pub(crate) fn release(
    transaction: &Transaction<'_>,
    session_id: &str,
    message_id: &str,
    recipient: &str,
    decision: &str,
    now_ms: i64,
) -> anyhow::Result<Value> {
    let (state, reason) = match decision {
        "approve" => ("queued", "approved"),
        "decline" => ("declined", "declined"),
        _ => return Err(anyhow::anyhow!("bad request: decision must be approve or decline")),
    };
    expire_held(transaction, now_ms)?;
    let current: Option<(String, Option<String>)> = transaction
        .query_row(
            "SELECT state, reason FROM agent_message_deliveries
             WHERE message_id = ?1 AND recipient = ?2",
            params![message_id, recipient],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((current, current_reason)) = current else {
        return Err(not_found(message_id));
    };
    if current != "held" {
        let expired = current == "declined" && current_reason.as_deref() == Some("expired");
        let (code, message) = if expired {
            ("expired", format!("message {message_id} waited 24 hours for {recipient} and expired"))
        } else {
            ("not_held", format!("message {message_id} is {current} for {recipient}, not held"))
        };
        return Err(refused_release(code, message, &current));
    }
    transaction.execute(
        "UPDATE agent_message_deliveries
         SET state = ?3, reason = ?4, updated_at_ms = ?5, held_until_ms = NULL,
             queued_at_ms = CASE WHEN ?3 = 'queued' THEN ?5 ELSE queued_at_ms END
         WHERE message_id = ?1 AND recipient = ?2",
        params![message_id, recipient, state, reason, now_ms],
    )?;
    snapshot(transaction, session_id, message_id, now_ms)?.ok_or_else(|| not_found(message_id))
}

fn refused_release(reason: &str, message: String, state: &str) -> anyhow::Error {
    refused_by("agent.message.release", reason, message, json!({"state": state}))
}
