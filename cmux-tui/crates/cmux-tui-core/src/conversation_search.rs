//! Home-only search over the local conversation owner (`conversation-search`,
//! plans/cmux-next/home.md section 2).
//!
//! An SQLite FTS5 index over the text parts of every message that is not
//! retracted. The store writes the index row in the transaction that writes
//! the message row, so a search never sees text that is not committed, and an
//! edit or a retraction replaces or removes the row in the same commit. Work
//! cards are not indexed. The query is plain text: every word must match as
//! a prefix, so `dep fai` finds "deploy failed"; FTS5 operators in the input
//! have no effect.

use cmux_conversation::{Message, Part};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;

/// The most hits one search returns.
pub(crate) const MAX_SEARCH_HITS: u32 = 100;
/// The longest query, in characters.
pub(crate) const MAX_QUERY_CHARS: usize = 200;
/// Words of context the snippet keeps around a match.
const SNIPPET_TOKENS: i64 = 12;

pub(crate) fn create_search_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS message_search_row (
           row INTEGER PRIMARY KEY,
           conversation TEXT NOT NULL,
           seq INTEGER NOT NULL,
           UNIQUE(conversation, seq)
         );
         CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
           text,
           tokenize = 'unicode61 remove_diacritics 2'
         );",
    )?;
    Ok(())
}

/// Index every stored message: the upgrade from a store without the index.
pub(crate) fn rebuild_search_index(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM message_search", [])?;
    transaction.execute("DELETE FROM message_search_row", [])?;
    let messages = {
        let mut statement = transaction.prepare("SELECT message_json FROM message")?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    for json in messages {
        let message: Message = serde_json::from_str(&json)
            .map_err(|_| anyhow::anyhow!("conversation message is corrupt"))?;
        index_message(transaction, &message)?;
    }
    Ok(())
}

/// The searchable text of a message: its text parts, one per line. A
/// retracted message has none.
fn searchable_text(message: &Message) -> Option<String> {
    if message.retracted_at.is_some() {
        return None;
    }
    let text = message
        .parts
        .iter()
        .filter_map(|part| match part {
            Part::Text { text, .. } => Some(text.as_str()),
            Part::Work { .. } => None,
        })
        .collect::<Vec<_>>()
        .join("\n");
    (!text.trim().is_empty()).then_some(text)
}

/// Replace the index row of `message` (insert, edit, retraction).
pub(crate) fn index_message(
    transaction: &Transaction<'_>,
    message: &Message,
) -> anyhow::Result<()> {
    let seq = i64::try_from(message.seq)?;
    let existing: Option<i64> = transaction
        .query_row(
            "SELECT row FROM message_search_row WHERE conversation = ?1 AND seq = ?2",
            params![message.conversation, seq],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(row) = existing {
        transaction.execute("DELETE FROM message_search WHERE rowid = ?1", [row])?;
    }
    let Some(text) = searchable_text(message) else {
        if let Some(row) = existing {
            transaction.execute("DELETE FROM message_search_row WHERE row = ?1", [row])?;
        }
        return Ok(());
    };
    let row = match existing {
        Some(row) => row,
        None => {
            transaction.execute(
                "INSERT INTO message_search_row(conversation, seq) VALUES(?1, ?2)",
                params![message.conversation, seq],
            )?;
            transaction.last_insert_rowid()
        }
    };
    transaction
        .execute("INSERT INTO message_search(rowid, text) VALUES(?1, ?2)", params![row, text])?;
    Ok(())
}

/// The FTS5 expression for a plain-text query: every word quoted (so
/// operators are literal) and matched as a prefix. `None` when the query has
/// no word.
pub(crate) fn match_expression(query: &str) -> Option<String> {
    let words = query
        .split_whitespace()
        .map(|word| format!("\"{}\"*", word.replace('"', "\"\"")))
        .collect::<Vec<_>>();
    (!words.is_empty()).then(|| words.join(" "))
}

/// One search hit: a message and a snippet of its text around the match.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct SearchHit {
    pub conversation: String,
    pub title: String,
    pub seq: u64,
    pub message_id: String,
    pub author: String,
    pub created_at: String,
    pub snippet: String,
}

/// The best `limit` hits for `query`, by FTS5 rank, newest first among equal
/// ranks.
pub(crate) fn search(
    connection: &Connection,
    query: &str,
    limit: u32,
) -> anyhow::Result<Vec<SearchHit>> {
    anyhow::ensure!(
        query.chars().count() <= MAX_QUERY_CHARS,
        "bad request: query is longer than {MAX_QUERY_CHARS} characters"
    );
    anyhow::ensure!(
        (1..=MAX_SEARCH_HITS).contains(&limit),
        "bad request: limit must be 1-{MAX_SEARCH_HITS}"
    );
    let Some(expression) = match_expression(query) else { return Ok(Vec::new()) };
    let mut statement = connection.prepare(
        "SELECT r.conversation, c.title, r.seq, m.message_json,
                snippet(message_search, 0, '', '', '…', ?3)
         FROM message_search
         JOIN message_search_row AS r ON r.row = message_search.rowid
         JOIN conversation AS c ON c.id = r.conversation
         JOIN message AS m ON m.conversation = r.conversation AND m.seq = r.seq
         WHERE message_search MATCH ?1
         ORDER BY rank, r.conversation, r.seq DESC
         LIMIT ?2",
    )?;
    let rows = statement
        .query_map(params![expression, limit, SNIPPET_TOKENS], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    rows.into_iter()
        .map(|(conversation, title, seq, json, snippet)| {
            let message: Message = serde_json::from_str(&json)
                .map_err(|_| anyhow::anyhow!("conversation message is corrupt"))?;
            Ok(SearchHit {
                conversation,
                title,
                seq: u64::try_from(seq)?,
                message_id: message.id,
                author: message.author,
                created_at: message.created_at,
                snippet,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_search_quotes_every_word_as_a_prefix() {
        assert_eq!(match_expression("  "), None);
        assert_eq!(match_expression("dep fai"), Some("\"dep\"* \"fai\"*".to_string()));
        // Operators and quotes are literal text, never FTS5 syntax.
        assert_eq!(
            match_expression("a\" OR NEAR(b"),
            Some("\"a\"\"\"* \"OR\"* \"NEAR(b\"*".to_string())
        );
    }
}
