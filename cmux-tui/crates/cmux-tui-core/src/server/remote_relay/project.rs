//! Remote-only projections (server-remote-conversations.md section 8). The
//! remote writer serializes these structs, never the local types with fields
//! removed, so a field added to a local type cannot reach a remote peer.
//! Not projected: `acp_session`, `work` parts (`session`, `host`, `preview`
//! can carry secrets), `client_msg_id`, `owner`, `created_at` of the
//! conversation, the agent loop guard, and the read cursors of other
//! participants (the peer gets only its own).

use cmux_conversation::{Change, Message, Part, PartRef, Participant, Reaction, Summary};
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteParticipant {
    pub id: String,
    pub kind: cmux_conversation::ParticipantKind,
    pub display_name: String,
}

/// A styled range of a text part (UTF-16 code units). `link` is shown as
/// text and opened only by a user click on the peer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteTextRun {
    pub start: u32,
    pub length: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mention: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum RemotePart {
    Text {
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        runs: Option<Vec<RemoteTextRun>>,
    },
}

fn text_run(run: &cmux_conversation::TextRun) -> RemoteTextRun {
    RemoteTextRun {
        start: run.start,
        length: run.length,
        mention: run.mention.clone(),
        link: run.link.clone(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteReplyTo {
    pub message_id: String,
    pub part_index: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteReaction {
    pub author: String,
    pub part_index: u32,
    pub kind: cmux_conversation::ReactionKind,
    pub at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteMessage {
    pub id: String,
    pub seq: u64,
    pub author: String,
    /// Text parts only; a work part is not projected.
    pub parts: Vec<RemotePart>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<RemoteReplyTo>,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retracted_at: Option<String>,
    pub reactions: Vec<RemoteReaction>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<cmux_conversation::Origin>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteSummary {
    pub id: String,
    pub title: String,
    pub participants: Vec<RemoteParticipant>,
    pub last_seq: u64,
    pub rev: u64,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_message: Option<RemoteMessage>,
    /// The peer's own read cursor only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub read_cursor: Option<u64>,
}

fn participant(participant: &Participant) -> RemoteParticipant {
    RemoteParticipant {
        id: participant.id.clone(),
        kind: participant.kind,
        display_name: participant.display_name.clone(),
    }
}

fn part(part: &Part) -> Option<RemotePart> {
    match part {
        Part::Text { text, runs } => Some(RemotePart::Text {
            text: text.clone(),
            runs: runs.as_ref().map(|runs| runs.iter().map(text_run).collect()),
        }),
        Part::Work { .. } => None,
    }
}

fn reply_to(reply_to: &PartRef) -> RemoteReplyTo {
    RemoteReplyTo { message_id: reply_to.message_id.clone(), part_index: reply_to.part_index }
}

fn reaction(reaction: &Reaction) -> RemoteReaction {
    RemoteReaction {
        author: reaction.author.clone(),
        part_index: reaction.part_index,
        kind: reaction.kind.clone(),
        at: reaction.at.clone(),
    }
}

pub(crate) fn message(message: &Message) -> RemoteMessage {
    RemoteMessage {
        id: message.id.clone(),
        seq: message.seq,
        author: message.author.clone(),
        parts: message.parts.iter().filter_map(part).collect(),
        reply_to: message.reply_to.as_ref().map(reply_to),
        created_at: message.created_at.clone(),
        edited_at: message.edited_at.clone(),
        retracted_at: message.retracted_at.clone(),
        reactions: message.reactions.iter().map(reaction).collect(),
        origin: message.origin.clone(),
    }
}

/// The summary for peer participant `viewer`.
pub(crate) fn summary(summary: &Summary, viewer: &str) -> RemoteSummary {
    RemoteSummary {
        id: summary.id.clone(),
        title: summary.title.clone(),
        participants: summary.participants.iter().map(participant).collect(),
        last_seq: summary.last_seq,
        rev: summary.rev,
        updated_at: summary.updated_at.clone(),
        last_message: summary.last_message.as_ref().map(message),
        read_cursor: summary.read_cursors.get(viewer).copied(),
    }
}

/// The remote form of a `conversation-changed` change for `viewer`, or
/// `None` when the peer must not see it (another participant's cursor, or a
/// change that does not decode).
pub(crate) fn change(change: &Value, viewer: &str) -> Option<Value> {
    let change: Change = serde_json::from_value(change.clone()).ok()?;
    let value = match change {
        Change::Message { message: m } => {
            serde_json::json!({"kind": "message", "message": message(&m)})
        }
        Change::MessageUpdated { message: m } => {
            serde_json::json!({"kind": "message-updated", "message": message(&m)})
        }
        Change::ReadCursor { participant, seq } if participant == viewer => {
            serde_json::json!({"kind": "read-cursor", "participant": participant, "seq": seq})
        }
        Change::ReadCursor { .. } => return None,
        Change::Conversation { conversation } => {
            serde_json::json!({"kind": "conversation", "conversation": summary(&conversation, viewer)})
        }
    };
    Some(value)
}
