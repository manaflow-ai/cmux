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
