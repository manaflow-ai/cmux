//! The person's own view of the conversation list on the local owner
//! (`conversation-inbox-state-v1`): a pin with its position and a "marked
//! unread" flag, per participant and conversation. This is not conversation
//! state: it lives beside the reducer head (no rev, no `conversation-changed`,
//! no corpus case) and only its participant reads it, as the Cloud owner keeps
//! the same fields in the person's UserDO inbox (home-core inbox/reducer.ts
//! `inbox.pin`, `inbox.mark_unread`), never in ConversationDO.

use std::collections::HashMap;

use cmux_conversation::Reject;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};

use super::{ConversationStore, load_head, rejected, to_i64};

/// Kept in the schema batch: `CREATE TABLE IF NOT EXISTS` needs no version
/// bump, and an older daemon ignores the table.
pub(super) const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS inbox_state (
       participant TEXT NOT NULL,
       conversation TEXT NOT NULL,
       pin_position INTEGER CHECK(pin_position IS NULL OR pin_position >= 0),
       marked_unread INTEGER NOT NULL DEFAULT 0 CHECK(marked_unread IN (0, 1)),
       PRIMARY KEY(participant, conversation)
     ) WITHOUT ROWID;";

/// The largest pin position (the Cloud owner's `MAX_PIN_POSITION`): a
/// position is an exact integer in every client, and the next default
/// position is one more.
pub(crate) const MAX_PIN_POSITION: u64 = (1 << 53) - 2;

/// One person's state of one conversation (the fields `conversation-list`
/// adds to a summary for its caller).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub(crate) struct InboxState {
    pub pinned: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pin_position: Option<u64>,
    pub marked_unread: bool,
}

/// `conversation-inbox-op` `op`: the same shapes as the Cloud owner's
/// `inbox.pin` and `inbox.mark_unread` params, tagged by `kind`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", deny_unknown_fields)]
pub(crate) enum InboxOp {
    /// Pin (at `position`, else the existing position, else after the last
    /// pin) or unpin.
    #[serde(rename = "inbox.pin")]
    Pin {
        pinned: bool,
        #[serde(default)]
        position: Option<u64>,
    },
    /// Flag the conversation unread (the read cursor stays) or clear it.
    #[serde(rename = "inbox.mark_unread")]
    MarkUnread { unread: bool },
}

impl ConversationStore {
    /// Every conversation `participant` pinned or marked, by conversation id.
    pub(crate) fn inbox_states(
        &mut self,
        participant: &str,
    ) -> anyhow::Result<HashMap<String, InboxState>> {
        let mut statement = self.connection.prepare(
            "SELECT conversation, pin_position, marked_unread FROM inbox_state
             WHERE participant = ?1",
        )?;
        let rows = statement
            .query_map(params![participant], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?, row.get::<_, i64>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows
            .into_iter()
            .map(|(conversation, position, unread)| (conversation, state(position, unread)))
            .collect())
    }

    /// Applies `op` to `actor`'s own state of `conversation` and returns the
    /// new state. The actor must be a participant. Values are absolute, so a
    /// retry writes the same row.
    pub(crate) fn apply_inbox_op(
        &mut self,
        conversation: &str,
        actor: &str,
        op: &InboxOp,
    ) -> anyhow::Result<InboxState> {
        if let InboxOp::Pin { position: Some(position), .. } = op {
            anyhow::ensure!(
                *position <= MAX_PIN_POSITION,
                "bad request: op.position must be at most {MAX_PIN_POSITION}"
            );
        }
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let head = load_head(&transaction, conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        if head.participant(actor).is_none() {
            return Err(rejected(Reject::NotParticipant));
        }
        let current = load(&transaction, actor, conversation)?;
        let next = match *op {
            InboxOp::Pin { pinned: false, .. } => {
                InboxState { pinned: false, pin_position: None, ..current }
            }
            InboxOp::Pin { pinned: true, position } => {
                let position = match (position, current.pin_position) {
                    (Some(position), _) => position,
                    (None, Some(kept)) => kept,
                    (None, None) => next_position(&transaction, actor)?,
                };
                InboxState { pinned: true, pin_position: Some(position), ..current }
            }
            InboxOp::MarkUnread { unread } => InboxState { marked_unread: unread, ..current },
        };
        if next.pin_position.is_none() && !next.marked_unread {
            transaction.execute(
                "DELETE FROM inbox_state WHERE participant = ?1 AND conversation = ?2",
                params![actor, conversation],
            )?;
        } else {
            let position = next.pin_position.map(to_i64).transpose()?;
            transaction.execute(
                "INSERT INTO inbox_state(participant, conversation, pin_position, marked_unread)
                 VALUES(?1, ?2, ?3, ?4)
                 ON CONFLICT(participant, conversation) DO UPDATE
                 SET pin_position = excluded.pin_position, marked_unread = excluded.marked_unread",
                params![actor, conversation, position, i64::from(next.marked_unread)],
            )?;
        }
        transaction.commit()?;
        Ok(next)
    }
}

fn state(position: Option<i64>, unread: i64) -> InboxState {
    let pin_position = position.and_then(|position| u64::try_from(position).ok());
    InboxState { pinned: pin_position.is_some(), pin_position, marked_unread: unread != 0 }
}

fn load(
    connection: &Connection,
    participant: &str,
    conversation: &str,
) -> anyhow::Result<InboxState> {
    let row: Option<(Option<i64>, i64)> = connection
        .query_row(
            "SELECT pin_position, marked_unread FROM inbox_state
             WHERE participant = ?1 AND conversation = ?2",
            params![participant, conversation],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    Ok(row.map(|(position, unread)| state(position, unread)).unwrap_or_default())
}

/// After `participant`'s last pin (the Cloud owner's `next_pin`).
fn next_position(connection: &Connection, participant: &str) -> anyhow::Result<u64> {
    let last: Option<i64> = connection.query_row(
        "SELECT MAX(pin_position) FROM inbox_state WHERE participant = ?1",
        params![participant],
        |row| row.get(0),
    )?;
    let next = last.and_then(|last| u64::try_from(last).ok()).map_or(0, |last| last + 1);
    anyhow::ensure!(
        next <= MAX_PIN_POSITION,
        "bad request: no pin position is left after the last pin"
    );
    Ok(next)
}
