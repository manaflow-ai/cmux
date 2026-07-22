use std::fmt;

use serde::{Deserialize, Serialize};

use crate::Lane;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RelayRole {
    Daemon,
    Client,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RelayPermission {
    Register,
    Connect,
    Join,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CircuitId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct LaneToken(pub String);

/// Canonical scope carried by HMAC relay tickets. Provider authorization is
/// deliberately separate from daemon/device authentication.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayTicketClaims {
    pub version: u8,
    pub issuer: String,
    pub permission: RelayPermission,
    pub role: RelayRole,
    pub slot: String,
    pub circuit: Option<CircuitId>,
    pub lane: Option<LaneToken>,
    pub generation: Option<u64>,
    pub expires_at_unix: u64,
}

impl RelayTicketClaims {
    pub const VERSION: u8 = 1;

    /// Stable bytes shared by native and Durable Object ticket issuers.
    pub fn signing_payload(&self) -> Vec<u8> {
        let permission = match self.permission {
            RelayPermission::Register => "register",
            RelayPermission::Connect => "connect",
            RelayPermission::Join => "join",
        };
        let role = match self.role {
            RelayRole::Daemon => "daemon",
            RelayRole::Client => "client",
        };
        format!(
            "cmux-relay-ticket-v2\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            self.version,
            self.issuer,
            permission,
            role,
            self.slot,
            self.circuit.as_ref().map_or("", |value| value.0.as_str()),
            self.lane.as_ref().map_or("", |value| value.0.as_str()),
            self.generation.map_or_else(String::new, |value| value.to_string()),
            self.expires_at_unix,
        )
        .into_bytes()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum RelayControl {
    Register {
        protocol: u8,
        slot: String,
        ticket: String,
    },
    Registered {
        lease_seconds: u32,
    },
    Connect {
        protocol: u8,
        slot: String,
        ticket: String,
        lane: LaneToken,
        generation: u64,
    },
    Allocated {
        circuit: CircuitId,
        lane: LaneToken,
        generation: u64,
        join_ticket: String,
    },
    Incoming {
        circuit: CircuitId,
        lane: LaneToken,
        generation: u64,
        join_ticket: String,
    },
    Join {
        protocol: u8,
        slot: String,
        circuit: CircuitId,
        lane: LaneToken,
        generation: u64,
        ticket: String,
        role: RelayRole,
    },
    Ready {
        circuit: CircuitId,
        lane: LaneToken,
        generation: u64,
    },
    Ping {
        nonce: u64,
    },
    Pong {
        nonce: u64,
    },
    Error {
        code: String,
        message: String,
        retryable: bool,
    },
}

impl fmt::Debug for RelayControl {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Register { protocol, slot, .. } => formatter
                .debug_struct("Register")
                .field("protocol", protocol)
                .field("slot", slot)
                .field("ticket", &"[REDACTED]")
                .finish(),
            Self::Registered { lease_seconds } => {
                formatter.debug_struct("Registered").field("lease_seconds", lease_seconds).finish()
            }
            Self::Connect { protocol, slot, lane, generation, .. } => formatter
                .debug_struct("Connect")
                .field("protocol", protocol)
                .field("slot", slot)
                .field("ticket", &"[REDACTED]")
                .field("lane", lane)
                .field("generation", generation)
                .finish(),
            Self::Allocated { circuit, lane, generation, .. } => formatter
                .debug_struct("Allocated")
                .field("circuit", circuit)
                .field("lane", lane)
                .field("generation", generation)
                .field("join_ticket", &"[REDACTED]")
                .finish(),
            Self::Incoming { circuit, lane, generation, .. } => formatter
                .debug_struct("Incoming")
                .field("circuit", circuit)
                .field("lane", lane)
                .field("generation", generation)
                .field("join_ticket", &"[REDACTED]")
                .finish(),
            Self::Join { protocol, slot, circuit, lane, generation, role, .. } => formatter
                .debug_struct("Join")
                .field("protocol", protocol)
                .field("slot", slot)
                .field("circuit", circuit)
                .field("lane", lane)
                .field("generation", generation)
                .field("ticket", &"[REDACTED]")
                .field("role", role)
                .finish(),
            Self::Ready { circuit, lane, generation } => formatter
                .debug_struct("Ready")
                .field("circuit", circuit)
                .field("lane", lane)
                .field("generation", generation)
                .finish(),
            Self::Ping { nonce } => formatter.debug_struct("Ping").field("nonce", nonce).finish(),
            Self::Pong { nonce } => formatter.debug_struct("Pong").field("nonce", nonce).finish(),
            Self::Error { code, message, retryable } => formatter
                .debug_struct("Error")
                .field("code", code)
                .field("message", message)
                .field("retryable", retryable)
                .finish(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelaySocketAttachment {
    pub role: RelayRole,
    pub slot: String,
    pub circuit: Option<CircuitId>,
    pub lane: Option<LaneToken>,
}

impl RelaySocketAttachment {
    pub fn control(slot: String) -> Self {
        Self { role: RelayRole::Daemon, slot, circuit: None, lane: None }
    }

    pub fn circuit(role: RelayRole, slot: String, circuit: CircuitId, lane: LaneToken) -> Self {
        Self { role, slot, circuit: Some(circuit), lane: Some(lane) }
    }
}

#[allow(dead_code)]
fn _lane_remains_endpoint_only(_: Lane) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_control_does_not_name_application_services() {
        let message = RelayControl::Incoming {
            circuit: CircuitId("opaque-circuit".into()),
            lane: LaneToken("opaque-lane".into()),
            generation: 7,
            join_ticket: "opaque-ticket".into(),
        };
        let json = serde_json::to_string(&message).unwrap();
        for secret in ["workspace", "terminal", "process", "path", "command"] {
            assert!(!json.contains(secret));
        }
    }

    #[test]
    fn ticket_scope_is_canonical_and_binds_lane_generation() {
        let claims = RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: "relay.example".into(),
            permission: RelayPermission::Join,
            role: RelayRole::Client,
            slot: "slot".into(),
            circuit: Some(CircuitId("circuit".into())),
            lane: Some(LaneToken("lane".into())),
            generation: Some(4),
            expires_at_unix: 99,
        };
        let payload = String::from_utf8(claims.signing_payload()).unwrap();
        assert!(payload.contains("\njoin\nclient\nslot\ncircuit\nlane\n4\n99"));
    }

    #[test]
    fn relay_control_debug_redacts_all_credentials() {
        let messages = [
            RelayControl::Register {
                protocol: 1,
                slot: "slot".into(),
                ticket: "register-secret".into(),
            },
            RelayControl::Allocated {
                circuit: CircuitId("circuit".into()),
                lane: LaneToken("lane".into()),
                generation: 2,
                join_ticket: "join-secret".into(),
            },
            RelayControl::Join {
                protocol: 1,
                slot: "slot".into(),
                circuit: CircuitId("circuit".into()),
                lane: LaneToken("lane".into()),
                generation: 2,
                ticket: "join-secret".into(),
                role: RelayRole::Client,
            },
        ];

        for message in messages {
            let debug = format!("{message:?}");
            assert!(debug.contains("[REDACTED]"));
            assert!(!debug.contains("register-secret"));
            assert!(!debug.contains("join-secret"));
        }
    }
}
