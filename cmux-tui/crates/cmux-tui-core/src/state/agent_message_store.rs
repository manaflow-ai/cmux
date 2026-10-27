//! Agent messages (plans/feat-agent-rooms/DESIGN.md): an immutable envelope
//! and one delivery receipt per recipient. Rows live in the session
//! registry, so a message outlives the daemon that accepted it; delivery
//! paths (acpmux prompts, agent hooks) move the receipts forward.
//!
//! The tables (agent_message_schema.rs) are additive and carry no foreign
//! keys: an older binary that opens the registry ignores them. Who may send
//! what, and where a delivery starts, is agent_message_policy.rs; held
//! deliveries are released or expire in agent_message_release.rs.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::agent_message_policy::{
    self as policy, CrossWorkspace, Start, check_limits, invalid, refused,
};
use super::agent_message_release::{expire_held, hold_deadline};
use super::agent_message_schema::DELIVERY_STATES;

/// Bytes of UTF-8 one body may hold.
pub(crate) const MAX_BODY_BYTES: usize = 32 * 1024;
/// Distinct recipients of one message.
pub(crate) const MAX_RECIPIENTS: usize = 64;
/// Characters of a sender's display name.
pub(crate) const MAX_SENDER_NAME_CHARS: usize = 64;
/// Messages kept once every receipt has left `queued` and `held`. Messages
/// with a queued or held receipt are never pruned.
const KEEP_SETTLED_MESSAGES: i64 = 2000;
/// The sender of a message the person sends: a request with no verified
/// agent identity (no terminal or ACP session launch credential).
pub(crate) const CLI_SENDER: &str = "cli";

fn bad_request(message: impl Into<String>) -> anyhow::Error {
    anyhow::anyhow!("bad request: {}", message.into())
}

pub(crate) fn not_found(id: &str) -> anyhow::Error {
    anyhow::Error::new(crate::resource::ResourceError::new(
        "resource.not_found",
        format!("no agent message {id:?}"),
        json!({"scope": "agent", "id": id}),
        false,
    ))
}

/// A message as `agent.message.send` received it.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub(crate) struct NewAgentMessage {
    /// The sender the caller wrote, if any. The sender is the verified
    /// actor; a claim that names anyone else is refused.
    pub(crate) sender: Option<String>,
    pub(crate) sender_name: Option<String>,
    /// Empty for a reply that goes to its parent's sender.
    pub(crate) recipients: Vec<String>,
    pub(crate) body: String,
    pub(crate) thread_id: Option<String>,
    pub(crate) in_reply_to: Option<String>,
}

/// Filters of `agent.message.list`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct AgentMessageFilter {
    pub(crate) recipient: Option<String>,
    pub(crate) sender: Option<String>,
    pub(crate) thread_id: Option<String>,
    pub(crate) state: Option<String>,
    /// The oldest messages first instead of the newest.
    pub(crate) oldest_first: bool,
}

/// Whether `value` names a recipient: a terminal agent (`term_<32 hex>`) or
/// an acpmux session (`acp:<session id>`).
pub(crate) fn is_recipient_address(value: &str) -> bool {
    if let Some(hex) = value.strip_prefix("term_") {
        return hex.len() == 32
            && hex.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
    }
    if let Some(session) = value.strip_prefix("acp:") {
        return !session.is_empty()
            && value.len() <= 256
            && session.chars().all(|ch| !ch.is_whitespace() && !ch.is_control());
    }
    false
}

/// What `send` knows about the request beyond its fields.
pub(crate) struct SendContext<'a> {
    /// The verified sender's address; `None` for the person.
    pub(crate) agent: Option<&'a str>,
    /// Whether a `term_` recipient is a terminal of this session.
    pub(crate) terminal_exists: &'a dyn Fn(&str) -> anyhow::Result<bool>,
    /// The public id of the workspace an address runs in, when known.
    pub(crate) workspace_of: &'a dyn Fn(&str) -> Option<String>,
    pub(crate) rule: CrossWorkspace,
}

/// Text only: newlines and tabs are the only control characters, so no
/// delivery path can carry a terminal escape sequence.
fn validate_body(body: &str) -> anyhow::Result<()> {
    if body.trim().is_empty() {
        return Err(bad_request("the message is empty"));
    }
    if body.len() > MAX_BODY_BYTES {
        return Err(invalid(
            "body",
            "body_too_large",
            format!("the message exceeds {MAX_BODY_BYTES} bytes"),
        ));
    }
    if body.chars().any(|ch| ch.is_control() && ch != '\n' && ch != '\t') {
        return Err(bad_request(
            "the message contains a control character; only newlines and tabs are allowed",
        ));
    }
    Ok(())
}

fn validate_sender_name(name: &str) -> anyhow::Result<()> {
    if name.trim().is_empty()
        || name.chars().count() > MAX_SENDER_NAME_CHARS
        || name.chars().any(char::is_control)
    {
        return Err(bad_request(format!(
            "the sender name must be one line of at most {MAX_SENDER_NAME_CHARS} characters"
        )));
    }
    Ok(())
}

fn validate_message_id(label: &str, id: &str) -> anyhow::Result<()> {
    if id.is_empty() || id.len() > 128 || id.chars().any(|ch| ch.is_whitespace() || ch.is_control())
    {
        return Err(bad_request(format!("{label} must be 1 to 128 characters without spaces")));
    }
    Ok(())
}

/// A fresh `msg_<32 hex>` id.
pub(crate) fn new_message_id() -> anyhow::Result<String> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| anyhow::anyhow!("random message id: {error}"))?;
    let mut id = String::with_capacity(36);
    id.push_str("msg_");
    for byte in bytes {
        id.push_str(&format!("{byte:02x}"));
    }
    Ok(id)
}

/// Store one message with one receipt per recipient, each started by the
/// workspace rule, and return its snapshot. Nothing is stored when the
/// sender claim, a limit or the workspace rule refuses the message.
pub(crate) fn send(
    transaction: &Transaction<'_>,
    session_id: &str,
    message_id: &str,
    message: &NewAgentMessage,
    context: &SendContext<'_>,
    now_ms: i64,
) -> anyhow::Result<Value> {
    let sender = context.agent.unwrap_or(CLI_SENDER);
    validate(message, sender)?;
    expire_held(transaction, now_ms)?;
    let parent = match &message.in_reply_to {
        Some(parent_id) => {
            Some(load_envelope(transaction, parent_id)?.ok_or_else(|| not_found(parent_id))?)
        }
        None => None,
    };
    let recipients = recipients_of(message, parent.as_ref())?;
    for recipient in &recipients {
        if !is_recipient_address(recipient) {
            return Err(bad_request(format!(
                "{recipient:?} is not a recipient; use a terminal id (term_...) or acp:<session id>"
            )));
        }
        if recipient.starts_with("term_") && !(context.terminal_exists)(recipient)? {
            return Err(anyhow::Error::new(crate::resource::ResourceError::new(
                "resource.not_found",
                format!("no terminal {recipient:?} in this session"),
                json!({"scope": "terminal", "id": recipient}),
                false,
            )));
        }
    }
    let (thread_id, references, kind) = match &parent {
        // A reply always joins its parent's thread; a thread_id that names
        // another thread would detach it from the conversation it answers.
        Some(parent) => {
            if message.thread_id.as_ref().is_some_and(|thread| *thread != parent.thread_id) {
                return Err(bad_request(format!(
                    "a reply to {} belongs to thread {}",
                    parent.id, parent.thread_id
                )));
            }
            let mut references = parent.references.clone();
            references.push(parent.id.clone());
            (parent.thread_id.clone(), references, "reply")
        }
        None => (
            message.thread_id.clone().unwrap_or_else(|| message_id.to_owned()),
            Vec::new(),
            "message",
        ),
    };
    if context.agent.is_some() {
        policy::check_thread_member(transaction, sender, &thread_id)?;
    }
    check_limits(
        transaction,
        &policy::Send {
            sender,
            recipients: &recipients,
            body: &message.body,
            thread_id: &thread_id,
            depth: references.len(),
            now_ms,
        },
    )?;
    let starts = starts(context, &recipients)?;
    let sequence: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sequence) + 1, 1) FROM agent_messages",
        [],
        |row| row.get(0),
    )?;
    transaction.execute(
        "INSERT INTO agent_messages(
           message_id, sequence, thread_id, kind, sender, sender_name, body,
           created_at_ms, in_reply_to, references_json
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            message_id,
            sequence,
            thread_id,
            kind,
            sender,
            message.sender_name,
            message.body,
            now_ms,
            message.in_reply_to,
            serde_json::to_string(&references)?,
        ],
    )?;
    policy::count_in_thread(transaction, &thread_id, now_ms)?;
    for (position, (recipient, start)) in recipients.iter().zip(starts).enumerate() {
        let (state, queued_at, held_until, reason) = match start {
            Start::Queued => ("queued", Some(now_ms), None, None),
            Start::Held(reason) => ("held", None, Some(hold_deadline(now_ms)), Some(reason)),
        };
        transaction.execute(
            "INSERT INTO agent_message_deliveries(
               message_id, recipient, position, state, attempts, updated_at_ms,
               created_at_ms, queued_at_ms, held_until_ms, reason
             ) VALUES(?1, ?2, ?3, ?4, 0, ?5, ?5, ?6, ?7, ?8)",
            params![
                message_id,
                recipient,
                i64::try_from(position)?,
                state,
                now_ms,
                queued_at,
                held_until,
                reason
            ],
        )?;
    }
    prune_settled(transaction)?;
    snapshot(transaction, session_id, message_id, now_ms)?.ok_or_else(|| not_found(message_id))
}

/// Every check of a send that needs no parent, terminal or workspace: the
/// sender claim and the fields' format. `sender` is the verified sender.
fn validate(message: &NewAgentMessage, sender: &str) -> anyhow::Result<()> {
    if let Some(claimed) = &message.sender
        && claimed != sender
    {
        return Err(invalid(
            "sender",
            "sender_mismatch",
            format!("this request is sent by {sender}; it cannot claim to be {claimed}"),
        ));
    }
    validate_body(&message.body)?;
    if let Some(name) = &message.sender_name {
        validate_sender_name(name)?;
    }
    if let Some(thread) = &message.thread_id {
        validate_message_id("thread_id", thread)?;
    }
    if let Some(parent) = &message.in_reply_to {
        validate_message_id("in_reply_to", parent)?;
    }
    if message.recipients.len() > MAX_RECIPIENTS {
        return Err(bad_request(format!(
            "the message has {} recipients; the limit is {MAX_RECIPIENTS}",
            message.recipients.len()
        )));
    }
    if let Some(recipient) = message.recipients.iter().find(|r| !is_recipient_address(r)) {
        return Err(bad_request(format!(
            "{recipient:?} is not a recipient; use a terminal id (term_...) or acp:<session id>"
        )));
    }
    Ok(())
}

/// The checks a send passes before the daemon asks acpmux for workspaces:
/// [`validate`], then the burst limit and each named recipient's limits,
/// read-only. `send` checks them all again under the commit's lock. A
/// retry of a stored send (`idempotency_key` in the ledger) skips them, so
/// the commit returns the first result.
pub(crate) fn precheck(
    connection: &Connection,
    idempotency_key: &str,
    message: &NewAgentMessage,
    agent: Option<&str>,
    now_ms: i64,
) -> anyhow::Result<()> {
    let replay: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM resource_mutations WHERE idempotency_key = ?1)",
        [idempotency_key],
        |row| row.get(0),
    )?;
    if replay {
        return Ok(());
    }
    let sender = agent.unwrap_or(CLI_SENDER);
    validate(message, sender)?;
    let mut recipients: Vec<String> = Vec::new();
    for recipient in &message.recipients {
        if !recipients.contains(recipient) {
            recipients.push(recipient.clone());
        }
    }
    policy::check_traffic(connection, sender, &recipients, &message.body, now_ms)
}

/// The distinct recipients of `message`: its own, else its parent's sender.
fn recipients_of(
    message: &NewAgentMessage,
    parent: Option<&Envelope>,
) -> anyhow::Result<Vec<String>> {
    let mut recipients: Vec<String> = Vec::new();
    for recipient in &message.recipients {
        if !recipients.contains(recipient) {
            recipients.push(recipient.clone());
        }
    }
    if recipients.is_empty() {
        let Some(parent) = parent else {
            return Err(bad_request("give at least one recipient, or a message to reply to"));
        };
        if !is_recipient_address(&parent.sender) {
            return Err(bad_request(format!(
                "message {} was sent from {}, which has no address to reply to",
                parent.id, parent.sender
            )));
        }
        recipients.push(parent.sender.clone());
    }
    if recipients.len() > MAX_RECIPIENTS {
        return Err(bad_request(format!(
            "the message has {} recipients; the limit is {MAX_RECIPIENTS}",
            recipients.len()
        )));
    }
    Ok(recipients)
}

/// Where each recipient's delivery starts; a refusal names the recipients
/// the cross-workspace rule refuses.
fn starts(context: &SendContext<'_>, recipients: &[String]) -> anyhow::Result<Vec<Start>> {
    let sender_workspace = context.agent.map(|agent| (context.workspace_of)(agent));
    let mut starts = Vec::with_capacity(recipients.len());
    let mut refused_recipients = Vec::new();
    for recipient in recipients {
        let workspace = (context.workspace_of)(recipient);
        match policy::start(
            sender_workspace.as_ref().map(Option::as_deref),
            workspace.as_deref(),
            context.rule,
        ) {
            Ok(start) => starts.push(start),
            Err(_) => refused_recipients.push(recipient.clone()),
        }
    }
    if !refused_recipients.is_empty() {
        return Err(refused(
            "cross_workspace",
            format!(
                "{} runs in another workspace, and this daemon refuses messages across workspaces",
                refused_recipients.join(", ")
            ),
            json!({"recipients": refused_recipients}),
        ));
    }
    Ok(starts)
}

/// Whether a receipt may move from `from` to `to`. Receipts move forward:
/// queued, delivered, acknowledged. A queued or failed delivery may fail
/// (again) or be delivered, a delivery path that claimed a message before
/// handing it over may record that the hand-over failed, and a person may
/// acknowledge a message that was never delivered. A held delivery moves
/// only by `agent.message.release`; the policy states (`declined`,
/// `unsent`, `retracted`) are final.
fn transition_allowed(from: &str, to: &str) -> bool {
    matches!(
        (from, to),
        ("queued", "delivered" | "acknowledged" | "failed")
            | ("failed", "delivered" | "acknowledged" | "failed")
            | ("delivered", "acknowledged" | "failed")
    )
}

/// Move `recipient`'s receipt of each message to `state`. A receipt that
/// already has that state is left as it is (a failure with a new error is
/// recorded as another attempt).
#[allow(clippy::too_many_arguments)]
pub(crate) fn mark(
    transaction: &Transaction<'_>,
    session_id: &str,
    ids: &[String],
    recipient: &str,
    state: &str,
    via: Option<&str>,
    error: Option<&str>,
    now_ms: i64,
) -> anyhow::Result<Vec<Value>> {
    if !matches!(state, "delivered" | "acknowledged" | "failed") {
        return Err(bad_request("state must be delivered, acknowledged or failed"));
    }
    if error.is_some() && state != "failed" {
        return Err(bad_request("an error is recorded only for a failed delivery"));
    }
    let now = now_ms;
    expire_held(transaction, now)?;
    let mut values = Vec::with_capacity(ids.len());
    let mut seen: Vec<&str> = Vec::new();
    for id in ids {
        if seen.contains(&id.as_str()) {
            continue;
        }
        seen.push(id);
        let current: Option<String> = transaction
            .query_row(
                "SELECT state FROM agent_message_deliveries
                 WHERE message_id = ?1 AND recipient = ?2",
                params![id, recipient],
                |row| row.get(0),
            )
            .optional()?;
        let Some(current) = current else {
            return Err(not_found(id));
        };
        let repeat_failure = current == "failed" && state == "failed";
        if current == state && !repeat_failure {
            // Same state: nothing changes.
        } else if transition_allowed(&current, state) {
            let attempt = i64::from(matches!(state, "delivered" | "failed"));
            transaction.execute(
                "UPDATE agent_message_deliveries
                 SET state = ?3, attempts = attempts + ?4, updated_at_ms = ?5,
                     via = COALESCE(?6, via), error = ?7,
                     delivered_at_ms = CASE WHEN ?3 = 'delivered' THEN ?5
                                            ELSE delivered_at_ms END,
                     acknowledged_at_ms = CASE WHEN ?3 = 'acknowledged' THEN ?5
                                               ELSE acknowledged_at_ms END
                 WHERE message_id = ?1 AND recipient = ?2",
                params![id, recipient, state, attempt, now, via, error],
            )?;
        } else {
            return Err(bad_request(format!(
                "message {id} is {current} for {recipient}; it cannot become {state}"
            )));
        }
        values.push(snapshot(transaction, session_id, id, now)?.ok_or_else(|| not_found(id))?);
    }
    Ok(values)
}

/// Counts a hand-over acpmux never accepted on `recipient`'s still-queued
/// receipt of `id`, with why (the delivery pump's attempt record).
pub(crate) fn note_queued_attempt(
    transaction: &Transaction<'_>,
    id: &str,
    recipient: &str,
    error: &str,
    now_ms: i64,
) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE agent_message_deliveries
         SET attempts = attempts + 1, error = ?3, updated_at_ms = ?4,
             via = 'acp.prompt'
         WHERE message_id = ?1 AND recipient = ?2 AND state = 'queued'",
        params![id, recipient, error, now_ms],
    )?;
    Ok(())
}

/// Up to `page` queued acpmux deliveries after `cursor` (a message's
/// sequence and the delivery's position), oldest first:
/// `(sequence, position, message id, recipient)`.
pub(crate) fn queued_acp(
    connection: &Connection,
    cursor: (i64, i64),
    page: usize,
) -> anyhow::Result<Vec<(i64, i64, String, String)>> {
    let mut statement = connection.prepare(
        "SELECT m.sequence, d.position, m.message_id, d.recipient
         FROM agent_message_deliveries AS d
         JOIN agent_messages AS m ON m.message_id = d.message_id
         WHERE d.state = 'queued' AND d.recipient LIKE 'acp:%'
           AND (m.sequence > ?1 OR (m.sequence = ?1 AND d.position > ?2))
         ORDER BY m.sequence, d.position
         LIMIT ?3",
    )?;
    let rows = statement
        .query_map(params![cursor.0, cursor.1, i64::try_from(page)?], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Newest messages first, or oldest first with [`AgentMessageFilter::oldest_first`].
pub(crate) fn list(
    connection: &Connection,
    session_id: &str,
    filter: &AgentMessageFilter,
    limit: usize,
    now_ms: i64,
) -> anyhow::Result<Vec<Value>> {
    if let Some(state) = &filter.state
        && !DELIVERY_STATES.contains(&state.as_str())
    {
        return Err(bad_request(format!("state must be one of {}", DELIVERY_STATES.join(", "))));
    }
    let order = if filter.oldest_first { "ASC" } else { "DESC" };
    let mut statement = connection.prepare(&format!(
        "SELECT m.message_id FROM agent_messages AS m
         WHERE (?1 IS NULL OR m.sender = ?1)
           AND (?2 IS NULL OR m.thread_id = ?2)
           AND (
             (?3 IS NULL AND ?4 IS NULL)
             OR EXISTS(
               SELECT 1 FROM agent_message_deliveries AS d
               WHERE d.message_id = m.message_id
                 AND (?3 IS NULL OR d.recipient = ?3)
                 AND (?4 IS NULL OR {EFFECTIVE_STATE} = ?4)
             )
           )
         ORDER BY m.sequence {order}
         LIMIT ?5"
    ))?;
    let ids = statement
        .query_map(
            params![
                filter.sender,
                filter.thread_id,
                filter.recipient,
                filter.state,
                i64::try_from(limit)?,
                now_ms
            ],
            |row| row.get::<_, String>(0),
        )?
        .collect::<Result<Vec<_>, _>>()?;
    let mut values = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(value) = snapshot(connection, session_id, &id, now_ms)? {
            values.push(value);
        }
    }
    Ok(values)
}

/// The sender of message `id`, if it is stored.
pub(crate) fn sender_of(connection: &Connection, id: &str) -> anyhow::Result<Option<String>> {
    Ok(load_envelope(connection, id)?.map(|envelope| envelope.sender))
}

struct Envelope {
    id: String,
    thread_id: String,
    sender: String,
    references: Vec<String>,
}

fn load_envelope(connection: &Connection, id: &str) -> anyhow::Result<Option<Envelope>> {
    connection
        .query_row(
            "SELECT message_id, thread_id, sender, references_json FROM agent_messages
             WHERE message_id = ?1",
            [id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            },
        )
        .optional()?
        .map(|(id, thread_id, sender, references)| {
            Ok(Envelope { id, thread_id, sender, references: serde_json::from_str(&references)? })
        })
        .transpose()
}

/// A delivery's state as of `?6` in [`list`]: a held delivery whose wait is
/// over reads as declined before a mutation stores it.
const EFFECTIVE_STATE: &str = "(CASE WHEN d.state = 'held' AND COALESCE(d.held_until_ms, 0) <= ?6
     THEN 'declined' ELSE d.state END)";

fn optional_decimal(value: Option<i64>) -> Value {
    value.map_or(Value::Null, |value| Value::String(value.to_string()))
}

/// The public `AgentMessageSnapshot` of one message as of `now_ms`.
pub(crate) fn snapshot(
    connection: &Connection,
    session_id: &str,
    id: &str,
    now_ms: i64,
) -> anyhow::Result<Option<Value>> {
    let row = connection
        .query_row(
            "SELECT message_id, thread_id, kind, sender, sender_name, body, created_at_ms,
                    in_reply_to, references_json
             FROM agent_messages WHERE message_id = ?1",
            [id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, String>(8)?,
                ))
            },
        )
        .optional()?;
    let Some((id, thread_id, kind, sender, sender_name, body, created, in_reply_to, references)) =
        row
    else {
        return Ok(None);
    };
    let expired = "d.state = 'held' AND COALESCE(d.held_until_ms, 0) <= ?2";
    let mut statement = connection.prepare(&format!(
        "SELECT d.recipient, CASE WHEN {expired} THEN 'declined' ELSE d.state END,
                d.attempts, d.updated_at_ms, d.via, d.error,
                CASE WHEN {expired} THEN 'expired' ELSE d.reason END,
                d.created_at_ms, d.queued_at_ms, d.delivered_at_ms, d.acknowledged_at_ms,
                CASE WHEN {expired} THEN NULL ELSE d.held_until_ms END
         FROM agent_message_deliveries AS d WHERE d.message_id = ?1 ORDER BY d.position"
    ))?;
    let deliveries = statement
        .query_map(params![&id, now_ms], |row| {
            Ok(json!({
                "recipient": row.get::<_, String>(0)?,
                "state": row.get::<_, String>(1)?,
                "attempts": row.get::<_, i64>(2)?.to_string(),
                "updated_at_ms": row.get::<_, i64>(3)?.to_string(),
                "via": row.get::<_, Option<String>>(4)?,
                "error": row.get::<_, Option<String>>(5)?,
                "reason": row.get::<_, Option<String>>(6)?,
                "created_at_ms": row.get::<_, i64>(7)?.to_string(),
                "queued_at_ms": optional_decimal(row.get(8)?),
                "delivered_at_ms": optional_decimal(row.get(9)?),
                "acknowledged_at_ms": optional_decimal(row.get(10)?),
                "held_until_ms": optional_decimal(row.get(11)?),
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let recipients: Vec<Value> =
        deliveries.iter().map(|delivery| delivery["recipient"].clone()).collect();
    let references: Vec<String> = serde_json::from_str(&references)?;
    Ok(Some(json!({
        "id": id,
        "session_id": session_id,
        "thread_id": thread_id,
        "kind": kind,
        "sender": sender,
        "sender_name": sender_name,
        "recipients": recipients,
        "body": body,
        "created_at_ms": created.to_string(),
        "in_reply_to": in_reply_to,
        "references": references,
        "deliveries": deliveries,
    })))
}

/// Drop messages older than the newest [`KEEP_SETTLED_MESSAGES`] once none
/// of their receipts is still queued or held.
fn prune_settled(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let cutoff: Option<i64> = transaction
        .query_row(
            "SELECT sequence FROM agent_messages ORDER BY sequence DESC LIMIT 1 OFFSET ?1",
            [KEEP_SETTLED_MESSAGES],
            |row| row.get(0),
        )
        .optional()?;
    let Some(cutoff) = cutoff else {
        return Ok(());
    };
    let settled = "SELECT m.message_id FROM agent_messages AS m
         WHERE m.sequence <= ?1
           AND NOT EXISTS(
             SELECT 1 FROM agent_message_deliveries AS d
             WHERE d.message_id = m.message_id AND d.state IN ('queued', 'held')
           )";
    transaction.execute(
        &format!("DELETE FROM agent_message_deliveries WHERE message_id IN ({settled})"),
        [cutoff],
    )?;
    transaction.execute(
        "DELETE FROM agent_messages
         WHERE sequence <= ?1
           AND NOT EXISTS(
             SELECT 1 FROM agent_message_deliveries AS d
             WHERE d.message_id = agent_messages.message_id
           )",
        [cutoff],
    )?;
    Ok(())
}
