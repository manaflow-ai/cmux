//! Wire types (plans/cmux-next/home.md section 2). Every field is
//! snake_case; optional fields are omitted when absent.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ParticipantKind {
    Human,
    Agent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentClass {
    Mux,
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Participant {
    /// `user_local`, `user_<id>` or `agent_<name>`.
    pub id: String,
    pub kind: ParticipantKind,
    pub display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_class: Option<AgentClass>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acp_session: Option<String>,
    /// The person a `remote_<install>` device participant belongs to
    /// (`user_local`): a paired device is the same human as the server's own
    /// user (server-remote-conversations.md section 5, decisions D-B, D-C).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person: Option<String>,
}

/// Where a message came from. Absent for local messages.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Origin {
    /// Sent by a paired install through the remote relay.
    Remote { install: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartRef {
    pub message_id: String,
    pub part_index: u32,
}

/// A styled range of a text part, in UTF-16 code units.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextRun {
    pub start: u32,
    pub length: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mention: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkStatus {
    Running,
    Done,
    Failed,
    Waiting,
}

/// A derived image of an attachment (a video's poster, an image's preview):
/// JPEG or WebP bytes stored by their SHA-256 next to the attachment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DerivedImage {
    pub hash: String,
    pub mime_type: String,
    pub byte_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Part {
    Text {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        runs: Option<Vec<TextRun>>,
    },
    Work {
        session: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        host: Option<String>,
        status: WorkStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        preview: Option<String>,
    },
    /// A file stored by content hash (attachments.rs). The owner commits it
    /// only when this conversation holds a record of the hash with the same
    /// type and size (and the same poster or preview).
    Attachment {
        /// SHA-256 of the bytes, 64 lowercase hex characters.
        hash: String,
        name: String,
        mime_type: String,
        byte_count: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        width: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        height: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        duration_ms: Option<u64>,
        /// Video only.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        poster: Option<DerivedImage>,
        /// Image only.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        preview: Option<DerivedImage>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tapback {
    Love,
    Like,
    Dislike,
    Laugh,
    Emphasize,
    Question,
}

/// `{"tapback": "love"}` or `{"emoji": "🎉"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReactionKind {
    Tapback(Tapback),
    Emoji(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reaction {
    pub author: String,
    pub part_index: u32,
    pub kind: ReactionKind,
    pub at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub conversation: String,
    /// 1-based and dense per conversation.
    pub seq: u64,
    pub client_msg_id: String,
    pub author: String,
    pub parts: Vec<Part>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<PartRef>,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retracted_at: Option<String>,
    #[serde(default)]
    pub reactions: Vec<Reaction>,
    /// Set by the owner for a message a paired install sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<Origin>,
}

/// The conversation state every op validates against: everything in a
/// [`Summary`] except the owner kind and the last message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConversationHead {
    pub id: String,
    pub title: String,
    pub participants: Vec<Participant>,
    pub last_seq: u64,
    /// Increases by exactly one per committed op.
    pub rev: u64,
    pub created_at: String,
    pub updated_at: String,
    pub read_cursors: BTreeMap<String, u64>,
    /// Agent text messages since the last human text message: the loop guard
    /// (budget.rs). Always on the wire, as the cloud head has it.
    #[serde(default)]
    pub agent_text_streak: u32,
    /// When the last agent text message was sent (RFC 3339 UTC, milliseconds).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_agent_text_at: Option<String>,
}

impl ConversationHead {
    pub fn participant(&self, id: &str) -> Option<&Participant> {
        self.participants.iter().find(|participant| participant.id == id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Summary {
    pub id: String,
    pub owner: String,
    pub title: String,
    pub participants: Vec<Participant>,
    pub last_seq: u64,
    pub rev: u64,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_message: Option<Message>,
    pub read_cursors: BTreeMap<String, u64>,
}

/// One conversation op, tagged by `kind`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum Op {
    #[serde(rename = "message.send")]
    MessageSend {
        client_msg_id: String,
        parts: Vec<Part>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply_to: Option<PartRef>,
    },
    #[serde(rename = "message.edit")]
    MessageEdit { message_id: String, parts: Vec<Part> },
    #[serde(rename = "message.retract")]
    MessageRetract { message_id: String },
    #[serde(rename = "reaction.add")]
    ReactionAdd { message_id: String, part_index: u32, reaction: ReactionKind },
    #[serde(rename = "reaction.remove")]
    ReactionRemove { message_id: String, part_index: u32, reaction: ReactionKind },
    #[serde(rename = "read_cursor.set")]
    ReadCursorSet { seq: u64 },
    #[serde(rename = "participants.add")]
    ParticipantsAdd { participant: Participant },
    #[serde(rename = "title.set")]
    TitleSet { title: String },
}

impl Op {
    /// The existing message this op changes, which the host loads.
    pub fn target_message_id(&self) -> Option<&str> {
        match self {
            Self::MessageEdit { message_id, .. }
            | Self::MessageRetract { message_id }
            | Self::ReactionAdd { message_id, .. }
            | Self::ReactionRemove { message_id, .. } => Some(message_id),
            Self::MessageSend { .. }
            | Self::ReadCursorSet { .. }
            | Self::ParticipantsAdd { .. }
            | Self::TitleSet { .. } => None,
        }
    }

    /// The message a `message.send` replies to, which the host loads.
    pub fn reply_to(&self) -> Option<&PartRef> {
        match self {
            Self::MessageSend { reply_to, .. } => reply_to.as_ref(),
            _ => None,
        }
    }

    /// True for `message.send`, which needs a new message id.
    pub fn is_send(&self) -> bool {
        matches!(self, Self::MessageSend { .. })
    }
}

/// What a committed op changed, carried by `conversation-changed`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Change {
    /// A new message.
    Message {
        message: Message,
    },
    /// An edited or retracted message, or one whose reactions changed.
    MessageUpdated {
        message: Message,
    },
    ReadCursor {
        participant: String,
        seq: u64,
    },
    /// Conversation metadata (title, participants) changed, or it was created.
    Conversation {
        conversation: Box<Summary>,
    },
}
