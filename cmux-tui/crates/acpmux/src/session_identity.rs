//! Host-qualified session identity carried at session summary boundaries.
//!
//! A mux session id is unique only within the daemon that owns it.  The
//! receipt keeps the local id and the agent's native id together with the
//! ownership/liveness generation that produced the observation.  Callers may
//! use [`SessionReceipt::qualified_id`] for exact routing while continuing to
//! accept the older name and prefix forms.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The host name used for sessions owned by this daemon from its own view.
pub const LOCAL_HOST_ID: &str = "local";

/// The identity receipt for one observed mux session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionReceipt {
    /// The host that owns the mux session in this view.
    pub host_id: String,
    /// The id used by the owning mux daemon.
    pub mux_session_id: String,
    /// The native session id reported by the agent, when known.
    #[serde(default)]
    pub agent_session_id: Option<String>,
    /// The ownership/liveness generation that produced this receipt.
    pub generation: u64,
}

impl SessionReceipt {
    /// Builds a receipt from its four identity components.
    pub fn new(
        host_id: impl Into<String>,
        mux_session_id: impl Into<String>,
        agent_session_id: Option<String>,
        generation: u64,
    ) -> Self {
        Self {
            host_id: host_id.into(),
            mux_session_id: mux_session_id.into(),
            agent_session_id,
            generation,
        }
    }

    /// The exact id used for routing a session across hosts.
    pub fn qualified_id(&self) -> String {
        format!("{}/{}", self.host_id, self.mux_session_id)
    }

    /// Splits an exact id into its host and mux components.
    pub fn split_qualified_id(value: &str) -> Option<(&str, &str)> {
        let (host, mux) = value.split_once('/')?;
        if host.is_empty() || mux.is_empty() || mux.contains('/') {
            return None;
        }
        Some((host, mux))
    }

    /// Serializes this receipt for a session summary or another receipt.
    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).expect("SessionReceipt is always serializable")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn receipt_round_trips_with_a_qualified_id() {
        let receipt =
            SessionReceipt::new("build-host", "mux-123", Some("agent-456".to_owned()), 17);
        assert_eq!(receipt.qualified_id(), "build-host/mux-123");
        assert_eq!(
            receipt.to_value(),
            json!({
                "hostId": "build-host",
                "muxSessionId": "mux-123",
                "agentSessionId": "agent-456",
                "generation": 17,
            })
        );
        assert_eq!(serde_json::from_value::<SessionReceipt>(receipt.to_value()).unwrap(), receipt);
    }

    #[test]
    fn qualified_id_parser_rejects_ambiguous_forms() {
        assert_eq!(SessionReceipt::split_qualified_id("host/mux"), Some(("host", "mux")));
        for value in ["mux", "/mux", "host/", "host/mux/extra"] {
            assert_eq!(SessionReceipt::split_qualified_id(value), None, "{value}");
        }
    }
}
