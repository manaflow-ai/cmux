//! Permission shapes: single answers, grouped batches
//! (`hub/permission_groups.rs`, docs/grouped-permissions.md) and the
//! `_acpmux/permission_pending` notification.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::require_all;

/// `_meta.acpmux` on an answer. Every field is optional; a relayed allow
/// carries the decision proof, the person's app may say whose answer it
/// relays, and a peer forwarding for its Web client says `via: "web"`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct AnswerMeta {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decision_nonce: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub person_decision: Option<String>,
    /// `{device, feedItem}`, from the person's connection only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answered_by: Option<AnsweredBy>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub via: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct AnsweredBy {
    pub device: String,
    pub feed_item: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct RequestMeta {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub acpmux: Option<AnswerMeta>,
    /// The app's gesture ticket for this exact pick (`transport.gesture`);
    /// the app's relay reads it, acpmux does not.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cmux_gesture: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct PermissionRespondParams {
    pub session_id: String,
    pub permission_id: String,
    /// The option chosen; absent cancels the request.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub option_id: Option<String>,
    /// A question's answers, by question.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answers: Option<Value>,
    /// Claude Code AskUserQuestion annotations beside the answers, by question text: `{preview?, notes?}`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub annotations: Option<Value>,
    #[serde(rename = "_meta", skip_serializing_if = "Option::is_none")]
    pub meta: Option<RequestMeta>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct PermissionRespondResult {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PermissionDecision {
    AllowOnce,
    AllowChat,
    Deny,
}

impl PermissionDecision {
    pub fn from_wire(text: &str) -> Option<Self> {
        Some(match text {
            "allow_once" => Self::AllowOnce,
            "allow_chat" => Self::AllowChat,
            "deny" => Self::Deny,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PermissionGroupState {
    Collecting,
    Pending,
    Resolved,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PermissionItemState {
    Pending,
    Resolved,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PermissionGroupItem {
    pub permission_id: String,
    /// The agent's `session/request_permission` params.
    #[schemars(with = "Map<String, Value>")]
    pub request: Value,
    #[schemars(with = "PermissionItemState")]
    pub state: &'static str,
}

/// A batch of permission requests from one turn, decided together.
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct PermissionGroup {
    pub group_id: String,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub revision: u64,
    #[schemars(with = "PermissionGroupState")]
    pub state: &'static str,
    pub items: Vec<PermissionGroupItem>,
    /// What a respond may choose: all three, or `deny` alone when a pending
    /// item has no single allow-once option.
    pub decisions: Vec<PermissionDecision>,
    /// The decision taken, once one was.
    pub decision: Option<PermissionDecision>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct PermissionGroupsParams {
    pub session_id: String,
    /// One group; absent lists them all. Never null.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(with = "String")]
    pub group_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ChatAllowance {
    pub active: bool,
    pub expires: AllowanceExpiry,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum AllowanceExpiry {
    SessionStopOrDaemonRestart,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum CoverageLabel {
    AcpRequestsOnly,
}

/// acpmux never claims host isolation.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Isolation {
    Unverified,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PermissionCoverage {
    pub label: CoverageLabel,
    pub isolation: Isolation,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PermissionBatching {
    pub window_ms: u64,
    pub max_items: u64,
    pub max_pending_groups: u64,
    pub max_receipts: u64,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PermissionGroupList {
    pub groups: Vec<PermissionGroup>,
    pub chat_allowance: ChatAllowance,
    pub coverage: PermissionCoverage,
    pub batching: PermissionBatching,
    /// Set when this reader's group allows would be refused, with the
    /// refusal's reason (`permission.person_required`: only the person
    /// allows a group, and a peer's link never is one). A deny still counts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allow_refused: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct PermissionGroupRespondParams {
    pub session_id: String,
    pub group_id: String,
    /// The group revision the decision was made on.
    pub revision: u64,
    /// 1 to 256 bytes; the same key with the same body replays the receipt.
    pub decision_key: String,
    pub decision: PermissionDecision,
    #[serde(rename = "_meta", skip_serializing_if = "Option::is_none")]
    pub meta: Option<RequestMeta>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct PermissionGroupReceipt {
    pub group: PermissionGroup,
    /// An earlier respond with the same key and body answered this.
    pub replayed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct PermissionChatRevokeParams {
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PermissionChatRevokeReceipt {
    /// Always false.
    pub active: bool,
}

/// To attached clients (and watchers not attached) when a permission or
/// question waits: the log record's message (the agent's request with
/// acpmux's `permissionId`) plus where it came from.
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PermissionPending {
    pub session_id: String,
    pub seq: u64,
    /// `attach` or `watch`.
    pub via: String,
    pub permission_id: String,
    /// The agent's `session/request_permission` params.
    #[schemars(with = "Map<String, Value>")]
    pub request: Value,
    /// Signs an allow relayed for the person (`hub/person.rs`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decision_nonce: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub person_instance: Option<String>,
    /// The batch it joined, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    /// Anything else the log record holds.
    #[serde(flatten)]
    pub record: Map<String, Value>,
}
