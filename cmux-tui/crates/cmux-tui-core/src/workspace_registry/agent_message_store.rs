//! Agent messages (plans/feat-agent-rooms/DESIGN.md): an immutable envelope
//! and one delivery receipt per recipient. Rows live in the session
//! registry, so a message outlives the daemon that accepted it; delivery
//! paths (acpmux prompts, agent hooks) move the receipts forward.
//!
//! The tables are additive and carry no foreign keys: an older binary that
//! opens the registry ignores them.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

/// Bytes of UTF-8 one body may hold.
pub(crate) const MAX_BODY_BYTES: usize = 32 * 1024;
/// Distinct recipients of one message.
pub(crate) const MAX_RECIPIENTS: usize = 64;
/// Characters of a sender's display name.
pub(crate) const MAX_SENDER_NAME_CHARS: usize = 64;
/// Messages kept once every receipt has left `queued`. Messages with a
/// queued receipt are never pruned.
const KEEP_SETTLED_MESSAGES: i64 = 2000;
/// The sender of a message sent from a shell that is neither an agent's
/// terminal nor an acpmux session.
pub(crate) const CLI_SENDER: &str = "cli";

/// Why a send fails, and queued receipts fail, while
/// `agents.messages.enabled` is false.
pub(crate) const TURNED_OFF: &str =
    "agent messages are turned off (agents.messages.enabled is false)";

const STATES: [&str; 4] = ["queued", "delivered", "acknowledged", "failed"];

pub(super) fn create_agent_message_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS agent_messages (
           message_id TEXT PRIMARY KEY NOT NULL,
           sequence INTEGER NOT NULL UNIQUE,
           thread_id TEXT NOT NULL,
           kind TEXT NOT NULL CHECK(kind IN ('message','reply')),
           sender TEXT NOT NULL,
           sender_name TEXT,
           body TEXT NOT NULL,
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
           in_reply_to TEXT,
           references_json TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS agent_messages_thread
           ON agent_messages(thread_id, sequence);
         CREATE TABLE IF NOT EXISTS agent_message_deliveries (
           message_id TEXT NOT NULL,
           recipient TEXT NOT NULL,
           position INTEGER NOT NULL CHECK(position >= 0),
           state TEXT NOT NULL
             CHECK(state IN ('queued','delivered','acknowledged','failed')),
           attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           via TEXT,
           error TEXT,
           PRIMARY KEY(message_id, recipient)
         );
         CREATE INDEX IF NOT EXISTS agent_message_deliveries_recipient
           ON agent_message_deliveries(recipient, state);
         CREATE TABLE IF NOT EXISTS agent_message_optouts (
           recipient TEXT PRIMARY KEY NOT NULL,
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
         );",
    )?;
    Ok(())
}

fn bad_request(message: impl Into<String>) -> anyhow::Error {
    anyhow::anyhow!("bad request: {}", message.into())
}

fn not_found(id: &str) -> anyhow::Error {
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
    pub(crate) sender: String,
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

/// A sender is a recipient address or [`CLI_SENDER`].
pub(crate) fn is_sender_address(value: &str) -> bool {
    value == CLI_SENDER || is_recipient_address(value)
}

/// Text only: newlines and tabs are the only control characters, so no
/// delivery path can carry a terminal escape sequence.
fn validate_body(body: &str) -> anyhow::Result<()> {
    if body.trim().is_empty() {
        return Err(bad_request("the message is empty"));
    }
    if body.len() > MAX_BODY_BYTES {
        return Err(bad_request(format!("the message exceeds {MAX_BODY_BYTES} bytes")));
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

/// Store one message with a queued receipt per recipient and return its
/// snapshot. `terminal_exists` answers whether a `term_` recipient is a
/// terminal of this session.
pub(crate) fn send(
    transaction: &Transaction<'_>,
    session_id: &str,
    message_id: &str,
    message: &NewAgentMessage,
    terminal_exists: &dyn Fn(&str) -> anyhow::Result<bool>,
    now_ms: u64,
) -> anyhow::Result<Value> {
    validate_body(&message.body)?;
    if !is_sender_address(&message.sender) {
        return Err(bad_request(format!("{:?} is not a sender address", message.sender)));
    }
    if let Some(name) = &message.sender_name {
        validate_sender_name(name)?;
    }
    if let Some(thread) = &message.thread_id {
        validate_message_id("thread_id", thread)?;
    }
    let parent = match &message.in_reply_to {
        Some(parent_id) => {
            validate_message_id("in_reply_to", parent_id)?;
            Some(load_envelope(transaction, parent_id)?.ok_or_else(|| not_found(parent_id))?)
        }
        None => None,
    };
    let mut recipients: Vec<String> = Vec::new();
    for recipient in &message.recipients {
        if !recipients.contains(recipient) {
            recipients.push(recipient.clone());
        }
    }
    if recipients.is_empty() {
        let Some(parent) = &parent else {
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
    for recipient in &recipients {
        if !is_recipient_address(recipient) {
            return Err(bad_request(format!(
                "{recipient:?} is not a recipient; use a terminal id (term_...) or acp:<session id>"
            )));
        }
        if receiving_disabled(transaction, recipient)? {
            return Err(bad_request(format!("{recipient} has messages disabled")));
        }
        if recipient.starts_with("term_") && !terminal_exists(recipient)? {
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
    let sequence: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sequence) + 1, 1) FROM agent_messages",
        [],
        |row| row.get(0),
    )?;
    let now = i64::try_from(now_ms)?;
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
            message.sender,
            message.sender_name,
            message.body,
            now,
            message.in_reply_to,
            serde_json::to_string(&references)?,
        ],
    )?;
    for (position, recipient) in recipients.iter().enumerate() {
        transaction.execute(
            "INSERT INTO agent_message_deliveries(
               message_id, recipient, position, state, attempts, updated_at_ms
             ) VALUES(?1, ?2, ?3, 'queued', 0, ?4)",
            params![message_id, recipient, i64::try_from(position)?, now],
        )?;
    }
    prune_settled(transaction)?;
    snapshot(transaction, session_id, message_id)?.ok_or_else(|| not_found(message_id))
}

/// Whether `recipient` turned agent messages off for itself.
fn receiving_disabled(connection: &Connection, recipient: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row("SELECT 1 FROM agent_message_optouts WHERE recipient = ?1", [recipient], |_| {
            Ok(())
        })
        .optional()?
        .is_some())
}

/// Turn receiving on or off for one recipient. Turning it off fails the
/// recipient's queued receipts, so nothing waits for a delivery that will
/// not come. Opt-outs of terminals that no longer exist are dropped (a
/// terminal id is never reused), so the table stays as small as the live
/// terminals and acpmux sessions that opted out. Returns the
/// `AgentMessageReceivingChange` result.
pub(crate) fn set_receiving(
    transaction: &Transaction<'_>,
    recipient: &str,
    enabled: bool,
    terminal_exists: &dyn Fn(&str) -> anyhow::Result<bool>,
    now_ms: u64,
) -> anyhow::Result<Value> {
    if !is_recipient_address(recipient) {
        return Err(bad_request(format!(
            "{recipient:?} is not a recipient; use a terminal id (term_...) or acp:<session id>"
        )));
    }
    if !enabled && recipient.starts_with("term_") && !terminal_exists(recipient)? {
        return Err(anyhow::Error::new(crate::resource::ResourceError::new(
            "resource.not_found",
            format!("no terminal {recipient:?} in this session"),
            json!({"scope": "terminal", "id": recipient}),
            false,
        )));
    }
    let terminals = {
        let mut statement = transaction.prepare(
            "SELECT recipient FROM agent_message_optouts WHERE substr(recipient, 1, 5) = 'term_'",
        )?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    for terminal in terminals {
        if terminal != recipient && !terminal_exists(&terminal)? {
            transaction
                .execute("DELETE FROM agent_message_optouts WHERE recipient = ?1", [&terminal])?;
        }
    }
    let now = i64::try_from(now_ms)?;
    let failed = if enabled {
        transaction
            .execute("DELETE FROM agent_message_optouts WHERE recipient = ?1", [recipient])?;
        Vec::new()
    } else {
        transaction.execute(
            "INSERT INTO agent_message_optouts(recipient, updated_at_ms) VALUES(?1, ?2)
             ON CONFLICT(recipient) DO UPDATE SET updated_at_ms = excluded.updated_at_ms",
            params![recipient, now],
        )?;
        fail_queued(
            transaction,
            Some(recipient),
            &format!("{recipient} has messages disabled"),
            now_ms,
        )?
    };
    Ok(json!({"recipient": recipient, "enabled": enabled, "failed": failed}))
}

/// Fail every queued receipt, or `recipient`'s, with `error`. Returns the
/// ids of the messages whose receipt failed.
pub(crate) fn fail_queued(
    transaction: &Transaction<'_>,
    recipient: Option<&str>,
    error: &str,
    now_ms: u64,
) -> anyhow::Result<Vec<String>> {
    let mut statement = transaction.prepare(
        "SELECT DISTINCT message_id FROM agent_message_deliveries
         WHERE state = 'queued' AND (?1 IS NULL OR recipient = ?1)
         ORDER BY message_id",
    )?;
    let ids = statement
        .query_map([recipient], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    transaction.execute(
        "UPDATE agent_message_deliveries SET state = 'failed', updated_at_ms = ?2, error = ?3
         WHERE state = 'queued' AND (?1 IS NULL OR recipient = ?1)",
        params![recipient, i64::try_from(now_ms)?, error],
    )?;
    Ok(ids)
}

/// Recipients that turned agent messages off, oldest change first.
pub(crate) fn disabled_recipients(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    let mut statement = connection.prepare(
        "SELECT recipient, updated_at_ms FROM agent_message_optouts
         ORDER BY updated_at_ms, recipient",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(json!({
                "recipient": row.get::<_, String>(0)?,
                "updated_at_ms": row.get::<_, i64>(1)?.to_string(),
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Whether a receipt may move from `from` to `to`. Receipts move forward:
/// queued, delivered, acknowledged. A queued or failed delivery may fail
/// (again) or be delivered, a delivery path that claimed a message before
/// handing it over may record that the hand-over failed, and a person may
/// acknowledge a message that was never delivered.
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
    now_ms: u64,
) -> anyhow::Result<Vec<Value>> {
    if !matches!(state, "delivered" | "acknowledged" | "failed") {
        return Err(bad_request("state must be delivered, acknowledged or failed"));
    }
    if error.is_some() && state != "failed" {
        return Err(bad_request("an error is recorded only for a failed delivery"));
    }
    // A delivery path claims a message before it hands it over, so a
    // recipient that turned messages off after the message was listed
    // never gets it.
    if state == "delivered" && receiving_disabled(transaction, recipient)? {
        return Err(bad_request(format!("{recipient} has messages disabled")));
    }
    let now = i64::try_from(now_ms)?;
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
                     via = COALESCE(?6, via), error = ?7
                 WHERE message_id = ?1 AND recipient = ?2",
                params![id, recipient, state, attempt, now, via, error],
            )?;
        } else {
            return Err(bad_request(format!(
                "message {id} is {current} for {recipient}; it cannot become {state}"
            )));
        }
        values.push(snapshot(transaction, session_id, id)?.ok_or_else(|| not_found(id))?);
    }
    Ok(values)
}

/// Newest messages first, or oldest first with [`AgentMessageFilter::oldest_first`].
pub(crate) fn list(
    connection: &Connection,
    session_id: &str,
    filter: &AgentMessageFilter,
    limit: usize,
) -> anyhow::Result<Vec<Value>> {
    if let Some(state) = &filter.state
        && !STATES.contains(&state.as_str())
    {
        return Err(bad_request("state must be queued, delivered, acknowledged or failed"));
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
                 AND (?4 IS NULL OR d.state = ?4)
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
                i64::try_from(limit)?
            ],
            |row| row.get::<_, String>(0),
        )?
        .collect::<Result<Vec<_>, _>>()?;
    let mut values = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(value) = snapshot(connection, session_id, &id)? {
            values.push(value);
        }
    }
    Ok(values)
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

/// The public `AgentMessageSnapshot` of one message.
pub(crate) fn snapshot(
    connection: &Connection,
    session_id: &str,
    id: &str,
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
    let mut statement = connection.prepare(
        "SELECT recipient, state, attempts, updated_at_ms, via, error
         FROM agent_message_deliveries WHERE message_id = ?1 ORDER BY position",
    )?;
    let deliveries = statement
        .query_map([&id], |row| {
            Ok(json!({
                "recipient": row.get::<_, String>(0)?,
                "state": row.get::<_, String>(1)?,
                "attempts": row.get::<_, i64>(2)?.to_string(),
                "updated_at_ms": row.get::<_, i64>(3)?.to_string(),
                "via": row.get::<_, Option<String>>(4)?,
                "error": row.get::<_, Option<String>>(5)?,
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
/// of their receipts is still queued.
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
             WHERE d.message_id = m.message_id AND d.state = 'queued'
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

#[cfg(test)]
mod tests {
    use super::*;

    fn connection() -> Connection {
        let mut connection = Connection::open_in_memory().unwrap();
        let transaction = connection.transaction().unwrap();
        create_agent_message_schema(&transaction).unwrap();
        transaction.commit().unwrap();
        connection
    }

    const TERM_A: &str = "term_0123456789abcdef0123456789abcdef";
    const TERM_B: &str = "term_fedcba9876543210fedcba9876543210";

    fn message(sender: &str, recipients: &[&str], body: &str) -> NewAgentMessage {
        NewAgentMessage {
            sender: sender.into(),
            sender_name: None,
            recipients: recipients.iter().map(|value| (*value).to_owned()).collect(),
            body: body.into(),
            thread_id: None,
            in_reply_to: None,
        }
    }

    fn any_terminal(_: &str) -> anyhow::Result<bool> {
        Ok(true)
    }

    fn send_one(connection: &mut Connection, id: &str, message: &NewAgentMessage) -> Value {
        let transaction = connection.transaction().unwrap();
        let value = send(&transaction, "session_x", id, message, &any_terminal, 10).unwrap();
        transaction.commit().unwrap();
        value
    }

    fn send_err(connection: &mut Connection, message: &NewAgentMessage) -> String {
        let transaction = connection.transaction().unwrap();
        send(&transaction, "session_x", "msg_err", message, &any_terminal, 10)
            .unwrap_err()
            .to_string()
    }

    #[test]
    fn a_message_starts_queued_for_each_recipient() {
        let mut connection = connection();
        let value = send_one(
            &mut connection,
            "msg_1",
            &message(TERM_A, &[TERM_B, "acp:review", TERM_B], "please review"),
        );
        assert_eq!(value["thread_id"], "msg_1");
        assert_eq!(value["kind"], "message");
        assert_eq!(value["recipients"], json!([TERM_B, "acp:review"]));
        let states: Vec<&str> = value["deliveries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|delivery| delivery["state"].as_str().unwrap())
            .collect();
        assert_eq!(states, ["queued", "queued"]);
    }

    #[test]
    fn a_reply_joins_the_parent_thread_and_goes_to_its_sender() {
        let mut connection = connection();
        send_one(&mut connection, "msg_1", &message(TERM_A, &[TERM_B], "question"));
        let mut reply = message(TERM_B, &[], "answer");
        reply.in_reply_to = Some("msg_1".into());
        let value = send_one(&mut connection, "msg_2", &reply);
        assert_eq!(value["thread_id"], "msg_1");
        assert_eq!(value["kind"], "reply");
        assert_eq!(value["in_reply_to"], "msg_1");
        assert_eq!(value["references"], json!(["msg_1"]));
        assert_eq!(value["recipients"], json!([TERM_A]));
        let mut nested = message(TERM_A, &[], "thanks");
        nested.in_reply_to = Some("msg_2".into());
        let value = send_one(&mut connection, "msg_3", &nested);
        assert_eq!(value["thread_id"], "msg_1");
        assert_eq!(value["references"], json!(["msg_1", "msg_2"]));
    }

    #[test]
    fn a_reply_needs_a_known_parent_with_an_address() {
        let mut connection = connection();
        let mut orphan = message(TERM_A, &[], "hello");
        orphan.in_reply_to = Some("msg_missing".into());
        assert!(send_err(&mut connection, &orphan).contains("msg_missing"));
        send_one(&mut connection, "msg_1", &message(CLI_SENDER, &[TERM_B], "from a shell"));
        let mut reply = message(TERM_B, &[], "answer");
        reply.in_reply_to = Some("msg_1".into());
        assert!(send_err(&mut connection, &reply).contains("no address to reply to"));
        reply.thread_id = Some("other".into());
        reply.recipients = vec![TERM_A.into()];
        assert!(send_err(&mut connection, &reply).contains("belongs to thread"));
    }

    #[test]
    fn bodies_and_addresses_are_validated() {
        let mut connection = connection();
        assert!(send_err(&mut connection, &message(TERM_A, &[TERM_B], " \n ")).contains("empty"));
        assert!(
            send_err(&mut connection, &message(TERM_A, &[TERM_B], "a\u{1b}[31mred"))
                .contains("control character")
        );
        let long = "x".repeat(MAX_BODY_BYTES + 1);
        assert!(send_err(&mut connection, &message(TERM_A, &[TERM_B], &long)).contains("exceeds"));
        assert!(
            send_err(&mut connection, &message(TERM_A, &["workspace:1"], "hi"))
                .contains("not a recipient")
        );
        assert!(send_err(&mut connection, &message("bob", &[TERM_B], "hi")).contains("sender"));
        assert!(send_err(&mut connection, &message(TERM_A, &[], "hi")).contains("recipient"));
        let mut named = message(TERM_A, &[TERM_B], "hi");
        named.sender_name = Some("two\nlines".into());
        assert!(send_err(&mut connection, &named).contains("sender name"));
        // Tabs and newlines are text.
        send_one(&mut connection, "msg_ok", &message(TERM_A, &[TERM_B], "a\tb\nc"));
    }

    #[test]
    fn an_unknown_terminal_recipient_is_not_found() {
        let mut connection = connection();
        let transaction = connection.transaction().unwrap();
        let error = send(
            &transaction,
            "session_x",
            "msg_1",
            &message(CLI_SENDER, &[TERM_B], "hi"),
            &|_| Ok(false),
            10,
        )
        .unwrap_err();
        let error = error.downcast_ref::<crate::resource::ResourceError>().unwrap();
        assert_eq!(error.code, "resource.not_found");
    }

    fn mark_one(
        connection: &mut Connection,
        id: &str,
        recipient: &str,
        state: &str,
        error: Option<&str>,
    ) -> anyhow::Result<Vec<Value>> {
        let transaction = connection.transaction().unwrap();
        let values = mark(
            &transaction,
            "session_x",
            &[id.to_owned()],
            recipient,
            state,
            Some("test"),
            error,
            20,
        )?;
        transaction.commit().unwrap();
        Ok(values)
    }

    #[test]
    fn receipts_move_forward_independently() {
        let mut connection = connection();
        send_one(&mut connection, "msg_1", &message(TERM_A, &[TERM_B, "acp:s"], "hi"));
        let values = mark_one(&mut connection, "msg_1", TERM_B, "delivered", None).unwrap();
        let deliveries = &values[0]["deliveries"];
        assert_eq!(deliveries[0]["state"], "delivered");
        assert_eq!(deliveries[0]["attempts"], "1");
        assert_eq!(deliveries[0]["via"], "test");
        assert_eq!(deliveries[1]["state"], "queued");
        // Repeating a state changes nothing; going back is refused.
        let values = mark_one(&mut connection, "msg_1", TERM_B, "delivered", None).unwrap();
        assert_eq!(values[0]["deliveries"][0]["attempts"], "1");
        mark_one(&mut connection, "msg_1", TERM_B, "acknowledged", None).unwrap();
        let refused = mark_one(&mut connection, "msg_1", TERM_B, "delivered", None).unwrap_err();
        assert!(refused.to_string().contains("cannot become delivered"));
        let refused = mark_one(&mut connection, "msg_1", TERM_B, "failed", None).unwrap_err();
        assert!(refused.to_string().contains("cannot become failed"));
        // A failed delivery records its error, and may be retried.
        let values =
            mark_one(&mut connection, "msg_1", "acp:s", "failed", Some("no daemon")).unwrap();
        assert_eq!(values[0]["deliveries"][1]["error"], "no daemon");
        let values = mark_one(&mut connection, "msg_1", "acp:s", "delivered", None).unwrap();
        assert_eq!(values[0]["deliveries"][1]["state"], "delivered");
        assert_eq!(values[0]["deliveries"][1]["attempts"], "2");
        assert_eq!(values[0]["deliveries"][1]["error"], Value::Null);
        // A recipient the message was not sent to is not found.
        assert!(mark_one(&mut connection, "msg_1", TERM_A, "delivered", None).is_err());
    }

    #[test]
    fn list_filters_by_recipient_state_sender_and_thread() {
        let mut connection = connection();
        send_one(&mut connection, "msg_1", &message(TERM_A, &[TERM_B], "one"));
        send_one(&mut connection, "msg_2", &message(TERM_B, &[TERM_A], "two"));
        send_one(&mut connection, "msg_3", &message(TERM_A, &[TERM_B], "three"));
        mark_one(&mut connection, "msg_1", TERM_B, "delivered", None).unwrap();
        let ids = |filter: AgentMessageFilter| -> Vec<String> {
            list(&connection, "session_x", &filter, 50)
                .unwrap()
                .into_iter()
                .map(|value| value["id"].as_str().unwrap().to_owned())
                .collect()
        };
        assert_eq!(ids(AgentMessageFilter::default()), ["msg_3", "msg_2", "msg_1"]);
        assert_eq!(
            ids(AgentMessageFilter { oldest_first: true, ..Default::default() }),
            ["msg_1", "msg_2", "msg_3"]
        );
        let to_b = AgentMessageFilter { recipient: Some(TERM_B.into()), ..Default::default() };
        assert_eq!(ids(to_b.clone()), ["msg_3", "msg_1"]);
        assert_eq!(ids(AgentMessageFilter { state: Some("queued".into()), ..to_b }), ["msg_3"]);
        assert_eq!(
            ids(AgentMessageFilter { sender: Some(TERM_B.into()), ..Default::default() }),
            ["msg_2"]
        );
        assert_eq!(
            ids(AgentMessageFilter { thread_id: Some("msg_2".into()), ..Default::default() }),
            ["msg_2"]
        );
        assert_eq!(
            list(&connection, "session_x", &AgentMessageFilter::default(), 1).unwrap().len(),
            1
        );
    }

    #[test]
    fn pruning_keeps_every_queued_message() {
        let mut connection = connection();
        send_one(&mut connection, "msg_queued", &message(TERM_A, &[TERM_B], "still waiting"));
        send_one(&mut connection, "msg_read", &message(TERM_A, &[TERM_B], "read"));
        mark_one(&mut connection, "msg_read", TERM_B, "acknowledged", None).unwrap();
        for index in 0..KEEP_SETTLED_MESSAGES {
            let id = format!("msg_fill_{index}");
            send_one(&mut connection, &id, &message(TERM_A, &[TERM_B], "fill"));
        }
        let transaction = connection.transaction().unwrap();
        assert!(snapshot(&transaction, "session_x", "msg_queued").unwrap().is_some());
        assert!(snapshot(&transaction, "session_x", "msg_read").unwrap().is_none());
    }

    #[test]
    fn message_ids_are_typed_and_random() {
        let first = new_message_id().unwrap();
        assert!(first.starts_with("msg_") && first.len() == 36);
        assert_ne!(first, new_message_id().unwrap());
    }

    fn set(connection: &mut Connection, recipient: &str, enabled: bool) -> Value {
        let transaction = connection.transaction().unwrap();
        let value = set_receiving(&transaction, recipient, enabled, &any_terminal, 20).unwrap();
        transaction.commit().unwrap();
        value
    }

    #[test]
    fn turning_receiving_off_fails_queued_messages_and_refuses_new_ones() {
        let mut connection = connection();
        send_one(&mut connection, "msg_1", &message(TERM_A, &[TERM_B, "acp:review"], "one"));
        send_one(&mut connection, "msg_2", &message(TERM_A, &["acp:review"], "two"));
        let value = set(&mut connection, TERM_B, false);
        assert_eq!(value, json!({"recipient": TERM_B, "enabled": false, "failed": ["msg_1"]}));
        let message_1 = snapshot(&connection, "session_x", "msg_1").unwrap().unwrap();
        assert_eq!(message_1["deliveries"][0]["state"], "failed");
        assert_eq!(message_1["deliveries"][0]["error"], format!("{TERM_B} has messages disabled"));
        assert_eq!(message_1["deliveries"][1]["state"], "queued");
        let error = send_err(&mut connection, &message(TERM_A, &["acp:review", TERM_B], "three"));
        assert_eq!(error, format!("bad request: {TERM_B} has messages disabled"));
        // A reply to an opted-out sender is refused too.
        let mut reply = message("acp:review", &[], "answer");
        reply.in_reply_to = Some("msg_2".into());
        let transaction = connection.transaction().unwrap();
        set_receiving(&transaction, TERM_A, false, &any_terminal, 21).unwrap();
        let error =
            send(&transaction, "session_x", "msg_3", &reply, &any_terminal, 22).unwrap_err();
        assert_eq!(error.to_string(), format!("bad request: {TERM_A} has messages disabled"));
        drop(transaction);
        assert_eq!(
            disabled_recipients(&connection).unwrap(),
            json!([{"recipient": TERM_B, "updated_at_ms": "20"}]).as_array().unwrap().clone()
        );
        let value = set(&mut connection, TERM_B, true);
        assert_eq!(value, json!({"recipient": TERM_B, "enabled": true, "failed": []}));
        assert!(disabled_recipients(&connection).unwrap().is_empty());
        send_one(&mut connection, "msg_4", &message(TERM_A, &[TERM_B], "back"));
    }

    #[test]
    fn failing_every_queued_receipt_leaves_settled_ones() {
        let mut connection = connection();
        send_one(&mut connection, "msg_1", &message(TERM_A, &[TERM_B], "one"));
        send_one(&mut connection, "msg_2", &message(TERM_B, &[TERM_A], "two"));
        let transaction = connection.transaction().unwrap();
        mark(&transaction, "session_x", &["msg_1".into()], TERM_B, "delivered", None, None, 15)
            .unwrap();
        let failed = fail_queued(&transaction, None, TURNED_OFF, 30).unwrap();
        transaction.commit().unwrap();
        assert_eq!(failed, ["msg_2"]);
        let message_1 = snapshot(&connection, "session_x", "msg_1").unwrap().unwrap();
        assert_eq!(message_1["deliveries"][0]["state"], "delivered");
        let message_2 = snapshot(&connection, "session_x", "msg_2").unwrap().unwrap();
        assert_eq!(message_2["deliveries"][0]["state"], "failed");
        assert_eq!(message_2["deliveries"][0]["error"], TURNED_OFF);
    }

    #[test]
    fn opt_outs_of_ended_terminals_are_dropped() {
        let mut connection = connection();
        set(&mut connection, TERM_A, false);
        let transaction = connection.transaction().unwrap();
        let only_b = |terminal: &str| -> anyhow::Result<bool> { Ok(terminal == TERM_B) };
        set_receiving(&transaction, TERM_B, false, &only_b, 30).unwrap();
        set_receiving(&transaction, "acp:review", false, &only_b, 31).unwrap();
        transaction.commit().unwrap();
        let rows: Vec<Value> = disabled_recipients(&connection).unwrap();
        let recipients: Vec<&str> =
            rows.iter().map(|row| row["recipient"].as_str().unwrap()).collect();
        assert_eq!(recipients, [TERM_B, "acp:review"]);
    }

    #[test]
    fn a_recipient_that_turned_messages_off_cannot_be_delivered_to() {
        let mut connection = connection();
        send_one(&mut connection, "msg_1", &message(TERM_A, &[TERM_B], "one"));
        set(&mut connection, TERM_B, false);
        let transaction = connection.transaction().unwrap();
        let error = mark(
            &transaction,
            "session_x",
            &["msg_1".into()],
            TERM_B,
            "delivered",
            Some("acp.prompt"),
            None,
            40,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), format!("bad request: {TERM_B} has messages disabled"));
        // A person may still acknowledge what reached them.
        mark(&transaction, "session_x", &["msg_1".into()], TERM_B, "acknowledged", None, None, 41)
            .unwrap();
    }

    #[test]
    fn receiving_is_set_only_for_recipient_addresses() {
        let mut connection = connection();
        let transaction = connection.transaction().unwrap();
        let error = set_receiving(&transaction, "cli", false, &any_terminal, 1).unwrap_err();
        assert!(error.to_string().contains("is not a recipient"), "{error}");
        let no_terminal = |_: &str| -> anyhow::Result<bool> { Ok(false) };
        let error = set_receiving(&transaction, TERM_A, false, &no_terminal, 1).unwrap_err();
        assert!(error.to_string().contains("no terminal"), "{error}");
    }
}
