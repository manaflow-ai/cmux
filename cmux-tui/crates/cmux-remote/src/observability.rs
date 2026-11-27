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
mod tests {
    use super::*;

    /// The transport snapshot crosses processes as JSON (`remote_cli` topology, the terminal
    /// client), so a daemon and a client one build apart read each other: `outer` is optional both
    /// ways.
    #[test]
    fn outer_path_is_optional_for_old_writers_and_old_readers() {
        // An old writer: no `outer`.
        let old = r#"{"provider":"relay","route":"relay+do://r","selected_path":{"kind":"relay","remote":"r:443","rtt_micros":12}}"#;
        let read: TransportSnapshot = serde_json::from_str(old).unwrap();
        assert_eq!(read.selected_path.as_ref().unwrap().outer, None);
        // A path with no outer path writes no `outer` key, so it is byte for byte what old builds wrote.
        assert!(!serde_json::to_string(&read).unwrap().contains("outer"));

        // A new writer with an outer path, read by a build that has never heard of `outer`.
        #[derive(Deserialize)]
        struct OldPath {
            kind: TransportPathKind,
            remote: Option<String>,
            rtt_micros: Option<u64>,
        }
        #[derive(Deserialize)]
        struct OldSnapshot {
            provider: String,
            selected_path: Option<OldPath>,
        }
        let mut new = read;
        new.selected_path.as_mut().unwrap().outer = Some(OuterPathSnapshot {
            proxy: Some("HTTP proxy p:3128".into()),
            tls_inspected: true,
        });
        let json = serde_json::to_string(&new).unwrap();
        let old_reader: OldSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(old_reader.provider, "relay");
        let path = old_reader.selected_path.unwrap();
        assert_eq!(
            (path.kind, path.remote.as_deref(), path.rtt_micros),
            (TransportPathKind::Relay, Some("r:443"), Some(12))
        );
        assert_eq!(serde_json::from_str::<TransportSnapshot>(&json).unwrap(), new);

        // A later writer may add fields to `outer` or leave `proxy` out.
        let later = r#"{"provider":"relay","route":"","selected_path":{"kind":"relay","outer":{"tls_inspected":true,"via":"pac"}}}"#;
        let outer = serde_json::from_str::<TransportSnapshot>(later)
            .unwrap()
            .selected_path
            .unwrap()
            .outer
            .unwrap();
        assert_eq!(outer, OuterPathSnapshot { proxy: None, tls_inspected: true });
        // And an `outer` with neither field still reads.
        let empty =
            r#"{"provider":"relay","route":"","selected_path":{"kind":"relay","outer":{}}}"#;
        assert_eq!(
            serde_json::from_str::<TransportSnapshot>(empty).unwrap().selected_path.unwrap().outer,
            Some(OuterPathSnapshot::default())
        );
    }
}
