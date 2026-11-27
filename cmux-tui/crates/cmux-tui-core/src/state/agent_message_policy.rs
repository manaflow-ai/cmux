//! Who may message whom, and how much (bead cx-55d27, PR 3 of 6).
//!
//! The sender is the request's verified actor, never a field the caller
//! writes. Each recipient's delivery starts by the workspace rule: an agent
//! sending to an agent of a workspace it shares starts `queued`; a recipient
//! (or a sender) whose workspace the daemon cannot tell starts `held`; agents
//! of different workspaces follow the daemon's cross-workspace setting
//! ([`CrossWorkspace`], default hold). A person (the local user's CLI or
//! app) is no agent: their messages start queued.
//!
//! Every limit is counted from the stored rows and their timestamps, so a
//! restart forgets nothing. A refused send stores nothing and names its
//! reason in `details.reason`.

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use crate::resource::ResourceError;
use crate::workspace_registry::Actor;
use cmux_json::JsonSet as _;

/// Sends one sender may make in [`BURST_WINDOW_MS`].
pub(crate) const BURST_LIMIT: i64 = 5;
pub(crate) const BURST_WINDOW_MS: i64 = 10_000;
/// Messages one sender may address to one recipient in [`PAIR_WINDOW_MS`].
pub(crate) const PAIR_LIMIT: i64 = 20;
pub(crate) const PAIR_WINDOW_MS: i64 = 60_000;
/// Held or queued deliveries one recipient may have waiting.
pub(crate) const QUEUE_CAP: i64 = 50;
/// Replies above a thread's first message (its references).
pub(crate) const MAX_REPLY_DEPTH: usize = 8;
/// Messages one thread may hold.
pub(crate) const THREAD_BUDGET: i64 = 40;
/// The same body from the same sender to the same recipient within this
/// window is a duplicate.
pub(crate) const DUPLICATE_WINDOW_MS: i64 = 10_000;
/// How long a held delivery waits for a person's decision.
pub(crate) const HOLD_MS: i64 = 24 * 60 * 60 * 1000;

/// The daemon's cross-workspace rule, read from this variable at each send:
/// `hold` (the default and any other value), `refuse` or `allow`.
pub(crate) const CROSS_WORKSPACE_ENV: &str = "CMUX_AGENT_MESSAGE_CROSS_WORKSPACE";

/// What happens to a message between agents of different workspaces.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CrossWorkspace {
    Hold,
    Refuse,
    Allow,
}

impl CrossWorkspace {
    pub(crate) fn configured() -> Self {
        match std::env::var(CROSS_WORKSPACE_ENV).ok().as_deref().map(str::trim) {
            Some("refuse") => Self::Refuse,
            Some("allow") => Self::Allow,
            _ => Self::Hold,
        }
    }
}

/// The verified sender of a request: `None` for the person (the local user
/// or the verified app, [`super::agent_message_store::CLI_SENDER`]), else
/// its address: a terminal id, `acp:<session>`, or the stored actor form
/// (`peer:…`, `app:…`, …) of any other actor, whose workspace is never known.
///
/// A local process that leaves out its launch credential is the local user,
/// so holds are advisory against an agent that hides its credential until
/// credentials are mandatory.
pub(crate) fn sender_address(actor: &Actor) -> Option<String> {
    match actor {
        Actor::Frontend { .. } => None,
        Actor::User { .. } if *actor == Actor::local_user() => None,
        Actor::Terminal { id } => Some(id.clone()),
        Actor::AcpSession { id, .. } => Some(format!("acp:{id}")),
        other => Some(other.wire()),
    }
}

/// A workspace key in one comparable form: lowercase, without dashes (the
/// app hands terminals and sessions the key's uppercase UUID form).
pub(crate) fn workspace_key(value: &str) -> String {
    value.chars().filter(|ch| *ch != '-').flat_map(char::to_lowercase).collect()
}

/// The start of one recipient's delivery.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Start {
    Queued,
    /// Held for a person's decision, with the reason the delivery records.
    Held(&'static str),
}

/// The workspace rule for one recipient. `sender` is `None` for a person;
/// a workspace is `None` when the daemon cannot tell it.
pub(crate) fn start(
    sender: Option<Option<&str>>,
    recipient: Option<&str>,
    rule: CrossWorkspace,
) -> Result<Start, &'static str> {
    let Some(sender) = sender else { return Ok(Start::Queued) };
    let (Some(sender), Some(recipient)) = (sender, recipient) else {
        return Ok(Start::Held("workspace_unknown"));
    };
    if sender == recipient {
        return Ok(Start::Queued);
    }
    match rule {
        CrossWorkspace::Allow => Ok(Start::Queued),
        CrossWorkspace::Hold => Ok(Start::Held("cross_workspace")),
        CrossWorkspace::Refuse => Err("cross_workspace"),
    }
}

/// A refused send: `operation.failed` with a typed `reason`.
pub(crate) fn refused(reason: &str, message: impl Into<String>, extra: Value) -> anyhow::Error {
    refused_by("agent.message.send", reason, message, extra)
}

/// A refusal of `operation`: `operation.failed` with a typed `reason`.
pub(crate) fn refused_by(
    operation: &str,
    reason: &str,
    message: impl Into<String>,
    extra: Value,
) -> anyhow::Error {
    let mut details = json!({"operation": operation, "reason": reason});
    if extra.as_object().is_some_and(|extra| !extra.is_empty()) {
        details.set("extra", extra);
    }
    anyhow::Error::new(ResourceError::new("operation.failed", message, details, false))
}

/// A refused field: `validation.invalid` naming the field and the reason.
pub(crate) fn invalid(field: &str, reason: &str, message: impl Into<String>) -> anyhow::Error {
    anyhow::Error::new(ResourceError::new(
        "validation.invalid",
        message,
        json!({"field": field, "reason": reason}),
        false,
    ))
}

/// What the limits read about one send.
pub(crate) struct Send<'a> {
    pub(crate) sender: &'a str,
    pub(crate) recipients: &'a [String],
    pub(crate) body: &'a str,
    pub(crate) thread_id: &'a str,
    /// The ancestors of a reply (empty for a first message).
    pub(crate) depth: usize,
    pub(crate) now_ms: i64,
}

/// Every limit, in the order a looping agent meets them.
pub(crate) fn check_limits(connection: &Connection, send: &Send<'_>) -> anyhow::Result<()> {
    if send.depth > MAX_REPLY_DEPTH {
        return Err(refused(
            "reply_depth",
            format!("a reply may be at most {MAX_REPLY_DEPTH} levels deep"),
            json!({"limit": MAX_REPLY_DEPTH, "depth": send.depth}),
        ));
    }
    // Counted in its own table: pruning old messages never resets it.
    let in_thread: i64 = connection
        .query_row(
            "SELECT messages FROM agent_message_threads WHERE thread_id = ?1",
            [send.thread_id],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(0);
    if in_thread >= THREAD_BUDGET {
        return Err(refused(
            "thread_budget",
            format!("thread {} already has {THREAD_BUDGET} messages", send.thread_id),
            json!({"limit": THREAD_BUDGET, "thread_id": send.thread_id}),
        ));
    }
    check_traffic(connection, send.sender, send.recipients, send.body, send.now_ms)
}

/// The limits on how much one sender sends: duplicates, the burst, and each
/// recipient's pair rate and waiting queue. Read-only, so a send runs them
/// before it asks acpmux anything, and again in its commit.
pub(crate) fn check_traffic(
    connection: &Connection,
    sender: &str,
    recipients: &[String],
    body: &str,
    now_ms: i64,
) -> anyhow::Result<()> {
    let send = Traffic { sender, recipients, body, now_ms };
    for recipient in send.recipients {
        let duplicate: Option<String> = connection
            .query_row(
                "SELECT m.message_id FROM agent_messages AS m
                 JOIN agent_message_deliveries AS d ON d.message_id = m.message_id
                 WHERE m.sender = ?1 AND d.recipient = ?2 AND m.body = ?3
                   AND m.created_at_ms > ?4
                 ORDER BY m.sequence DESC LIMIT 1",
                params![send.sender, recipient, send.body, send.now_ms - DUPLICATE_WINDOW_MS],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(original) = duplicate {
            return Err(refused(
                "duplicate",
                format!("the same message to {recipient} was sent as {original} moments ago"),
                json!({"message_id": original, "recipient": recipient}),
            ));
        }
    }
    let recent: i64 = connection.query_row(
        "SELECT COUNT(*) FROM agent_messages WHERE sender = ?1 AND created_at_ms > ?2",
        params![send.sender, send.now_ms - BURST_WINDOW_MS],
        |row| row.get(0),
    )?;
    if recent >= BURST_LIMIT {
        return Err(refused(
            "rate_limited",
            format!("at most {BURST_LIMIT} messages in {} seconds", BURST_WINDOW_MS / 1000),
            json!({"limit": "burst", "count": BURST_LIMIT, "window_ms": BURST_WINDOW_MS}),
        ));
    }
    for recipient in send.recipients {
        let to_pair: i64 = connection.query_row(
            "SELECT COUNT(*) FROM agent_messages AS m
             JOIN agent_message_deliveries AS d ON d.message_id = m.message_id
             WHERE m.sender = ?1 AND d.recipient = ?2 AND m.created_at_ms > ?3",
            params![send.sender, recipient, send.now_ms - PAIR_WINDOW_MS],
            |row| row.get(0),
        )?;
        if to_pair >= PAIR_LIMIT {
            return Err(refused(
                "rate_limited",
                format!("at most {PAIR_LIMIT} messages a minute to {recipient}"),
                json!({"limit": "pair", "count": PAIR_LIMIT, "window_ms": PAIR_WINDOW_MS,
                       "recipient": recipient}),
            ));
        }
        let waiting = waiting(connection, recipient, send.now_ms)?;
        if waiting >= QUEUE_CAP {
            return Err(refused(
                "queue_full",
                format!("{recipient} already has {QUEUE_CAP} messages waiting"),
                json!({"limit": QUEUE_CAP, "recipient": recipient}),
            ));
        }
    }
    Ok(())
}

struct Traffic<'a> {
    sender: &'a str,
    recipients: &'a [String],
    body: &'a str,
    now_ms: i64,
}

/// An agent may put a message in an existing thread only when it takes part
/// in it: it sent one of the thread's messages or one was addressed to it.
/// A thread with no stored message is open to anyone.
pub(crate) fn check_thread_member(
    connection: &Connection,
    sender: &str,
    thread_id: &str,
) -> anyhow::Result<()> {
    let (exists, member): (bool, bool) = connection.query_row(
        "SELECT
           EXISTS(SELECT 1 FROM agent_messages WHERE thread_id = ?1),
           EXISTS(SELECT 1 FROM agent_messages AS m
                  WHERE m.thread_id = ?1 AND (m.sender = ?2 OR EXISTS(
                    SELECT 1 FROM agent_message_deliveries AS d
                    WHERE d.message_id = m.message_id AND d.recipient = ?2)))",
        params![thread_id, sender],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    if exists && !member {
        return Err(refused(
            "thread_not_joined",
            format!("{sender} takes no part in thread {thread_id}"),
            json!({"thread_id": thread_id}),
        ));
    }
    Ok(())
}

/// Count one more message in `thread_id`, and forget the counts of threads
/// that have no stored message and no new one for a week.
pub(crate) fn count_in_thread(
    connection: &Connection,
    thread_id: &str,
    now_ms: i64,
) -> anyhow::Result<()> {
    connection.execute(
        "INSERT INTO agent_message_threads(thread_id, messages, updated_at_ms)
         VALUES(?1, 1, ?2)
         ON CONFLICT(thread_id) DO UPDATE
           SET messages = messages + 1, updated_at_ms = excluded.updated_at_ms",
        params![thread_id, now_ms],
    )?;
    connection.execute(
        "DELETE FROM agent_message_threads
         WHERE updated_at_ms < ?1
           AND NOT EXISTS(SELECT 1 FROM agent_messages AS m
                          WHERE m.thread_id = agent_message_threads.thread_id)",
        [now_ms.saturating_sub(THREAD_COUNT_KEEP_MS)],
    )?;
    Ok(())
}

/// How long the message count of a thread with no stored message is kept.
const THREAD_COUNT_KEEP_MS: i64 = 7 * HOLD_MS;

/// The recipient's deliveries still waiting: queued, or held and not expired.
fn waiting(connection: &Connection, recipient: &str, now_ms: i64) -> anyhow::Result<i64> {
    Ok(connection.query_row(
        "SELECT COUNT(*) FROM agent_message_deliveries
         WHERE recipient = ?1
           AND (state = 'queued' OR (state = 'held' AND COALESCE(held_until_ms, 0) > ?2))",
        params![recipient, now_ms],
        |row| row.get(0),
    )?)
}

/// The daemon's clock for agent messages. Debug builds add the offset in
/// milliseconds that the file `CMUX_TUI_TEST_AGENT_MESSAGE_CLOCK_FILE`
/// holds, so a socket test can move time (expiry, rate windows) without
/// waiting. Release builds have no seam.
pub(crate) fn now_ms() -> i64 {
    let now = i64::try_from(crate::mux::now_ms()).unwrap_or(i64::MAX);
    now.saturating_add(test_clock_offset())
}

#[cfg(debug_assertions)]
fn test_clock_offset() -> i64 {
    std::env::var_os("CMUX_TUI_TEST_AGENT_MESSAGE_CLOCK_FILE")
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| text.trim().parse::<i64>().ok())
        .unwrap_or(0)
}

#[cfg(not(debug_assertions))]
fn test_clock_offset() -> i64 {
    0
}
