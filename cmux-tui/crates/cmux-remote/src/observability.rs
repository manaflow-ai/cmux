use cmux_remote_protocol::Lane;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ConnectionState {
    Connected,
    Reconnecting,
    Disconnected,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TransportPathKind {
    Local,
    Direct,
    Relay,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransportPathSnapshot {
    pub kind: TransportPathKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtt_micros: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransportSnapshot {
    pub provider: String,
    pub route: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected_path: Option<TransportPathSnapshot>,
}

impl TransportSnapshot {
    pub fn unknown() -> Self {
        Self { provider: "unknown".into(), route: String::new(), selected_path: None }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientConnectionSnapshot {
    pub session_id: String,
    pub generation: u64,
    pub state: ConnectionState,
    pub lane_bindings: Vec<Vec<Lane>>,
    pub physical_link_count: usize,
    pub transport: TransportSnapshot,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerConnectionSnapshot {
    pub device_id: String,
    pub session_id: String,
    pub generation: u64,
    pub state: ConnectionState,
    pub resume_lease_remaining_ms: Option<u64>,
    pub lane_bindings: Vec<Vec<Lane>>,
    pub physical_link_count: usize,
}
