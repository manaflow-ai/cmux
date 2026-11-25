//! Chat state through the sync engine (`hub/synced.rs`): `_acpmux/sync/pull`, the edits a replica
//! lacks since its version vector, and `_acpmux/sync/push`, a replica's edits merged into this
//! daemon's. Keys are `title/<sessionId>` (a string) and `read/<sessionId>` (true read, false
//! unread). The delta is `cmux_sync::Delta` as JSON: `{since, covers, entries}`.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::require_all;

/// `_acpmux/sync/pull`: send the version vector you hold (an object of actor to sequence; none
/// or `{}` for everything). The answer holds only the edits you lack, so a replica ten edits
/// behind gets about ten entries however many chats there are.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct SyncPullParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vv: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct SyncPullResult {
    /// This daemon's replica id: the actor its own edits carry.
    pub actor: String,
    /// The edits the caller lacks (`{since, covers, entries}`).
    pub delta: Value,
    /// What this daemon covers after them: send it back as `vv` next time.
    pub vv: Value,
}

/// `_acpmux/sync/push`: a delta from another replica (a phone, the Mac, a VM), merged here in any
/// order, any number of times. A title or read mark that wins is applied to the chat as a rename
/// or a mark would be.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct SyncPushParams {
    pub delta: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct SyncPushDone {
    /// The keys whose value changed here.
    pub changed: Vec<String>,
    /// This daemon did not cover the delta's `since`: entries merged, but pull to fill the rest.
    pub gap: bool,
    /// What this daemon covers now: the pusher's edits it covers are acked.
    pub vv: Value,
}
