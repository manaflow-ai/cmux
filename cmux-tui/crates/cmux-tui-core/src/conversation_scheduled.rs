//! Send Later on the local conversation owner (`conversation-scheduled-v1`,
//! cmux#25634): a participant's `message.send` held until its time, then
//! committed by the owner as that participant, exactly as if it were sent
//! then. A waiting message is not conversation state: it lives beside the
//! reducer head like the per-person inbox state (no rev, no
//! `conversation-changed`, no corpus case), and only its author reads it.
//!
//! Delivery is one transaction: the op (idempotency key = its
//! `client_msg_id`, as every send) and the removal of the row commit together,
//! so a crash at any point sends it at most once, and a restart sends what
//! came due while the daemon was down. A send the reducer refuses (the author
//! left the conversation, the agent budget) keeps the row as `failed` with the
//! reason, for the author to retry, edit or cancel.

use std::sync::{Condvar, Mutex, PoisonError};
use std::time::Duration;

use cmux_conversation::{Op, OpRequest, Part, Reject};
use rusqlite::{OptionalExtension, Transaction, TransactionBehavior, params};
use serde::Serialize;

use super::{
    ConversationStore, OpOutcome, apply_op_in, attachments, load_head, load_message_by_id,
    load_message_by_seq, new_id, rejected, to_i64,
};

/// Kept in the schema batch: `CREATE TABLE IF NOT EXISTS` needs no version
/// bump, and an older daemon ignores the table.
pub(super) const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS scheduled_message (
       id TEXT PRIMARY KEY NOT NULL,
       conversation TEXT NOT NULL,
       author TEXT NOT NULL,
       client_msg_id TEXT NOT NULL,
       op_json TEXT NOT NULL,
       send_at_ms INTEGER NOT NULL CHECK(send_at_ms >= 0),
       created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
       failure TEXT,
       UNIQUE(conversation, author, client_msg_id)
     );
     CREATE INDEX IF NOT EXISTS scheduled_message_by_due
       ON scheduled_message(send_at_ms, id) WHERE failure IS NULL;
     CREATE INDEX IF NOT EXISTS scheduled_message_by_author
       ON scheduled_message(author, send_at_ms, id);";

/// The latest time a message may be scheduled for, from now.
pub(crate) const MAX_HORIZON_MS: u64 = 366 * 24 * 3_600_000;
/// Waiting and failed messages one participant may hold at once.
pub(crate) const MAX_PER_AUTHOR: i64 = 500;

/// A Send Later refusal that is not a reducer reason (`schedule_rejected`):
/// `unknown_scheduled` (no such message of the caller's), `too_late` (past
/// the horizon), `too_many`, `not_a_send` (only `message.send` waits).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScheduleRejected(pub &'static str);

impl ScheduleRejected {
    pub const CODE: &'static str = "schedule_rejected";
}

impl std::fmt::Display for ScheduleRejected {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for ScheduleRejected {}

fn refused(reason: &'static str) -> anyhow::Error {
    ScheduleRejected(reason).into()
}

/// One waiting (or failed) message, as `conversation-scheduled-list` and the
/// `conversation-scheduled-changed` event show it to its author.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct ScheduledMessage {
    pub id: String,
    pub conversation: String,
    pub author: String,
    /// The `message.send` op it will commit.
    pub op: Op,
    pub send_at_ms: u64,
    pub created_at_ms: u64,
    /// `waiting`, or `failed` with `failure` (the refusal's reason code).
    pub state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
}

/// What became of a due (or Send Now) message.
#[derive(Debug)]
pub(crate) enum Delivery {
    /// Committed and removed from the queue.
    Sent { scheduled: ScheduledMessage, outcome: OpOutcome },
    /// The owner refused the send; the row stays, marked failed.
    Failed { scheduled: ScheduledMessage },
    /// Nothing waits under that id (sent or cancelled meanwhile).
    Gone,
    /// An agent's send inside the rate gap: it waits until the gap ends.
    Postponed,
}

/// A change of a waiting message: its new time and/or its new parts.
#[derive(Debug, Default)]
pub(crate) struct ScheduledEdit {
    pub send_at_ms: Option<u64>,
    pub parts: Option<Vec<Part>>,
}

impl ConversationStore {
    /// Queues `op` (a `message.send` of `actor`) for `send_at_ms`. The send is
    /// checked now as it would be at delivery (participant, parts, reply and
    /// thread targets, attachments); a retry with the same `client_msg_id`
    /// and op returns the waiting message at its time (a retry that counts
    /// its delay again from a later now is the same message, not a second
    /// one), another op under that id is `idempotency_conflict`. A time
    /// already past sends at once.
    pub(crate) fn schedule_send(
        &mut self,
        conversation: &str,
        actor: &str,
        op: &Op,
        send_at_ms: u64,
        now_ms: u64,
    ) -> anyhow::Result<(ScheduledMessage, bool)> {
        let Op::MessageSend { client_msg_id, parts, .. } = op else {
            return Err(refused("not_a_send"));
        };
        if send_at_ms > now_ms.saturating_add(MAX_HORIZON_MS) {
            return Err(refused("too_late"));
        }
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(existing) = load_by_client_id(&transaction, conversation, actor, client_msg_id)?
        {
            if existing.op != *op {
                return Err(rejected(Reject::IdempotencyConflict));
            }
            return Ok((existing, false));
        }
        check_send(&transaction, conversation, actor, op, now_ms)?;
        // The id was already spent on a send: the delivery would replay it.
        let spent: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM op_ledger_v2
             WHERE conversation = ?1 AND actor = ?2 AND idempotency_key = ?3)",
            params![conversation, actor, client_msg_id],
            |row| row.get(0),
        )?;
        if spent {
            return Err(rejected(Reject::IdempotencyConflict));
        }
        let held: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM scheduled_message WHERE author = ?1",
            params![actor],
            |row| row.get(0),
        )?;
        if held >= MAX_PER_AUTHOR {
            return Err(refused("too_many"));
        }
        let scheduled = ScheduledMessage {
            id: new_id("sch_", now_ms)?,
            conversation: conversation.to_string(),
            author: actor.to_string(),
            op: op.clone(),
            send_at_ms,
            created_at_ms: now_ms,
            state: "waiting",
            failure: None,
        };
        transaction.execute(
            "INSERT INTO scheduled_message(id, conversation, author, client_msg_id, op_json,
                                           send_at_ms, created_at_ms, failure)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL)",
            params![
                scheduled.id,
                conversation,
                actor,
                client_msg_id,
                serde_json::to_string(op)?,
                to_i64(send_at_ms)?,
                to_i64(now_ms)?,
            ],
        )?;
        // The attachments it carries stay referenced while it waits, so the
        // unreferenced sweep never takes their bytes before the send.
        attachments::write_refs(&transaction, conversation, &scheduled.id, parts)?;
        transaction.commit()?;
        Ok((scheduled, true))
    }

    /// `actor`'s waiting and failed messages, earliest first; of one
    /// conversation when `conversation` is set.
    pub(crate) fn scheduled_messages(
        &mut self,
        actor: &str,
        conversation: Option<&str>,
    ) -> anyhow::Result<Vec<ScheduledMessage>> {
        let mut statement = self.connection.prepare(
            "SELECT id, conversation, author, op_json, send_at_ms, created_at_ms, failure
             FROM scheduled_message
             WHERE author = ?1 AND (?2 IS NULL OR conversation = ?2)
             ORDER BY send_at_ms, id",
        )?;
        let rows = statement
            .query_map(params![actor, conversation], read_row)?
            .collect::<Result<Vec<_>, _>>()?;
        // A row this daemon cannot read (written by a newer one) is left out,
        // never the whole list; the sender marks it failed (`unreadable`).
        Ok(rows
            .into_iter()
            .filter_map(|row| row.decode().map_err(|error| eprintln!("cmux-tui: {error:#}")).ok())
            .collect())
    }

    /// Moves `actor`'s message `id` to a new time and/or replaces its parts.
    /// A failed message waits again.
    pub(crate) fn edit_scheduled(
        &mut self,
        actor: &str,
        id: &str,
        edit: ScheduledEdit,
        now_ms: u64,
    ) -> anyhow::Result<ScheduledMessage> {
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut scheduled = load_own(&transaction, actor, id)?;
        if let Some(send_at_ms) = edit.send_at_ms {
            if send_at_ms > now_ms.saturating_add(MAX_HORIZON_MS) {
                return Err(refused("too_late"));
            }
            scheduled.send_at_ms = send_at_ms;
        }
        if let Some(new_parts) = edit.parts {
            let Op::MessageSend { parts, .. } = &mut scheduled.op else {
                return Err(refused("not_a_send"));
            };
            *parts = new_parts;
        }
        check_send(&transaction, &scheduled.conversation, actor, &scheduled.op, now_ms)?;
        scheduled.state = "waiting";
        scheduled.failure = None;
        transaction.execute(
            "UPDATE scheduled_message SET op_json = ?2, send_at_ms = ?3, failure = NULL
             WHERE id = ?1",
            params![id, serde_json::to_string(&scheduled.op)?, to_i64(scheduled.send_at_ms)?],
        )?;
        attachments::write_refs(&transaction, &scheduled.conversation, id, send_parts(&scheduled))?;
        transaction.commit()?;
        Ok(scheduled)
    }

    /// Removes `actor`'s message `id` unsent and returns it.
    pub(crate) fn cancel_scheduled(
        &mut self,
        actor: &str,
        id: &str,
    ) -> anyhow::Result<ScheduledMessage> {
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let scheduled = load_own(&transaction, actor, id)?;
        remove(&transaction, &scheduled)?;
        transaction.commit()?;
        Ok(scheduled)
    }

    /// The author of message `id`, if one waits under it.
    pub(crate) fn scheduled_author(&mut self, id: &str) -> anyhow::Result<Option<String>> {
        Ok(self
            .connection
            .query_row("SELECT author FROM scheduled_message WHERE id = ?1", params![id], |row| {
                row.get(0)
            })
            .optional()?)
    }

    /// The earliest time a waiting message is due (failed ones never are).
    pub(crate) fn next_scheduled_due(&mut self) -> anyhow::Result<Option<u64>> {
        let due: Option<i64> = self.connection.query_row(
            "SELECT MIN(send_at_ms) FROM scheduled_message WHERE failure IS NULL",
            [],
            |row| row.get(0),
        )?;
        Ok(due.map(|due| u64::try_from(due).unwrap_or(0)))
    }

    /// The waiting messages due at `now_ms`, earliest first.
    pub(crate) fn due_scheduled(&mut self, now_ms: u64) -> anyhow::Result<Vec<String>> {
        let mut statement = self.connection.prepare(
            "SELECT id FROM scheduled_message WHERE failure IS NULL AND send_at_ms <= ?1
             ORDER BY send_at_ms, id",
        )?;
        statement
            .query_map(params![to_i64(now_ms)?], |row| row.get(0))?
            .collect::<Result<_, _>>()
            .map_err(Into::into)
    }

    /// Sends message `id` now (its author chose Send Now: `due_at` is `None`)
    /// or because it came due (`due_at` is the sender's now): the op and the
    /// removal of the row in one transaction. Checked in that transaction,
    /// so a message moved later or marked failed since the sender read the
    /// due list is not sent (`Gone`). A refusal by the owner marks the row
    /// failed with its reason; a row this daemon cannot read is marked
    /// failed `unreadable` without decoding it, so it stops coming due.
    pub(crate) fn deliver_scheduled(
        &mut self,
        id: &str,
        due_at: Option<u64>,
    ) -> anyhow::Result<Delivery> {
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let Some(row) = load_row(&transaction, id)? else {
            return Ok(Delivery::Gone);
        };
        if let Some(now_ms) = due_at
            && (row.failure.is_some() || u64::try_from(row.send_at_ms).unwrap_or(0) > now_ms)
        {
            return Ok(Delivery::Gone);
        }
        let scheduled = match row.decode() {
            Ok(scheduled) => scheduled,
            Err(error) => {
                eprintln!("cmux-tui: {error:#}");
                transaction.execute(
                    "UPDATE scheduled_message SET failure = 'unreadable' WHERE id = ?1",
                    params![id],
                )?;
                transaction.commit()?;
                return Ok(Delivery::Gone);
            }
        };
        let Op::MessageSend { client_msg_id, .. } = &scheduled.op else {
            return Err(refused("not_a_send"));
        };
        let sent = apply_op_in(
            &transaction,
            &scheduled.conversation,
            client_msg_id,
            &scheduled.author,
            &scheduled.op,
        );
        match sent {
            Ok(outcome) => {
                remove(&transaction, &scheduled)?;
                transaction.commit()?;
                Ok(Delivery::Sent { scheduled, outcome })
            }
            Err(error) => {
                // A store failure fails the message too: it is not retried on
                // its own (a broken row would otherwise come due forever).
                let reason = failure_reason(&error).unwrap_or_else(|| {
                    eprintln!("cmux-tui: scheduled message {id} not sent: {error:#}");
                    "store_error".to_string()
                });
                // Nothing of the refused op was written; only the mark.
                drop(transaction);
                // The agent rate gap is a wait, not a refusal: it waits out
                // the gap and goes then.
                if reason == Reject::AgentRate.code() {
                    let later = crate::workspace_registry::unix_epoch_ms()?
                        .saturating_add(cmux_conversation::MIN_AGENT_GAP_MS);
                    self.connection.execute(
                        "UPDATE scheduled_message SET send_at_ms = ?2 WHERE id = ?1",
                        params![id, to_i64(later)?],
                    )?;
                    return Ok(Delivery::Postponed);
                }
                self.connection.execute(
                    "UPDATE scheduled_message SET failure = ?2 WHERE id = ?1",
                    params![id, reason],
                )?;
                Ok(Delivery::Failed {
                    scheduled: ScheduledMessage {
                        state: "failed",
                        failure: Some(reason),
                        ..scheduled
                    },
                })
            }
        }
    }
}

/// The reason code of an owner refusal, or `None` for a store failure.
fn failure_reason(error: &anyhow::Error) -> Option<String> {
    error
        .downcast_ref::<super::ConversationRejected>()
        .map(|rejected| rejected.0.code().to_string())
        .or_else(|| error.downcast_ref::<attachments::AttachmentRejected>().map(|r| r.0.into()))
}

/// The checks the owner makes of this send, without writing anything: the
/// author takes part, the id and parts are valid, the reply and thread
/// targets exist, the attachments are the author's. Time-dependent guards
/// (the agent budget and rate) are checked at delivery.
fn check_send(
    transaction: &Transaction<'_>,
    conversation: &str,
    actor: &str,
    op: &Op,
    now_ms: u64,
) -> anyhow::Result<()> {
    let Op::MessageSend { client_msg_id, parts, answers, answers_pending, .. } = op else {
        return Err(refused("not_a_send"));
    };
    let head = load_head(transaction, conversation)?
        .ok_or_else(|| rejected(Reject::UnknownConversation))?;
    // A scheduled message answers nothing and asks nothing: those belong to
    // an agent's live turn.
    if !answers.is_empty()
        || !answers_pending.is_empty()
        || parts.iter().any(|part| matches!(part, Part::Question(_)))
    {
        return Err(rejected(Reject::InvalidParts));
    }
    // The reducer's own checks (participant, id, parts, reply and thread
    // targets) on a commit that is thrown away.
    let target_of = |id: Option<&str>| match id {
        Some(id) => load_message_by_id(transaction, id),
        None => Ok(None),
    };
    let reply_target = target_of(op.reply_to().map(|reply| reply.message_id.as_str()))?;
    let thread_target = target_of(op.thread_root())?;
    let last_message = load_message_by_seq(transaction, conversation, head.last_seq)?;
    let now = cmux_conversation::format_rfc3339_millis(now_ms);
    cmux_conversation::apply(
        &head,
        &OpRequest {
            actor,
            idempotency_key: client_msg_id,
            op,
            now: &now,
            new_message_id: "msg_check",
            target: None,
            reply_target: reply_target.as_ref(),
            thread_target: thread_target.as_ref(),
            last_message: last_message.as_ref(),
        },
    )
    .map_err(rejected)?;
    attachments::check_parts(transaction, conversation, actor, parts)
}

fn send_parts(scheduled: &ScheduledMessage) -> &[Part] {
    match &scheduled.op {
        Op::MessageSend { parts, .. } => parts,
        _ => &[],
    }
}

/// Deletes the row and the attachment references it held.
fn remove(transaction: &Transaction<'_>, scheduled: &ScheduledMessage) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM scheduled_message WHERE id = ?1", params![scheduled.id])?;
    attachments::write_refs(transaction, &scheduled.conversation, &scheduled.id, &[])
}

/// A stored row before its op is decoded.
struct Row {
    id: String,
    conversation: String,
    author: String,
    op_json: String,
    send_at_ms: i64,
    created_at_ms: i64,
    failure: Option<String>,
}

impl Row {
    fn decode(self) -> anyhow::Result<ScheduledMessage> {
        let op = serde_json::from_str(&self.op_json).map_err(|error| {
            anyhow::anyhow!("scheduled message {} is corrupt: {error}", self.id)
        })?;
        Ok(ScheduledMessage {
            id: self.id,
            conversation: self.conversation,
            author: self.author,
            op,
            send_at_ms: u64::try_from(self.send_at_ms).unwrap_or(0),
            created_at_ms: u64::try_from(self.created_at_ms).unwrap_or(0),
            state: if self.failure.is_some() { "failed" } else { "waiting" },
            failure: self.failure,
        })
    }
}

fn read_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Row> {
    Ok(Row {
        id: row.get(0)?,
        conversation: row.get(1)?,
        author: row.get(2)?,
        op_json: row.get(3)?,
        send_at_ms: row.get(4)?,
        created_at_ms: row.get(5)?,
        failure: row.get(6)?,
    })
}

const SELECT_ROW: &str = "SELECT id, conversation, author, op_json, send_at_ms, created_at_ms,
                                 failure FROM scheduled_message";

fn load_row(transaction: &Transaction<'_>, id: &str) -> anyhow::Result<Option<Row>> {
    Ok(transaction
        .query_row(&format!("{SELECT_ROW} WHERE id = ?1"), params![id], read_row)
        .optional()?)
}

/// `actor`'s own message `id`; anyone else's is unknown to them.
fn load_own(
    transaction: &Transaction<'_>,
    actor: &str,
    id: &str,
) -> anyhow::Result<ScheduledMessage> {
    match load_row(transaction, id)? {
        Some(row) if row.author == actor => row.decode(),
        _ => Err(refused("unknown_scheduled")),
    }
}

fn load_by_client_id(
    transaction: &Transaction<'_>,
    conversation: &str,
    actor: &str,
    client_msg_id: &str,
) -> anyhow::Result<Option<ScheduledMessage>> {
    transaction
        .query_row(
            &format!("{SELECT_ROW} WHERE conversation = ?1 AND author = ?2 AND client_msg_id = ?3"),
            params![conversation, actor, client_msg_id],
            read_row,
        )
        .optional()?
        .map(Row::decode)
        .transpose()
}

/// The sender's wake: a change of the queue bumps the generation, and the
/// sender waits for a new generation or its next due time. Nothing scheduled:
/// it waits with no timeout (no polling, idle-wakeups.md).
#[derive(Debug, Default)]
pub(crate) struct SenderWake {
    state: Mutex<WakeState>,
    changed: Condvar,
}

#[derive(Debug, Default)]
struct WakeState {
    generation: u64,
    started: bool,
}

impl SenderWake {
    /// The queue changed: the sender looks again.
    pub(crate) fn notify(&self) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.generation += 1;
        self.changed.notify_all();
    }

    /// True for the first caller only: it starts the sender.
    pub(crate) fn claim_start(&self) -> bool {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        !std::mem::replace(&mut state.started, true)
    }

    pub(crate) fn generation(&self) -> u64 {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).generation
    }

    /// Waits until the generation moves past `seen` or `timeout` passes;
    /// returns the generation then.
    pub(crate) fn wait(&self, seen: u64, timeout: Option<Duration>) -> u64 {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let state = match timeout {
            Some(timeout) => {
                self.changed
                    .wait_timeout_while(state, timeout, |state| state.generation == seen)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0
            }
            None => self
                .changed
                .wait_while(state, |state| state.generation == seen)
                .unwrap_or_else(PoisonError::into_inner),
        };
        state.generation
    }
}
