//! Durable outbox for person-authorized question answers. Only the first claim may
//! send. Every replay, including after a crash, may query ACP's receipt only.
//! Callers authenticate the actor and verify the live person decision before a
//! new claim. Neither that proof nor any key is accepted by this persistence API.

use super::*;
use cmux_conversation::{Part, Question};

pub(super) const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS question_delivery (
  id TEXT PRIMARY KEY NOT NULL,
  conversation TEXT NOT NULL,
  actor TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  message TEXT NOT NULL,
  intent_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending', 'delivered', 'refused')),
  result_json TEXT,
  refusal TEXT,
  UNIQUE(conversation, actor, idempotency_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS question_delivery_pending_message
  ON question_delivery(message) WHERE state = 'pending';
";

/// Exact non-secret identity that an ACP receipt must match. Digests refer to
/// the immutable request and encoded answers, not a fresh read after restart.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
// skew: strict local delivery record: an ignored field would let a receipt match a different request
#[serde(deny_unknown_fields)]
pub(crate) struct DeliveryBinding {
    pub session_id: String,
    pub permission_id: String,
    pub instance: String,
    pub decision_nonce: String,
    pub request_digest: String,
    pub option_id: String,
    pub answers_digest: String,
    /// Native Home may have already sent through its person-proven ACP line.
    /// Such an intent queries this receipt and never authorizes another send.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
// skew: strict local delivery record written and read by the same daemon's store
#[serde(deny_unknown_fields)]
pub(crate) struct DeliveryIntent {
    pub id: String,
    pub conversation: String,
    pub actor: String,
    pub idempotency_key: String,
    pub binding: DeliveryBinding,
    pub question: Question,
    pub op: Op,
    pub fingerprint: String,
}

#[derive(Debug)]
pub(crate) enum DeliveryClaim {
    Send(DeliveryIntent),
    Reconcile(DeliveryIntent),
    Finished(OpOutcome),
    Refused(String),
}

/// Only a matching, definitive ACP receipt may finish an intent. A timeout,
/// absent receipt or closed pending prompt is not a definitive result.
#[derive(Debug, Clone)]
pub(crate) enum DeliveryResult {
    Delivered,
    Refused(String),
}

#[derive(Debug)]
pub(crate) enum DeliveryCompletion {
    Answered(OpOutcome),
    Refused(String),
}

struct StoredDelivery {
    intent: DeliveryIntent,
    state: String,
    result: Option<OpResult>,
    refusal: Option<String>,
}

impl StoredDelivery {
    fn into_claim(self) -> anyhow::Result<DeliveryClaim> {
        Ok(match self.state.as_str() {
            "pending" => DeliveryClaim::Reconcile(self.intent),
            "delivered" => DeliveryClaim::Finished(OpOutcome {
                result: self.result.context("delivery result missing")?,
                replayed: true,
            }),
            "refused" => DeliveryClaim::Refused(self.refusal.context("refusal missing")?),
            _ => anyhow::bail!("invalid delivery state"),
        })
    }
}

fn load(connection: &Connection, id: &str) -> anyhow::Result<Option<StoredDelivery>> {
    let row: Option<(String, String, Option<String>, Option<String>)> = connection
        .query_row(
            "SELECT intent_json, state, result_json, refusal FROM question_delivery WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    row.map(|(intent, state, result, refusal)| {
        Ok(StoredDelivery {
            intent: serde_json::from_str(&intent)?,
            state,
            result: result.map(|s| serde_json::from_str(&s)).transpose()?,
            refusal,
        })
    })
    .transpose()
}

pub(super) fn message_pending(connection: &Connection, message: &str) -> anyhow::Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM question_delivery WHERE message = ?1 AND state = 'pending')",
        [message],
        |row| row.get(0),
    )?)
}

/// Recheck under the writer transaction too: another store connection may have
/// claimed between a caller's early check and taking SQLite's writer lock.
pub(super) fn check_pending(connection: &Connection, op: &Op) -> anyhow::Result<()> {
    let Some(message) = op.target_message_id() else { return Ok(()) };
    if message_pending(connection, message)? {
        return Err(QuestionDeliveryBusy.into());
    }
    Ok(())
}

/// NORMAL is sufficient for ordinary batched writes, but the intent must reach
/// stable storage before permission_respond can run. FULL is connection-local
/// and scoped to this transaction; restore the store's previous setting on both
/// success and failure. A restoration failure never grants permission to send.
fn durable<T>(
    connection: &mut Connection,
    operation: impl FnOnce(&Transaction<'_>) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let previous: i64 = connection.pragma_query_value(None, "synchronous", |row| row.get(0))?;
    connection.pragma_update(None, "synchronous", "FULL")?;
    let result: anyhow::Result<T> = (|| {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let value = operation(&transaction)?;
        transaction.commit()?;
        Ok(value)
    })();
    let restored = connection.pragma_update(None, "synchronous", previous);
    match result {
        Ok(value) => {
            restored.context("restore conversation durability")?;
            Ok(value)
        }
        Err(error) => {
            // The original error determines whether the critical commit worked;
            // either way the caller gets no Send capability.
            restored.context("restore conversation durability after failed delivery write")?;
            Err(error)
        }
    }
}

impl ConversationStore {
    /// The record-only approval exception belongs to an actual stored Chief
    /// message, never an agent/name claimed by the question or request envelope.
    #[cfg(test)]
    pub(crate) fn question_author_is_chief(
        &self,
        conversation: &str,
        op: &Op,
    ) -> anyhow::Result<bool> {
        Ok(self.question_chief_author(conversation, op)?.is_some())
    }
    pub(crate) fn question_chief_author(
        &self,
        conversation: &str,
        op: &Op,
    ) -> anyhow::Result<Option<String>> {
        let Op::QuestionAnswer { message_id, part_index, .. } = op else { return Ok(None) };
        self.message_chief_author(conversation, message_id, *part_index as usize)
    }

    /// [`Self::question_chief_author`] for the stored message and question part itself, before
    /// any op exists (the decision read that Home signs for).
    pub(crate) fn message_chief_author(
        &self,
        conversation: &str,
        message_id: &str,
        part_index: usize,
    ) -> anyhow::Result<Option<String>> {
        let Some(message) = load_message_by_id(&self.connection, message_id)? else {
            return Ok(None);
        };
        if message.conversation != conversation
            || !matches!(message.parts.get(part_index), Some(Part::Question(_)))
        {
            return Ok(None);
        }
        let Some(head) = load_head(&self.connection, conversation)? else { return Ok(None) };
        Ok(head
            .participants
            .iter()
            .find(|participant| {
                participant.id == message.author
                    && participant.kind == cmux_conversation::ParticipantKind::Agent
                    && participant.agent_class == Some(cmux_conversation::AgentClass::Mux)
            })
            .map(|p| p.id.clone()))
    }

    /// Retry lookup precedes decoding a fresh person decision. The authenticated
    /// actor and unchanged op identify only a receipt query, never a new send.
    pub(crate) fn lookup_question_delivery(
        &self,
        conversation: &str,
        key: &str,
        actor: &str,
        op: &Op,
    ) -> anyhow::Result<Option<DeliveryClaim>> {
        validate_idempotency_key(key)?;
        let id = format!("qd_{}", fingerprint(&json!([conversation, actor, key]))?);
        let Some(stored) = load(&self.connection, &id)? else { return Ok(None) };
        if stored.intent.fingerprint != fingerprint(&json!({"actor": actor, "op": op}))? {
            return Err(rejected(Reject::IdempotencyConflict));
        }
        Ok(Some(stored.into_claim()?))
    }

    /// Called under the store mutex, released before any network operation.
    /// The stable id is scoped to the conversation, authenticated actor and key.
    pub(crate) fn claim_question_delivery(
        &mut self,
        conversation: &str,
        key: &str,
        actor: &str,
        op: &Op,
        binding: &DeliveryBinding,
    ) -> anyhow::Result<DeliveryClaim> {
        validate_idempotency_key(key)?;
        let Op::QuestionAnswer { message_id, part_index, .. } = op else {
            anyhow::bail!("not a question answer");
        };
        let id = format!("qd_{}", fingerprint(&json!([conversation, actor, key]))?);
        let op_fingerprint = fingerprint(&json!({"actor": actor, "op": op}))?;
        let memory_pending = self.question_deliveries.contains(message_id);
        durable(&mut self.connection, |transaction| {
            if let Some(stored) = load(transaction, &id)? {
                if stored.intent.fingerprint != op_fingerprint || stored.intent.binding != *binding
                {
                    return Err(rejected(Reject::IdempotencyConflict));
                }
                return stored.into_claim();
            }
            if memory_pending || message_pending(transaction, message_id)? {
                return Err(QuestionDeliveryBusy.into());
            }
            // Run exactly the normal reducer and ledger validation, then discard
            // its writes while retaining this transaction's SQLite writer lock.
            transaction.execute_batch("SAVEPOINT validate_question_delivery")?;
            let target = load_message_by_id(transaction, message_id)?;
            let preview = apply_op_in(transaction, conversation, key, actor, op)?;
            transaction.execute_batch(
                "ROLLBACK TO validate_question_delivery; RELEASE validate_question_delivery",
            )?;
            if preview.replayed {
                return Ok(DeliveryClaim::Finished(preview));
            }
            let Some(Part::Question(question)) =
                target.as_ref().and_then(|message| message.parts.get(*part_index as usize))
            else {
                return Err(rejected(Reject::InvalidPartIndex));
            };
            anyhow::ensure!(
                question.session.strip_prefix("local/").unwrap_or(&question.session)
                    == binding.session_id
                    && question.permission.as_deref() == Some(binding.permission_id.as_str()),
                "question.stale"
            );
            let intent = DeliveryIntent {
                id: id.clone(),
                conversation: conversation.into(),
                actor: actor.into(),
                idempotency_key: key.into(),
                binding: binding.clone(),
                question: question.clone(),
                op: op.clone(),
                fingerprint: op_fingerprint.clone(),
            };
            transaction.execute(
                "INSERT INTO question_delivery
                 (id, conversation, actor, idempotency_key, message, intent_json, state)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending')",
                params![id, conversation, actor, key, message_id, serde_json::to_string(&intent)?],
            )?;
            Ok(if binding.receipt_id.is_some() {
                DeliveryClaim::Reconcile(intent)
            } else {
                DeliveryClaim::Send(intent)
            })
        })
    }

    #[cfg(test)]
    pub(crate) fn pending_question_deliveries(&self) -> anyhow::Result<Vec<DeliveryIntent>> {
        let mut statement = self.connection.prepare(
            "SELECT intent_json FROM question_delivery WHERE state = 'pending' ORDER BY id",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .map(|row| Ok(serde_json::from_str(&row?)?))
            .collect()
    }

    /// Revalidates the exact binding before committing the answer and ledger in
    /// the same durable transaction that retires the active reservation. Any SQL
    /// failure rolls everything back; a later receipt query can reconcile it.
    pub(crate) fn finish_question_delivery(
        &mut self,
        id: &str,
        binding: &DeliveryBinding,
        result: DeliveryResult,
    ) -> anyhow::Result<DeliveryCompletion> {
        durable(&mut self.connection, |transaction| {
            let stored = load(transaction, id)?.context("unknown question delivery")?;
            anyhow::ensure!(stored.intent.binding == *binding, "question.receipt_mismatch");
            if stored.state == "delivered" {
                anyhow::ensure!(
                    matches!(result, DeliveryResult::Delivered),
                    "question.receipt_mismatch"
                );
                return Ok(DeliveryCompletion::Answered(OpOutcome {
                    result: stored.result.context("delivery result missing")?,
                    replayed: true,
                }));
            }
            if stored.state == "refused" {
                let reason = stored.refusal.context("refusal missing")?;
                anyhow::ensure!(
                    matches!(&result, DeliveryResult::Refused(other) if other == &reason),
                    "question.receipt_mismatch"
                );
                return Ok(DeliveryCompletion::Refused(reason));
            }
            let intent = &stored.intent;
            match result {
                DeliveryResult::Delivered => {
                    let Op::QuestionAnswer { message_id, part_index, .. } = &intent.op else {
                        anyhow::bail!("invalid delivery op");
                    };
                    let message = load_message_by_id(transaction, message_id)?;
                    anyhow::ensure!(
                        message.as_ref().and_then(|m| m.parts.get(*part_index as usize))
                            == Some(&Part::Question(intent.question.clone())),
                        "question.stale"
                    );
                    let outcome = apply_op_in(
                        transaction,
                        &intent.conversation,
                        &intent.idempotency_key,
                        &intent.actor,
                        &intent.op,
                    )?;
                    transaction.execute(
                        "UPDATE question_delivery SET state = 'delivered', result_json = ?2
                         WHERE id = ?1",
                        params![id, serde_json::to_string(&outcome.result)?],
                    )?;
                    Ok(DeliveryCompletion::Answered(outcome))
                }
                DeliveryResult::Refused(reason) => {
                    anyhow::ensure!(!reason.is_empty(), "empty delivery refusal");
                    transaction.execute(
                        "UPDATE question_delivery SET state = 'refused', refusal = ?2 WHERE id = ?1",
                        params![id, reason],
                    )?;
                    Ok(DeliveryCompletion::Refused(reason))
                }
            }
        })
    }
}

#[cfg(test)]
#[path = "conversation_deliveries_tests.rs"]
mod tests;
