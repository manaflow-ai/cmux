use std::fmt;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_remote_protocol::{CircuitId, LaneToken, RelayPermission, RelayRole, RelayTicketClaims};
use hmac::{Hmac, Mac};
use sha2::Sha256;

const SIGNED_TICKET_PREFIX: &str = "v2";
const OPAQUE_TICKET_PREFIX: &str = "o2";
const DEFAULT_ISSUER: &str = "cmux-relay";
const MINIMUM_SECRET_BYTES: usize = 32;
const MAXIMUM_TICKET_BYTES: usize = 4 * 1024;
const OPAQUE_CAPABILITY_BYTES: usize = 32;
const MAXIMUM_SCOPE_BYTES: usize = 256;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone)]
pub struct TicketAuthority {
    issuer: String,
    secret: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct TicketExpectation<'a> {
    pub permission: RelayPermission,
    pub role: RelayRole,
    pub slot: &'a str,
    pub circuit: Option<&'a CircuitId>,
    pub lane: Option<&'a LaneToken>,
    pub generation: Option<u64>,
    pub require_route_binding: bool,
}

impl TicketAuthority {
    pub fn open() -> Self {
        Self::open_with_issuer(DEFAULT_ISSUER.into()).expect("default ticket issuer is valid")
    }

    pub fn open_with_issuer(issuer: String) -> Result<Self, TicketError> {
        validate_issuer(&issuer)?;
        Ok(Self { issuer, secret: None })
    }

    pub fn hmac(secret: Vec<u8>) -> Result<Self, TicketError> {
        Self::hmac_with_issuer(secret, DEFAULT_ISSUER.into())
    }

    pub fn hmac_with_issuer(secret: Vec<u8>, issuer: String) -> Result<Self, TicketError> {
        validate_issuer(&issuer)?;
        if secret.len() < MINIMUM_SECRET_BYTES {
            return Err(TicketError::InvalidSecret);
        }
        Ok(Self { issuer, secret: Some(secret) })
    }

    pub fn from_optional_secret(
        secret: Option<Vec<u8>>,
        issuer: String,
    ) -> Result<Self, TicketError> {
        match secret {
            Some(secret) => Self::hmac_with_issuer(secret, issuer),
            None => Self::open_with_issuer(issuer),
        }
    }

    pub fn issuer(&self) -> &str {
        &self.issuer
    }

    pub const fn uses_hmac(&self) -> bool {
        self.secret.is_some()
    }

    pub fn issue(&self, claims: &RelayTicketClaims) -> Result<String, TicketError> {
        let secret = self.secret.as_ref().ok_or(TicketError::SigningDisabled)?;
        validate_claim_shape(claims, &self.issuer)?;
        let payload =
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).map_err(|_| TicketError::Claims)?);
        let mut mac = HmacSha256::new_from_slice(secret).map_err(|_| TicketError::InvalidSecret)?;
        mac.update(&claims.signing_payload());
        let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
        Ok(format!("{SIGNED_TICKET_PREFIX}.{payload}.{signature}"))
    }

    pub fn issue_join_capability(&self, claims: &RelayTicketClaims) -> Result<String, TicketError> {
        if self.uses_hmac() {
            return self.issue(claims);
        }
        validate_claim_shape(claims, &self.issuer)?;
        if claims.permission != RelayPermission::Join {
            return Err(TicketError::Scope);
        }
        let mut capability = [0_u8; OPAQUE_CAPABILITY_BYTES];
        getrandom::fill(&mut capability).map_err(|_| TicketError::RandomnessUnavailable)?;
        Ok(format!("{OPAQUE_TICKET_PREFIX}.{}", URL_SAFE_NO_PAD.encode(capability)))
    }

    pub(crate) fn verify_provider(
        &self,
        ticket: &str,
        expected: TicketExpectation<'_>,
        now: SystemTime,
    ) -> Result<Option<RelayTicketClaims>, TicketError> {
        if !matches!(expected.permission, RelayPermission::Register | RelayPermission::Connect) {
            return Err(TicketError::Scope);
        }
        if self.secret.is_none() {
            if ticket.is_empty() {
                return Err(TicketError::Empty);
            }
            if ticket.len() > MAXIMUM_TICKET_BYTES {
                return Err(TicketError::Encoding);
            }
            return Ok(None);
        }
        self.verify_signed(ticket, expected, now).map(Some)
    }

    pub(crate) fn verify_join(
        &self,
        ticket: &str,
        expected: TicketExpectation<'_>,
        now: SystemTime,
    ) -> Result<Option<RelayTicketClaims>, TicketError> {
        if expected.permission != RelayPermission::Join || !expected.require_route_binding {
            return Err(TicketError::Scope);
        }
        if self.secret.is_none() {
            return Ok(None);
        }
        self.verify_signed(ticket, expected, now).map(Some)
    }

    fn verify_signed(
        &self,
        ticket: &str,
        expected: TicketExpectation<'_>,
        now: SystemTime,
    ) -> Result<RelayTicketClaims, TicketError> {
        let secret = self.secret.as_ref().ok_or(TicketError::SigningDisabled)?;
        if ticket.len() > MAXIMUM_TICKET_BYTES {
            return Err(TicketError::Encoding);
        }
        let mut fields = ticket.split('.');
        if fields.next() != Some(SIGNED_TICKET_PREFIX) {
            return Err(TicketError::Encoding);
        }
        let payload = fields.next().ok_or(TicketError::Encoding)?;
        let signature = fields.next().ok_or(TicketError::Encoding)?;
        if fields.next().is_some() {
            return Err(TicketError::Encoding);
        }
        let payload = URL_SAFE_NO_PAD.decode(payload).map_err(|_| TicketError::Encoding)?;
        let claims: RelayTicketClaims =
            serde_json::from_slice(&payload).map_err(|_| TicketError::Claims)?;
        validate_claim_shape(&claims, &self.issuer)?;
        let signature = URL_SAFE_NO_PAD.decode(signature).map_err(|_| TicketError::Encoding)?;
        let mut mac = HmacSha256::new_from_slice(secret).map_err(|_| TicketError::InvalidSecret)?;
        mac.update(&claims.signing_payload());
        mac.verify_slice(&signature).map_err(|_| TicketError::InvalidSignature)?;

        let now = now.duration_since(UNIX_EPOCH).map_err(|_| TicketError::InvalidClock)?.as_secs();
        if claims.expires_at_unix <= now {
            return Err(TicketError::Expired);
        }
        if !scope_matches(&claims, expected) {
            return Err(TicketError::Scope);
        }
        Ok(claims)
    }
}

fn validate_issuer(issuer: &str) -> Result<(), TicketError> {
    if !valid_scope_component(issuer) { Err(TicketError::InvalidIssuer) } else { Ok(()) }
}

fn validate_claim_shape(
    claims: &RelayTicketClaims,
    expected_issuer: &str,
) -> Result<(), TicketError> {
    if claims.version != RelayTicketClaims::VERSION
        || claims.issuer != expected_issuer
        || !valid_scope_component(&claims.slot)
        || claims.expires_at_unix == 0
    {
        return Err(TicketError::Claims);
    }
    if claims.circuit.as_ref().is_some_and(|value| !valid_scope_component(&value.0))
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

fn valid_scope_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAXIMUM_SCOPE_BYTES
        && !value.bytes().any(|byte| matches!(byte, b'\n' | b'\r'))
}

fn scope_matches(claims: &RelayTicketClaims, expected: TicketExpectation<'_>) -> bool {
    if claims.permission != expected.permission
        || claims.role != expected.role
        || claims.slot != expected.slot
    {
        return false;
    }
    let circuit_matches = optional_scope_matches(claims.circuit.as_ref(), expected.circuit);
    let lane_matches = optional_scope_matches(claims.lane.as_ref(), expected.lane);
    let generation_matches = match claims.generation {
        Some(claimed) => Some(claimed) == expected.generation,
        None => !expected.require_route_binding,
    };
    circuit_matches
        && lane_matches
        && generation_matches
        && (!expected.require_route_binding
            || (claims.circuit.is_some() && claims.lane.is_some() && claims.generation.is_some()))
}

fn optional_scope_matches<T: PartialEq>(claimed: Option<&T>, expected: Option<&T>) -> bool {
    match claimed {
        Some(claimed) => Some(claimed) == expected,
        None => true,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TicketError {
    Empty,
    Encoding,
    Claims,
    Expired,
    InvalidSignature,
    InvalidSecret,
    InvalidIssuer,
    InvalidClock,
    SigningDisabled,
    RandomnessUnavailable,
    Scope,
}

impl fmt::Display for TicketError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Empty => "relay ticket is empty",
            Self::Encoding => "relay ticket encoding is invalid",
            Self::Claims => "relay ticket claims are invalid",
            Self::Expired => "relay ticket has expired",
            Self::InvalidSignature => "relay ticket signature is invalid",
            Self::InvalidSecret => "relay HMAC secret must contain at least 32 bytes",
            Self::InvalidIssuer => {
                "relay ticket issuer must contain 1 to 256 bytes without newline"
            }
            Self::InvalidClock => "system clock cannot represent a relay ticket expiry",
            Self::SigningDisabled => "relay ticket signing is not configured",
            Self::RandomnessUnavailable => "secure randomness is unavailable",
            Self::Scope => "relay ticket does not authorize this operation",
        })
    }
}

impl std::error::Error for TicketError {}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    const ISSUER: &str = "relay.example";

    fn join_claims(expires_at_unix: u64) -> RelayTicketClaims {
        RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: ISSUER.into(),
            permission: RelayPermission::Join,
            role: RelayRole::Client,
            slot: "slot-a".into(),
            circuit: Some(CircuitId("circuit-a".into())),
            lane: Some(LaneToken("interactive".into())),
            generation: Some(7),
            expires_at_unix,
        }
    }

    fn join_expectation<'a>(circuit: &'a CircuitId, lane: &'a LaneToken) -> TicketExpectation<'a> {
        TicketExpectation {
            permission: RelayPermission::Join,
            role: RelayRole::Client,
            slot: "slot-a",
            circuit: Some(circuit),
            lane: Some(lane),
            generation: Some(7),
            require_route_binding: true,
        }
    }

    #[test]
    fn v2_ticket_round_trip_binds_permission_route_and_expiry() {
        let authority = TicketAuthority::hmac_with_issuer(vec![7; 32], ISSUER.into()).unwrap();
        let claims = join_claims(1_030);
        let ticket = authority.issue(&claims).unwrap();
        assert!(ticket.starts_with("v2."));
        let circuit = claims.circuit.clone().unwrap();
        let lane = claims.lane.clone().unwrap();
        let expectation = join_expectation(&circuit, &lane);
        let verified = authority
            .verify_join(&ticket, expectation, UNIX_EPOCH + Duration::from_secs(1_000))
            .unwrap()
            .unwrap();
        assert_eq!(verified, claims);

        let wrong_lane = LaneToken("bulk".into());
        assert_eq!(
            authority.verify_join(
                &ticket,
                join_expectation(&circuit, &wrong_lane),
                UNIX_EPOCH + Duration::from_secs(1_000),
            ),
            Err(TicketError::Scope)
        );
        assert_eq!(
            authority.verify_join(&ticket, expectation, UNIX_EPOCH + Duration::from_secs(1_030),),
            Err(TicketError::Expired)
        );
    }

    #[test]
    fn provider_ticket_permission_and_optional_route_scope_are_enforced() {
        let authority = TicketAuthority::hmac_with_issuer(vec![7; 32], ISSUER.into()).unwrap();
        let claims = RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: ISSUER.into(),
            permission: RelayPermission::Connect,
            role: RelayRole::Client,
            slot: "slot-a".into(),
            circuit: None,
            lane: None,
            generation: None,
            expires_at_unix: 1_030,
        };
        let ticket = authority.issue(&claims).unwrap();
        let expected = TicketExpectation {
            permission: RelayPermission::Connect,
            role: RelayRole::Client,
            slot: "slot-a",
            circuit: None,
            lane: Some(&LaneToken("interactive".into())),
            generation: Some(9),
            require_route_binding: false,
        };
        authority
            .verify_provider(&ticket, expected, UNIX_EPOCH + Duration::from_secs(1_000))
            .unwrap();
        assert_eq!(
            authority.verify_provider(
                &ticket,
                TicketExpectation { permission: RelayPermission::Register, ..expected },
                UNIX_EPOCH + Duration::from_secs(1_000),
            ),
            Err(TicketError::Scope)
        );
    }

    #[test]
    fn open_mode_issues_independent_strong_join_capabilities() {
        let authority = TicketAuthority::open_with_issuer(ISSUER.into()).unwrap();
        let claims = join_claims(1_030);
        let first = authority.issue_join_capability(&claims).unwrap();
        let second = authority.issue_join_capability(&claims).unwrap();
        assert!(first.starts_with("o2."));
        assert_ne!(first, second);
        assert!(first.len() >= 40);
    }
}
