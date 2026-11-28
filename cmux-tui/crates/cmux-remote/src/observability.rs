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
    /// How the carrier's own TCP and TLS left this machine, where the provider knows (the relay):
    /// `None` for a path that has not connected yet or a provider that does not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outer: Option<OuterPathSnapshot>,
}

/// The outer path of a carrier (`provider::proxied`): telemetry only, since the Noise session
/// inside is end to end whatever carries it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OuterPathSnapshot {
    /// The proxy the connection went through (`HTTP proxy host:port`, never its credentials),
    /// `None` for a direct connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<String>,
    /// The server's TLS chain is not one the public web PKI vouches for: a proxy that inspects
    /// TLS re-signed it with a company root the OS trusts (or the server uses a private CA).
    #[serde(default)]
    pub tls_inspected: bool,
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
    /// How long since the client last sent a frame the session delivered
    /// (anything but connection control), or since the connection opened.
    /// The session supervisor replaces an old-build session host under a
    /// session idle this long (cmux-host `machine.rs`). Absent from an older
    /// session host.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_idle_ms: Option<u64>,
}

#[cfg(test)]
#[path = "observability_tests.rs"]
mod tests;
