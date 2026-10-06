//! `conversation-search` (the local owner) and `home.search` (the cloud
//! read): one read model, shared with the cloud reducer through the corpus
//! `backend/packages/home-core/conformance/conversation-search-cases.json`.
//!
//! Home messages only, in conversations where the actor is a participant. The
//! match is a case-insensitive substring of the text parts: both sides are
//! lower-cased per code point (`char::to_lowercase`), so every script works
//! without a tokenizer. Order: newest `created_at` first, then conversation id
//! ascending, then seq descending. A retracted message never matches.

use serde::{Deserialize, Serialize};

use crate::types::{ConversationHead, Message, Part};

pub const MAX_QUERY_CHARS: usize = 200;
pub const SNIPPET_CHARS: usize = 120;
pub const MIN_SEARCH_LIMIT: u32 = 1;
pub const MAX_SEARCH_LIMIT: u32 = 100;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchInput {
    pub query: String,
    pub limit: u32,
}

/// One conversation and its messages (any order).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct SearchSource {
    pub head: ConversationHead,
    pub messages: Vec<Message>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchHit {
    pub conversation: String,
    pub title: String,
    pub seq: u64,
    pub message_id: String,
    pub author: String,
    pub created_at: String,
    pub snippet: String,
}

/// Why a search was refused (the corpus `reject` codes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchReject {
    InvalidQuery,
    InvalidLimit,
}

impl SearchReject {
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidQuery => "invalid_query",
            Self::InvalidLimit => "invalid_limit",
        }
    }
}

/// The trimmed query, or why it is refused.
pub fn validate_search(input: &SearchInput) -> Result<String, SearchReject> {
    let query = input.query.trim();
    if query.is_empty()
        || query.chars().count() > MAX_QUERY_CHARS
        || query.chars().any(|ch| ch <= '\u{1f}' || ch == '\u{7f}')
    {
        return Err(SearchReject::InvalidQuery);
    }
    if !(MIN_SEARCH_LIMIT..=MAX_SEARCH_LIMIT).contains(&input.limit) {
        return Err(SearchReject::InvalidLimit);
    }
    Ok(query.to_string())
}

/// The text of a message for matching and snippets: its text parts joined
/// by one space, whitespace collapsed.
pub fn message_text(message: &Message) -> String {
    let joined = message
        .parts
        .iter()
        .filter_map(|part| match part {
            Part::Text { text, .. } => Some(text.as_str()),
            // A link preview is found by its title (the URL is in the text part that carries it).
            Part::LinkPreview { title, .. } => title.as_deref(),
            Part::Work { .. } | Part::Attachment { .. } => None,
        })
        .collect::<Vec<_>>()
        .join(" ");
    joined.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn fold(ch: char) -> String {
    ch.to_lowercase().collect()
}

/// Code-point offset of the first case-insensitive match of `needle`.
fn find_folded(text: &[char], needle: &[String]) -> Option<usize> {
    let folded = text.iter().map(|ch| fold(*ch)).collect::<Vec<_>>();
    (0..folded.len()).find(|&start| {
        start + needle.len() <= folded.len()
            && needle.iter().enumerate().all(|(offset, ch)| &folded[start + offset] == ch)
    })
}

/// Up to `SNIPPET_CHARS` characters centered on the match at `at` (a code
/// point offset), with an ellipsis where it cuts.
pub fn snippet_of(text: &str, at: usize, length: usize) -> String {
    let chars = text.chars().collect::<Vec<_>>();
    if chars.len() <= SNIPPET_CHARS {
        return text.to_string();
    }
    let centered = at as i64 - ((SNIPPET_CHARS as i64 - length as i64).div_euclid(2));
    let start = centered.clamp(0, (chars.len() - SNIPPET_CHARS) as i64) as usize;
    let end = (start + SNIPPET_CHARS).min(chars.len());
    let mut snippet = String::new();
    if start > 0 {
        snippet.push('…');
    }
    snippet.extend(&chars[start..end]);
    if end < chars.len() {
        snippet.push('…');
    }
    snippet
}

/// Whether `message` matches `needle` (folded per code point), with its hit.
pub fn search_hit(
    head: &ConversationHead,
    message: &Message,
    needle: &[String],
) -> Option<SearchHit> {
    if message.conversation != head.id || message.retracted_at.is_some() {
        return None;
    }
    let text = message_text(message);
    let chars = text.chars().collect::<Vec<_>>();
    let at = find_folded(&chars, needle)?;
    Some(SearchHit {
        conversation: head.id.clone(),
        title: head.title.clone(),
        seq: message.seq,
        message_id: message.id.clone(),
        author: message.author.clone(),
        created_at: message.created_at.clone(),
        snippet: snippet_of(&text, at, needle.len()),
    })
}

/// The query folded per code point, for `search_hit`.
pub fn fold_query(query: &str) -> Vec<String> {
    query.chars().map(fold).collect()
}

/// Newest first, then conversation id ascending, then seq descending.
pub fn sort_hits(hits: &mut [SearchHit]) {
    hits.sort_by(|a, b| {
        b.created_at
            .cmp(&a.created_at)
            .then_with(|| a.conversation.cmp(&b.conversation))
            .then_with(|| b.seq.cmp(&a.seq))
    });
}

/// The search over in-memory sources (the corpus form).
pub fn search_conversations(
    actor: &str,
    input: &SearchInput,
    sources: &[SearchSource],
) -> Result<Vec<SearchHit>, SearchReject> {
    let needle = fold_query(&validate_search(input)?);
    let mut hits = sources
        .iter()
        .filter(|source| source.head.participant(actor).is_some())
        .flat_map(|source| {
            source.messages.iter().filter_map(|message| search_hit(&source.head, message, &needle))
        })
        .collect::<Vec<_>>();
    sort_hits(&mut hits);
    hits.truncate(input.limit as usize);
    Ok(hits)
}
