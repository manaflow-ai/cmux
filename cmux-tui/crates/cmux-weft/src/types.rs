//! Control-protocol messages (JSON).

use std::net::Ipv6Addr;

use serde::{Deserialize, Serialize};

use crate::policy::PortRange;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NodeState {
    Pending,
    Approved,
}

impl NodeState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "pending" => Some(Self::Pending),
            "approved" => Some(Self::Approved),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayInfo {
    pub region: String,
    pub url: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegisterRequest {
    pub tailnet: String,
    pub auth_key: String,
    pub name: String,
    /// Ed25519 public key, standard base64.
    pub machine_key: String,
    /// X25519 public key, standard base64.
    pub node_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RegisterResponse {
    pub node_id: String,
    pub address: Ipv6Addr,
    pub state: NodeState,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerView {
    pub id: String,
    pub name: String,
    pub node_key: String,
    pub address: Ipv6Addr,
    pub home_relay: Option<String>,
    pub tags: Vec<String>,
    pub user: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboundAllow {
    pub node_key: String,
    pub ports: Vec<PortRange>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelfView {
    pub id: String,
    pub name: String,
    pub address: Ipv6Addr,
    pub node_key: String,
    pub tags: Vec<String>,
    pub state: NodeState,
    pub key_expires_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Netmap {
    pub version: u64,
    pub node: SelfView,
    pub peers: Vec<PeerView>,
    pub inbound: Vec<InboundAllow>,
    pub relays: Vec<RelayInfo>,
    pub relay_ticket: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EndpointsRequest {
    pub home_relay: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RotateRequest {
    pub node_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateTailnetRequest {
    pub name: String,
    #[serde(default)]
    pub require_approval: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MintAuthKeyResponse {
    pub key: String,
    pub expires_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PolicyResponse {
    pub version: u64,
    pub policy: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NodeSummary {
    pub id: String,
    pub name: String,
    pub address: Ipv6Addr,
    pub tags: Vec<String>,
    pub user: Option<String>,
    pub state: NodeState,
    pub home_relay: Option<String>,
    pub last_seen_ms: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuditEntry {
    pub ts_ms: u64,
    pub actor: String,
    pub action: String,
    pub detail: serde_json::Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ErrorBody {
    pub error: String,
}
