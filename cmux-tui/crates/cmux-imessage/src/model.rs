use serde::Serialize;

/// One conversation: a 1:1 chat or a group chat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct Thread {
    /// `chat.ROWID`, the id the other calls take.
    pub chat_id: i64,
    /// `chat.guid`, stable across launches (`iMessage;-;+15551234567`, `iMessage;+;chat123...`).
    pub guid: String,
    /// The group's name when it has one, else the participants' handles joined by ", ".
    pub title: String,
    /// The group's own name (`chat.display_name`), when set.
    pub display_name: Option<String>,
    pub is_group: bool,
    /// `iMessage`, `SMS`, `RCS`, ...
    pub service: Option<String>,
    /// Participants' handles (phone numbers or emails), sorted, without the Mac's own account.
    pub participants: Vec<String>,
    pub last_message: Option<ThreadPreview>,
}

/// The newest message of a thread, for the list row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct ThreadPreview {
    pub rowid: i64,
    pub text: Option<String>,
    pub is_from_me: bool,
    pub sender: Option<String>,
    pub date_ms: Option<i64>,
    pub has_attachments: bool,
}

/// One message of a conversation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct Message {
    /// `message.ROWID`; increases with arrival, so it is the paging and live-update watermark.
    pub rowid: i64,
    pub guid: String,
    pub chat_id: i64,
    /// The sender's handle; `None` for the Mac's own messages.
    pub sender: Option<String>,
    pub is_from_me: bool,
    pub date_ms: Option<i64>,
    /// The text: `message.text`, or decoded from `attributedBody` when that column is empty.
    pub text: Option<String>,
    pub attachments: Vec<Attachment>,
    /// The sender edited it after sending (`date_edited`); `text` is the latest version.
    pub edited: bool,
    /// The sender unsent it (`date_retracted`); `text` is then `None`.
    pub unsent: bool,
}

/// An attachment's metadata. The mirror never copies the file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct Attachment {
    pub name: Option<String>,
    pub mime_type: Option<String>,
}
