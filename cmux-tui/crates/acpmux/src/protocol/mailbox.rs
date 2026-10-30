//! Typed shapes for the daemon-local `_acpmux/mail/*` methods.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::mailbox::{DeliveryReceipt, MailMessage};

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct MailSendParams {
    pub id: String,
    pub sender: String,
    /// Session recipient for ordinary mail. Omit when `target` is supplied.
    pub recipient: Option<String>,
    pub body: String,
    /// Quiet reports alias (`reports:<person>`). Omit for session mail.
    pub target: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(with = "Option<BTreeMap<String, Value>>")]
    pub metadata: Option<BTreeMap<String, Value>>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MailSendResult {
    pub message: MailMessage,
    pub delivery: DeliveryReceipt,
    pub created: bool,
    pub duplicate: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct MailReadParams {
    pub recipient: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct MailWaitParams {
    pub recipient: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MailPageResult {
    pub cursor: u64,
    pub messages: Vec<MailRow>,
    pub next_cursor: Option<u64>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MailRow {
    pub message: MailMessage,
    pub delivery: DeliveryReceipt,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct MailAckParams {
    pub recipient: String,
    pub message_id: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MailAckResult {
    pub delivery: DeliveryReceipt,
}
