//! The local conversation owner's durable store (plans/cmux-next/home.md
//! sections 1 and 2, capability `local-conversations-v1`).
//!
//! It is its own owner next to the workspace registry, with its own file
//! `conversations.sqlite3` in the session state directory. Validation is the
//! pure `cmux-conversation` reducer; this module only loads the rows an op
//! needs, assigns ids and time, and commits the head, the message row and the
//! idempotency ledger row in one SQLite transaction. Callers publish events
//! only after a method returns, so no event ever describes an uncommitted
//! write. Typing indicators are never stored.

use std::path::Path;
use std::sync::{Arc, Mutex};

use anyhow::Context;
use cmux_conversation::{
    ConversationHead, CreateRequest, Message, Op, OpRequest, Origin, Participant, Reject, Summary,
    encode_id, format_rfc3339_millis, summary, valid_participant_id, valid_token,
};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

#[path = "conversation_import.rs"]
mod import;
pub(crate) use import::ImportedMessage;

/// The store's file inside the session state directory.
pub(crate) const CONVERSATIONS_FILE: &str = "conversations.sqlite3";
/// 2: the op ledger is keyed by actor too (`op_ledger_v2`) and the agent loop
/// guard lives in `agent_guard`. Version 1 ledger rows are not consulted.
const SCHEMA_VERSION: i64 = 2;
/// Largest `tail` and `limit` a page request may ask for.
pub(crate) const MAX_PAGE_MESSAGES: u32 = 500;
/// The participant id of the Mac's own user in local conversations.
pub(crate) const LOCAL_USER: &str = "user_local";

/// An op the conversation reducer refused. The control socket reports it
/// with `error_code` [`ConversationRejected::CODE`] and the reason code as
/// the error text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConversationRejected(pub Reject);

impl ConversationRejected {
    pub const CODE: &'static str = "conversation_rejected";
}

impl std::fmt::Display for ConversationRejected {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0.code())
    }
}

impl std::error::Error for ConversationRejected {}

fn rejected(reject: Reject) -> anyhow::Error {
    ConversationRejected(reject).into()
}

/// The result of a committed op, stored in the idempotency ledger and
/// returned unchanged to every replay.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct OpResult {
    pub rev: u64,
    /// The seq of the message the op created or changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<u64>,
    /// The wire change object (`conversation-changed.change`).
    pub change: Value,
    /// `remote` for an op a paired install committed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<Origin>,
}

/// A committed or replayed `conversation-op`.
#[derive(Debug, Clone)]
pub(crate) struct OpOutcome {
    pub result: OpResult,
    pub replayed: bool,
}

/// A committed or replayed `conversation-create`.
#[derive(Debug, Clone)]
pub(crate) struct CreateOutcome {
    pub summary: Summary,
    pub replayed: bool,
}

pub(crate) struct ConversationStore {
    connection: Connection,
}

impl std::fmt::Debug for ConversationStore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("ConversationStore").finish_non_exhaustive()
    }
}

impl ConversationStore {
    /// Open `conversations.sqlite3` in `directory`, or an in-memory store
    /// when there is no directory (an in-memory session, tests).
    pub(crate) fn open(directory: Option<&Path>) -> anyhow::Result<Self> {
        let connection = match directory {
            Some(directory) => {
                let path = directory.join(CONVERSATIONS_FILE);
                let connection = crate::workspace_registry::open_registry_database(&path)
                    .with_context(|| format!("open conversation store {}", path.display()))?;
                crate::platform::restrict_file(&path)
                    .with_context(|| format!("restrict conversation store {}", path.display()))?;
                connection
            }
            None => Connection::open_in_memory()?,
        };
        Self::initialize(connection)
    }

    fn initialize(mut connection: Connection) -> anyhow::Result<Self> {
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA fullfsync=ON;
             CREATE TABLE IF NOT EXISTS meta (
               key TEXT PRIMARY KEY NOT NULL,
               value TEXT NOT NULL
             );",
        )?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let stored: Option<String> = transaction
            .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| row.get(0))
            .optional()?;
        if let Some(stored) = stored {
            let stored: i64 = stored.parse().context("conversation store schema is invalid")?;
            anyhow::ensure!(
                stored <= SCHEMA_VERSION,
                "unsupported conversation store schema {stored}; newest supported is \
                 {SCHEMA_VERSION}"
            );
        }
        transaction.execute_batch(
            "CREATE TABLE IF NOT EXISTS conversation (
               id TEXT PRIMARY KEY NOT NULL,
               title TEXT NOT NULL,
               participants_json TEXT NOT NULL,
               last_seq INTEGER NOT NULL CHECK(last_seq >= 0),
               rev INTEGER NOT NULL CHECK(rev >= 1),
               created_at TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS conversation_by_updated
               ON conversation(updated_at DESC, id DESC);
             CREATE TABLE IF NOT EXISTS message (
               conversation TEXT NOT NULL,
               seq INTEGER NOT NULL CHECK(seq >= 1),
               id TEXT NOT NULL,
               message_json TEXT NOT NULL,
               PRIMARY KEY(conversation, seq)
             ) WITHOUT ROWID;
             CREATE UNIQUE INDEX IF NOT EXISTS message_by_id ON message(id);
             CREATE TABLE IF NOT EXISTS op_ledger (
               conversation TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               fingerprint TEXT NOT NULL,
               result_json TEXT NOT NULL,
               PRIMARY KEY(conversation, idempotency_key)
             ) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS create_ledger (
               idempotency_key TEXT PRIMARY KEY NOT NULL,
               fingerprint TEXT NOT NULL,
               conversation TEXT NOT NULL
             ) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS read_cursor (
               conversation TEXT NOT NULL,
               participant TEXT NOT NULL,
               seq INTEGER NOT NULL CHECK(seq >= 0),
               PRIMARY KEY(conversation, participant)
             ) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS op_ledger_v2 (
               conversation TEXT NOT NULL,
               actor TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               fingerprint TEXT NOT NULL,
               result_json TEXT NOT NULL,
               PRIMARY KEY(conversation, actor, idempotency_key)
             ) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS agent_guard (
               conversation TEXT PRIMARY KEY NOT NULL,
               agent_text_streak INTEGER NOT NULL CHECK(agent_text_streak >= 0),
               last_agent_text_at TEXT
             ) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS agent_token (
               participant TEXT PRIMARY KEY NOT NULL,
               token_hash TEXT NOT NULL
             ) WITHOUT ROWID;",
        )?;
        crate::conversation_search::drop_search_index(&transaction)?;
        transaction.execute(
            "INSERT INTO meta(key, value) VALUES('schema_version', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![SCHEMA_VERSION.to_string()],
        )?;
        transaction.commit()?;
        Ok(Self { connection })
    }

    /// Mints the credential of agent `participant`: a random token whose SHA-256
    /// is stored (a new token replaces the old one). A connection becomes that
    /// participant only by presenting the token (`conversation-bind`).
    pub(crate) fn mint_agent_token(&mut self, participant: &str) -> anyhow::Result<String> {
        anyhow::ensure!(
            valid_participant_id(participant) && participant.starts_with("agent_"),
            "bad request: participant must be an agent id"
        );
        let mut random = [0_u8; 32];
        getrandom::fill(&mut random).map_err(|_| anyhow::anyhow!("agent token randomness"))?;
        let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        self.connection.execute(
            "INSERT INTO agent_token(participant, token_hash) VALUES(?1, ?2)
             ON CONFLICT(participant) DO UPDATE SET token_hash = excluded.token_hash",
            params![participant, token_digest(&token)],
        )?;
        Ok(token)
    }

    /// Whether `token` is the current credential of `participant`.
    pub(crate) fn verify_agent_token(
        &mut self,
        participant: &str,
        token: &str,
    ) -> anyhow::Result<bool> {
        let stored: Option<String> = self
            .connection
            .query_row(
                "SELECT token_hash FROM agent_token WHERE participant = ?1",
                params![participant],
                |row| row.get(0),
            )
            .optional()?;
        Ok(stored.is_some_and(|stored| stored == token_digest(token)))
    }

    /// `conversation-search`: the best `limit` hits for `query` over the text
    /// of every message that is not retracted.
    pub(crate) fn search(
        &mut self,
        actor: &str,
        input: &cmux_conversation::SearchInput,
    ) -> anyhow::Result<Vec<cmux_conversation::SearchHit>> {
        crate::conversation_search::search(&mut self.connection, actor, input, |connection, id| {
            load_head(connection, id)
        })
    }

    /// Every conversation, newest `updated_at` first.
    pub(crate) fn list(&mut self) -> anyhow::Result<Vec<Summary>> {
        let transaction = self.connection.transaction()?;
        let ids = {
            let mut statement = transaction
                .prepare("SELECT id FROM conversation ORDER BY updated_at DESC, id DESC")?;
            statement
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut summaries = Vec::with_capacity(ids.len());
        for id in ids {
            let head = load_head(&transaction, &id)?.context("conversation vanished")?;
            let last = load_message_by_seq(&transaction, &id, head.last_seq)?;
            summaries.push(summary(&head, last.as_ref()));
        }
        Ok(summaries)
    }

    /// Create a conversation. A retry with the same idempotency key and the
    /// same request returns the conversation it created.
    pub(crate) fn create(
        &mut self,
        idempotency_key: &str,
        actor: &str,
        title: &str,
        participants: &[Participant],
    ) -> anyhow::Result<CreateOutcome> {
        validate_idempotency_key(idempotency_key)?;
        let fingerprint =
            fingerprint(&json!({"actor": actor, "title": title, "participants": participants}))?;
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        let id = new_id("conv_", now_ms)?;
        let now = format_rfc3339_millis(now_ms);
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing: Option<(String, String)> = transaction
            .query_row(
                "SELECT fingerprint, conversation FROM create_ledger WHERE idempotency_key = ?1",
                params![idempotency_key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((stored, conversation)) = existing {
            if stored != fingerprint {
                return Err(rejected(Reject::IdempotencyConflict));
            }
            let head = load_head(&transaction, &conversation)?
                .context("created conversation is missing")?;
            let last = load_message_by_seq(&transaction, &conversation, head.last_seq)?;
            return Ok(CreateOutcome { summary: summary(&head, last.as_ref()), replayed: true });
        }
        let head = cmux_conversation::create(&CreateRequest {
            id: &id,
            actor,
            title,
            participants,
            now: &now,
        })
        .map_err(rejected)?;
        write_head(&transaction, &head)?;
        transaction.execute(
            "INSERT INTO create_ledger(idempotency_key, fingerprint, conversation)
             VALUES(?1, ?2, ?3)",
            params![idempotency_key, fingerprint, head.id],
        )?;
        transaction.commit()?;
        Ok(CreateOutcome { summary: summary(&head, None), replayed: false })
    }

    /// The summary and the last `tail` messages, ascending by seq.
    pub(crate) fn snapshot(
        &mut self,
        conversation: &str,
        tail: u32,
    ) -> anyhow::Result<(Summary, Vec<Message>)> {
        let transaction = self.connection.transaction()?;
        let head = load_head(&transaction, conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        let messages = load_page(&transaction, conversation, head.last_seq + 1, tail)?;
        let summary = summary(&head, messages.last());
        Ok((summary, messages))
    }

    /// Up to `limit` messages with seq below `before_seq`, ascending.
    pub(crate) fn history(
        &mut self,
        conversation: &str,
        before_seq: u64,
        limit: u32,
    ) -> anyhow::Result<Vec<Message>> {
        let transaction = self.connection.transaction()?;
        load_head(&transaction, conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        load_page(&transaction, conversation, before_seq, limit)
    }

    /// The head of `conversation`, or `None` when it does not exist.
    pub(crate) fn head(&mut self, conversation: &str) -> anyhow::Result<Option<ConversationHead>> {
        load_head(&self.connection, conversation)
    }

    /// Validate a typing indicator. Typing is never stored.
    pub(crate) fn check_typing(&mut self, conversation: &str, actor: &str) -> anyhow::Result<()> {
        let head = load_head(&self.connection, conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        cmux_conversation::check_typing(&head, actor).map_err(rejected)
    }

    /// Apply one op in one transaction: ledger check, reducer, head and
    /// message writes, ledger row. A replay with the same key and the same
    /// request returns the stored result with `replayed` and writes nothing.
    pub(crate) fn apply_op(
        &mut self,
        conversation: &str,
        idempotency_key: &str,
        actor: &str,
        op: &Op,
    ) -> anyhow::Result<OpOutcome> {
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let outcome = apply_op_in(&transaction, conversation, idempotency_key, actor, op)?;
        transaction.commit()?;
        Ok(outcome)
    }

    /// Apply every op in one transaction: all commit or none does (pairing a
    /// device into every conversation of its person).
    pub(crate) fn apply_ops_atomically(
        &mut self,
        ops: &[(String, String, String, Op)],
    ) -> anyhow::Result<Vec<OpOutcome>> {
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut outcomes = Vec::with_capacity(ops.len());
        for (conversation, idempotency_key, actor, op) in ops {
            outcomes.push(apply_op_in(&transaction, conversation, idempotency_key, actor, op)?);
        }
        transaction.commit()?;
        Ok(outcomes)
    }
}

/// One op inside `transaction`: ledger check, reducer, head and message
/// writes, ledger row. The caller commits.
fn apply_op_in(
    transaction: &Transaction<'_>,
    conversation: &str,
    idempotency_key: &str,
    actor: &str,
    op: &Op,
) -> anyhow::Result<OpOutcome> {
    validate_idempotency_key(idempotency_key)?;
    let fingerprint = fingerprint(&json!({"actor": actor, "op": op}))?;
    let now_ms = crate::workspace_registry::unix_epoch_ms()?;
    let new_message_id = if op.is_send() { new_id("msg_", now_ms)? } else { String::new() };
    let now = format_rfc3339_millis(now_ms);
    let head = load_head(transaction, conversation)?
        .ok_or_else(|| rejected(Reject::UnknownConversation))?;
    let existing: Option<(String, String)> = transaction
        .query_row(
            "SELECT fingerprint, result_json FROM op_ledger_v2
             WHERE conversation = ?1 AND actor = ?2 AND idempotency_key = ?3",
            params![conversation, actor, idempotency_key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if let Some((stored, result)) = existing {
        if stored != fingerprint {
            return Err(rejected(Reject::IdempotencyConflict));
        }
        let result = serde_json::from_str(&result).context("conversation ledger is corrupt")?;
        return Ok(OpOutcome { result, replayed: true });
    }
    let target = match op.target_message_id() {
        Some(id) => load_message_by_id(transaction, id)?,
        None => None,
    };
    let reply_target = match op.reply_to() {
        Some(reply_to) => load_message_by_id(transaction, &reply_to.message_id)?,
        None => None,
    };
    let last_message = load_message_by_seq(transaction, conversation, head.last_seq)?;
    let mut commit = cmux_conversation::apply(
        &head,
        &OpRequest {
            actor,
            idempotency_key,
            op,
            now: &now,
            new_message_id: &new_message_id,
            target: target.as_ref(),
            reply_target: reply_target.as_ref(),
            last_message: last_message.as_ref(),
        },
    )
    .map_err(rejected)?;
    if let Op::MessageSend { parts, .. } = op {
        // After every reducer rule (the conformance corpus order), over the
        // head's loop-guard counters (no row window to fill with work cards).
        cmux_conversation::check_agent_streak(&head, actor, parts, now_ms).map_err(rejected)?;
    }
    let origin = stamp_origin(&mut commit, actor, op);
    write_head(transaction, &commit.head)?;
    if let Some(message) = &commit.message {
        write_message(transaction, message)?;
    }
    let result = OpResult {
        rev: commit.head.rev,
        seq: commit.message.as_ref().map(|message| message.seq),
        change: serde_json::to_value(&commit.change)?,
        origin,
    };
    transaction.execute(
        "INSERT INTO op_ledger_v2(conversation, actor, idempotency_key, fingerprint,
                                  result_json)
         VALUES(?1, ?2, ?3, ?4, ?5)",
        params![
            conversation,
            actor,
            idempotency_key,
            fingerprint,
            serde_json::to_string(&result)?,
        ],
    )?;
    Ok(OpOutcome { result, replayed: false })
}

/// The owner stamps the origin of an op from its actor, never from the
/// request: every op of a `remote_<install>` actor is remote on its ledger
/// row, and the message it sends is remote (server-remote-conversations.md
/// section 5).
fn stamp_origin(commit: &mut cmux_conversation::Commit, actor: &str, op: &Op) -> Option<Origin> {
    let install = actor.strip_prefix("remote_")?;
    let origin = Origin::Remote { install: install.to_string() };
    // Only the message a device sends is remote. A reaction, edit or retract
    // changes someone's message (maybe a local one): its origin stays.
    if !op.is_send() {
        return Some(origin);
    }
    if let Some(message) = commit.message.as_mut() {
        message.origin = Some(origin.clone());
    }
    if let cmux_conversation::Change::Message { message } = &mut commit.change {
        message.origin = Some(origin.clone());
    }
    Some(origin)
}

fn validate_idempotency_key(key: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        valid_token(key),
        "bad request: idempotency_key must be 1-128 printable ASCII characters"
    );
    Ok(())
}

/// A stable digest of a request re-serialized from its typed form, so the
/// field order is canonical and a replay is recognized whatever the client's
/// key order.
fn fingerprint(request: &Value) -> anyhow::Result<String> {
    let digest = Sha256::digest(serde_json::to_vec(request)?);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn token_digest(token: &str) -> String {
    Sha256::digest(token.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `<prefix>` + 26 Crockford base32 characters: the current millisecond and
/// 80 random bits.
fn new_id(prefix: &str, now_ms: u64) -> anyhow::Result<String> {
    let mut random = [0_u8; 10];
    getrandom::fill(&mut random).map_err(|_| anyhow::anyhow!("conversation id randomness"))?;
    Ok(encode_id(prefix, now_ms, random))
}

fn to_i64(value: u64) -> anyhow::Result<i64> {
    i64::try_from(value).context("conversation counter exceeds SQLite range")
}

fn load_head(connection: &Connection, id: &str) -> anyhow::Result<Option<ConversationHead>> {
    let row: Option<(String, String, i64, i64, String, String)> = connection
        .query_row(
            "SELECT title, participants_json, last_seq, rev, created_at, updated_at
             FROM conversation WHERE id = ?1",
            params![id],
            |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?))
            },
        )
        .optional()?;
    let Some((title, participants, last_seq, rev, created_at, updated_at)) = row else {
        return Ok(None);
    };
    let mut statement =
        connection.prepare("SELECT participant, seq FROM read_cursor WHERE conversation = ?1")?;
    let read_cursors = statement
        .query_map(params![id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
        .map(|row| {
            let (participant, seq) = row?;
            Ok((participant, u64::try_from(seq).context("read cursor is negative")?))
        })
        .collect::<anyhow::Result<_>>()?;
    let guard: (i64, Option<String>) = connection
        .query_row(
            "SELECT agent_text_streak, last_agent_text_at FROM agent_guard WHERE conversation = ?1",
            params![id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?
        .unwrap_or((0, None));
    Ok(Some(ConversationHead {
        id: id.to_string(),
        title,
        participants: serde_json::from_str(&participants)
            .context("conversation participants are corrupt")?,
        last_seq: u64::try_from(last_seq).context("conversation last_seq is negative")?,
        rev: u64::try_from(rev).context("conversation rev is negative")?,
        created_at,
        updated_at,
        read_cursors,
        agent_text_streak: u32::try_from(guard.0).context("agent_text_streak is out of range")?,
        last_agent_text_at: guard.1,
    }))
}

fn write_head(transaction: &Transaction<'_>, head: &ConversationHead) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO conversation(id, title, participants_json, last_seq, rev, created_at,
                                  updated_at)
         VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(id) DO UPDATE SET
           title = excluded.title,
           participants_json = excluded.participants_json,
           last_seq = excluded.last_seq,
           rev = excluded.rev,
           updated_at = excluded.updated_at",
        params![
            head.id,
            head.title,
            serde_json::to_string(&head.participants)?,
            to_i64(head.last_seq)?,
            to_i64(head.rev)?,
            head.created_at,
            head.updated_at,
        ],
    )?;
    transaction.execute(
        "INSERT INTO agent_guard(conversation, agent_text_streak, last_agent_text_at)
         VALUES(?1, ?2, ?3)
         ON CONFLICT(conversation) DO UPDATE SET
           agent_text_streak = excluded.agent_text_streak,
           last_agent_text_at = excluded.last_agent_text_at",
        params![head.id, i64::from(head.agent_text_streak), head.last_agent_text_at],
    )?;
    for (participant, seq) in &head.read_cursors {
        transaction.execute(
            "INSERT INTO read_cursor(conversation, participant, seq) VALUES(?1, ?2, ?3)
             ON CONFLICT(conversation, participant) DO UPDATE SET seq = excluded.seq",
            params![head.id, participant, to_i64(*seq)?],
        )?;
    }
    Ok(())
}

fn write_message(transaction: &Transaction<'_>, message: &Message) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO message(conversation, seq, id, message_json) VALUES(?1, ?2, ?3, ?4)
         ON CONFLICT(conversation, seq) DO UPDATE SET message_json = excluded.message_json",
        params![
            message.conversation,
            to_i64(message.seq)?,
            message.id,
            serde_json::to_string(message)?,
        ],
    )?;
    Ok(())
}

fn parse_message(json: &str) -> anyhow::Result<Message> {
    serde_json::from_str(json).context("conversation message is corrupt")
}

fn load_message_by_id(connection: &Connection, id: &str) -> anyhow::Result<Option<Message>> {
    let json: Option<String> = connection
        .query_row("SELECT message_json FROM message WHERE id = ?1", params![id], |row| row.get(0))
        .optional()?;
    json.as_deref().map(parse_message).transpose()
}

fn load_message_by_seq(
    connection: &Connection,
    conversation: &str,
    seq: u64,
) -> anyhow::Result<Option<Message>> {
    if seq == 0 {
        return Ok(None);
    }
    let json: Option<String> = connection
        .query_row(
            "SELECT message_json FROM message WHERE conversation = ?1 AND seq = ?2",
            params![conversation, to_i64(seq)?],
            |row| row.get(0),
        )
        .optional()?;
    json.as_deref().map(parse_message).transpose()
}

/// The last `limit` messages with seq below `before_seq`, ascending.
fn load_page(
    connection: &Connection,
    conversation: &str,
    before_seq: u64,
    limit: u32,
) -> anyhow::Result<Vec<Message>> {
    let mut statement = connection.prepare(
        "SELECT message_json FROM message WHERE conversation = ?1 AND seq < ?2
         ORDER BY seq DESC LIMIT ?3",
    )?;
    let before_seq = i64::try_from(before_seq).unwrap_or(i64::MAX);
    let mut messages = statement
        .query_map(params![conversation, before_seq, i64::from(limit)], |row| {
            row.get::<_, String>(0)
        })?
        .map(|row| parse_message(&row?))
        .collect::<anyhow::Result<Vec<_>>>()?;
    messages.reverse();
    Ok(messages)
}

/// An event the local conversation owner publishes after a commit
/// (`conversation-changed`) or for a typing indicator (`conversation-typing`).
#[derive(Debug, Clone)]
pub enum ConversationEvent {
    /// One committed op; `rev` increases by exactly one per committed op.
    Changed { conversation: String, rev: u64, transaction: Option<Arc<str>>, change: Value },
    /// A participant started or stopped typing. Never stored or replayed.
    Typing { conversation: String, participant: String, on: bool },
}

impl ConversationEvent {
    /// The subscribe-stream JSON of this event.
    pub(crate) fn wire_json(&self) -> Value {
        match self {
            Self::Changed { conversation, rev, transaction, change } => json!({
                "event": "conversation-changed",
                "conversation": conversation,
                "rev": rev,
                "transaction": transaction.as_deref(),
                "change": change,
            }),
            Self::Typing { conversation, participant, on } => json!({
                "event": "conversation-typing",
                "conversation": conversation,
                "participant": participant,
                "on": on,
            }),
        }
    }
}

/// The owner's hosting state on the mux: the store, opened on first use, and
/// the lock held across one write and the event it publishes, so subscribers
/// see each conversation's `rev` in commit order. Lock order: `publish`, then
/// `store`, then the workspace registry.
#[derive(Default)]
pub(crate) struct ConversationHost {
    pub(crate) store: Mutex<Option<ConversationStore>>,
    pub(crate) publish: Mutex<()>,
    /// The participant each connection bound with an agent token (memory only).
    pub(crate) bindings: Mutex<std::collections::BTreeMap<u64, String>>,
    /// Remote-relay peers, pairing records and revocation limits.
    pub(crate) remote: crate::remote_relay_state::RemoteRelayState,
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_conversation::{Part, ParticipantKind};

    fn participants() -> Vec<Participant> {
        vec![
            Participant {
                id: "user_local".to_string(),
                kind: ParticipantKind::Human,
                display_name: "Me".to_string(),
                agent_class: None,
                acp_session: None,
                person: None,
            },
            Participant {
                id: "agent_mux".to_string(),
                kind: ParticipantKind::Agent,
                display_name: "mux".to_string(),
                agent_class: Some(cmux_conversation::AgentClass::Mux),
                acp_session: Some("mux".to_string()),
                person: None,
            },
        ]
    }

    fn send(key: &str, text: &str) -> Op {
        Op::MessageSend {
            client_msg_id: key.to_string(),
            parts: vec![Part::Text { text: text.to_string(), runs: None }],
            reply_to: None,
        }
    }

    #[test]
    fn conversation_store_persists_across_reopen() {
        let directory = std::env::temp_dir()
            .join(format!("cmux-conversations-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let id = {
            let mut store = ConversationStore::open(Some(&directory)).unwrap();
            let created = store.create("create-1", "user_local", "mux", &participants()).unwrap();
            assert!(!created.replayed);
            let id = created.summary.id;
            assert!(id.starts_with("conv_") && id.len() == 31);
            for index in 1..=3 {
                let key = format!("c{index}");
                store.apply_op(&id, &key, "user_local", &send(&key, "hi")).unwrap();
            }
            store.apply_op(&id, "read-1", "agent_mux", &Op::ReadCursorSet { seq: 2 }).unwrap();
            id
        };
        assert!(directory.join(CONVERSATIONS_FILE).is_file());
        let mut store = ConversationStore::open(Some(&directory)).unwrap();
        let (summary, messages) = store.snapshot(&id, 2).unwrap();
        assert_eq!(summary.last_seq, 3);
        assert_eq!(summary.rev, 5);
        assert_eq!(summary.read_cursors.get("agent_mux"), Some(&2));
        assert_eq!(messages.iter().map(|message| message.seq).collect::<Vec<_>>(), vec![2, 3]);
        assert_eq!(summary.last_message.unwrap().seq, 3);
        // The ledger survives the reopen: the replay changes nothing.
        let replay = store.apply_op(&id, "c3", "user_local", &send("c3", "hi")).unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.result.seq, Some(3));
        assert_eq!(replay.result.rev, 4);
        let created = store.create("create-1", "user_local", "mux", &participants()).unwrap();
        assert!(created.replayed);
        assert_eq!(created.summary.id, id);
        let history = store.history(&id, 2, 500).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(store.list().unwrap().len(), 1);
        drop(store);
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn conversation_store_rejects_a_newer_schema() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                 INSERT INTO meta VALUES('schema_version', '3');",
            )
            .unwrap();
        let error = ConversationStore::initialize(connection).unwrap_err();
        assert!(error.to_string().contains("unsupported conversation store schema 3"));
    }
}
