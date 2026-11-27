use std::fmt;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_remote_protocol::{CircuitId, LaneToken, RelayPermission, RelayRole, RelayTicketClaims};
use hmac::{Hmac, Mac};
use sha2::Sha256;

pub(crate) const MAX_TICKET_BYTES: usize = 4 * 1024;
pub(crate) const DEFAULT_TICKET_ISSUER: &str = "cmux-relay";
const TICKET_PREFIX: &str = "v2";
const MIN_KEY_BYTES: usize = 32;
const MAX_SCOPE_BYTES: usize = 256;

#[derive(Debug, Clone, Copy)]
pub(crate) struct TicketExpectation<'a> {
    pub permission: RelayPermission,
    pub role: RelayRole,
    pub slot: &'a str,
    pub circuit: Option<&'a CircuitId>,
    pub lane: Option<&'a LaneToken>,
    pub generation: Option<u64>,
    pub now: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TicketError {
    Configuration,
    Encoding,
    Signature,
    Claims,
    Expired,
    UnsupportedVersion,
    Scope,
}

impl fmt::Display for TicketError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::Configuration => "ticket verifier is not configured",
            Self::Encoding => "ticket encoding is invalid",
            Self::Signature => "ticket signature is invalid",
            Self::Claims => "ticket claims are invalid",
            Self::Expired => "ticket has expired",
            Self::UnsupportedVersion => "relay ticket claims version is unsupported",
            Self::Scope => "ticket scope does not authorize this operation",
        };
        formatter.write_str(message)
    }
}

pub(crate) fn issue_ticket(
    claims: &RelayTicketClaims,
    key: &[u8],
    expected_issuer: &str,
) -> Result<String, TicketError> {
    validate_configuration(key, expected_issuer)?;
    validate_issuable_claims(claims, expected_issuer)?;

    let payload =
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).map_err(|_| TicketError::Claims)?);
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| TicketError::Configuration)?;
    mac.update(&claims.signing_payload());
    let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    Ok(format!("{TICKET_PREFIX}.{payload}.{signature}"))
}

pub(crate) fn verify_ticket(
    ticket: &str,
    key: &[u8],
    expected_issuer: &str,
    expected: TicketExpectation<'_>,
) -> Result<RelayTicketClaims, TicketError> {
    let claims = verify_ticket_claims(ticket, key, expected_issuer, expected.now)?;
    if !scope_matches(&claims, expected) {
        return Err(TicketError::Scope);
    }
    Ok(claims)
}

pub(crate) fn verify_ticket_claims(
    ticket: &str,
    key: &[u8],
    expected_issuer: &str,
    now: u64,
) -> Result<RelayTicketClaims, TicketError> {
    validate_configuration(key, expected_issuer)?;
    if ticket.len() > MAX_TICKET_BYTES {
        return Err(TicketError::Encoding);
    }

    let mut parts = ticket.split('.');
    let prefix = parts.next().ok_or(TicketError::Encoding)?;
    let payload = parts.next().ok_or(TicketError::Encoding)?;
    let signature = parts.next().ok_or(TicketError::Encoding)?;
    if prefix != TICKET_PREFIX || parts.next().is_some() {
        return Err(TicketError::Encoding);
    }

    let payload = URL_SAFE_NO_PAD.decode(payload).map_err(|_| TicketError::Encoding)?;
    let claims: RelayTicketClaims =
        serde_json::from_slice(&payload).map_err(|_| TicketError::Claims)?;
    validate_claim_shape(&claims, expected_issuer)?;

    let signature = URL_SAFE_NO_PAD.decode(signature).map_err(|_| TicketError::Encoding)?;
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| TicketError::Configuration)?;
    mac.update(&claims.signing_payload());
    mac.verify_slice(&signature).map_err(|_| TicketError::Signature)?;

    if claims.expires_at_unix <= now {
        return Err(TicketError::Expired);
    }
    if !claims.is_temporally_valid_at(now) {
        return Err(TicketError::Claims);
    }
    Ok(claims)
}

fn validate_configuration(key: &[u8], issuer: &str) -> Result<(), TicketError> {
    if key.len() < MIN_KEY_BYTES || !valid_scope_component(issuer) {
        return Err(TicketError::Configuration);
    }
    Ok(())
}

fn validate_claim_shape(
    claims: &RelayTicketClaims,
    expected_issuer: &str,
) -> Result<(), TicketError> {
    if claims.version != RelayTicketClaims::VERSION {
        return Err(TicketError::UnsupportedVersion);
    }
    if claims.issuer != expected_issuer
        || !valid_scope_component(&claims.slot)
        || claims.issued_at_unix == 0
        || claims.expires_at_unix == 0
        || claims.circuit.as_ref().is_some_and(|value| !valid_scope_component(&value.0))
        || claims.lane.as_ref().is_some_and(|value| !valid_scope_component(&value.0))
    {
        return Err(TicketError::Claims);
    }

    match claims.permission {
        RelayPermission::Register => {
            if claims.role != RelayRole::Daemon
                || claims.circuit.is_some()
                || claims.lane.is_some()
                || claims.generation.is_some()
            {
                return Err(TicketError::Claims);
            }
        }
        RelayPermission::Connect => {
            if claims.role != RelayRole::Client || claims.circuit.is_some() {
                return Err(TicketError::Claims);
            }
        }
        RelayPermission::Join => {
            if claims.circuit.is_none() || claims.lane.is_none() || claims.generation.is_none() {
                return Err(TicketError::Claims);
            }
        }
    }
    Ok(())
}

fn validate_issuable_claims(
    claims: &RelayTicketClaims,
    expected_issuer: &str,
) -> Result<(), TicketError> {
    validate_claim_shape(claims, expected_issuer)?;
    if !claims.has_valid_lifetime() {
        return Err(TicketError::Claims);
    }
    Ok(())
}

fn scope_matches(claims: &RelayTicketClaims, expected: TicketExpectation<'_>) -> bool {
    if claims.permission != expected.permission
        || claims.role != expected.role
        || claims.slot != expected.slot
    {
        return false;
    }

    optional_scope_matches(claims.circuit.as_ref(), expected.circuit)
        && optional_scope_matches(claims.lane.as_ref(), expected.lane)
        && match claims.generation {
            Some(generation) => Some(generation) == expected.generation,
            None => expected.permission != RelayPermission::Join,
        }
}

fn optional_scope_matches<T: PartialEq>(claimed: Option<&T>, expected: Option<&T>) -> bool {
    match claimed {
        Some(claimed) => Some(claimed) == expected,
        None => true,
    }
}

fn valid_scope_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_SCOPE_BYTES
        && !value.bytes().any(|byte| matches!(byte, b'\n' | b'\r'))
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &[u8] = b"0123456789abcdef0123456789abcdef";
    const OTHER_KEY: &[u8] = b"fedcba9876543210fedcba9876543210";
    const ISSUER: &str = "relay.cloudflare.example";

    fn claims(permission: RelayPermission, role: RelayRole) -> RelayTicketClaims {
        RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: ISSUER.into(),
            permission,
            role,
            slot: "opaque-slot".into(),
            circuit: None,
            lane: None,
            generation: None,
            issued_at_unix: 100,
            expires_at_unix: 200,
        }
    }

    fn wire_claims(issued_at_unix: u64, expires_at_unix: u64) -> RelayTicketClaims {
        serde_json::from_value(serde_json::json!({
            "version": RelayTicketClaims::VERSION,
            "issuer": ISSUER,
            "permission": "connect",
            "role": "client",
            "slot": "opaque-slot",
            "circuit": null,
            "lane": null,
            "generation": null,
            "issued_at_unix": issued_at_unix,
            "expires_at_unix": expires_at_unix,
        }))
        .unwrap()
    }

    fn intended_signing_payload(claims: &RelayTicketClaims, issued_at_unix: u64) -> Vec<u8> {
        let permission = match claims.permission {
            RelayPermission::Register => "register",
            RelayPermission::Connect => "connect",
            RelayPermission::Join => "join",
        };
        let role = match claims.role {
            RelayRole::Daemon => "daemon",
            RelayRole::Client => "client",
        };
        format!(
            "cmux-relay-ticket-v2\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            claims.version,
            claims.issuer,
            permission,
            role,
            claims.slot,
            claims.circuit.as_ref().map_or("", |value| value.0.as_str()),
            claims.lane.as_ref().map_or("", |value| value.0.as_str()),
            claims.generation.map_or_else(String::new, |value| value.to_string()),
            issued_at_unix,
            claims.expires_at_unix,
        )
        .into_bytes()
    }

    fn intended_ticket(claims: &RelayTicketClaims, issued_at_unix: u64) -> String {
        let mut wire_claims = serde_json::to_value(claims).unwrap();
        wire_claims["issued_at_unix"] = serde_json::json!(issued_at_unix);
        let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&wire_claims).unwrap());
        let mut mac = Hmac::<Sha256>::new_from_slice(KEY).unwrap();
        mac.update(&intended_signing_payload(claims, issued_at_unix));
        let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
        format!("{TICKET_PREFIX}.{payload}.{signature}")
    }

    fn tamper_issued_at(ticket: &str, issued_at_unix: u64) -> String {
        let parts = ticket.split('.').collect::<Vec<_>>();
        let mut claims: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        claims["issued_at_unix"] = serde_json::json!(issued_at_unix);
        let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
        format!("{}.{}.{}", parts[0], payload, parts[2])
    }

    fn legacy_v1_ticket() -> String {
        let claims = serde_json::json!({
            "version": 1,
            "issuer": ISSUER,
            "permission": "connect",
            "role": "client",
            "slot": "opaque-slot",
            "circuit": null,
            "lane": null,
            "generation": null,
            "expires_at_unix": 1_100,
        });
        let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
        let mut mac = Hmac::<Sha256>::new_from_slice(KEY).unwrap();
        mac.update(
            b"cmux-relay-ticket-v2\n1\nrelay.cloudflare.example\nconnect\nclient\nopaque-slot\n\n\n\n1100",
        );
        let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
        format!("{TICKET_PREFIX}.{payload}.{signature}")
    }

    #[test]
    fn uses_shared_v2_claims_and_canonical_signing_payload() {
        let mut claims = claims(RelayPermission::Connect, RelayRole::Client);
        claims.lane = Some(LaneToken("interactive".into()));
        claims.generation = Some(4);
        let ticket = issue_ticket(&claims, KEY, ISSUER).unwrap();
        assert!(ticket.starts_with("v2."));

        let verified = verify_ticket(
            &ticket,
            KEY,
            ISSUER,
            TicketExpectation {
                permission: RelayPermission::Connect,
                role: RelayRole::Client,
                slot: "opaque-slot",
                circuit: None,
                lane: Some(&LaneToken("interactive".into())),
                generation: Some(4),
                now: 100,
            },
        )
        .unwrap();
        assert_eq!(verified, claims);
    }

    #[test]
    fn provider_ticket_can_be_slot_wide_but_cannot_cross_permission() {
        let claims = claims(RelayPermission::Connect, RelayRole::Client);
        let ticket = issue_ticket(&claims, KEY, ISSUER).unwrap();
        let lane = LaneToken("bulk".into());
        let expectation = TicketExpectation {
            permission: RelayPermission::Connect,
            role: RelayRole::Client,
            slot: "opaque-slot",
            circuit: None,
            lane: Some(&lane),
            generation: Some(9),
            now: 100,
        };
        assert!(verify_ticket(&ticket, KEY, ISSUER, expectation).is_ok());

        let wrong_permission = TicketExpectation {
            permission: RelayPermission::Register,
            role: RelayRole::Daemon,
            ..expectation
        };
        assert_eq!(verify_ticket(&ticket, KEY, ISSUER, wrong_permission), Err(TicketError::Scope));
    }

    #[test]
    fn join_tickets_are_role_and_route_bound() {
        let circuit = CircuitId("circuit".into());
        let lane = LaneToken("lane".into());
        let mut client = claims(RelayPermission::Join, RelayRole::Client);
        client.circuit = Some(circuit.clone());
        client.lane = Some(lane.clone());
        client.generation = Some(7);
        let mut daemon = client.clone();
        daemon.role = RelayRole::Daemon;

        let client_ticket = issue_ticket(&client, KEY, ISSUER).unwrap();
        let daemon_ticket = issue_ticket(&daemon, KEY, ISSUER).unwrap();
        assert_ne!(client_ticket, daemon_ticket);

        let expected = TicketExpectation {
            permission: RelayPermission::Join,
            role: RelayRole::Client,
            slot: "opaque-slot",
            circuit: Some(&circuit),
            lane: Some(&lane),
            generation: Some(7),
            now: 100,
        };
        assert!(verify_ticket(&client_ticket, KEY, ISSUER, expected).is_ok());
        assert_eq!(
            verify_ticket(
                &client_ticket,
                KEY,
                ISSUER,
                TicketExpectation { generation: Some(8), ..expected },
            ),
            Err(TicketError::Scope)
        );
        assert_eq!(
            verify_ticket(
                &client_ticket,
                KEY,
                ISSUER,
                TicketExpectation { role: RelayRole::Daemon, ..expected },
            ),
            Err(TicketError::Scope)
        );
    }

    #[test]
    fn rejects_wrong_key_issuer_and_expiry() {
        let claims = claims(RelayPermission::Connect, RelayRole::Client);
        let ticket = issue_ticket(&claims, KEY, ISSUER).unwrap();
        let expected = TicketExpectation {
            permission: RelayPermission::Connect,
            role: RelayRole::Client,
            slot: "opaque-slot",
            circuit: None,
            lane: None,
            generation: None,
            now: 100,
        };
        assert_eq!(
            verify_ticket(&ticket, OTHER_KEY, ISSUER, expected),
            Err(TicketError::Signature)
        );
        assert_eq!(verify_ticket(&ticket, KEY, "other-relay", expected), Err(TicketError::Claims));
        assert_eq!(
            verify_ticket(&ticket, KEY, ISSUER, TicketExpectation { now: 200, ..expected },),
            Err(TicketError::Expired)
        );
    }

    #[test]
    fn rejects_ticket_lifetime_over_five_minutes() {
        let claims = wire_claims(1_000, 1_301);
        let ticket = intended_ticket(&claims, 1_000);
        assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000), Err(TicketError::Claims));
    }

    #[test]
    fn rejects_ticket_issued_more_than_five_minutes_ago() {
        let claims = wire_claims(699, 1_001);
        let ticket = intended_ticket(&claims, 699);
        assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000), Err(TicketError::Claims));
    }

    #[test]
    fn rejects_ticket_issued_beyond_clock_skew() {
        let claims = wire_claims(1_031, 1_100);
        let ticket = intended_ticket(&claims, 1_031);
        assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000), Err(TicketError::Claims));
    }

    #[test]
    fn accepts_lifetime_and_clock_skew_boundaries() {
        for (issued_at_unix, expires_at_unix) in [(1_000, 1_300), (1_030, 1_300)] {
            let claims = wire_claims(issued_at_unix, expires_at_unix);
            let ticket = intended_ticket(&claims, issued_at_unix);
            assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000).unwrap(), claims);
        }
    }

    #[test]
    fn issued_at_is_covered_by_signature() {
        let claims = wire_claims(1_000, 1_100);
        let ticket = intended_ticket(&claims, 1_000);
        assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000).unwrap(), claims);
        assert_eq!(
            verify_ticket_claims(&tamper_issued_at(&ticket, 1_001), KEY, ISSUER, 1_000),
            Err(TicketError::Signature)
        );
    }

    #[test]
    fn rejects_legacy_claims_version_explicitly() {
        let error = verify_ticket_claims(&legacy_v1_ticket(), KEY, ISSUER, 1_000)
            .expect_err("legacy claims must be rejected");
        assert!(error.to_string().contains("version"));
    }
}
