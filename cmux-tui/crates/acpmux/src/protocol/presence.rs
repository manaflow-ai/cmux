//! Chat multiplayer presence (`hub/presence.rs`): `_acpmux/typing`, the author a request may
//! name, and the `_acpmux/presence` notification, which `_acpmux/attach` also answers.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::require_all;

/// The person a request comes from (`hub/author.rs`): stamped by the daemon that admitted
/// them, and accepted only from the unix socket or a peer forwarding for its own.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct Author {
    /// `tailnet:<login>` until accounts are mapped, then `user_…`; one line of at most 256 bytes.
    pub id: String,
    /// One line of 1 to 64 characters.
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub login: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub node: Option<String>,
    /// A link guest's prompts wait for the chat owner's approval.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval: Option<AuthorApproval>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum AuthorApproval {
    Owner,
}

/// `_meta.acpmux` of a request that may name its person; other fields pass.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AuthorMetaFields {
    /// None: the chat's owner.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<Author>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct AuthorMeta {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub acpmux: Option<AuthorMetaFields>,
}

/// `_acpmux/typing`: at most 2 a second per connection (`typing.rate_limited`); an `on`
/// lapses after 8 s. The connection must be attached to the chat.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct TypingParams {
    pub session_id: String,
    pub on: bool,
    #[serde(rename = "_meta", skip_serializing_if = "Option::is_none")]
    pub meta: Option<AuthorMeta>,
}

/// `_acpmux/rooms` (RFD 0141 phase 2): every room the client shows now, replacing the set it
/// named before; both empty unsubscribes. A chat must be attached on this connection.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct RoomsParams {
    #[serde(default)]
    pub chats: Vec<String>,
    #[serde(default)]
    pub workspaces: Vec<String>,
}

/// `_acpmux/rooms`'s answer: how many rooms the connection watches now.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct RoomsResult {
    pub rooms: u64,
}

/// `_acpmux/follow` (RFD 0141 phase 3): follow the person `target` (an id live in a chat on this
/// daemon, never the caller's own), or nobody (`null`). The caller's rooms hear it as the
/// record's `following`. Refusals: `presence.follow_not_live`, `presence.follow_self`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct FollowParams {
    #[serde(default)]
    pub target: Option<String>,
    #[serde(rename = "_meta", skip_serializing_if = "Option::is_none")]
    pub meta: Option<AuthorMeta>,
}

/// `_acpmux/follow`'s answer: whom the caller follows now.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FollowResult {
    pub following: Option<String>,
}

/// `_acpmux/room`: one watched room's snapshot (`snapshot: true`, `presence` every record) or
/// one change of it (`presence` the records that joined, `deltas` one `cmux-presence` delta per
/// record that stayed, `left` the ids that went).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct RoomNote {
    /// `{chat: id}` or `{workspace: id}`.
    pub room: serde_json::Value,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub snapshot: bool,
    pub presence: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub deltas: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub left: Vec<String>,
}

/// One person in a chat. The hub never marks the caller's own entry: a connection may carry
/// several people, so the client compares ids (a caller with no author is `owner`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct Participant {
    pub id: String,
    pub name: String,
    /// How many connections carry this person in the chat.
    pub devices: u64,
    pub viewing: bool,
    pub typing: bool,
}

/// `_acpmux/presence`, to every connection attached to the chat on each change, and
/// `presence` in the `_acpmux/attach` reply. Never in the log, `_acpmux/events` or an export.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct PresenceNote {
    pub session_id: String,
    /// One per person, by id; at most 32 besides the owner.
    pub participants: Vec<Participant>,
}
