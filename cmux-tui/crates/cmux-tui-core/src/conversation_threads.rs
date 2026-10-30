//! Thread reads on the local conversation owner (`conversation-thread-v1`,
//! cx-59n8.6): one thread (its root and replies, paged) and the stats of the
//! thread roots in a snapshot or history page. Both are computed at read time
//! from an expression index over `message.thread_root`, as the cloud owner
//! does over its rows, so no reducer or corpus change is needed. A retracted
//! reply stays in the thread read (shown as "message deleted") but does not
//! count in the stats (cx-59n8.9). The thread object (title, owner, status;
//! conversation-thread-objects-v1) comes from the root's `thread`; the status
//! is derived: a live reply after the resolution reopens the thread.

use cmux_conversation::{Message, Reject, ThreadStatus};
use rusqlite::{Connection, params};
use serde::Serialize;

use super::{ConversationStore, load_head, load_message_by_id, parse_message, rejected, to_i64};

/// Kept in the schema batch: `CREATE INDEX IF NOT EXISTS` needs no version
/// bump, and an older daemon ignores it.
pub(super) const SCHEMA: &str = "CREATE INDEX IF NOT EXISTS message_by_thread
       ON message(conversation, json_extract(message_json, '$.thread_root'), seq)
       WHERE json_extract(message_json, '$.thread_root') IS NOT NULL;";

/// How many distinct reply authors a summary names.
const SUMMARY_AUTHORS: usize = 3;

/// The stats of one thread root (`threads` items and `thread` of a page).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct ThreadSummary {
    pub root: String,
    pub reply_count: u64,
    pub last_reply_seq: Option<u64>,
    pub last_reply_at: Option<String>,
    /// The first distinct reply authors, ascending by seq.
    pub authors: Vec<String>,
    /// `resolved` while the root's resolution is newer than every live reply.
    pub status: ThreadStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// Who resolved it and when; only while `status` is `resolved`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved_by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved_at: Option<String>,
}

/// `conversation-thread` data.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct ThreadPage {
    pub root: Message,
    /// Ascending by seq, after `after_seq`.
    pub replies: Vec<Message>,
    pub has_more: bool,
    pub thread: ThreadSummary,
}

impl ConversationStore {
    /// The root `root` of `conversation` and up to `limit` of its replies
    /// with seq above `after_seq`. A root that is unknown, in another
    /// conversation or itself a reply is `unknown_message`.
    pub(crate) fn thread(
        &mut self,
        conversation: &str,
        root: &str,
        after_seq: u64,
        limit: u32,
    ) -> anyhow::Result<ThreadPage> {
        let transaction = self.connection.transaction()?;
        load_head(&transaction, conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        let root = load_message_by_id(&transaction, root)?
            .filter(|message| message.conversation == conversation && message.thread_root.is_none())
            .ok_or_else(|| rejected(Reject::UnknownMessage))?;
        let mut statement = transaction.prepare(
            "SELECT message_json FROM message
             WHERE conversation = ?1 AND json_extract(message_json, '$.thread_root') = ?2
               AND seq > ?3
             ORDER BY seq LIMIT ?4",
        )?;
        let after_seq = i64::try_from(after_seq).unwrap_or(i64::MAX);
        let mut replies = statement
            .query_map(params![conversation, root.id, after_seq, i64::from(limit) + 1], |row| {
                row.get::<_, String>(0)
            })?
            .map(|row| parse_message(&row?))
            .collect::<anyhow::Result<Vec<_>>>()?;
        let has_more = replies.len() > limit as usize;
        replies.truncate(limit as usize);
        drop(statement);
        let thread = summary(&transaction, conversation, &root)?;
        Ok(ThreadPage { root, replies, has_more, thread })
    }

    /// The summaries of the roots in `messages` that have replies or a
    /// thread object, in page order.
    pub(crate) fn thread_summaries(
        &mut self,
        conversation: &str,
        messages: &[Message],
    ) -> anyhow::Result<Vec<ThreadSummary>> {
        let transaction = self.connection.transaction()?;
        let mut summaries = Vec::new();
        for message in messages.iter().filter(|message| message.thread_root.is_none()) {
            let summary = summary(&transaction, conversation, message)?;
            if summary.reply_count > 0 || message.thread.is_some() {
                summaries.push(summary);
            }
        }
        Ok(summaries)
    }
}

/// The stats of root `root` over its replies that are not retracted: count,
/// last reply, and the first distinct authors, read through
/// `message_by_thread`, with the root's thread object.
fn summary(
    connection: &Connection,
    conversation: &str,
    root_message: &Message,
) -> anyhow::Result<ThreadSummary> {
    let mut summary = stats(connection, conversation, &root_message.id)?;
    if let Some(thread) = &root_message.thread {
        summary.status = thread.status(summary.last_reply_seq);
        summary.title = thread.title.clone();
        summary.owner = thread.owner.clone();
        if summary.status == ThreadStatus::Resolved {
            summary.resolved_by = thread.resolved.as_ref().map(|resolved| resolved.by.clone());
            summary.resolved_at = thread.resolved.as_ref().map(|resolved| resolved.at.clone());
        }
    }
    Ok(summary)
}

fn stats(connection: &Connection, conversation: &str, root: &str) -> anyhow::Result<ThreadSummary> {
    let (count, last_seq): (i64, Option<i64>) = connection.query_row(
        "SELECT count(*), max(seq) FROM message
         WHERE conversation = ?1 AND json_extract(message_json, '$.thread_root') = ?2
           AND json_extract(message_json, '$.retracted_at') IS NULL",
        params![conversation, root],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let mut summary = ThreadSummary {
        root: root.to_owned(),
        reply_count: u64::try_from(count).unwrap_or(0),
        last_reply_seq: None,
        last_reply_at: None,
        authors: Vec::new(),
        status: ThreadStatus::Open,
        title: None,
        owner: None,
        resolved_by: None,
        resolved_at: None,
    };
    let Some(last_seq) = last_seq else { return Ok(summary) };
    let last_json: String = connection.query_row(
        "SELECT message_json FROM message WHERE conversation = ?1 AND seq = ?2",
        params![conversation, last_seq],
        |row| row.get(0),
    )?;
    let last = parse_message(&last_json)?;
    summary.last_reply_seq = Some(last.seq);
    summary.last_reply_at = Some(last.created_at);
    let mut statement = connection.prepare(
        "SELECT json_extract(message_json, '$.author') AS author, min(seq) AS first FROM message
         WHERE conversation = ?1 AND json_extract(message_json, '$.thread_root') = ?2
           AND json_extract(message_json, '$.retracted_at') IS NULL
         GROUP BY author ORDER BY first LIMIT ?3",
    )?;
    let limit = to_i64(SUMMARY_AUTHORS as u64)?;
    summary.authors = statement
        .query_map(params![conversation, root, limit], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(summary)
}
