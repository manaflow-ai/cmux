//! Home-only search over the local conversation owner (`conversation-search`,
//! capability `conversation-search-v1`, plans/cmux-next/home.md section 2).
//!
//! The read model is the shared one in `cmux_conversation::search` (corpus
//! `conversation-search-cases.json`, also run by the cloud owner): a
//! case-insensitive substring of the text parts, per code point, in the
//! conversations where the actor is a participant, newest first. It reads the
//! committed message rows in one SQLite read transaction, so a search never
//! sees uncommitted text, and an edit or a retraction changes the results
//! with its own commit.

use cmux_conversation::{
    SearchHit, SearchInput, SearchReject, fold_query, search_hit, sort_hits, validate_search,
};
use rusqlite::{Connection, Transaction};

/// A refused search: the reply's `error_code` is `conversation_rejected`
/// and its `reason` the corpus code (`invalid_query`, `invalid_limit`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConversationSearchRejected(pub SearchReject);

impl std::fmt::Display for ConversationSearchRejected {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0.code())
    }
}

impl std::error::Error for ConversationSearchRejected {}

/// conversation-search-v1 shipped an FTS5 index kept by triggers; the shared
/// read model needs no index, so its tables and triggers go.
pub(crate) fn drop_search_index(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "DROP TRIGGER IF EXISTS message_search_insert;
         DROP TRIGGER IF EXISTS message_search_update;
         DROP TABLE IF EXISTS message_search;
         DROP TABLE IF EXISTS message_search_row;",
    )?;
    Ok(())
}

/// The hits of `actor`'s search over every stored conversation.
pub(crate) fn search(
    connection: &mut Connection,
    actor: &str,
    input: &SearchInput,
    load_head: impl Fn(&Connection, &str) -> anyhow::Result<Option<cmux_conversation::ConversationHead>>,
) -> anyhow::Result<Vec<SearchHit>> {
    let query = validate_search(input).map_err(ConversationSearchRejected)?;
    let needle = fold_query(&query);
    let transaction = connection.transaction()?;
    let ids = {
        let mut statement = transaction.prepare("SELECT id FROM conversation")?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    let mut hits = Vec::new();
    for id in ids {
        let Some(head) = load_head(&transaction, &id)? else { continue };
        if head.participant(actor).is_none() {
            continue;
        }
        let mut statement = transaction
            .prepare_cached("SELECT message_json FROM message WHERE conversation = ?1")?;
        let rows = statement.query_map([&id], |row| row.get::<_, String>(0))?;
        for json in rows {
            let message: cmux_conversation::Message = serde_json::from_str(&json?)
                .map_err(|_| anyhow::anyhow!("conversation message is corrupt"))?;
            hits.extend(search_hit(&head, &message, &needle));
        }
    }
    sort_hits(&mut hits);
    hits.truncate(input.limit as usize);
    Ok(hits)
}
