//! The conversation owner's pure reducer (plans/cmux-next/home.md sections 1
//! and 2, capability `local-conversations-v1`).
//!
//! This crate holds the wire types and the validation of every conversation
//! op. It has no I/O, no clock and no randomness: the host passes `now`, new
//! ids and the stored rows an op needs, and persists what [`apply`] returns.
//! The local owner (the cmux daemon) and the cloud owner (`ConversationDO`)
//! run the same reducer, so both speak the same ops and events.

mod attachments;
mod budget;
mod id;
mod link_preview;
mod reducer;
mod search;
mod types;

pub use attachments::{
    AttachmentClass, AttachmentReject, DerivedVariant, MAX_ATTACHMENT_BYTES,
    MAX_ATTACHMENT_NAME_CHARS, MAX_DIMENSION, MAX_DURATION_MS, MAX_POSTER_BYTES,
    MAX_PREVIEW_IMAGE_BYTES, attachment_class, is_denied_name, is_derived_image_type, is_sha256,
    valid_attachment_name, valid_attachment_part, validate_attachment_meta, validate_derived,
};
pub use budget::{
    BUDGET_WINDOW, MAX_AGENT_TURNS, MIN_AGENT_GAP_MS, check_agent_budget, check_agent_streak,
    parse_rfc3339_millis,
};
pub use id::{encode_id, format_rfc3339_millis};
pub use link_preview::{
    MAX_LINK_SITE_CHARS, MAX_LINK_TITLE_CHARS, MAX_LINK_URL_BYTES, valid_link_preview_part,
    valid_link_url,
};
pub use reducer::{
    Commit, CreateRequest, OpRequest, Reject, apply, check_typing, create, summary,
    valid_participant_id, valid_token,
};
pub use search::{
    MAX_QUERY_CHARS, MAX_SEARCH_LIMIT, MIN_SEARCH_LIMIT, SNIPPET_CHARS, SearchHit, SearchInput,
    SearchReject, SearchSource, fold_query, message_text, search_conversations, search_hit,
    snippet_of, sort_hits, validate_search,
};
pub use types::{
    AgentClass, Change, ConversationHead, DerivedImage, Message, Op, Origin, Part, PartRef,
    Participant, ParticipantKind, Reaction, ReactionKind, Summary, Tapback, TextRun, WorkStatus,
};

/// `Summary.owner` for conversations owned by a local daemon.
pub const OWNER_LOCAL: &str = "local";
/// Most parts in one message.
pub const MAX_PARTS: usize = 16;
/// Most UTF-8 bytes of text across a message's text parts.
pub const MAX_TEXT_BYTES: usize = 64 * 1024;
/// Longest title, in characters.
pub const MAX_TITLE_CHARS: usize = 200;
/// Most participants in one conversation.
pub const MAX_PARTICIPANTS: usize = 64;
/// Longest participant display name, in characters.
pub const MAX_DISPLAY_NAME_CHARS: usize = 100;
/// Most text runs in one text part.
pub const MAX_TEXT_RUNS: usize = 1024;
/// Longest work-part preview, in UTF-8 bytes.
pub const MAX_PREVIEW_BYTES: usize = 4096;
/// Longest emoji reaction, in UTF-8 bytes.
pub const MAX_EMOJI_BYTES: usize = 64;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod link_preview_tests;
