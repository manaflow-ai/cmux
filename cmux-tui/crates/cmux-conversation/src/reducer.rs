//! Validation and state transitions for conversation ops (the rule table in
//! plans/cmux-next/home.md section 2).

use crate::types::{
    Change, ConversationHead, Message, Op, Part, Participant, ParticipantKind, Reaction,
    ReactionKind, Summary,
};
use crate::{
    MAX_DISPLAY_NAME_CHARS, MAX_EMOJI_BYTES, MAX_PARTICIPANTS, MAX_PARTS, MAX_PREVIEW_BYTES,
    MAX_TEXT_BYTES, MAX_TEXT_RUNS, MAX_TITLE_CHARS, OWNER_LOCAL,
};

/// Why the owner refused an op. [`Reject::code`] is the stable wire reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reject {
    /// The actor is not a participant of the conversation.
    NotParticipant,
    /// Only the author may edit or retract a message.
    NotAuthor,
    /// The target or reply-to message does not exist in this conversation.
    UnknownMessage,
    /// Parts are empty, too many, too long, or malformed.
    InvalidParts,
    /// The idempotency key was used before with a different request.
    IdempotencyConflict,
    /// A read cursor may not move backwards.
    CursorRegression,
    /// The conversation does not exist.
    UnknownConversation,
    /// A read cursor may not pass the last message.
    CursorOutOfRange,
    /// The message was retracted and can no longer change.
    Retracted,
    /// `client_msg_id` is malformed or differs from the idempotency key.
    InvalidClientMsgId,
    /// The part index names no part of the message.
    InvalidPartIndex,
    /// The actor already has this reaction on this part.
    DuplicateReaction,
    /// The actor has no such reaction on this part.
    UnknownReaction,
    /// The reaction kind is malformed (for example an empty emoji).
    InvalidReaction,
    /// A participant with this id already exists.
    DuplicateParticipant,
    /// A participant record is malformed, or the conversation is full.
    InvalidParticipant,
    /// A title must have 1 to 200 characters.
    InvalidTitle,
    /// Agents already posted the most messages allowed since the last human
    /// message (budget.rs).
    AgentBudget,
    /// An agent posted less than the minimum gap after the last agent message.
    AgentRate,
    /// The request names an actor other than the connection's principal.
    ActorMismatch,
}

impl Reject {
    pub const ALL: [Self; 20] = [
        Self::NotParticipant,
        Self::NotAuthor,
        Self::UnknownMessage,
        Self::InvalidParts,
        Self::IdempotencyConflict,
        Self::CursorRegression,
        Self::UnknownConversation,
        Self::CursorOutOfRange,
        Self::Retracted,
        Self::InvalidClientMsgId,
        Self::InvalidPartIndex,
        Self::DuplicateReaction,
        Self::UnknownReaction,
        Self::InvalidReaction,
        Self::DuplicateParticipant,
        Self::InvalidParticipant,
        Self::InvalidTitle,
        Self::AgentBudget,
        Self::AgentRate,
        Self::ActorMismatch,
    ];

    pub fn code(self) -> &'static str {
        match self {
            Self::NotParticipant => "not_participant",
            Self::NotAuthor => "not_author",
            Self::UnknownMessage => "unknown_message",
            Self::InvalidParts => "invalid_parts",
            Self::IdempotencyConflict => "idempotency_conflict",
            Self::CursorRegression => "cursor_regression",
            Self::UnknownConversation => "unknown_conversation",
            Self::CursorOutOfRange => "cursor_out_of_range",
            Self::Retracted => "retracted",
            Self::InvalidClientMsgId => "invalid_client_msg_id",
            Self::InvalidPartIndex => "invalid_part_index",
            Self::DuplicateReaction => "duplicate_reaction",
            Self::UnknownReaction => "unknown_reaction",
            Self::InvalidReaction => "invalid_reaction",
            Self::DuplicateParticipant => "duplicate_participant",
            Self::InvalidParticipant => "invalid_participant",
            Self::InvalidTitle => "invalid_title",
            Self::AgentBudget => "agent_budget",
            Self::AgentRate => "agent_rate",
            Self::ActorMismatch => "actor_mismatch",
        }
    }
}

impl std::fmt::Display for Reject {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code())
    }
}

impl std::error::Error for Reject {}

/// The result of one committed op: the new head, the message row to upsert
/// (for message ops) and the change to publish after the commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Commit {
    pub head: ConversationHead,
    pub message: Option<Message>,
    pub change: Change,
}

/// One op and the stored rows it needs. The host loads `target` for ops that
/// name a message ([`Op::target_message_id`]), `reply_target` for a send with
/// `reply_to` ([`Op::reply_to`]), and the conversation's last message.
#[derive(Debug, Clone, Copy)]
pub struct OpRequest<'a> {
    pub actor: &'a str,
    pub idempotency_key: &'a str,
    pub op: &'a Op,
    /// RFC 3339 UTC with milliseconds.
    pub now: &'a str,
    /// The id a `message.send` assigns to its message.
    pub new_message_id: &'a str,
    pub target: Option<&'a Message>,
    pub reply_target: Option<&'a Message>,
    pub last_message: Option<&'a Message>,
}

/// A new conversation.
#[derive(Debug, Clone, Copy)]
pub struct CreateRequest<'a> {
    /// The owner-assigned conversation id.
    pub id: &'a str,
    pub actor: &'a str,
    pub title: &'a str,
    pub participants: &'a [Participant],
    pub now: &'a str,
}

/// Validate a new conversation and return its head at `rev` 1.
pub fn create(request: &CreateRequest<'_>) -> Result<ConversationHead, Reject> {
    validate_title(request.title)?;
    if request.participants.is_empty() || request.participants.len() > MAX_PARTICIPANTS {
        return Err(Reject::InvalidParticipant);
    }
    for (index, participant) in request.participants.iter().enumerate() {
        validate_participant(participant)?;
        if request.participants[..index].iter().any(|earlier| earlier.id == participant.id) {
            return Err(Reject::DuplicateParticipant);
        }
    }
    if !request.participants.iter().any(|participant| participant.id == request.actor) {
        return Err(Reject::NotParticipant);
    }
    Ok(ConversationHead {
        id: request.id.to_string(),
        title: request.title.to_string(),
        participants: request.participants.to_vec(),
        last_seq: 0,
        rev: 1,
        created_at: request.now.to_string(),
        updated_at: request.now.to_string(),
        read_cursors: Default::default(),
        agent_text_streak: 0,
        last_agent_text_at: None,
    })
}

/// A typing indicator is accepted only from a participant.
pub fn check_typing(head: &ConversationHead, actor: &str) -> Result<(), Reject> {
    require_participant(head, actor)
}

/// The wire summary of a conversation.
pub fn summary(head: &ConversationHead, last_message: Option<&Message>) -> Summary {
    Summary {
        id: head.id.clone(),
        owner: OWNER_LOCAL.to_string(),
        title: head.title.clone(),
        participants: head.participants.clone(),
        last_seq: head.last_seq,
        rev: head.rev,
        created_at: head.created_at.clone(),
        updated_at: head.updated_at.clone(),
        last_message: last_message.cloned(),
        read_cursors: head.read_cursors.clone(),
    }
}

/// Validate one op against the head and return what to commit. Every
/// committed op increases `rev` by exactly one.
pub fn apply(head: &ConversationHead, request: &OpRequest<'_>) -> Result<Commit, Reject> {
    require_participant(head, request.actor)?;
    let mut next = head.clone();
    next.rev = head.rev + 1;
    let now = request.now;
    let (message, change) = match request.op {
        Op::MessageSend { client_msg_id, parts, reply_to } => {
            if client_msg_id != request.idempotency_key || !valid_token(client_msg_id) {
                return Err(Reject::InvalidClientMsgId);
            }
            validate_parts(parts)?;
            if let Some(reply_to) = reply_to {
                let replied = request
                    .reply_target
                    .filter(|message| {
                        message.id == reply_to.message_id && message.conversation == head.id
                    })
                    .ok_or(Reject::UnknownMessage)?;
                if reply_to.part_index as usize >= replied.parts.len() {
                    return Err(Reject::InvalidPartIndex);
                }
            }
            next.last_seq = head.last_seq + 1;
            next.updated_at = now.to_string();
            // The loop guard counts text only; a work card neither counts nor resets it.
            if parts.iter().any(|part| matches!(part, Part::Text { .. })) {
                let author = head.participant(request.actor);
                if author.is_some_and(|p| p.kind == ParticipantKind::Agent) {
                    next.agent_text_streak = head.agent_text_streak.saturating_add(1);
                    next.last_agent_text_at = Some(now.to_string());
                } else {
                    next.agent_text_streak = 0;
                }
            }
            let message = Message {
                id: request.new_message_id.to_string(),
                conversation: head.id.clone(),
                seq: next.last_seq,
                client_msg_id: client_msg_id.clone(),
                author: request.actor.to_string(),
                parts: parts.clone(),
                reply_to: reply_to.clone(),
                created_at: now.to_string(),
                edited_at: None,
                retracted_at: None,
                reactions: Vec::new(),
            };
            let change = Change::Message { message: message.clone() };
            (Some(message), change)
        }
        // Edits, retractions and reactions change a message, not the
        // conversation list order, so `updated_at` stays (their change
        // carries only the message).
        Op::MessageEdit { message_id, parts } => {
            let mut message = target(head, request, message_id)?;
            if message.author != request.actor {
                return Err(Reject::NotAuthor);
            }
            if message.retracted_at.is_some() {
                return Err(Reject::Retracted);
            }
            validate_parts(parts)?;
            message.parts = parts.clone();
            message.edited_at = Some(now.to_string());
            let part_count = message.parts.len();
            message.reactions.retain(|reaction| (reaction.part_index as usize) < part_count);
            updated(message)
        }
        Op::MessageRetract { message_id } => {
            let mut message = target(head, request, message_id)?;
            if message.author != request.actor {
                return Err(Reject::NotAuthor);
            }
            if message.retracted_at.is_some() {
                return Err(Reject::Retracted);
            }
            message.parts.clear();
            message.reactions.clear();
            message.retracted_at = Some(now.to_string());
            updated(message)
        }
        Op::ReactionAdd { message_id, part_index, reaction } => {
            let mut message = target(head, request, message_id)?;
            if message.retracted_at.is_some() {
                return Err(Reject::Retracted);
            }
            if *part_index as usize >= message.parts.len() {
                return Err(Reject::InvalidPartIndex);
            }
            validate_reaction(reaction)?;
            if message.reactions.iter().any(|existing| {
                existing.author == request.actor
                    && existing.part_index == *part_index
                    && existing.kind == *reaction
            }) {
                return Err(Reject::DuplicateReaction);
            }
            message.reactions.push(Reaction {
                author: request.actor.to_string(),
                part_index: *part_index,
                kind: reaction.clone(),
                at: now.to_string(),
            });
            updated(message)
        }
        Op::ReactionRemove { message_id, part_index, reaction } => {
            let mut message = target(head, request, message_id)?;
            if message.retracted_at.is_some() {
                return Err(Reject::Retracted);
            }
            let position = message
                .reactions
                .iter()
                .position(|existing| {
                    existing.author == request.actor
                        && existing.part_index == *part_index
                        && existing.kind == *reaction
                })
                .ok_or(Reject::UnknownReaction)?;
            message.reactions.remove(position);
            updated(message)
        }
        Op::ReadCursorSet { seq } => {
            if *seq > head.last_seq {
                return Err(Reject::CursorOutOfRange);
            }
            let current = head.read_cursors.get(request.actor).copied().unwrap_or(0);
            if *seq < current {
                return Err(Reject::CursorRegression);
            }
            // Reading does not reorder the conversation list, so
            // `updated_at` stays.
            next.read_cursors.insert(request.actor.to_string(), *seq);
            (None, Change::ReadCursor { participant: request.actor.to_string(), seq: *seq })
        }
        Op::ParticipantsAdd { participant } => {
            validate_participant(participant)?;
            if head.participant(&participant.id).is_some() {
                return Err(Reject::DuplicateParticipant);
            }
            if head.participants.len() >= MAX_PARTICIPANTS {
                return Err(Reject::InvalidParticipant);
            }
            next.participants.push(participant.clone());
            next.updated_at = now.to_string();
            let conversation = Box::new(summary(&next, request.last_message));
            (None, Change::Conversation { conversation })
        }
        Op::TitleSet { title } => {
            validate_title(title)?;
            next.title = title.clone();
            next.updated_at = now.to_string();
            let conversation = Box::new(summary(&next, request.last_message));
            (None, Change::Conversation { conversation })
        }
    };
    Ok(Commit { head: next, message, change })
}

fn updated(message: Message) -> (Option<Message>, Change) {
    let change = Change::MessageUpdated { message: message.clone() };
    (Some(message), change)
}

fn target(
    head: &ConversationHead,
    request: &OpRequest<'_>,
    message_id: &str,
) -> Result<Message, Reject> {
    request
        .target
        .filter(|message| message.id == message_id && message.conversation == head.id)
        .cloned()
        .ok_or(Reject::UnknownMessage)
}

fn require_participant(head: &ConversationHead, actor: &str) -> Result<(), Reject> {
    if head.participant(actor).is_some() { Ok(()) } else { Err(Reject::NotParticipant) }
}

/// An opaque client token (idempotency key, `client_msg_id`): 1 to 128
/// printable ASCII characters.
pub fn valid_token(token: &str) -> bool {
    !token.is_empty() && token.len() <= 128 && token.bytes().all(|byte| byte.is_ascii_graphic())
}

/// `user_<id>` or `agent_<name>`, where the suffix is 1 to 64 characters of
/// ASCII letters, digits, `_`, `.` or `-`.
pub fn valid_participant_id(id: &str) -> bool {
    let suffix = id.strip_prefix("user_").or_else(|| id.strip_prefix("agent_"));
    suffix.is_some_and(|suffix| {
        !suffix.is_empty()
            && suffix.len() <= 64
            && suffix
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    })
}

fn validate_title(title: &str) -> Result<(), Reject> {
    let count = title.chars().count();
    if count == 0 || count > MAX_TITLE_CHARS || title.chars().any(char::is_control) {
        return Err(Reject::InvalidTitle);
    }
    Ok(())
}

fn validate_participant(participant: &Participant) -> Result<(), Reject> {
    let prefix_matches = match participant.kind {
        ParticipantKind::Human => {
            participant.id.starts_with("user_") && participant.agent_class.is_none()
        }
        ParticipantKind::Agent => participant.id.starts_with("agent_"),
    };
    let name_chars = participant.display_name.chars().count();
    let valid = valid_participant_id(&participant.id)
        && prefix_matches
        && name_chars > 0
        && name_chars <= MAX_DISPLAY_NAME_CHARS
        && !participant.display_name.chars().any(char::is_control)
        && participant.acp_session.as_deref().is_none_or(|session| {
            !session.is_empty()
                && session.len() <= 256
                && session.bytes().all(|byte| byte.is_ascii_graphic())
        });
    if valid { Ok(()) } else { Err(Reject::InvalidParticipant) }
}

fn validate_reaction(reaction: &ReactionKind) -> Result<(), Reject> {
    match reaction {
        ReactionKind::Tapback(_) => Ok(()),
        ReactionKind::Emoji(emoji) => {
            if emoji.is_empty()
                || emoji.len() > MAX_EMOJI_BYTES
                || emoji
                    .chars()
                    .any(|character| character.is_control() || character.is_whitespace())
            {
                Err(Reject::InvalidReaction)
            } else {
                Ok(())
            }
        }
    }
}

fn valid_short_text(value: &str, max_bytes: usize) -> bool {
    !value.is_empty() && value.len() <= max_bytes && !value.chars().any(char::is_control)
}

fn validate_parts(parts: &[Part]) -> Result<(), Reject> {
    if parts.is_empty() || parts.len() > MAX_PARTS {
        return Err(Reject::InvalidParts);
    }
    let mut text_bytes = 0_usize;
    for part in parts {
        match part {
            Part::Text { text, runs } => {
                if text.is_empty() {
                    return Err(Reject::InvalidParts);
                }
                text_bytes += text.len();
                if text_bytes > MAX_TEXT_BYTES {
                    return Err(Reject::InvalidParts);
                }
                if let Some(runs) = runs {
                    let utf16_len = text.encode_utf16().count() as u64;
                    if runs.len() > MAX_TEXT_RUNS {
                        return Err(Reject::InvalidParts);
                    }
                    for run in runs {
                        let end = u64::from(run.start) + u64::from(run.length);
                        let mention_ok = run.mention.as_deref().is_none_or(valid_participant_id);
                        let link_ok =
                            run.link.as_deref().is_none_or(|link| valid_short_text(link, 2048));
                        if run.length == 0 || end > utf16_len || !mention_ok || !link_ok {
                            return Err(Reject::InvalidParts);
                        }
                    }
                }
            }
            Part::Work { session, host, preview, .. } => {
                let valid = valid_short_text(session, 256)
                    && host.as_deref().is_none_or(|host| valid_short_text(host, 256))
                    && preview.as_deref().is_none_or(|preview| preview.len() <= MAX_PREVIEW_BYTES);
                if !valid {
                    return Err(Reject::InvalidParts);
                }
            }
        }
    }
    Ok(())
}
