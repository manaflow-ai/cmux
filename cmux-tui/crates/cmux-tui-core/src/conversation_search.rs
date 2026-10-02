//! Home-only search over the local conversation owner (`conversation-search`,
//! capability `conversation-search-v1`, plans/cmux-next/home.md section 2).
//!
//! An SQLite FTS5 index over the text parts of every message that is not
//! retracted. SQLite triggers on the `message` table keep it, so the index
//! row changes in the statement that writes the message row: a search never
//! sees uncommitted text, an edit or a retraction changes the results in the
//! same commit, and a binary that predates the index keeps it current too
//! (the triggers live in the store file). Work cards are not indexed. The
//! query is plain text: every word must match as a prefix, so `dep fai`
//! finds "deploy failed"; FTS5 operators in the input are literal, and a word
//! without a letter or digit is ignored.

use cmux_conversation::Message;
use rusqlite::{Connection, Transaction, params};
use serde::Serialize;

/// The most hits one search returns.
pub(crate) const MAX_SEARCH_HITS: u32 = 100;
/// The longest query, in characters.
pub(crate) const MAX_QUERY_CHARS: usize = 200;
/// Words of context the snippet keeps around a match.
const SNIPPET_TOKENS: i64 = 12;

/// The searchable text of the message row `NEW`: its text parts, one per
/// line, or nothing for a retracted or unreadable message.
const ROW_TEXT: &str = "(SELECT group_concat(json_extract(p.value, '$.text'), char(10))
     FROM json_each(
       CASE WHEN json_valid(NEW.message_json) THEN NEW.message_json ELSE '{}' END, '$.parts'
     ) AS p
     WHERE json_extract(p.value, '$.type') = 'text')";

/// Replace the index row of message `NEW` (an insert or an update).
fn reindex_statements() -> String {
    format!(
        "INSERT OR IGNORE INTO message_search_row(conversation, seq)
           VALUES(NEW.conversation, NEW.seq);
         DELETE FROM message_search WHERE rowid = (
           SELECT row FROM message_search_row
           WHERE conversation = NEW.conversation AND seq = NEW.seq);
         INSERT INTO message_search(rowid, text)
           SELECT r.row, t.text
           FROM message_search_row AS r, (SELECT {ROW_TEXT} AS text) AS t
           WHERE r.conversation = NEW.conversation AND r.seq = NEW.seq
             AND json_valid(NEW.message_json)
             AND json_extract(NEW.message_json, '$.retracted_at') IS NULL
             AND trim(coalesce(t.text, '')) <> '';"
    )
}

pub(crate) fn create_search_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let reindex = reindex_statements();
    transaction.execute_batch(&format!(
        "CREATE TABLE IF NOT EXISTS message_search_row (
           row INTEGER PRIMARY KEY,
           conversation TEXT NOT NULL,
           seq INTEGER NOT NULL,
           UNIQUE(conversation, seq)
         );
         CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
           text,
           tokenize = 'unicode61 remove_diacritics 2',
           prefix = '2 3'
         );
         CREATE TRIGGER IF NOT EXISTS message_search_insert AFTER INSERT ON message BEGIN
           {reindex}
         END;
         CREATE TRIGGER IF NOT EXISTS message_search_update
           AFTER UPDATE OF message_json ON message BEGIN
           {reindex}
         END;"
    ))?;
    Ok(())
}

/// Index every stored message: the upgrade from a store without the index.
/// Rewriting each row fires the update trigger.
pub(crate) fn rebuild_search_index(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM message_search", [])?;
    transaction.execute("DELETE FROM message_search_row", [])?;
    transaction.execute("UPDATE message SET message_json = message_json", [])?;
    Ok(())
}

/// The FTS5 expression for a plain-text query: every word quoted (so
/// operators are literal) and matched as a prefix. `None` when the query has
/// no word.
pub(crate) fn match_expression(query: &str) -> Option<String> {
    let words = query
        .split_whitespace()
        .filter(|word| word.chars().any(char::is_alphanumeric))
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

/// The best `limit` hits for `query`, by FTS5 rank, the most recently indexed
/// first among equal ranks.
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
         ORDER BY rank, r.row DESC
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
        assert_eq!(match_expression("- * …"), None);
        assert_eq!(
            match_expression("deploy - staging"),
            Some("\"deploy\"* \"staging\"*".to_string())
        );
        assert_eq!(match_expression("dep fai"), Some("\"dep\"* \"fai\"*".to_string()));
        // Operators and quotes are literal text, never FTS5 syntax.
        assert_eq!(
            match_expression("a\" OR NEAR(b"),
            Some("\"a\"\"\"* \"OR\"* \"NEAR(b\"*".to_string())
        );
    }
}
