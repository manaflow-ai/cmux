//! The shared Home core's rows (CmuxHomeCore `Participant`, `MessagePart`, `Message`,
//! `ConversationSummary`, ...) in the shape Swift's synthesized `Codable` writes and reads: enum cases
//! as `{"case": {"_0": ...}}`, ids as plain strings, dates as seconds since 1970, a dictionary keyed by
//! an id as an alternating `[key, value, ...]` array, nil optionals left out.
//!
//! `ThreadSummary`, `ThreadPage` and `HistoryPage` are not `Codable` in Swift; their rows here are this
//! area's own camelCase shape.

use serde::ser::SerializeSeq;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

/// `Participant`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Participant {
    pub id: String,
    /// `human` or `agent`.
    pub kind: String,
    pub display_name: String,
    /// `chief` or `agent`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_class: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_user: Option<String>,
    /// `active` or `invited`.
    #[serde(default = "active")]
    pub membership: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invited_contact: Option<String>,
    /// `owner`, `admin`, `member` or `read_only`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
}

fn active() -> String {
    "active".into()
}

impl Participant {
    pub fn new(id: String, kind: &str, display_name: String, agent_class: Option<&str>) -> Self {
        Self {
            id,
            kind: kind.into(),
            display_name,
            agent_class: agent_class.map(Into::into),
            owner_user: None,
            membership: active(),
            invited_contact: None,
            role: None,
        }
    }
}

/// `Mention`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mention {
    pub start: i64,
    pub length: i64,
    pub participant: String,
}

/// `WorkRef`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkRef {
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    pub title: String,
    /// `running`, `waiting`, `done` or `failed`.
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
}

/// `AttachmentDerivedImage` (snake_case keys, as Swift's `CodingKeys` name them).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DerivedImage {
    pub hash: String,
    pub mime_type: String,
    pub byte_count: i64,
}

/// `AttachmentRef`. Swift also reads the legacy `mimeType`/`byteCount` keys.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentRef {
    pub hash: String,
    pub name: String,
    #[serde(alias = "mimeType")]
    pub mime_type: String,
    #[serde(alias = "byteCount")]
    pub byte_count: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<DerivedImage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<DerivedImage>,
}

/// `LinkPreview`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkPreview {
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub site: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<DerivedImage>,
}

/// `MessagePart`. The approval, question and location cases are kept whole (their shapes are the
/// Home core's own; this area only passes them through).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MessagePart {
    Text {
        #[serde(rename = "_0")]
        text: String,
        #[serde(default)]
        mentions: Vec<Mention>,
    },
    Work {
        #[serde(rename = "_0")]
        work: WorkRef,
    },
    Approval {
        #[serde(rename = "_0")]
        approval: Value,
    },
    Question {
        #[serde(rename = "_0")]
        question: Value,
    },
    Attachment {
        #[serde(rename = "_0")]
        attachment: AttachmentRef,
    },
    LinkPreview {
        #[serde(rename = "_0")]
        link: LinkPreview,
    },
    Location {
        #[serde(rename = "_0")]
        location: Value,
    },
}

impl MessagePart {
    pub fn text(text: impl Into<String>) -> Self {
        MessagePart::Text { text: text.into(), mentions: Vec::new() }
    }
}

/// `Reaction.Kind`: `{"tapback": {"_0": "love"}}` or `{"emoji": {"_0": "🎉"}}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReactionKind {
    Tapback {
        #[serde(rename = "_0")]
        tapback: String,
    },
    Emoji {
        #[serde(rename = "_0")]
        emoji: String,
    },
}

/// `Reaction.Tapback`'s raw values.
pub const TAPBACKS: &[&str] = &["love", "like", "dislike", "laugh", "emphasize", "question"];

/// `Reaction`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reaction {
    pub author: String,
    pub part_index: i64,
    pub kind: ReactionKind,
}

/// `PartRef`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PartRef {
    pub message: String,
    pub part_index: i64,
}

/// `ThreadInfo`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_at_seq: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_by: Option<String>,
}

/// A question part the owner sent: Swift builds the `AgentQuestion` (CmuxAgentQuestion) from the
/// payload and puts it at `partIndex`; until it does the part reads `question`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireQuestion {
    pub part_index: usize,
    pub payload: Value,
}

/// `Message`. `wireQuestions` is this area's side field (Swift's decoder skips unknown keys).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub conversation: String,
    pub seq: u64,
    #[serde(rename = "clientMessageID")]
    pub client_message_id: String,
    pub author: String,
    pub parts: Vec<MessagePart>,
    pub created_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retracted_at: Option<f64>,
    pub reactions: Vec<Reaction>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<PartRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_root: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread: Option<ThreadInfo>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub wire_questions: Vec<WireQuestion>,
}

/// `ConversationSummary`: the fields the mappings set; the rest at their Swift defaults.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub id: String,
    /// `cloud` or `local`.
    pub owner: String,
    pub title: String,
    pub participants: Vec<Participant>,
    pub last_seq: u64,
    pub rev: u64,
    pub created_at: f64,
    pub updated_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_message: Option<Message>,
    #[serde(serialize_with = "pairs")]
    pub read_cursors: Vec<(String, u64)>,
    #[serde(serialize_with = "pairs")]
    pub read_cursor_times: Vec<(String, f64)>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pin_rank: Option<i64>,
    pub muted: bool,
    pub mention_count: i64,
    /// `chief`, `direct` or `group`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub declared_kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub member_count: Option<i64>,
    /// `ChiefReplyPolicy`: `auto`, `mentions` or `all`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chief_replies: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel_chief: Option<String>,
}

/// A Swift dictionary whose key is not `String` or `Int`: `[key, value, key, value, ...]`.
fn pairs<S: Serializer, V: Serialize>(
    pairs: &[(String, V)],
    serializer: S,
) -> Result<S::Ok, S::Error> {
    let mut seq = serializer.serialize_seq(Some(pairs.len() * 2))?;
    for (key, value) in pairs {
        seq.serialize_element(key)?;
        seq.serialize_element(value)?;
    }
    seq.end()
}

/// Reads a Swift `[ParticipantID: V]` (alternating array), or a JSON object.
pub fn read_pairs<'de, D: Deserializer<'de>, V: serde::de::DeserializeOwned>(
    deserializer: D,
) -> Result<Vec<(String, V)>, D::Error> {
    use serde::de::Error;
    match Value::deserialize(deserializer)? {
        Value::Array(items) => {
            if items.len() % 2 != 0 {
                return Err(D::Error::custom("an odd key-value array"));
            }
            items
                .chunks(2)
                .map(|pair| {
                    let key = pair[0]
                        .as_str()
                        .ok_or_else(|| D::Error::custom("a key that is not text"))?;
                    let value =
                        serde_json::from_value(pair[1].clone()).map_err(D::Error::custom)?;
                    Ok((key.to_string(), value))
                })
                .collect()
        }
        Value::Object(map) => map
            .into_iter()
            .map(|(key, value)| Ok((key, serde_json::from_value(value).map_err(D::Error::custom)?)))
            .collect(),
        Value::Null => Ok(Vec::new()),
        _ => Err(D::Error::custom("a dictionary that is neither an array nor an object")),
    }
}

/// `ThreadSummary` (this area's row).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSummary {
    pub root: String,
    pub reply_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_reply_seq: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_reply_at: Option<f64>,
    pub authors: Vec<String>,
}

/// `ThreadPage` (this area's row).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPage {
    pub root: Message,
    pub replies: Vec<Message>,
    pub has_more: bool,
    pub summary: ThreadSummary,
}

/// `HistoryPage` (this area's row).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HistoryPage {
    pub messages: Vec<Message>,
    pub threads: Vec<ThreadSummary>,
}

/// `ConversationPage` (this area's row).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ConversationPage {
    pub conversation: Summary,
    pub messages: Vec<Message>,
    pub threads: Vec<ThreadSummary>,
}
