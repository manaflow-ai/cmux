//! The daemon's acpmux call for the `fleet.hosts` signal source (`apps/fleet_hosts.rs`):
//! `_acpmux/peer_status`, this machine's health and every peer's, each peer asked at once
//! with its own 5 s bound. It opens its own link to this machine's acpmux socket for the one
//! call and never starts acpmux.

use std::time::Duration;

use serde_json::{Value, json};

use super::{AcpmuxLink, LinkError};

/// acpmux bounds each peer at 5 s and asks them at once; this machine's own health adds little.
const STATUS_TIMEOUT: Duration = Duration::from_secs(10);

impl crate::mux::Mux {
    /// `_acpmux/peer_status`: `{"hosts": [ROW...]}`, or why it could not be read.
    pub(crate) fn acp_peer_status(&self) -> Result<Value, String> {
        let socket = self
            .control_clients
            .agent_sessions
            .socket()
            .ok_or_else(|| "acpmux is not running here".to_string())?;
        let link =
            AcpmuxLink::connect(&socket, |_| {}).map_err(|error| format!("acpmux: {error}"))?;
        let answer = link.call("_acpmux/peer_status", json!({}), STATUS_TIMEOUT);
        link.close();
        answer.map_err(|error| match error {
            LinkError::Rpc(message, _) | LinkError::BadList(message) => message,
            LinkError::MethodNotFound(_) => {
                "this acpmux is too old to report its machines (no _acpmux/peer_status)".into()
            }
            LinkError::Closed => "acpmux closed the link".into(),
            LinkError::Timeout | LinkError::Busy => "acpmux did not answer in time".into(),
        })
    }
}
