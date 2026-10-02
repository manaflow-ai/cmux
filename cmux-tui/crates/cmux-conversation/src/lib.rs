//! The conversation owner's pure reducer (plans/cmux-next/home.md sections 1
//! and 2, capability `local-conversations-v1`).
//!
//! This crate holds the wire types and the validation of every conversation
//! op. It has no I/O, no clock and no randomness: the host passes `now`, new
//! ids and the stored rows an op needs, and persists what [`apply`] returns.
//! The local owner (the cmux daemon) and the cloud owner (`ConversationDO`)
//! run the same reducer, so both speak the same ops and events.

mod id;
mod reducer;
mod types;

pub use id::{encode_id, format_rfc3339_millis};
pub use reducer::{
    Commit, CreateRequest, OpRequest, Reject, apply, check_typing, create, summary,
    valid_participant_id, valid_token,
};
pub use types::{
    AgentClass, Change, ConversationHead, Message, Op, Part, PartRef, Participant, ParticipantKind,
    Reaction, ReactionKind, Summary, Tapback, TextRun, WorkStatus,
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
