//! The owners' wire rows as the daemon sends them (CmuxNextDaemon `Conversations/` and
//! `CloudConversations/`): snake_case, read leniently where the Swift decoders are.
//!
//! cmux-conversation (`src/types.rs`) models the same rows on the daemon side; this crate takes no
//! dependency on it, so these are the read-only subset the mapping needs.

use super::lenient;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// `ConversationParticipant`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Participant {
    pub id: String,
    /// `human`, `agent` or `address`.
    pub kind: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_class: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acp_session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_user: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub left_at: Option<String>,
}

/// `ConversationTextRun`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextRun {
    pub start: i64,
    pub length: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mention: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
}

/// `ConversationDerivedImage`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DerivedImage {
    pub hash: String,
    pub mime_type: String,
    pub byte_count: i64,
}

/// `ConversationAttachment`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    pub hash: String,
    pub name: String,
    pub mime_type: String,
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

/// `StoredConversationAttachment`: what the owner stored for an upload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredAttachment {
    pub hash: String,
    pub mime_type: String,
    pub byte_count: i64,
    #[serde(default)]
    pub poster: Option<DerivedImage>,
    #[serde(default)]
    pub preview: Option<DerivedImage>,
}

/// `ConversationLinkPreview`.
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

/// `ConversationPart`, tagged by `type`.
#[derive(Debug, Clone, PartialEq)]
pub enum Part {
    Text {
        text: String,
        runs: Vec<TextRun>,
    },
    Work {
        session: String,
        host: Option<String>,
        status: String,
        preview: Option<String>,
    },
    Attachment(Attachment),
    LinkPreview(LinkPreview),
    /// A part this build does not know: its type and the whole object.
    Unknown {
        kind: String,
        payload: Value,
    },
}

impl Part {
    /// `ConversationPart.plainText`.
    pub fn plain_text(&self) -> String {
        match self {
            Part::Text { text, .. } => text.clone(),
            Part::Work { session, status, preview, .. } => {
                preview.clone().unwrap_or_else(|| format!("{session} {status}"))
            }
            Part::Attachment(attachment) => attachment.name.clone(),
            Part::LinkPreview(link) => link.title.clone().unwrap_or_else(|| link.url.clone()),
            Part::Unknown { kind, payload } => match payload.get("url") {
                Some(Value::String(url)) if !url.is_empty() => url.clone(),
                _ => kind.clone(),
            },
        }
    }
}

fn decode<'de, D: serde::Deserializer<'de>, T: serde::de::DeserializeOwned>(
    value: Value,
) -> Result<T, D::Error> {
    use serde::de::Error;
    serde_json::from_value(value).map_err(D::Error::custom)
}

impl<'de> Deserialize<'de> for Part {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let value = Value::deserialize(deserializer)?;
        let kind = value
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| D::Error::custom("a part without a type"))?
            .to_string();
        let field = |name: &str| value.get(name).cloned().unwrap_or(Value::Null);
        Ok(match kind.as_str() {
            "text" => Part::Text {
                text: decode::<D, _>(field("text"))?,
                runs: match field("runs") {
                    Value::Null => Vec::new(),
                    runs => decode::<D, _>(runs)?,
                },
            },
            "work" => Part::Work {
                session: decode::<D, _>(field("session"))?,
                host: decode::<D, _>(field("host"))?,
                status: decode::<D, _>(field("status"))?,
                preview: decode::<D, _>(field("preview"))?,
            },
            "attachment" => Part::Attachment(decode::<D, _>(value)?),
            "link_preview" => Part::LinkPreview(decode::<D, _>(value)?),
            _ => Part::Unknown { kind, payload: value },
        })
    }
}

impl Serialize for Part {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::Error;
        let with_type = |kind: &str, body: Value| -> Value {
            let mut object = Map::new();
            object.insert("type".into(), Value::String(kind.into()));
            if let Value::Object(fields) = body {
                object.extend(fields);
            }
            Value::Object(object)
        };
        let value = match self {
            Part::Text { text, runs } => {
                let mut object = Map::new();
                object.insert("type".into(), "text".into());
                object.insert("text".into(), text.clone().into());
                if !runs.is_empty() {
                    object.insert(
                        "runs".into(),
                        serde_json::to_value(runs).map_err(S::Error::custom)?,
                    );
                }
                Value::Object(object)
            }
            Part::Work { session, host, status, preview } => {
                let mut object = Map::new();
                object.insert("type".into(), "work".into());
                object.insert("session".into(), session.clone().into());
                if let Some(host) = host {
                    object.insert("host".into(), host.clone().into());
                }
                object.insert("status".into(), status.clone().into());
                if let Some(preview) = preview {
                    object.insert("preview".into(), preview.clone().into());
                }
                Value::Object(object)
            }
            Part::Attachment(a) => {
                with_type("attachment", serde_json::to_value(a).map_err(S::Error::custom)?)
            }
            Part::LinkPreview(l) => {
                with_type("link_preview", serde_json::to_value(l).map_err(S::Error::custom)?)
            }
            Part::Unknown { payload, .. } => payload.clone(),
        };
        value.serialize(serializer)
    }
}

/// `ConversationReactionKind`: `{"tapback": ...}` or `{"emoji": ...}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReactionKind {
    Tapback(String),
    Emoji(String),
}

/// `ConversationReaction`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reaction {
    pub author: String,
    #[serde(default)]
    pub part_index: i64,
    pub kind: ReactionKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<String>,
}

/// `ConversationPartRef`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartRef {
    pub message_id: String,
    pub part_index: i64,
}

/// `ConversationThreadObject.Resolved`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resolved {
    pub by: String,
    #[serde(default)]
    pub at: Option<String>,
    #[serde(default)]
    pub seq: Option<u64>,
}

/// `ConversationThreadObject`: a thread's title, owner and resolution, on its root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadObject {
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub resolved: Option<Resolved>,
}

/// `ConversationMessage`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub conversation: String,
    pub seq: u64,
    pub client_msg_id: String,
    pub author: String,
    pub parts: Vec<Part>,
    pub created_at: String,
    #[serde(default)]
    pub edited_at: Option<String>,
    #[serde(default)]
    pub retracted_at: Option<String>,
    #[serde(default)]
    pub reactions: Vec<Reaction>,
    #[serde(default)]
    pub reply_to: Option<PartRef>,
    #[serde(default)]
    pub thread_root: Option<String>,
    #[serde(default)]
    pub thread: Option<ThreadObject>,
}

/// `ConversationSummary.Settings`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default, deserialize_with = "lenient")]
    pub wake_policy: Option<String>,
}

/// `ConversationSummary`: a conversation's head.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Summary {
    pub id: String,
    #[serde(default = "local_owner")]
    pub owner: String,
    pub title: String,
    pub participants: Vec<Participant>,
    pub last_seq: u64,
    pub rev: u64,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default)]
    pub last_message: Option<Message>,
    #[serde(default)]
    pub read_cursors: BTreeMap<String, u64>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub member_count: Option<i64>,
    /// `settings` read with `try?`: a wrong shape is no settings.
    #[serde(default, deserialize_with = "lenient")]
    pub settings: Option<Settings>,
    #[serde(default)]
    pub channel_chief: Option<String>,
}

fn local_owner() -> String {
    "local".into()
}

/// `ConversationThreadSummary`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadSummary {
    pub root: String,
    pub reply_count: i64,
    #[serde(default)]
    pub last_reply_seq: Option<u64>,
    #[serde(default)]
    pub last_reply_at: Option<String>,
    #[serde(default)]
    pub authors: Vec<String>,
}

/// `ConversationThread`: one thread page.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ThreadPage {
    pub root: Message,
    pub replies: Vec<Message>,
    #[serde(default)]
    pub has_more: bool,
    pub thread: ThreadSummary,
}

/// `CloudInboxEntry`: the account's own row for a cloud conversation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxEntry {
    pub conversation: String,
    pub rev: u64,
    #[serde(default = "group_kind")]
    pub kind: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub last_seq: u64,
    #[serde(default)]
    pub last_at: String,
    #[serde(default)]
    pub preview: String,
    #[serde(default)]
    pub dm_peer: Option<String>,
    #[serde(default)]
    pub removed: bool,
    #[serde(default)]
    pub unread: u64,
    #[serde(default)]
    pub mentions: u64,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub pin_position: Option<i64>,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub muted_until: Option<u64>,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub marked_unread: bool,
}

fn group_kind() -> String {
    "group".into()
}
