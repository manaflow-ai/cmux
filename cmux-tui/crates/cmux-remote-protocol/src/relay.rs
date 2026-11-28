use std::fmt;

use serde::{Deserialize, Serialize};

/// Maximum carrier message accepted by relay implementations that batch
/// several encrypted remote frames into one WebSocket message.
pub const MAX_RELAY_BATCH_BYTES: usize = 1024 * 1024;

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
    #[serde(default)]
    pub issued_at_unix: u64,
    pub expires_at_unix: u64,
}

impl RelayTicketClaims {
    pub const VERSION: u8 = 2;
    pub const MAX_LIFETIME_SECONDS: u64 = 5 * 60;
    pub const MAX_FUTURE_CLOCK_SKEW_SECONDS: u64 = 30;

    pub fn has_valid_lifetime(&self) -> bool {
        self.issued_at_unix != 0
            && self
                .expires_at_unix
                .checked_sub(self.issued_at_unix)
                .is_some_and(|lifetime| lifetime > 0 && lifetime <= Self::MAX_LIFETIME_SECONDS)
    }

    pub fn is_temporally_valid_at(&self, now_unix: u64) -> bool {
        self.expires_at_unix > now_unix
            && self.issued_at_unix <= now_unix.saturating_add(Self::MAX_FUTURE_CLOCK_SKEW_SECONDS)
            && now_unix.saturating_sub(self.issued_at_unix) <= Self::MAX_LIFETIME_SECONDS
            && self.has_valid_lifetime()
    }

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
            "cmux-relay-ticket-v2\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            self.version,
            self.issuer,
            permission,
            role,
            self.slot,
            self.circuit.as_ref().map_or("", |value| value.0.as_str()),
            self.lane.as_ref().map_or("", |value| value.0.as_str()),
            self.generation.map_or_else(String::new, |value| value.to_string()),
            self.issued_at_unix,
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
