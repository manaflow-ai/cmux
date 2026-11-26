use std::fmt;

use serde::{Deserialize, Serialize};

/// Maximum carrier message accepted by relay implementations that batch
/// several encrypted remote frames into one WebSocket message.
pub const MAX_RELAY_BATCH_BYTES: usize = 1024 * 1024;

#[cfg_attr(test, derive(schemars::JsonSchema))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RelayRole {
    Daemon,
    Client,
}

#[cfg_attr(test, derive(schemars::JsonSchema))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RelayPermission {
    Register,
    Connect,
    Join,
}

#[cfg_attr(test, derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CircuitId(pub String);

#[cfg_attr(test, derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct LaneToken(pub String);

/// Canonical scope carried by HMAC relay tickets. Provider authorization is
/// deliberately separate from daemon/device authentication.
#[cfg_attr(test, derive(schemars::JsonSchema))]
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
    /// The CarrierGrant this Connect ticket was minted beside: the base64url
    /// SHA-256 of the grant's compact JWS. A relay that sees it requires the
    /// Connect to present that grant, so the grant is checked off the VM.
    /// Absent on the wire, and from the signing payload, when None, so a
    /// ticket without it signs to the same v2 bytes as before.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grant: Option<String>,
    /// Where the circuit's Durable Object should be created: a Cloudflare
    /// location hint (`wnam`, `weur`, ...) computed by the relay from the
    /// viewer's request, carried in both Join tickets so whichever end joins
    /// first creates the object near the viewer. Absent on the wire, and from
    /// the signing payload, when None, so a ticket without it signs to the
    /// same v2 bytes as before. A verifier that predates it decodes the ticket
    /// (unknown fields are ignored) but, signing without it, rejects the
    /// signature: only the relay that minted it verifies it, which is why it
    /// is signed and why both ends of one deploy always agree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
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
        let mut payload = format!(
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
        );
        if let Some(grant) = &self.grant {
            payload.push_str("\ngrant:");
            payload.push_str(grant);
        }
        if let Some(region) = &self.region {
            payload.push_str("\nregion:");
            payload.push_str(region);
        }
        payload.into_bytes()
    }
}

#[cfg_attr(test, derive(schemars::JsonSchema))]
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
    /// A daemon socket held open for one inline circuit (RFD 0039 cut 5), on
    /// the slot's control route with the same Register ticket. The relay
    /// answers `Registered`, then `Ready` once it pairs the socket with a
    /// client's inline `Connect`; from then on the socket carries that
    /// circuit's binary frames. It is not the slot's registration: `Incoming`
    /// never goes to it. A relay that predates this answers `Error` and closes.
    Standby {
        protocol: u8,
        slot: String,
        ticket: String,
    },
    Connect {
        protocol: u8,
        slot: String,
        ticket: String,
        lane: LaneToken,
        generation: u64,
        /// The client understands `Parked`. A relay sends `Parked` only when
        /// this is set, because an older client fails on a control type it
        /// does not know. Absent on the wire when false.
        #[serde(default, skip_serializing_if = "is_false")]
        accepts_parked: bool,
        /// The CarrierGrant's compact JWS, for a ticket that names one
        /// ([`RelayTicketClaims::grant`]). Absent on the wire when None.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        grant: Option<String>,
        /// The client takes its circuit on this socket (RFD 0039 cut 5): a
        /// relay with a daemon `Standby` socket free answers `Ready` here and
        /// forwards binary frames between this socket and that one, with no
        /// circuit hop. Otherwise, as for a client that leaves this unset, it
        /// answers `Allocated` and the circuit is joined as before. A relay
        /// that predates this ignores it. Absent on the wire when false.
        #[serde(default, skip_serializing_if = "is_false")]
        inline: bool,
    },
    /// The relay holds this Connect until the slot's daemon registers, then
    /// answers it with `Allocated`. Sent only to a client that set
    /// `accepts_parked`.
    Parked {
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

fn is_false(value: &bool) -> bool {
    !*value
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
            Self::Standby { protocol, slot, .. } => formatter
                .debug_struct("Standby")
                .field("protocol", protocol)
                .field("slot", slot)
                .field("ticket", &"[REDACTED]")
                .finish(),
            Self::Registered { lease_seconds } => {
                formatter.debug_struct("Registered").field("lease_seconds", lease_seconds).finish()
            }
            Self::Connect {
                protocol,
                slot,
                lane,
                generation,
                accepts_parked,
                grant,
                inline,
                ..
            } => formatter
                .debug_struct("Connect")
                .field("protocol", protocol)
                .field("slot", slot)
                .field("ticket", &"[REDACTED]")
                .field("lane", lane)
                .field("generation", generation)
                .field("accepts_parked", accepts_parked)
                .field("grant", &grant.as_ref().map(|_| "[REDACTED]"))
                .field("inline", inline)
                .finish(),
            Self::Parked { lane, generation } => formatter
                .debug_struct("Parked")
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

#[cfg(test)]
mod grant_tests {
    use super::*;

    fn connect_claims(grant: Option<&str>) -> RelayTicketClaims {
        RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: "issuer".into(),
            permission: RelayPermission::Connect,
            role: RelayRole::Client,
            slot: "slot-a".into(),
            circuit: None,
            lane: None,
            generation: None,
            issued_at_unix: 1_000,
            expires_at_unix: 1_300,
            grant: grant.map(str::to_owned),
            region: None,
        }
    }

    #[test]
    fn a_ticket_without_a_grant_signs_to_the_v2_bytes() {
        assert_eq!(
            connect_claims(None).signing_payload(),
            b"cmux-relay-ticket-v2\n2\nissuer\nconnect\nclient\nslot-a\n\n\n\n1000\n1300".to_vec()
        );
        let wire = serde_json::to_value(connect_claims(None)).unwrap();
        assert!(wire.get("grant").is_none());
    }

    #[test]
    fn a_ticket_naming_a_grant_signs_it() {
        let named = connect_claims(Some("digest-a"));
        assert!(named.signing_payload().ends_with(b"\n1300\ngrant:digest-a"));
        assert_ne!(named.signing_payload(), connect_claims(Some("digest-b")).signing_payload());
        let back: RelayTicketClaims =
            serde_json::from_value(serde_json::to_value(&named).unwrap()).unwrap();
        assert_eq!(back, named);
    }

    #[test]
    fn a_connect_carries_its_grant_only_when_set_and_never_prints_it() {
        let connect = |grant: Option<&str>| RelayControl::Connect {
            protocol: 1,
            slot: "slot-a".into(),
            ticket: "ticket".into(),
            lane: LaneToken("lane".into()),
            generation: 1,
            accepts_parked: false,
            grant: grant.map(str::to_owned),
            inline: false,
        };
        let bare = serde_json::to_value(connect(None)).unwrap();
        assert!(bare.get("grant").is_none());
        let legacy: RelayControl = serde_json::from_value(bare).unwrap();
        assert_eq!(legacy, connect(None));
        let with = connect(Some("header.claims.signature"));
        let wire = serde_json::to_value(&with).unwrap();
        assert_eq!(wire["grant"], "header.claims.signature");
        assert!(!format!("{with:?}").contains("header.claims.signature"));
    }
}

/// Old against new, both ways, for the `region` claim (relay placement). `OldClaims` is
/// `RelayTicketClaims` as shipped before `region`: same fields and signing bytes, no `region`.
#[cfg(test)]
mod region_lockstep_tests {
    use super::*;

    #[derive(Debug, PartialEq, Deserialize)]
    struct OldClaims {
        version: u8,
        issuer: String,
        permission: RelayPermission,
        role: RelayRole,
        slot: String,
        circuit: Option<CircuitId>,
        lane: Option<LaneToken>,
        generation: Option<u64>,
        #[serde(default)]
        issued_at_unix: u64,
        expires_at_unix: u64,
        #[serde(default)]
        grant: Option<String>,
    }

    fn join(region: Option<&str>) -> RelayTicketClaims {
        RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: "issuer".into(),
            permission: RelayPermission::Join,
            role: RelayRole::Client,
            slot: "slot-a".into(),
            circuit: Some(CircuitId("ab".repeat(32))),
            lane: Some(LaneToken("lane".into())),
            generation: Some(3),
            issued_at_unix: 1_000,
            expires_at_unix: 1_300,
            grant: None,
            region: region.map(str::to_owned),
        }
    }

    #[test]
    fn an_old_ticket_decodes_on_new_with_no_region_and_the_same_signing_bytes() {
        let old_wire = serde_json::json!({
            "version": 2, "issuer": "issuer", "permission": "join", "role": "client",
            "slot": "slot-a", "circuit": "ab".repeat(32), "lane": "lane", "generation": 3,
            "issued_at_unix": 1000, "expires_at_unix": 1300,
        });
        let new: RelayTicketClaims = serde_json::from_value(old_wire).unwrap();
        assert_eq!(new, join(None));
        assert_eq!(
            new.signing_payload(),
            format!(
                "cmux-relay-ticket-v2\n2\nissuer\njoin\nclient\nslot-a\n{}\nlane\n3\n1000\n1300",
                "ab".repeat(32)
            )
            .into_bytes()
        );
        assert!(serde_json::to_value(&new).unwrap().get("region").is_none());
    }

    #[test]
    fn a_new_ticket_with_a_region_decodes_on_old_and_is_signed_by_the_region() {
        let with = join(Some("weur"));
        let wire = serde_json::to_value(&with).unwrap();
        assert_eq!(wire["region"], "weur");
        // Old claims decoding ignores the extra key: no decoder in this crate refuses unknown fields.
        let old: OldClaims = serde_json::from_value(wire).unwrap();
        assert_eq!(old.slot, "slot-a");
        assert_eq!(old.generation, Some(3));
        // The region is signed: it cannot be changed or dropped without breaking the signature,
        // and an old verifier (which signs without it) rejects it rather than trust it.
        assert!(with.signing_payload().ends_with(b"\n1300\nregion:weur"));
        assert_ne!(with.signing_payload(), join(None).signing_payload());
        assert_ne!(with.signing_payload(), join(Some("enam")).signing_payload());
    }

    #[test]
    fn grant_and_region_sign_in_a_fixed_order() {
        let mut both = join(Some("apac"));
        both.grant = Some("digest".into());
        assert!(both.signing_payload().ends_with(b"\n1300\ngrant:digest\nregion:apac"));
    }
}
