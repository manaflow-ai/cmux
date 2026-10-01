//! Wire frames between the link and a mux server.
//! Mirrors packages/protocol/src/link.ts; keep them in sync.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineInfo {
    pub id: String,
    pub name: String,
    pub os: String,
    pub link_version: String,
    pub acpmux: bool,
}

/// Link to server.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Up {
    Hello { machine: MachineInfo },
    Result {
        id: u64,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        value: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    Event { event: Event },
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Event {
    #[serde(rename_all = "camelCase")]
    TurnEnd {
        session_id: String,
        name: String,
        status: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        stop_reason: Option<String>,
        reply: String,
    },
    #[serde(rename_all = "camelCase")]
    Permission {
        session_id: String,
        name: String,
        permission_id: String,
        title: String,
    },
}

/// Server to link.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Down {
    #[serde(rename_all = "camelCase")]
    Welcome { account_id: String },
    Call { id: u64, method: String, params: Value },
}
